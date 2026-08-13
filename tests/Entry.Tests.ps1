Describe '项目管家入口' {
    BeforeAll {
        $entryPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'project-handoff-manager\scripts\project_manager.ps1'
    }

    It '默认输出四项中文操作菜单的 JSON' {
        Test-Path -LiteralPath $entryPath | Should -BeTrue

        $result = & $entryPath -Action menu | ConvertFrom-Json

        $result.safeMode | Should -BeTrue
        $result.operations.Count | Should -Be 4
        $result.message | Should -Match '执行前'
    }

    It 'checkout 已实现且缺少 T9 项目路径时安全拒绝' {
        { & $entryPath -Action checkout } | Should -Throw '*必须提供 -ProjectPath*'
    }

    It 'inspect 使用配置文件列出本机和移动盘项目' {
        $localRoot = Join-Path $TestDrive '本机项目'
        $portableRoot = Join-Path $TestDrive '项目仓库'
        New-Item -ItemType Directory -Path (Join-Path $localRoot '本机甲'),(Join-Path $portableRoot '暂停项目\移动乙') -Force | Out-Null
        $configPath = Join-Path $TestDrive 'config.json'
        @{
            schemaVersion = 1
            local = @{ currentProjectsRoot = $localRoot; pausedProjectsRoot = (Join-Path $TestDrive '本机暂停') }
            portableDrive = @{ repositoryRoot = $portableRoot }
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $configPath -Encoding utf8

        $result = & $entryPath -Action inspect -ConfigPath $configPath | ConvertFrom-Json

        $result.executed | Should -BeTrue
        $result.overview.LocalProjects.Name | Should -Contain '本机甲'
        $result.overview.PortableProjects.Name | Should -Contain '移动乙'
    }

    It 'resume 自动纳管并返回可继续工作的摘要' {
        $project = Join-Path $TestDrive '入口项目'
        New-Item -ItemType Directory -Path $project -Force | Out-Null

        $result = & $entryPath -Action resume -ProjectPath $project -ComputerName 'TEST-PC' | ConvertFrom-Json

        $result.executed | Should -BeTrue
        $result.result.State | Should -Be 'local_active'
        Test-Path -LiteralPath (Join-Path $project '项目交接\项目身份.json') | Should -BeTrue
    }

    It 'pause 第一次只预览，明确确认后才更新暂停状态' {
        $project = Join-Path $TestDrive '暂停入口项目'
        New-Item -ItemType Directory -Path $project -Force | Out-Null
        & $entryPath -Action adopt -ProjectPath $project -ComputerName 'TEST-PC' | Out-Null

        $preview = & $entryPath -Action pause -ProjectPath $project -ComputerName 'TEST-PC' | ConvertFrom-Json
        $before = Get-Content -LiteralPath (Join-Path $project '项目交接\项目身份.json') -Raw | ConvertFrom-Json
        $executed = & $entryPath -Action pause -ProjectPath $project -ComputerName 'TEST-PC' -ConfirmStop | ConvertFrom-Json
        $after = Get-Content -LiteralPath (Join-Path $project '项目交接\项目身份.json') -Raw | ConvertFrom-Json

        $preview.executed | Should -BeFalse
        $preview.requiresConfirmation | Should -BeTrue
        $before.state | Should -Be 'local_active'
        $executed.executed | Should -BeTrue
        $after.state | Should -Be 'local_paused'
    }

    It 'checkin 第一次只显示完整归还计划且不复制或删除' {
        $project = Join-Path $TestDrive '归还入口项目'
        $repository = Join-Path $TestDrive '入口项目仓库'
        New-Item -ItemType Directory -Path $project,$repository -Force | Out-Null
        & $entryPath -Action adopt -ProjectPath $project | Out-Null
        $driveLetter = [System.IO.Path]::GetPathRoot($TestDrive).TrimEnd('\')
        $drive = [pscustomobject]@{
            DriveLetter=$driveLetter;VolumeLabel='T9';FileSystem='NTFS';HealthStatus='Healthy';OperationalStatus='OK'
            IsReadOnly=$false;IsOffline=$false;FreeBytes=100GB;FriendlyName='Samsung PSSD T9';VolumeSerial='TEST';DeviceId='TEST'
        }
        $configPath = Join-Path $TestDrive 'checkin-entry-config.json'
        @{schemaVersion=1;local=@{};portableDrive=@{driveLetter=$driveLetter;volumeLabel='T9';requiredFileSystem='NTFS';friendlyName='Samsung PSSD T9';repositoryRoot=$repository;volumeSerial='TEST';deviceId='TEST'}} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $configPath -Encoding utf8

        $preview = & $entryPath -Action checkin -ProjectPath $project -ConfigPath $configPath -DriveInfo $drive | ConvertFrom-Json

        $preview.executed | Should -BeFalse
        $preview.requiresConfirmation | Should -BeTrue
        $preview.result.Plan.SourcePath | Should -Be (Get-Item $project).FullName
        Test-Path -LiteralPath $preview.result.OfficialPath | Should -BeFalse
        Test-Path -LiteralPath $project | Should -BeTrue
    }

    It 'checkout 第一次只显示完整借出计划且不复制或删除' {
        $repository = Join-Path $TestDrive '借出入口仓库'
        $project = Join-Path $repository '暂停项目\借出入口项目'
        $currentRoot = Join-Path $TestDrive '借出当前'
        $receivingRoot = Join-Path $TestDrive '借出接收'
        New-Item -ItemType Directory -Path $project -Force | Out-Null
        & $entryPath -Action adopt -ProjectPath $project | Out-Null
        $drive = [pscustomobject]@{
            DriveLetter='T:';VolumeLabel='T9';FileSystem='NTFS';HealthStatus='Healthy';OperationalStatus='OK'
            IsReadOnly=$false;IsOffline=$false;FreeBytes=100GB;FriendlyName='Samsung PSSD T9';VolumeSerial='TEST';DeviceId='TEST'
        }

        $preview = & $entryPath -Action checkout -ProjectPath $project -PortableRepositoryRoot $repository -LocalCurrentRoot $currentRoot -LocalReceivingRoot $receivingRoot -DriveInfo $drive | ConvertFrom-Json

        $preview.executed | Should -BeFalse
        $preview.requiresConfirmation | Should -BeTrue
        $preview.result.Plan.SourcePath | Should -Be (Get-Item $project).FullName
        Test-Path -LiteralPath $preview.result.OfficialPath | Should -BeFalse
        Test-Path -LiteralPath $project | Should -BeTrue
    }

    It 'checkout 入口把配置中的文件系统和设备型号传入磁盘校验' {
        $repository = Join-Path $TestDrive '入口配置校验仓库'
        $project = Join-Path $repository '暂停项目\配置校验项目'
        $currentRoot = Join-Path $TestDrive '配置校验当前'
        $receivingRoot = Join-Path $TestDrive '配置校验接收'
        New-Item -ItemType Directory -Path $project -Force | Out-Null
        & $entryPath -Action adopt -ProjectPath $project | Out-Null
        $configPath = Join-Path $TestDrive 'checkout-config.json'
        @{
            schemaVersion = 1
            local = @{ currentProjectsRoot=$currentRoot; receivingRoot=$receivingRoot; pausedProjectsRoot=(Join-Path $TestDrive '暂停') }
            portableDrive = @{
                driveLetter='T:'; volumeLabel='T9'; requiredFileSystem='exFAT'; friendlyName='Expected Model'
                repositoryRoot=$repository; volumeSerial=$null; deviceId=$null
            }
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $configPath -Encoding utf8
        $drive = [pscustomobject]@{
            DriveLetter='T:';VolumeLabel='T9';FileSystem='NTFS';HealthStatus='Healthy';OperationalStatus='OK'
            IsReadOnly=$false;IsOffline=$false;FreeBytes=100GB;FriendlyName='Samsung PSSD T9';VolumeSerial='TEST';DeviceId='TEST'
        }

        $preview = & $entryPath -Action checkout -ProjectPath $project -ConfigPath $configPath -DriveInfo $drive -LocalFreeBytes 100GB | ConvertFrom-Json

        $preview.result.Plan.CanExecute | Should -BeFalse
        $preview.result.Plan.Blockers -join '；' | Should -Match '文件系统不匹配'
        $preview.result.Plan.Blockers -join '；' | Should -Match '设备型号不匹配'
    }

    It 'repair 自动识别借出清理恢复并且不重新复制' {
        $modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'project-handoff-manager\scripts\ProjectManager.Core.psm1'
        Import-Module $modulePath -Force
        $driveLetter = [System.IO.Path]::GetPathRoot($TestDrive).TrimEnd('\')
        $repository = Join-Path $TestDrive 'repair-入口仓库'
        $project = Join-Path $repository '暂停项目\repair-入口项目'
        $currentRoot = Join-Path $TestDrive 'repair-当前'
        $receivingRoot = Join-Path $TestDrive 'repair-接收'
        New-Item -ItemType Directory -Path $project -Force | Out-Null
        Initialize-PHMProject -ProjectPath $project -InitialState 'on_t9' | Out-Null
        Set-Content -LiteralPath (Join-Path $project 'data.txt') -Value 'portable' -Encoding utf8
        $drive = [pscustomobject]@{
            DriveLetter=$driveLetter;VolumeLabel='T9';FileSystem='NTFS';HealthStatus='Healthy';OperationalStatus='OK'
            IsReadOnly=$false;IsOffline=$false;FreeBytes=100GB;FriendlyName='Samsung PSSD T9';VolumeSerial='TEST';DeviceId='test'
        }
        $transfer = Invoke-PHMCheckout -PortableProjectPath $project -PortableRepositoryRoot $repository -LocalCurrentRoot $currentRoot -LocalReceivingRoot $receivingRoot -DriveInfo $drive -LocalFreeBytes 100GB -ExpectedDriveLetter $driveLetter -ExpectedVolumeSerial TEST -ExpectedDeviceId test -ConfirmTransfer
        $failedDelete = { param($path) throw 'disk busy' }
        Complete-PHMCheckoutCleanup -PortableSourcePath $project -LocalTargetPath $transfer.OfficialPath -PortableRepositoryRoot $repository -DriveInfo $drive -ExpectedDriveLetter $driveLetter -ExpectedVolumeSerial TEST -ExpectedDeviceId test -ConfirmCleanup -DeleteAction $failedDelete | Out-Null
        $configPath = Join-Path $TestDrive 'repair-config.json'
        @{
            schemaVersion=1
            local=@{currentProjectsRoot=$currentRoot;receivingRoot=$receivingRoot;pausedProjectsRoot=(Join-Path $TestDrive 'repair-暂停')}
            portableDrive=@{driveLetter=$driveLetter;volumeLabel='T9';requiredFileSystem='NTFS';friendlyName='Samsung PSSD T9';repositoryRoot=$repository;volumeSerial='TEST';deviceId='test'}
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $configPath -Encoding utf8

        $result = & $entryPath -Action repair -TargetPath $transfer.OfficialPath -ConfigPath $configPath -DriveInfo $drive | ConvertFrom-Json

        $result.executed | Should -BeTrue
        $result.repairKind | Should -Be 'checkout-cleanup'
        Test-Path -LiteralPath $project | Should -BeFalse
        Test-Path -LiteralPath $transfer.OfficialPath | Should -BeTrue
    }
}
