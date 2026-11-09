---
name: technology-objects
description: TIA Portal 工艺对象（Technology Object / TO）的创建与编辑，适用博途 V20/V21。用户提到工艺对象、TO、运动控制轴、TO_PositioningAxis、TO_SpeedAxis、TO_SynchronousAxis、凸轮/cam、测量输入、外部编码器、TO XML 导入导出、轴参数时使用。基于 TiaMcpServer 的 GetTechnologyObjects/ExportTechnologyObject/ImportTechnologyObject，以及 Openness 的 TechnologicalObjects.Create / Parameters.Find / AxisHardwareConnectionProvider。
---

# 工艺对象（Technology Objects, TO）

本技能只处理**工艺对象**：创建、读取、参数编辑、导出/导入、与驱动硬件互连。
其它任务（普通块/变量/HMI/下载）回到主技能 [../SKILL.md](../SKILL.md)。

## 0. 先认清事实（不要承诺做不到的事）

| 事实 | 含义 |
|---|---|
| TO 在工程树中的实体是 `SW.TechnologicalObjects.TechnologicalInstanceDB` | 导出/导入以这个 XML 为单位，不是普通 FB |
| TO 只能挂在 **PLC 根节点** `PlcSoftware.TechnologicalObjectGroup` | **不能**放进 SW-Unit（软件单元）里 |
| 当前版本（2.3.x）的 MCP 只暴露 5 个 TO 工具 | `GetTechnologyObjects`、`ExportTechnologyObject`、`ExportTechnologyObjectsToDirectory`、`ImportTechnologyObject`、`ImportTechnologyObjectsFromDirectory` |
| **没有** `CreateTechnologyObject` / `Get/SetTechnologyObjectParameter` / `DeleteTechnologyObject` MCP 工具 | 创建走 XML 模板导入；参数走 XML 编辑或原生 Openness API；删除只能在 TIA UI 或自写 Openness 程序 |
| 工具描述里 `ImportTechnologyObject` 标的是 "best-effort" | 导入后**必须**回读确认，不能只看调用成功 |
| TO 的 `type + version` 组合因安装的 TIA/Startdrive 库而异 | V21 已验证 `TO_PositioningAxis` = `10.0`；**不要**照抄示例里的 6.0/7.0/8.0 |

两条路线，选一条：

- **路线 A（默认，纯 MCP）**：导出模板 → 克隆/改名/改参数 → 导入 → 回读 → 编译。
  适用于：现场只有 MCP 客户端、已有至少一个同类型 TO 可作模板。
- **路线 B（原生 Openness API）**：`TechnologicalObjects.Create` + `Parameters.Find` + `ActorInterface.Connect`。
  适用于：从零创建、需要批量改参数、需要连驱动。要求自建 C# 程序并引用 Siemens.Engineering。

路线 A 的核心认知：**TO XML 不能凭空手写**。`Interface` 段是整条类型继承链（如
`TO_PositioningAxis → TO_SpeedAxis → TO_Axis → TO_AnyMotionObject → ...`），
版本号必须与本机库一致。手写/篡改类型等于制造不可导入的垃圾。

## 1. 路线 A：MCP 模板法（推荐）

### 1.1 标准动作序列（照抄）

```
Bootstrap                                   ← 环境自检，不连接
AttachToOpenProject(projectName=...)        ← 或 OpenProject(path) / CreateProject
GetProjectTree                               ← 取真实 softwarePath（如 PLC_1）
GetTechnologyObjects(softwarePath)           ← 确认现有 TO 名称与类型
ExportTechnologyObject(softwarePath, <同名TO>, "D:\to_work\tpl.xml")
   或 ExportTechnologyObjectsToDirectory(softwarePath, "D:\to_work\tpl", regexName="Axis_.*")
powershell scripts\Edit-ToXml.ps1 -Action Clone  -Path tpl.xml -OutFile new.xml -NewName Axis_2 -NewNumber 2
powershell scripts\Edit-ToXml.ps1 -Action Set    -Path new.xml -Parameter "_Actor.Interface.Telegram" -Value "106"
powershell scripts\Edit-ToXml.ps1 -Action Validate -Path new.xml
ImportTechnologyObject(softwarePath, folderPath="", importPath="D:\to_work\new.xml")
GetTechnologyObjects(softwarePath)           ← 必须看到新 TO
CompileAndDiagnosePlc(softwarePath)          ← errorCount 必须为 0
SaveProject
```

### 1.2 三种常见诉求的做法

**① 新建同类型 TO**：导出同类型现成 TO → `Clone` 改 `Name`/`Number` → 按需 `Set` 参数 → 导入。
没有可导出的同类型 TO 时，先在 TIA UI 手工建一个最小 TO（或跑路线 B 的 `Create`），导出后再复制。

**② 修改已有 TO 参数**：先备份原 XML → 导出 → `Set` → 用**同名**导入（服务端固定用
`ImportOptions.Override`）→ 回读。若 Override 被 TIA 拒绝，改名为 `原名_old` 导入新对象，
旧对象在 TIA UI 删除（MCP 无删除工具）。

**③ 跨项目复制 TO**：必须从**目标 TIA 版本**的工程导出模板，再导入目标工程。V19 导出的 XML
虽然通常能导入 V21，但 `VREF` / 报文地址、库版本可能不匹配；导入后要重新绑定硬件并编译验证。

### 1.3 命名与清理

- 新建对象统一加前缀（如 `MCP_TO_`），便于在 TIA UI 里找到并删除。
- `Number` 必须在该 PLC 内唯一；用 `GetTechnologyObjects` 看不到编号时，导出 XML 读 `<Number>`，
  或直接给一个远离现网段的编号。
- 批量导入按文件名列举结果，但对象名由 XML 内的 `<Name>` 决定；文件名只影响日志可读性。

## 2. 路线 B：原生 Openness API（创建/参数/硬件互连）

完整代码、版本探测、异常处理见 [references/openness-api.md](references/openness-api.md)。
最小骨架：

```csharp
using Siemens.Engineering.SW;
using Siemens.Engineering.SW.TechnologicalObjects;

var plcSoftware = ...; // PlcSoftware
var to = plcSoftware.TechnologicalObjectGroup.TechnologicalObjects
             .FirstOrDefault(t => t.Name == "MCP_TO_Axis1")
         ?? plcSoftware.TechnologicalObjectGroup.TechnologicalObjects
             .Create("MCP_TO_Axis1", "TO_PositioningAxis", new Version(10, 0));

to.Parameters.Find("Actor.InverseDirection")!.Value = true;
to.Parameters.Find("PositionLimits_HW.Active")!.Value = true;
```

三条硬规则：

1. `Create` 不会覆盖同名对象，必须先 `FirstOrDefault` 查重。
2. 版本号不要写死；V21 的 `TO_PositioningAxis` 用 `10.0`，其它类型/版本按
   [references/openness-api.md](references/openness-api.md) 的降序探测法处理。
3. 把轴连到驱动**不能**靠写 `Actor.Type` 等参数（不会抛异常，但也不会真连上）。必须用
   `GetService<AxisHardwareConnectionProvider>().ActorInterface.Connect(...)` 并检查 `IsConnected`。

## 3. 参数怎么找、怎么写

- **最可靠**：导出该 TO 的 XML，看 `<ParameterData><Parameters>` 里的
  `<Parameter Name="..." Value="..." />`。这是本机、本版本、本对象的真实参数名。
- API 路径（`Parameters.Find`）与 XML 参数名**不完全一致**：XML 里常见 `_Actor.*`、
  `_PositionLimits_HW.*`、`Sensor[2].*`；API 里常见 `Actor.*`、`PositionLimits_HW.*`。
  **不要机械转换**，两边都以实际导出/探测为准。
- 值类型：`Bool` 写 `True`/`False`；枚举写数字；实数用小数点（不变区域格式）；标签引用写符号名。
- `VREF`（`AddressIn`/`AddressOut`）是硬件地址引用，**不要手改**；换工程/换 CPU 后用路线 B 重连或
  在 TIA UI 重新选报文。

已验证可用的参数名（来自 Siemens 官方片段与真实导出，仍需在你的工程回读确认）：

| 参数 | 类型 | 含义 |
|---|---|---|
| `Actor.InverseDirection` | Bool | 反向运行（XML 名以导出为准） |
| `PositionLimits_HW.Active` | Bool | 启用硬件限位 |
| `_PositionLimits_HW.MinSwitchAddress` / `.MaxSwitchAddress` | PlcTag | 硬件限位开关点 |
| `_Actor.Interface.Telegram` / `_Sensor[1].Interface.Telegram` | 枚举数字 | 报文号（真实导出为 `106`） |
| `_Sensor[1].ActiveHoming.DigitalInput` | PlcTag | 回零开关 |
| `_Units.VelocityUnit` | 枚举数字 | 速度单位 |
| `_Actor.DataAdaptionOffline` | Bool | 离线数据适配 |
| `Sensor[2].Existent` | Bool | 是否启用第 2 个传感器 |

驱动侧参数（如 `Actor.DriveParameter.MaxSpeed`）随 Startdrive/报文配置变化，
必须从你自己的导出 XML 里确认名字，不要照抄。

更多类型与常用参数见 [references/to-types.md](references/to-types.md)。

## 4. TO XML 结构（必须懂，否则改坏文件）

```xml
<Document>
  <Engineering version="V21" />
  <SW.TechnologicalObjects.TechnologicalInstanceDB ID="0">
    <AttributeList>
      <HeaderAuthor>SIMATIC</HeaderAuthor> ... <HeaderVersion>10.0</HeaderVersion>
      <InstanceOfName>TO_PositioningAxis</InstanceOfName>
      <Interface> ... 类型继承链 + 成员 ... </Interface>
      <Name>Axis_1</Name>                         <!-- 对象名，导入后以此为准 -->
      <Number>1</Number>                          <!-- PLC 内唯一 -->
      <OfSystemLibElement>TO_PositioningAxis</OfSystemLibElement>
      <OfSystemLibVersion>10.0</OfSystemLibVersion>
      <ParameterData><Parameters>
        <Parameter Name="_Actor.DataAdaptionOffline" Value="True" />
      </Parameters></ParameterData>
      <ProgrammingLanguage>Motion_DB</ProgrammingLanguage>
    </AttributeList>
    <ObjectList> ... Title/Comment 多语言文本 ... </ObjectList>
  </SW.TechnologicalObjects.TechnologicalInstanceDB>
</Document>
```

详细字段、编辑边界与校验清单见 [references/to-xml-format.md](references/to-xml-format.md)。

**只能改**：`Name`、`Number`、`ParameterData/Parameters` 里的参数值、`ObjectList` 文本。
**不要改**：`Interface` 结构、`OfSystemLibElement`、`OfSystemLibVersion`、`ID`、`VREF` 地址块。

## 5. 脚本

`scripts/Edit-ToXml.ps1`（PowerShell 5.1 可用，UTF-8 BOM 输出）：

```powershell
# 查看全部参数与关键属性
.\Edit-ToXml.ps1 -Action List -Path .\Axis_1.xml

# 导入前结构自检（不启动 TIA）
.\Edit-ToXml.ps1 -Action Validate -Path .\new.xml

# 克隆模板并改名/改编号
.\Edit-ToXml.ps1 -Action Clone -Path .\Axis_1.xml -OutFile .\Axis_2.xml -NewName Axis_2 -NewNumber 2

# 改/增参数（值一律按字符串写入）
.\Edit-ToXml.ps1 -Action Set -Path .\Axis_2.xml -Parameter "_Actor.Interface.Telegram" -Value "106"

# 读单个参数
.\Edit-ToXml.ps1 -Action Get -Path .\Axis_2.xml -Parameter "_Actor.Interface.Telegram"
```

脚本只做文本级 XML 变换，不连接 TIA；导入与回读仍由 MCP 工具完成。

## 6. 验收清单（缺一项都不算完成）

1. `GetTechnologyObjects` 回读到目标 TO，且 `OfSystemLibElement` 与预期一致。
2. 若是改名/新建，`Number` 无冲突。
3. `CompileAndDiagnosePlc` 返回 `errorCount=0`（警告可接受）。
4. `SaveProject` 成功。
5. 涉及驱动轴：在 TIA UI 或路线 B 确认 `ActorInterface.IsConnected = true`，并核对输入/输出地址。
6. 已有工程里留下的一次性对象已按前缀标注，交付时告知用户清理名单。

## 7. 常见坑

| 现象 | 根因 | 处理 |
|---|---|---|
| 导入报 "does not exist or is not a valid technology object" | 本机没有该 type/version 库 | 换版本探测；确认装了 Startdrive/对应 CPU 固件库 |
| 导入成功但 `GetTechnologyObjects` 看不到 | best-effort 静默失败 / 名字未刷新 | 重新 `GetTechnologyObjects`；读服务端 stderr；换同名 Override |
| 对象建在 SW-Unit 下失败 | TO 不支持 SW-Unit | 强制放 PLC 根 |
| 编译报接口/类型错误 | 改了 `Interface` 或跨版本复制 | 回退到同版本导出的模板，只改 Name/Number/参数 |
| 轴“配置好了”但驱动不动 | 只写了 `Actor.*` 参数，没做硬件连接 | 用 `AxisHardwareConnectionProvider` 并验证 `IsConnected` |
| 中文名导入后乱码 | XML 非 UTF-8 BOM | 统一 UTF-8 BOM；中文名尽量只在 Title/Comment 用 |

## 8. 参考文件

- [references/mcp-tools.md](references/mcp-tools.md) — 5 个 TO 工具的精确参数、返回与限制
- [references/to-xml-format.md](references/to-xml-format.md) — 导出 XML 逐段说明与安全编辑边界
- [references/openness-api.md](references/openness-api.md) — C# 创建/改参/连驱动/版本探测
- [references/to-types.md](references/to-types.md) — 常用 TO 类型、适用 CPU、典型参数
