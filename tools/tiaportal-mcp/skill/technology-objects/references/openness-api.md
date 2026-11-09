# 原生 Openness API：创建、改参、连驱动

适用 TIA Portal V20 / V21（`Siemens.Engineering.Base.dll` + `Siemens.Engineering.Step7.dll`）。
以下代码来自 Siemens 官方 Openness 代码片段与官方 AI 技能，并标注了需要现场复核的点。

## 1. 命名空间与程序集

```csharp
using Siemens.Engineering;                 // Project, Version, MasterCopyMode
using Siemens.Engineering.HW;              // Device, DeviceItem, DeviceItemClassifications
using Siemens.Engineering.HW.Features;     // SoftwareContainer
using Siemens.Engineering.SW;              // PlcSoftware
using Siemens.Engineering.SW.TechnologicalObjects; // TechnologicalInstanceDBGroup / TechnologicalObject
using Siemens.Engineering.Compiler;        // Compiler（编译）
```

程序集：

- `Siemens.Engineering.Base.dll`
- `Siemens.Engineering.Step7.dll`

## 2. 拿到 PlcSoftware

```csharp
var device = project.Devices.First(d => d.Name == "PLC_1");
var cpu = device.DeviceItems.Single(i => i.Classification == DeviceItemClassifications.CPU);
var plcSoftware = cpu.GetService<SoftwareContainer>().Software as PlcSoftware;
```

也可用 `device.DeviceItems[1].GetService<SoftwareContainer>()`（官方片段写法），
但按 `Classification == CPU` 选更稳。

## 3. 创建 TO

```csharp
const string NameOfTo = "MCP_TO_Axis1";
const string TypeOfTo = "TO_PositioningAxis";

var to = plcSoftware.TechnologicalObjectGroup.TechnologicalObjects
    .FirstOrDefault(t => t.Name == NameOfTo);

if (to == null)
{
    to = plcSoftware.TechnologicalObjectGroup.TechnologicalObjects
        .Create(NameOfTo, TypeOfTo, new Version(10, 0));   // V21 定位轴：10.0
}
```

规则：

- `Create` **不会覆盖**同名对象；先 `FirstOrDefault` 查重。
- `TechnologicalObjectGroup` 是 PLC 根级容器；TO **不能**放进 SW-Unit。
- 子分组：

```csharp
TechnologicalInstanceDBGroup GetOrCreateToGroup(
    TechnologicalInstanceDBGroup root, IEnumerable<string> segments)
{
    var cur = root;
    foreach (var s in segments)
        cur = cur.Groups.Find(s) ?? cur.Groups.Create(s);
    return cur;
}
```

## 4. 版本号：必须探测，不能写死

`type + version` 取决于本机安装的 TIA / Startdrive / CPU 库。已确认：

- TIA Portal **V21**：`TO_PositioningAxis` → **`10.0`** 可用；
- 同一环境 `1.0`–`9.0`、`11.0`、`12.0` 均报 "does not exist or is not a valid technology object"。

没有公开 API 能在创建前枚举合法组合，因此用降序探测：

```csharp
static TechnologicalObject CreateWithVersionProbe(
    TechnologicalObjectComposition group, string name, string type,
    IEnumerable<double> candidateVersions)
{
    Exception? last = null;
    foreach (var v in candidateVersions.OrderByDescending(x => x))
    {
        try
        {
            return group.Create(name, type,
                new Version((int)v, (int)((v - (int)v) * 10)));
        }
        catch (Exception ex) { last = ex; }
    }
    throw new InvalidOperationException(
        $"No compatible version of '{type}'. Last error: {last?.Message}");
}

// 例：V21 定位轴
var to = CreateWithVersionProbe(
    plcSoftware.TechnologicalObjectGroup.TechnologicalObjects,
    "MCP_TO_Axis1", "TO_PositioningAxis",
    new[] { 12.0, 11.0, 10.0, 9.0, 8.0, 7.0, 6.0 });
```

其它类型（同步轴、外部编码器、凸轮等）用同样的候选集；成功创建后用
`to.OfSystemLibVersion`（若可读）或导出 XML 的 `<OfSystemLibVersion>` 记录实际版本。

## 5. 读写参数

```csharp
// 布尔
to.Parameters.Find("Actor.InverseDirection")!.Value = true;

// 启用硬件限位
to.Parameters.Find("PositionLimits_HW.Active")!.Value = true;

// 参数接受 PlcTag：先拿到标签对象
var tag = plcSoftware.TagTableGroup.TagTables
    .First(t => t.Name.ToLower().Contains("default"))
    .Tags.Find("Axis_MinSwitch");

to.Parameters.Find("_PositionLimits_HW.MinSwitchAddress")!.Value = tag;
```

规则：

- `Find(path)` 找不到返回 `null`；访问 `.Value` 前判空。
- 路径用点号分隔，数组用 `Sensor[1]` 形式；是否带前导下划线因参数而异。
- 值类型必须匹配（Bool / 数值 / `PlcTag` / 枚举），否则抛异常。
- 想拿到某个 TO 的真实参数清单：导出 XML 看 `<Parameter Name=...>`，比反射枚举更可靠。

## 6. 连接驱动硬件（轴 ↔ 驱动）

**反模式**：`to.Parameters.Find("Actor.Type").Value = ...` 不抛异常，但**不会**建立硬件连接。

### 6.1 Startdrive 工程（官方片段做法，最简）

```csharp
var driveObject = s120.DriveAxes()
    .First(x => x.Name == "BlueAxis")
    .AsDriveObjectContainer()
    .DriveObject();

var to = plcSoftware.TechnologicalObjectGroup
    .AllTechnologicalInstanceDBs()
    .Single(x => x.Name == "PositioningAxis_blue");

driveObject.ConnectToTechnologyObject(to);   // Startdrive 扩展方法
```

注意：`DriveAxes()` / `AsDriveObjectContainer()` / `AllTechnologicalInstanceDBs()` /
`ConnectToTechnologyObject()` 都来自 Siemens 示例的**扩展方法库**，不是 Openness 核心 API。
没有该扩展库时用 6.2。

### 6.2 通用做法（Openness 服务）

```csharp
var provider = to.GetService<AxisHardwareConnectionProvider>();
var actor = provider.ActorInterface;          // 轴/编码器硬件连接接口

// 报文地址：从驱动侧 telegram 的 Address 集合取，按方向过滤
var io = telegram.Addresses;
var inAddr  = io.First(a => a.IoType == AddressIoType.Input);
var outAddr = io.First(a => a.IoType == AddressIoType.Output);

actor.Connect(inAddr.StartAddress, outAddr.StartAddress, ConnectOption.Default);

if (!actor.IsConnected)
    throw new InvalidOperationException("Connect() 未抛异常，但 IsConnected=false。");
```

必须现场复核（不同 SDK/版本成员名和地址单位可能不同）：

- `Address.IoType` 在部分版本是 `GetAttribute("IoType")`；先反射确认。
- `Connect` 的地址单位是**字节**还是**位**，因 SDK 版本而异；不要照抄 `×8`，
  用 `GetAttribute("StartAddress")` 的实际值 + 回读 `InputAddress/OutputAddress` 验证。
- `Connect` 不抛异常 ≠ 成功；一律回读 `IsConnected` 和地址。

## 7. 从全局库 MasterCopy 放置 TO

```csharp
// ContentType == "TechnologicalInstanceDB"
var toGroup = GetOrCreateToGroup(plcSoftware.TechnologicalObjectGroup, new[] { "Motion" });
toGroup.TechnologicalObjects.CreateFrom(masterCopy, MasterCopyMode.ThrowIfExists);
```

- TO 的 MasterCopy 必须路由到 `TechnologicalObjectGroup.TechnologicalObjects.CreateFrom`，
  不能走 `BlockGroup.Blocks.CreateFrom`。
- `TO_CamTrack`、`TO_OutputCam`、`TO_MeasuringInput` 等类型**不支持**从项目库/全局库复制，
  只能新建或 XML 导入。

## 8. 编译与保存

```csharp
var compiler = plcSoftware.GetService<Compiler>();
var result = compiler.Compile();          // 检查 result.ErrorCount == 0
project.Save();
```

## 9. 异常与排查

| 异常/现象 | 原因 | 处理 |
|---|---|---|
| `EngineeringTargetInvocationException` + "does not exist or is not a valid technology object" | type/version 不在本机库 | 降序探测；确认 CPU 固件与 Startdrive |
| `Create` 返回 `null` | 版本/类型无效或未加载库 | 换候选版本；检查项目是否含对应轴工艺包 |
| `Parameters.Find(...)` 返回 `null` | 参数路径不存在 | 用导出 XML 的真实参数名；区分 `_` 前缀 |
| `.Value` 赋值抛类型异常 | 值类型不匹配 | 按参数类型转换（Bool/数值/PlcTag） |
| `Connect()` 无异常但驱动不动 | 只写了 `Actor.*` 参数 | 用 `AxisHardwareConnectionProvider` 并检查 `IsConnected` |
| TO 无法放入 SW-Unit | API 限制 | 放 PLC 根 `TechnologicalObjectGroup` |
| 编译报接口错误 | 手改了 Interface / 跨版本模板 | 用同版本模板重做，只改 Name/Number/Parameter |

## 10. 与 MCP 的分工

- MCP 已提供：列出、导出、导入（含 Override）。
- MCP 未提供：`Create`、参数读写、删除、硬件连接。
- 因此：**能用模板导入完成的，走 MCP**；需要从零建、批量改参数、连驱动的，写一个
  引用 Openness 的小程序（或扩展 TiaMcpServer 的 TO 工具）。
