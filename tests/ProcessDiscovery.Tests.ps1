Describe '项目进程识别' {
    BeforeAll {
        $modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'project-handoff-manager\scripts\ProjectManager.Core.psm1'
        Import-Module $modulePath -Force

        function New-ProcessRecord {
            param(
                [int]$Id,
                [string]$Name,
                [string]$CommandLine,
                [string]$ExecutablePath = 'C:\Tools\tool.exe',
                [int]$ParentProcessId = 1,
                [long]$WorkingSetSize = 104857600,
                [double]$CpuSeconds = 2.5
            )
            [pscustomobject]@{
                Id               = $Id
                Name             = $Name
                CommandLine      = $CommandLine
                ExecutablePath   = $ExecutablePath
                ParentProcessId  = $ParentProcessId
                WorkingSetSize   = $WorkingSetSize
                CpuSeconds       = $CpuSeconds
            }
        }
    }

    It '完整项目路径命中命令行时列为可停止并说明证据' {
        $project = 'D:\项目\项目甲'
        $records = @(
            New-ProcessRecord -Id 101 -Name 'node' -CommandLine "node `"$project\server.js`""
            New-ProcessRecord -Id 102 -Name 'python' -CommandLine 'python D:\其他项目\app.py'
        )

        $plan = Get-PHMProjectProcessPlan -ProjectPath $project -ProcessRecords $records

        $plan.StopCandidates.Count | Should -Be 1
        $plan.StopCandidates[0].Id | Should -Be 101
        $plan.StopCandidates[0].Evidence | Should -Match '完整项目路径'
        $plan.EstimatedMemoryMB | Should -Be 100
    }

    It 'Codex 主程序和系统保护进程即使命中项目路径也不会停止' {
        $project = 'D:\项目\项目甲'
        $records = @(
            New-ProcessRecord -Id 201 -Name 'OpenAI.Codex' -CommandLine "OpenAI.Codex.exe --cwd `"$project`""
            New-ProcessRecord -Id 202 -Name 'services' -CommandLine "services.exe $project"
        )

        $plan = Get-PHMProjectProcessPlan -ProjectPath $project -ProcessRecords $records

        $plan.StopCandidates.Count | Should -Be 0
        $plan.Skipped.Count | Should -Be 2
        $plan.Skipped.Reason | Should -Not -Contain $null
        $plan.Skipped.Reason | Should -Match '保护'
    }

    It '只出现项目文件夹名称而没有完整路径时标记为归属不明' {
        $project = 'D:\项目\项目甲'
        $records = @(
            New-ProcessRecord -Id 301 -Name 'node' -CommandLine 'node 项目甲\server.js'
        )

        $plan = Get-PHMProjectProcessPlan -ProjectPath $project -ProcessRecords $records

        $plan.StopCandidates.Count | Should -Be 0
        $plan.Uncertain.Count | Should -Be 1
        $plan.Uncertain[0].Reason | Should -Match '只有项目名称'
    }

    It '明确命中进程的非保护子进程可随项目停止' {
        $project = 'D:\项目\项目甲'
        $records = @(
            New-ProcessRecord -Id 401 -Name 'npm' -CommandLine "npm --prefix `"$project`" run dev"
            New-ProcessRecord -Id 402 -Name 'node' -CommandLine 'node child-worker.js' -ParentProcessId 401
        )

        $plan = Get-PHMProjectProcessPlan -ProjectPath $project -ProcessRecords $records

        $plan.StopCandidates.Id | Should -Contain 401
        $plan.StopCandidates.Id | Should -Contain 402
        ($plan.StopCandidates | Where-Object Id -eq 402).Evidence | Should -Match '父进程'
    }

    It '相似项目路径不会误匹配' {
        $project = 'D:\项目\项目甲'
        $records = @(
            New-ProcessRecord -Id 501 -Name 'node' -CommandLine 'node D:\项目\项目甲-副本\server.js'
        )

        $plan = Get-PHMProjectProcessPlan -ProjectPath $project -ProcessRecords $records

        $plan.StopCandidates.Count | Should -Be 0
        $plan.Uncertain.Count | Should -Be 0
    }
}
