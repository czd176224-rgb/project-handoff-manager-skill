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
        $result = & $entryPath -Action checkin | ConvertFrom-Json

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
}
