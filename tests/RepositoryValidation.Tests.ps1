Describe '仓库验证工具' {
    BeforeAll {
        $repoRoot = Split-Path $PSScriptRoot -Parent
        $validator = Join-Path $repoRoot 'scripts\validate_skill.ps1'
        $skillRoot = Join-Path $repoRoot 'project-handoff-manager'
    }

    It '接受当前有效 Skill' {
        Test-Path -LiteralPath $validator | Should -BeTrue
        & $validator -SkillPath $skillRoot | Should -BeTrue
    }

    It '拒绝缺少 SKILL.md 的目录' {
        $empty = Join-Path $TestDrive 'empty-skill'
        New-Item -ItemType Directory -Path $empty | Out-Null

        & $validator -SkillPath $empty | Should -BeFalse
    }
}
