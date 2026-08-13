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
        [pscustomobject]@{ Id = 1; Action = 'resume'; Name = '开始或继续当前项目'; RequiresPreview = $true; Implemented = $false }
        [pscustomobject]@{ Id = 2; Action = 'pause'; Name = '暂停当前项目'; RequiresPreview = $true; Implemented = $false }
        [pscustomobject]@{ Id = 3; Action = 'checkin'; Name = '将当前项目归还到 T9'; RequiresPreview = $true; Implemented = $false }
        [pscustomobject]@{ Id = 4; Action = 'checkout'; Name = '从 T9 借出项目到本机'; RequiresPreview = $true; Implemented = $false }
    )
}

Export-ModuleMember -Function Get-PHMVersion, Get-PHMMenu
