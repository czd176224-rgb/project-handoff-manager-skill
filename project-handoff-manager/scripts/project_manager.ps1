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
    [string]$ValidationResult,
    [switch]$ConfirmStop,
    [object]$DriveInfo,
    [string]$TargetPath,
    [switch]$ConfirmTransfer,
    [switch]$ConfirmProcessStop,
    [switch]$AllowSensitiveFiles,
    [switch]$ConfirmCleanup
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

if ($Action -eq 'pause') {
    if (-not $ProjectPath) {
        throw "操作 'pause' 必须提供 -ProjectPath。"
    }
    $result = Suspend-PHMProject -ProjectPath $ProjectPath -ComputerName $ComputerName -ConfirmStop:$ConfirmStop
    [pscustomobject]@{
        safeMode             = $true
        executed             = [bool]$result.Executed
        requiresConfirmation = [bool](-not $result.Executed)
        action               = 'pause'
        message              = if ($result.Executed) { '项目已暂停；已更新交接信息。T9 未使用，文件未删除。' } else { '这是执行预览；确认清单后使用 -ConfirmStop 执行。' }
        result               = $result
    } | ConvertTo-Json -Depth 12
    exit 0
}

if ($Action -eq 'checkin') {
    if (-not $ProjectPath) { throw "操作 'checkin' 必须提供 -ProjectPath。" }
    if ($ConfirmCleanup) {
        if (-not $TargetPath) { throw "完成归还清理必须提供 -TargetPath。" }
        $cleanup = Complete-PHMCheckinCleanup -SourcePath $ProjectPath -TargetPath $TargetPath -ConfirmCleanup
        [pscustomobject]@{
            safeMode=$true; executed=[bool]$cleanup.Executed; action='checkin-cleanup'
            message=if($cleanup.Executed){'本机来源已清理，T9 是唯一正式完整副本。'}else{'未清理来源；请查看阻断原因。'}
            result=$cleanup
        } | ConvertTo-Json -Depth 12
        exit 0
    }

    $loadedConfig = if ($ConfigPath) { Read-PHMConfig -Path $ConfigPath } else { $null }
    if (-not $PortableRepositoryRoot -and $loadedConfig) { $PortableRepositoryRoot = $loadedConfig.PortableRepositoryRoot }
    if (-not $PortableRepositoryRoot) { throw "操作 'checkin' 必须提供 -PortableRepositoryRoot 或包含该路径的 -ConfigPath。" }
    $portableConfig = if ($loadedConfig) { $loadedConfig.Raw.portableDrive } else { $null }
    $expectedLetter = if ($portableConfig -and $portableConfig.driveLetter) { [string]$portableConfig.driveLetter } else { 'T:' }
    $expectedLabel = if ($portableConfig -and $portableConfig.volumeLabel) { [string]$portableConfig.volumeLabel } else { 'T9' }
    $expectedFileSystem = if ($portableConfig -and $portableConfig.requiredFileSystem) { [string]$portableConfig.requiredFileSystem } else { 'NTFS' }
    $expectedFriendlyName = if ($portableConfig -and $portableConfig.friendlyName) { [string]$portableConfig.friendlyName } else { 'Samsung PSSD T9' }
    $expectedVolumeSerial = if ($portableConfig -and $portableConfig.volumeSerial) { [string]$portableConfig.volumeSerial } else { $null }
    $expectedDeviceId = if ($portableConfig -and $portableConfig.deviceId) { [string]$portableConfig.deviceId } else { $null }
    $markerPath = if ($portableConfig -and $portableConfig.deviceMarkerPath) { [string]$portableConfig.deviceMarkerPath } else { Join-Path $PortableRepositoryRoot '..\管理资料\项目管家设备.json' }
    if (-not $DriveInfo) { $DriveInfo = Get-PHMPortableDriveInfo -DriveLetter $expectedLetter -DeviceMarkerPath $markerPath }

    $result = Invoke-PHMCheckin -ProjectPath $ProjectPath -PortableRepositoryRoot $PortableRepositoryRoot -DriveInfo $DriveInfo -ConfirmTransfer:$ConfirmTransfer -ConfirmProcessStop:$ConfirmProcessStop -AllowSensitiveFiles:$AllowSensitiveFiles -ComputerName $ComputerName -ExpectedVolumeSerial $expectedVolumeSerial -ExpectedDeviceId $expectedDeviceId
    [pscustomobject]@{
        safeMode=$true; executed=[bool]$result.Executed; requiresConfirmation=[bool](-not $ConfirmTransfer); action='checkin'
        message=if($result.Executed){'目标已经校验并提交；本机来源仍保留，需单独确认清理。'}else{'尚未完成归还；请查看预览、确认项或失败阶段。'}
        result=$result
    } | ConvertTo-Json -Depth 15
    exit 0
}

[pscustomobject]@{
    safeMode = $true
    executed = $false
    action   = $Action
    message  = "操作 '$Action' 尚未实现；未修改任何文件。"
} | ConvertTo-Json -Depth 5
