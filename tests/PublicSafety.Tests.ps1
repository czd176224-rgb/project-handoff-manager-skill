Describe '公开仓库安全边界' {
    BeforeAll {
        $repoRoot = Split-Path $PSScriptRoot -Parent
    }

    It '示例配置不包含真实用户绝对路径' {
        $configPath = Join-Path $repoRoot 'config.example.json'
        Test-Path -LiteralPath $configPath | Should -BeTrue
        $content = Get-Content -LiteralPath $configPath -Raw

        $content | Should -Not -Match 'C:\\Users\\24927'
        $content | Should -Not -Match 'Documents\\Codex'
    }

    It '项目身份模式禁止未声明字段' {
        $schemaPath = Join-Path $repoRoot 'project-handoff-manager\assets\schema\project-identity.schema.json'
        Test-Path -LiteralPath $schemaPath | Should -BeTrue
        $schema = Get-Content -LiteralPath $schemaPath -Raw | ConvertFrom-Json

        $schema.additionalProperties | Should -BeFalse
        $schema.required | Should -Contain 'project_id'
        $schema.required | Should -Contain 'official_location'
        $schema.required | Should -Contain 'state'
    }
}
