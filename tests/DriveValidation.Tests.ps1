Describe 'T9 移动盘校验' {
    BeforeAll {
        $modulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'project-handoff-manager\scripts\ProjectManager.Core.psm1'
        Import-Module $modulePath -Force

        function New-ValidDriveInfo {
            [pscustomobject]@{
                DriveLetter='T:'; VolumeLabel='T9'; FileSystem='NTFS'; HealthStatus='Healthy'
                OperationalStatus='OK'; IsReadOnly=$false; IsOffline=$false; FreeBytes=500GB
                FriendlyName='Samsung PSSD T9'; VolumeSerial='ABCD1234'; DeviceId='portable-device-1'
            }
        }
    }

    It '所有身份、健康、可写和容量条件满足时通过' {
        $result = Test-PHMPortableDrive -Actual (New-ValidDriveInfo) -ExpectedDriveLetter 'T:' -ExpectedVolumeLabel 'T9' -ExpectedFileSystem 'NTFS' -ExpectedFriendlyName 'Samsung PSSD T9' -ExpectedVolumeSerial 'ABCD1234' -ExpectedDeviceId 'portable-device-1' -RequiredBytes 100GB

        $result.IsValid | Should -BeTrue
        $result.Blockers.Count | Should -Be 0
        $result.FreeBytes | Should -Be 500GB
    }

    It '错误盘符、卷标、文件系统或设备型号均会阻断' {
        $actual = New-ValidDriveInfo
        $actual.DriveLetter = 'E:'
        $actual.VolumeLabel = 'OTHER'
        $actual.FileSystem = 'exFAT'
        $actual.FriendlyName = 'Generic USB Disk'

        $result = Test-PHMPortableDrive -Actual $actual -ExpectedDriveLetter 'T:' -ExpectedVolumeLabel 'T9' -ExpectedFileSystem 'NTFS' -ExpectedFriendlyName 'Samsung PSSD T9'

        $result.IsValid | Should -BeFalse
        $result.Blockers -join '；' | Should -Match '盘符'
        $result.Blockers -join '；' | Should -Match '卷标'
        $result.Blockers -join '；' | Should -Match '文件系统'
        $result.Blockers -join '；' | Should -Match '设备型号'
    }

    It '只读、离线、不健康或空间不足均会阻断' {
        $actual = New-ValidDriveInfo
        $actual.IsReadOnly = $true
        $actual.IsOffline = $true
        $actual.HealthStatus = 'Warning'
        $actual.OperationalStatus = 'Degraded'
        $actual.FreeBytes = 10MB

        $result = Test-PHMPortableDrive -Actual $actual -RequiredBytes 20MB

        $result.IsValid | Should -BeFalse
        $result.Blockers -join '；' | Should -Match '只读'
        $result.Blockers -join '；' | Should -Match '离线'
        $result.Blockers -join '；' | Should -Match '健康'
        $result.Blockers -join '；' | Should -Match '空间不足'
    }

    It '卷序列或项目管家设备标识不一致时阻断且结果不回显完整序列号' {
        $actual = New-ValidDriveInfo

        $result = Test-PHMPortableDrive -Actual $actual -ExpectedVolumeSerial 'DIFFERENT' -ExpectedDeviceId 'other-device'
        $json = $result | ConvertTo-Json -Depth 5

        $result.IsValid | Should -BeFalse
        $result.Blockers -join '；' | Should -Match '卷序列'
        $result.Blockers -join '；' | Should -Match '设备标识'
        $json | Should -Not -Match 'ABCD1234'
        $json | Should -Not -Match 'portable-device-1'
    }
}
