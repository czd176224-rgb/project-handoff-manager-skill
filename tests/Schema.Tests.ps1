Describe '项目管家数据契约' {
    BeforeAll {
        $schemaRoot = Join-Path (Split-Path $PSScriptRoot -Parent) 'project-handoff-manager\assets\schema'
    }

    It '包含三个可解析且版本化的 JSON Schema' {
        $names = @('project-identity.schema.json', 'environment.schema.json', 'registry.schema.json')

        foreach ($name in $names) {
            $path = Join-Path $schemaRoot $name
            Test-Path -LiteralPath $path | Should -BeTrue
            $schema = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            $schema.'$schema' | Should -Be 'https://json-schema.org/draft/2020-12/schema'
            $schema.additionalProperties | Should -BeFalse
        }
    }
}
