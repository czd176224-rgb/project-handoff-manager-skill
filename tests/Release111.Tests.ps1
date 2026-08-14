BeforeAll {
    $script:modulePath = Join-Path $PSScriptRoot '..\project-handoff-manager\scripts\ProjectManager.Core.psm1'
    Import-Module $script:modulePath -Force

    function New-TestCheckoutProject {
        param([Parameter(Mandatory)][string]$Root)

        $repositoryRoot = Join-Path $Root 'portable-repository'
        $portableSource = Join-Path $repositoryRoot '暂停项目\demo-project'
        $localTarget = Join-Path $Root 'local\demo-project'
        $projectId = [guid]::NewGuid().ToString()

        foreach ($path in @($portableSource, $localTarget)) {
            New-Item -ItemType Directory -Path (Join-Path $path '项目交接') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $path '项目交接\项目交接报告.md') -Value '# 项目交接报告' -Encoding utf8NoBOM
        }

        Set-Content -LiteralPath (Join-Path $portableSource 'payload.txt') -Value 'portable-original' -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $localTarget 'payload.txt') -Value 'local-work-after-checkout' -Encoding utf8NoBOM

        $identity = [ordered]@{
            schema_version = 1
            project_id = $projectId
            project_name = 'demo-project'
            revision = 1
            official_location = $localTarget
            state = 'cleanup_pending'
            last_computer = 'TEST'
            last_operation = 'checkout'
            last_updated = '2026-08-14T00:00:00Z'
        }
        $receipt = [ordered]@{
            schema_version = 1
            operation = 'checkout'
            project_id = $projectId
            repository_root = $repositoryRoot
            source_path = $portableSource
            target_path = $localTarget
            transferred_at = '2026-08-14T00:00:00Z'
            source_manifest_digest = 'checkout-time-digest'
        }
        foreach ($path in @($portableSource, $localTarget)) {
            $identity | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $path '项目交接\项目身份.json') -Encoding utf8NoBOM
            $receipt | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $path '项目交接\转移凭证.json') -Encoding utf8NoBOM
        }

        $driveLetter = [System.IO.Path]::GetPathRoot($repositoryRoot).TrimEnd('\')
        [pscustomobject]@{
            RepositoryRoot = $repositoryRoot
            PortableSource = $portableSource
            LocalTarget = $localTarget
            DriveInfo = [pscustomobject]@{
                DriveLetter = $driveLetter
                VolumeLabel = 'TEST'
                FileSystem = 'NTFS'
                FriendlyName = 'TEST-DRIVE'
                HealthStatus = 'Healthy'
                OperationalStatus = 'OK'
                IsReadOnly = $false
                IsOffline = $false
                FreeBytes = 10GB
                VolumeSerial = 'SERIAL-1'
                DeviceId = 'DEVICE-1'
            }
        }
    }

    function New-TestCheckinProject {
        param([Parameter(Mandatory)][string]$Root)

        $localSource = Join-Path $Root 'local\demo-project'
        $repositoryRoot = Join-Path $Root 'portable-repository'
        $portableTarget = Join-Path $repositoryRoot '暂停项目\demo-project'
        $projectId = [guid]::NewGuid().ToString()

        New-Item -ItemType Directory -Path (Join-Path $localSource '项目交接') -Force | Out-Null
        New-Item -ItemType Directory -Path (Split-Path $portableTarget -Parent) -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $localSource 'payload.txt') -Value 'same-project-content' -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $localSource '项目交接\项目交接报告.md') -Value '# 项目交接报告' -Encoding utf8NoBOM

        $identity = [ordered]@{
            schema_version = 1
            project_id = $projectId
            project_name = 'demo-project'
            revision = 1
            official_location = $portableTarget
            state = 'cleanup_pending'
            last_computer = 'TEST'
            last_operation = 'checkin'
            last_updated = '2026-08-14T00:00:00Z'
        }
        $identity | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $localSource '项目交接\项目身份.json') -Encoding utf8NoBOM
        Copy-Item -LiteralPath $localSource -Destination $portableTarget -Recurse

        $digest = InModuleScope ProjectManager.Core -Parameters @{ ProjectPath = $portableTarget } {
            Get-PHMCleanupDigest -ProjectPath $ProjectPath
        }
        $receipt = [ordered]@{
            schema_version = 1
            operation = 'checkin'
            project_id = $projectId
            source_path = $localSource
            target_path = $portableTarget
            source_manifest_digest = $digest
            transferred_at = '2026-08-14T00:00:00Z'
        }
        $receipt | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $portableTarget '项目交接\转移凭证.json') -Encoding utf8NoBOM

        $driveLetter = [System.IO.Path]::GetPathRoot($repositoryRoot).TrimEnd('\')
        [pscustomobject]@{
            LocalSource = $localSource
            PortableTarget = $portableTarget
            RepositoryRoot = $repositoryRoot
            DriveInfo = [pscustomobject]@{
                DriveLetter = $driveLetter
                VolumeLabel = 'TEST'
                FileSystem = 'NTFS'
                FriendlyName = 'TEST-DRIVE'
                HealthStatus = 'Healthy'
                OperationalStatus = 'OK'
                IsReadOnly = $false
                IsOffline = $false
                FreeBytes = 10GB
                VolumeSerial = 'SERIAL-1'
                DeviceId = 'DEVICE-1'
            }
        }
    }

    function Set-TestCheckinRecoveryMarker {
        param(
            [Parameter(Mandatory)]$Fixture,
            [int]$SchemaVersion = 1,
            [string]$ProjectId,
            [string]$SourcePath,
            [string]$TargetPath
        )

        $identity = Get-Content -LiteralPath (Join-Path $Fixture.PortableTarget '项目交接\项目身份.json') -Raw | ConvertFrom-Json
        $marker = [ordered]@{
            schema_version = $SchemaVersion
            operation = 'checkin-cleanup'
            state = 'prepared'
            project_id = if ($ProjectId) { $ProjectId } else { [string]$identity.project_id }
            source_path = if ($SourcePath) { $SourcePath } else { $Fixture.LocalSource }
            target_path = if ($TargetPath) { $TargetPath } else { $Fixture.PortableTarget }
            repository_root = $Fixture.RepositoryRoot
            prepared_at = '2026-08-14T00:00:00Z'
        }
        $markerPath = Join-Path $Fixture.PortableTarget '项目交接\归还清理恢复.json'
        $marker | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $markerPath -Encoding utf8NoBOM
        $markerPath
    }
}

Describe 'Project handoff manager 1.1.1 contract' {
    It 'reports version 1.1.1 without changing schema version' {
        $version = Get-PHMVersion
        $version.Version | Should -Be '1.1.1'
        $version.SchemaVersion | Should -Be 1
    }

    It 'keeps the four primary menu actions unchanged' {
        $menu = @(Get-PHMMenu)
        @($menu.Action) | Should -Be @('resume', 'pause', 'checkin', 'checkout')
    }
}

Describe 'Get-PHMProjectInventory incremental hashing' {
    It 'does not hash file contents during metadata-only previews' {
        $project = Join-Path $TestDrive 'metadata-project'
        New-Item -ItemType Directory -Path $project -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $project 'one.txt') -Value 'one' -Encoding utf8NoBOM

        $hashCalls = 0
        $inventory = Get-PHMProjectInventory -ProjectPath $project -MetadataOnly -HashProvider {
            param($path)
            $script:hashCalls++
            throw "Metadata-only inventory must not hash $path"
        }

        $inventory.FileCount | Should -Be 1
        $inventory.Files[0].Hash | Should -BeNullOrEmpty
        $hashCalls | Should -Be 0
    }

    It 'reuses hashes for unchanged files and rehashes only changed files' {
        $project = Join-Path $TestDrive 'baseline-project'
        New-Item -ItemType Directory -Path $project -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $project 'one.txt') -Value 'one' -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $project 'two.txt') -Value 'two' -Encoding utf8NoBOM

        $hashCalls = [System.Collections.Generic.List[string]]::new()
        $hashProvider = {
            param($path)
            $hashCalls.Add($path)
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        }

        $first = Get-PHMProjectInventory -ProjectPath $project -HashProvider $hashProvider
        $hashCalls.Count | Should -Be 2

        $hashCalls.Clear()
        $second = Get-PHMProjectInventory -ProjectPath $project -BaselineInventory $first -HashProvider $hashProvider
        $hashCalls.Count | Should -Be 0
        @($second.Files | Where-Object HashPolicy -eq 'reused').Count | Should -Be 2

        Set-Content -LiteralPath (Join-Path $project 'two.txt') -Value 'two-updated' -Encoding utf8NoBOM
        $hashCalls.Clear()
        $third = Get-PHMProjectInventory -ProjectPath $project -BaselineInventory $second -HashProvider $hashProvider
        $hashCalls.Count | Should -Be 1
        (Split-Path $hashCalls[0] -Leaf) | Should -Be 'two.txt'
        $third.ManifestDigest | Should -Not -Be $second.ManifestDigest
    }

    It 'keeps checkin previews metadata-only' {
        $project = Join-Path $TestDrive 'preview-project'
        $repository = Join-Path $TestDrive 'preview-repository'
        New-Item -ItemType Directory -Path $project, $repository -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $project 'payload.bin') -Value 'preview-content' -Encoding utf8NoBOM
        $driveLetter = [System.IO.Path]::GetPathRoot($repository).TrimEnd('\')
        $driveInfo = [pscustomobject]@{
            DriveLetter = $driveLetter
            VolumeLabel = 'TEST'
            FileSystem = 'NTFS'
            FriendlyName = 'TEST-DRIVE'
            HealthStatus = 'Healthy'
            OperationalStatus = 'OK'
            IsReadOnly = $false
            IsOffline = $false
            FreeBytes = 10GB
            VolumeSerial = 'SERIAL-1'
            DeviceId = 'DEVICE-1'
        }

        $plan = New-PHMCheckinPlan `
            -ProjectPath $project `
            -PortableRepositoryRoot $repository `
            -DriveInfo $driveInfo `
            -ProcessRecords @() `
            -PathSafetyProvider { param($path) $true } `
            -ExpectedDriveLetter $driveLetter `
            -ExpectedVolumeLabel 'TEST' `
            -ExpectedFileSystem 'NTFS' `
            -ExpectedFriendlyName 'TEST-DRIVE' `
            -ExpectedVolumeSerial 'SERIAL-1' `
            -ExpectedDeviceId 'DEVICE-1'

        $plan.Inventory.FileCount | Should -Be 1
        @($plan.Inventory.Files | Where-Object { $_.Hash }).Count | Should -Be 0
        @($plan.Inventory.Files | Where-Object HashPolicy -eq 'none').Count | Should -Be 1
    }
}

Describe 'Separate T9 cleanup after checkout' {
    It 'deletes only on the separate cleanup command even when the local project changed after checkout' {
        $fixture = New-TestCheckoutProject -Root (Join-Path $TestDrive 'confirmed-delete')
        $script:deletedPath = $null

        $result = Complete-PHMCheckoutCleanup `
            -PortableSourcePath $fixture.PortableSource `
            -LocalTargetPath $fixture.LocalTarget `
            -PortableRepositoryRoot $fixture.RepositoryRoot `
            -DriveInfo $fixture.DriveInfo `
            -ConfirmCleanup `
            -DeleteAction { param($path) $script:deletedPath = $path } `
            -PathSafetyProvider { param($path) $true } `
            -RegistryWriter { param($path, $record) $path } `
            -ComputerName 'TEST' `
            -ExpectedDriveLetter $fixture.DriveInfo.DriveLetter `
            -ExpectedVolumeLabel 'TEST' `
            -ExpectedFileSystem 'NTFS' `
            -ExpectedFriendlyName 'TEST-DRIVE' `
            -ExpectedVolumeSerial 'SERIAL-1' `
            -ExpectedDeviceId 'DEVICE-1'

        $result.Executed | Should -BeTrue
        $result.State | Should -Be 'local_active'
        $script:deletedPath | Should -Be $fixture.PortableSource
    }

    It 'still blocks deletion when the registered device identity is wrong' {
        $fixture = New-TestCheckoutProject -Root (Join-Path $TestDrive 'wrong-device')
        $script:deletedPath = $null

        $result = Complete-PHMCheckoutCleanup `
            -PortableSourcePath $fixture.PortableSource `
            -LocalTargetPath $fixture.LocalTarget `
            -PortableRepositoryRoot $fixture.RepositoryRoot `
            -DriveInfo $fixture.DriveInfo `
            -ConfirmCleanup `
            -DeleteAction { param($path) $script:deletedPath = $path } `
            -PathSafetyProvider { param($path) $true } `
            -ComputerName 'TEST' `
            -ExpectedDriveLetter $fixture.DriveInfo.DriveLetter `
            -ExpectedVolumeLabel 'TEST' `
            -ExpectedFileSystem 'NTFS' `
            -ExpectedFriendlyName 'TEST-DRIVE' `
            -ExpectedVolumeSerial 'SERIAL-1' `
            -ExpectedDeviceId 'WRONG-DEVICE'

        $result.Executed | Should -BeFalse
        $result.BlockedReason | Should -Match '设备或磁盘校验失败'
        $script:deletedPath | Should -BeNullOrEmpty
    }

    It 'still blocks deletion when the two checkout receipts do not match' {
        $fixture = New-TestCheckoutProject -Root (Join-Path $TestDrive 'receipt-mismatch')
        $targetReceiptPath = Join-Path $fixture.LocalTarget '项目交接\转移凭证.json'
        $targetReceipt = Get-Content -LiteralPath $targetReceiptPath -Raw | ConvertFrom-Json
        $targetReceipt.transferred_at = '2026-08-14T01:00:00Z'
        $targetReceipt | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $targetReceiptPath -Encoding utf8NoBOM

        $result = Complete-PHMCheckoutCleanup `
            -PortableSourcePath $fixture.PortableSource `
            -LocalTargetPath $fixture.LocalTarget `
            -PortableRepositoryRoot $fixture.RepositoryRoot `
            -DriveInfo $fixture.DriveInfo `
            -ConfirmCleanup `
            -DeleteAction { param($path) throw 'must not delete' } `
            -PathSafetyProvider { param($path) $true } `
            -ComputerName 'TEST' `
            -ExpectedDriveLetter $fixture.DriveInfo.DriveLetter `
            -ExpectedVolumeLabel 'TEST' `
            -ExpectedFileSystem 'NTFS' `
            -ExpectedFriendlyName 'TEST-DRIVE' `
            -ExpectedVolumeSerial 'SERIAL-1' `
            -ExpectedDeviceId 'DEVICE-1'

        $result.Executed | Should -BeFalse
        $result.BlockedReason | Should -Be '两端借出回执不一致。'
    }

    It 'repairs a partial T9 deletion without requiring full hashes' {
        $fixture = New-TestCheckoutProject -Root (Join-Path $TestDrive 'partial-delete')

        $cleanup = Complete-PHMCheckoutCleanup `
            -PortableSourcePath $fixture.PortableSource `
            -LocalTargetPath $fixture.LocalTarget `
            -PortableRepositoryRoot $fixture.RepositoryRoot `
            -DriveInfo $fixture.DriveInfo `
            -ConfirmCleanup `
            -DeleteAction {
                param($path)
                Remove-Item -LiteralPath (Join-Path $path 'payload.txt') -Force
                throw 'simulated directory handle failure'
            } `
            -PathSafetyProvider { param($path) $true } `
            -RegistryWriter { param($path, $record) $path } `
            -ComputerName 'TEST' `
            -ExpectedDriveLetter $fixture.DriveInfo.DriveLetter `
            -ExpectedVolumeLabel 'TEST' `
            -ExpectedFileSystem 'NTFS' `
            -ExpectedFriendlyName 'TEST-DRIVE' `
            -ExpectedVolumeSerial 'SERIAL-1' `
            -ExpectedDeviceId 'DEVICE-1'

        $cleanup.Executed | Should -BeFalse
        $cleanup.Recoverable | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $fixture.LocalTarget '项目交接\借出清理恢复.json') | Should -BeTrue

        $repair = Repair-PHMCheckoutCleanup `
            -LocalTargetPath $fixture.LocalTarget `
            -PortableRepositoryRoot $fixture.RepositoryRoot `
            -DriveInfo $fixture.DriveInfo `
            -PathSafetyProvider { param($path) $true } `
            -RegistryWriter { param($path, $record) $path } `
            -ComputerName 'TEST' `
            -ExpectedDriveLetter $fixture.DriveInfo.DriveLetter `
            -ExpectedVolumeLabel 'TEST' `
            -ExpectedFileSystem 'NTFS' `
            -ExpectedFriendlyName 'TEST-DRIVE' `
            -ExpectedVolumeSerial 'SERIAL-1' `
            -ExpectedDeviceId 'DEVICE-1'

        $repair.Executed | Should -BeTrue
        $repair.Repaired | Should -BeTrue
        Test-Path -LiteralPath $fixture.PortableSource | Should -BeFalse
    }

    It 'leaves a repair marker when registry finalization fails after deletion' {
        $fixture = New-TestCheckoutProject -Root (Join-Path $TestDrive 'registry-failure')

        $cleanup = Complete-PHMCheckoutCleanup `
            -PortableSourcePath $fixture.PortableSource `
            -LocalTargetPath $fixture.LocalTarget `
            -PortableRepositoryRoot $fixture.RepositoryRoot `
            -DriveInfo $fixture.DriveInfo `
            -ConfirmCleanup `
            -DeleteAction { param($path) Remove-Item -LiteralPath $path -Recurse -Force } `
            -PathSafetyProvider { param($path) $true } `
            -RegistryWriter { param($path, $record) throw 'simulated registry failure' } `
            -ComputerName 'TEST' `
            -ExpectedDriveLetter $fixture.DriveInfo.DriveLetter `
            -ExpectedVolumeLabel 'TEST' `
            -ExpectedFileSystem 'NTFS' `
            -ExpectedFriendlyName 'TEST-DRIVE' `
            -ExpectedVolumeSerial 'SERIAL-1' `
            -ExpectedDeviceId 'DEVICE-1'

        $cleanup.Executed | Should -BeTrue
        $cleanup.Recoverable | Should -BeTrue
        $cleanup.RegistryState | Should -Be 'pending_repair'
        Test-Path -LiteralPath $fixture.PortableSource | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $fixture.LocalTarget '项目交接\借出清理恢复.json') | Should -BeTrue
    }
}

Describe 'Invoke-PHMCheckin optimized transfer' {
    It 'copies and verifies a managed project with the optimized inventory path' {
        $project = Join-Path $TestDrive 'checkin-project'
        $repository = Join-Path $TestDrive 'checkin-repository'
        New-Item -ItemType Directory -Path $project, $repository -Force | Out-Null
        Initialize-PHMProject -ProjectPath $project -ComputerName 'TEST' | Out-Null
        Set-Content -LiteralPath (Join-Path $project 'payload.txt') -Value 'verified-payload' -Encoding utf8NoBOM

        $driveLetter = [System.IO.Path]::GetPathRoot($repository).TrimEnd('\')
        $driveInfo = [pscustomobject]@{
            DriveLetter = $driveLetter
            VolumeLabel = 'TEST'
            FileSystem = 'NTFS'
            FriendlyName = 'TEST-DRIVE'
            HealthStatus = 'Healthy'
            OperationalStatus = 'OK'
            IsReadOnly = $false
            IsOffline = $false
            FreeBytes = 10GB
            VolumeSerial = 'SERIAL-1'
            DeviceId = 'DEVICE-1'
        }

        $result = Invoke-PHMCheckin `
            -ProjectPath $project `
            -PortableRepositoryRoot $repository `
            -DriveInfo $driveInfo `
            -ProcessRecords @() `
            -ConfirmTransfer `
            -CopyAction {
                param($source, $destination)
                New-Item -ItemType Directory -Path $destination -Force | Out-Null
                Get-ChildItem -LiteralPath $source -Force | Copy-Item -Destination $destination -Recurse -Force
                [pscustomobject]@{ Success = $true; ExitCode = 0; Message = '' }
            } `
            -RegistryWriter { param($path, $record) $path } `
            -PathSafetyProvider { param($path) $true } `
            -ComputerName 'TEST' `
            -ExpectedDriveLetter $driveLetter `
            -ExpectedVolumeLabel 'TEST' `
            -ExpectedFileSystem 'NTFS' `
            -ExpectedFriendlyName 'TEST-DRIVE' `
            -ExpectedVolumeSerial 'SERIAL-1' `
            -ExpectedDeviceId 'DEVICE-1'

        $result.Executed | Should -BeTrue
        $result.Verified | Should -BeTrue
        $result.Verification.IsMatch | Should -BeTrue
        Test-Path -LiteralPath $result.OfficialPath | Should -BeTrue
        Test-Path -LiteralPath $result.ReceivingPath | Should -BeFalse
    }
}

Describe 'Invoke-PHMCheckout optimized transfer' {
    It 'copies and verifies a portable project while retaining the T9 source after transfer confirmation' {
        $repository = Join-Path $TestDrive 'checkout-repository'
        $portableProject = Join-Path $repository '暂停项目\portable-project'
        $localCurrentRoot = Join-Path $TestDrive 'local-current'
        $localReceivingRoot = Join-Path $TestDrive 'local-receiving'
        New-Item -ItemType Directory -Path $portableProject, $localCurrentRoot, $localReceivingRoot -Force | Out-Null
        Initialize-PHMProject -ProjectPath $portableProject -ComputerName 'TEST' -InitialState 'on_t9' | Out-Null
        Set-Content -LiteralPath (Join-Path $portableProject 'payload.txt') -Value 'portable-payload' -Encoding utf8NoBOM

        $driveLetter = [System.IO.Path]::GetPathRoot($repository).TrimEnd('\')
        $driveInfo = [pscustomobject]@{
            DriveLetter = $driveLetter
            VolumeLabel = 'TEST'
            FileSystem = 'NTFS'
            FriendlyName = 'TEST-DRIVE'
            HealthStatus = 'Healthy'
            OperationalStatus = 'OK'
            IsReadOnly = $false
            IsOffline = $false
            FreeBytes = 10GB
            VolumeSerial = 'SERIAL-1'
            DeviceId = 'DEVICE-1'
        }

        $result = Invoke-PHMCheckout `
            -PortableProjectPath $portableProject `
            -PortableRepositoryRoot $repository `
            -LocalCurrentRoot $localCurrentRoot `
            -LocalReceivingRoot $localReceivingRoot `
            -LocalFreeBytes 10GB `
            -DriveInfo $driveInfo `
            -ConfirmTransfer `
            -CopyAction {
                param($source, $destination)
                New-Item -ItemType Directory -Path $destination -Force | Out-Null
                Get-ChildItem -LiteralPath $source -Force | Copy-Item -Destination $destination -Recurse -Force
                [pscustomobject]@{ Success = $true; ExitCode = 0; Message = '' }
            } `
            -RegistryWriter { param($path, $record) $path } `
            -PathSafetyProvider { param($path) $true } `
            -ComputerName 'TEST' `
            -ExpectedDriveLetter $driveLetter `
            -ExpectedVolumeLabel 'TEST' `
            -ExpectedFileSystem 'NTFS' `
            -ExpectedFriendlyName 'TEST-DRIVE' `
            -ExpectedVolumeSerial 'SERIAL-1' `
            -ExpectedDeviceId 'DEVICE-1'

        $result.Executed | Should -BeTrue
        $result.Verified | Should -BeTrue
        $result.Verification.IsMatch | Should -BeTrue
        $result.CleanupRequired | Should -BeTrue
        Test-Path -LiteralPath $result.OfficialPath | Should -BeTrue
        Test-Path -LiteralPath $result.SourcePath | Should -BeTrue
        Test-Path -LiteralPath $result.ContinuePromptPath | Should -BeTrue
    }
}

Describe 'Handoff record result summaries' {
    It 'writes the caller supplied result instead of a fixed local-only statement' {
        $project = Join-Path $TestDrive 'handoff-result'
        New-Item -ItemType Directory -Path $project | Out-Null
        Initialize-PHMProject -ProjectPath $project -ComputerName 'TEST-PC' | Out-Null

        InModuleScope ProjectManager.Core -Parameters @{ ProjectPath = $project } {
            Add-PHMHandoffRecord `
                -ProjectPath $ProjectPath `
                -ComputerName 'TEST-PC' `
                -ActionLabel '归还到移动硬盘' `
                -Changes (New-PHMEmptyChanges) `
                -ResultSummary '移动硬盘目标已校验；本机来源仍保留。' | Out-Null
        }

        $report = Get-Content -LiteralPath (Join-Path $project '项目交接\项目交接报告.md') -Raw
        $report | Should -Match '结果：移动硬盘目标已校验；本机来源仍保留。'
        $report | Should -Not -Match '结果：项目仍在本机；未使用 T9；未删除文件。'
    }
}

Describe 'AI-neutral continue prompt' {
    It 'can be used by any AI software without product-specific wording' {
        $project = Join-Path $TestDrive 'neutral-prompt'
        New-Item -ItemType Directory -Path $project | Out-Null
        Initialize-PHMProject -ProjectPath $project -ComputerName 'TEST-PC' | Out-Null

        $promptPath = Write-PHMContinuePrompt -ProjectPath $project
        $content = Get-Content -LiteralPath $promptPath -Raw

        $content | Should -Match '# 在新的 AI 软件或本地开发环境中继续此项目'
        $content | Should -Match '请把当前项目文件夹作为工作区'
        $content | Should -Match '项目交接/项目交接报告.md'
        $content | Should -Match '项目交接/环境清单.json'
        $content | Should -Not -Match '新 Codex 任务'
    }
}

Describe 'Checkin cleanup recovery' {
    It 'leaves a repair marker when registry update fails after source deletion' {
        $fixture = New-TestCheckinProject -Root (Join-Path $TestDrive 'checkin-recovery-marker')
        $script:deleteCalled = $false
        $script:markerExistedBeforeDelete = $false

        $result = Complete-PHMCheckinCleanup `
            -SourcePath $fixture.LocalSource `
            -TargetPath $fixture.PortableTarget `
            -PortableRepositoryRoot $fixture.RepositoryRoot `
            -DriveInfo $fixture.DriveInfo `
            -ConfirmCleanup `
            -ExpectedDriveLetter $fixture.DriveInfo.DriveLetter `
            -ExpectedVolumeLabel 'TEST' `
            -ExpectedFileSystem 'NTFS' `
            -ExpectedFriendlyName 'TEST-DRIVE' `
            -ExpectedVolumeSerial 'SERIAL-1' `
            -ExpectedDeviceId 'DEVICE-1' `
            -DeleteAction {
                param($path)
                $script:deleteCalled = $true
                $script:markerExistedBeforeDelete = Test-Path -LiteralPath (Join-Path $fixture.PortableTarget '项目交接\归还清理恢复.json') -PathType Leaf
                Remove-Item -LiteralPath $path -Recurse -Force
            } `
            -RegistryWriter { param($path, $record) throw 'simulated registry failure' }

        $result.Executed | Should -BeTrue
        $result.Recoverable | Should -BeTrue
        $result.RegistryState | Should -Be 'pending_repair'
        $script:deleteCalled | Should -BeTrue
        $script:markerExistedBeforeDelete | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $fixture.PortableTarget '项目交接\归还清理恢复.json') | Should -BeTrue
    }

    It 'blocks without mutating target state while the receipt source still exists' {
        $fixture = New-TestCheckinProject -Root (Join-Path $TestDrive 'checkin-source-present')
        $markerPath = Set-TestCheckinRecoveryMarker -Fixture $fixture
        $identityPath = Join-Path $fixture.PortableTarget '项目交接\项目身份.json'
        $reportPath = Join-Path $fixture.PortableTarget '项目交接\项目交接报告.md'
        $identityBefore = Get-Content -LiteralPath $identityPath -Raw
        $reportBefore = Get-Content -LiteralPath $reportPath -Raw

        $repair = Repair-PHMCheckinCleanup `
            -PortableTargetPath $fixture.PortableTarget `
            -PortableRepositoryRoot $fixture.RepositoryRoot `
            -DriveInfo $fixture.DriveInfo `
            -ExpectedDriveLetter $fixture.DriveInfo.DriveLetter `
            -ExpectedVolumeLabel 'TEST' `
            -ExpectedFileSystem 'NTFS' `
            -ExpectedFriendlyName 'TEST-DRIVE' `
            -ExpectedVolumeSerial 'SERIAL-1' `
            -ExpectedDeviceId 'DEVICE-1' `
            -RegistryWriter { throw 'registry must not be called' }

        $repair.Executed | Should -BeFalse
        $repair.BlockedReason | Should -Match '正常归还清理流程'
        Test-Path -LiteralPath $fixture.LocalSource | Should -BeTrue
        Test-Path -LiteralPath $markerPath | Should -BeTrue
        (Get-Content -LiteralPath $identityPath -Raw) | Should -BeExactly $identityBefore
        (Get-Content -LiteralPath $reportPath -Raw) | Should -BeExactly $reportBefore
    }

    It 'rejects an unsupported recovery marker schema before using its paths' {
        $fixture = New-TestCheckinProject -Root (Join-Path $TestDrive 'checkin-marker-schema')
        Set-TestCheckinRecoveryMarker -Fixture $fixture -SchemaVersion 2 | Out-Null

        {
            Repair-PHMCheckinCleanup `
                -PortableTargetPath $fixture.PortableTarget `
                -PortableRepositoryRoot $fixture.RepositoryRoot `
                -DriveInfo $fixture.DriveInfo `
                -ExpectedDriveLetter $fixture.DriveInfo.DriveLetter `
                -ExpectedVolumeLabel 'TEST' `
                -ExpectedFileSystem 'NTFS' `
                -ExpectedFriendlyName 'TEST-DRIVE' `
                -ExpectedVolumeSerial 'SERIAL-1' `
                -ExpectedDeviceId 'DEVICE-1'
        } | Should -Throw '*版本*'
    }

    It 'rejects a marker source path that does not match the checkin receipt' {
        $fixture = New-TestCheckinProject -Root (Join-Path $TestDrive 'checkin-marker-receipt-mismatch')
        $wrongSource = Join-Path (Split-Path $fixture.LocalSource -Parent) 'missing-source'
        Set-TestCheckinRecoveryMarker -Fixture $fixture -SourcePath $wrongSource | Out-Null

        {
            Repair-PHMCheckinCleanup `
                -PortableTargetPath $fixture.PortableTarget `
                -PortableRepositoryRoot $fixture.RepositoryRoot `
                -DriveInfo $fixture.DriveInfo `
                -ExpectedDriveLetter $fixture.DriveInfo.DriveLetter `
                -ExpectedVolumeLabel 'TEST' `
                -ExpectedFileSystem 'NTFS' `
                -ExpectedFriendlyName 'TEST-DRIVE' `
                -ExpectedVolumeSerial 'SERIAL-1' `
                -ExpectedDeviceId 'DEVICE-1'
        } | Should -Throw '*转移凭证*'
    }

    It 'repairs target state without deleting or copying again' {
        $fixture = New-TestCheckinProject -Root (Join-Path $TestDrive 'checkin-repair')
        $script:registryWrites = 0

        $first = Complete-PHMCheckinCleanup `
            -SourcePath $fixture.LocalSource `
            -TargetPath $fixture.PortableTarget `
            -PortableRepositoryRoot $fixture.RepositoryRoot `
            -DriveInfo $fixture.DriveInfo `
            -ConfirmCleanup `
            -ExpectedDriveLetter $fixture.DriveInfo.DriveLetter `
            -ExpectedVolumeLabel 'TEST' `
            -ExpectedFileSystem 'NTFS' `
            -ExpectedFriendlyName 'TEST-DRIVE' `
            -ExpectedVolumeSerial 'SERIAL-1' `
            -ExpectedDeviceId 'DEVICE-1' `
            -DeleteAction { param($path) Remove-Item -LiteralPath $path -Recurse -Force } `
            -RegistryWriter { param($path, $record) throw 'simulated registry failure' }

        $first.Recoverable | Should -BeTrue

        $repair = Repair-PHMCheckinCleanup `
            -PortableTargetPath $fixture.PortableTarget `
            -PortableRepositoryRoot $fixture.RepositoryRoot `
            -DriveInfo $fixture.DriveInfo `
            -ExpectedDriveLetter $fixture.DriveInfo.DriveLetter `
            -ExpectedVolumeLabel 'TEST' `
            -ExpectedFileSystem 'NTFS' `
            -ExpectedFriendlyName 'TEST-DRIVE' `
            -ExpectedVolumeSerial 'SERIAL-1' `
            -ExpectedDeviceId 'DEVICE-1' `
            -RegistryWriter { param($path, $record) $script:registryWrites++ }

        $repair.Executed | Should -BeTrue
        $repair.Repaired | Should -BeTrue
        $script:registryWrites | Should -Be 1
        Test-Path -LiteralPath (Join-Path $fixture.PortableTarget '项目交接\归还清理恢复.json') | Should -BeFalse
    }

    It 'does not duplicate identity or report updates across a failed repair retry' {
        $fixture = New-TestCheckinProject -Root (Join-Path $TestDrive 'checkin-idempotent-repair')
        $first = Complete-PHMCheckinCleanup `
            -SourcePath $fixture.LocalSource `
            -TargetPath $fixture.PortableTarget `
            -PortableRepositoryRoot $fixture.RepositoryRoot `
            -DriveInfo $fixture.DriveInfo `
            -ConfirmCleanup `
            -ExpectedDriveLetter $fixture.DriveInfo.DriveLetter `
            -ExpectedVolumeLabel 'TEST' `
            -ExpectedFileSystem 'NTFS' `
            -ExpectedFriendlyName 'TEST-DRIVE' `
            -ExpectedVolumeSerial 'SERIAL-1' `
            -ExpectedDeviceId 'DEVICE-1' `
            -DeleteAction { param($path) Remove-Item -LiteralPath $path -Recurse -Force } `
            -RegistryWriter { throw 'initial registry failure' }
        $first.Recoverable | Should -BeTrue

        $identityPath = Join-Path $fixture.PortableTarget '项目交接\项目身份.json'
        $reportPath = Join-Path $fixture.PortableTarget '项目交接\项目交接报告.md'
        $revisionBeforeRetry = (Get-Content -LiteralPath $identityPath -Raw | ConvertFrom-Json).revision
        $resultLineCountBeforeRetry = @((Get-Content -LiteralPath $reportPath) | Where-Object { $_ -eq '- 结果：本机来源已按独立确认清理；移动硬盘目标为正式完整副本。' }).Count

        {
            Repair-PHMCheckinCleanup `
                -PortableTargetPath $fixture.PortableTarget `
                -PortableRepositoryRoot $fixture.RepositoryRoot `
                -DriveInfo $fixture.DriveInfo `
                -ExpectedDriveLetter $fixture.DriveInfo.DriveLetter `
                -ExpectedVolumeLabel 'TEST' `
                -ExpectedFileSystem 'NTFS' `
                -ExpectedFriendlyName 'TEST-DRIVE' `
                -ExpectedVolumeSerial 'SERIAL-1' `
                -ExpectedDeviceId 'DEVICE-1' `
                -RegistryWriter { throw 'retry registry failure' }
        } | Should -Throw '*retry registry failure*'

        $repair = Repair-PHMCheckinCleanup `
            -PortableTargetPath $fixture.PortableTarget `
            -PortableRepositoryRoot $fixture.RepositoryRoot `
            -DriveInfo $fixture.DriveInfo `
            -ExpectedDriveLetter $fixture.DriveInfo.DriveLetter `
            -ExpectedVolumeLabel 'TEST' `
            -ExpectedFileSystem 'NTFS' `
            -ExpectedFriendlyName 'TEST-DRIVE' `
            -ExpectedVolumeSerial 'SERIAL-1' `
            -ExpectedDeviceId 'DEVICE-1' `
            -RegistryWriter { param($path, $record) $path }

        $repair.Repaired | Should -BeTrue
        (Get-Content -LiteralPath $identityPath -Raw | ConvertFrom-Json).revision | Should -Be $revisionBeforeRetry
        @((Get-Content -LiteralPath $reportPath) | Where-Object { $_ -eq '- 结果：本机来源已按独立确认清理；移动硬盘目标为正式完整副本。' }).Count | Should -Be $resultLineCountBeforeRetry
    }

    It 'routes a blocked checkin repair and reports the blocking reason truthfully' {
        $fixture = New-TestCheckinProject -Root (Join-Path $TestDrive 'checkin-repair-route')
        Set-TestCheckinRecoveryMarker -Fixture $fixture | Out-Null
        $configPath = Join-Path $TestDrive 'checkin-repair-route-config.json'
        [ordered]@{
            schemaVersion = 1
            portableDrive = [ordered]@{
                repositoryRoot = $fixture.RepositoryRoot
                driveLetter = $fixture.DriveInfo.DriveLetter
                volumeLabel = 'TEST'
                requiredFileSystem = 'NTFS'
                friendlyName = 'TEST-DRIVE'
                volumeSerial = 'SERIAL-1'
                deviceId = 'DEVICE-1'
            }
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $configPath -Encoding utf8NoBOM

        $entryPath = Join-Path $PSScriptRoot '..\project-handoff-manager\scripts\project_manager.ps1'
        $parameters = @{
            Action = 'repair'
            TargetPath = $fixture.PortableTarget
            PortableRepositoryRoot = $fixture.RepositoryRoot
            ConfigPath = $configPath
            DriveInfo = $fixture.DriveInfo
            ComputerName = 'TEST'
        }
        $job = Start-Job -ScriptBlock { param($path, $arguments) & $path @arguments } -ArgumentList $entryPath, $parameters
        $raw = Receive-Job -Job $job -Wait -AutoRemoveJob
        $envelope = ($raw -join [Environment]::NewLine) | ConvertFrom-Json

        $envelope.action | Should -Be 'repair'
        $envelope.repairKind | Should -Be 'checkin-cleanup'
        $envelope.executed | Should -BeFalse
        $envelope.message | Should -Match '本机来源仍存在'
        $envelope.message | Should -Not -Match '恢复已完成'
    }
}
