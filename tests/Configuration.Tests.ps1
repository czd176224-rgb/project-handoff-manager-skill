Describe '项目管家配置加载' {
    BeforeAll {
        $modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'project-handoff-manager\scripts\ProjectManager.Core.psm1'
        Import-Module $modulePath -Force
    }

    It '读取本机有限根目录和移动盘项目仓库' {
        $path = Join-Path $TestDrive 'config.json'
        @{
            schemaVersion = 1
            local = @{ currentProjectsRoot = 'D:\项目\当前'; receivingRoot = 'D:\项目\正在接收'; pausedProjectsRoot = 'D:\项目\暂停'; additionalRoots = @('E:\其他项目') }
            portableDrive = @{ driveLetter = 'T:'; repositoryRoot = 'T:\项目仓库' }
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path -Encoding utf8

        $config = Read-PHMConfig -Path $path

        $config.LocalRoots | Should -Be @('D:\项目\当前', 'D:\项目\暂停', 'E:\其他项目')
        $config.LocalCurrentRoot | Should -Be 'D:\项目\当前'
        $config.LocalReceivingRoot | Should -Be 'D:\项目\正在接收'
        $config.PortableRepositoryRoot | Should -Be 'T:\项目仓库'
    }

    It '拒绝不支持的配置版本' {
        $path = Join-Path $TestDrive 'future.json'
        '{"schemaVersion":99}' | Set-Content -LiteralPath $path -Encoding utf8

        { Read-PHMConfig -Path $path } | Should -Throw '*配置版本*'
    }
}
