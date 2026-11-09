# TO XML 格式与安全编辑边界

MCP 导出的工艺对象是 SimaticML 的 `SW.TechnologicalObjects.TechnologicalInstanceDB`。
它同时包含**实例 DB 接口**和**工艺参数数据**；理解这两块才能安全编辑。

## 1. 整体骨架（以真实 V19 导出为参照，V21 仅版本号不同）

```xml
<?xml version="1.0" encoding="utf-8"?>
<Document>
  <Engineering version="V19" />                       <!-- 导出时的 TIA 版本 -->
  <SW.TechnologicalObjects.TechnologicalInstanceDB ID="0">
    <AttributeList>
      <!-- ① 库头信息（由系统生成，与实例身份无关，不要改） -->
      <HeaderAuthor>SIMATIC</HeaderAuthor>
      <HeaderFamily>BasicMC</HeaderFamily>
      <HeaderName>TO_PosAx</HeaderName>
      <HeaderVersion>7.0</HeaderVersion>
      <!-- 实际类型名（与 OfSystemLibElement 对应，不要改） -->
      <InstanceOfName>TO_PositioningAxis</InstanceOfName>

      <!-- ② 实例接口（类型继承链 + 成员；不要改） -->
      <Interface>
        <Sections xmlns="http://www.siemens.com/automation/Openness/SW/Interface/v5">
          <Section Name="Base">
            <Sections Datatype="TO_SpeedAxis" Version="6.0">
              <Section Name="Base">
                <Sections Datatype="TO_Axis" Version="5.0">
                  ...
                </Sections>
              </Section>
              <Section Name="Input" /> <Section Name="Output" />
              <Section Name="InOut" /> <Section Name="Static" />
            </Sections>
          </Section>
          ...  Position / Velocity / Actor / Sensor / DynamicLimits /
               PositionLimits_SW / PositionLimits_HW / FollowingError ...
        </Sections>
      </Interface>

      <!-- ③ 对象身份（改名/克隆只动这里） -->
      <Name>Axis_1</Name>                             <!-- TO 名称；导入以此为准 -->
      <Namespace />                                   <!-- 通常为空 -->
      <Number>1</Number>                              <!-- 对象编号，PLC 内唯一 -->
      <OfSystemLibElement>TO_PositioningAxis</OfSystemLibElement>
      <OfSystemLibVersion>7.0</OfSystemLibVersion>     <!-- 本机库版本，不能乱改 -->

      <!-- ④ 工艺参数（键值对，编辑重点） -->
      <ParameterData>
        <Parameters>
          <Parameter Name="_Sensor[1].ActiveHoming.DigitalInput" Value="Axis_1_Homing switch" />
          <Parameter Name="_Sensor[1].DataAdaptionOffline" Value="True" />
          <Parameter Name="_Actor.DataAdaptionOffline" Value="True" />
          <Parameter Name="_Sensor[1].Interface.EncoderConnection" Value="7" />
        </Parameters>
      </ParameterData>

      <ProgrammingLanguage>Motion_DB</ProgrammingLanguage>
    </AttributeList>

    <!-- ⑤ 标题/注释（多语言文本） -->
    <ObjectList>
      <MultilingualText ID="1" CompositionName="Comment">
        <ObjectList>
          <MultilingualTextItem ID="2" CompositionName="Items">
            <AttributeList><Culture>en-US</Culture><Text /></AttributeList>
          </MultilingualTextItem>
        </ObjectList>
      </MultilingualText>
      <MultilingualText ID="3" CompositionName="Title"> ... </MultilingualText>
    </ObjectList>
  </SW.TechnologicalObjects.TechnologicalInstanceDB>
</Document>
```

要点：

- 根节点固定为 `SW.TechnologicalObjects.TechnologicalInstanceDB`（含点号的完整 local-name），没有别的合法根。
- `AttributeList` 的真实顺序是：`Header*` → `InstanceOfName` → `Interface` → `Name` → `Namespace`
  → `Number` → `OfSystemLibElement` → `OfSystemLibVersion` → `ParameterData` → `ProgrammingLanguage`。
  脚本按 local-name 查找，不依赖顺序；TIA 也不强求顺序，但保持原顺序更稳。
- `Interface` 的嵌套 `Sections` 编码**类型继承链**。例如定位轴：
  `TO_PositioningAxis → TO_SpeedAxis → TO_Axis → TO_AnyMotionObject`。
  每一个 `Version` 都来自安装库，不能凭记忆写。
- `ParameterData` 只包含“与默认值不同”的参数；没出现的参数使用默认值。
- 文件编码：真实导出是 **UTF-8 with BOM**。保持 BOM，避免中文标题/变量名乱码。

## 2. 字段编辑权限

| 字段/区块 | 可改 | 说明 |
|---|---|---|
| `Document/Engineering@version` | 不建议 | 导出环境记录；跨版本导入时保持原值更稳 |
| `AttributeList/Header*` | ❌ | 系统生成的库头（Author/Family/Name/Version） |
| `AttributeList/InstanceOfName` | ❌ | 实际类型名，必须与 `OfSystemLibElement` 一致 |
| `AttributeList/Name` | ✅ | 克隆/改名唯一入口 |
| `AttributeList/Number` | ✅ | 必须唯一；不填会由 TIA 分配，但批量克隆建议显式指定 |
| `AttributeList/OfSystemLibElement` | ❌ | 改它等于伪造类型；必须整份换模板 |
| `AttributeList/OfSystemLibVersion` | ❌ | 本机库版本；跨版本需重新导出模板 |
| `AttributeList/ProgrammingLanguage` | ❌ | TO 固定 `Motion_DB` |
| `Interface` 整段 | ❌ | 手改会破坏接口/类型一致性 |
| `Interface/.../VREF`（AddressIn/AddressOut） | ❌ | 硬件地址引用，跨工程不可移植 |
| `ParameterData/Parameters/Parameter` | ✅ | 增/改参数值；名字必须与导出文件里的一致 |
| `ObjectList` 的 Title/Comment 文本 | ✅ | 支持多语言；中文写在此处 |
| `ID` 属性 | ❌ | 内部对象 ID |

## 3. 参数命名与取值

- 同一个参数在 API 和 XML 中可能不同名。真实导出里常见带下划线的内部名：
  `_Actor.*`、`_Sensor[1].*`、`_PositionLimits_HW.*`、`_Units.*`；
  而 Openness `Parameters.Find` 常用不带下划线的 `Actor.*`、`PositionLimits_HW.*`。
  **以实际导出文件为准**，不要猜测。
- 取值规则：

| 参数类型 | XML `Value` 写法 | 示例 |
|---|---|---|
| Bool | `True` / `False`（首字母大写） | `Value="True"` |
| 整数/枚举 | 十进制数字 | `Value="106"` |
| 实数 | 小数点，invariant culture | `Value="3000.0"` |
| 标签引用 | 符号名（不是 `%M0.0`） | `Value="Axis_1_Homing switch"` |
| 文本 | 原文；XML 特殊字符转义 | `Value="A &amp; B"` |

- 新增参数：在 `<Parameters>` 下追加
  `<Parameter Name="..." Value="..." />`；同名已存在时改 `Value` 即可。
- 删除参数：直接移除该 `<Parameter>` 节点，即回到默认值。

## 4. 克隆（新建同类型 TO）的正确姿势

1. 导出目标类型的一个现成 TO（最好就是目标 PLC、目标 TIA 版本）。
2. 复制文件 → 改 `Name`、`Number`。
3. 按需改 `ParameterData` 参数。
4. （可选）改 Title/Comment 文本。
5. `Validate` → 导入 → `GetTechnologyObjects` 回读 → 编译。

**不要**通过改 `OfSystemLibElement` 把定位轴变成同步轴；类型继承链与接口成员都不同，
必然导入/编译失败。

## 5. 导入前自检清单（脚本 `Validate` 已覆盖大部分）

- [ ] XML 可解析，根节点是 `SW.TechnologicalObjects.TechnologicalInstanceDB`
- [ ] `Name` 非空、与目标工程现有 TO 不冲突（或确认要 Override）
- [ ] `Number` 是整数且唯一
- [ ] `OfSystemLibElement` / `OfSystemLibVersion` 与模板一致
- [ ] `Interface` 未被改动（可用原始模板做 diff）
- [ ] 所有 `Parameter` 的 `Name` 能在同类型模板中找到（新参数需确认拼写）
- [ ] 文件 UTF-8 BOM
- [ ] 目标 `softwarePath` 是 PLC 根，不是 SW-Unit
- [ ] 导入后 `GetTechnologyObjects` 能看到该对象，`CompileAndDiagnosePlc` 为 0 错

## 6. 版本兼容

- TIA 官方说明：各版本 Openness 库可导入受支持的旧版 SimaticML。V19 导出通常能进 V21。
- 但 `OfSystemLibVersion` 与 `VREF`/报文相关字段仍可能与目标工程不匹配。
- 生产环境一律**从目标工程导出模板**；跨版本只用于试验，并在编译后重新绑定硬件。
