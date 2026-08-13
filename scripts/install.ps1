[CmdletBinding()]
param(
    [string]$DestinationRoot,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$skillName = 'project-handoff-manager'
$repositoryRoot = Split-Path $PSScriptRoot -Parent
$sourceSkillPath = Join-Path $repositoryRoot $skillName
$installVerifierPath = Join-Path $PSScriptRoot 'verify_install.ps1'

function Get-DefaultSkillRoot {
    if ($env:CODEX_HOME) {
        return (Join-Path $env:CODEX_HOME 'skills')
    }
    if (-not $env:USERPROFILE) {
        throw '无法确定当前 Codex 用户目录；请显式提供 -DestinationRoot。'
    }
    return (Join-Path (Join-Path $env:USERPROFILE '.codex') 'skills')
}

function Test-PathWithin {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Parent)
    $candidate = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    $parentFull = [System.IO.Path]::GetFullPath($Parent).TrimEnd('\')
    return $candidate.Equals($parentFull, [System.StringComparison]::OrdinalIgnoreCase) -or
        $candidate.StartsWith($parentFull + '\', [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-PathChainSafe {
    param([Parameter(Mandatory)][string]$Path)
    $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    $root = [System.IO.Path]::GetPathRoot($fullPath).TrimEnd('\')
    $current = $root
    foreach ($segment in @($fullPath.Substring($root.Length).TrimStart('\') -split '\\' | Where-Object { $_ })) {
        $current = Join-Path $current $segment
        if (-not (Test-Path -LiteralPath $current)) { continue }
        $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if ([bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { return $false }
    }
    return $true
}

function Assert-VerifiedSkill {
    param([Parameter(Mandatory)][string]$Path)
    $result = @(& $installVerifierPath -SkillPath $Path -Quiet)[-1]
    if (-not $result -or -not $result.Valid) { throw "Skill 完整发布验证失败：$Path" }
}

function Get-DirectoryFileMap {
    param([Parameter(Mandatory)][string]$Path)

    $root = (Get-Item -LiteralPath $Path).FullName.TrimEnd('\')
    $map = @{}
    foreach ($file in @(Get-ChildItem -LiteralPath $root -Recurse -File -Force | Sort-Object FullName)) {
        $relative = $file.FullName.Substring($root.Length).TrimStart('\').Replace('\', '/')
        $map[$relative] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    }
    return $map
}

function Test-DirectoriesEqual {
    param(
        [Parameter(Mandatory)][string]$Left,
        [Parameter(Mandatory)][string]$Right
    )

    $leftMap = Get-DirectoryFileMap -Path $Left
    $rightMap = Get-DirectoryFileMap -Path $Right
    if ($leftMap.Count -ne $rightMap.Count) { return $false }
    foreach ($key in $leftMap.Keys) {
        if (-not $rightMap.ContainsKey($key) -or $leftMap[$key] -ne $rightMap[$key]) { return $false }
    }
    return $true
}

Assert-VerifiedSkill -Path $sourceSkillPath
if (-not $DestinationRoot) { $DestinationRoot = Get-DefaultSkillRoot }
$DestinationRoot = [System.IO.Path]::GetFullPath($DestinationRoot).TrimEnd('\')
foreach ($protected in @($repositoryRoot, $sourceSkillPath)) {
    if ((Test-PathWithin -Path $DestinationRoot -Parent $protected) -or (Test-PathWithin -Path $protected -Parent $DestinationRoot)) {
        throw "安装目标与发布仓库或源 Skill 路径重叠：$DestinationRoot"
    }
}
if (-not (Test-PathChainSafe -Path $DestinationRoot)) { throw "安装目标路径链包含重解析点：$DestinationRoot" }
New-Item -ItemType Directory -Path $DestinationRoot -Force | Out-Null
$destinationPath = Join-Path (Get-Item -LiteralPath $DestinationRoot).FullName $skillName

if (Test-Path -LiteralPath $destinationPath) {
    if (-not (Test-PathChainSafe -Path $destinationPath)) {
        throw "现有目标 Skill 本身或完整路径链包含重解析点，禁止比较、备份或替换：$destinationPath"
    }
    if (-not (Test-Path -LiteralPath $destinationPath -PathType Container)) {
        throw "现有目标不是 Skill 目录，禁止覆盖：$destinationPath"
    }
    if (Test-DirectoriesEqual -Left $sourceSkillPath -Right $destinationPath) {
        Write-Host "已安装：$destinationPath"
        return [pscustomobject]@{ Status='AlreadyInstalled'; DestinationPath=$destinationPath; BackupPath=$null }
    }
    if (-not $Force) {
        throw "目标 Skill 已存在且内容不同。请检查差异，或显式使用 -Force 安全升级：$destinationPath"
    }
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmssfff'
$backupPath = $null
$stagingPath = Join-Path $DestinationRoot ".$skillName.staging-$([guid]::NewGuid().ToString('N'))"
$rollbackPath = Join-Path $DestinationRoot ".$skillName.rollback-$([guid]::NewGuid().ToString('N'))"

try {
    if (Test-Path -LiteralPath $destinationPath -PathType Container) {
        $backupPath = Join-Path $DestinationRoot "$skillName.backup-$timestamp"
        Copy-Item -LiteralPath $destinationPath -Destination $backupPath -Recurse -Force
        if (-not (Test-DirectoriesEqual -Left $destinationPath -Right $backupPath)) {
            throw '现有 Skill 备份校验失败，已停止升级。'
        }
    }

    Copy-Item -LiteralPath $sourceSkillPath -Destination $stagingPath -Recurse -Force
    Assert-VerifiedSkill -Path $stagingPath
    if (-not (Test-DirectoriesEqual -Left $sourceSkillPath -Right $stagingPath)) {
        throw '暂存 Skill 与发布源不一致，已停止安装。'
    }

    if (Test-Path -LiteralPath $destinationPath -PathType Container) {
        Move-Item -LiteralPath $destinationPath -Destination $rollbackPath
    }
    try {
        Move-Item -LiteralPath $stagingPath -Destination $destinationPath
        Assert-VerifiedSkill -Path $destinationPath
    }
    catch {
        if (Test-Path -LiteralPath $rollbackPath -PathType Container) {
            Move-Item -LiteralPath $rollbackPath -Destination $destinationPath
        }
        throw
    }
    if (Test-Path -LiteralPath $rollbackPath -PathType Container) {
        Remove-Item -LiteralPath $rollbackPath -Recurse -Force
    }

    $status = if ($backupPath) { 'Upgraded' } else { 'Installed' }
    Write-Host "安装验证通过：$destinationPath"
    if ($backupPath) { Write-Host "原版本可从备份恢复：$backupPath" }
    [pscustomobject]@{ Status=$status; DestinationPath=$destinationPath; BackupPath=$backupPath }
}
finally {
    if (Test-Path -LiteralPath $stagingPath) { Remove-Item -LiteralPath $stagingPath -Recurse -Force }
}
