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
}
