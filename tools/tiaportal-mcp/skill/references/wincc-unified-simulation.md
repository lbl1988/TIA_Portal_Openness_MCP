# WinCC Unified ↔ S7-PLCSIM 仿真通讯排障

适用：Unified Comfort Panel 仿真、WinCC Unified PC Runtime（`https://<计算机名>/WebRH`）
对接 S7-PLCSIM（经典，版本必须与 TIA 一致）或 PLCSIM Advanced。

## 1. 症状与第一判断

| 症状 | 第一判断 |
|---|---|
| HMI 所有数值显示 0.00，按钮点了没反应 | 通讯链路断，不是变量绑定错 |
| 数值 0 但 PLC 里初始值非 0（如 `Cfg_MaterialSpeed=100.0`） | 同上；若绑定正确，停机时也应显示初始值 |
| 画面上的"运行"绿灯亮 | **不能**作为通讯判据——那多半是静态文字/静态图形 |

## 2. 自下而上的诊断链（按顺序，任一步失败就停）

### 2.1 进程是否存在

```powershell
Get-Process S7PLCSIMV21,VplcHost64 -ErrorAction SilentlyContinue
Get-Process | Where-Object { $_.ProcessName -match 'Siemens|TIA|plcsim' }
```

没有 `S7PLCSIMV21` / `VplcHost64` → 仿真器根本没起，后面全部免谈。
注意：`Siemens.Simatic.Simulation.Runtime.Manager.exe` 是 **PLCSIM Advanced**，与经典 PLCSIM 是两套东西。

### 2.2 虚拟网卡是否就绪

```powershell
Get-NetIPAddress -AddressFamily IPv4 | Select InterfaceAlias,IPAddress,PrefixLength,AddressState
Get-NetAdapter | Select Name,InterfaceDescription,Status,LinkSpeed
Get-NetAdapterBinding -InterfaceAlias '以太网 2' | Select ComponentID,Enabled
```

期望：`Siemens PLCSIM Virtual Ethernet Adapter`，`Status=Up`，
IP 与 PLC 同网段（例：PLC `192.168.0.1`，网卡 `192.168.0.100/24`），
`plcsim_ndislwf`（S7-PLCSIM Advanced Virtual Switch）绑定为 `Enabled`。

### 2.3 ARP —— 决定性判据

```powershell
ping -n 2 -w 800 -S 192.168.0.100 192.168.0.1
arp -a -N 192.168.0.100
1..20 | ForEach-Object { $ip="192.168.0.$_"; if((ping -n 1 -w 300 -S 192.168.0.100 $ip) -match 'TTL='){"ALIVE: $ip"} }
```

| 现象 | 含义 |
|---|---|
| `Reply from 192.168.0.100: Destination host unreachable` | 本机发不出 ARP 回应 → 对端不存在 |
| `arp` 里该 IP 的 MAC 为 `00-00-00-00-00-00` / `Unreachable` | 同上，**二层就断了** |
| 整段扫描全无应答 | vPLC 没有挂到这张虚拟网卡 |

`Destination host unreachable` 来自本机源地址，说明**与 TCP 102、防火墙、许可证、路由都无关**。
（不带 `-S` 时若走默认路由跑到物理网卡，会出现 `TTL expired in transit` 来自网关的假象，别被误导——一定要带 `-S`。）

### 2.4 PG/PC 接口访问点（最常见的"隔天连不上"）

控制面板 → **设置 PG/PC 接口**：

- 应用程序访问点：`S7ONLINE`
- 接口：`Siemens PLCSIM Virtual Ethernet Adapter TCPIP.1`

**不能留 `Auto`，也不能指向物理网卡。** 重启后会自动跳回默认，这是"昨天能连、今天不能"的主因。
注意：该设置不是 ICMP/ARP 的前提，所以 ARP 失败**不能**归因于它；它只影响 S7 应用层握手。

### 2.5 HMI 工程侧（MCP 可全自动核对）

```
GetHmiProgramInfo(HMI_RT_1)                        → Unified / 画面清单
CompileAndDiagnoseHmi(HMI_RT_1)                    → 必须 errorCount=0
GetHmiTags(HMI_RT_1, "HMI_Tags")                   → 变量清单
GetObjectProperty(HmiTag,"HMI_RT_1:HMI_Tags:<tag>","Address|Connection|AccessMode|AcquisitionCycle")
GetObjectProperty(HmiScreenItem,"HMI_RT_1:<画面>:<控件>","Dynamizations")   → 期望 TagDynamization
ListObjectChildren(HmiScreenItem,"HMI_RT_1:<画面>:<按钮>","EventHandlers") → 期望 3 个
```

配套核对 PLC 侧：
- `GetBlockInfo(PLC_1, "<DB>")` → `memoryLayout=Standard` 才能用绝对地址
- `DumpDeviceAttributes(PLC_1, "putget")` → `ProtectionEnablePutGetCommunication=True`

## 3. 修复顺序

1. 打开 TIA 工程
2. 设置 PG/PC 接口 → `S7ONLINE` 绑 `Siemens PLCSIM Virtual Ethernet Adapter TCPIP.1`
3. 在线 → 仿真 → **启动仿真**（经典 PLCSIM 版本必须与 TIA 一致，用 `ProbeSimulationCapability` 预检）
4. 下载时**勾选硬件组态**（改过 IP 必须重下硬件，否则 vPLC 仍是旧地址）
5. 在 PLCSIM 窗口确认 CPU 显示的 IP 等于工程里配置的 IP
6. 回到 2.3 复测 ARP；通了再用 `ReadPlcLiveValuesS7("192.168.0.1","DB5.DBD4:REAL")` 验证数值
7. 最后启动 HMI 仿真，浏览器开 `https://<计算机名>/WebRH`

## 4. MCP 当前能力缺口（已实测，别再反复试）

| 想做的事 | 现状 |
|---|---|
| `ExportHmiScreen` / `ExportHmiConnection` / `ExportHmiTagTable` | 对 Unified **一律 `ExportFailed`** |
| `DescribeObject("Software","HMI_RT_1")` | 解析成 `Siemens.Engineering.SW.PlcSoftware`，HMI 的 `Connections` 集合不可反射 |
| 读按钮 `ScriptCode` 原文 | 读不出（`EventHandlers[0].scriptcode` 返回空） |
| 管理 PG/PC 接口访问点 | 无工具，只能 UI 操作 |
| 从 MCP 启动经典 PLCSIM | 做不到，必须 TIA UI 的「启动仿真」；`DownloadToPlc` 只能下载到已在运行的目标 |
| 预检 | `ProbeSimulationCapability`（经典/Advanced 区分）、`CheckDownloadReadiness` 可用 |

排查 HMI 程序是否健康时，**以 `CompileAndDiagnoseHmi` 的 errorCount 为准**，不要依赖导出。
