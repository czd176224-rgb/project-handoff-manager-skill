Set-StrictMode -Version Latest

function Get-PHMVersion {
    [CmdletBinding()]
    param()

    [pscustomobject]@{
        Name          = 'project-handoff-manager'
        Version       = '0.1.0'
        SchemaVersion = 1
    }
}

function Get-PHMMenu {
    [CmdletBinding()]
    param()

    @(
        [pscustomobject]@{ Id = 1; Action = 'resume'; Name = '开始或继续当前项目'; RequiresPreview = $true; Implemented = $true }
        [pscustomobject]@{ Id = 2; Action = 'pause'; Name = '暂停当前项目'; RequiresPreview = $true; Implemented = $false }
        [pscustomobject]@{ Id = 3; Action = 'checkin'; Name = '将当前项目归还到 T9'; RequiresPreview = $true; Implemented = $false }
        [pscustomobject]@{ Id = 4; Action = 'checkout'; Name = '从 T9 借出项目到本机'; RequiresPreview = $true; Implemented = $false }
    )
}

function Get-PHMIdentitySummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ProjectPath
    )

    $identityPath = Join-Path $ProjectPath '项目交接\项目身份.json'
    if (-not (Test-Path -LiteralPath $identityPath -PathType Leaf)) {
        return [pscustomobject]@{
            Managed   = $false
            ProjectId = $null
            State     = $null
            Revision  = $null
            Error     = $null
        }
    }

    try {
        $identity = Get-Content -LiteralPath $identityPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        [pscustomobject]@{
            Managed   = $true
            ProjectId = [string]$identity.project_id
            State     = [string]$identity.state
            Revision  = $identity.revision
            Error     = $null
        }
    }
    catch {
        [pscustomobject]@{
            Managed   = $false
            ProjectId = $null
            State     = $null
            Revision  = $null
            Error     = '项目身份文件损坏'
        }
    }
}

function New-PHMProjectSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.IO.DirectoryInfo]$Directory,
        [Parameter(Mandatory)]
        [string]$Source,
        [Parameter(Mandatory)]
        [string]$Category
    )

    $identity = Get-PHMIdentitySummary -ProjectPath $Directory.FullName
    $resolvedCategory = $Category
    if ($identity.Error) {
        $resolvedCategory = '异常'
    }

    [pscustomobject]@{
        Name         = $Directory.Name
        Path         = $Directory.FullName
        Source       = $Source
        Category     = $resolvedCategory
        Managed      = $identity.Managed
        ProjectId    = $identity.ProjectId
        State        = $identity.State
        Revision     = $identity.Revision
        LastModified = $Directory.LastWriteTimeUtc.ToString('o')
        Error        = $identity.Error
    }
}

function Get-PHMProjectOverview {
    [CmdletBinding()]
    param(
        [string]$CurrentProjectPath,
        [string[]]$LocalRoots = @(),
        [string]$PortableRepositoryRoot
    )

    $localProjects = @()
    $portableProjects = @()
    $seenLocalPaths = @{}

    if ($CurrentProjectPath -and (Test-Path -LiteralPath $CurrentProjectPath -PathType Container)) {
        $directory = Get-Item -LiteralPath $CurrentProjectPath
        $localProjects += New-PHMProjectSummary -Directory $directory -Source 'local' -Category '当前项目'
        $seenLocalPaths[$directory.FullName.ToLowerInvariant()] = $true
    }

    foreach ($root in @($LocalRoots)) {
        if (-not $root -or -not (Test-Path -LiteralPath $root -PathType Container)) {
            continue
        }

        foreach ($directory in @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue)) {
            $key = $directory.FullName.ToLowerInvariant()
            if ($seenLocalPaths.ContainsKey($key)) {
                continue
            }

            $identity = Get-PHMIdentitySummary -ProjectPath $directory.FullName
            $category = if (-not $identity.Managed) { '待纳管' } elseif ($identity.State -eq 'cleanup_pending') { '清理待完成' } else { '可归还' }
            $localProjects += New-PHMProjectSummary -Directory $directory -Source 'local' -Category $category
            $seenLocalPaths[$key] = $true
        }
    }

    if ($PortableRepositoryRoot -and (Test-Path -LiteralPath $PortableRepositoryRoot -PathType Container)) {
        $portableGroups = @(
            @{ Folder = '暂停项目'; ManagedCategory = '可借出'; UnmanagedCategory = '首次借出需纳管' }
            @{ Folder = '已完成项目'; ManagedCategory = '已完成'; UnmanagedCategory = '已完成' }
            @{ Folder = '待整理任务'; ManagedCategory = '待整理'; UnmanagedCategory = '待整理' }
            @{ Folder = '正在接收'; ManagedCategory = '转移未完成'; UnmanagedCategory = '转移未完成' }
        )

        foreach ($group in $portableGroups) {
            $groupPath = Join-Path $PortableRepositoryRoot $group.Folder
            if (-not (Test-Path -LiteralPath $groupPath -PathType Container)) {
                continue
            }

            foreach ($directory in @(Get-ChildItem -LiteralPath $groupPath -Directory -Force -ErrorAction SilentlyContinue)) {
                $identity = Get-PHMIdentitySummary -ProjectPath $directory.FullName
                $category = if ($identity.Managed) { $group.ManagedCategory } else { $group.UnmanagedCategory }
                $portableProjects += New-PHMProjectSummary -Directory $directory -Source 'portable' -Category $category
            }
        }
    }

    $localIds = @($localProjects | Where-Object { $_.ProjectId } | ForEach-Object ProjectId)
    $portableIds = @($portableProjects | Where-Object { $_.ProjectId } | ForEach-Object ProjectId)
    $conflictingIds = @($localIds | Where-Object { $portableIds -contains $_ } | Select-Object -Unique)
    foreach ($project in @($localProjects) + @($portableProjects)) {
        if ($project.ProjectId -and $conflictingIds -contains $project.ProjectId) {
            $project.Category = '冲突'
        }
    }

    $abnormal = @(@($localProjects) + @($portableProjects) | Where-Object {
        $_.Category -in @('冲突', '清理待完成', '转移未完成', '异常')
    })

    [pscustomobject]@{
        GeneratedAt      = (Get-Date).ToUniversalTime().ToString('o')
        LocalProjects    = @($localProjects)
        PortableProjects = @($portableProjects)
        AbnormalProjects = @($abnormal)
    }
}

function Write-PHMUtf8File {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Content
    )

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Initialize-PHMProject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ProjectPath,
        [string]$ComputerName = $env:COMPUTERNAME,
        [ValidateSet('local_active', 'local_paused', 'on_t9', 'completed_on_t9')]
        [string]$InitialState = 'local_active'
    )

    if (-not (Test-Path -LiteralPath $ProjectPath -PathType Container)) {
        throw "项目文件夹不存在：$ProjectPath"
    }

    $projectDirectory = Get-Item -LiteralPath $ProjectPath
    $createdDirectories = @()
    $createdFiles = @()
    foreach ($relativePath in @('输入资料', '输出成果', '项目缓存', '离线依赖', '项目交接')) {
        $path = Join-Path $projectDirectory.FullName $relativePath
        if (-not (Test-Path -LiteralPath $path -PathType Container)) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
            $createdDirectories += $path
        }
    }

    $handoffRoot = Join-Path $projectDirectory.FullName '项目交接'
    $identityPath = Join-Path $handoffRoot '项目身份.json'
    if (-not (Test-Path -LiteralPath $identityPath -PathType Leaf)) {
        $timestamp = (Get-Date).ToUniversalTime().ToString('o')
        $identity = [ordered]@{
            schema_version    = 1
            project_id        = [guid]::NewGuid().ToString()
            project_name      = $projectDirectory.Name
            revision          = 1
            official_location = $projectDirectory.FullName
            state             = $InitialState
            last_computer     = [string]$ComputerName
            last_operation    = 'adopt'
            last_updated      = $timestamp
        }
        Write-PHMUtf8File -Path $identityPath -Content ($identity | ConvertTo-Json -Depth 5)
        $createdFiles += $identityPath
    }

    $reportPath = Join-Path $handoffRoot '项目交接报告.md'
    if (-not (Test-Path -LiteralPath $reportPath -PathType Leaf)) {
        $report = @'
# 项目交接报告

## 项目目标与不能改变的约束

## 当前任务

## 已完成事项

## 未完成事项和任务队列

## 下一步

## 重要决定及原因

## 最近新增材料及其位置

## 最近输出成果及其位置

## 最近修改的关键文件

## 启动、构建、测试和验证命令

## 最后一次验证结果

## 已知问题、阻断项和不能删除的文件

## 最近交接记录
'@
        Write-PHMUtf8File -Path $reportPath -Content $report
        $createdFiles += $reportPath
    }

    $environmentPath = Join-Path $handoffRoot '环境清单.json'
    if (-not (Test-Path -LiteralPath $environmentPath -PathType Leaf)) {
        $environment = [ordered]@{
            schemaVersion       = 1
            capturedAt          = $null
            computerName        = $null
            platform            = 'Windows'
            tools               = @()
            dependencyFiles     = @()
            projectCache        = [ordered]@{ fileCount = 0; totalBytes = 0; lastModified = $null; available = $true }
            offlineDependencies = [ordered]@{ fileCount = 0; totalBytes = 0; lastModified = $null; available = $true }
            notes               = @()
        }
        Write-PHMUtf8File -Path $environmentPath -Content ($environment | ConvertTo-Json -Depth 5)
        $createdFiles += $environmentPath
    }

    $identity = Get-Content -LiteralPath $identityPath -Raw | ConvertFrom-Json
    [pscustomobject]@{
        ProjectPath        = $projectDirectory.FullName
        ProjectId          = [string]$identity.project_id
        CreatedDirectories = @($createdDirectories)
        CreatedFiles       = @($createdFiles)
        WasAlreadyManaged  = ($createdFiles -notcontains $identityPath)
    }
}

function Get-PHMRelativePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BasePath,
        [Parameter(Mandatory)][string]$Path
    )

    $base = (Get-Item -LiteralPath $BasePath).FullName.TrimEnd('\') + '\'
    $full = (Get-Item -LiteralPath $Path).FullName
    if (-not $full.StartsWith($base, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $full
    }
    return $full.Substring($base.Length)
}

function Get-PHMProjectChanges {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [datetime]$Since = [datetime]::MinValue
    )

    $materials = @()
    $outputs = @()
    $unclassified = @()
    $excludedRoots = @('项目交接\', '项目缓存\', '离线依赖\')

    foreach ($file in @(Get-ChildItem -LiteralPath $ProjectPath -Recurse -File -Force -ErrorAction SilentlyContinue)) {
        if ($file.LastWriteTimeUtc -le $Since.ToUniversalTime()) {
            continue
        }

        $relativePath = Get-PHMRelativePath -BasePath $ProjectPath -Path $file.FullName
        $summary = [pscustomobject]@{
            RelativePath = $relativePath
            Size         = $file.Length
            LastModified = $file.LastWriteTimeUtc.ToString('o')
        }

        if ($relativePath.StartsWith('输入资料\', [System.StringComparison]::OrdinalIgnoreCase)) {
            $materials += $summary
        }
        elseif ($relativePath.StartsWith('输出成果\', [System.StringComparison]::OrdinalIgnoreCase)) {
            $outputs += $summary
        }
        elseif (-not ($excludedRoots | Where-Object { $relativePath.StartsWith($_, [System.StringComparison]::OrdinalIgnoreCase) })) {
            $unclassified += $summary
        }
    }

    [pscustomobject]@{
        Since        = $Since.ToUniversalTime().ToString('o')
        NewMaterials = @($materials)
        NewOutputs   = @($outputs)
        Unclassified = @($unclassified)
    }
}

function Get-PHMDirectoryInventory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $files = @(if (Test-Path -LiteralPath $Path -PathType Container) {
        Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '_项目管家清单.json' }
    })

    $latest = @($files | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)
    [long]$totalBytes = 0
    foreach ($file in $files) {
        $totalBytes += [long]$file.Length
    }
    [pscustomobject]@{
        fileCount    = $files.Count
        totalBytes   = $totalBytes
        lastModified = if ($latest.Count -gt 0) { $latest[0].LastWriteTimeUtc.ToString('o') } else { $null }
        available    = (Test-Path -LiteralPath $Path -PathType Container)
    }
}

function Update-PHMEnvironmentManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [string]$ComputerName = $env:COMPUTERNAME
    )

    $dependencyNames = @(
        'package-lock.json', 'pnpm-lock.yaml', 'yarn.lock', 'requirements.txt',
        'requirements.lock', 'pyproject.toml', 'poetry.lock', 'uv.lock', 'Pipfile.lock'
    )
    $dependencyFiles = @(Get-ChildItem -LiteralPath $ProjectPath -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $dependencyNames -contains $_.Name } |
        ForEach-Object { Get-PHMRelativePath -BasePath $ProjectPath -Path $_.FullName } |
        Sort-Object -Unique)

    $manifest = [ordered]@{
        schemaVersion       = 1
        capturedAt          = (Get-Date).ToUniversalTime().ToString('o')
        computerName        = [string]$ComputerName
        platform            = 'Windows'
        tools               = @(
            [ordered]@{
                name    = 'PowerShell'
                version = $PSVersionTable.PSVersion.ToString()
                path    = (Get-Process -Id $PID).Path
            }
        )
        dependencyFiles     = @($dependencyFiles)
        projectCache        = Get-PHMDirectoryInventory -Path (Join-Path $ProjectPath '项目缓存')
        offlineDependencies = Get-PHMDirectoryInventory -Path (Join-Path $ProjectPath '离线依赖')
        notes               = @()
    }

    $environmentPath = Join-Path $ProjectPath '项目交接\环境清单.json'
    Write-PHMUtf8File -Path $environmentPath -Content ($manifest | ConvertTo-Json -Depth 10)
    return $environmentPath
}

function Update-PHMIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [Parameter(Mandatory)][string]$ComputerName,
        [Parameter(Mandatory)][string]$Operation,
        [Parameter(Mandatory)][string]$State
    )

    $identityPath = Join-Path $ProjectPath '项目交接\项目身份.json'
    $identity = Get-Content -LiteralPath $identityPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $identity.revision = [int]$identity.revision + 1
    $identity.official_location = (Get-Item -LiteralPath $ProjectPath).FullName
    $identity.state = $State
    $identity.last_computer = $ComputerName
    $identity.last_operation = $Operation
    $identity.last_updated = (Get-Date).ToUniversalTime().ToString('o')
    Write-PHMUtf8File -Path $identityPath -Content ($identity | ConvertTo-Json -Depth 10)
    return $identity
}

function Add-PHMHandoffRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [Parameter(Mandatory)][string]$ComputerName,
        [Parameter(Mandatory)][string]$ActionLabel,
        [Parameter(Mandatory)]$Changes,
        [string]$CurrentTask,
        [string]$NextStep,
        [string]$ValidationResult
    )

    $reportPath = Join-Path $ProjectPath '项目交接\项目交接报告.md'
    $existing = Get-Content -LiteralPath $reportPath -Raw
    $timestamp = (Get-Date).ToUniversalTime().ToString('o')
    $materials = @($Changes.NewMaterials | ForEach-Object RelativePath) -join '；'
    $outputs = @($Changes.NewOutputs | ForEach-Object RelativePath) -join '；'
    $other = @($Changes.Unclassified | ForEach-Object RelativePath) -join '；'
    $record = @(
        '',
        "### $timestamp - $ActionLabel",
        "- 电脑：$ComputerName",
        "- 当前任务：$CurrentTask",
        "- 下一步：$NextStep",
        "- 新材料：$materials",
        "- 新输出：$outputs",
        "- 未分类变化：$other",
        "- 最后验证：$ValidationResult",
        '- 结果：项目仍在本机；未使用 T9；未删除文件。'
    ) -join [Environment]::NewLine
    Write-PHMUtf8File -Path $reportPath -Content ($existing.TrimEnd() + [Environment]::NewLine + $record + [Environment]::NewLine)
    return $reportPath
}

function Get-PHMMarkdownSection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][string]$Heading
    )

    $pattern = '(?ms)^##\s+' + [regex]::Escape($Heading) + '\s*\r?\n(?<body>.*?)(?=^##\s+|\z)'
    $match = [regex]::Match($Content, $pattern)
    if (-not $match.Success) {
        return ''
    }
    return $match.Groups['body'].Value.Trim()
}

function Set-PHMMarkdownSection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Content,
        [Parameter(Mandatory)][string]$Heading,
        [AllowEmptyString()][string]$Value
    )

    $pattern = '(?ms)^##\s+' + [regex]::Escape($Heading) + '\s*\r?\n.*?(?=^##\s+|\z)'
    $replacement = "## $Heading" + [Environment]::NewLine + [Environment]::NewLine + $Value.Trim() + [Environment]::NewLine + [Environment]::NewLine
    if ([regex]::IsMatch($Content, $pattern)) {
        return [regex]::Replace($Content, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($match) $replacement }, 1)
    }
    return $Content.TrimEnd() + [Environment]::NewLine + [Environment]::NewLine + $replacement
}

function Update-PHMTaskSections {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [string]$CurrentTask,
        [string]$NextStep,
        [string]$ValidationResult
    )

    $reportPath = Join-Path $ProjectPath '项目交接\项目交接报告.md'
    $content = Get-Content -LiteralPath $reportPath -Raw
    if (-not [string]::IsNullOrWhiteSpace($CurrentTask)) {
        $previousTask = Get-PHMMarkdownSection -Content $content -Heading '当前任务'
        if (-not [string]::IsNullOrWhiteSpace($previousTask) -and $previousTask -ne $CurrentTask) {
            $queue = Get-PHMMarkdownSection -Content $content -Heading '未完成事项和任务队列'
            $queueItem = "- $previousTask"
            if ($queue -notmatch ('(?m)^' + [regex]::Escape($queueItem) + '$')) {
                $queue = (@($queue, $queueItem) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join [Environment]::NewLine
                $content = Set-PHMMarkdownSection -Content $content -Heading '未完成事项和任务队列' -Value $queue
            }
        }
        $content = Set-PHMMarkdownSection -Content $content -Heading '当前任务' -Value $CurrentTask
    }
    if (-not [string]::IsNullOrWhiteSpace($NextStep)) {
        $content = Set-PHMMarkdownSection -Content $content -Heading '下一步' -Value $NextStep
    }
    if (-not [string]::IsNullOrWhiteSpace($ValidationResult)) {
        $content = Set-PHMMarkdownSection -Content $content -Heading '最后一次验证结果' -Value $ValidationResult
    }
    Write-PHMUtf8File -Path $reportPath -Content $content
}

function Resume-PHMProject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [string]$ComputerName = $env:COMPUTERNAME
    )

    Initialize-PHMProject -ProjectPath $ProjectPath -ComputerName $ComputerName -InitialState 'local_active' | Out-Null
    $identityPath = Join-Path $ProjectPath '项目交接\项目身份.json'
    $identityBefore = Get-Content -LiteralPath $identityPath -Raw | ConvertFrom-Json
    $since = if ($identityBefore.last_updated) { [datetime]::Parse([string]$identityBefore.last_updated).ToUniversalTime() } else { [datetime]::MinValue }
    $changes = Get-PHMProjectChanges -ProjectPath $ProjectPath -Since $since
    $environmentPath = Update-PHMEnvironmentManifest -ProjectPath $ProjectPath -ComputerName $ComputerName
    $identity = Update-PHMIdentity -ProjectPath $ProjectPath -ComputerName $ComputerName -Operation 'resume' -State 'local_active'
    $reportPath = Add-PHMHandoffRecord -ProjectPath $ProjectPath -ComputerName $ComputerName -ActionLabel '开始或继续' -Changes $changes

    [pscustomobject]@{
        ProjectId       = [string]$identity.project_id
        ProjectPath     = (Get-Item -LiteralPath $ProjectPath).FullName
        State           = [string]$identity.state
        Changes         = $changes
        EnvironmentPath = $environmentPath
        ReportPath      = $reportPath
        UsedPortableDrive = $false
        DeletedFiles      = 0
    }
}

function Save-PHMCheckpoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [string]$ComputerName = $env:COMPUTERNAME,
        [string]$CurrentTask,
        [string]$NextStep,
        [string]$ValidationResult
    )

    Initialize-PHMProject -ProjectPath $ProjectPath -ComputerName $ComputerName | Out-Null
    $identityPath = Join-Path $ProjectPath '项目交接\项目身份.json'
    $identityBefore = Get-Content -LiteralPath $identityPath -Raw | ConvertFrom-Json
    $since = if ($identityBefore.last_updated) { [datetime]::Parse([string]$identityBefore.last_updated).ToUniversalTime() } else { [datetime]::MinValue }
    $changes = Get-PHMProjectChanges -ProjectPath $ProjectPath -Since $since
    $environmentPath = Update-PHMEnvironmentManifest -ProjectPath $ProjectPath -ComputerName $ComputerName
    Update-PHMTaskSections -ProjectPath $ProjectPath -CurrentTask $CurrentTask -NextStep $NextStep -ValidationResult $ValidationResult
    $identity = Update-PHMIdentity -ProjectPath $ProjectPath -ComputerName $ComputerName -Operation 'checkpoint' -State ([string]$identityBefore.state)
    $reportPath = Add-PHMHandoffRecord -ProjectPath $ProjectPath -ComputerName $ComputerName -ActionLabel '记录当前进度' -Changes $changes -CurrentTask $CurrentTask -NextStep $NextStep -ValidationResult $ValidationResult

    [pscustomobject]@{
        ProjectId         = [string]$identity.project_id
        State             = [string]$identity.state
        Changes           = $changes
        EnvironmentPath   = $environmentPath
        ReportPath        = $reportPath
        StoppedProcesses  = 0
        UsedPortableDrive = $false
        DeletedFiles      = 0
    }
}

function Read-PHMConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "配置文件不存在：$Path"
    }

    try {
        $config = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "配置文件无法解析：$Path。$($_.Exception.Message)"
    }

    if (-not $config.PSObject.Properties['schemaVersion'] -or [int]$config.schemaVersion -ne 1) {
        throw "不支持的配置版本；当前只支持 schemaVersion 1。"
    }

    $localRoots = @()
    if ($config.PSObject.Properties['local'] -and $config.local) {
        foreach ($propertyName in @('currentProjectsRoot', 'pausedProjectsRoot')) {
            $property = $config.local.PSObject.Properties[$propertyName]
            if ($property -and $property.Value) {
                $localRoots += [string]$property.Value
            }
        }
        $additional = $config.local.PSObject.Properties['additionalRoots']
        if ($additional -and $additional.Value) {
            $localRoots += @($additional.Value | ForEach-Object { [string]$_ })
        }
    }

    $portableRepositoryRoot = $null
    if ($config.PSObject.Properties['portableDrive'] -and $config.portableDrive) {
        $repositoryProperty = $config.portableDrive.PSObject.Properties['repositoryRoot']
        if ($repositoryProperty) {
            $portableRepositoryRoot = [string]$repositoryProperty.Value
        }
    }

    [pscustomobject]@{
        SchemaVersion          = 1
        LocalRoots             = @($localRoots)
        PortableRepositoryRoot = $portableRepositoryRoot
        Raw                    = $config
    }
}

Export-ModuleMember -Function Get-PHMVersion, Get-PHMMenu, Get-PHMProjectOverview, Initialize-PHMProject, Resume-PHMProject, Save-PHMCheckpoint, Read-PHMConfig
