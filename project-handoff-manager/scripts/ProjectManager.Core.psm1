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
        [pscustomobject]@{ Id = 2; Action = 'pause'; Name = '暂停当前项目'; RequiresPreview = $true; Implemented = $true }
        [pscustomobject]@{ Id = 3; Action = 'checkin'; Name = '将当前项目归还到 T9'; RequiresPreview = $true; Implemented = $true }
        [pscustomobject]@{ Id = 4; Action = 'checkout'; Name = '从 T9 借出项目到本机'; RequiresPreview = $true; Implemented = $true }
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
        [string]$ProjectId,
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
            project_id        = if ($ProjectId) { $ProjectId } else { [guid]::NewGuid().ToString() }
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
            nodeEnvironment     = [ordered]@{
                status = 'not_detected'; dependenciesPresent = $false; lockFile = $null; recoveryCommand = $null
                note = '随项目存在的 node_modules 仍需在本机验证，不能保证可直接运行。'
            }
            pythonEnvironment   = [ordered]@{
                status = 'not_detected'; virtualEnvironmentPresent = $false; configurationFile = $null
                originalPythonHome = $null; recoverySource = $null; recoveryCommand = $null
                note = '复制来的虚拟环境必须检查原 Python 路径，不能保证可直接运行。'
            }
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

    $environment = Test-PHMProjectEnvironment -ProjectPath $ProjectPath
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
        nodeEnvironment     = [ordered]@{
            status              = $environment.NodeEnvironment.Status
            dependenciesPresent = [bool]$environment.NodeEnvironment.DependenciesPresent
            lockFile            = $environment.NodeEnvironment.LockFile
            recoveryCommand     = $environment.NodeEnvironment.RecoveryCommand
            note                = $environment.NodeEnvironment.Note
        }
        pythonEnvironment   = [ordered]@{
            status                    = $environment.PythonEnvironment.Status
            virtualEnvironmentPresent = [bool]$environment.PythonEnvironment.VirtualEnvironmentPresent
            configurationFile         = $environment.PythonEnvironment.ConfigurationFile
            originalPythonHome        = $environment.PythonEnvironment.OriginalPythonHome
            recoverySource            = $environment.PythonEnvironment.RecoverySource
            recoveryCommand           = $environment.PythonEnvironment.RecoveryCommand
            note                      = $environment.PythonEnvironment.Note
        }
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
        [Parameter(Mandatory)][string]$State,
        [string]$OfficialLocation
    )

    $identityPath = Join-Path $ProjectPath '项目交接\项目身份.json'
    $identity = Get-Content -LiteralPath $identityPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $identity.revision = [int]$identity.revision + 1
    $identity.official_location = if ($OfficialLocation) { [System.IO.Path]::GetFullPath($OfficialLocation) } else { (Get-Item -LiteralPath $ProjectPath).FullName }
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

    $localCurrentRoot = $null
    $localReceivingRoot = $null
    if ($config.PSObject.Properties['local'] -and $config.local) {
        $currentProperty = $config.local.PSObject.Properties['currentProjectsRoot']
        if ($currentProperty) { $localCurrentRoot = [string]$currentProperty.Value }
        $receivingProperty = $config.local.PSObject.Properties['receivingRoot']
        if ($receivingProperty) { $localReceivingRoot = [string]$receivingProperty.Value }
    }

    [pscustomobject]@{
        SchemaVersion          = 1
        LocalRoots             = @($localRoots)
        LocalCurrentRoot       = $localCurrentRoot
        LocalReceivingRoot     = $localReceivingRoot
        PortableRepositoryRoot = $portableRepositoryRoot
        Raw                    = $config
    }
}

function Get-PHMObjectProperty {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$InputObject,
        [Parameter(Mandatory)][string]$Name,
        $DefaultValue = $null
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $DefaultValue
}

function Test-PHMTextContainsProjectPath {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$Text,
        [Parameter(Mandatory)][string]$ProjectPath
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    $normalizedText = $Text.Replace('/', '\')
    $normalizedPath = $ProjectPath.Replace('/', '\').TrimEnd('\')
    $pattern = '(?i)(^|[\s"''=])' + [regex]::Escape($normalizedPath) + '(?=\\|[\s"'']|$)'
    return [regex]::IsMatch($normalizedText, $pattern)
}

function Test-PHMTextContainsProjectName {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$Text,
        [Parameter(Mandatory)][string]$ProjectName
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    $pattern = '(?i)(^|[\\/\s"''])' + [regex]::Escape($ProjectName) + '(?=[\\/\s"'']|$)'
    return [regex]::IsMatch($Text, $pattern)
}

function Get-PHMSystemProcessRecords {
    [CmdletBinding()]
    param()

    $records = @()
    foreach ($process in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
        $runtime = Get-Process -Id $process.ProcessId -ErrorAction SilentlyContinue
        $records += [pscustomobject]@{
            Id              = [int]$process.ProcessId
            Name            = [System.IO.Path]::GetFileNameWithoutExtension([string]$process.Name)
            CommandLine     = [string]$process.CommandLine
            ExecutablePath  = [string]$process.ExecutablePath
            ParentProcessId = [int]$process.ParentProcessId
            WorkingSetSize  = if ($runtime) { [long]$runtime.WorkingSet64 } else { [long]$process.WorkingSetSize }
            CpuSeconds      = if ($runtime -and $runtime.CPU) { [double]$runtime.CPU } else { 0.0 }
        }
    }
    return @($records)
}

function ConvertTo-PHMProcessSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Record,
        [string]$Evidence,
        [string]$Reason
    )

    $workingSet = [long](Get-PHMObjectProperty -InputObject $Record -Name 'WorkingSetSize' -DefaultValue 0)
    [pscustomobject]@{
        Id              = [int](Get-PHMObjectProperty -InputObject $Record -Name 'Id' -DefaultValue 0)
        Name            = [string](Get-PHMObjectProperty -InputObject $Record -Name 'Name' -DefaultValue '')
        ParentProcessId = [int](Get-PHMObjectProperty -InputObject $Record -Name 'ParentProcessId' -DefaultValue 0)
        CommandLine     = [string](Get-PHMObjectProperty -InputObject $Record -Name 'CommandLine' -DefaultValue '')
        MemoryMB        = [math]::Round($workingSet / 1MB, 2)
        CpuSeconds      = [double](Get-PHMObjectProperty -InputObject $Record -Name 'CpuSeconds' -DefaultValue 0)
        Evidence        = $Evidence
        Reason          = $Reason
    }
}

function Get-PHMProjectProcessPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [object[]]$ProcessRecords
    )

    $normalizedProjectPath = $ProjectPath.Replace('/', '\').TrimEnd('\')
    $projectName = Split-Path $normalizedProjectPath -Leaf
    $records = if ($PSBoundParameters.ContainsKey('ProcessRecords')) { @($ProcessRecords) } else { @(Get-PHMSystemProcessRecords) }
    $protectedPattern = '^(?i:OpenAI\.Codex|Codex|ChatGPT|System|Idle|Registry|smss|csrss|wininit|services|lsass|winlogon|dwm|explorer)$'
    $candidates = @()
    $skipped = @()
    $uncertain = @()
    $candidateIds = @{}

    foreach ($record in $records) {
        $recordId = [int](Get-PHMObjectProperty -InputObject $record -Name 'Id' -DefaultValue 0)
        $name = [string](Get-PHMObjectProperty -InputObject $record -Name 'Name' -DefaultValue '')
        $commandLine = [string](Get-PHMObjectProperty -InputObject $record -Name 'CommandLine' -DefaultValue '')
        $executablePath = [string](Get-PHMObjectProperty -InputObject $record -Name 'ExecutablePath' -DefaultValue '')
        $exactCommandMatch = Test-PHMTextContainsProjectPath -Text $commandLine -ProjectPath $normalizedProjectPath
        $exactExecutableMatch = Test-PHMTextContainsProjectPath -Text $executablePath -ProjectPath $normalizedProjectPath
        $isProtected = $name -match $protectedPattern

        if ($recordId -eq $PID -and ($exactCommandMatch -or $exactExecutableMatch)) {
            $skipped += ConvertTo-PHMProcessSummary -Record $record -Reason '保护进程：项目管家当前运行进程不能停止自身。'
            continue
        }

        if (($exactCommandMatch -or $exactExecutableMatch) -and $isProtected) {
            $skipped += ConvertTo-PHMProcessSummary -Record $record -Reason '保护进程：即使命中项目路径也默认跳过。'
            continue
        }
        if ($exactCommandMatch -or $exactExecutableMatch) {
            $evidence = if ($exactCommandMatch) { '命令行包含完整项目路径' } else { '可执行文件位于完整项目路径内' }
            $summary = ConvertTo-PHMProcessSummary -Record $record -Evidence $evidence
            $candidates += $summary
            $candidateIds[[int]$summary.Id] = $true
            continue
        }
        if (Test-PHMTextContainsProjectName -Text $commandLine -ProjectName $projectName) {
            $uncertain += ConvertTo-PHMProcessSummary -Record $record -Reason '只有项目名称，没有完整项目路径，无法证明归属。'
        }
    }

    $addedChild = $true
    while ($addedChild) {
        $addedChild = $false
        foreach ($record in $records) {
            $id = [int](Get-PHMObjectProperty -InputObject $record -Name 'Id' -DefaultValue 0)
            $parentId = [int](Get-PHMObjectProperty -InputObject $record -Name 'ParentProcessId' -DefaultValue 0)
            $name = [string](Get-PHMObjectProperty -InputObject $record -Name 'Name' -DefaultValue '')
            if ($candidateIds.ContainsKey($id) -or -not $candidateIds.ContainsKey($parentId)) { continue }
            if ($name -match $protectedPattern) {
                $skipped += ConvertTo-PHMProcessSummary -Record $record -Reason '保护进程：父进程属于项目，但本进程仍默认跳过。'
                continue
            }
            $summary = ConvertTo-PHMProcessSummary -Record $record -Evidence "父进程 $parentId 已由完整项目路径确认"
            $candidates += $summary
            $candidateIds[$id] = $true
            $addedChild = $true
        }
    }

    $estimatedMemory = 0.0
    foreach ($candidate in $candidates) { $estimatedMemory += [double]$candidate.MemoryMB }
    [pscustomobject]@{
        ProjectPath      = $normalizedProjectPath
        GeneratedAt      = (Get-Date).ToUniversalTime().ToString('o')
        StopCandidates   = @($candidates | Sort-Object Id -Unique)
        Skipped          = @($skipped | Sort-Object Id -Unique)
        Uncertain        = @($uncertain | Sort-Object Id -Unique)
        EstimatedMemoryMB = [math]::Round($estimatedMemory, 2)
        RequiresConfirmation = $true
    }
}

function Invoke-PHMDefaultProcessStopper {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Candidate)

    try {
        $process = Get-Process -Id ([int]$Candidate.Id) -ErrorAction Stop
        if ($process.HasExited) {
            return [pscustomobject]@{ Exited = $true; Error = $null }
        }

        $closeRequested = $false
        try { $closeRequested = $process.CloseMainWindow() } catch { $closeRequested = $false }
        if ($closeRequested) {
            try { $process.WaitForExit(2000) | Out-Null } catch {}
            $process.Refresh()
        }

        if (-not $process.HasExited) {
            Stop-Process -Id $process.Id -ErrorAction Stop
            try { $process.WaitForExit(3000) | Out-Null } catch {}
        }

        $stillRunning = Get-Process -Id $process.Id -ErrorAction SilentlyContinue
        [pscustomobject]@{ Exited = ($null -eq $stillRunning); Error = if ($stillRunning) { '进程未退出' } else { $null } }
    }
    catch {
        $existing = Get-Process -Id ([int]$Candidate.Id) -ErrorAction SilentlyContinue
        if (-not $existing) {
            return [pscustomobject]@{ Exited = $true; Error = $null }
        }
        return [pscustomobject]@{ Exited = $false; Error = $_.Exception.Message }
    }
}

function Suspend-PHMProject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [string]$ComputerName = $env:COMPUTERNAME,
        [object[]]$ProcessRecords,
        [switch]$ConfirmStop,
        [scriptblock]$ProcessStopper
    )

    if (-not (Test-Path -LiteralPath $ProjectPath -PathType Container)) {
        throw "项目文件夹不存在：$ProjectPath"
    }

    $planParameters = @{ ProjectPath = $ProjectPath }
    if ($PSBoundParameters.ContainsKey('ProcessRecords')) {
        $planParameters.ProcessRecords = @($ProcessRecords)
    }
    $plan = Get-PHMProjectProcessPlan @planParameters
    $expected = if ($plan.StopCandidates.Count -gt 0) {
        "预计停止 $($plan.StopCandidates.Count) 个明确属于项目的进程，预计释放 $($plan.EstimatedMemoryMB) MB 内存；归属不明和保护进程保持运行。"
    }
    else {
        '没有发现可安全停止的项目进程；确认后仍会更新项目交接状态为已暂停。'
    }

    if (-not $ConfirmStop) {
        return [pscustomobject]@{
            Executed       = $false
            RequiresConfirmation = $true
            Plan           = $plan
            ExpectedResult = $expected
            Message        = '当前仅为执行预览；尚未停止进程、更新状态或删除文件。'
        }
    }

    Initialize-PHMProject -ProjectPath $ProjectPath -ComputerName $ComputerName -InitialState 'local_active' | Out-Null
    $identityPath = Join-Path $ProjectPath '项目交接\项目身份.json'
    $identityBefore = Get-Content -LiteralPath $identityPath -Raw | ConvertFrom-Json
    $since = if ($identityBefore.last_updated) { [datetime]::Parse([string]$identityBefore.last_updated).ToUniversalTime() } else { [datetime]::MinValue }
    $changes = Get-PHMProjectChanges -ProjectPath $ProjectPath -Since $since

    $usingCustomStopper = $PSBoundParameters.ContainsKey('ProcessStopper')
    if (-not $ProcessStopper) {
        $ProcessStopper = { param($candidate) Invoke-PHMDefaultProcessStopper -Candidate $candidate }
    }
    $stopped = @()
    $failed = @()
    foreach ($candidate in @($plan.StopCandidates | Sort-Object Id -Descending)) {
        try {
            $stopResult = & $ProcessStopper $candidate
            if ($stopResult -and [bool]$stopResult.Exited) {
                $stopped += $candidate
            }
            else {
                $failed += [pscustomobject]@{
                    Id    = $candidate.Id
                    Name  = $candidate.Name
                    Error = if ($stopResult) { [string]$stopResult.Error } else { '停止器没有返回结果' }
                }
            }
        }
        catch {
            $failed += [pscustomobject]@{ Id = $candidate.Id; Name = $candidate.Name; Error = $_.Exception.Message }
        }
    }

    $environmentPath = Update-PHMEnvironmentManifest -ProjectPath $ProjectPath -ComputerName $ComputerName
    $identity = Update-PHMIdentity -ProjectPath $ProjectPath -ComputerName $ComputerName -Operation 'pause' -State 'local_paused'
    $reportPath = Add-PHMHandoffRecord -ProjectPath $ProjectPath -ComputerName $ComputerName -ActionLabel '暂停当前项目' -Changes $changes -ValidationResult "停止成功：$($stopped.Count)；停止失败：$($failed.Count)"

    $releasedMemory = 0.0
    foreach ($candidate in $stopped) { $releasedMemory += [double]$candidate.MemoryMB }
    if ($usingCustomStopper -or $PSBoundParameters.ContainsKey('ProcessRecords')) {
        $failedIds = @($failed | ForEach-Object Id)
        $remaining = @($plan.StopCandidates | Where-Object { $failedIds -contains $_.Id })
    }
    else {
        $remaining = @($plan.StopCandidates | Where-Object { Get-Process -Id ([int]$_.Id) -ErrorAction SilentlyContinue })
    }

    [pscustomobject]@{
        Executed                = $true
        ProjectId               = [string]$identity.project_id
        State                   = [string]$identity.state
        Plan                    = $plan
        StoppedProcesses        = @($stopped)
        FailedProcesses         = @($failed)
        RemainingCandidates     = @($remaining)
        ActualReleasedMemoryMB  = [math]::Round($releasedMemory, 2)
        EnvironmentPath         = $environmentPath
        ReportPath              = $reportPath
        UsedPortableDrive       = $false
        DeletedFiles            = 0
    }
}

function Test-PHMPortableDrive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Actual,
        [string]$ExpectedDriveLetter,
        [string]$ExpectedVolumeLabel,
        [string]$ExpectedFileSystem,
        [string]$ExpectedFriendlyName,
        [string]$ExpectedVolumeSerial,
        [string]$ExpectedDeviceId,
        [long]$RequiredBytes = 0
    )

    $driveLetter = [string](Get-PHMObjectProperty -InputObject $Actual -Name 'DriveLetter' -DefaultValue '')
    $volumeLabel = [string](Get-PHMObjectProperty -InputObject $Actual -Name 'VolumeLabel' -DefaultValue '')
    $fileSystem = [string](Get-PHMObjectProperty -InputObject $Actual -Name 'FileSystem' -DefaultValue '')
    $friendlyName = [string](Get-PHMObjectProperty -InputObject $Actual -Name 'FriendlyName' -DefaultValue '')
    $health = [string](Get-PHMObjectProperty -InputObject $Actual -Name 'HealthStatus' -DefaultValue '')
    $operational = [string](Get-PHMObjectProperty -InputObject $Actual -Name 'OperationalStatus' -DefaultValue '')
    $isReadOnly = [bool](Get-PHMObjectProperty -InputObject $Actual -Name 'IsReadOnly' -DefaultValue $true)
    $isOffline = [bool](Get-PHMObjectProperty -InputObject $Actual -Name 'IsOffline' -DefaultValue $true)
    $freeBytes = [long](Get-PHMObjectProperty -InputObject $Actual -Name 'FreeBytes' -DefaultValue 0)
    $actualVolumeSerial = [string](Get-PHMObjectProperty -InputObject $Actual -Name 'VolumeSerial' -DefaultValue '')
    $actualDeviceId = [string](Get-PHMObjectProperty -InputObject $Actual -Name 'DeviceId' -DefaultValue '')
    $blockers = @()

    if ($ExpectedDriveLetter -and $driveLetter.TrimEnd('\') -ne $ExpectedDriveLetter.TrimEnd('\')) { $blockers += "盘符不匹配：期望 $ExpectedDriveLetter。" }
    if ($ExpectedVolumeLabel -and $volumeLabel -ne $ExpectedVolumeLabel) { $blockers += "卷标不匹配：期望 $ExpectedVolumeLabel。" }
    if ($ExpectedFileSystem -and $fileSystem -ne $ExpectedFileSystem) { $blockers += "文件系统不匹配：期望 $ExpectedFileSystem。" }
    if ($ExpectedFriendlyName -and $friendlyName -ne $ExpectedFriendlyName) { $blockers += "设备型号不匹配：期望 $ExpectedFriendlyName。" }
    if ($ExpectedVolumeSerial -and $actualVolumeSerial -ne $ExpectedVolumeSerial) { $blockers += '卷序列不匹配；可能插入了错误磁盘。' }
    if ($ExpectedDeviceId -and $actualDeviceId -ne $ExpectedDeviceId) { $blockers += '项目管家设备标识不匹配。' }
    if ($health -and $health -ne 'Healthy') { $blockers += "磁盘健康状态异常：$health。" }
    if ($operational -and $operational -notmatch '^(OK|Online)$') { $blockers += "磁盘运行状态异常：$operational。" }
    if ($isReadOnly) { $blockers += '磁盘为只读状态。' }
    if ($isOffline) { $blockers += '磁盘处于离线状态。' }
    if ($freeBytes -lt $RequiredBytes) { $blockers += "空间不足：需要 $RequiredBytes 字节，可用 $freeBytes 字节。" }

    [pscustomobject]@{
        IsValid          = ($blockers.Count -eq 0)
        Blockers         = @($blockers)
        DriveLetter      = $driveLetter
        VolumeLabel      = $volumeLabel
        FileSystem       = $fileSystem
        FriendlyName     = $friendlyName
        HealthStatus     = $health
        OperationalStatus = $operational
        IsReadOnly       = $isReadOnly
        IsOffline        = $isOffline
        FreeBytes        = $freeBytes
        RequiredBytes    = $RequiredBytes
        IdentityChecked  = [bool]($ExpectedVolumeSerial -or $ExpectedDeviceId)
    }
}

function Get-PHMPortableDriveInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DriveLetter,
        [string]$DeviceMarkerPath
    )

    $letter = $DriveLetter.TrimEnd(':','\')
    $volume = Get-Volume -DriveLetter $letter -ErrorAction Stop
    $partition = Get-Partition -DriveLetter $letter -ErrorAction Stop
    $disk = $partition | Get-Disk -ErrorAction Stop
    $logicalDisk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$letter`:'" -ErrorAction SilentlyContinue
    $deviceId = $null
    if ($DeviceMarkerPath -and (Test-Path -LiteralPath $DeviceMarkerPath -PathType Leaf)) {
        try {
            $marker = Get-Content -LiteralPath $DeviceMarkerPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $deviceId = [string]$marker.device_id
        }
        catch { throw "项目管家设备标识文件损坏：$DeviceMarkerPath。$($_.Exception.Message)" }
    }

    [pscustomobject]@{
        DriveLetter      = "$letter`:"
        VolumeLabel      = [string]$volume.FileSystemLabel
        FileSystem       = [string]$volume.FileSystem
        HealthStatus     = [string]$volume.HealthStatus
        OperationalStatus = [string]($volume.OperationalStatus -join ',')
        IsReadOnly       = [bool]$disk.IsReadOnly
        IsOffline        = [bool]$disk.IsOffline
        FreeBytes        = [long]$volume.SizeRemaining
        FriendlyName     = [string]$disk.FriendlyName
        VolumeSerial     = [string]$logicalDisk.VolumeSerialNumber
        DeviceId         = $deviceId
    }
}

function Register-PHMPortableDevice {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$DriveInfo,
        [Parameter(Mandatory)][string]$DeviceMarkerPath,
        [Parameter(Mandatory)][string]$LocalTrustPath,
        [switch]$ConfirmRegistration,
        [string]$ExpectedDriveLetter = 'T:',
        [string]$ExpectedVolumeLabel = 'T9',
        [string]$ExpectedFileSystem = 'NTFS',
        [string]$ExpectedFriendlyName = 'Samsung PSSD T9'
    )

    $validation = Test-PHMPortableDrive -Actual $DriveInfo -ExpectedDriveLetter $ExpectedDriveLetter -ExpectedVolumeLabel $ExpectedVolumeLabel -ExpectedFileSystem $ExpectedFileSystem -ExpectedFriendlyName $ExpectedFriendlyName
    if (-not $validation.IsValid) {
        return [pscustomobject]@{ Executed=$false; RequiresConfirmation=$false; DeviceMarkerPath=$DeviceMarkerPath; LocalTrustPath=$LocalTrustPath; Blockers=@($validation.Blockers) }
    }
    if (-not $ConfirmRegistration) {
        return [pscustomobject]@{
            Executed=$false; RequiresConfirmation=$true; DeviceMarkerPath=$DeviceMarkerPath; LocalTrustPath=$LocalTrustPath; Blockers=@()
            ExpectedResult='移动盘写入随机设备标识；本机信任文件保存该标识和卷序列。两者均不进入公开仓库。'
        }
    }

    $deviceId = [guid]::NewGuid().ToString()
    if (Test-Path -LiteralPath $DeviceMarkerPath -PathType Leaf) {
        $existingMarker = Get-Content -LiteralPath $DeviceMarkerPath -Raw | ConvertFrom-Json -ErrorAction Stop
        if ($existingMarker.device_id) { $deviceId = [string]$existingMarker.device_id }
    }
    if (Test-Path -LiteralPath $LocalTrustPath -PathType Leaf) {
        $existingTrust = Get-Content -LiteralPath $LocalTrustPath -Raw | ConvertFrom-Json -ErrorAction Stop
        $actualSerial = [string](Get-PHMObjectProperty -InputObject $DriveInfo -Name 'VolumeSerial' -DefaultValue '')
        if ($existingTrust.device_id -ne $deviceId -or $existingTrust.volume_serial -ne $actualSerial) {
            return [pscustomobject]@{ Executed=$false; RequiresConfirmation=$false; DeviceMarkerPath=$DeviceMarkerPath; LocalTrustPath=$LocalTrustPath; Blockers=@('现有设备标识或卷序列与当前磁盘不一致。') }
        }
    }

    New-Item -ItemType Directory -Path (Split-Path $DeviceMarkerPath -Parent),(Split-Path $LocalTrustPath -Parent) -Force | Out-Null
    $marker = [ordered]@{
        schema_version = 1
        device_id      = $deviceId
        volume_label   = [string](Get-PHMObjectProperty -InputObject $DriveInfo -Name 'VolumeLabel' -DefaultValue '')
        created_at     = (Get-Date).ToUniversalTime().ToString('o')
    }
    $trust = [ordered]@{
        schema_version = 1
        device_id      = $deviceId
        volume_serial  = [string](Get-PHMObjectProperty -InputObject $DriveInfo -Name 'VolumeSerial' -DefaultValue '')
        drive_letter   = [string](Get-PHMObjectProperty -InputObject $DriveInfo -Name 'DriveLetter' -DefaultValue '')
        friendly_name  = [string](Get-PHMObjectProperty -InputObject $DriveInfo -Name 'FriendlyName' -DefaultValue '')
        registered_at  = (Get-Date).ToUniversalTime().ToString('o')
    }
    Write-PHMUtf8File -Path $DeviceMarkerPath -Content ($marker | ConvertTo-Json -Depth 5)
    Write-PHMUtf8File -Path $LocalTrustPath -Content ($trust | ConvertTo-Json -Depth 5)
    [pscustomobject]@{ Executed=$true; RequiresConfirmation=$false; DeviceMarkerPath=$DeviceMarkerPath; LocalTrustPath=$LocalTrustPath; Blockers=@() }
}

function Get-PHMStringHash {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        return ([System.BitConverter]::ToString($algorithm.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally { $algorithm.Dispose() }
}

function Get-PHMProjectInventory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectPath)

    if (-not (Test-Path -LiteralPath $ProjectPath -PathType Container)) {
        throw "项目文件夹不存在：$ProjectPath"
    }
    $root = (Get-Item -LiteralPath $ProjectPath).FullName
    $stack = [System.Collections.Generic.Stack[string]]::new()
    $stack.Push($root)
    $files = @()
    $directories = @()
    $reparsePoints = @()
    $unreadable = @()

    while ($stack.Count -gt 0) {
        $directoryPath = $stack.Pop()
        try {
            $children = @(Get-ChildItem -LiteralPath $directoryPath -Force -ErrorAction Stop)
        }
        catch {
            $unreadable += [pscustomobject]@{ RelativePath = Get-PHMRelativePath -BasePath $root -Path $directoryPath; Error = $_.Exception.Message }
            continue
        }

        foreach ($child in $children) {
            $relativePath = Get-PHMRelativePath -BasePath $root -Path $child.FullName
            $isReparsePoint = [bool]($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint)
            if ($isReparsePoint) {
                $reparsePoints += [pscustomobject]@{
                    RelativePath = $relativePath
                    Type         = if ($child.PSIsContainer) { 'Directory' } else { 'File' }
                    LinkType     = [string](Get-PHMObjectProperty -InputObject $child -Name 'LinkType' -DefaultValue 'ReparsePoint')
                }
                continue
            }
            if ($child.PSIsContainer) {
                $directories += [pscustomobject]@{ RelativePath = $relativePath; LastModified = $child.LastWriteTimeUtc.ToString('o') }
                $stack.Push($child.FullName)
                continue
            }

            $isCritical = $relativePath -in @(
                '项目交接\项目身份.json',
                '项目交接\项目交接报告.md',
                '项目交接\环境清单.json'
            )
            $files += [pscustomobject]@{
                RelativePath = $relativePath
                FullPath     = $child.FullName
                Size         = [long]$child.Length
                LastModified = $child.LastWriteTimeUtc.ToString('o')
                IsCritical   = $isCritical
                IsBulky      = ($relativePath -match '^(?i:node_modules|\.venv|项目缓存|离线依赖|\.git\\objects)\\')
                Hash         = $null
                HashPolicy   = 'full'
            }
        }
    }

    $files = @($files | Sort-Object RelativePath)
    foreach ($file in $files) {
        try {
            $file.Hash = (Get-FileHash -LiteralPath $file.FullPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        }
        catch {
            $unreadable += [pscustomobject]@{ RelativePath = $file.RelativePath; Error = $_.Exception.Message }
        }
    }

    [long]$totalBytes = 0
    foreach ($file in $files) { $totalBytes += $file.Size }
    $manifestLines = @($files | ForEach-Object { "$($_.RelativePath)|$($_.Size)|$($_.LastModified)|$($_.Hash)" })
    $manifestDigest = Get-PHMStringHash -Text ($manifestLines -join "`n")

    [pscustomobject]@{
        RootPath       = $root
        FileCount      = $files.Count
        DirectoryCount = $directories.Count
        TotalBytes     = $totalBytes
        Files          = @($files)
        Directories    = @($directories | Sort-Object RelativePath)
        CriticalFiles  = @($files | Where-Object IsCritical)
        ReparsePoints  = @($reparsePoints)
        Unreadable     = @($unreadable)
        ManifestDigest = $manifestDigest
    }
}

function Get-PHMSensitiveFiles {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Inventory)

    @($Inventory.Files | Where-Object {
        $name = Split-Path $_.RelativePath -Leaf
        $name -match '^(?i:\.env(?:\..+)?|id_rsa|id_ed25519|credentials.*\.json)$' -or
        $name -match '(?i:\.(pem|key|pfx|p12))$'
    } | ForEach-Object RelativePath)
}

function New-PHMCheckinPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [Parameter(Mandatory)][string]$PortableRepositoryRoot,
        [Parameter(Mandatory)]$DriveInfo,
        [object[]]$ProcessRecords,
        [switch]$AllowSensitiveFiles,
        [string]$ExpectedDriveLetter = 'T:',
        [string]$ExpectedVolumeLabel = 'T9',
        [string]$ExpectedFileSystem = 'NTFS',
        [string]$ExpectedFriendlyName = 'Samsung PSSD T9',
        [string]$ExpectedVolumeSerial,
        [string]$ExpectedDeviceId
    )

    if (-not (Test-Path -LiteralPath $ProjectPath -PathType Container)) {
        throw "项目文件夹不存在：$ProjectPath"
    }
    $sourcePath = (Get-Item -LiteralPath $ProjectPath).FullName
    $projectName = Split-Path $sourcePath -Leaf
    $identitySummary = Get-PHMIdentitySummary -ProjectPath $sourcePath
    $projectId = $identitySummary.ProjectId
    if (-not $projectId) {
        $projectId = [guid]::NewGuid().ToString()
    }

    $inventory = Get-PHMProjectInventory -ProjectPath $sourcePath
    $requiredBytes = [long]($inventory.TotalBytes + [math]::Max(100MB, [math]::Ceiling($inventory.TotalBytes * 0.1)))
    $driveValidation = Test-PHMPortableDrive -Actual $DriveInfo -ExpectedDriveLetter $ExpectedDriveLetter -ExpectedVolumeLabel $ExpectedVolumeLabel -ExpectedFileSystem $ExpectedFileSystem -ExpectedFriendlyName $ExpectedFriendlyName -ExpectedVolumeSerial $ExpectedVolumeSerial -ExpectedDeviceId $ExpectedDeviceId -RequiredBytes $requiredBytes
    $receivingPath = Join-Path $PortableRepositoryRoot "正在接收\$projectId\$projectName"
    $officialPath = Join-Path $PortableRepositoryRoot "暂停项目\$projectName"
    $blockers = @($driveValidation.Blockers)
    if ($inventory.ReparsePoints.Count -gt 0) { $blockers += "发现 $($inventory.ReparsePoints.Count) 个重解析点；为防止复制项目外内容，归还已阻断。" }
    if ($inventory.Unreadable.Count -gt 0) { $blockers += "发现 $($inventory.Unreadable.Count) 个无法读取的文件或目录。" }
    if (Test-Path -LiteralPath $receivingPath) { $blockers += "临时接收目录已存在：$receivingPath。请先修复未完成转移。" }
    if (Test-Path -LiteralPath $officialPath) { $blockers += "正式目录已存在：$officialPath。禁止自动覆盖。" }

    $sensitiveFiles = @(Get-PHMSensitiveFiles -Inventory $inventory)
    $requiresSensitiveConfirmation = ($sensitiveFiles.Count -gt 0 -and -not $AllowSensitiveFiles)
    if ($requiresSensitiveConfirmation) { $blockers += "发现 $($sensitiveFiles.Count) 个可能包含凭据的敏感文件；需要明确确认随完整项目迁移。" }

    $pauseParameters = @{ ProjectPath = $sourcePath }
    if ($PSBoundParameters.ContainsKey('ProcessRecords')) { $pauseParameters.ProcessRecords = @($ProcessRecords) }
    $pausePlan = Get-PHMProjectProcessPlan @pauseParameters
    $requiresPauseConfirmation = $pausePlan.StopCandidates.Count -gt 0
    if ($requiresPauseConfirmation) { $blockers += "发现 $($pausePlan.StopCandidates.Count) 个明确属于项目的运行进程；必须先确认暂停。" }

    [pscustomobject]@{
        CanExecute                    = ($blockers.Count -eq 0)
        SourcePath                    = $sourcePath
        ProjectName                   = $projectName
        ProjectId                     = $projectId
        NeedsAdoption                 = (-not $identitySummary.Managed)
        PortableRepositoryRoot        = $PortableRepositoryRoot
        ReceivingPath                 = $receivingPath
        OfficialPath                  = $officialPath
        Inventory                     = $inventory
        RequiredBytes                 = $requiredBytes
        DriveValidation               = $driveValidation
        PausePlan                     = $pausePlan
        RequiresPauseConfirmation     = $requiresPauseConfirmation
        SensitiveFiles                = @($sensitiveFiles)
        RequiresSensitiveConfirmation = $requiresSensitiveConfirmation
        ReparsePoints                 = @($inventory.ReparsePoints)
        ExcludedFiles                 = @()
        Blockers                      = @($blockers)
        ExpectedResult                = '确认后将暂停项目、更新交接、复制到空暂存目录、校验并提交为 T9 正式副本；本机来源不会在本阶段删除。'
    }
}

function Copy-PHMProjectDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )

    $parent = Split-Path $Destination -Parent
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $output = & robocopy $Source $Destination /E /COPY:DAT /DCOPY:DAT /R:1 /W:1 /XJ /SL /NP /NFL /NDL /NJH /NJS 2>&1
    $exitCode = $LASTEXITCODE
    [pscustomobject]@{
        Success  = ($exitCode -le 7)
        ExitCode = $exitCode
        Message  = ($output -join [Environment]::NewLine)
    }
}

function Compare-PHMProjectInventories {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$SourceInventory,
        [Parameter(Mandatory)]$DestinationInventory,
        [bool]$RequireManagementFiles = $true
    )

    $differences = @()
    $destinationByPath = @{}
    foreach ($file in @($DestinationInventory.Files)) { $destinationByPath[$file.RelativePath.ToLowerInvariant()] = $file }
    foreach ($sourceFile in @($SourceInventory.Files)) {
        $key = $sourceFile.RelativePath.ToLowerInvariant()
        if (-not $destinationByPath.ContainsKey($key)) {
            $differences += "目标缺少文件：$($sourceFile.RelativePath)"
            continue
        }
        $destinationFile = $destinationByPath[$key]
        if ([long]$sourceFile.Size -ne [long]$destinationFile.Size) {
            $differences += "文件大小不一致：$($sourceFile.RelativePath)"
        }
        if ($sourceFile.Hash -and $destinationFile.Hash -and $sourceFile.Hash -ne $destinationFile.Hash) {
            $differences += "文件哈希不一致：$($sourceFile.RelativePath)"
        }
    }
    $sourcePaths = @($SourceInventory.Files | ForEach-Object { $_.RelativePath.ToLowerInvariant() })
    foreach ($destinationFile in @($DestinationInventory.Files)) {
        if ($sourcePaths -notcontains $destinationFile.RelativePath.ToLowerInvariant()) {
            $differences += "目标多出文件：$($destinationFile.RelativePath)"
        }
    }
    if ($SourceInventory.FileCount -ne $DestinationInventory.FileCount) { $differences += '文件总数不一致。' }
    if ($SourceInventory.TotalBytes -ne $DestinationInventory.TotalBytes) { $differences += '总字节数不一致。' }

    foreach ($criticalPath in $(if ($RequireManagementFiles) { @('项目交接\项目身份.json', '项目交接\项目交接报告.md', '项目交接\环境清单.json') } else { @() })) {
        $target = @($DestinationInventory.Files | Where-Object RelativePath -eq $criticalPath)
        if ($target.Count -eq 0) { $differences += "缺少关键管理文件：$criticalPath"; continue }
        try {
            if ($criticalPath.EndsWith('.json')) {
                Get-Content -LiteralPath $target[0].FullPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop | Out-Null
            }
            elseif ([string]::IsNullOrWhiteSpace((Get-Content -LiteralPath $target[0].FullPath -Raw -ErrorAction Stop))) {
                throw '文件为空'
            }
        }
        catch { $differences += "关键管理文件不可解析：$criticalPath" }
    }

    [pscustomobject]@{
        IsMatch     = ($differences.Count -eq 0)
        Differences = @($differences)
        SourceFiles = $SourceInventory.FileCount
        TargetFiles = $DestinationInventory.FileCount
        SourceBytes = $SourceInventory.TotalBytes
        TargetBytes = $DestinationInventory.TotalBytes
    }
}

function Get-PHMCleanupDigest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectPath)

    $inventory = Get-PHMProjectInventory -ProjectPath $ProjectPath
    $lines = @($inventory.Files | Where-Object { $_.RelativePath -notin @('项目交接\转移凭证.json', '项目交接\借出最终化恢复.json') } | ForEach-Object {
        "$($_.RelativePath)|$($_.Size)|$($_.LastModified)|$($_.Hash)"
    })
    Get-PHMStringHash -Text ($lines -join "`n")
}

function Write-PHMRegistry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RegistryPath,
        [Parameter(Mandatory)]$Record
    )

    $directory = Split-Path $RegistryPath -Parent
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    if (Test-Path -LiteralPath $RegistryPath -PathType Leaf) {
        $registry = Get-Content -LiteralPath $RegistryPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    else {
        $registry = [pscustomobject]@{ schemaVersion = 1; updatedAt = $null; projects = @() }
    }
    $projects = @($registry.projects | Where-Object projectId -ne $Record.projectId)
    $projects += $Record
    $updated = [ordered]@{
        schemaVersion = 1
        updatedAt     = (Get-Date).ToUniversalTime().ToString('o')
        projects      = @($projects | Sort-Object projectName)
    }
    $tempPath = "$RegistryPath.tmp-$([guid]::NewGuid().ToString('N'))"
    $backupPath = "$RegistryPath.bak"
    Write-PHMUtf8File -Path $tempPath -Content ($updated | ConvertTo-Json -Depth 10)
    Get-Content -LiteralPath $tempPath -Raw | ConvertFrom-Json -ErrorAction Stop | Out-Null
    if (Test-Path -LiteralPath $RegistryPath) {
        if (Test-Path -LiteralPath $backupPath) { Remove-Item -LiteralPath $backupPath -Force }
        [System.IO.File]::Replace($tempPath, $RegistryPath, $backupPath, $true)
    }
    else { [System.IO.File]::Move($tempPath, $RegistryPath) }
    return $RegistryPath
}

function Get-PHMRegistryPathFromRepository {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PortableRepositoryRoot)
    Join-Path (Split-Path $PortableRepositoryRoot -Parent) '管理资料\项目登记.json'
}

function New-PHMEmptyChanges {
    [pscustomobject]@{ NewMaterials = @(); NewOutputs = @(); Unclassified = @() }
}

function Invoke-PHMCheckin {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [Parameter(Mandatory)][string]$PortableRepositoryRoot,
        [Parameter(Mandatory)]$DriveInfo,
        [object[]]$ProcessRecords,
        [switch]$ConfirmTransfer,
        [switch]$ConfirmProcessStop,
        [switch]$AllowSensitiveFiles,
        [scriptblock]$ProcessStopper,
        [scriptblock]$CopyAction,
        [scriptblock]$RegistryWriter,
        [string]$ComputerName = $env:COMPUTERNAME,
        [string]$ExpectedVolumeSerial,
        [string]$ExpectedDeviceId
    )

    $planParameters = @{
        ProjectPath=$ProjectPath; PortableRepositoryRoot=$PortableRepositoryRoot; DriveInfo=$DriveInfo
        AllowSensitiveFiles=$AllowSensitiveFiles; ExpectedVolumeSerial=$ExpectedVolumeSerial; ExpectedDeviceId=$ExpectedDeviceId
    }
    if ($PSBoundParameters.ContainsKey('ProcessRecords')) { $planParameters.ProcessRecords = @($ProcessRecords) }
    $plan = New-PHMCheckinPlan @planParameters
    if (-not $ConfirmTransfer) {
        return [pscustomobject]@{ Executed=$false; Verified=$false; RequiresConfirmation=$true; Plan=$plan; OfficialPath=$plan.OfficialPath; ReceivingPath=$plan.ReceivingPath; DeletedFiles=0 }
    }
    if ($plan.RequiresSensitiveConfirmation -and -not $AllowSensitiveFiles) {
        return [pscustomobject]@{ Executed=$false; Verified=$false; FailureStage='sensitive-confirmation'; Plan=$plan; OfficialPath=$plan.OfficialPath; ReceivingPath=$plan.ReceivingPath; DeletedFiles=0 }
    }
    if ($plan.RequiresPauseConfirmation -and -not $ConfirmProcessStop) {
        return [pscustomobject]@{ Executed=$false; Verified=$false; FailureStage='pause-confirmation'; Plan=$plan; OfficialPath=$plan.OfficialPath; ReceivingPath=$plan.ReceivingPath; DeletedFiles=0 }
    }

    $pauseParameters = @{ ProjectPath=$ProjectPath; ComputerName=$ComputerName; ConfirmStop=$true }
    if ($PSBoundParameters.ContainsKey('ProcessRecords')) { $pauseParameters.ProcessRecords = @($ProcessRecords) }
    if ($ProcessStopper) { $pauseParameters.ProcessStopper = $ProcessStopper }
    $pauseResult = Suspend-PHMProject @pauseParameters
    if ($pauseResult.RemainingCandidates.Count -gt 0) {
        return [pscustomobject]@{ Executed=$false; Verified=$false; FailureStage='pause'; Plan=$plan; PauseResult=$pauseResult; OfficialPath=$plan.OfficialPath; ReceivingPath=$plan.ReceivingPath; DeletedFiles=0 }
    }

    $executionPlanParameters = @{
        ProjectPath=$ProjectPath; PortableRepositoryRoot=$PortableRepositoryRoot; DriveInfo=$DriveInfo
        AllowSensitiveFiles=$AllowSensitiveFiles; ExpectedVolumeSerial=$ExpectedVolumeSerial; ExpectedDeviceId=$ExpectedDeviceId
    }
    if ($PSBoundParameters.ContainsKey('ProcessRecords')) { $executionPlanParameters.ProcessRecords = @() }
    $plan = New-PHMCheckinPlan @executionPlanParameters
    if (-not $plan.CanExecute) {
        return [pscustomobject]@{ Executed=$false; Verified=$false; FailureStage='preflight'; Plan=$plan; OfficialPath=$plan.OfficialPath; ReceivingPath=$plan.ReceivingPath; DeletedFiles=0 }
    }

    $sourceBefore = Get-PHMProjectInventory -ProjectPath $plan.SourcePath
    if (-not $CopyAction) { $CopyAction = { param($source,$destination) Copy-PHMProjectDirectory -Source $source -Destination $destination } }
    try { $copyResult = & $CopyAction $plan.SourcePath $plan.ReceivingPath }
    catch { $copyResult = [pscustomobject]@{ Success=$false; ExitCode=-1; Message=$_.Exception.Message } }
    if (-not $copyResult -or -not [bool]$copyResult.Success) {
        Update-PHMIdentity -ProjectPath $plan.SourcePath -ComputerName $ComputerName -Operation 'checkin-copy-failed' -State 'transfer_incomplete' | Out-Null
        return [pscustomobject]@{ Executed=$false; Verified=$false; FailureStage='copy'; CopyResult=$copyResult; OfficialPath=$plan.OfficialPath; ReceivingPath=$plan.ReceivingPath; DeletedFiles=0 }
    }

    $sourceAfter = Get-PHMProjectInventory -ProjectPath $plan.SourcePath
    if ($sourceBefore.ManifestDigest -ne $sourceAfter.ManifestDigest) {
        Update-PHMIdentity -ProjectPath $plan.SourcePath -ComputerName $ComputerName -Operation 'checkin-source-changed' -State 'transfer_incomplete' | Out-Null
        return [pscustomobject]@{ Executed=$false; Verified=$false; FailureStage='source-changed'; OfficialPath=$plan.OfficialPath; ReceivingPath=$plan.ReceivingPath; DeletedFiles=0 }
    }
    $targetInventory = Get-PHMProjectInventory -ProjectPath $plan.ReceivingPath
    $verification = Compare-PHMProjectInventories -SourceInventory $sourceAfter -DestinationInventory $targetInventory
    if (-not $verification.IsMatch) {
        Update-PHMIdentity -ProjectPath $plan.SourcePath -ComputerName $ComputerName -Operation 'checkin-verification-failed' -State 'transfer_incomplete' | Out-Null
        return [pscustomobject]@{ Executed=$false; Verified=$false; FailureStage='verification'; Verification=$verification; OfficialPath=$plan.OfficialPath; ReceivingPath=$plan.ReceivingPath; DeletedFiles=0 }
    }

    New-Item -ItemType Directory -Path (Split-Path $plan.OfficialPath -Parent) -Force | Out-Null
    Move-Item -LiteralPath $plan.ReceivingPath -Destination $plan.OfficialPath -ErrorAction Stop
    Update-PHMIdentity -ProjectPath $plan.SourcePath -ComputerName $ComputerName -Operation 'checkin' -State 'cleanup_pending' -OfficialLocation $plan.OfficialPath | Out-Null
    Add-PHMHandoffRecord -ProjectPath $plan.SourcePath -ComputerName $ComputerName -ActionLabel '归还到 T9（等待清理本机来源）' -Changes (New-PHMEmptyChanges) -ValidationResult '目标项目已完成完整性校验。' | Out-Null
    $cleanupDigest = Get-PHMCleanupDigest -ProjectPath $plan.SourcePath
    $receipt = [ordered]@{
        schema_version         = 1
        operation              = 'checkin'
        project_id             = $plan.ProjectId
        source_path            = $plan.SourcePath
        target_path            = $plan.OfficialPath
        transferred_at         = (Get-Date).ToUniversalTime().ToString('o')
        source_manifest_digest = $cleanupDigest
    }
    $sourceReceiptPath = Join-Path $plan.SourcePath '项目交接\转移凭证.json'
    Write-PHMUtf8File -Path $sourceReceiptPath -Content ($receipt | ConvertTo-Json -Depth 5)
    foreach ($name in @('项目身份.json','项目交接报告.md','环境清单.json','转移凭证.json')) {
        [System.IO.File]::Copy((Join-Path $plan.SourcePath "项目交接\$name"), (Join-Path $plan.OfficialPath "项目交接\$name"), $true)
    }
    $finalSourceDigest = Get-PHMCleanupDigest -ProjectPath $plan.SourcePath
    $finalTargetDigest = Get-PHMCleanupDigest -ProjectPath $plan.OfficialPath
    if ($finalSourceDigest -ne $cleanupDigest -or $finalTargetDigest -ne $cleanupDigest) {
        return [pscustomobject]@{ Executed=$false; Verified=$false; FailureStage='finalization'; OfficialPath=$plan.OfficialPath; ReceivingPath=$plan.ReceivingPath; DeletedFiles=0 }
    }

    $registryPath = Get-PHMRegistryPathFromRepository -PortableRepositoryRoot $PortableRepositoryRoot
    $record = [pscustomobject]@{ projectId=$plan.ProjectId; projectName=$plan.ProjectName; state='cleanup_pending'; location=$plan.OfficialPath; updatedAt=(Get-Date).ToUniversalTime().ToString('o') }
    if (-not $RegistryWriter) { $RegistryWriter = { param($path,$item) Write-PHMRegistry -RegistryPath $path -Record $item } }
    try { & $RegistryWriter $registryPath $record | Out-Null }
    catch {
        return [pscustomobject]@{ Executed=$false; Verified=$true; FailureStage='registry'; Error=$_.Exception.Message; OfficialPath=$plan.OfficialPath; ReceivingPath=$plan.ReceivingPath; DeletedFiles=0; CleanupRequired=$true }
    }

    [pscustomobject]@{
        Executed=$true; Verified=$true; FailureStage=$null; ProjectId=$plan.ProjectId
        SourcePath=$plan.SourcePath; OfficialPath=$plan.OfficialPath; ReceivingPath=$plan.ReceivingPath
        Verification=$verification; CopyResult=$copyResult; RegistryPath=$registryPath
        CleanupRequired=$true; SourceStillExists=$true; DeletedFiles=0
        CleanupPrompt="目标项目已经完整校验。准备清理本机来源：$($plan.SourcePath)"
    }
}

function Test-PHMDeletionPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$ProtectedRoots = @()
    )

    try { $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\') } catch { return $false }
    $root = [System.IO.Path]::GetPathRoot($fullPath).TrimEnd('\')
    if ($fullPath -eq $root) { return $false }
    $userProfile = [System.IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\')
    if ($fullPath.Equals($userProfile, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    foreach ($protected in @($ProtectedRoots)) {
        if (-not $protected) { continue }
        $protectedFull = [System.IO.Path]::GetFullPath($protected).TrimEnd('\')
        if ($fullPath.Equals($protectedFull, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    }
    return $true
}

function Complete-PHMCheckinCleanup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$TargetPath,
        [switch]$ConfirmCleanup,
        [string[]]$ProtectedRoots = @()
    )

    $sourceFull = if (Test-Path -LiteralPath $SourcePath) { (Get-Item -LiteralPath $SourcePath).FullName } else { [System.IO.Path]::GetFullPath($SourcePath) }
    $targetFull = if (Test-Path -LiteralPath $TargetPath) { (Get-Item -LiteralPath $TargetPath).FullName } else { [System.IO.Path]::GetFullPath($TargetPath) }
    if (-not $ConfirmCleanup) {
        return [pscustomobject]@{ Executed=$false; RequiresConfirmation=$true; SourcePath=$sourceFull; TargetPath=$targetFull; ExpectedResult='删除本机来源后，T9 成为唯一正式完整副本。' }
    }
    if (-not (Test-PHMDeletionPath -Path $sourceFull -ProtectedRoots $ProtectedRoots)) {
        return [pscustomobject]@{ Executed=$false; RequiresConfirmation=$false; SourcePath=$sourceFull; TargetPath=$targetFull; BlockedReason='来源路径受删除保护。' }
    }
    if (-not (Test-Path -LiteralPath $sourceFull -PathType Container) -or -not (Test-Path -LiteralPath $targetFull -PathType Container)) {
        return [pscustomobject]@{ Executed=$false; BlockedReason='来源或目标项目不存在。'; SourcePath=$sourceFull; TargetPath=$targetFull }
    }
    $receiptPath = Join-Path $targetFull '项目交接\转移凭证.json'
    if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) {
        return [pscustomobject]@{ Executed=$false; BlockedReason='目标缺少转移凭证。'; SourcePath=$sourceFull; TargetPath=$targetFull }
    }
    $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
    if (-not $sourceFull.Equals([System.IO.Path]::GetFullPath([string]$receipt.source_path), [System.StringComparison]::OrdinalIgnoreCase) -or
        -not $targetFull.Equals([System.IO.Path]::GetFullPath([string]$receipt.target_path), [System.StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{ Executed=$false; BlockedReason='转移凭证路径与当前路径不一致。'; SourcePath=$sourceFull; TargetPath=$targetFull }
    }
    $sourceIdentity = Get-Content -LiteralPath (Join-Path $sourceFull '项目交接\项目身份.json') -Raw | ConvertFrom-Json
    $targetIdentity = Get-Content -LiteralPath (Join-Path $targetFull '项目交接\项目身份.json') -Raw | ConvertFrom-Json
    if ($sourceIdentity.project_id -ne $receipt.project_id -or $targetIdentity.project_id -ne $receipt.project_id) {
        return [pscustomobject]@{ Executed=$false; BlockedReason='项目编号不一致。'; SourcePath=$sourceFull; TargetPath=$targetFull }
    }
    $sourceDigest = Get-PHMCleanupDigest -ProjectPath $sourceFull
    $targetDigest = Get-PHMCleanupDigest -ProjectPath $targetFull
    if ($sourceDigest -ne $receipt.source_manifest_digest -or $targetDigest -ne $receipt.source_manifest_digest) {
        Update-PHMIdentity -ProjectPath $sourceFull -ComputerName $env:COMPUTERNAME -Operation 'cleanup-blocked' -State 'conflict' -OfficialLocation $targetFull | Out-Null
        Update-PHMIdentity -ProjectPath $targetFull -ComputerName $env:COMPUTERNAME -Operation 'cleanup-blocked' -State 'conflict' -OfficialLocation $targetFull | Out-Null
        return [pscustomobject]@{ Executed=$false; BlockedReason='来源或目标在复制后发生变化，已禁止自动清理并标记冲突。'; SourcePath=$sourceFull; TargetPath=$targetFull }
    }

    Remove-Item -LiteralPath $sourceFull -Recurse -Force -ErrorAction Stop
    $identity = Update-PHMIdentity -ProjectPath $targetFull -ComputerName $env:COMPUTERNAME -Operation 'checkin-cleanup' -State 'on_t9' -OfficialLocation $targetFull
    Add-PHMHandoffRecord -ProjectPath $targetFull -ComputerName $env:COMPUTERNAME -ActionLabel '完成归还并清理本机来源' -Changes (New-PHMEmptyChanges) -ValidationResult 'T9 为唯一正式完整副本。' | Out-Null
    $repositoryRoot = Split-Path (Split-Path $targetFull -Parent) -Parent
    $registryPath = Get-PHMRegistryPathFromRepository -PortableRepositoryRoot $repositoryRoot
    $record = [pscustomobject]@{ projectId=[string]$identity.project_id; projectName=[string]$identity.project_name; state='on_t9'; location=$targetFull; updatedAt=(Get-Date).ToUniversalTime().ToString('o') }
    Write-PHMRegistry -RegistryPath $registryPath -Record $record | Out-Null
    [pscustomobject]@{ Executed=$true; DeletedSource=$true; SourcePath=$sourceFull; TargetPath=$targetFull; State='on_t9'; RegistryPath=$registryPath }
}

function New-PHMDeterministicProjectId {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectPath)

    $normalized = [System.IO.Path]::GetFullPath($ProjectPath).TrimEnd('\').ToLowerInvariant()
    $hash = Get-PHMStringHash -Text $normalized
    return ([guid]::ParseExact($hash.Substring(0, 32), 'N')).ToString()
}

function Test-PHMPathWithin {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ParentPath
    )

    $candidate = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    $parent = [System.IO.Path]::GetFullPath($ParentPath).TrimEnd('\')
    return $candidate.Equals($parent, [System.StringComparison]::OrdinalIgnoreCase) -or
        $candidate.StartsWith($parent + '\', [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-PHMPathDriveLetter {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $root = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($Path))
    if (-not $root) { throw "无法确定路径所在卷：$Path" }
    if ($root -match '^[A-Za-z]:\\') { return $root.Substring(0, 2).ToUpperInvariant() }
    return $root.TrimEnd('\', '/').ToUpperInvariant()
}

function Test-PHMPathOnValidatedDrive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$DriveInfo
    )

    $pathDrive = Get-PHMPathDriveLetter -Path $Path
    $validatedDrive = ([string](Get-PHMObjectProperty -InputObject $DriveInfo -Name 'DriveLetter' -DefaultValue '')).TrimEnd('\', '/').ToUpperInvariant()
    return ($validatedDrive -and $pathDrive.Equals($validatedDrive, [System.StringComparison]::OrdinalIgnoreCase))
}

function Test-PHMPathChainSafe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [scriptblock]$PathSafetyProvider
    )

    if ($PathSafetyProvider) { return [bool](& $PathSafetyProvider $Path) }
    $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    $root = [System.IO.Path]::GetPathRoot($fullPath).TrimEnd('\')
    $current = $root
    $relative = $fullPath.Substring($root.Length).TrimStart('\')
    foreach ($segment in @($relative -split '\\' | Where-Object { $_ })) {
        $current = Join-Path $current $segment
        if (-not (Test-Path -LiteralPath $current)) { continue }
        try { $attributes = (Get-Item -LiteralPath $current -Force -ErrorAction Stop).Attributes }
        catch { return $false }
        if ([bool]($attributes -band [System.IO.FileAttributes]::ReparsePoint)) { return $false }
    }
    return $true
}

function New-PHMCheckoutPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PortableProjectPath,
        [Parameter(Mandatory)][string]$PortableRepositoryRoot,
        [Parameter(Mandatory)][string]$LocalCurrentRoot,
        [Parameter(Mandatory)][string]$LocalReceivingRoot,
        [Parameter(Mandatory)]$DriveInfo,
        [Nullable[long]]$LocalFreeBytes,
        [scriptblock]$LocalFreeSpaceProvider,
        [scriptblock]$PathSafetyProvider,
        [switch]$AllowSensitiveFiles,
        [string]$ExpectedDriveLetter = 'T:',
        [string]$ExpectedVolumeLabel = 'T9',
        [string]$ExpectedFileSystem = 'NTFS',
        [string]$ExpectedFriendlyName = 'Samsung PSSD T9',
        [string]$ExpectedVolumeSerial,
        [string]$ExpectedDeviceId
    )

    if (-not (Test-Path -LiteralPath $PortableProjectPath -PathType Container)) {
        throw "T9 项目文件夹不存在：$PortableProjectPath"
    }

    $sourcePath = (Get-Item -LiteralPath $PortableProjectPath).FullName
    $repositoryRoot = [System.IO.Path]::GetFullPath($PortableRepositoryRoot).TrimEnd('\')
    $pausedRoot = [System.IO.Path]::GetFullPath((Join-Path $repositoryRoot '暂停项目')).TrimEnd('\')
    $projectName = Split-Path $sourcePath -Leaf
    $identitySummary = Get-PHMIdentitySummary -ProjectPath $sourcePath
    $needsAdoption = (-not $identitySummary.Managed -and -not $identitySummary.Error)
    $projectId = if ($identitySummary.ProjectId) { $identitySummary.ProjectId } else { New-PHMDeterministicProjectId -ProjectPath $sourcePath }
    $inventory = Get-PHMProjectInventory -ProjectPath $sourcePath
    $requiredBytes = [long]($inventory.TotalBytes + [math]::Max(100MB, [math]::Ceiling($inventory.TotalBytes * 0.1)))
    $driveValidation = Test-PHMPortableDrive -Actual $DriveInfo -ExpectedDriveLetter $ExpectedDriveLetter -ExpectedVolumeLabel $ExpectedVolumeLabel -ExpectedFileSystem $ExpectedFileSystem -ExpectedFriendlyName $ExpectedFriendlyName -ExpectedVolumeSerial $ExpectedVolumeSerial -ExpectedDeviceId $ExpectedDeviceId
    $currentRoot = [System.IO.Path]::GetFullPath($LocalCurrentRoot)
    $receivingRoot = [System.IO.Path]::GetFullPath($LocalReceivingRoot)
    $receivingPath = Join-Path $receivingRoot "$projectId\$projectName"
    $officialPath = Join-Path $currentRoot $projectName
    $blockers = @($driveValidation.Blockers)
    if (-not (Test-PHMPathOnValidatedDrive -Path $sourcePath -DriveInfo $DriveInfo) -or
        -not (Test-PHMPathOnValidatedDrive -Path $repositoryRoot -DriveInfo $DriveInfo)) {
        $blockers += 'T9 来源或项目仓库不在已验证 DriveInfo.DriveLetter 所指向的卷上。'
    }
    foreach ($protectedPath in @($repositoryRoot, $pausedRoot, $sourcePath)) {
        if (-not (Test-PHMPathChainSafe -Path $protectedPath -PathSafetyProvider $PathSafetyProvider)) {
            $blockers += "T9 路径链包含重解析点或无法验证：$protectedPath"
        }
    }
    $sourceParent = [System.IO.Path]::GetFullPath((Split-Path $sourcePath -Parent)).TrimEnd('\')
    if (-not $sourceParent.Equals($pausedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        $blockers += 'T9 来源必须是配置的 PortableRepositoryRoot\暂停项目 下的直接项目子目录。'
    }
    if (-not $ExpectedVolumeSerial -or -not $ExpectedDeviceId) {
        $blockers += '缺少本机信任记录中的卷序列或设备标识；不能确认是已登记的 T9。'
    }

    if ($identitySummary.Error) { $blockers += "$($identitySummary.Error)；不能将损坏的身份文件当作旧项目自动纳管。" }
    if ([bool]((Get-Item -LiteralPath $sourcePath).Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { $blockers += 'T9 项目根目录是重解析点；借出已阻断。' }
    if ($inventory.ReparsePoints.Count -gt 0) { $blockers += "发现 $($inventory.ReparsePoints.Count) 个重解析点；为防止复制项目外内容，借出已阻断。" }
    if ($inventory.Unreadable.Count -gt 0) { $blockers += "发现 $($inventory.Unreadable.Count) 个无法读取的文件或目录。" }
    if (Test-Path -LiteralPath $officialPath) { $blockers += "本机正式目录已存在：$officialPath。禁止自动覆盖。" }
    if (Test-Path -LiteralPath $receivingPath) { $blockers += "本机暂存目录已存在：$receivingPath。请先修复未完成借出。" }
    if ((Test-PHMPathWithin -Path $officialPath -ParentPath $sourcePath) -or (Test-PHMPathWithin -Path $receivingPath -ParentPath $sourcePath)) {
        $blockers += '本机目标或暂存目录不能位于 T9 来源项目内部。'
    }
    $resolvedLocalFreeBytes = $null
    $localFreeSpaceEvidence = $null
    if ($PSBoundParameters.ContainsKey('LocalFreeBytes')) {
        $resolvedLocalFreeBytes = [long]$LocalFreeBytes
        $localFreeSpaceEvidence = '由调用方显式提供。'
    }
    else {
        if (-not $LocalFreeSpaceProvider) {
            $LocalFreeSpaceProvider = {
                param($path)
                $probe = [System.IO.Path]::GetFullPath($path)
                while (-not (Test-Path -LiteralPath $probe) -and (Split-Path $probe -Parent) -and (Split-Path $probe -Parent) -ne $probe) {
                    $probe = Split-Path $probe -Parent
                }
                $root = [System.IO.Path]::GetPathRoot($probe)
                if (-not $root) { throw "无法确定目标路径所在卷：$path" }
                ([System.IO.DriveInfo]::new($root)).AvailableFreeSpace
            }
        }
        try {
            $resolvedLocalFreeBytes = [long](& $LocalFreeSpaceProvider $currentRoot)
            $localFreeSpaceEvidence = "已自动查询本机目标卷可用空间：$resolvedLocalFreeBytes 字节。"
        }
        catch {
            $localFreeSpaceEvidence = "自动查询失败：$($_.Exception.Message)"
            $blockers += "无法查询本机可用空间：$($_.Exception.Message)"
        }
    }
    if ($null -ne $resolvedLocalFreeBytes -and $resolvedLocalFreeBytes -lt $requiredBytes) {
        $blockers += "本机空间不足：需要 $requiredBytes 字节，可用 $resolvedLocalFreeBytes 字节。"
    }

    $sensitiveFiles = @(Get-PHMSensitiveFiles -Inventory $inventory)
    $requiresSensitiveConfirmation = ($sensitiveFiles.Count -gt 0 -and -not $AllowSensitiveFiles)
    if ($requiresSensitiveConfirmation) { $blockers += "发现 $($sensitiveFiles.Count) 个可能包含凭据的敏感文件；需要明确确认随完整项目借出。" }

    $expectedActions = @('复制前复核 T9 来源清单', '完整复制到本机空暂存目录', '复核来源并校验目标哈希', '原子提升到本机正式目录', '生成环境检查结果和继续项目提示词', '保留 T9 来源并等待独立清理确认')
    if ($needsAdoption) { $expectedActions = @('借出前自动纳管旧项目') + $expectedActions }

    [pscustomobject]@{
        CanExecute          = ($blockers.Count -eq 0)
        SourcePath          = $sourcePath
        ProjectName         = $projectName
        ProjectId           = $projectId
        PortableRepositoryRoot = $repositoryRoot
        NeedsAdoption       = $needsAdoption
        ReceivingPath       = $receivingPath
        OfficialPath        = $officialPath
        Inventory           = $inventory
        RequiredBytes       = $requiredBytes
        LocalFreeBytes      = $resolvedLocalFreeBytes
        LocalFreeSpaceEvidence = $localFreeSpaceEvidence
        DriveValidation     = $driveValidation
        SensitiveFiles      = @($sensitiveFiles)
        RequiresSensitiveConfirmation = $requiresSensitiveConfirmation
        ReparsePoints       = @($inventory.ReparsePoints)
        Unreadable          = @($inventory.Unreadable)
        Blockers            = @($blockers)
        ExpectedActions     = @($expectedActions)
        ExpectedResult      = '确认后复制到本机、校验并提交为正式目录；T9 来源保留，需第二次确认后才清理。'
    }
}

function Test-PHMProjectEnvironment {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectPath)

    if (-not (Test-Path -LiteralPath $ProjectPath -PathType Container)) {
        throw "项目文件夹不存在：$ProjectPath"
    }
    $root = (Get-Item -LiteralPath $ProjectPath).FullName

    $nodeLockFile = $null
    $nodeRecoveryCommand = $null
    foreach ($candidate in @('package-lock.json', 'pnpm-lock.yaml', 'yarn.lock')) {
        if (Test-Path -LiteralPath (Join-Path $root $candidate) -PathType Leaf) {
            $nodeLockFile = $candidate
            $nodeRecoveryCommand = switch ($candidate) {
                'package-lock.json' { 'npm ci' }
                'pnpm-lock.yaml' { 'pnpm install --frozen-lockfile' }
                'yarn.lock' { 'yarn install --frozen-lockfile' }
            }
            break
        }
    }
    $nodeModulesPresent = Test-Path -LiteralPath (Join-Path $root 'node_modules') -PathType Container
    $nodeStatus = if ($nodeModulesPresent) { 'present_needs_validation' } elseif ($nodeLockFile) { 'needs_restore' } else { 'not_detected' }

    $pythonRecoverySource = $null
    $pythonRecoveryCommand = $null
    foreach ($candidate in @('uv.lock', 'requirements.lock', 'requirements.txt', 'pyproject.toml')) {
        if (-not (Test-Path -LiteralPath (Join-Path $root $candidate) -PathType Leaf)) { continue }
        $pythonRecoverySource = $candidate
        $pythonRecoveryCommand = switch ($candidate) {
            'uv.lock' { 'uv sync' }
            'requirements.lock' { 'python -m venv .venv; .\.venv\Scripts\python -m pip install -r requirements.lock' }
            'requirements.txt' { 'python -m venv .venv; .\.venv\Scripts\python -m pip install -r requirements.txt' }
            'pyproject.toml' { 'python -m venv .venv; .\.venv\Scripts\python -m pip install .' }
        }
        break
    }

    $venvPath = Join-Path $root '.venv'
    $venvPresent = Test-Path -LiteralPath $venvPath -PathType Container
    $venvConfigPath = Join-Path $venvPath 'pyvenv.cfg'
    $venvConfigPresent = Test-Path -LiteralPath $venvConfigPath -PathType Leaf
    $originalPythonHome = $null
    if ($venvConfigPresent) {
        $configText = Get-Content -LiteralPath $venvConfigPath -Raw -ErrorAction SilentlyContinue
        $homeMatch = [regex]::Match([string]$configText, '(?im)^\s*home\s*=\s*(?<home>.+?)\s*$')
        if ($homeMatch.Success) { $originalPythonHome = $homeMatch.Groups['home'].Value.Trim() }
    }
    $pythonStatus = 'not_detected'
    if ($venvPresent) {
        if (-not $venvConfigPresent -or -not $originalPythonHome -or -not (Test-Path -LiteralPath $originalPythonHome)) {
            $pythonStatus = 'needs_rebuild'
        }
        else { $pythonStatus = 'present_needs_validation' }
    }
    elseif ($pythonRecoverySource) { $pythonStatus = 'needs_restore' }

    [pscustomobject]@{
        ProjectPath = $root
        NodeEnvironment = [pscustomobject]@{
            Status              = $nodeStatus
            DependenciesPresent = $nodeModulesPresent
            LockFile            = $nodeLockFile
            RecoveryCommand     = $nodeRecoveryCommand
            Note                = '随项目存在的 node_modules 仅作为现状记录；仍需在本机验证，不能保证可直接运行。'
        }
        PythonEnvironment = [pscustomobject]@{
            Status                    = $pythonStatus
            VirtualEnvironmentPresent = $venvPresent
            ConfigurationFile         = if ($venvConfigPresent) { '.venv\pyvenv.cfg' } else { $null }
            OriginalPythonHome        = $originalPythonHome
            RecoverySource            = $pythonRecoverySource
            RecoveryCommand           = $pythonRecoveryCommand
            Note                      = '复制来的虚拟环境必须检查原 Python 路径；即使路径存在，也不能保证可直接运行。'
        }
        ProjectCache        = Get-PHMDirectoryInventory -Path (Join-Path $root '项目缓存')
        OfflineDependencies = Get-PHMDirectoryInventory -Path (Join-Path $root '离线依赖')
    }
}

function Write-PHMContinuePrompt {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectPath)

    if (-not (Test-Path -LiteralPath $ProjectPath -PathType Container)) {
        throw "项目文件夹不存在：$ProjectPath"
    }
    $handoffRoot = Join-Path (Get-Item -LiteralPath $ProjectPath).FullName '项目交接'
    New-Item -ItemType Directory -Path $handoffRoot -Force | Out-Null
    $path = Join-Path $handoffRoot '继续项目提示词.md'
    $content = @'
# 在新 Codex 任务中继续此项目

请把当前项目文件夹作为工作区，并按以下顺序继续：

1. 先完整阅读 `项目交接/项目交接报告.md`，确认项目目标、不能改变的约束、当前任务、未完成事项、下一步和最后验证结果。
2. 再读取 `项目交接/环境清单.json`，检查 Node、Python、项目缓存和离线依赖的现状。
3. 不要假定复制来的 `node_modules`、`.venv`、缓存或离线依赖必然可直接运行；先执行环境检查，并按锁文件给出的恢复命令重建或验证环境。
4. 检查工作区和交接记录是否一致，然后继续上次未完成工作。
5. 完成新的阶段后，更新项目交接报告、环境清单和验证结果。
'@
    Write-PHMUtf8File -Path $path -Content $content
    return $path
}

function Copy-PHMCheckoutHandoffFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LocalProjectPath,
        [Parameter(Mandatory)][string]$PortableProjectPath
    )

    $portableHandoff = Join-Path $PortableProjectPath '项目交接'
    New-Item -ItemType Directory -Path $portableHandoff -Force | Out-Null
    foreach ($name in @('项目身份.json', '项目交接报告.md', '环境清单.json', '继续项目提示词.md')) {
        $source = Join-Path $LocalProjectPath "项目交接\$name"
        if (Test-Path -LiteralPath $source -PathType Leaf) {
            [System.IO.File]::Copy($source, (Join-Path $portableHandoff $name), $true)
        }
    }
}

function Complete-PHMCheckoutFinalization {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PortableSourcePath,
        [Parameter(Mandatory)][string]$LocalTargetPath,
        [Parameter(Mandatory)][string]$PortableRepositoryRoot,
        [Parameter(Mandatory)][string]$ProjectId,
        [switch]$NeedsAdoption,
        [scriptblock]$RegistryWriter,
        [string]$ComputerName = $env:COMPUTERNAME
    )

    $sourcePath = (Get-Item -LiteralPath $PortableSourcePath -ErrorAction Stop).FullName
    $targetPath = (Get-Item -LiteralPath $LocalTargetPath -ErrorAction Stop).FullName
    $repositoryRoot = [System.IO.Path]::GetFullPath($PortableRepositoryRoot).TrimEnd('\')
    $markerPath = Join-Path $targetPath '项目交接\借出最终化恢复.json'
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) { throw '缺少借出最终化恢复记录。' }
    $marker = Get-Content -LiteralPath $markerPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ([string]$marker.project_id -ne $ProjectId -or
        -not $sourcePath.Equals([System.IO.Path]::GetFullPath([string]$marker.source_path), [System.StringComparison]::OrdinalIgnoreCase) -or
        -not $targetPath.Equals([System.IO.Path]::GetFullPath([string]$marker.target_path), [System.StringComparison]::OrdinalIgnoreCase) -or
        -not $repositoryRoot.Equals([System.IO.Path]::GetFullPath([string]$marker.repository_root).TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)) {
        throw '借出最终化恢复记录与当前项目不一致。'
    }

    if ($NeedsAdoption -or -not (Test-Path -LiteralPath (Join-Path $targetPath '项目交接\项目身份.json') -PathType Leaf)) {
        Initialize-PHMProject -ProjectPath $targetPath -ComputerName $ComputerName -ProjectId $ProjectId -InitialState 'local_active' | Out-Null
    }
    $environmentPath = Update-PHMEnvironmentManifest -ProjectPath $targetPath -ComputerName $ComputerName
    $environment = Test-PHMProjectEnvironment -ProjectPath $targetPath
    $continuePromptPath = Write-PHMContinuePrompt -ProjectPath $targetPath
    Update-PHMIdentity -ProjectPath $targetPath -ComputerName $ComputerName -Operation 'checkout' -State 'cleanup_pending' -OfficialLocation $targetPath | Out-Null
    Add-PHMHandoffRecord -ProjectPath $targetPath -ComputerName $ComputerName -ActionLabel '从 T9 借出（等待清理 T9 来源）' -Changes (New-PHMEmptyChanges) -ValidationResult '本机目标已完成完整性校验；T9 来源仍保留。' | Out-Null
    Copy-PHMCheckoutHandoffFiles -LocalProjectPath $targetPath -PortableProjectPath $sourcePath

    $cleanupDigest = Get-PHMCleanupDigest -ProjectPath $targetPath
    if ((Get-PHMCleanupDigest -ProjectPath $sourcePath) -ne $cleanupDigest) { throw '两端最终化摘要不一致。' }
    $receipt = [ordered]@{
        schema_version=1; operation='checkout'; project_id=$ProjectId
        repository_root=$repositoryRoot; source_path=$sourcePath; target_path=$targetPath
        transferred_at=(Get-Date).ToUniversalTime().ToString('o'); source_manifest_digest=$cleanupDigest
    }
    $receiptJson = $receipt | ConvertTo-Json -Depth 5
    foreach ($projectPath in @($sourcePath, $targetPath)) {
        Write-PHMUtf8File -Path (Join-Path $projectPath '项目交接\转移凭证.json') -Content $receiptJson
    }

    $registryPath = Get-PHMRegistryPathFromRepository -PortableRepositoryRoot $repositoryRoot
    $targetIdentity = Get-Content -LiteralPath (Join-Path $targetPath '项目交接\项目身份.json') -Raw | ConvertFrom-Json
    $record = [pscustomobject]@{ projectId=$ProjectId; projectName=[string]$targetIdentity.project_name; state='cleanup_pending'; location=$targetPath; updatedAt=(Get-Date).ToUniversalTime().ToString('o') }
    if (-not $RegistryWriter) { $RegistryWriter = { param($path,$item) Write-PHMRegistry -RegistryPath $path -Record $item } }
    & $RegistryWriter $registryPath $record | Out-Null
    Remove-Item -LiteralPath $markerPath -Force -ErrorAction Stop

    [pscustomobject]@{
        Executed=$true; Verified=$true; ProjectId=$ProjectId; SourcePath=$sourcePath; OfficialPath=$targetPath
        RegistryPath=$registryPath; Environment=$environment; EnvironmentPath=$environmentPath
        ContinuePromptPath=$continuePromptPath; CleanupRequired=$true; SourceStillExists=$true; DeletedFiles=0
    }
}

function Repair-PHMCheckoutFinalization {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LocalTargetPath,
        [Parameter(Mandatory)][string]$PortableRepositoryRoot,
        [Parameter(Mandatory)]$DriveInfo,
        [scriptblock]$PathSafetyProvider,
        [scriptblock]$RegistryWriter,
        [string]$ComputerName = $env:COMPUTERNAME,
        [string]$ExpectedDriveLetter = 'T:',
        [string]$ExpectedVolumeLabel = 'T9',
        [string]$ExpectedFileSystem = 'NTFS',
        [string]$ExpectedFriendlyName = 'Samsung PSSD T9',
        [Parameter(Mandatory)][string]$ExpectedVolumeSerial,
        [Parameter(Mandatory)][string]$ExpectedDeviceId
    )
    $targetPath = (Get-Item -LiteralPath $LocalTargetPath -ErrorAction Stop).FullName
    $markerPath = Join-Path $targetPath '项目交接\借出最终化恢复.json'
    $marker = Get-Content -LiteralPath $markerPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $repositoryRoot = [System.IO.Path]::GetFullPath($PortableRepositoryRoot).TrimEnd('\')
    if (-not $repositoryRoot.Equals([System.IO.Path]::GetFullPath([string]$marker.repository_root).TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)) { throw '恢复记录不属于指定的 T9 项目仓库。' }
    $driveValidation = Test-PHMPortableDrive -Actual $DriveInfo -ExpectedDriveLetter $ExpectedDriveLetter -ExpectedVolumeLabel $ExpectedVolumeLabel -ExpectedFileSystem $ExpectedFileSystem -ExpectedFriendlyName $ExpectedFriendlyName -ExpectedVolumeSerial $ExpectedVolumeSerial -ExpectedDeviceId $ExpectedDeviceId
    if (-not $driveValidation.IsValid) { throw "设备或磁盘校验失败：$($driveValidation.Blockers -join '；')" }
    $sourcePath = [System.IO.Path]::GetFullPath([string]$marker.source_path)
    if (-not (Test-PHMPathOnValidatedDrive -Path $sourcePath -DriveInfo $DriveInfo) -or
        -not (Test-PHMPathOnValidatedDrive -Path $repositoryRoot -DriveInfo $DriveInfo)) {
        throw '恢复来源或项目仓库不在已验证 DriveInfo.DriveLetter 所指向的卷上。'
    }
    $pausedRoot = [System.IO.Path]::GetFullPath((Join-Path $repositoryRoot '暂停项目')).TrimEnd('\')
    foreach ($protectedPath in @($repositoryRoot, $pausedRoot, $sourcePath)) {
        if (-not (Test-PHMPathChainSafe -Path $protectedPath -PathSafetyProvider $PathSafetyProvider)) { throw "恢复路径链包含重解析点或无法验证：$protectedPath" }
    }
    if (-not ([System.IO.Path]::GetFullPath((Split-Path $sourcePath -Parent)).TrimEnd('\')).Equals($pausedRoot, [System.StringComparison]::OrdinalIgnoreCase)) { throw '恢复来源不是指定 T9 仓库暂停项目下的直接子目录。' }
    Complete-PHMCheckoutFinalization -PortableSourcePath $sourcePath -LocalTargetPath $targetPath -PortableRepositoryRoot $repositoryRoot -ProjectId ([string]$marker.project_id) -NeedsAdoption:([bool]$marker.needs_adoption) -RegistryWriter $RegistryWriter -ComputerName $ComputerName
}

function Invoke-PHMCheckout {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PortableProjectPath,
        [Parameter(Mandatory)][string]$PortableRepositoryRoot,
        [Parameter(Mandatory)][string]$LocalCurrentRoot,
        [Parameter(Mandatory)][string]$LocalReceivingRoot,
        [Parameter(Mandatory)]$DriveInfo,
        [Nullable[long]]$LocalFreeBytes,
        [scriptblock]$LocalFreeSpaceProvider,
        [scriptblock]$PathSafetyProvider,
        [switch]$ConfirmTransfer,
        [switch]$AllowSensitiveFiles,
        [scriptblock]$CopyAction,
        [scriptblock]$RegistryWriter,
        [scriptblock]$FinalizationAction,
        [string]$ComputerName = $env:COMPUTERNAME,
        [string]$ExpectedDriveLetter = 'T:',
        [string]$ExpectedVolumeLabel = 'T9',
        [string]$ExpectedFileSystem = 'NTFS',
        [string]$ExpectedFriendlyName = 'Samsung PSSD T9',
        [string]$ExpectedVolumeSerial,
        [string]$ExpectedDeviceId
    )

    $planParameters = @{
        PortableProjectPath=$PortableProjectPath; PortableRepositoryRoot=$PortableRepositoryRoot; LocalCurrentRoot=$LocalCurrentRoot; LocalReceivingRoot=$LocalReceivingRoot
        DriveInfo=$DriveInfo; ExpectedDriveLetter=$ExpectedDriveLetter; ExpectedVolumeLabel=$ExpectedVolumeLabel
        ExpectedFileSystem=$ExpectedFileSystem; ExpectedFriendlyName=$ExpectedFriendlyName
        ExpectedVolumeSerial=$ExpectedVolumeSerial; ExpectedDeviceId=$ExpectedDeviceId
        AllowSensitiveFiles=$AllowSensitiveFiles
    }
    if ($PSBoundParameters.ContainsKey('LocalFreeBytes')) { $planParameters.LocalFreeBytes = $LocalFreeBytes }
    if ($LocalFreeSpaceProvider) { $planParameters.LocalFreeSpaceProvider = $LocalFreeSpaceProvider }
    if ($PathSafetyProvider) { $planParameters.PathSafetyProvider = $PathSafetyProvider }
    $plan = New-PHMCheckoutPlan @planParameters
    if (-not $ConfirmTransfer) {
        return [pscustomobject]@{ Executed=$false; Verified=$false; RequiresConfirmation=$true; Plan=$plan; OfficialPath=$plan.OfficialPath; ReceivingPath=$plan.ReceivingPath; CleanupRequired=$false; DeletedFiles=0 }
    }
    if (-not $plan.CanExecute) {
        return [pscustomobject]@{ Executed=$false; Verified=$false; FailureStage='preflight'; Plan=$plan; OfficialPath=$plan.OfficialPath; ReceivingPath=$plan.ReceivingPath; CleanupRequired=$false; DeletedFiles=0 }
    }

    $sourceBefore = Get-PHMProjectInventory -ProjectPath $plan.SourcePath
    if (-not $CopyAction) { $CopyAction = { param($source,$destination) Copy-PHMProjectDirectory -Source $source -Destination $destination } }
    try { $copyResult = & $CopyAction $plan.SourcePath $plan.ReceivingPath }
    catch { $copyResult = [pscustomobject]@{ Success=$false; ExitCode=-1; Message=$_.Exception.Message } }
    if (-not $copyResult -or -not [bool]$copyResult.Success) {
        return [pscustomobject]@{ Executed=$false; Verified=$false; FailureStage='copy'; CopyResult=$copyResult; OfficialPath=$plan.OfficialPath; ReceivingPath=$plan.ReceivingPath; CleanupRequired=$false; DeletedFiles=0 }
    }

    $sourceAfter = Get-PHMProjectInventory -ProjectPath $plan.SourcePath
    if ($sourceBefore.ManifestDigest -ne $sourceAfter.ManifestDigest) {
        return [pscustomobject]@{ Executed=$false; Verified=$false; FailureStage='source-changed'; OfficialPath=$plan.OfficialPath; ReceivingPath=$plan.ReceivingPath; CleanupRequired=$false; DeletedFiles=0 }
    }
    $targetInventory = Get-PHMProjectInventory -ProjectPath $plan.ReceivingPath
    $verification = Compare-PHMProjectInventories -SourceInventory $sourceAfter -DestinationInventory $targetInventory -RequireManagementFiles:(-not $plan.NeedsAdoption)
    if (-not $verification.IsMatch) {
        return [pscustomobject]@{ Executed=$false; Verified=$false; FailureStage='verification'; Verification=$verification; OfficialPath=$plan.OfficialPath; ReceivingPath=$plan.ReceivingPath; CleanupRequired=$false; DeletedFiles=0 }
    }

    try {
        New-Item -ItemType Directory -Path (Split-Path $plan.OfficialPath -Parent) -Force | Out-Null
        Move-Item -LiteralPath $plan.ReceivingPath -Destination $plan.OfficialPath -ErrorAction Stop
    }
    catch {
        return [pscustomobject]@{ Executed=$false; Verified=$true; FailureStage='promotion'; Error=$_.Exception.Message; OfficialPath=$plan.OfficialPath; ReceivingPath=$plan.ReceivingPath; CleanupRequired=$false; DeletedFiles=0 }
    }

    $repositoryRoot = $plan.PortableRepositoryRoot
    $recoveryMarker = [ordered]@{
        schema_version=1; operation='checkout-finalization'; project_id=$plan.ProjectId
        repository_root=$repositoryRoot; source_path=$plan.SourcePath; target_path=$plan.OfficialPath
        needs_adoption=[bool]$plan.NeedsAdoption; created_at=(Get-Date).ToUniversalTime().ToString('o')
    }
    $recoveryMarkerPath = Join-Path $plan.OfficialPath '项目交接\借出最终化恢复.json'
    New-Item -ItemType Directory -Path (Split-Path $recoveryMarkerPath -Parent) -Force | Out-Null
    Write-PHMUtf8File -Path $recoveryMarkerPath -Content ($recoveryMarker | ConvertTo-Json -Depth 5)
    try {
        if ($FinalizationAction) { & $FinalizationAction $plan.OfficialPath $plan.SourcePath | Out-Null }
        $finalized = Complete-PHMCheckoutFinalization -PortableSourcePath $plan.SourcePath -LocalTargetPath $plan.OfficialPath -PortableRepositoryRoot $repositoryRoot -ProjectId $plan.ProjectId -NeedsAdoption:$plan.NeedsAdoption -RegistryWriter $RegistryWriter -ComputerName $ComputerName
    }
    catch {
        return [pscustomobject]@{
            Executed=$false; Verified=$true; FailureStage='finalization'; Error=$_.Exception.Message
            Recoverable=$true; RecoveryState='both_copies_preserved'; SourcePath=$plan.SourcePath
            OfficialPath=$plan.OfficialPath; ReceivingPath=$plan.ReceivingPath; CleanupRequired=$true; DeletedFiles=0
        }
    }

    [pscustomobject]@{
        Executed=$true; Verified=$true; FailureStage=$null; ProjectId=$plan.ProjectId
        SourcePath=$plan.SourcePath; OfficialPath=$plan.OfficialPath; ReceivingPath=$plan.ReceivingPath
        Verification=$verification; CopyResult=$copyResult; RegistryPath=$finalized.RegistryPath
        Environment=$finalized.Environment; EnvironmentPath=$finalized.EnvironmentPath; ContinuePromptPath=$finalized.ContinuePromptPath
        CleanupRequired=$true; SourceStillExists=$true; DeletedFiles=0
        CleanupPrompt="本机项目已经完整校验。确认两份均未变化后，可清理 T9 来源：$($plan.SourcePath)"
    }
}

function Get-PHMCheckoutCleanupSummary {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectPath)

    if (-not (Test-Path -LiteralPath $ProjectPath -PathType Container)) { return $null }
    $inventory = Get-PHMProjectInventory -ProjectPath $ProjectPath
    [pscustomobject]@{
        Path           = (Get-Item -LiteralPath $ProjectPath).FullName
        FileCount      = $inventory.FileCount
        TotalBytes     = $inventory.TotalBytes
        ManifestDigest = Get-PHMCleanupDigest -ProjectPath $ProjectPath
    }
}

function Complete-PHMCheckoutCleanup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PortableSourcePath,
        [Parameter(Mandatory)][string]$LocalTargetPath,
        [Parameter(Mandatory)][string]$PortableRepositoryRoot,
        [Parameter(Mandatory)]$DriveInfo,
        [switch]$ConfirmCleanup,
        [scriptblock]$DeleteAction,
        [scriptblock]$PathSafetyProvider,
        [scriptblock]$RegistryWriter,
        [string]$ComputerName = $env:COMPUTERNAME,
        [string]$ExpectedDriveLetter = 'T:',
        [string]$ExpectedVolumeLabel = 'T9',
        [string]$ExpectedFileSystem = 'NTFS',
        [string]$ExpectedFriendlyName = 'Samsung PSSD T9',
        [string]$ExpectedVolumeSerial,
        [string]$ExpectedDeviceId
    )

    $sourceFull = if (Test-Path -LiteralPath $PortableSourcePath) { (Get-Item -LiteralPath $PortableSourcePath).FullName } else { [System.IO.Path]::GetFullPath($PortableSourcePath) }
    $targetFull = if (Test-Path -LiteralPath $LocalTargetPath) { (Get-Item -LiteralPath $LocalTargetPath).FullName } else { [System.IO.Path]::GetFullPath($LocalTargetPath) }
    $repositoryRoot = [System.IO.Path]::GetFullPath($PortableRepositoryRoot).TrimEnd('\')
    $pausedRoot = [System.IO.Path]::GetFullPath((Join-Path $repositoryRoot '暂停项目')).TrimEnd('\')
    $sourceParent = [System.IO.Path]::GetFullPath((Split-Path $sourceFull -Parent)).TrimEnd('\')
    $pathIsDirectProject = $sourceParent.Equals($pausedRoot, [System.StringComparison]::OrdinalIgnoreCase) -and
        -not $sourceFull.Equals($pausedRoot, [System.StringComparison]::OrdinalIgnoreCase)
    $driveValidation = Test-PHMPortableDrive -Actual $DriveInfo -ExpectedDriveLetter $ExpectedDriveLetter -ExpectedVolumeLabel $ExpectedVolumeLabel -ExpectedFileSystem $ExpectedFileSystem -ExpectedFriendlyName $ExpectedFriendlyName -ExpectedVolumeSerial $ExpectedVolumeSerial -ExpectedDeviceId $ExpectedDeviceId
    $pathDriveMatches = (Test-PHMPathOnValidatedDrive -Path $sourceFull -DriveInfo $DriveInfo) -and
        (Test-PHMPathOnValidatedDrive -Path $repositoryRoot -DriveInfo $DriveInfo)
    $sourceSummary = Get-PHMCheckoutCleanupSummary -ProjectPath $sourceFull
    $targetSummary = Get-PHMCheckoutCleanupSummary -ProjectPath $targetFull
    if (-not $ConfirmCleanup) {
        return [pscustomobject]@{
            Executed=$false; RequiresConfirmation=$true; PortableSourcePath=$sourceFull; LocalTargetPath=$targetFull
            ReceiptPath=(Join-Path $targetFull '项目交接\转移凭证.json'); SourceSummary=$sourceSummary; TargetSummary=$targetSummary
            PortableRepositoryRoot=$repositoryRoot; DriveValidation=$driveValidation
            ExpectedResult='复核磁盘身份、仓库边界、借出回执、项目编号和两端摘要后，只删除 T9 来源；本机项目转为 local_active。'
        }
    }
    if ($sourceFull.Equals($targetFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{ Executed=$false; BlockedReason='T9 来源与本机目标不能是同一路径。'; PortableSourcePath=$sourceFull; LocalTargetPath=$targetFull; DeletedFiles=0 }
    }
    if (-not $ExpectedVolumeSerial -or -not $ExpectedDeviceId) {
        return [pscustomobject]@{ Executed=$false; BlockedReason='缺少本机信任记录中的卷序列或设备标识；禁止清理。'; PortableSourcePath=$sourceFull; LocalTargetPath=$targetFull; DeletedFiles=0 }
    }
    if (-not $driveValidation.IsValid) {
        return [pscustomobject]@{ Executed=$false; BlockedReason="设备或磁盘校验失败：$($driveValidation.Blockers -join '；')"; PortableSourcePath=$sourceFull; LocalTargetPath=$targetFull; DeletedFiles=0 }
    }
    if (-not $pathDriveMatches) {
        return [pscustomobject]@{ Executed=$false; BlockedReason='T9 来源或项目仓库不在已验证 DriveInfo.DriveLetter 所指向的卷上。'; PortableSourcePath=$sourceFull; LocalTargetPath=$targetFull; DeletedFiles=0 }
    }
    foreach ($protectedPath in @($repositoryRoot, $pausedRoot, $sourceFull)) {
        if (-not (Test-PHMPathChainSafe -Path $protectedPath -PathSafetyProvider $PathSafetyProvider)) {
            return [pscustomobject]@{ Executed=$false; BlockedReason="T9 路径链包含重解析点或无法验证：$protectedPath"; PortableSourcePath=$sourceFull; LocalTargetPath=$targetFull; DeletedFiles=0 }
        }
    }
    if (-not $pathIsDirectProject -or -not (Test-PHMDeletionPath -Path $sourceFull -ProtectedRoots @($pausedRoot))) {
        return [pscustomobject]@{ Executed=$false; BlockedReason='只允许删除 PortableRepositoryRoot\暂停项目 下的直接子目录（单个项目）。'; PortableSourcePath=$sourceFull; LocalTargetPath=$targetFull; DeletedFiles=0 }
    }
    if (-not $sourceSummary -or -not $targetSummary) {
        return [pscustomobject]@{ Executed=$false; BlockedReason='T9 来源或本机目标项目不存在。'; PortableSourcePath=$sourceFull; LocalTargetPath=$targetFull; DeletedFiles=0 }
    }

    $sourceReceiptPath = Join-Path $sourceFull '项目交接\转移凭证.json'
    $targetReceiptPath = Join-Path $targetFull '项目交接\转移凭证.json'
    if (-not (Test-Path -LiteralPath $sourceReceiptPath -PathType Leaf) -or -not (Test-Path -LiteralPath $targetReceiptPath -PathType Leaf)) {
        return [pscustomobject]@{ Executed=$false; BlockedReason='任一端缺少借出回执。'; PortableSourcePath=$sourceFull; LocalTargetPath=$targetFull; DeletedFiles=0 }
    }
    try {
        $sourceReceipt = Get-Content -LiteralPath $sourceReceiptPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $targetReceipt = Get-Content -LiteralPath $targetReceiptPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        return [pscustomobject]@{ Executed=$false; BlockedReason='借出回执无法解析。'; PortableSourcePath=$sourceFull; LocalTargetPath=$targetFull; DeletedFiles=0 }
    }
    $receiptFields = @('schema_version','operation','project_id','repository_root','source_path','target_path','transferred_at','source_manifest_digest')
    $receiptMismatch = $false
    foreach ($field in $receiptFields) {
        if ([string]$sourceReceipt.$field -cne [string]$targetReceipt.$field) { $receiptMismatch = $true; break }
    }
    if ($receiptMismatch -or $sourceReceipt.operation -ne 'checkout') {
        return [pscustomobject]@{ Executed=$false; BlockedReason='两端借出回执不一致。'; PortableSourcePath=$sourceFull; LocalTargetPath=$targetFull; DeletedFiles=0 }
    }
    if (-not $sourceFull.Equals([System.IO.Path]::GetFullPath([string]$sourceReceipt.source_path), [System.StringComparison]::OrdinalIgnoreCase) -or
        -not $targetFull.Equals([System.IO.Path]::GetFullPath([string]$sourceReceipt.target_path), [System.StringComparison]::OrdinalIgnoreCase) -or
        -not $repositoryRoot.Equals([System.IO.Path]::GetFullPath([string]$sourceReceipt.repository_root).TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{ Executed=$false; BlockedReason='借出回执路径与当前路径不一致。'; PortableSourcePath=$sourceFull; LocalTargetPath=$targetFull; DeletedFiles=0 }
    }

    try {
        $sourceIdentity = Get-Content -LiteralPath (Join-Path $sourceFull '项目交接\项目身份.json') -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $targetIdentity = Get-Content -LiteralPath (Join-Path $targetFull '项目交接\项目身份.json') -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch { return [pscustomobject]@{ Executed=$false; BlockedReason='项目身份文件无法解析。'; PortableSourcePath=$sourceFull; LocalTargetPath=$targetFull; DeletedFiles=0 } }
    if ($sourceIdentity.project_id -ne $sourceReceipt.project_id -or $targetIdentity.project_id -ne $sourceReceipt.project_id -or
        $sourceIdentity.state -ne 'cleanup_pending' -or $targetIdentity.state -ne 'cleanup_pending' -or
        -not ([System.IO.Path]::GetFullPath([string]$sourceIdentity.official_location)).Equals($targetFull, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not ([System.IO.Path]::GetFullPath([string]$targetIdentity.official_location)).Equals($targetFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{ Executed=$false; BlockedReason='项目编号不一致。'; PortableSourcePath=$sourceFull; LocalTargetPath=$targetFull; DeletedFiles=0 }
    }
    if ($sourceSummary.ManifestDigest -ne $targetReceipt.source_manifest_digest -or $targetSummary.ManifestDigest -ne $targetReceipt.source_manifest_digest) {
        return [pscustomobject]@{ Executed=$false; BlockedReason='任一副本在复制后发生变化，已禁止清理并保留双份。'; PortableSourcePath=$sourceFull; LocalTargetPath=$targetFull; DeletedFiles=0 }
    }

    $deletedFiles = [int]$sourceSummary.FileCount
    $sourceInventoryBeforeCleanup = Get-PHMProjectInventory -ProjectPath $sourceFull
    try {
        $identity = Update-PHMIdentity -ProjectPath $targetFull -ComputerName $ComputerName -Operation 'checkout-cleanup-prepare' -State 'local_active' -OfficialLocation $targetFull
        Add-PHMHandoffRecord -ProjectPath $targetFull -ComputerName $ComputerName -ActionLabel '准备完成借出并清理 T9 来源' -Changes (New-PHMEmptyChanges) -ValidationResult '两端回执、身份、路径和完整摘要已复核；本机已先转为可恢复活动状态。' | Out-Null
        $recoveryRecord = [ordered]@{
            schema_version=1; operation='checkout-cleanup'; project_id=[string]$identity.project_id
            repository_root=$repositoryRoot; portable_source_path=$sourceFull; local_target_path=$targetFull
            source_manifest_digest=[string]$sourceReceipt.source_manifest_digest
            source_files=@($sourceInventoryBeforeCleanup.Files | ForEach-Object { [ordered]@{ relative_path=$_.RelativePath; size=[long]$_.Size; sha256=[string]$_.Hash } })
            state='prepared'; prepared_at=(Get-Date).ToUniversalTime().ToString('o')
        }
        Write-PHMUtf8File -Path (Join-Path $targetFull '项目交接\借出清理恢复.json') -Content ($recoveryRecord | ConvertTo-Json -Depth 5)
    }
    catch { return [pscustomobject]@{ Executed=$false; BlockedReason="无法先建立本机安全恢复状态：$($_.Exception.Message)"; Recoverable=$true; PortableSourcePath=$sourceFull; LocalTargetPath=$targetFull; DeletedFiles=0 } }
    if (-not $DeleteAction) { $DeleteAction = { param($path) Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop } }
    try { & $DeleteAction $sourceFull | Out-Null }
    catch { return [pscustomobject]@{ Executed=$false; BlockedReason="T9 来源清理失败：$($_.Exception.Message)"; Recoverable=$true; RecoveryState='local_active_source_retained'; PortableSourcePath=$sourceFull; LocalTargetPath=$targetFull; DeletedFiles=0 } }
    $registryPath = Get-PHMRegistryPathFromRepository -PortableRepositoryRoot $repositoryRoot
    $record = [pscustomobject]@{ projectId=[string]$identity.project_id; projectName=[string]$identity.project_name; state='checked_out'; location=$targetFull; updatedAt=(Get-Date).ToUniversalTime().ToString('o') }
    if (-not $RegistryWriter) { $RegistryWriter = { param($path,$item) Write-PHMRegistry -RegistryPath $path -Record $item } }
    $registryError = $null
    try {
        & $RegistryWriter $registryPath $record | Out-Null
        $registryState = 'checked_out'
        $recoverable = $false
        Remove-Item -LiteralPath (Join-Path $targetFull '项目交接\借出清理恢复.json') -Force -ErrorAction Stop
    }
    catch {
        $registryState = 'pending_repair'
        $recoverable = $true
        $registryError = $_.Exception.Message
    }
    [pscustomobject]@{ Executed=$true; DeletedSource=$true; PortableSourcePath=$sourceFull; LocalTargetPath=$targetFull; State='local_active'; RegistryPath=$registryPath; RegistryState=$registryState; RegistryError=$registryError; Recoverable=$recoverable; DeletedFiles=$deletedFiles }
}

function Repair-PHMCheckoutCleanup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LocalTargetPath,
        [Parameter(Mandatory)][string]$PortableRepositoryRoot,
        [Parameter(Mandatory)]$DriveInfo,
        [scriptblock]$DeleteAction,
        [scriptblock]$PathSafetyProvider,
        [scriptblock]$InventoryProvider,
        [scriptblock]$RegistryWriter,
        [string]$ComputerName = $env:COMPUTERNAME,
        [string]$ExpectedDriveLetter = 'T:',
        [string]$ExpectedVolumeLabel = 'T9',
        [string]$ExpectedFileSystem = 'NTFS',
        [string]$ExpectedFriendlyName = 'Samsung PSSD T9',
        [Parameter(Mandatory)][string]$ExpectedVolumeSerial,
        [Parameter(Mandatory)][string]$ExpectedDeviceId
    )

    $targetFull = (Get-Item -LiteralPath $LocalTargetPath -ErrorAction Stop).FullName
    $markerPath = Join-Path $targetFull '项目交接\借出清理恢复.json'
    $marker = Get-Content -LiteralPath $markerPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ([string]$marker.operation -ne 'checkout-cleanup' -or [string]$marker.state -ne 'prepared') { throw '借出清理恢复记录的操作或状态无效。' }

    $repositoryRoot = [System.IO.Path]::GetFullPath($PortableRepositoryRoot).TrimEnd('\')
    $markerRepository = [System.IO.Path]::GetFullPath([string]$marker.repository_root).TrimEnd('\')
    $sourceFull = [System.IO.Path]::GetFullPath([string]$marker.portable_source_path)
    $markerTarget = [System.IO.Path]::GetFullPath([string]$marker.local_target_path)
    if (-not $repositoryRoot.Equals($markerRepository, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not $targetFull.Equals($markerTarget, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw '借出清理恢复记录与指定仓库或本机项目不一致。'
    }

    $driveValidation = Test-PHMPortableDrive -Actual $DriveInfo -ExpectedDriveLetter $ExpectedDriveLetter -ExpectedVolumeLabel $ExpectedVolumeLabel -ExpectedFileSystem $ExpectedFileSystem -ExpectedFriendlyName $ExpectedFriendlyName -ExpectedVolumeSerial $ExpectedVolumeSerial -ExpectedDeviceId $ExpectedDeviceId
    if (-not $driveValidation.IsValid) { throw "设备或磁盘校验失败：$($driveValidation.Blockers -join '；')" }
    if (-not (Test-PHMPathOnValidatedDrive -Path $sourceFull -DriveInfo $DriveInfo) -or
        -not (Test-PHMPathOnValidatedDrive -Path $repositoryRoot -DriveInfo $DriveInfo)) {
        throw '恢复来源或项目仓库不在已验证 DriveInfo.DriveLetter 所指向的卷上。'
    }

    $pausedRoot = [System.IO.Path]::GetFullPath((Join-Path $repositoryRoot '暂停项目')).TrimEnd('\')
    foreach ($protectedPath in @($repositoryRoot, $pausedRoot, $sourceFull)) {
        if (-not (Test-PHMPathChainSafe -Path $protectedPath -PathSafetyProvider $PathSafetyProvider)) { throw "恢复路径链包含重解析点或无法验证：$protectedPath" }
    }
    $sourceParent = [System.IO.Path]::GetFullPath((Split-Path $sourceFull -Parent)).TrimEnd('\')
    if (-not $sourceParent.Equals($pausedRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-PHMDeletionPath -Path $sourceFull -ProtectedRoots @($pausedRoot))) {
        throw '恢复只允许清理指定仓库暂停项目下的直接项目子目录。'
    }

    $identity = Get-Content -LiteralPath (Join-Path $targetFull '项目交接\项目身份.json') -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ([string]$identity.project_id -ne [string]$marker.project_id -or [string]$identity.state -ne 'local_active' -or
        -not ([System.IO.Path]::GetFullPath([string]$identity.official_location)).Equals($targetFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw '本机项目身份与借出清理恢复记录不一致。'
    }

    $deletedSource = $false
    if (Test-Path -LiteralPath $sourceFull -PathType Container) {
        if (-not $InventoryProvider) { $InventoryProvider = { param($path) Get-PHMProjectInventory -ProjectPath $path } }
        $remainingInventory = & $InventoryProvider $sourceFull
        if (-not $remainingInventory) { throw '无法取得 T9 来源残余内容清单，禁止重试删除。' }
        if (@($remainingInventory.Unreadable).Count -gt 0) { throw 'T9 来源残余内容包含不可读文件或目录，禁止重试删除。' }
        if ($remainingInventory.ReparsePoints.Count -gt 0) { throw 'T9 来源残余内容包含重解析点，禁止重试删除。' }
        $originalFiles = @{}
        foreach ($file in @($marker.source_files)) { $originalFiles[([string]$file.relative_path).ToLowerInvariant()] = $file }
        if ($originalFiles.Count -eq 0 -and $remainingInventory.FileCount -gt 0) { throw '借出清理恢复记录缺少删除前逐文件清单。' }
        foreach ($remainingFile in @($remainingInventory.Files)) {
            $key = $remainingFile.RelativePath.ToLowerInvariant()
            if (-not $originalFiles.ContainsKey($key)) { throw "T9 来源残余内容出现新增文件：$($remainingFile.RelativePath)" }
            $original = $originalFiles[$key]
            if ([long]$remainingFile.Size -ne [long]$original.size -or [string]$remainingFile.Hash -ne [string]$original.sha256) {
                throw "T9 来源残余文件发生变化：$($remainingFile.RelativePath)"
            }
        }
        if (-not $DeleteAction) { $DeleteAction = { param($path) Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop } }
        & $DeleteAction $sourceFull | Out-Null
        $deletedSource = $true
    }

    $registryPath = Get-PHMRegistryPathFromRepository -PortableRepositoryRoot $repositoryRoot
    $record = [pscustomobject]@{ projectId=[string]$identity.project_id; projectName=[string]$identity.project_name; state='checked_out'; location=$targetFull; updatedAt=(Get-Date).ToUniversalTime().ToString('o') }
    if (-not $RegistryWriter) { $RegistryWriter = { param($path,$item) Write-PHMRegistry -RegistryPath $path -Record $item } }
    & $RegistryWriter $registryPath $record | Out-Null
    Remove-Item -LiteralPath $markerPath -Force -ErrorAction Stop

    [pscustomobject]@{
        Executed=$true; Repaired=$true; DeletedSource=$deletedSource; PortableSourcePath=$sourceFull
        LocalTargetPath=$targetFull; State='local_active'; RegistryPath=$registryPath; RegistryState='checked_out'
    }
}

Export-ModuleMember -Function Get-PHMVersion, Get-PHMMenu, Get-PHMProjectOverview, Initialize-PHMProject, Resume-PHMProject, Save-PHMCheckpoint, Read-PHMConfig, Get-PHMProjectProcessPlan, Suspend-PHMProject, Test-PHMPortableDrive, Get-PHMPortableDriveInfo, Register-PHMPortableDevice, Get-PHMProjectInventory, New-PHMCheckinPlan, Invoke-PHMCheckin, Test-PHMDeletionPath, Complete-PHMCheckinCleanup, New-PHMCheckoutPlan, Test-PHMProjectEnvironment, Write-PHMContinuePrompt, Invoke-PHMCheckout, Repair-PHMCheckoutFinalization, Complete-PHMCheckoutCleanup, Repair-PHMCheckoutCleanup
