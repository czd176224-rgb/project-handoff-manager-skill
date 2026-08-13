Describe 'T9 一次性设备绑定' {
    BeforeAll {
        $modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'project-handoff-manager\scripts\ProjectManager.Core.psm1'
        Import-Module $modulePath -Force
        function New-RegistrationDrive {
            [pscustomobject]@{
                DriveLetter='T:';VolumeLabel='T9';FileSystem='NTFS';HealthStatus='Healthy';OperationalStatus='OK'
                IsReadOnly=$false;IsOffline=$false;FreeBytes=100GB;FriendlyName='Samsung PSSD T9'
                VolumeSerial='LOCAL-SERIAL-ONLY';DeviceId=$null
            }
        }
    }

    It '未确认时只显示将写入的两个精确位置' {
        $marker = Join-Path $TestDrive 'T9\管理资料\项目管家设备.json'
        $trust = Join-Path $TestDrive '本机\项目管家设备信任.json'

        $result = Register-PHMPortableDevice -DriveInfo (New-RegistrationDrive) -DeviceMarkerPath $marker -LocalTrustPath $trust

        $result.Executed | Should -BeFalse
        $result.RequiresConfirmation | Should -BeTrue
        $result.DeviceMarkerPath | Should -Be $marker
        $result.LocalTrustPath | Should -Be $trust
        Test-Path -LiteralPath $marker | Should -BeFalse
        Test-Path -LiteralPath $trust | Should -BeFalse
    }

    It '确认后写入同一随机设备标识且不在移动盘标识中保存卷序列' {
        $marker = Join-Path $TestDrive 'T9确认\管理资料\项目管家设备.json'
        $trust = Join-Path $TestDrive '本机确认\项目管家设备信任.json'

        $result = Register-PHMPortableDevice -DriveInfo (New-RegistrationDrive) -DeviceMarkerPath $marker -LocalTrustPath $trust -ConfirmRegistration
        $markerData = Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json
        $trustData = Get-Content -LiteralPath $trust -Raw | ConvertFrom-Json

        $result.Executed | Should -BeTrue
        { [guid]::Parse($markerData.device_id) } | Should -Not -Throw
        $trustData.device_id | Should -Be $markerData.device_id
        $trustData.volume_serial | Should -Be 'LOCAL-SERIAL-ONLY'
        ($markerData.PSObject.Properties.Name) | Should -Not -Contain 'volume_serial'
        ($result | ConvertTo-Json) | Should -Not -Match 'LOCAL-SERIAL-ONLY'
    }

    It '错误型号或只读磁盘不允许绑定' {
        $drive = New-RegistrationDrive
        $drive.FriendlyName = 'Generic USB'
        $drive.IsReadOnly = $true

        $result = Register-PHMPortableDevice -DriveInfo $drive -DeviceMarkerPath (Join-Path $TestDrive 'marker.json') -LocalTrustPath (Join-Path $TestDrive 'trust.json') -ConfirmRegistration

        $result.Executed | Should -BeFalse
        $result.Blockers -join '；' | Should -Match '设备型号'
        $result.Blockers -join '；' | Should -Match '只读'
    }
}
