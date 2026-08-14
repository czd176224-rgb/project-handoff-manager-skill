Describe '继续项目与交接信息同步' {
    BeforeAll {
        $modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'project-handoff-manager\scripts\ProjectManager.Core.psm1'
        Import-Module $modulePath -Force

        function Set-OldProjectTimestamp {
            param([string]$ProjectPath)
            $identityPath = Join-Path $ProjectPath '项目交接\项目身份.json'
            $identity = Get-Content -LiteralPath $identityPath -Raw | ConvertFrom-Json
            $identity.last_updated = '2020-01-01T00:00:00Z'
            $identity | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $identityPath -Encoding utf8
        }
    }

    It '继续项目时识别新材料、新输出和未分类变化并更新身份' {
        $project = Join-Path $TestDrive '继续项目'
        New-Item -ItemType Directory -Path $project -Force | Out-Null
        Initialize-PHMProject -ProjectPath $project -ComputerName 'OLD-PC' | Out-Null
        Set-OldProjectTimestamp -ProjectPath $project
        Set-Content -LiteralPath (Join-Path $project '输入资料\新材料.pdf') -Value 'input' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $project '输出成果\新成果.pptx') -Value 'output' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $project '根目录文件.txt') -Value 'other' -Encoding utf8

        $result = Resume-PHMProject -ProjectPath $project -ComputerName 'NEW-PC'
        $identity = Get-Content -LiteralPath (Join-Path $project '项目交接\项目身份.json') -Raw | ConvertFrom-Json

        $result.Changes.NewMaterials.RelativePath | Should -Contain '输入资料\新材料.pdf'
        $result.Changes.NewOutputs.RelativePath | Should -Contain '输出成果\新成果.pptx'
        $result.Changes.Unclassified.RelativePath | Should -Contain '根目录文件.txt'
        $identity.state | Should -Be 'local_active'
        $identity.last_computer | Should -Be 'NEW-PC'
        $identity.last_operation | Should -Be 'resume'
        $identity.revision | Should -BeGreaterThan 1
    }

    It '继续项目时更新环境清单并记录锁文件、缓存和离线依赖状态' {
        $project = Join-Path $TestDrive '环境项目'
        New-Item -ItemType Directory -Path $project -Force | Out-Null
        Initialize-PHMProject -ProjectPath $project -ComputerName 'TEST-PC' | Out-Null
        Set-Content -LiteralPath (Join-Path $project 'package-lock.json') -Value '{}' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $project '项目缓存\cache.bin') -Value 'cache' -Encoding utf8
        Set-Content -LiteralPath (Join-Path $project '离线依赖\package.zip') -Value 'dependency' -Encoding utf8

        $result = Resume-PHMProject -ProjectPath $project -ComputerName 'TEST-PC'
        $environment = Get-Content -LiteralPath (Join-Path $project '项目交接\环境清单.json') -Raw | ConvertFrom-Json

        $environment.capturedAt | Should -Not -BeNullOrEmpty
        $environment.tools.name | Should -Contain 'PowerShell'
        $environment.dependencyFiles | Should -Contain 'package-lock.json'
        $environment.projectCache.fileCount | Should -Be 1
        $environment.offlineDependencies.fileCount | Should -Be 1
        $result.EnvironmentPath | Should -Be (Join-Path $project '项目交接\环境清单.json')
    }

    It '继续和记录进度都会追加可供任意 AI 软件读取的交接记录' {
        $project = Join-Path $TestDrive '记录项目'
        New-Item -ItemType Directory -Path $project -Force | Out-Null
        Initialize-PHMProject -ProjectPath $project -ComputerName 'TEST-PC' | Out-Null

        Resume-PHMProject -ProjectPath $project -ComputerName 'TEST-PC' | Out-Null
        $checkpoint = Save-PHMCheckpoint -ProjectPath $project -ComputerName 'TEST-PC' -CurrentTask '完善项目扫描' -NextStep '编写冲突测试' -ValidationResult '12 项测试通过'
        $report = Get-Content -LiteralPath (Join-Path $project '项目交接\项目交接报告.md') -Raw

        $report | Should -Match '开始或继续'
        $report | Should -Match '记录当前进度'
        $report | Should -Match '完善项目扫描'
        $report | Should -Match '编写冲突测试'
        $report | Should -Match '12 项测试通过'
        $report | Should -Match '## 当前任务\r?\n\r?\n完善项目扫描'
        $report | Should -Match '## 下一步\r?\n\r?\n编写冲突测试'
        $report | Should -Match '## 最后一次验证结果\r?\n\r?\n12 项测试通过'
        $checkpoint.StoppedProcesses | Should -Be 0
        $checkpoint.UsedPortableDrive | Should -BeFalse
        $checkpoint.DeletedFiles | Should -Be 0
    }

    It '开始新的工作事项时将原当前任务移入未完成队列且不改变项目编号' {
        $project = Join-Path $TestDrive '新任务项目'
        New-Item -ItemType Directory -Path $project -Force | Out-Null
        Initialize-PHMProject -ProjectPath $project -ComputerName 'TEST-PC' | Out-Null
        $identityBefore = Get-Content -LiteralPath (Join-Path $project '项目交接\项目身份.json') -Raw | ConvertFrom-Json

        Save-PHMCheckpoint -ProjectPath $project -CurrentTask '任务甲' | Out-Null
        Save-PHMCheckpoint -ProjectPath $project -CurrentTask '任务乙' | Out-Null
        $report = Get-Content -LiteralPath (Join-Path $project '项目交接\项目交接报告.md') -Raw
        $identityAfter = Get-Content -LiteralPath (Join-Path $project '项目交接\项目身份.json') -Raw | ConvertFrom-Json

        $report | Should -Match '## 当前任务\r?\n\r?\n任务乙'
        $report | Should -Match '## 未完成事项和任务队列[\s\S]*- 任务甲'
        $identityAfter.project_id | Should -Be $identityBefore.project_id
    }
}
