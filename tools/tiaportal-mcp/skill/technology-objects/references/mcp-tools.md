# MCP 工艺对象工具参考（TiaMcpServer v2.2.8 / V20-V21）

前置条件：`Connect`（或自动 attach）+ 工程已打开；`softwarePath` 必须来自 `GetProjectTree`
（例如 `PLC_1`），不要自己猜。

## 工具清单

| 工具 | 作用 | 层 |
|---|---|---|
| `GetTechnologyObjects` | 列出 PLC 软件内全部 TO | L2 |
| `ExportTechnologyObject` | 导出单个 TO 为 XML | L2 |
| `ExportTechnologyObjectsToDirectory` | 批量导出 TO XML | L2 |
| `ImportTechnologyObject` | 导入单个 TO XML | L2 |
| `ImportTechnologyObjectsFromDirectory` | 批量导入 TO XML | L2 |

## 1. GetTechnologyObjects

```jsonc
// 入参
{ "softwarePath": "PLC_1" }

// 返回
{
  "ok": true,
  "softwarePath": "PLC_1",
  "count": 2,
  "items": [
    {
      "name": "Axis_1",
      "ofSystemLibElement": "TO_PositioningAxis",
      "ofSystemLibVersion": "10.0",
      "typeHint": null
    }
  ],
  "message": "2 technology object(s) found in 'PLC_1'."
}
```

- `ofSystemLibElement` / `ofSystemLibVersion` 可能为空；为空时用 `typeHint`（CLR 类型名）兜底。
- 这是导入后的**唯一**可信回读手段；每次导入/克隆后都要调用。

## 2. ExportTechnologyObject

```jsonc
// 入参
{
  "softwarePath": "PLC_1",
  "toName": "Axis_1",                    // 必须与 GetTechnologyObjects 返回完全一致
  "exportPath": "D:\\to_work\\Axis_1.xml" // 文件路径；目录不存在会自动创建
}

// 返回（ResponseMessage）
{
  "message": "Technology object 'Axis_1' exported to 'D:\\to_work\\Axis_1.xml'.",
  "meta": { "exportPath": "D:\\to_work\\Axis_1.xml", "toName": "Axis_1" }
}
```

- 同名文件会被先删除再写，安全。
- 导出的是完整 `TechnologicalInstanceDB` XML，可直接作为模板。

## 3. ExportTechnologyObjectsToDirectory

```jsonc
// 入参
{
  "softwarePath": "PLC_1",
  "exportDir": "D:\\to_work\\tpl",
  "regexName": "Axis_.*"     // 可选；空字符串 = 全部
}

// 返回（ResponseImportBatch）
{
  "imported": ["Axis_1", "Axis_2"],   // 这里实际是“已导出”的名称
  "failed": [ { "path": "Axis_3", "error": "..." } ]
}
```

- 每个 TO 保存为 `<TOName>.xml`。
- 注意返回字段名沿用 ImportBatch（`imported` 表示成功项，对导出而言是“已导出”）。

## 4. ImportTechnologyObject

```jsonc
// 入参
{
  "softwarePath": "PLC_1",
  "folderPath": "",                       // TO 子分组路径；"" = 根
  "importPath": "D:\\to_work\\Axis_2.xml"
}

// 返回（ResponseMessage）
{
  "message": "Technology object imported from 'D:\\to_work\\Axis_2.xml'",
  "meta": { "timestamp": "...", "success": true }
}
```

关键行为（源码 `Portal.Software.cs::TryImportEngineeringObjectIntoCollection`）：

- 优先调用集合的 `Import(FileInfo, ImportOptions)`，**固定传 `ImportOptions.Override`**；
  没有该重载才退回 `Import(FileInfo)`。
- 对象名取自 XML 的 `<Name>`，不是文件名。
- 失败会抛 `PortalException`，但整体被包装成 best-effort 工具；**不要以“没报错”作为成功依据**，
  必须 `GetTechnologyObjects` 回读。
- `folderPath` 指向 TO 子分组；TO 不能放进 SW-Unit。

## 5. ImportTechnologyObjectsFromDirectory

```jsonc
// 入参
{
  "softwarePath": "PLC_1",
  "folderPath": "",
  "dir": "D:\\to_work\\new",
  "regexName": "Axis_.*",   // 可选，对“文件名(不含扩展名)”匹配，忽略大小写
  "overwrite": true         // v2.2.8 源码中该参数被接受但未参与分支：始终 Override
}

// 返回（ResponseImportBatch）
{
  "imported": ["Axis_2", "Axis_3"],
  "failed": [ { "path": "D:\\to_work\\new\\bad.xml", "error": "..." } ]
}
```

- 只扫描目录**顶层**的 `*.xml`（`SearchOption.TopDirectoryOnly`），不递归。
- `regexName` 匹配的是**文件名（不含扩展名）**，不是 XML 内的 TO 名。
- `imported[]` 记录的是文件名，不是导入后的对象名；对象名看 XML `<Name>` 或回读。
- 单个失败不影响其余文件；逐个检查 `failed[]`。

## 6. 没有的能力（不要绕路）

| 需求 | 现状 | 替代 |
|---|---|---|
| 直接创建 TO | 无 `CreateTechnologyObject` | 路线 A 模板导入 / 路线 B `TechnologicalObjects.Create` |
| 读/写 TO 参数 | 无参数工具 | 导出 XML 改 `<Parameter>` / 路线 B `Parameters.Find` |
| 删除 TO | 无删除工具 | TIA UI 删除 / 自写 Openness |
| 连驱动硬件 | 无工具 | 路线 B `AxisHardwareConnectionProvider` |
| TO 放进 SW-Unit | Openness 不支持 | 放 PLC 根 `TechnologicalObjectGroup` |

## 7. 调用示例（MCP 客户端）

```
GetProjectTree
→ softwarePath = "PLC_1"
GetTechnologyObjects(softwarePath="PLC_1")
ExportTechnologyObject(softwarePath="PLC_1", toName="Axis_1", exportPath="D:\\to_work\\tpl.xml")
【本地：Edit-ToXml.ps1 Clone/Set/Validate】
ImportTechnologyObject(softwarePath="PLC_1", folderPath="", importPath="D:\\to_work\\new.xml")
GetTechnologyObjects(softwarePath="PLC_1")
CompileAndDiagnosePlc(softwarePath="PLC_1")
SaveProject
```
