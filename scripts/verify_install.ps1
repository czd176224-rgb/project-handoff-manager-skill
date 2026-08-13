[CmdletBinding()]
param(
    [string]$DestinationRoot,
    [string]$SkillPath,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-DefaultSkillRoot {
    if ($env:CODEX_HOME) { return (Join-Path $env:CODEX_HOME 'skills') }
    if (-not $env:USERPROFILE) { throw '无法确定当前 Codex 用户目录；请显式提供 -DestinationRoot 或 -SkillPath。' }
    return (Join-Path (Join-Path $env:USERPROFILE '.codex') 'skills')
}

function Test-Utf8Bom {
    param([Parameter(Mandatory)][string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    return ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
}

try {
    if (-not $SkillPath) {
        if (-not $DestinationRoot) { $DestinationRoot = Get-DefaultSkillRoot }
        $SkillPath = Join-Path $DestinationRoot 'project-handoff-manager'
    }
    $SkillPath = (Get-Item -LiteralPath $SkillPath -ErrorAction Stop).FullName
    $allowedFiles = @(
        'SKILL.md', 'agents\openai.yaml', 'scripts\project_manager.ps1',
        'scripts\ProjectManager.Core.psm1', 'assets\schema\registry.schema.json',
        'assets\schema\project-identity.schema.json', 'assets\schema\environment.schema.json',
        'assets\standard-project\离线依赖\.gitkeep', 'assets\standard-project\输入资料\.gitkeep',
        'assets\standard-project\输出成果\.gitkeep', 'assets\standard-project\项目缓存\.gitkeep',
        'assets\standard-project\项目交接\环境清单.json', 'assets\standard-project\项目交接\项目交接报告.md'
    )
    foreach ($relative in $allowedFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $SkillPath $relative) -PathType Leaf)) {
            throw "缺少必需文件：$relative"
        }
    }
    $actualFiles = @(Get-ChildItem -LiteralPath $SkillPath -Recurse -File -Force | ForEach-Object {
        $_.FullName.Substring($SkillPath.TrimEnd('\').Length).TrimStart('\')
    })
    $unexpected = @(Compare-Object -ReferenceObject $allowedFiles -DifferenceObject $actualFiles | Where-Object SideIndicator -eq '=>')
    if ($unexpected) { throw "发现不属于公开 Skill 的额外文件：$($unexpected[0].InputObject)" }
    $allowedDirectories = @(
        'agents', 'assets', 'assets\schema', 'assets\standard-project',
        'assets\standard-project\离线依赖', 'assets\standard-project\输入资料',
        'assets\standard-project\输出成果', 'assets\standard-project\项目缓存',
        'assets\standard-project\项目交接', 'scripts'
    )
    $actualDirectories = @(Get-ChildItem -LiteralPath $SkillPath -Recurse -Directory -Force | ForEach-Object {
        $_.FullName.Substring($SkillPath.TrimEnd('\').Length).TrimStart('\')
    })
    $unexpectedDirectory = @(Compare-Object -ReferenceObject $allowedDirectories -DifferenceObject $actualDirectories | Where-Object SideIndicator -eq '=>')
    if ($unexpectedDirectory) { throw "发现不属于公开 Skill 的额外目录：$($unexpectedDirectory[0].InputObject)" }

    $allItems = @((Get-Item -LiteralPath $SkillPath -Force)) + @(Get-ChildItem -LiteralPath $SkillPath -Recurse -Force)
    $reparsePoint = $allItems | Where-Object {
        [bool]($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
    } | Select-Object -First 1
    if ($reparsePoint) { throw "Skill 包含重解析点：$($reparsePoint.FullName)" }

    $forbiddenNames = '(?i)(^|[\\/])(\.git|tests|\.superpowers)([\\/]|$)|(^|[\\/])(local\.config\.json|项目管家设备信任\.json|项目管家设备\.json|[^\\/]*\.secrets\.json|credentials[^\\/]*\.json)$'
    foreach ($relative in $actualFiles) {
        if ($relative -match $forbiddenNames) { throw "Skill 包含仓库或本机私有文件：$relative" }
    }

    $privacyPatterns = @(
        'C:\\Users\\[A-Za-z0-9._-]+',
        '(?i)(gho|ghp|github_pat)_[A-Za-z0-9_]+',
        '(?i)(api[_-]?key|access[_-]?token|client[_-]?secret|password)\s*[:=]\s*["'']?(?!test|example|dummy|simulated)[^\s"'']{8,}',
        'BEGIN (RSA|OPENSSH|EC) PRIVATE KEY'
    )
    foreach ($pattern in $privacyPatterns) {
        $match = Select-String -LiteralPath @($actualFiles | ForEach-Object { Join-Path $SkillPath $_ }) -Pattern $pattern -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($match) { throw "Skill 内容命中隐私或凭据模式：$($match.Path) 第 $($match.LineNumber) 行" }
    }

    $skillContent = Get-Content -LiteralPath (Join-Path $SkillPath 'SKILL.md') -Raw
    $frontmatter = [regex]::Match($skillContent, '\A---\r?\n(?<body>.*?)\r?\n---', 'Singleline')
    if (-not $frontmatter.Success -or
        $frontmatter.Groups['body'].Value -notmatch '(?m)^name:\s*project-handoff-manager\s*$' -or
        $frontmatter.Groups['body'].Value -notmatch '(?m)^description:\s*.+$') {
        throw 'SKILL.md frontmatter 无效。'
    }

    $entryPath = Join-Path $SkillPath 'scripts\project_manager.ps1'
    $modulePath = Join-Path $SkillPath 'scripts\ProjectManager.Core.psm1'
    foreach ($scriptPath in @($entryPath, $modulePath)) {
        if (-not (Test-Utf8Bom -Path $scriptPath)) { throw "脚本不是 UTF-8 BOM：$scriptPath" }
    }

    $module = Import-Module $modulePath -Force -PassThru
    $version = Get-PHMVersion
    if ($version.Version -ne '1.0.0') { throw "版本错误：期望 1.0.0，实际 $($version.Version)" }
    $expectedMenu = @('开始或继续当前项目','暂停当前项目','将当前项目归还到 T9','从 T9 借出项目到本机')
    $menu = @(Get-PHMMenu)
    if ($menu.Count -ne 4 -or (Compare-Object -ReferenceObject $expectedMenu -DifferenceObject @($menu.Name))) {
        throw '四项中文菜单不完整或顺序错误。'
    }
    Remove-Module $module.Name -Force

    $hostExe = (Get-Process -Id $PID).Path
    $entryOutput = & $hostExe -NoProfile -NonInteractive -File $entryPath -Action menu 2>&1
    if ($LASTEXITCODE -ne 0) { throw "入口执行失败，退出码：$LASTEXITCODE" }
    $entry = ($entryOutput | Out-String) | ConvertFrom-Json -ErrorAction Stop
    if ($entry.operations.Count -ne 4 -or -not $entry.safeMode) { throw '入口菜单结果无效。' }

    if (-not $Quiet) {
        Write-Host "安装验证通过：project-handoff-manager 1.0.0"
        Write-Host "Skill 路径：$SkillPath"
        Write-Host '目录、无污染、隐私扫描、UTF-8 BOM、模块导入、四项菜单和入口执行均正常。'
    }
    [pscustomobject]@{ Valid=$true; Version='1.0.0'; SkillPath=$SkillPath; MenuCount=4 }
}
catch {
    throw "安装验证失败：$($_.Exception.Message)"
}
