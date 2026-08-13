Describe '事务式从 T9 借出' {
    BeforeAll {
        $modulePath=Join-Path (Split-Path $PSScriptRoot -Parent) 'project-handoff-manager\scripts\ProjectManager.Core.psm1'
        Import-Module $modulePath -Force
        $script:CheckoutTestDriveLetter = [System.IO.Path]::GetPathRoot($TestDrive).TrimEnd('\')
        foreach ($commandName in @('New-PHMCheckoutPlan','Invoke-PHMCheckout','Complete-PHMCheckoutCleanup','Repair-PHMCheckoutFinalization','Repair-PHMCheckoutCleanup')) {
            $PSDefaultParameterValues["${commandName}:ExpectedDriveLetter"] = $script:CheckoutTestDriveLetter
        }
        function New-CheckoutDrive {[pscustomobject]@{DriveLetter=$script:CheckoutTestDriveLetter;VolumeLabel='T9';FileSystem='NTFS';HealthStatus='Healthy';OperationalStatus='OK';IsReadOnly=$false;IsOffline=$false;FreeBytes=100GB;FriendlyName='Samsung PSSD T9';VolumeSerial='TEST';DeviceId='test'}}
        function New-CheckoutFixture {
            param([string]$Name)
            $repo=Join-Path $TestDrive "$Name-工作盘\项目仓库"
            $source=Join-Path $repo "暂停项目\$Name"
            New-Item -ItemType Directory -Path $source -Force|Out-Null
            Initialize-PHMProject -ProjectPath $source -InitialState 'on_t9'|Out-Null
            Set-Content -LiteralPath (Join-Path $source 'data.txt') -Value 'portable-data' -Encoding utf8
            [pscustomobject]@{Repository=$repo;Source=$source;CurrentRoot=(Join-Path $TestDrive "$Name-当前");ReceivingRoot=(Join-Path $TestDrive "$Name-接收")}
        }
    }

    It '成功时本机目标完成校验但 T9 来源仍保留等待独立清理' {
        $fixture=New-CheckoutFixture -Name '成功借出'

        $result=Invoke-PHMCheckout -PortableProjectPath $fixture.Source -PortableRepositoryRoot $fixture.Repository -LocalCurrentRoot $fixture.CurrentRoot -LocalReceivingRoot $fixture.ReceivingRoot -DriveInfo (New-CheckoutDrive) -ExpectedVolumeSerial TEST -ExpectedDeviceId test -ConfirmTransfer

        $result.Executed|Should -BeTrue
        $result.Verified|Should -BeTrue
        $result.CleanupRequired|Should -BeTrue
        Test-Path -LiteralPath $fixture.Source|Should -BeTrue
        Test-Path -LiteralPath $result.OfficialPath|Should -BeTrue
        Test-Path -LiteralPath $result.ReceivingPath|Should -BeFalse
        (Get-Content -LiteralPath (Join-Path $fixture.Source '项目交接\项目身份.json') -Raw|ConvertFrom-Json).state|Should -Be 'cleanup_pending'
        (Get-Content -LiteralPath (Join-Path $result.OfficialPath '项目交接\项目身份.json') -Raw|ConvertFrom-Json).state|Should -Be 'cleanup_pending'
        Test-Path -LiteralPath (Join-Path $result.OfficialPath '项目交接\继续项目提示词.md')|Should -BeTrue
    }

    It '复制失败、来源变化或校验差异时始终保留 T9 来源' {
        $fixture=New-CheckoutFixture -Name '失败借出'
        $failure={param($s,$d)[pscustomobject]@{Success=$false;ExitCode=8;Message='fail'}}

        $result=Invoke-PHMCheckout -PortableProjectPath $fixture.Source -PortableRepositoryRoot $fixture.Repository -LocalCurrentRoot $fixture.CurrentRoot -LocalReceivingRoot $fixture.ReceivingRoot -DriveInfo (New-CheckoutDrive) -ExpectedVolumeSerial TEST -ExpectedDeviceId test -ConfirmTransfer -CopyAction $failure

        $result.Executed|Should -BeFalse
        $result.FailureStage|Should -Be 'copy'
        Test-Path -LiteralPath $fixture.Source|Should -BeTrue
        Test-Path -LiteralPath $result.OfficialPath|Should -BeFalse
        $result.DeletedFiles|Should -Be 0
    }

    It '未纳管旧项目可完成借出并在两端进入 cleanup_pending' {
        $repo=Join-Path $TestDrive '未纳管-工作盘\项目仓库'
        $source=Join-Path $repo '暂停项目\未纳管项目'
        New-Item -ItemType Directory -Path $source -Force|Out-Null
        Set-Content -LiteralPath (Join-Path $source 'data.txt') -Value 'legacy' -Encoding utf8

        $result=Invoke-PHMCheckout -PortableProjectPath $source -PortableRepositoryRoot $repo -LocalCurrentRoot (Join-Path $TestDrive '未纳管-当前') -LocalReceivingRoot (Join-Path $TestDrive '未纳管-接收') -DriveInfo (New-CheckoutDrive) -ExpectedVolumeSerial TEST -ExpectedDeviceId test -ConfirmTransfer

        $result.Executed|Should -BeTrue
        (Get-Content -LiteralPath (Join-Path $source '项目交接\项目身份.json') -Raw|ConvertFrom-Json).state|Should -Be 'cleanup_pending'
        (Get-Content -LiteralPath (Join-Path $result.OfficialPath '项目交接\项目身份.json') -Raw|ConvertFrom-Json).state|Should -Be 'cleanup_pending'
        Test-Path -LiteralPath (Join-Path $result.OfficialPath '项目交接\转移凭证.json')|Should -BeTrue
    }

    It '确认清理且两份未变化时删除 T9 来源并将本机状态更新为 local_active' {
        $fixture=New-CheckoutFixture -Name '完成借出'
        $transfer=Invoke-PHMCheckout -PortableProjectPath $fixture.Source -PortableRepositoryRoot $fixture.Repository -LocalCurrentRoot $fixture.CurrentRoot -LocalReceivingRoot $fixture.ReceivingRoot -DriveInfo (New-CheckoutDrive) -ExpectedVolumeSerial TEST -ExpectedDeviceId test -ConfirmTransfer

        $result=Complete-PHMCheckoutCleanup -PortableSourcePath $fixture.Source -LocalTargetPath $transfer.OfficialPath -PortableRepositoryRoot $fixture.Repository -DriveInfo (New-CheckoutDrive) -ExpectedVolumeSerial TEST -ExpectedDeviceId test -ConfirmCleanup
        $identity=Get-Content -LiteralPath (Join-Path $transfer.OfficialPath '项目交接\项目身份.json') -Raw|ConvertFrom-Json

        $result.Executed|Should -BeTrue
        Test-Path -LiteralPath $fixture.Source|Should -BeFalse
        Test-Path -LiteralPath $transfer.OfficialPath|Should -BeTrue
        $identity.state|Should -Be 'local_active'
        $identity.official_location|Should -Be (Get-Item $transfer.OfficialPath).FullName
    }

    It '等待清理期间任一副本增加材料时阻止删除 T9 来源' {
        $fixture=New-CheckoutFixture -Name '变化借出'
        $transfer=Invoke-PHMCheckout -PortableProjectPath $fixture.Source -PortableRepositoryRoot $fixture.Repository -LocalCurrentRoot $fixture.CurrentRoot -LocalReceivingRoot $fixture.ReceivingRoot -DriveInfo (New-CheckoutDrive) -ExpectedVolumeSerial TEST -ExpectedDeviceId test -ConfirmTransfer
        Set-Content -LiteralPath (Join-Path $transfer.OfficialPath '输入资料\新材料.txt') -Value 'new' -Encoding utf8

        $result=Complete-PHMCheckoutCleanup -PortableSourcePath $fixture.Source -LocalTargetPath $transfer.OfficialPath -PortableRepositoryRoot $fixture.Repository -DriveInfo (New-CheckoutDrive) -ExpectedVolumeSerial TEST -ExpectedDeviceId test -ConfirmCleanup

        $result.Executed|Should -BeFalse
        $result.BlockedReason|Should -Match '发生变化'
        Test-Path -LiteralPath $fixture.Source|Should -BeTrue
        Test-Path -LiteralPath $transfer.OfficialPath|Should -BeTrue
    }
}
