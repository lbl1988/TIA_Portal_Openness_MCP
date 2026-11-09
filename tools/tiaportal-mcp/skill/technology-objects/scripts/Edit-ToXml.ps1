#requires -Version 5.1
<#
.SYNOPSIS
    编辑 TIA Portal 工艺对象（TO）导出 XML：改名、改编号、读/写参数、克隆、导入前自检。
.DESCRIPTION
    只做本地 XML 变换，不连接 TIA。生成的 XML 为 UTF-8 with BOM，供 TiaMcpServer 的
    ImportTechnologyObject / ImportTechnologyObjectsFromDirectory 使用。
.PARAMETER Path
    源 TO XML 路径（ExportTechnologyObject 导出所得）。
.PARAMETER Action
    List | Get | Set | Rename | Clone | Validate
.PARAMETER Parameter
    Action=Get/Set 时的参数名，必须与导出 XML 中的 Name 完全一致。
.PARAMETER Value
    Action=Set 时写入的字符串值（Bool 用 True/False，实数用小数点）。
.PARAMETER NewName
    Action=Rename/Clone 时的新对象名。
.PARAMETER NewNumber
    Action=Rename/Clone 时的新对象编号（可选，>=0 生效）。
.PARAMETER OutFile
    输出路径；缺省时：Rename/Set 原地保存，Clone 保存为同目录\NewName.xml。
.EXAMPLE
    .\Edit-ToXml.ps1 -Action List -Path .\Axis_1.xml
.EXAMPLE
    .\Edit-ToXml.ps1 -Action Clone -Path .\Axis_1.xml -OutFile .\Axis_2.xml -NewName Axis_2 -NewNumber 2
.EXAMPLE
    .\Edit-ToXml.ps1 -Action Set -Path .\Axis_2.xml -Parameter "_Actor.DriveParameter.MaxSpeed" -Value "3000.0"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Path,

    [Parameter(Mandatory = $true)]
    [ValidateSet('List', 'Get', 'Set', 'Rename', 'Clone', 'Validate')]
    [string]$Action,

    [string]$Parameter,
    [string]$Value,
    [string]$NewName,
    [int]$NewNumber = -1,
    [string]$OutFile
)

$ErrorActionPreference = 'Stop'

# ── 基础工具 ───────────────────────────────────────────────────────────────

function Get-FullPath([string]$p) {
    return [System.IO.Path]::GetFullPath($p)
}

function Load-ToXml([string]$p) {
    $full = Get-FullPath $p
    if (-not (Test-Path -LiteralPath $full)) {
        throw "文件不存在: $full"
    }
    $doc = New-Object System.Xml.XmlDocument
    $doc.PreserveWhitespace = $true
    $doc.Load($full)
    return @{ Doc = $doc; FullPath = $full }
}

function Get-ToNode([System.Xml.XmlDocument]$doc) {
    # 根节点固定为 SW.TechnologicalObjects.TechnologicalInstanceDB（local-name 含点号）
    $node = $doc.SelectSingleNode("//*[local-name()='SW.TechnologicalObjects.TechnologicalInstanceDB']")
    if ($null -eq $node) {
        throw "不是工艺对象 XML：缺少 SW.TechnologicalObjects.TechnologicalInstanceDB 节点。"
    }
    return $node
}

function Get-AttrList([System.Xml.XmlNode]$toNode) {
    $al = Get-ChildElement $toNode 'AttributeList'
    if ($null -eq $al) {
        throw "TO XML 缺少 AttributeList。"
    }
    return $al
}

function Get-ChildElement([System.Xml.XmlNode]$parent, [string]$localName) {
    if ($null -eq $parent) { return $null }
    foreach ($c in $parent.ChildNodes) {
        if ($c.NodeType -eq [System.Xml.XmlNodeType]::Element -and $c.LocalName -eq $localName) {
            return $c
        }
    }
    return $null
}

function Add-ChildBefore([System.Xml.XmlNode]$parent, [System.Xml.XmlElement]$newChild, [string]$beforeLocalName) {
    $before = Get-ChildElement $parent $beforeLocalName
    if ($null -ne $before) {
        [void]$parent.InsertBefore($newChild, $before)
    }
    else {
        [void]$parent.AppendChild($newChild)
    }
}

function Get-ParametersNode([System.Xml.XmlNode]$toNode, [bool]$create) {
    $al = Get-AttrList $toNode
    $pd = Get-ChildElement $al 'ParameterData'
    if ($null -eq $pd) {
        if (-not $create) { return $null }
        $pd = $al.OwnerDocument.CreateElement('ParameterData')
        Add-ChildBefore $al $pd 'ProgrammingLanguage'
    }
    $ps = Get-ChildElement $pd 'Parameters'
    if ($null -eq $ps) {
        if (-not $create) { return $null }
        $ps = $al.OwnerDocument.CreateElement('Parameters')
        [void]$pd.AppendChild($ps)
    }
    return $ps
}

function Find-Parameter([System.Xml.XmlNode]$paramsNode, [string]$name) {
    if ($null -eq $paramsNode) { return $null }
    foreach ($c in $paramsNode.ChildNodes) {
        if ($c.NodeType -eq [System.Xml.XmlNodeType]::Element -and
            $c.LocalName -eq 'Parameter' -and
            $c.GetAttribute('Name') -eq $name) {
            return $c
        }
    }
    return $null
}

function Set-Identity([System.Xml.XmlNode]$toNode, [string]$name, [int]$number) {
    if ([string]::IsNullOrWhiteSpace($name)) {
        throw "NewName 不能为空。"
    }
    $al = Get-AttrList $toNode
    $nameNode = Get-ChildElement $al 'Name'
    if ($null -eq $nameNode) {
        throw "TO XML 缺少 AttributeList/Name，不能改名。"
    }
    $nameNode.InnerText = $name

    if ($number -ge 0) {
        $numNode = Get-ChildElement $al 'Number'
        if ($null -eq $numNode) {
            $numNode = $al.OwnerDocument.CreateElement('Number')
            Add-ChildBefore $al $numNode 'OfSystemLibElement'
        }
        $numNode.InnerText = [string]$number
    }
}

function Save-ToXml([System.Xml.XmlDocument]$doc, [string]$p) {
    $full = Get-FullPath $p
    $dir = [System.IO.Path]::GetDirectoryName($full)
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        [void](New-Item -ItemType Directory -Force -Path $dir)
    }
    # TIA 期望 UTF-8 with BOM；保留原空白格式
    $settings = New-Object System.Xml.XmlWriterSettings
    $settings.Encoding = New-Object System.Text.UTF8Encoding($true)
    $settings.Indent = $false
    $settings.NewLineHandling = [System.Xml.NewLineHandling]::None
    $writer = [System.Xml.XmlWriter]::Create($full, $settings)
    try {
        $doc.Save($writer)
    }
    finally {
        $writer.Dispose()
    }
    return $full
}

function Get-TargetPath([string]$action, [string]$sourceFull, [string]$outFile, [string]$newName) {
    if (-not [string]::IsNullOrWhiteSpace($outFile)) {
        return (Get-FullPath $outFile)
    }
    if ($action -eq 'Clone') {
        if ([string]::IsNullOrWhiteSpace($newName)) {
            throw "Action=Clone 需要 -NewName（或显式 -OutFile）。"
        }
        return (Join-Path ([System.IO.Path]::GetDirectoryName($sourceFull)) ($newName + '.xml'))
    }
    return $sourceFull
}

function Show-ToSummary([System.Xml.XmlNode]$toNode) {
    $al = Get-AttrList $toNode
    foreach ($field in @('Name', 'Number', 'OfSystemLibElement', 'OfSystemLibVersion', 'ProgrammingLanguage')) {
        $n = Get-ChildElement $al $field
        $v = if ($null -ne $n) { $n.InnerText } else { '(absent)' }
        Write-Output ("{0,-22}{1}" -f ($field + ':'), $v)
    }
    $ps = Get-ParametersNode $toNode $false
    if ($null -eq $ps) {
        Write-Output "Parameters:            (none; all defaults)"
        return
    }
    $count = 0
    foreach ($p in $ps.ChildNodes) {
        if ($p.NodeType -eq [System.Xml.XmlNodeType]::Element -and $p.LocalName -eq 'Parameter') { $count++ }
    }
    Write-Output ("Parameters:            {0}" -f $count)
}

function Test-ToXml([System.Xml.XmlDocument]$doc, [string]$fullPath) {
    $errors = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]

    $toNode = $null
    try { $toNode = Get-ToNode $doc }
    catch { $errors.Add($_.Exception.Message) }

    if ($null -ne $toNode) {
        $al = Get-ChildElement $toNode 'AttributeList'
        if ($null -eq $al) {
            $errors.Add("缺少 AttributeList。")
        }
        else {
            $name = Get-ChildElement $al 'Name'
            if ($null -eq $name -or [string]::IsNullOrWhiteSpace($name.InnerText)) {
                $errors.Add("AttributeList/Name 为空。")
            }
            $num = Get-ChildElement $al 'Number'
            if ($null -eq $num) {
                $warnings.Add("缺少 Number；导入时可能由 TIA 自动分配。")
            }
            elseif ($num.InnerText -notmatch '^\d+$') {
                $errors.Add("Number 不是非负整数: '$($num.InnerText)'。")
            }
            foreach ($field in @('OfSystemLibElement', 'OfSystemLibVersion')) {
                $n = Get-ChildElement $al $field
                if ($null -eq $n -or [string]::IsNullOrWhiteSpace($n.InnerText)) {
                    $errors.Add("缺少 $field。")
                }
            }
            $iface = Get-ChildElement $al 'Interface'
            if ($null -eq $iface) { $errors.Add("缺少 Interface。") }
            $pl = Get-ChildElement $al 'ProgrammingLanguage'
            if ($null -eq $pl) { $errors.Add("缺少 ProgrammingLanguage。") }
            elseif ($pl.InnerText -ne 'Motion_DB') {
                $warnings.Add("ProgrammingLanguage 预期为 Motion_DB，实际 '$($pl.InnerText)'。")
            }

            $ps = Get-ParametersNode $toNode $false
            if ($null -eq $ps) {
                $warnings.Add("没有 ParameterData/Parameters（全部使用默认值）。")
            }
            else {
                $seen = @{}
                foreach ($p in $ps.ChildNodes) {
                    if ($p.NodeType -ne [System.Xml.XmlNodeType]::Element -or $p.LocalName -ne 'Parameter') { continue }
                    $pn = $p.GetAttribute('Name')
                    if ([string]::IsNullOrWhiteSpace($pn)) {
                        $errors.Add("存在 Name 为空的 Parameter。")
                    }
                    elseif ($seen.ContainsKey($pn)) {
                        $errors.Add("参数重复: $pn")
                    }
                    else {
                        $seen[$pn] = $true
                    }
                }
            }

            $vref = 0
            foreach ($m in $doc.SelectNodes("//*[local-name()='Member'][@Datatype='VREF']")) { $vref++ }
            if ($vref -gt 0) {
                $warnings.Add("含 $vref 个 VREF 硬件地址引用；跨工程/换 CPU 后需重新绑定，不要手改。")
            }
        }
    }

    $bytes = [System.IO.File]::ReadAllBytes($fullPath)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    if (-not $hasBom) {
        $warnings.Add("文件无 UTF-8 BOM；中文标题/变量名可能乱码。")
    }

    foreach ($w in $warnings) { Write-Output ("WARN  " + $w) }
    foreach ($e in $errors) { Write-Output ("FAIL  " + $e) }
    if ($errors.Count -eq 0) {
        Write-Output "PASS  结构自检通过（仍需 MCP 导入 + 回读 + 编译验证）。"
        return $true
    }
    return $false
}

# ── 主流程 ─────────────────────────────────────────────────────────────────

try {
    $loaded = Load-ToXml $Path
    $doc = $loaded.Doc
    $sourceFull = $loaded.FullPath
    $toNode = Get-ToNode $doc

    switch ($Action) {
        'List' {
            Write-Output "File: $sourceFull"
            Show-ToSummary $toNode
            $ps = Get-ParametersNode $toNode $false
            if ($null -ne $ps) {
                Write-Output ''
                Write-Output 'Parameters:'
                foreach ($p in $ps.ChildNodes) {
                    if ($p.NodeType -eq [System.Xml.XmlNodeType]::Element -and $p.LocalName -eq 'Parameter') {
                        Write-Output ("  {0} = {1}" -f $p.GetAttribute('Name'), $p.GetAttribute('Value'))
                    }
                }
            }
            exit 0
        }

        'Get' {
            if (-not $PSBoundParameters.ContainsKey('Parameter')) { throw "Action=Get 需要 -Parameter。" }
            $ps = Get-ParametersNode $toNode $false
            $p = Find-Parameter $ps $Parameter
            if ($null -eq $p) {
                Write-Output "NOT FOUND: $Parameter"
                exit 1
            }
            Write-Output $p.GetAttribute('Value')
            exit 0
        }

        'Set' {
            if (-not $PSBoundParameters.ContainsKey('Parameter')) { throw "Action=Set 需要 -Parameter。" }
            if (-not $PSBoundParameters.ContainsKey('Value')) { throw "Action=Set 需要 -Value。" }
            $ps = Get-ParametersNode $toNode $true
            $p = Find-Parameter $ps $Parameter
            $created = $false
            if ($null -eq $p) {
                $p = $ps.OwnerDocument.CreateElement('Parameter')
                [void]$p.SetAttribute('Name', $Parameter)
                [void]$ps.AppendChild($p)
                $created = $true
            }
            [void]$p.SetAttribute('Value', $Value)
            $target = Get-TargetPath 'Set' $sourceFull $OutFile $NewName
            $saved = Save-ToXml $doc $target
            $verb = if ($created) { 'added' } else { 'updated' }
            Write-Output ("$verb $Parameter = $Value -> $saved")
            exit 0
        }

        'Rename' {
            if (-not $PSBoundParameters.ContainsKey('NewName')) { throw "Action=Rename 需要 -NewName。" }
            Set-Identity $toNode $NewName $NewNumber
            $target = Get-TargetPath 'Rename' $sourceFull $OutFile $NewName
            $saved = Save-ToXml $doc $target
            Write-Output ("renamed -> $NewName (Number=$NewNumber) -> $saved")
            exit 0
        }

        'Clone' {
            if (-not $PSBoundParameters.ContainsKey('NewName')) { throw "Action=Clone 需要 -NewName。" }
            Set-Identity $toNode $NewName $NewNumber
            $target = Get-TargetPath 'Clone' $sourceFull $OutFile $NewName
            $saved = Save-ToXml $doc $target
            Write-Output ("cloned -> $NewName (Number=$NewNumber) -> $saved")
            exit 0
        }

        'Validate' {
            Write-Output "File: $sourceFull"
            Show-ToSummary $toNode
            Write-Output ''
            $ok = Test-ToXml $doc $sourceFull
            exit ($(if ($ok) { 0 } else { 1 }))
        }
    }
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 2
}
