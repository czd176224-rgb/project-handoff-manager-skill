Describe '项目发现与总览' {
    BeforeAll {
        $modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'project-handoff-manager\scripts\ProjectManager.Core.psm1'
        Import-Module $modulePath -Force

        function New-TestProjectIdentity {
            param(
                [string]$ProjectPath,
                [string]$ProjectId,
                [string]$State = 'local_paused'
            )

            $handoff = Join-Path $ProjectPath '项目交接'
            New-Item -ItemType Directory -Path $handoff -Force | Out-Null
            @{
                schema_version    = 1
                project_id        = $ProjectId
                project_name      = Split-Path $ProjectPath -Leaf
                revision          = 1
                official_location = $ProjectPath
                state             = $State
                last_computer     = 'TEST-PC'
                last_operation    = 'pause'
                last_updated      = '2026-08-13T00:00:00Z'
            } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $handoff '项目身份.json') -Encoding utf8
        }
    }

    It '只扫描配置根目录的直接子文件夹并包含当前外部项目' {
        $currentRoot = Join-Path $TestDrive '01-当前项目'
        $pausedRoot = Join-Path $TestDrive '02-暂停项目'
        $externalCurrent = Join-Path $TestDrive '外部当前项目'
        $nested = Join-Path $currentRoot '项目甲\不应递归发现'
        New-Item -ItemType Directory -Path $nested,$pausedRoot,$externalCurrent -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $pausedRoot '项目乙') -Force | Out-Null

        $result = Get-PHMProjectOverview -CurrentProjectPath $externalCurrent -LocalRoots @($currentRoot, $pausedRoot)

        $result.LocalProjects.Name | Should -Contain '项目甲'
        $result.LocalProjects.Name | Should -Contain '项目乙'
        $result.LocalProjects.Name | Should -Contain '外部当前项目'
        $result.LocalProjects.Name | Should -Not -Contain '不应递归发现'
        ($result.LocalProjects | Where-Object Path -eq $externalCurrent).Category | Should -Be '当前项目'
        ($result.LocalProjects | Where-Object Name -eq '项目甲').Category | Should -Be '待纳管'
    }

    It '按 T9 仓库位置分类可借出、待整理、已完成和转移未完成' {
        $repository = Join-Path $TestDrive '项目仓库'
        $paused = Join-Path $repository '暂停项目\正式项目'
        $unmanaged = Join-Path $repository '暂停项目\旧项目'
        $completed = Join-Path $repository '已完成项目\完成项目'
        $unsorted = Join-Path $repository '待整理任务\散乱资料'
        $receiving = Join-Path $repository '正在接收\中断项目'
        New-Item -ItemType Directory -Path $paused,$unmanaged,$completed,$unsorted,$receiving -Force | Out-Null
        New-TestProjectIdentity -ProjectPath $paused -ProjectId '11111111-1111-1111-1111-111111111111' -State 'on_t9'

        $result = Get-PHMProjectOverview -LocalRoots @() -PortableRepositoryRoot $repository

        ($result.PortableProjects | Where-Object Name -eq '正式项目').Category | Should -Be '可借出'
        ($result.PortableProjects | Where-Object Name -eq '旧项目').Category | Should -Be '首次借出需纳管'
        ($result.PortableProjects | Where-Object Name -eq '完成项目').Category | Should -Be '已完成'
        ($result.PortableProjects | Where-Object Name -eq '散乱资料').Category | Should -Be '待整理'
        ($result.PortableProjects | Where-Object Name -eq '中断项目').Category | Should -Be '转移未完成'
    }

    It '相同项目编号同时存在于本机和 T9 时标记冲突' {
        $localRoot = Join-Path $TestDrive '本机'
        $localProject = Join-Path $localRoot '同一项目'
        $repository = Join-Path $TestDrive 'T9仓库'
        $portableProject = Join-Path $repository '暂停项目\同一项目'
        New-Item -ItemType Directory -Path $localProject,$portableProject -Force | Out-Null
        $id = '22222222-2222-2222-2222-222222222222'
        New-TestProjectIdentity -ProjectPath $localProject -ProjectId $id
        New-TestProjectIdentity -ProjectPath $portableProject -ProjectId $id -State 'on_t9'

        $result = Get-PHMProjectOverview -LocalRoots @($localRoot) -PortableRepositoryRoot $repository

        ($result.LocalProjects | Where-Object ProjectId -eq $id).Category | Should -Be '冲突'
        ($result.PortableProjects | Where-Object ProjectId -eq $id).Category | Should -Be '冲突'
        $result.AbnormalProjects.Count | Should -Be 2
    }
}
