Describe '事务式归还 T9' {
    BeforeAll {
        $modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'project-handoff-manager\scripts\ProjectManager.Core.psm1'
        Import-Module $modulePath -Force
        $script:TransactionDriveLetter = [System.IO.Path]::GetPathRoot($TestDrive).TrimEnd('\')
        $PSDefaultParameterValues['Invoke-PHMCheckin:ExpectedDriveLetter'] = $script:TransactionDriveLetter

        function New-TransactionDriveInfo {
            [pscustomobject]@{
                DriveLetter=$script:TransactionDriveLetter; VolumeLabel='T9'; FileSystem='NTFS'; HealthStatus='Healthy'
                OperationalStatus='OK'; IsReadOnly=$false; IsOffline=$false; FreeBytes=100GB
                FriendlyName='Samsung PSSD T9'; VolumeSerial='TEST1234'; DeviceId='test-device'
            }
        }

        function New-TransactionProject {
            param([string]$Name='事务项目')
            $project = Join-Path $TestDrive $Name
            New-Item -ItemType Directory -Path $project -Force | Out-Null
            Initialize-PHMProject -ProjectPath $project -ComputerName 'TEST-PC' | Out-Null
            Set-Content -LiteralPath (Join-Path $project '输入资料\材料.txt') -Value 'source-material' -Encoding utf8
            Set-Content -LiteralPath (Join-Path $project '输出成果\成果.txt') -Value 'source-output' -Encoding utf8
            return $project
        }
    }

    It '成功时经暂存复制和校验后提交正式目录但保留本机来源' {
        $project = New-TransactionProject
        $repository = Join-Path $TestDrive '项目仓库'
        New-Item -ItemType Directory -Path $repository -Force | Out-Null

        $result = Invoke-PHMCheckin -ProjectPath $project -PortableRepositoryRoot $repository -DriveInfo (New-TransactionDriveInfo) -ProcessRecords @() -ConfirmTransfer

        $result.Executed | Should -BeTrue
        $result.Verified | Should -BeTrue
        $result.CleanupRequired | Should -BeTrue
        Test-Path -LiteralPath $project | Should -BeTrue
        Test-Path -LiteralPath $result.OfficialPath | Should -BeTrue
        Test-Path -LiteralPath $result.ReceivingPath | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $result.OfficialPath '项目交接\转移凭证.json') | Should -BeTrue
        (Get-Content -LiteralPath (Join-Path $project '项目交接\项目身份.json') -Raw | ConvertFrom-Json).state | Should -Be 'cleanup_pending'
        (Get-Content -LiteralPath (Join-Path $result.OfficialPath '项目交接\项目身份.json') -Raw | ConvertFrom-Json).state | Should -Be 'cleanup_pending'
        $registry = Get-Content -LiteralPath (Join-Path (Split-Path $repository -Parent) '管理资料\项目登记.json') -Raw | ConvertFrom-Json
        $registry.projects.state | Should -Contain 'cleanup_pending'
    }

    It '复制器失败时不创建正式目录且来源保持完整' {
        $project = New-TransactionProject -Name '复制失败项目'
        $repository = Join-Path $TestDrive '失败仓库'
        New-Item -ItemType Directory -Path $repository -Force | Out-Null
        $copyFailure = { param($source,$destination) New-Item -ItemType Directory -Path $destination -Force | Out-Null; [pscustomobject]@{ Success=$false; ExitCode=8; Message='模拟复制失败' } }

        $result = Invoke-PHMCheckin -ProjectPath $project -PortableRepositoryRoot $repository -DriveInfo (New-TransactionDriveInfo) -ProcessRecords @() -ConfirmTransfer -CopyAction $copyFailure

        $result.Executed | Should -BeFalse
        $result.Verified | Should -BeFalse
        $result.DeletedFiles | Should -Be 0
        Test-Path -LiteralPath $project | Should -BeTrue
        Test-Path -LiteralPath $result.OfficialPath | Should -BeFalse
        Get-Content -LiteralPath (Join-Path $project '输入资料\材料.txt') -Raw | Should -Match 'source-material'
    }

    It '复制期间来源新增文件时停止提交且不删除来源' {
        $project = New-TransactionProject -Name '变化项目'
        $repository = Join-Path $TestDrive '变化仓库'
        New-Item -ItemType Directory -Path $repository -Force | Out-Null
        $copyAndModify = {
            param($source,$destination)
            New-Item -ItemType Directory -Path $destination -Force | Out-Null
            Get-ChildItem -LiteralPath $source -Force | Copy-Item -Destination $destination -Recurse -Force
            Set-Content -LiteralPath (Join-Path $source '复制中新增.txt') -Value 'changed' -Encoding utf8
            [pscustomobject]@{ Success=$true; ExitCode=1; Message='copied then changed' }
        }

        $result = Invoke-PHMCheckin -ProjectPath $project -PortableRepositoryRoot $repository -DriveInfo (New-TransactionDriveInfo) -ProcessRecords @() -ConfirmTransfer -CopyAction $copyAndModify

        $result.Executed | Should -BeFalse
        $result.FailureStage | Should -Be 'source-changed'
        Test-Path -LiteralPath $project | Should -BeTrue
        Test-Path -LiteralPath $result.OfficialPath | Should -BeFalse
    }

    It '目标同大小内容被篡改时哈希校验失败且不提交正式目录' {
        $project = New-TransactionProject -Name '哈希项目'
        $repository = Join-Path $TestDrive '哈希仓库'
        New-Item -ItemType Directory -Path $repository -Force | Out-Null
        $copyAndCorrupt = {
            param($source,$destination)
            New-Item -ItemType Directory -Path $destination -Force | Out-Null
            Get-ChildItem -LiteralPath $source -Force | Copy-Item -Destination $destination -Recurse -Force
            $target = Join-Path $destination '输入资料\材料.txt'
            $bytes = [System.IO.File]::ReadAllBytes($target)
            $bytes[0] = $bytes[0] -bxor 1
            [System.IO.File]::WriteAllBytes($target,$bytes)
            [pscustomobject]@{ Success=$true; ExitCode=1; Message='copied then corrupted' }
        }

        $result = Invoke-PHMCheckin -ProjectPath $project -PortableRepositoryRoot $repository -DriveInfo (New-TransactionDriveInfo) -ProcessRecords @() -ConfirmTransfer -CopyAction $copyAndCorrupt

        $result.Executed | Should -BeFalse
        $result.FailureStage | Should -Be 'verification'
        $result.Verification.Differences -join '；' | Should -Match '哈希'
        Test-Path -LiteralPath $project | Should -BeTrue
        Test-Path -LiteralPath $result.OfficialPath | Should -BeFalse
    }

    It '登记写入失败时仍保留本机来源和已校验目标供修复' {
        $project = New-TransactionProject -Name '登记失败项目'
        $repository = Join-Path $TestDrive '登记失败仓库'
        New-Item -ItemType Directory -Path $repository -Force | Out-Null
        $writer = { param($registryPath,$record) throw '模拟登记失败' }

        $result = Invoke-PHMCheckin -ProjectPath $project -PortableRepositoryRoot $repository -DriveInfo (New-TransactionDriveInfo) -ProcessRecords @() -ConfirmTransfer -RegistryWriter $writer

        $result.Executed | Should -BeFalse
        $result.FailureStage | Should -Be 'registry'
        Test-Path -LiteralPath $project | Should -BeTrue
        Test-Path -LiteralPath $result.OfficialPath | Should -BeTrue
        $result.DeletedFiles | Should -Be 0
    }
}
