Describe '归还后的独立来源清理' {
    BeforeAll {
        $modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'project-handoff-manager\scripts\ProjectManager.Core.psm1'
        Import-Module $modulePath -Force

        function New-CleanupDriveInfo {
            [pscustomobject]@{
                DriveLetter='T:'; VolumeLabel='T9'; FileSystem='NTFS'; HealthStatus='Healthy'
                OperationalStatus='OK'; IsReadOnly=$false; IsOffline=$false; FreeBytes=100GB
                FriendlyName='Samsung PSSD T9'; VolumeSerial='TEST1234'; DeviceId='test-device'
            }
        }

        function New-PendingCheckin {
            param([string]$Name)
            $project = Join-Path $TestDrive $Name
            $repository = Join-Path $TestDrive ($Name + '-仓库')
            New-Item -ItemType Directory -Path $project,$repository -Force | Out-Null
            Initialize-PHMProject -ProjectPath $project | Out-Null
            Set-Content -LiteralPath (Join-Path $project 'data.txt') -Value 'data' -Encoding utf8
            $result = Invoke-PHMCheckin -ProjectPath $project -PortableRepositoryRoot $repository -DriveInfo (New-CleanupDriveInfo) -ProcessRecords @() -ConfirmTransfer
            [pscustomobject]@{ Source=$project; Target=$result.OfficialPath; Repository=$repository; Transfer=$result }
        }
    }

    It '未明确确认时只显示精确删除路径和预期结果' {
        $pending = New-PendingCheckin -Name '清理预览'

        $result = Complete-PHMCheckinCleanup -SourcePath $pending.Source -TargetPath $pending.Target

        $result.Executed | Should -BeFalse
        $result.RequiresConfirmation | Should -BeTrue
        $result.SourcePath | Should -Be (Get-Item $pending.Source).FullName
        Test-Path -LiteralPath $pending.Source | Should -BeTrue
        Test-Path -LiteralPath $pending.Target | Should -BeTrue
    }

    It '确认且来源未变化时删除本机来源并把 T9 状态更新为 on_t9' {
        $pending = New-PendingCheckin -Name '完成清理'

        $result = Complete-PHMCheckinCleanup -SourcePath $pending.Source -TargetPath $pending.Target -ConfirmCleanup
        $targetIdentity = Get-Content -LiteralPath (Join-Path $pending.Target '项目交接\项目身份.json') -Raw | ConvertFrom-Json

        $result.Executed | Should -BeTrue
        $result.DeletedSource | Should -BeTrue
        Test-Path -LiteralPath $pending.Source | Should -BeFalse
        Test-Path -LiteralPath $pending.Target | Should -BeTrue
        $targetIdentity.state | Should -Be 'on_t9'
    }

    It '来源在复制后发生变化时禁止清理并保留两个副本' {
        $pending = New-PendingCheckin -Name '变化后清理'
        Set-Content -LiteralPath (Join-Path $pending.Source '新材料.txt') -Value 'new' -Encoding utf8

        $result = Complete-PHMCheckinCleanup -SourcePath $pending.Source -TargetPath $pending.Target -ConfirmCleanup

        $result.Executed | Should -BeFalse
        $result.BlockedReason | Should -Match '发生变化'
        Test-Path -LiteralPath $pending.Source | Should -BeTrue
        Test-Path -LiteralPath $pending.Target | Should -BeTrue
    }

    It '删除保护拒绝盘符根目录、用户目录和指定项目管理根目录' {
        Test-PHMDeletionPath -Path 'C:\' | Should -BeFalse
        Test-PHMDeletionPath -Path $env:USERPROFILE | Should -BeFalse
        $managedRoot = Join-Path $TestDrive '项目管理根目录'
        New-Item -ItemType Directory -Path $managedRoot | Out-Null
        Test-PHMDeletionPath -Path $managedRoot -ProtectedRoots @($managedRoot) | Should -BeFalse
        $child = Join-Path $managedRoot '具体项目'
        New-Item -ItemType Directory -Path $child | Out-Null
        Test-PHMDeletionPath -Path $child -ProtectedRoots @($managedRoot) | Should -BeTrue
    }
}
