Describe 'Project handoff skill presentation contract' {
    BeforeAll {
        $skillRoot = Join-Path (Split-Path $PSScriptRoot -Parent) 'project-handoff-manager'
        $skill = Get-Content -LiteralPath (Join-Path $skillRoot 'SKILL.md') -Raw
        $agent = Get-Content -LiteralPath (Join-Path $skillRoot 'agents\openai.yaml') -Raw
    }

    It 'keeps JSON as the machine interface' {
        $skill | Should -Match '脚本 JSON'
    }

    It 'requires concise Chinese user-facing output' {
        $skill | Should -Match '简洁中文'
        $skill | Should -Match '下一步'
        $agent | Should -Match '不要直接展示原始 JSON'
    }

    It 'documents the stable 1.1.1 compatibility boundary' {
        $skill | Should -Match '稳定版 `1\.1\.1`'
        $skill | Should -Match '保留原有 JSON 接口、四项菜单和迁移步骤'
    }

    It 'tells the user to repair an interrupted checkin cleanup instead of claiming completion' {
        $entry = Get-Content -LiteralPath (Join-Path $skillRoot 'scripts\project_manager.ps1') -Raw
        $entry | Should -Match '\$cleanup\.Recoverable'
        $entry | Should -Match '请对 T9 目标项目运行 repair'
    }
}
