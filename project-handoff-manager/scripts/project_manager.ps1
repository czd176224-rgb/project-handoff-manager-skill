[CmdletBinding()]
param(
    [ValidateSet('menu', 'inspect', 'adopt', 'resume', 'checkpoint', 'pause', 'checkin', 'checkout', 'repair')]
    [string]$Action = 'menu'
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

[pscustomobject]@{
    safeMode = $true
    executed = $false
    action   = $Action
    message  = "操作 '$Action' 尚未实现；未修改任何文件。"
} | ConvertTo-Json -Depth 5
