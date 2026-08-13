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

    It '未实现操作不会执行文件变更' {
        $result = & $entryPath -Action checkout | ConvertFrom-Json

        $result.executed | Should -BeFalse
        $result.message | Should -Match '尚未实现'
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
        $drive = [pscustomobject]@{
            DriveLetter='T:';VolumeLabel='T9';FileSystem='NTFS';HealthStatus='Healthy';OperationalStatus='OK'
            IsReadOnly=$false;IsOffline=$false;FreeBytes=100GB;FriendlyName='Samsung PSSD T9';VolumeSerial='TEST';DeviceId='TEST'
        }

        $preview = & $entryPath -Action checkin -ProjectPath $project -PortableRepositoryRoot $repository -DriveInfo $drive | ConvertFrom-Json

        $preview.executed | Should -BeFalse
        $preview.requiresConfirmation | Should -BeTrue
        $preview.result.Plan.SourcePath | Should -Be (Get-Item $project).FullName
        Test-Path -LiteralPath $preview.result.OfficialPath | Should -BeFalse
        Test-Path -LiteralPath $project | Should -BeTrue
    }
}
