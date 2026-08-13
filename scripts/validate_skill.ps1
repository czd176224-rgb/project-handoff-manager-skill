[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SkillPath
)

$skillFile = Join-Path $SkillPath 'SKILL.md'
$agentFile = Join-Path $SkillPath 'agents\openai.yaml'

if (-not (Test-Path -LiteralPath $skillFile -PathType Leaf)) {
    return $false
}

if (-not (Test-Path -LiteralPath $agentFile -PathType Leaf)) {
    return $false
}

$content = Get-Content -LiteralPath $skillFile -Raw
$frontmatter = [regex]::Match($content, '\A---\r?\n(?<body>.*?)\r?\n---', 'Singleline')
if (-not $frontmatter.Success) {
    return $false
}

$body = $frontmatter.Groups['body'].Value
$nameMatch = [regex]::Match($body, '(?m)^name:\s*(?<value>[a-z0-9-]+)\s*$')
$descriptionMatch = [regex]::Match($body, '(?m)^description:\s*(?<value>.+)\s*$')

if (-not $nameMatch.Success -or -not $descriptionMatch.Success) {
    return $false
}

$name = $nameMatch.Groups['value'].Value
if ($name.Length -gt 64 -or $name.StartsWith('-') -or $name.EndsWith('-') -or $name.Contains('--')) {
    return $false
}

return $true
