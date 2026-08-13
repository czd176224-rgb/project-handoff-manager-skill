[CmdletBinding()]
param(
    [ValidateSet('menu', 'inspect', 'adopt', 'resume', 'checkpoint', 'pause', 'checkin', 'checkout', 'repair')]
    [string]$Action = 'menu',
    [string]$ConfigPath,
    [string]$ProjectPath,
    [string]$CurrentProjectPath,
    [string[]]$LocalRoots = @(),
    [string]$LocalCurrentRoot,
    [string]$LocalReceivingRoot,
    [Nullable[long]]$LocalFreeBytes,
    [string]$PortableRepositoryRoot,
    [string]$LocalTrustPath,
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
    if (-not $LocalTrustPath -and $portableConfig -and $portableConfig.localTrustPath) { $LocalTrustPath = [string]$portableConfig.localTrustPath }
    if ((-not $expectedVolumeSerial -or -not $expectedDeviceId) -and $LocalTrustPath -and (Test-Path -LiteralPath $LocalTrustPath -PathType Leaf)) {
        $trust = Get-Content -LiteralPath $LocalTrustPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if (-not $expectedVolumeSerial) { $expectedVolumeSerial = [string]$trust.volume_serial }
        if (-not $expectedDeviceId) { $expectedDeviceId = [string]$trust.device_id }
    }
    $markerPath = if ($portableConfig -and $portableConfig.deviceMarkerPath) { [string]$portableConfig.deviceMarkerPath } else { Join-Path $PortableRepositoryRoot '..\管理资料\项目管家设备.json' }
    if (-not $DriveInfo) { $DriveInfo = Get-PHMPortableDriveInfo -DriveLetter $expectedLetter -DeviceMarkerPath $markerPath }

    if ($ConfirmCleanup) {
        if (-not $TargetPath) { throw "完成归还清理必须提供 -TargetPath。" }
        if (-not $expectedVolumeSerial -or -not $expectedDeviceId) { throw '完成归还清理缺少本机 T9 设备信任记录。' }
        $cleanup = Complete-PHMCheckinCleanup -SourcePath $ProjectPath -TargetPath $TargetPath -PortableRepositoryRoot $PortableRepositoryRoot -DriveInfo $DriveInfo -ConfirmCleanup -ExpectedDriveLetter $expectedLetter -ExpectedVolumeLabel $expectedLabel -ExpectedFileSystem $expectedFileSystem -ExpectedFriendlyName $expectedFriendlyName -ExpectedVolumeSerial $expectedVolumeSerial -ExpectedDeviceId $expectedDeviceId
        [pscustomobject]@{
            safeMode=$true; executed=[bool]$cleanup.Executed; action='checkin-cleanup'
            message=if($cleanup.Executed){'本机来源已清理，T9 是唯一正式完整副本。'}else{'未清理来源；请查看阻断原因。'}
            result=$cleanup
        } | ConvertTo-Json -Depth 12
        exit 0
    }

    $result = Invoke-PHMCheckin -ProjectPath $ProjectPath -PortableRepositoryRoot $PortableRepositoryRoot -DriveInfo $DriveInfo -ConfirmTransfer:$ConfirmTransfer -ConfirmProcessStop:$ConfirmProcessStop -AllowSensitiveFiles:$AllowSensitiveFiles -ComputerName $ComputerName -ExpectedDriveLetter $expectedLetter -ExpectedVolumeLabel $expectedLabel -ExpectedFileSystem $expectedFileSystem -ExpectedFriendlyName $expectedFriendlyName -ExpectedVolumeSerial $expectedVolumeSerial -ExpectedDeviceId $expectedDeviceId
    [pscustomobject]@{
        safeMode=$true; executed=[bool]$result.Executed; requiresConfirmation=[bool](-not $ConfirmTransfer); action='checkin'
        message=if($result.Executed){'目标已经校验并提交；本机来源仍保留，需单独确认清理。'}else{'尚未完成归还；请查看预览、确认项或失败阶段。'}
        result=$result
    } | ConvertTo-Json -Depth 15
    exit 0
}

if ($Action -eq 'repair') {
    if (-not $TargetPath) { throw "操作 'repair' 必须提供 -TargetPath（本机正式项目目录）。" }
    $loadedConfig = if ($ConfigPath) { Read-PHMConfig -Path $ConfigPath } else { $null }
    if (-not $PortableRepositoryRoot -and $loadedConfig) { $PortableRepositoryRoot = $loadedConfig.PortableRepositoryRoot }
    if (-not $PortableRepositoryRoot) { throw "操作 'repair' 必须提供 -PortableRepositoryRoot 或包含该路径的 -ConfigPath。" }
    $portableConfig = if ($loadedConfig) { $loadedConfig.Raw.portableDrive } else { $null }
    $expectedLetter = if ($portableConfig -and $portableConfig.driveLetter) { [string]$portableConfig.driveLetter } else { 'T:' }
    $expectedLabel = if ($portableConfig -and $portableConfig.volumeLabel) { [string]$portableConfig.volumeLabel } else { 'T9' }
    $expectedFileSystem = if ($portableConfig -and $portableConfig.requiredFileSystem) { [string]$portableConfig.requiredFileSystem } else { 'NTFS' }
    $expectedFriendlyName = if ($portableConfig -and $portableConfig.friendlyName) { [string]$portableConfig.friendlyName } else { 'Samsung PSSD T9' }
    $expectedVolumeSerial = if ($portableConfig -and $portableConfig.volumeSerial) { [string]$portableConfig.volumeSerial } else { $null }
    $expectedDeviceId = if ($portableConfig -and $portableConfig.deviceId) { [string]$portableConfig.deviceId } else { $null }
    if (-not $LocalTrustPath -and $portableConfig -and $portableConfig.localTrustPath) { $LocalTrustPath = [string]$portableConfig.localTrustPath }
    if ((-not $expectedVolumeSerial -or -not $expectedDeviceId) -and $LocalTrustPath -and (Test-Path -LiteralPath $LocalTrustPath -PathType Leaf)) {
        $trust = Get-Content -LiteralPath $LocalTrustPath -Raw | ConvertFrom-Json
        if (-not $expectedVolumeSerial) { $expectedVolumeSerial = [string]$trust.volume_serial }
        if (-not $expectedDeviceId) { $expectedDeviceId = [string]$trust.device_id }
    }
    if (-not $expectedVolumeSerial -or -not $expectedDeviceId) { throw '操作 repair 缺少本机 T9 设备信任记录。' }
    $markerPath = if ($portableConfig -and $portableConfig.deviceMarkerPath) { [string]$portableConfig.deviceMarkerPath } else { Join-Path $PortableRepositoryRoot '..\管理资料\项目管家设备.json' }
    if (-not $DriveInfo) { $DriveInfo = Get-PHMPortableDriveInfo -DriveLetter $expectedLetter -DeviceMarkerPath $markerPath }
    $finalizationMarker = Join-Path $TargetPath '项目交接\借出最终化恢复.json'
    $cleanupMarker = Join-Path $TargetPath '项目交接\借出清理恢复.json'
    if (Test-Path -LiteralPath $finalizationMarker -PathType Leaf) {
        $repairKind = 'checkout-finalization'
        $repairResult = Repair-PHMCheckoutFinalization -LocalTargetPath $TargetPath -PortableRepositoryRoot $PortableRepositoryRoot -DriveInfo $DriveInfo -ComputerName $ComputerName -ExpectedDriveLetter $expectedLetter -ExpectedVolumeLabel $expectedLabel -ExpectedFileSystem $expectedFileSystem -ExpectedFriendlyName $expectedFriendlyName -ExpectedVolumeSerial $expectedVolumeSerial -ExpectedDeviceId $expectedDeviceId
    }
    elseif (Test-Path -LiteralPath $cleanupMarker -PathType Leaf) {
        $repairKind = 'checkout-cleanup'
        $repairResult = Repair-PHMCheckoutCleanup -LocalTargetPath $TargetPath -PortableRepositoryRoot $PortableRepositoryRoot -DriveInfo $DriveInfo -ComputerName $ComputerName -ExpectedDriveLetter $expectedLetter -ExpectedVolumeLabel $expectedLabel -ExpectedFileSystem $expectedFileSystem -ExpectedFriendlyName $expectedFriendlyName -ExpectedVolumeSerial $expectedVolumeSerial -ExpectedDeviceId $expectedDeviceId
    }
    else { throw '本机项目中没有可恢复的借出最终化或借出清理记录。' }
    [pscustomobject]@{
        safeMode=$true; executed=[bool]$repairResult.Executed; action='repair'; repairKind=$repairKind
        message=if($repairKind -eq 'checkout-cleanup'){'借出清理恢复已完成；本机项目保持活动状态，T9 来源已清理并完成登记。'}else{'借出最终化恢复已完成；T9 来源仍保留，需按正常清理步骤单独确认。'}
        result=$repairResult
    } | ConvertTo-Json -Depth 20
    exit 0
}

if ($Action -eq 'checkout') {
    if (-not $ProjectPath) { throw "操作 'checkout' 必须提供 -ProjectPath。" }
    $loadedConfig = if ($ConfigPath) { Read-PHMConfig -Path $ConfigPath } else { $null }
    if (-not $PortableRepositoryRoot -and $loadedConfig) { $PortableRepositoryRoot = $loadedConfig.PortableRepositoryRoot }
    $portableConfig = if ($loadedConfig) { $loadedConfig.Raw.portableDrive } else { $null }
    $expectedLetter = if ($portableConfig -and $portableConfig.driveLetter) { [string]$portableConfig.driveLetter } else { 'T:' }
    $expectedLabel = if ($portableConfig -and $portableConfig.volumeLabel) { [string]$portableConfig.volumeLabel } else { 'T9' }
    $expectedFileSystem = if ($portableConfig -and $portableConfig.requiredFileSystem) { [string]$portableConfig.requiredFileSystem } else { 'NTFS' }
    $expectedFriendlyName = if ($portableConfig -and $portableConfig.friendlyName) { [string]$portableConfig.friendlyName } else { 'Samsung PSSD T9' }
    $expectedVolumeSerial = if ($portableConfig -and $portableConfig.volumeSerial) { [string]$portableConfig.volumeSerial } else { $null }
    $expectedDeviceId = if ($portableConfig -and $portableConfig.deviceId) { [string]$portableConfig.deviceId } else { $null }
    if (-not $LocalTrustPath -and $portableConfig -and $portableConfig.localTrustPath) { $LocalTrustPath = [string]$portableConfig.localTrustPath }
    if ((-not $expectedVolumeSerial -or -not $expectedDeviceId) -and $LocalTrustPath -and (Test-Path -LiteralPath $LocalTrustPath -PathType Leaf)) {
        $trust = Get-Content -LiteralPath $LocalTrustPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if (-not $expectedVolumeSerial) { $expectedVolumeSerial = [string]$trust.volume_serial }
        if (-not $expectedDeviceId) { $expectedDeviceId = [string]$trust.device_id }
    }

    if ($ConfirmCleanup) {
        if (-not $TargetPath) { throw "完成借出清理必须提供 -TargetPath。" }
        if (-not $PortableRepositoryRoot) { throw "完成借出清理必须提供 -PortableRepositoryRoot 或包含该路径的 -ConfigPath。" }
        $markerPath = if ($portableConfig -and $portableConfig.deviceMarkerPath) { [string]$portableConfig.deviceMarkerPath } else { Join-Path $PortableRepositoryRoot '..\管理资料\项目管家设备.json' }
        if (-not $DriveInfo) { $DriveInfo = Get-PHMPortableDriveInfo -DriveLetter $expectedLetter -DeviceMarkerPath $markerPath }
        $cleanup = Complete-PHMCheckoutCleanup -PortableSourcePath $ProjectPath -LocalTargetPath $TargetPath -PortableRepositoryRoot $PortableRepositoryRoot -DriveInfo $DriveInfo -ConfirmCleanup -ComputerName $ComputerName -ExpectedDriveLetter $expectedLetter -ExpectedVolumeLabel $expectedLabel -ExpectedFileSystem $expectedFileSystem -ExpectedFriendlyName $expectedFriendlyName -ExpectedVolumeSerial $expectedVolumeSerial -ExpectedDeviceId $expectedDeviceId
        [pscustomobject]@{
            safeMode=$true; executed=[bool]$cleanup.Executed; action='checkout-cleanup'
            message=if($cleanup.Executed){'T9 来源已清理，本机项目已转为当前活动项目。'}else{'未清理 T9 来源；双份均保留，请查看阻断原因。'}
            result=$cleanup
        } | ConvertTo-Json -Depth 15
        exit 0
    }

    if (-not $LocalCurrentRoot -and $loadedConfig) { $LocalCurrentRoot = $loadedConfig.LocalCurrentRoot }
    if (-not $LocalReceivingRoot -and $loadedConfig) { $LocalReceivingRoot = $loadedConfig.LocalReceivingRoot }
    if (-not $LocalCurrentRoot) { throw "操作 'checkout' 必须提供 -LocalCurrentRoot 或在配置中设置 local.currentProjectsRoot。" }
    if (-not $LocalReceivingRoot) { throw "操作 'checkout' 必须提供 -LocalReceivingRoot 或在配置中设置 local.receivingRoot。" }

    if (-not $PortableRepositoryRoot) { throw "操作 'checkout' 必须提供 -PortableRepositoryRoot 或包含该路径的 -ConfigPath。" }
    $markerPath = if ($portableConfig -and $portableConfig.deviceMarkerPath) { [string]$portableConfig.deviceMarkerPath } else { Join-Path $PortableRepositoryRoot '..\管理资料\项目管家设备.json' }
    if (-not $DriveInfo) { $DriveInfo = Get-PHMPortableDriveInfo -DriveLetter $expectedLetter -DeviceMarkerPath $markerPath }

    $checkoutParameters = @{
        PortableProjectPath=$ProjectPath; PortableRepositoryRoot=$PortableRepositoryRoot; LocalCurrentRoot=$LocalCurrentRoot; LocalReceivingRoot=$LocalReceivingRoot
        DriveInfo=$DriveInfo; ConfirmTransfer=$ConfirmTransfer; AllowSensitiveFiles=$AllowSensitiveFiles; ComputerName=$ComputerName
        ExpectedDriveLetter=$expectedLetter; ExpectedVolumeLabel=$expectedLabel
        ExpectedFileSystem=$expectedFileSystem; ExpectedFriendlyName=$expectedFriendlyName
        ExpectedVolumeSerial=$expectedVolumeSerial; ExpectedDeviceId=$expectedDeviceId
    }
    if ($PSBoundParameters.ContainsKey('LocalFreeBytes')) { $checkoutParameters.LocalFreeBytes = $LocalFreeBytes }
    $result = Invoke-PHMCheckout @checkoutParameters
    [pscustomobject]@{
        safeMode=$true; executed=[bool]$result.Executed; requiresConfirmation=[bool](-not $ConfirmTransfer); action='checkout'
        message=if($result.Executed){'本机目标已经校验并可继续；T9 来源仍保留，需单独确认清理。'}else{'尚未完成借出；请查看预览、阻断项或失败阶段。'}
        result=$result
    } | ConvertTo-Json -Depth 20
    exit 0
}

[pscustomobject]@{
    safeMode = $true
    executed = $false
    action   = $Action
    message  = "操作 '$Action' 尚未实现；未修改任何文件。"
} | ConvertTo-Json -Depth 5
