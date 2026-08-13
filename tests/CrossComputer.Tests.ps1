Describe '电脑 A 到模拟 T9 再到电脑 B 的完整闭环' {
    BeforeAll {
        $modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'project-handoff-manager\scripts\ProjectManager.Core.psm1'
        Import-Module $modulePath -Force
        $script:SimulatedDriveLetter = [System.IO.Path]::GetPathRoot($TestDrive).TrimEnd('\')

        function New-CheckinDrive {
            [pscustomobject]@{
                DriveLetter=$script:SimulatedDriveLetter; VolumeLabel='T9'; FileSystem='NTFS'; HealthStatus='Healthy'; OperationalStatus='OK'
                IsReadOnly=$false; IsOffline=$false; FreeBytes=100GB; FriendlyName='Samsung PSSD T9'
                VolumeSerial='SIMULATED'; DeviceId='simulated-device'
            }
        }
        function New-CheckoutDrive {
            [pscustomobject]@{
                DriveLetter=$script:SimulatedDriveLetter; VolumeLabel='T9'; FileSystem='NTFS'; HealthStatus='Healthy'; OperationalStatus='OK'
                IsReadOnly=$false; IsOffline=$false; FreeBytes=100GB; FriendlyName='Samsung PSSD T9'
                VolumeSerial='SIMULATED'; DeviceId='simulated-device'
            }
        }
    }

    It '归还 A、清理 A、借出 B、恢复并新增材料、再归还清理 B，最终仅模拟 T9 保留正式副本' {
        $computerARoot = Join-Path $TestDrive 'computer-a\current'
        $computerBRoot = Join-Path $TestDrive 'computer-b\current'
        $computerBReceiving = Join-Path $TestDrive 'computer-b\receiving'
        $portableRepository = Join-Path $TestDrive 'simulated-t9\项目仓库'
        $computerAProject = Join-Path $computerARoot '跨电脑项目'
        New-Item -ItemType Directory -Path $computerAProject -Force | Out-Null
        Initialize-PHMProject -ProjectPath $computerAProject -ComputerName 'COMPUTER-A' | Out-Null
        Set-Content -LiteralPath (Join-Path $computerAProject '输入资料\初始材料.txt') -Value 'from-a' -Encoding utf8

        $aCheckin = Invoke-PHMCheckin -ProjectPath $computerAProject -PortableRepositoryRoot $portableRepository -DriveInfo (New-CheckinDrive) -ProcessRecords @() -ConfirmTransfer -ExpectedDriveLetter $script:SimulatedDriveLetter -ExpectedVolumeSerial SIMULATED -ExpectedDeviceId simulated-device -ComputerName 'COMPUTER-A'
        $aCleanup = Complete-PHMCheckinCleanup -SourcePath $computerAProject -TargetPath $aCheckin.OfficialPath -PortableRepositoryRoot $portableRepository -DriveInfo (New-CheckinDrive) -ExpectedDriveLetter $script:SimulatedDriveLetter -ExpectedVolumeSerial SIMULATED -ExpectedDeviceId simulated-device -ConfirmCleanup -ProtectedRoots @($computerARoot)
        $aCheckin.Executed | Should -BeTrue
        $aCleanup.Executed | Should -BeTrue
        Test-Path -LiteralPath $computerAProject | Should -BeFalse

        $bCheckout = Invoke-PHMCheckout -PortableProjectPath $aCheckin.OfficialPath -PortableRepositoryRoot $portableRepository -LocalCurrentRoot $computerBRoot -LocalReceivingRoot $computerBReceiving -DriveInfo (New-CheckoutDrive) -LocalFreeBytes 100GB -ExpectedDriveLetter $script:SimulatedDriveLetter -ExpectedVolumeSerial SIMULATED -ExpectedDeviceId simulated-device -ConfirmTransfer -ComputerName 'COMPUTER-B'
        $bCleanup = Complete-PHMCheckoutCleanup -PortableSourcePath $aCheckin.OfficialPath -LocalTargetPath $bCheckout.OfficialPath -PortableRepositoryRoot $portableRepository -DriveInfo (New-CheckoutDrive) -ExpectedDriveLetter $script:SimulatedDriveLetter -ExpectedVolumeSerial SIMULATED -ExpectedDeviceId simulated-device -ConfirmCleanup -ComputerName 'COMPUTER-B'
        $resume = Resume-PHMProject -ProjectPath $bCheckout.OfficialPath -ComputerName 'COMPUTER-B'
        $bCheckout.Executed | Should -BeTrue
        $bCleanup.Executed | Should -BeTrue
        $resume.State | Should -Be 'local_active'
        Test-Path -LiteralPath $resume.EnvironmentPath | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $bCheckout.OfficialPath '项目交接\继续项目提示词.md') | Should -BeTrue
        Test-Path -LiteralPath $aCheckin.OfficialPath | Should -BeFalse

        $newMaterial = Join-Path $bCheckout.OfficialPath '输入资料\电脑B新增材料.txt'
        Set-Content -LiteralPath $newMaterial -Value 'from-b' -Encoding utf8
        $bCheckin = Invoke-PHMCheckin -ProjectPath $bCheckout.OfficialPath -PortableRepositoryRoot $portableRepository -DriveInfo (New-CheckinDrive) -ProcessRecords @() -ConfirmTransfer -ExpectedDriveLetter $script:SimulatedDriveLetter -ExpectedVolumeSerial SIMULATED -ExpectedDeviceId simulated-device -ComputerName 'COMPUTER-B'
        $finalCleanup = Complete-PHMCheckinCleanup -SourcePath $bCheckout.OfficialPath -TargetPath $bCheckin.OfficialPath -PortableRepositoryRoot $portableRepository -DriveInfo (New-CheckinDrive) -ExpectedDriveLetter $script:SimulatedDriveLetter -ExpectedVolumeSerial SIMULATED -ExpectedDeviceId simulated-device -ConfirmCleanup -ProtectedRoots @($computerBRoot)

        $bCheckin.Executed | Should -BeTrue
        $finalCleanup.Executed | Should -BeTrue
        Test-Path -LiteralPath $computerAProject | Should -BeFalse
        Test-Path -LiteralPath $bCheckout.OfficialPath | Should -BeFalse
        Test-Path -LiteralPath $bCheckin.OfficialPath | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $bCheckin.OfficialPath '输入资料\电脑B新增材料.txt') | Should -BeTrue
        (Get-Content -LiteralPath (Join-Path $bCheckin.OfficialPath '项目交接\项目身份.json') -Raw | ConvertFrom-Json).state | Should -Be 'on_t9'
        @(Get-ChildItem -LiteralPath (Join-Path $portableRepository '暂停项目') -Directory).Count | Should -Be 1
    }
}
