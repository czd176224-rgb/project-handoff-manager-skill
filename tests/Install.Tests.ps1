Describe 'v1.0.0 Skill 安装与隔离验证' {
    BeforeAll {
        $repoRoot = Split-Path $PSScriptRoot -Parent
        $installer = Join-Path $repoRoot 'scripts\install.ps1'
        $verifier = Join-Path $repoRoot 'scripts\verify_install.ps1'
        $sourceSkill = Join-Path $repoRoot 'project-handoff-manager'
    }

    It '将完整 Skill 安装到显式 TestDrive 根并通过独立验证' {
        $destinationRoot = Join-Path $TestDrive 'codex-a\skills'

        $result = @(& $installer -DestinationRoot $destinationRoot)[-1]
        $installed = Join-Path $destinationRoot 'project-handoff-manager'
        $validation = @(& $verifier -DestinationRoot $destinationRoot)[-1]

        $result.Status | Should -Be 'Installed'
        $validation.Valid | Should -BeTrue
        $validation.Version | Should -Be '1.0.0'
        Test-Path -LiteralPath (Join-Path $installed 'SKILL.md') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $installed 'scripts\ProjectManager.Core.psm1') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $installed 'tests') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $installed '.git') | Should -BeFalse
        (Get-ChildItem -LiteralPath $sourceSkill -Recurse -File -Force).Count |
            Should -Be (Get-ChildItem -LiteralPath $installed -Recurse -File -Force).Count
    }

    It '内容完全相同时返回已安装且不重复复制' {
        $destinationRoot = Join-Path $TestDrive 'codex-idempotent\skills'
        $first = @(& $installer -DestinationRoot $destinationRoot)[-1]
        $skillFile = Join-Path $first.DestinationPath 'SKILL.md'
        $writeTime = (Get-Item -LiteralPath $skillFile).LastWriteTimeUtc

        $second = @(& $installer -DestinationRoot $destinationRoot)[-1]

        $second.Status | Should -Be 'AlreadyInstalled'
        (Get-Item -LiteralPath $skillFile).LastWriteTimeUtc | Should -Be $writeTime
        @(Get-ChildItem -LiteralPath $destinationRoot -Directory -Filter 'project-handoff-manager*').Count | Should -Be 1
    }

    It '不同内容默认拒绝覆盖，Force 时先保留可恢复备份' {
        $destinationRoot = Join-Path $TestDrive 'codex-upgrade\skills'
        $first = @(& $installer -DestinationRoot $destinationRoot)[-1]
        $marker = Join-Path $first.DestinationPath '本机旧文件.txt'
        Set-Content -LiteralPath $marker -Value 'keep-in-backup' -Encoding utf8

        { & $installer -DestinationRoot $destinationRoot } | Should -Throw '*内容不同*'
        Test-Path -LiteralPath $marker | Should -BeTrue

        $upgraded = @(& $installer -DestinationRoot $destinationRoot -Force)[-1]
        $upgraded.Status | Should -Be 'Upgraded'
        Test-Path -LiteralPath (Join-Path $upgraded.BackupPath '本机旧文件.txt') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $upgraded.DestinationPath '本机旧文件.txt') | Should -BeFalse
        @(& $verifier -SkillPath $upgraded.DestinationPath)[-1].Valid | Should -BeTrue
    }

    It '验证器拒绝仓库污染、本机配置、凭据内容和重解析点' {
        $cases = @(
            @{ Name='tests'; Prepare={ param($skill) New-Item -ItemType Directory -Path (Join-Path $skill 'tests') -Force | Out-Null; Set-Content -LiteralPath (Join-Path $skill 'tests\x.ps1') -Value 'x' } },
            @{ Name='local-config'; Prepare={ param($skill) Set-Content -LiteralPath (Join-Path $skill 'local.config.json') -Value '{}' } },
            @{ Name='credential'; Prepare={ param($skill) $credentialLine = ('api' + '_key = ' + 'secret-value-12345'); Add-Content -LiteralPath (Join-Path $skill 'SKILL.md') -Value $credentialLine } },
            @{ Name='reparse'; Prepare={ param($skill) $outside=Join-Path (Split-Path $skill -Parent) 'outside'; New-Item -ItemType Directory -Path $outside -Force|Out-Null; New-Item -ItemType Junction -Path (Join-Path $skill 'linked') -Target $outside|Out-Null } }
        )
        foreach ($case in $cases) {
            $root = Join-Path $TestDrive ("polluted-" + $case.Name)
            $installed = @(& $installer -DestinationRoot $root)[-1].DestinationPath
            & $case.Prepare $installed
            { & $verifier -SkillPath $installed -Quiet } | Should -Throw '*安装验证失败*'
        }
    }

    It '安装器拒绝与仓库或源 Skill 重叠的目标根' {
        $repoRoot = Split-Path $sourceSkill -Parent
        foreach ($overlap in @($repoRoot, $sourceSkill, (Join-Path $sourceSkill 'nested-skills'), (Split-Path $repoRoot -Parent))) {
            { & $installer -DestinationRoot $overlap } | Should -Throw '*路径重叠*'
        }
    }

    It '目标 Skill 是指向同内容外部副本的 junction 时在比较前拒绝且不修改两端' {
        $destinationRoot = Join-Path $TestDrive 'junction-target\skills'
        $externalRoot = Join-Path $TestDrive 'junction-target\external'
        $externalSkill = Join-Path $externalRoot 'published-copy'
        New-Item -ItemType Directory -Path $destinationRoot,$externalRoot -Force | Out-Null
        Copy-Item -LiteralPath $sourceSkill -Destination $externalSkill -Recurse -Force
        $destinationPath = Join-Path $destinationRoot 'project-handoff-manager'
        New-Item -ItemType Junction -Path $destinationPath -Target $externalSkill | Out-Null
        $externalSkillHash = (Get-FileHash -LiteralPath (Join-Path $externalSkill 'SKILL.md') -Algorithm SHA256).Hash

        { & $installer -DestinationRoot $destinationRoot } | Should -Throw '*重解析点*'

        [bool]((Get-Item -LiteralPath $destinationPath -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint) | Should -BeTrue
        Test-Path -LiteralPath $externalSkill -PathType Container | Should -BeTrue
        (Get-FileHash -LiteralPath (Join-Path $externalSkill 'SKILL.md') -Algorithm SHA256).Hash | Should -Be $externalSkillHash
        @(Get-ChildItem -LiteralPath $destinationRoot -Directory -Filter 'project-handoff-manager.backup-*').Count | Should -Be 0
    }
}
