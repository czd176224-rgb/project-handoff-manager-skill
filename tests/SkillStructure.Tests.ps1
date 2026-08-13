Describe 'Codex Skill 公开包结构' {
    BeforeAll {
        $repoRoot = Split-Path $PSScriptRoot -Parent
        $skillRoot = Join-Path $repoRoot 'project-handoff-manager'
    }

    It '包含 Skill 必需入口和代理元数据' {
        @(
            'SKILL.md'
            'agents\openai.yaml'
            'scripts\project_manager.ps1'
            'scripts\ProjectManager.Core.psm1'
        ) | ForEach-Object {
            Test-Path -LiteralPath (Join-Path $skillRoot $_) | Should -BeTrue
        }
    }

    It '包含标准项目的五个中文目录' {
        @('输入资料', '输出成果', '项目缓存', '离线依赖', '项目交接') | ForEach-Object {
            Test-Path -LiteralPath (Join-Path $skillRoot "assets\standard-project\$_") | Should -BeTrue
        }
    }

    It 'SKILL 描述覆盖核心触发场景和安全边界' {
        $content = Get-Content -LiteralPath (Join-Path $skillRoot 'SKILL.md') -Raw

        $content | Should -Match '归还'
        $content | Should -Match '借出'
        $content | Should -Match '暂停'
        $content | Should -Match 'Codex.*数据库'
    }
}
