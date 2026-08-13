Describe '借出与清理安全边界' {
    BeforeAll {
        $modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'project-handoff-manager\scripts\ProjectManager.Core.psm1'
        Import-Module $modulePath -Force
        $script:CheckoutTestDriveLetter = [System.IO.Path]::GetPathRoot($TestDrive).TrimEnd('\')
        foreach ($commandName in @('New-PHMCheckoutPlan','Invoke-PHMCheckout','Complete-PHMCheckoutCleanup','Repair-PHMCheckoutFinalization','Repair-PHMCheckoutCleanup')) {
            $PSDefaultParameterValues["${commandName}:ExpectedDriveLetter"] = $script:CheckoutTestDriveLetter
        }

        function New-SecureCheckoutDrive {
            param([string]$FileSystem = 'NTFS', [string]$FriendlyName = 'Samsung PSSD T9', [string]$DeviceId = 'test', [string]$DriveLetter = $script:CheckoutTestDriveLetter)
            [pscustomobject]@{
                DriveLetter=$DriveLetter; VolumeLabel='T9'; FileSystem=$FileSystem
                HealthStatus='Healthy'; OperationalStatus='OK'; IsReadOnly=$false; IsOffline=$false
                FreeBytes=100GB; FriendlyName=$FriendlyName; VolumeSerial='TEST'; DeviceId=$DeviceId
            }
        }

        function New-SecureCheckoutFixture {
            param([string]$Name, [switch]$Unmanaged)
            $repository = Join-Path $TestDrive "$Name-工作盘\项目仓库"
            $source = Join-Path $repository "暂停项目\$Name"
            New-Item -ItemType Directory -Path $source -Force | Out-Null
            if (-not $Unmanaged) { Initialize-PHMProject -ProjectPath $source -InitialState 'on_t9' | Out-Null }
            Set-Content -LiteralPath (Join-Path $source 'data.txt') -Value 'portable-data' -Encoding utf8
            [pscustomobject]@{
                Repository=$repository; Source=$source
                CurrentRoot=(Join-Path $TestDrive "$Name-当前")
                ReceivingRoot=(Join-Path $TestDrive "$Name-接收")
            }
        }
    }

    It '错误文件系统和设备型号都阻断借出' {
        $fixture = New-SecureCheckoutFixture -Name '错误设备'
        $plan = New-PHMCheckoutPlan -PortableProjectPath $fixture.Source -PortableRepositoryRoot $fixture.Repository -LocalCurrentRoot $fixture.CurrentRoot -LocalReceivingRoot $fixture.ReceivingRoot -DriveInfo (New-SecureCheckoutDrive -FileSystem 'exFAT' -FriendlyName 'Other Disk') -LocalFreeBytes 100GB -ExpectedVolumeSerial TEST -ExpectedDeviceId test

        $plan.CanExecute | Should -BeFalse
        $plan.Blockers -join '；' | Should -Match '文件系统'
        $plan.Blockers -join '；' | Should -Match '设备型号'
    }

    It '未显式提供空间时自动查询并在空间不足时阻断' {
        $fixture = New-SecureCheckoutFixture -Name '自动空间'
        $plan = New-PHMCheckoutPlan -PortableProjectPath $fixture.Source -PortableRepositoryRoot $fixture.Repository -LocalCurrentRoot $fixture.CurrentRoot -LocalReceivingRoot $fixture.ReceivingRoot -DriveInfo (New-SecureCheckoutDrive) -LocalFreeSpaceProvider { param($path) 0 } -ExpectedVolumeSerial TEST -ExpectedDeviceId test

        $plan.CanExecute | Should -BeFalse
        $plan.LocalFreeBytes | Should -Be 0
        $plan.LocalFreeSpaceEvidence | Should -Match '自动查询'
        $plan.Blockers -join '；' | Should -Match '本机空间不足'
    }

    It '本机空间查询失败时明确阻断而不是静默跳过' {
        $fixture = New-SecureCheckoutFixture -Name '空间查询失败'
        $plan = New-PHMCheckoutPlan -PortableProjectPath $fixture.Source -PortableRepositoryRoot $fixture.Repository -LocalCurrentRoot $fixture.CurrentRoot -LocalReceivingRoot $fixture.ReceivingRoot -DriveInfo (New-SecureCheckoutDrive) -LocalFreeSpaceProvider { param($path) throw 'cannot query' } -ExpectedVolumeSerial TEST -ExpectedDeviceId test

        $plan.CanExecute | Should -BeFalse
        $plan.LocalFreeBytes | Should -BeNullOrEmpty
        $plan.LocalFreeSpaceEvidence | Should -Match 'cannot query'
        $plan.Blockers -join '；' | Should -Match '无法查询本机可用空间'
    }

    It '敏感文件默认阻断且只有显式确认才放行' {
        $fixture = New-SecureCheckoutFixture -Name '敏感项目'
        Set-Content -LiteralPath (Join-Path $fixture.Source '.env') -Value 'TOKEN=secret' -Encoding utf8

        $blocked = New-PHMCheckoutPlan -PortableProjectPath $fixture.Source -PortableRepositoryRoot $fixture.Repository -LocalCurrentRoot $fixture.CurrentRoot -LocalReceivingRoot $fixture.ReceivingRoot -DriveInfo (New-SecureCheckoutDrive) -LocalFreeBytes 100GB -ExpectedVolumeSerial TEST -ExpectedDeviceId test
        $allowed = New-PHMCheckoutPlan -PortableProjectPath $fixture.Source -PortableRepositoryRoot $fixture.Repository -LocalCurrentRoot $fixture.CurrentRoot -LocalReceivingRoot $fixture.ReceivingRoot -DriveInfo (New-SecureCheckoutDrive) -LocalFreeBytes 100GB -ExpectedVolumeSerial TEST -ExpectedDeviceId test -AllowSensitiveFiles

        $blocked.CanExecute | Should -BeFalse
        $blocked.SensitiveFiles | Should -Contain '.env'
        $blocked.Blockers -join '；' | Should -Match '敏感文件'
        $allowed.CanExecute | Should -BeTrue
    }

    It '转移清单对项目缓存中的每一个大文件计算完整哈希' {
        $fixture = New-SecureCheckoutFixture -Name '完整哈希'
        $cache = Join-Path $fixture.Source '项目缓存'
        New-Item -ItemType Directory -Path $cache -Force | Out-Null
        1..25 | ForEach-Object { Set-Content -LiteralPath (Join-Path $cache ("large-{0:d2}.bin" -f $_)) -Value ('x' * 128) -Encoding ascii }

        $inventory = Get-PHMProjectInventory -ProjectPath $fixture.Source

        @($inventory.Files | Where-Object { -not $_.Hash }).Count | Should -Be 0
        @($inventory.Files | Where-Object { $_.HashPolicy -ne 'full' }).Count | Should -Be 0
    }

    It '未纳管旧项目复制失败时来源完全不被纳管或改写' {
        $fixture = New-SecureCheckoutFixture -Name '旧项目失败' -Unmanaged
        $before = @(Get-ChildItem -LiteralPath $fixture.Source -Recurse -Force | ForEach-Object FullName)
        $failure = { param($source,$destination) [pscustomobject]@{ Success=$false; ExitCode=8; Message='fail' } }

        $result = Invoke-PHMCheckout -PortableProjectPath $fixture.Source -PortableRepositoryRoot $fixture.Repository -LocalCurrentRoot $fixture.CurrentRoot -LocalReceivingRoot $fixture.ReceivingRoot -DriveInfo (New-SecureCheckoutDrive) -LocalFreeBytes 100GB -ExpectedVolumeSerial TEST -ExpectedDeviceId test -ConfirmTransfer -CopyAction $failure

        $result.Executed | Should -BeFalse
        $result.FailureStage | Should -Be 'copy'
        Test-Path -LiteralPath (Join-Path $fixture.Source '项目交接') | Should -BeFalse
        @(Get-ChildItem -LiteralPath $fixture.Source -Recurse -Force | ForEach-Object FullName) | Should -Be $before
    }

    It '同大小同时间的大文件内容变化也会使校验失败' {
        $fixture = New-SecureCheckoutFixture -Name '大文件篡改'
        $cache = Join-Path $fixture.Source '项目缓存'
        New-Item -ItemType Directory -Path $cache -Force | Out-Null
        $largePath = Join-Path $cache 'payload.bin'
        [System.IO.File]::WriteAllBytes($largePath, [byte[]](1..200))
        $copyAndCorrupt = {
            param($source,$destination)
            Copy-Item -LiteralPath $source -Destination $destination -Recurse -Force
            $sourceFile = Get-Item -LiteralPath (Join-Path $source '项目缓存\payload.bin')
            $targetFile = Join-Path $destination '项目缓存\payload.bin'
            [System.IO.File]::WriteAllBytes($targetFile, [byte[]](200..1))
            (Get-Item -LiteralPath $targetFile).LastWriteTimeUtc = $sourceFile.LastWriteTimeUtc
            [pscustomobject]@{ Success=$true; ExitCode=1; Message='copied then corrupted' }
        }

        $result = Invoke-PHMCheckout -PortableProjectPath $fixture.Source -PortableRepositoryRoot $fixture.Repository -LocalCurrentRoot $fixture.CurrentRoot -LocalReceivingRoot $fixture.ReceivingRoot -DriveInfo (New-SecureCheckoutDrive) -LocalFreeBytes 100GB -ExpectedVolumeSerial TEST -ExpectedDeviceId test -ConfirmTransfer -CopyAction $copyAndCorrupt

        $result.Executed | Should -BeFalse
        $result.FailureStage | Should -Be 'verification'
        $result.Verification.Differences -join '；' | Should -Match '哈希'
    }

    It 'promotion 后最终化失败时保留两份并返回明确可恢复状态' {
        $fixture = New-SecureCheckoutFixture -Name '最终化失败'
        $failure = { param($local,$portable) throw 'finalization failed' }

        $result = Invoke-PHMCheckout -PortableProjectPath $fixture.Source -PortableRepositoryRoot $fixture.Repository -LocalCurrentRoot $fixture.CurrentRoot -LocalReceivingRoot $fixture.ReceivingRoot -DriveInfo (New-SecureCheckoutDrive) -LocalFreeBytes 100GB -ExpectedVolumeSerial TEST -ExpectedDeviceId test -ConfirmTransfer -FinalizationAction $failure

        $result.Executed | Should -BeFalse
        $result.FailureStage | Should -Be 'finalization'
        $result.Recoverable | Should -BeTrue
        Test-Path -LiteralPath $fixture.Source | Should -BeTrue
        Test-Path -LiteralPath $result.OfficialPath | Should -BeTrue
    }

    It '只允许清理仓库暂停项目下的直接项目子目录' {
        $fixture = New-SecureCheckoutFixture -Name '任意路径'
        $outside = Join-Path $TestDrive 'outside'
        New-Item -ItemType Directory -Path $outside -Force | Out-Null

        $result = Complete-PHMCheckoutCleanup -PortableSourcePath $outside -LocalTargetPath $fixture.CurrentRoot -PortableRepositoryRoot $fixture.Repository -DriveInfo (New-SecureCheckoutDrive) -ExpectedVolumeSerial TEST -ExpectedDeviceId test -ConfirmCleanup

        $result.Executed | Should -BeFalse
        $result.BlockedReason | Should -Match '暂停项目.*直接子目录'
        Test-Path -LiteralPath $outside | Should -BeTrue
    }

    It '清理时重新验证设备身份并拒绝错误磁盘' {
        $fixture = New-SecureCheckoutFixture -Name '错误盘清理'
        $target = Join-Path $fixture.CurrentRoot '错误盘清理'
        New-Item -ItemType Directory -Path $target -Force | Out-Null

        $result = Complete-PHMCheckoutCleanup -PortableSourcePath $fixture.Source -LocalTargetPath $target -PortableRepositoryRoot $fixture.Repository -DriveInfo (New-SecureCheckoutDrive -DeviceId 'wrong') -ExpectedVolumeSerial TEST -ExpectedDeviceId 'test' -ConfirmCleanup

        $result.Executed | Should -BeFalse
        $result.BlockedReason | Should -Match '设备|磁盘'
        Test-Path -LiteralPath $fixture.Source | Should -BeTrue
    }

    It '清理时拒绝来源路径不在 DriveInfo 指定卷上' {
        $fixture = New-SecureCheckoutFixture -Name '错误卷清理'

        $result = Complete-PHMCheckoutCleanup -PortableSourcePath $fixture.Source -LocalTargetPath $fixture.CurrentRoot -PortableRepositoryRoot $fixture.Repository -DriveInfo (New-SecureCheckoutDrive -DriveLetter 'Z:') -ExpectedDriveLetter 'Z:' -ExpectedVolumeSerial TEST -ExpectedDeviceId test -ConfirmCleanup

        $result.Executed | Should -BeFalse
        $result.BlockedReason | Should -Match 'DriveInfo.DriveLetter|已验证.*卷'
        Test-Path -LiteralPath $fixture.Source | Should -BeTrue
    }

    It '两端回执任一字段不一致时拒绝清理' {
        $fixture = New-SecureCheckoutFixture -Name '回执不一致'
        $transfer = Invoke-PHMCheckout -PortableProjectPath $fixture.Source -PortableRepositoryRoot $fixture.Repository -LocalCurrentRoot $fixture.CurrentRoot -LocalReceivingRoot $fixture.ReceivingRoot -DriveInfo (New-SecureCheckoutDrive) -LocalFreeBytes 100GB -ExpectedVolumeSerial TEST -ExpectedDeviceId test -ConfirmTransfer
        $sourceReceiptPath = Join-Path $fixture.Source '项目交接\转移凭证.json'
        $receipt = Get-Content -LiteralPath $sourceReceiptPath -Raw | ConvertFrom-Json
        $receipt.transferred_at = '2000-01-01T00:00:00Z'
        $receipt | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $sourceReceiptPath -Encoding utf8

        $result = Complete-PHMCheckoutCleanup -PortableSourcePath $fixture.Source -LocalTargetPath $transfer.OfficialPath -PortableRepositoryRoot $fixture.Repository -DriveInfo (New-SecureCheckoutDrive) -ExpectedVolumeSerial 'TEST' -ExpectedDeviceId 'test' -ConfirmCleanup

        $result.Executed | Should -BeFalse
        $result.BlockedReason | Should -Match '回执不一致'
        Test-Path -LiteralPath $fixture.Source | Should -BeTrue
    }

    It '最终登记失败时来源虽已清理但本机保持 local_active 并给出修复状态' {
        $fixture = New-SecureCheckoutFixture -Name '登记失败恢复'
        $transfer = Invoke-PHMCheckout -PortableProjectPath $fixture.Source -PortableRepositoryRoot $fixture.Repository -LocalCurrentRoot $fixture.CurrentRoot -LocalReceivingRoot $fixture.ReceivingRoot -DriveInfo (New-SecureCheckoutDrive) -LocalFreeBytes 100GB -ExpectedVolumeSerial TEST -ExpectedDeviceId test -ConfirmTransfer
        $writer = { param($path,$record) throw 'registry failed' }

        $result = Complete-PHMCheckoutCleanup -PortableSourcePath $fixture.Source -LocalTargetPath $transfer.OfficialPath -PortableRepositoryRoot $fixture.Repository -DriveInfo (New-SecureCheckoutDrive) -ExpectedVolumeSerial 'TEST' -ExpectedDeviceId 'test' -ConfirmCleanup -RegistryWriter $writer
        $identity = Get-Content -LiteralPath (Join-Path $transfer.OfficialPath '项目交接\项目身份.json') -Raw | ConvertFrom-Json

        $result.Executed | Should -BeTrue
        $result.Recoverable | Should -BeTrue
        $result.RegistryState | Should -Be 'pending_repair'
        $identity.state | Should -Be 'local_active'
        Test-Path -LiteralPath $fixture.Source | Should -BeFalse
    }

    It '借出来源不是配置仓库暂停项目的直接子目录时阻断' {
        $fixture = New-SecureCheckoutFixture -Name '仓库绑定'
        $wrongRepository = Join-Path $TestDrive '另一个仓库'

        $plan = New-PHMCheckoutPlan -PortableProjectPath $fixture.Source -PortableRepositoryRoot $wrongRepository -LocalCurrentRoot $fixture.CurrentRoot -LocalReceivingRoot $fixture.ReceivingRoot -DriveInfo (New-SecureCheckoutDrive) -LocalFreeBytes 100GB -ExpectedVolumeSerial TEST -ExpectedDeviceId test

        $plan.CanExecute | Should -BeFalse
        $plan.Blockers -join '；' | Should -Match '配置.*暂停项目.*直接项目子目录'
    }

    It '借出计划拒绝来源路径不在 DriveInfo 指定卷上' {
        $fixture = New-SecureCheckoutFixture -Name '错误来源卷'

        $plan = New-PHMCheckoutPlan -PortableProjectPath $fixture.Source -PortableRepositoryRoot $fixture.Repository -LocalCurrentRoot $fixture.CurrentRoot -LocalReceivingRoot $fixture.ReceivingRoot -DriveInfo (New-SecureCheckoutDrive -DriveLetter 'Z:') -LocalFreeBytes 100GB -ExpectedDriveLetter 'Z:' -ExpectedVolumeSerial TEST -ExpectedDeviceId test

        $plan.CanExecute | Should -BeFalse
        $plan.Blockers -join '；' | Should -Match 'DriveInfo.DriveLetter|已验证.*卷'
    }

    It '借出计划拒绝仓库祖先路径中的 junction 或重解析点' {
        $fixture = New-SecureCheckoutFixture -Name '祖先重解析点'
        $pathSafety = { param($path) -not $path.EndsWith('暂停项目', [System.StringComparison]::OrdinalIgnoreCase) }

        $plan = New-PHMCheckoutPlan -PortableProjectPath $fixture.Source -PortableRepositoryRoot $fixture.Repository -LocalCurrentRoot $fixture.CurrentRoot -LocalReceivingRoot $fixture.ReceivingRoot -DriveInfo (New-SecureCheckoutDrive) -LocalFreeBytes 100GB -ExpectedVolumeSerial TEST -ExpectedDeviceId test -PathSafetyProvider $pathSafety

        $plan.CanExecute | Should -BeFalse
        $plan.Blockers -join '；' | Should -Match '路径链包含重解析点'
    }

    It '缺少本机设备信任标识时阻断借出' {
        $fixture = New-SecureCheckoutFixture -Name '信任绑定'

        $plan = New-PHMCheckoutPlan -PortableProjectPath $fixture.Source -PortableRepositoryRoot $fixture.Repository -LocalCurrentRoot $fixture.CurrentRoot -LocalReceivingRoot $fixture.ReceivingRoot -DriveInfo (New-SecureCheckoutDrive) -LocalFreeBytes 100GB

        $plan.CanExecute | Should -BeFalse
        $plan.Blockers -join '；' | Should -Match '信任记录'
    }

    It '清理显式拒绝来源与目标为同一路径' {
        $fixture = New-SecureCheckoutFixture -Name '同路径'

        $result = Complete-PHMCheckoutCleanup -PortableSourcePath $fixture.Source -LocalTargetPath $fixture.Source -PortableRepositoryRoot $fixture.Repository -DriveInfo (New-SecureCheckoutDrive) -ExpectedVolumeSerial TEST -ExpectedDeviceId test -ConfirmCleanup

        $result.Executed | Should -BeFalse
        $result.BlockedReason | Should -Match '不能是同一路径'
        Test-Path -LiteralPath $fixture.Source | Should -BeTrue
    }

    It '最终化失败后可从本机正式目录恢复而无需重新复制' {
        $fixture = New-SecureCheckoutFixture -Name '最终化恢复'
        $failure = { param($local,$portable) throw 'stop before finalization' }
        $failed = Invoke-PHMCheckout -PortableProjectPath $fixture.Source -PortableRepositoryRoot $fixture.Repository -LocalCurrentRoot $fixture.CurrentRoot -LocalReceivingRoot $fixture.ReceivingRoot -DriveInfo (New-SecureCheckoutDrive) -LocalFreeBytes 100GB -ExpectedVolumeSerial TEST -ExpectedDeviceId test -ConfirmTransfer -FinalizationAction $failure

        $repaired = Repair-PHMCheckoutFinalization -LocalTargetPath $failed.OfficialPath -PortableRepositoryRoot $fixture.Repository -DriveInfo (New-SecureCheckoutDrive) -ExpectedVolumeSerial TEST -ExpectedDeviceId test

        $repaired.Executed | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $failed.OfficialPath '项目交接\借出最终化恢复.json') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $failed.OfficialPath '项目交接\转移凭证.json') | Should -BeTrue
        Test-Path -LiteralPath $fixture.Source | Should -BeTrue
    }

    It '最终化恢复拒绝恢复记录来源所在卷与已验证磁盘不一致' {
        $fixture = New-SecureCheckoutFixture -Name '最终化错误卷'
        $failure = { param($local,$portable) throw 'stop before finalization' }
        $failed = Invoke-PHMCheckout -PortableProjectPath $fixture.Source -PortableRepositoryRoot $fixture.Repository -LocalCurrentRoot $fixture.CurrentRoot -LocalReceivingRoot $fixture.ReceivingRoot -DriveInfo (New-SecureCheckoutDrive) -LocalFreeBytes 100GB -ExpectedVolumeSerial TEST -ExpectedDeviceId test -ConfirmTransfer -FinalizationAction $failure

        { Repair-PHMCheckoutFinalization -LocalTargetPath $failed.OfficialPath -PortableRepositoryRoot $fixture.Repository -DriveInfo (New-SecureCheckoutDrive -DriveLetter 'Z:') -ExpectedDriveLetter 'Z:' -ExpectedVolumeSerial TEST -ExpectedDeviceId test } | Should -Throw '*DriveInfo.DriveLetter*'
        Test-Path -LiteralPath $fixture.Source | Should -BeTrue
    }

    It 'T9 删除失败后可安全恢复且不重新复制项目' {
        $fixture = New-SecureCheckoutFixture -Name '清理恢复'
        $transfer = Invoke-PHMCheckout -PortableProjectPath $fixture.Source -PortableRepositoryRoot $fixture.Repository -LocalCurrentRoot $fixture.CurrentRoot -LocalReceivingRoot $fixture.ReceivingRoot -DriveInfo (New-SecureCheckoutDrive) -LocalFreeBytes 100GB -ExpectedVolumeSerial TEST -ExpectedDeviceId test -ConfirmTransfer
        $failedDelete = { param($path) Remove-Item -LiteralPath (Join-Path $path 'data.txt') -Force; throw 'disk busy after partial delete' }
        $failed = Complete-PHMCheckoutCleanup -PortableSourcePath $fixture.Source -LocalTargetPath $transfer.OfficialPath -PortableRepositoryRoot $fixture.Repository -DriveInfo (New-SecureCheckoutDrive) -ExpectedVolumeSerial TEST -ExpectedDeviceId test -ConfirmCleanup -DeleteAction $failedDelete

        $failed.Executed | Should -BeFalse
        $failed.Recoverable | Should -BeTrue
        Test-Path -LiteralPath $fixture.Source | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $transfer.OfficialPath '项目交接\借出清理恢复.json') | Should -BeTrue
        { Repair-PHMCheckoutCleanup -LocalTargetPath $transfer.OfficialPath -PortableRepositoryRoot (Join-Path $TestDrive '错误仓库') -DriveInfo (New-SecureCheckoutDrive) -ExpectedVolumeSerial TEST -ExpectedDeviceId test } | Should -Throw '*指定仓库*'
        { Repair-PHMCheckoutCleanup -LocalTargetPath $transfer.OfficialPath -PortableRepositoryRoot $fixture.Repository -DriveInfo (New-SecureCheckoutDrive -DeviceId 'wrong') -ExpectedVolumeSerial TEST -ExpectedDeviceId test } | Should -Throw '*设备或磁盘*'

        $repaired = Repair-PHMCheckoutCleanup -LocalTargetPath $transfer.OfficialPath -PortableRepositoryRoot $fixture.Repository -DriveInfo (New-SecureCheckoutDrive) -ExpectedVolumeSerial TEST -ExpectedDeviceId test

        $repaired.Executed | Should -BeTrue
        $repaired.DeletedSource | Should -BeTrue
        Test-Path -LiteralPath $fixture.Source | Should -BeFalse
        Test-Path -LiteralPath $transfer.OfficialPath | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $transfer.OfficialPath '项目交接\借出清理恢复.json') | Should -BeFalse
    }

    It '部分删除后残余文件内容变化时恢复阻断' {
        $fixture = New-SecureCheckoutFixture -Name '残余内容变化'
        Set-Content -LiteralPath (Join-Path $fixture.Source 'keep.txt') -Value 'original' -Encoding utf8
        $transfer = Invoke-PHMCheckout -PortableProjectPath $fixture.Source -PortableRepositoryRoot $fixture.Repository -LocalCurrentRoot $fixture.CurrentRoot -LocalReceivingRoot $fixture.ReceivingRoot -DriveInfo (New-SecureCheckoutDrive) -LocalFreeBytes 100GB -ExpectedVolumeSerial TEST -ExpectedDeviceId test -ConfirmTransfer
        $failedDelete = { param($path) Remove-Item -LiteralPath (Join-Path $path 'data.txt') -Force; throw 'partial' }
        Complete-PHMCheckoutCleanup -PortableSourcePath $fixture.Source -LocalTargetPath $transfer.OfficialPath -PortableRepositoryRoot $fixture.Repository -DriveInfo (New-SecureCheckoutDrive) -ExpectedVolumeSerial TEST -ExpectedDeviceId test -ConfirmCleanup -DeleteAction $failedDelete | Out-Null
        Set-Content -LiteralPath (Join-Path $fixture.Source 'keep.txt') -Value 'changed' -Encoding utf8

        { Repair-PHMCheckoutCleanup -LocalTargetPath $transfer.OfficialPath -PortableRepositoryRoot $fixture.Repository -DriveInfo (New-SecureCheckoutDrive) -ExpectedVolumeSerial TEST -ExpectedDeviceId test } | Should -Throw '*残余文件发生变化*'
        Test-Path -LiteralPath $fixture.Source | Should -BeTrue
    }

    It '部分删除后来源新增文件时恢复阻断' {
        $fixture = New-SecureCheckoutFixture -Name '残余新增文件'
        $transfer = Invoke-PHMCheckout -PortableProjectPath $fixture.Source -PortableRepositoryRoot $fixture.Repository -LocalCurrentRoot $fixture.CurrentRoot -LocalReceivingRoot $fixture.ReceivingRoot -DriveInfo (New-SecureCheckoutDrive) -LocalFreeBytes 100GB -ExpectedVolumeSerial TEST -ExpectedDeviceId test -ConfirmTransfer
        $failedDelete = { param($path) Remove-Item -LiteralPath (Join-Path $path 'data.txt') -Force; throw 'partial' }
        Complete-PHMCheckoutCleanup -PortableSourcePath $fixture.Source -LocalTargetPath $transfer.OfficialPath -PortableRepositoryRoot $fixture.Repository -DriveInfo (New-SecureCheckoutDrive) -ExpectedVolumeSerial TEST -ExpectedDeviceId test -ConfirmCleanup -DeleteAction $failedDelete | Out-Null
        Set-Content -LiteralPath (Join-Path $fixture.Source 'unexpected.txt') -Value 'new' -Encoding utf8

        { Repair-PHMCheckoutCleanup -LocalTargetPath $transfer.OfficialPath -PortableRepositoryRoot $fixture.Repository -DriveInfo (New-SecureCheckoutDrive) -ExpectedVolumeSerial TEST -ExpectedDeviceId test } | Should -Throw '*新增文件*'
        Test-Path -LiteralPath $fixture.Source | Should -BeTrue
    }

    It '部分删除后残余内容存在不可读项时恢复阻断' {
        $fixture = New-SecureCheckoutFixture -Name '残余不可读'
        $transfer = Invoke-PHMCheckout -PortableProjectPath $fixture.Source -PortableRepositoryRoot $fixture.Repository -LocalCurrentRoot $fixture.CurrentRoot -LocalReceivingRoot $fixture.ReceivingRoot -DriveInfo (New-SecureCheckoutDrive) -LocalFreeBytes 100GB -ExpectedVolumeSerial TEST -ExpectedDeviceId test -ConfirmTransfer
        $failedDelete = { param($path) Remove-Item -LiteralPath (Join-Path $path 'data.txt') -Force; throw 'partial' }
        Complete-PHMCheckoutCleanup -PortableSourcePath $fixture.Source -LocalTargetPath $transfer.OfficialPath -PortableRepositoryRoot $fixture.Repository -DriveInfo (New-SecureCheckoutDrive) -ExpectedVolumeSerial TEST -ExpectedDeviceId test -ConfirmCleanup -DeleteAction $failedDelete | Out-Null
        $inventoryProvider = {
            param($path)
            $inventory = Get-PHMProjectInventory -ProjectPath $path
            $inventory.Unreadable = @('locked.bin')
            $inventory
        }

        { Repair-PHMCheckoutCleanup -LocalTargetPath $transfer.OfficialPath -PortableRepositoryRoot $fixture.Repository -DriveInfo (New-SecureCheckoutDrive) -ExpectedVolumeSerial TEST -ExpectedDeviceId test -InventoryProvider $inventoryProvider } | Should -Throw '*不可读*'
        Test-Path -LiteralPath $fixture.Source | Should -BeTrue
    }
}
