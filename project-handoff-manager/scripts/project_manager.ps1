[CmdletBinding()]
param(
    [ValidateSet('menu', 'inspect', 'adopt', 'resume', 'checkpoint', 'pause', 'checkin', 'checkout', 'repair')]
    [string]$Action = 'menu',
    [string]$ConfigPath,
    [string]$ProjectPath,
    [string]$CurrentProjectPath,
    [string[]]$LocalRoots = @(),
    [string]$PortableRepositoryRoot,
    [string]$ComputerName = $env:COMPUTERNAME,
    [string]$CurrentTask,
    [string]$NextStep,
    [string]$ValidationResult
)

$modulePath = Join-Path $PSScriptRoot 'ProjectManager.Core.psm1'
Import-Module $modulePath -Force

if ($Action -eq 'menu') {
    [pscustomobject]@{
        safeMode  = $true
        executed  = $false
        message   = '请选择操作。每项操作执行前都会显示具体内容和预期结果。'
        operations = @(Get-PHMMenu)
    } | ConvertTo-Json -Depth 5
    exit 0
}

if ($Action -eq 'inspect') {
    if ($ConfigPath) {
        $config = Read-PHMConfig -Path $ConfigPath
        $LocalRoots = @($config.LocalRoots)
        if (-not $PortableRepositoryRoot) {
            $PortableRepositoryRoot = $config.PortableRepositoryRoot
        }
    }
    $overview = Get-PHMProjectOverview -CurrentProjectPath $CurrentProjectPath -LocalRoots $LocalRoots -PortableRepositoryRoot $PortableRepositoryRoot
    [pscustomobject]@{
        safeMode = $true
        executed = $true
        action   = 'inspect'
        message  = '项目总览已刷新；只读取有限目录的直接子文件夹，没有迁移或删除文件。'
        overview = $overview
    } | ConvertTo-Json -Depth 10
    exit 0
}

if ($Action -in @('adopt', 'resume', 'checkpoint')) {
    if (-not $ProjectPath) {
        throw "操作 '$Action' 必须提供 -ProjectPath。"
    }

    $result = switch ($Action) {
        'adopt' { Initialize-PHMProject -ProjectPath $ProjectPath -ComputerName $ComputerName }
        'resume' { Resume-PHMProject -ProjectPath $ProjectPath -ComputerName $ComputerName }
        'checkpoint' { Save-PHMCheckpoint -ProjectPath $ProjectPath -ComputerName $ComputerName -CurrentTask $CurrentTask -NextStep $NextStep -ValidationResult $ValidationResult }
    }
    [pscustomobject]@{
        safeMode = $true
        executed = $true
        action   = $Action
        message  = '操作完成；项目仍在本机，未使用 T9，未删除文件。'
        result   = $result
    } | ConvertTo-Json -Depth 12
    exit 0
}

[pscustomobject]@{
    safeMode = $true
    executed = $false
    action   = $Action
    message  = "操作 '$Action' 尚未实现；未修改任何文件。"
} | ConvertTo-Json -Depth 5
