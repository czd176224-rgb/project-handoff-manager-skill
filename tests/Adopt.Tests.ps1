Describe '自动纳入项目管理' {
    BeforeAll {
        $modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'project-handoff-manager\scripts\ProjectManager.Core.psm1'
        Import-Module $modulePath -Force
    }

    It '只补充管理结构且不移动或覆盖已有文件' {
        $project = Join-Path $TestDrive '已有项目'
        $existingReport = Join-Path $project '项目交接\项目交接报告.md'
        New-Item -ItemType Directory -Path (Split-Path $existingReport -Parent) -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $project '已有材料.txt') -Value 'keep-me' -Encoding utf8
        Set-Content -LiteralPath $existingReport -Value '# 我的已有报告' -Encoding utf8

        $result = Initialize-PHMProject -ProjectPath $project -ComputerName 'TEST-PC' -InitialState 'local_active'

        @('输入资料', '输出成果', '项目缓存', '离线依赖', '项目交接') | ForEach-Object {
            Test-Path -LiteralPath (Join-Path $project $_) | Should -BeTrue
        }
        Get-Content -LiteralPath (Join-Path $project '已有材料.txt') -Raw | Should -Match 'keep-me'
        Get-Content -LiteralPath $existingReport -Raw | Should -Match '我的已有报告'
        $result.CreatedFiles | Should -Not -Contain $existingReport
    }

    It '创建符合正式契约的稳定 UUID 身份且重复执行保持不变' {
        $project = Join-Path $TestDrive '新项目'
        New-Item -ItemType Directory -Path $project -Force | Out-Null

        $first = Initialize-PHMProject -ProjectPath $project -ComputerName 'TEST-PC' -InitialState 'local_active'
        $identityPath = Join-Path $project '项目交接\项目身份.json'
        $firstIdentity = Get-Content -LiteralPath $identityPath -Raw | ConvertFrom-Json
        $second = Initialize-PHMProject -ProjectPath $project -ComputerName 'OTHER-PC' -InitialState 'local_active'
        $secondIdentity = Get-Content -LiteralPath $identityPath -Raw | ConvertFrom-Json

        { [guid]::Parse($firstIdentity.project_id) } | Should -Not -Throw
        $firstIdentity.project_id | Should -Be $secondIdentity.project_id
        $secondIdentity.project_name | Should -Be '新项目'
        $secondIdentity.state | Should -Be 'local_active'
        $secondIdentity.official_location | Should -Be (Get-Item $project).FullName
        $first.CreatedFiles | Should -Contain $identityPath
        $second.CreatedFiles.Count | Should -Be 0
    }

    It '新建的交接报告包含固定的十三类信息' {
        $project = Join-Path $TestDrive '报告项目'
        New-Item -ItemType Directory -Path $project -Force | Out-Null

        Initialize-PHMProject -ProjectPath $project -ComputerName 'TEST-PC' | Out-Null
        $report = Get-Content -LiteralPath (Join-Path $project '项目交接\项目交接报告.md') -Raw

        @(
            '项目目标与不能改变的约束', '当前任务', '已完成事项', '未完成事项和任务队列',
            '下一步', '重要决定及原因', '最近新增材料及其位置', '最近输出成果及其位置',
            '最近修改的关键文件', '启动、构建、测试和验证命令', '最后一次验证结果',
            '已知问题、阻断项和不能删除的文件', '最近交接记录'
        ) | ForEach-Object { $report | Should -Match ([regex]::Escape($_)) }
    }
}
