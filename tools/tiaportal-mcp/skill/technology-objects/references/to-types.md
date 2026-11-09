# 常用 TO 类型与参数

> 类型名（`OfSystemLibElement` / `Create` 的 `type`）区分大小写。
> 可用性取决于 **CPU 型号/固件 + TIA 版本 + 是否安装 Startdrive**；
> 若 `Create` 报 "does not exist or is not a valid technology object"，先查版本（见
> [openness-api.md](openness-api.md) §4），再确认该 CPU 是否支持此类工艺对象。

## 1. 类型目录

| 类型 | 用途 | 典型硬件前提 | 备注 |
|---|---|---|---|
| `TO_SpeedAxis` | 速度轴：只给速度/使能，不做位置闭环 | S7-1500 / S7-1200（视固件） | 定位轴的基础父类型 |
| `TO_PositioningAxis` | 定位轴：相对/绝对定位、回零、软/硬限位 | 驱动器/编码器；V21 版本 `10.0` 已验证 | 最常用 |
| `TO_SynchronousAxis` | 同步轴：电子齿轮、凸轮同步 | 通常 S7-1500(T) + 驱动 | 比定位轴多同步接口 |
| `TO_ExternalEncoder` | 外部编码器：把编码器作为测量轴 | 编码器接入 | 常与同步/测量配合 |
| `TO_MeasuringInput` | 测量输入 / 探针：高速锁存位置 | 支持 DI 探针的 CPU | 不支持从库复制 |
| `TO_OutputCam` | 输出凸轮：位置区间输出 | S7-1500/1200（视固件） | 不支持从库复制 |
| `TO_Cam` | 凸轮：位置/时间凸轮盘 | 同步轴配套 |  |
| `TO_CamTrack` | 凸轮轨道：多凸轮组合 | S7-1500T 类 | 不支持从库复制 |
| `TO_CommandTable` | 命令表：开环/简单定位（S7-1200 常见） | S7-1200 PTO | 与定位轴二选一 |
| `TO_Kinematics` | 运动学：机器人/多轴插补 | S7-1500T | 版本/许可要求高 |

**基础/内部类型，不要直接创建**：`TO_Axis`、`TO_AnyMotionObject`、`TO_Object`。
它们只出现在 XML 的 `Interface` 继承链里。

## 2. 选型建议

```
只控转速、不需要位置闭环        → TO_SpeedAxis
点位/相对绝对定位、回零、限位    → TO_PositioningAxis
电子齿轮 / 凸轮同步             → TO_SynchronousAxis (+ TO_Cam / TO_CamTrack)
开环步进、PTO、简单顺序定位      → TO_CommandTable
编码器当测量轴                  → TO_ExternalEncoder
高速探针/锁存                   → TO_MeasuringInput
位置区间高速输出                → TO_OutputCam
多轴插补/机器人                 → TO_Kinematics（S7-1500T）
```

## 3. 已验证参数名

以下来自 Siemens 官方代码片段与真实工程导出。**不同版本/类型会有差异**，
使用前用导出的 XML 或 `Parameters.Find` 实际确认。

| API 路径（`Parameters.Find`） | XML 参数名（导出所见） | 类型 | 说明 |
|---|---|---|---|
| `Actor.InverseDirection` | 以导出为准 | Bool | 方向取反（官方片段） |
| `PositionLimits_HW.Active` | `PositionLimits_HW.Active` | Bool | 启用硬件限位（官方片段） |
| `_PositionLimits_HW.MinSwitchAddress` | `_PositionLimits_HW.MinSwitchAddress` | PlcTag | 最小限位开关（真实导出） |
| `_PositionLimits_HW.MaxSwitchAddress` | `_PositionLimits_HW.MaxSwitchAddress` | PlcTag | 最大限位开关（真实导出） |
| `_Actor.Interface.Telegram` | `_Actor.Interface.Telegram` | 枚举(数字) | 驱动报文，真实导出为 `106` |
| `_Sensor[1].Interface.Telegram` | `_Sensor[1].Interface.Telegram` | 枚举(数字) | 编码器报文，真实导出为 `106` |
| `_Sensor[1].ActiveHoming.DigitalInput` | `_Sensor[1].ActiveHoming.DigitalInput` | PlcTag | 回零开关（真实导出） |
| `_Actor.DataAdaptionOffline` | `_Actor.DataAdaptionOffline` | Bool | 离线数据适配（真实导出） |
| `_Units.VelocityUnit` | `_Units.VelocityUnit` | 枚举(数字) | 速度单位（真实导出为 `1524`） |
| `Sensor[2].Existent` | `Sensor[2].Existent` | Bool | 是否启用第 2 个传感器（真实导出） |

说明：

- 带 `_` 前缀的多为内部/系统参数；是否可写取决于 TO 类型与版本。
- 驱动侧参数（如 `Actor.DriveParameter.MaxSpeed`）随 Startdrive/报文配置变化，
  **不要照抄**；只能从你自己的导出 XML 确认。
- `ParameterData` 只列“非默认值”；要恢复默认，删掉对应 `<Parameter>`。
- `VREF`（`AddressIn` / `AddressOut`）不要手改；换工程后必须重新做硬件连接。

## 4. 常见 TO 参数分组（用于定位参数位置）

| 分组 | 典型内容 |
|---|---|
| `Actor` | 驱动侧：报文、方向、最大速度、数据适配 |
| `Sensor[n]` | 编码器侧：报文、编码器类型、回零、安装方向 |
| `DynamicLimits` | 加速度、减速度、急停减速 |
| `PositionLimits_SW` | 软件限位：启用、上下限、停止方式 |
| `PositionLimits_HW` | 硬件限位：启用、开关点 |
| `FollowingError` | 跟随误差监控：启用、阈值、响应 |
| `Units` | 位置/速度单位、模态量换算 |
| `Homing` / `ActiveHoming` | 回零模式、开关、零位偏移 |
| `StatusBits` / `ErrorBits` | 状态/错误位（多为只读） |

## 5. 版本速查（只作起点，必须探测）

| TIA | 类型 | 可用版本（已知） |
|---|---|---|
| V21 | `TO_PositioningAxis` | `10.0` ✅；`1.0`–`9.0`、`11.0`、`12.0` ❌ |
| V19 | `TO_PositioningAxis` | 导出样本为 `7.0` |
| 通用 | `TO_SynchronousAxis` | 导出样本为 `8.0`（V19） |

样本版本不代表你的机器可用。总是用降序候选探测（`12.0 → 6.0`）。
