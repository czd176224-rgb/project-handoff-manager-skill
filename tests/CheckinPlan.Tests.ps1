Describe '归还 T9 执行计划' {
    BeforeAll {
        $modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'project-handoff-manager\scripts\ProjectManager.Core.psm1'
        Import-Module $modulePath -Force

        function New-CheckinDriveInfo {
            [pscustomobject]@{
                DriveLetter='T:'; VolumeLabel='T9'; FileSystem='NTFS'; HealthStatus='Healthy'
                OperationalStatus='OK'; IsReadOnly=$false; IsOffline=$false; FreeBytes=100GB
                FriendlyName='Samsung PSSD T9'; VolumeSerial='TEST1234'; DeviceId='test-device'
            }
        }
    }

    It '生成源、暂存、正式路径和完整项目文件清单但不复制' {
        $project = Join-Path $TestDrive '计划项目'
        $repository = Join-Path $TestDrive '项目仓库'
        New-Item -ItemType Directory -Path $project,$repository -Force | Out-Null
        Initialize-PHMProject -ProjectPath $project -ComputerName 'TEST-PC' | Out-Null
        Set-Content -LiteralPath (Join-Path $project '输入资料\材料.txt') -Value 'input' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $project '输出成果\成果.txt') -Value 'output' -Encoding utf8
        $identity = Get-Content -LiteralPath (Join-Path $project '项目交接\项目身份.json') -Raw | ConvertFrom-Json

        $plan = New-PHMCheckinPlan -ProjectPath $project -PortableRepositoryRoot $repository -DriveInfo (New-CheckinDriveInfo) -ProcessRecords @()

        $plan.CanExecute | Should -BeTrue
        $plan.SourcePath | Should -Be (Get-Item $project).FullName
        $plan.ReceivingPath | Should -Be (Join-Path $repository "正在接收\$($identity.project_id)\计划项目")
        $plan.OfficialPath | Should -Be (Join-Path $repository '暂停项目\计划项目')
        $plan.Inventory.FileCount | Should -BeGreaterOrEqual 5
        $plan.Inventory.TotalBytes | Should -BeGreaterThan 0
        $plan.Inventory.CriticalFiles.RelativePath | Should -Contain '项目交接\项目身份.json'
        Test-Path -LiteralPath $plan.ReceivingPath | Should -BeFalse
        Test-Path -LiteralPath $plan.OfficialPath | Should -BeFalse
    }

    It '敏感文件需要明确确认但默认不从完整项目中静默排除' {
        $project = Join-Path $TestDrive '敏感项目'
        $repository = Join-Path $TestDrive '敏感仓库'
        New-Item -ItemType Directory -Path $project,$repository -Force | Out-Null
        Initialize-PHMProject -ProjectPath $project | Out-Null
        Set-Content -LiteralPath (Join-Path $project '.env') -Value 'API_KEY=test-only' -Encoding utf8

        $plan = New-PHMCheckinPlan -ProjectPath $project -PortableRepositoryRoot $repository -DriveInfo (New-CheckinDriveInfo) -ProcessRecords @()

        $plan.CanExecute | Should -BeFalse
        $plan.RequiresSensitiveConfirmation | Should -BeTrue
        $plan.SensitiveFiles | Should -Contain '.env'
        $plan.ExcludedFiles.Count | Should -Be 0
        $confirmed = New-PHMCheckinPlan -ProjectPath $project -PortableRepositoryRoot $repository -DriveInfo (New-CheckinDriveInfo) -ProcessRecords @() -AllowSensitiveFiles
        $confirmed.CanExecute | Should -BeTrue
    }

    It '目录联接或重解析点进入阻断项且不会被递归扫描' {
        $project = Join-Path $TestDrive '联接项目'
        $outside = Join-Path $TestDrive '项目外资料'
        $repository = Join-Path $TestDrive '联接仓库'
        New-Item -ItemType Directory -Path $project,$outside,$repository -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $outside '不能跟随.txt') -Value 'outside' -Encoding utf8
        Initialize-PHMProject -ProjectPath $project | Out-Null
        New-Item -ItemType Junction -Path (Join-Path $project '外部联接') -Target $outside | Out-Null

        $plan = New-PHMCheckinPlan -ProjectPath $project -PortableRepositoryRoot $repository -DriveInfo (New-CheckinDriveInfo) -ProcessRecords @()

        $plan.CanExecute | Should -BeFalse
        $plan.Blockers -join '；' | Should -Match '重解析点'
        $plan.Inventory.ReparsePoints.RelativePath | Should -Contain '外部联接'
        $plan.Inventory.Files.RelativePath | Should -Not -Contain '外部联接\不能跟随.txt'
    }

    It '同名正式目录或同项目编号冲突时拒绝覆盖' {
        $project = Join-Path $TestDrive '冲突项目'
        $repository = Join-Path $TestDrive '冲突仓库'
        $official = Join-Path $repository '暂停项目\冲突项目'
        New-Item -ItemType Directory -Path $project,$official -Force | Out-Null
        Initialize-PHMProject -ProjectPath $project | Out-Null

        $plan = New-PHMCheckinPlan -ProjectPath $project -PortableRepositoryRoot $repository -DriveInfo (New-CheckinDriveInfo) -ProcessRecords @()

        $plan.CanExecute | Should -BeFalse
        $plan.Blockers -join '；' | Should -Match '正式目录已存在'
    }

    It '磁盘校验失败或项目进程尚未暂停时拒绝执行' {
        $project = Join-Path $TestDrive '阻断项目'
        $repository = Join-Path $TestDrive '阻断仓库'
        New-Item -ItemType Directory -Path $project,$repository -Force | Out-Null
        Initialize-PHMProject -ProjectPath $project | Out-Null
        $badDrive = New-CheckinDriveInfo
        $badDrive.IsReadOnly = $true
        $processes = @([pscustomobject]@{ Id=999; Name='node'; CommandLine="node `"$project\server.js`""; ExecutablePath='C:\node.exe'; ParentProcessId=1; WorkingSetSize=1MB; CpuSeconds=1 })

        $plan = New-PHMCheckinPlan -ProjectPath $project -PortableRepositoryRoot $repository -DriveInfo $badDrive -ProcessRecords $processes

        $plan.CanExecute | Should -BeFalse
        $plan.Blockers -join '；' | Should -Match '只读'
        $plan.RequiresPauseConfirmation | Should -BeTrue
        $plan.PausePlan.StopCandidates.Id | Should -Contain 999
    }
}
