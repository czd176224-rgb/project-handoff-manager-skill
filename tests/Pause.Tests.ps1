Describe '安全暂停项目' {
    BeforeAll {
        $modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'project-handoff-manager\scripts\ProjectManager.Core.psm1'
        Import-Module $modulePath -Force

        function New-PauseProcessRecord {
            param([int]$Id,[string]$Name,[string]$CommandLine,[int]$ParentProcessId=1,[long]$WorkingSetSize=52428800)
            [pscustomobject]@{
                Id=$Id; Name=$Name; CommandLine=$CommandLine; ExecutablePath='C:\Tools\tool.exe'
                ParentProcessId=$ParentProcessId; WorkingSetSize=$WorkingSetSize; CpuSeconds=1.0
            }
        }
    }

    It '未确认时只返回预览，不停止进程也不改变项目状态' {
        $project = Join-Path $TestDrive '预览项目'
        New-Item -ItemType Directory -Path $project -Force | Out-Null
        Initialize-PHMProject -ProjectPath $project -ComputerName 'TEST-PC' | Out-Null
        $records = @(New-PauseProcessRecord -Id 101 -Name 'node' -CommandLine "node `"$project\server.js`"")
        $script:stopCalls = 0

        $result = Suspend-PHMProject -ProjectPath $project -ProcessRecords $records -ProcessStopper { $script:stopCalls++ }
        $identity = Get-Content -LiteralPath (Join-Path $project '项目交接\项目身份.json') -Raw | ConvertFrom-Json

        $result.Executed | Should -BeFalse
        $result.Plan.StopCandidates.Count | Should -Be 1
        $result.ExpectedResult | Should -Match '释放'
        $script:stopCalls | Should -Be 0
        $identity.state | Should -Be 'local_active'
    }

    It '确认后只停止明确归属候选并报告实际释放资源' {
        $project = Join-Path $TestDrive '停止项目'
        New-Item -ItemType Directory -Path $project -Force | Out-Null
        Initialize-PHMProject -ProjectPath $project -ComputerName 'TEST-PC' | Out-Null
        $records = @(
            New-PauseProcessRecord -Id 201 -Name 'node' -CommandLine "node `"$project\server.js`"" -WorkingSetSize 104857600
            New-PauseProcessRecord -Id 202 -Name 'OpenAI.Codex' -CommandLine "OpenAI.Codex.exe --cwd `"$project`""
            New-PauseProcessRecord -Id 203 -Name 'python' -CommandLine "python $(Split-Path $project -Leaf)\worker.py"
        )
        $script:stoppedIds = @()
        $stopper = { param($candidate) $script:stoppedIds += $candidate.Id; [pscustomobject]@{ Exited=$true; Error=$null } }

        $result = Suspend-PHMProject -ProjectPath $project -ComputerName 'TEST-PC' -ProcessRecords $records -ConfirmStop -ProcessStopper $stopper
        $identity = Get-Content -LiteralPath (Join-Path $project '项目交接\项目身份.json') -Raw | ConvertFrom-Json
        $report = Get-Content -LiteralPath (Join-Path $project '项目交接\项目交接报告.md') -Raw

        $script:stoppedIds | Should -Be @(201)
        $result.Executed | Should -BeTrue
        $result.StoppedProcesses.Count | Should -Be 1
        $result.ActualReleasedMemoryMB | Should -Be 100
        $result.RemainingCandidates.Count | Should -Be 0
        $identity.state | Should -Be 'local_paused'
        $identity.last_operation | Should -Be 'pause'
        $report | Should -Match '暂停当前项目'
    }

    It '没有项目进程时仍完成暂停并更新交接状态' {
        $project = Join-Path $TestDrive '无进程项目'
        New-Item -ItemType Directory -Path $project -Force | Out-Null
        Initialize-PHMProject -ProjectPath $project -ComputerName 'TEST-PC' | Out-Null

        $result = Suspend-PHMProject -ProjectPath $project -ComputerName 'TEST-PC' -ProcessRecords @() -ConfirmStop
        $identity = Get-Content -LiteralPath (Join-Path $project '项目交接\项目身份.json') -Raw | ConvertFrom-Json

        $result.Executed | Should -BeTrue
        $result.StoppedProcesses.Count | Should -Be 0
        $identity.state | Should -Be 'local_paused'
    }

    It '停止失败时保留失败进程并在结果中明确报告' {
        $project = Join-Path $TestDrive '失败项目'
        New-Item -ItemType Directory -Path $project -Force | Out-Null
        Initialize-PHMProject -ProjectPath $project -ComputerName 'TEST-PC' | Out-Null
        $records = @(New-PauseProcessRecord -Id 301 -Name 'node' -CommandLine "node `"$project\server.js`"")
        $stopper = { param($candidate) [pscustomobject]@{ Exited=$false; Error='拒绝访问' } }

        $result = Suspend-PHMProject -ProjectPath $project -ProcessRecords $records -ConfirmStop -ProcessStopper $stopper

        $result.FailedProcesses.Count | Should -Be 1
        $result.RemainingCandidates.Count | Should -Be 1
        $result.FailedProcesses[0].Error | Should -Be '拒绝访问'
    }
}
