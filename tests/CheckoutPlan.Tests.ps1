Describe '从 T9 借出执行计划' {
    BeforeAll {
        $modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'project-handoff-manager\scripts\ProjectManager.Core.psm1'
        Import-Module $modulePath -Force
        $script:CheckoutTestDriveLetter = [System.IO.Path]::GetPathRoot($TestDrive).TrimEnd('\')
        $PSDefaultParameterValues['New-PHMCheckoutPlan:ExpectedDriveLetter'] = $script:CheckoutTestDriveLetter
        function New-CheckoutDriveInfo {
            [pscustomobject]@{DriveLetter=$script:CheckoutTestDriveLetter;VolumeLabel='T9';FileSystem='NTFS';HealthStatus='Healthy';OperationalStatus='OK';IsReadOnly=$false;IsOffline=$false;FreeBytes=100GB;FriendlyName='Samsung PSSD T9';VolumeSerial='TEST';DeviceId='test'}
        }
        function New-PortableProject {
            param([string]$Repository,[string]$Name='借出项目',[switch]$Unmanaged)
            $path=Join-Path $Repository "暂停项目\$Name"
            New-Item -ItemType Directory -Path $path -Force|Out-Null
            if(-not $Unmanaged){Initialize-PHMProject -ProjectPath $path -InitialState 'on_t9'|Out-Null}
            Set-Content -LiteralPath (Join-Path $path 'data.txt') -Value 'portable' -Encoding utf8
            return $path
        }
    }

    It '生成 T9 来源、本机暂存和本机正式路径且不复制' {
        $repository=Join-Path $TestDrive '项目仓库'
        $source=New-PortableProject -Repository $repository
        $currentRoot=Join-Path $TestDrive '01-当前项目'
        $receivingRoot=Join-Path $TestDrive '00-待整理\正在接收'
        $identity=Get-Content -LiteralPath (Join-Path $source '项目交接\项目身份.json') -Raw|ConvertFrom-Json

        $plan=New-PHMCheckoutPlan -PortableProjectPath $source -PortableRepositoryRoot $repository -LocalCurrentRoot $currentRoot -LocalReceivingRoot $receivingRoot -DriveInfo (New-CheckoutDriveInfo) -ExpectedVolumeSerial TEST -ExpectedDeviceId test

        $plan.CanExecute|Should -BeTrue
        $plan.SourcePath|Should -Be (Get-Item $source).FullName
        $plan.ReceivingPath|Should -Be (Join-Path $receivingRoot "$($identity.project_id)\借出项目")
        $plan.OfficialPath|Should -Be (Join-Path $currentRoot '借出项目')
        $plan.Inventory.FileCount|Should -BeGreaterThan 3
        Test-Path -LiteralPath $plan.ReceivingPath|Should -BeFalse
        Test-Path -LiteralPath $plan.OfficialPath|Should -BeFalse
    }

    It '没有身份的旧项目显示为借出前自动纳管' {
        $repository=Join-Path $TestDrive '旧仓库'
        $source=New-PortableProject -Repository $repository -Name '旧项目' -Unmanaged

        $plan=New-PHMCheckoutPlan -PortableProjectPath $source -PortableRepositoryRoot $repository -LocalCurrentRoot (Join-Path $TestDrive '当前') -LocalReceivingRoot (Join-Path $TestDrive '接收') -DriveInfo (New-CheckoutDriveInfo) -ExpectedVolumeSerial TEST -ExpectedDeviceId test

        $plan.NeedsAdoption|Should -BeTrue
        $plan.CanExecute|Should -BeTrue
        $plan.ExpectedActions -join '；'|Should -Match '自动纳管'
    }

    It '本机同名正式目录或残留暂存目录存在时拒绝覆盖' {
        $repository=Join-Path $TestDrive '冲突仓库'
        $source=New-PortableProject -Repository $repository -Name '冲突项目'
        $currentRoot=Join-Path $TestDrive '冲突当前'
        $receivingRoot=Join-Path $TestDrive '冲突接收'
        $identity=Get-Content -LiteralPath (Join-Path $source '项目交接\项目身份.json') -Raw|ConvertFrom-Json
        New-Item -ItemType Directory -Path (Join-Path $currentRoot '冲突项目'),(Join-Path $receivingRoot "$($identity.project_id)\冲突项目") -Force|Out-Null

        $plan=New-PHMCheckoutPlan -PortableProjectPath $source -PortableRepositoryRoot $repository -LocalCurrentRoot $currentRoot -LocalReceivingRoot $receivingRoot -DriveInfo (New-CheckoutDriveInfo) -ExpectedVolumeSerial TEST -ExpectedDeviceId test

        $plan.CanExecute|Should -BeFalse
        $plan.Blockers -join '；'|Should -Match '本机正式目录已存在'
        $plan.Blockers -join '；'|Should -Match '本机暂存目录已存在'
    }

    It '错误磁盘或本机空间不足时阻断借出' {
        $repository=Join-Path $TestDrive '磁盘仓库'
        $source=New-PortableProject -Repository $repository -Name '磁盘项目'
        $drive=New-CheckoutDriveInfo
        $drive.VolumeLabel='WRONG'

        $plan=New-PHMCheckoutPlan -PortableProjectPath $source -PortableRepositoryRoot $repository -LocalCurrentRoot (Join-Path $TestDrive '当前2') -LocalReceivingRoot (Join-Path $TestDrive '接收2') -DriveInfo $drive -LocalFreeBytes 0 -ExpectedVolumeSerial TEST -ExpectedDeviceId test

        $plan.CanExecute|Should -BeFalse
        $plan.Blockers -join '；'|Should -Match '卷标'
        $plan.Blockers -join '；'|Should -Match '本机空间不足'
    }
}
