Describe '项目管家核心模块' {
    BeforeAll {
        $modulePath = Join-Path $PSScriptRoot '..\project-handoff-manager\scripts\ProjectManager.Core.psm1'
    }

    It '能够加载并返回结构化版本信息' {
        Test-Path -LiteralPath $modulePath | Should -BeTrue
        Import-Module $modulePath -Force

        $versionInfo = Get-PHMVersion

        $versionInfo.Name | Should -Be 'project-handoff-manager'
        $versionInfo.Version | Should -Match '^0\.1\.0$'
        $versionInfo.SchemaVersion | Should -Be 1
    }

    It '返回四项中文主菜单且全部默认预览' {
        Import-Module $modulePath -Force

        $menu = Get-PHMMenu

        $menu.Count | Should -Be 4
        $menu.Name | Should -Be @(
            '开始或继续当前项目'
            '暂停当前项目'
            '将当前项目归还到 T9'
            '从 T9 借出项目到本机'
        )
        $menu.RequiresPreview | Should -Not -Contain $false
        ($menu | Where-Object Action -eq 'resume').Implemented | Should -BeTrue
        ($menu | Where-Object Action -in @('pause', 'checkin', 'checkout')).Implemented | Should -Not -Contain $true
    }
}
