Describe '借出后的环境与依赖恢复检查' {
    BeforeAll {
        $modulePath=Join-Path (Split-Path $PSScriptRoot -Parent) 'project-handoff-manager\scripts\ProjectManager.Core.psm1'
        Import-Module $modulePath -Force
    }

    It '识别可疑的可复制 Python venv 并给出基于锁文件的重建命令' {
        $project=Join-Path $TestDrive 'Python项目'
        New-Item -ItemType Directory -Path (Join-Path $project '.venv') -Force|Out-Null
        'home = Z:\MissingPython'|Set-Content -LiteralPath (Join-Path $project '.venv\pyvenv.cfg') -Encoding utf8
        'demo==1.0'|Set-Content -LiteralPath (Join-Path $project 'requirements.lock') -Encoding utf8

        $result=Test-PHMProjectEnvironment -ProjectPath $project

        $result.PythonEnvironment.Status|Should -Be 'needs_rebuild'
        $result.PythonEnvironment.RecoveryCommand|Should -Match 'requirements.lock'
    }

    It '记录 node_modules、锁文件、项目缓存和离线依赖是否随项目存在' {
        $project=Join-Path $TestDrive 'Node项目'
        New-Item -ItemType Directory -Path (Join-Path $project 'node_modules\demo'),(Join-Path $project '项目缓存'),(Join-Path $project '离线依赖') -Force|Out-Null
        '{}'|Set-Content -LiteralPath (Join-Path $project 'package-lock.json') -Encoding utf8
        'x'|Set-Content -LiteralPath (Join-Path $project 'node_modules\demo\index.js') -Encoding utf8
        'c'|Set-Content -LiteralPath (Join-Path $project '项目缓存\cache') -Encoding utf8
        'd'|Set-Content -LiteralPath (Join-Path $project '离线依赖\package.tgz') -Encoding utf8

        $result=Test-PHMProjectEnvironment -ProjectPath $project

        $result.NodeEnvironment.DependenciesPresent|Should -BeTrue
        $result.NodeEnvironment.LockFile|Should -Be 'package-lock.json'
        $result.ProjectCache.FileCount|Should -Be 1
        $result.OfflineDependencies.FileCount|Should -Be 1
    }

    It '生成可直接交给任意 AI 软件的中文继续提示词' {
        $project=Join-Path $TestDrive '提示词项目'
        New-Item -ItemType Directory -Path $project -Force|Out-Null
        Initialize-PHMProject -ProjectPath $project|Out-Null

        $path=Write-PHMContinuePrompt -ProjectPath $project
        $content=Get-Content -LiteralPath $path -Raw

        $content|Should -Match '项目交接报告.md'
        $content|Should -Match '环境清单.json'
        $content|Should -Match '继续上次未完成'
    }
}
