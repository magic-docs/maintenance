$ErrorActionPreference = "Stop"

function Read-YesNo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prompt,
        [bool]$DefaultYes = $true
    )

    while ($true) {
        $suffix = if ($DefaultYes) { "[Y/n]" } else { "[y/N]" }
        $answer = (Read-Host "$Prompt $suffix").Trim()

        if ([string]::IsNullOrWhiteSpace($answer)) {
            return $DefaultYes
        }

        switch -Regex ($answer.ToLowerInvariant()) {
            "^(y|yes)$" { return $true }
            "^(n|no)$" { return $false }
            default { Write-Host "Please answer y or n." -ForegroundColor Yellow }
        }
    }
}

function Read-PositiveInteger {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prompt,
        [int]$DefaultValue
    )

    while ($true) {
        $fullPrompt = if ($PSBoundParameters.ContainsKey("DefaultValue")) {
            "$Prompt [$DefaultValue]"
        }
        else {
            $Prompt
        }

        $answer = (Read-Host $fullPrompt).Trim()

        if ([string]::IsNullOrWhiteSpace($answer) -and $PSBoundParameters.ContainsKey("DefaultValue")) {
            return $DefaultValue
        }

        $parsed = 0
        if ([int]::TryParse($answer, [ref]$parsed) -and $parsed -ge 1) {
            return $parsed
        }

        Write-Host "Please enter a whole number >= 1." -ForegroundColor Yellow
    }
}

function Read-CsvFileName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prompt,
        [Parameter(Mandatory = $true)]
        [string]$DirectoryPath
    )

    while ($true) {
        $candidate = (Read-Host $Prompt).Trim()

        if ([string]::IsNullOrWhiteSpace($candidate)) {
            Write-Host "File name cannot be empty." -ForegroundColor Yellow
            continue
        }

        $invalidChars = [System.IO.Path]::GetInvalidFileNameChars()
        $containsInvalid = $false
        foreach ($char in $invalidChars) {
            if ($candidate.Contains($char)) {
                $containsInvalid = $true
                break
            }
        }

        if ($containsInvalid) {
            Write-Host "File name contains invalid characters." -ForegroundColor Yellow
            continue
        }

        if (-not $candidate.ToLowerInvariant().EndsWith(".csv")) {
            $candidate = "$candidate.csv"
        }

        $candidatePath = (Join-Path -Path $DirectoryPath -ChildPath $candidate)
        if (Test-Path -LiteralPath $candidatePath) {
            $overwrite = Read-YesNo -Prompt "WARNING: '$candidate' already exists and all data in it will be deleted if you continue. Overwrite it?" -DefaultYes $false
            if ($overwrite) {
                Remove-Item -LiteralPath $candidatePath -Force
                return $candidatePath
            }

            Write-Host "Choose another file name or select an existing file." -ForegroundColor Yellow
            continue
        }

        return $candidatePath
    }
}

function Resolve-TargetCsvPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DirectoryPath
    )

    $csvFiles = @(Get-ChildItem -Path $DirectoryPath -Filter *.csv -File -ErrorAction SilentlyContinue)

    if ($csvFiles.Count -eq 0) {
        Write-Host "No CSV files found in: $DirectoryPath" -ForegroundColor Yellow
        return Read-CsvFileName -Prompt "Enter a new CSV file name to create" -DirectoryPath $DirectoryPath
    }

    if ($csvFiles.Count -eq 1) {
        $onlyFile = $csvFiles[0]
        $useExisting = Read-YesNo -Prompt "Found CSV '$($onlyFile.Name)'. Continue with this file?" -DefaultYes $true
        if ($useExisting) {
            return $onlyFile.FullName
        }

        return Read-CsvFileName -Prompt "Enter a different CSV file name" -DirectoryPath $DirectoryPath
    }

    $latestFile = $csvFiles | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $useLatest = Read-YesNo -Prompt "Found $($csvFiles.Count) CSV files. Latest is '$($latestFile.Name)' (modified $($latestFile.LastWriteTime)). Continue with it?" -DefaultYes $true
    if ($useLatest) {
        return $latestFile.FullName
    }

    Write-Host ""
    Write-Host "CSV files found:" -ForegroundColor Cyan
    $sorted = $csvFiles | Sort-Object LastWriteTime -Descending
    $index = 1
    foreach ($file in $sorted) {
        Write-Host ("{0}. {1} (modified {2})" -f $index, $file.Name, $file.LastWriteTime)
        $index++
    }
    Write-Host ""

    $choice = Read-Host "Enter an existing file number, or type a new file name"
    $choice = $choice.Trim()

    $picked = 0
    if ([int]::TryParse($choice, [ref]$picked) -and $picked -ge 1 -and $picked -le $sorted.Count) {
        return $sorted[$picked - 1].FullName
    }

    if ([string]::IsNullOrWhiteSpace($choice)) {
        return Read-CsvFileName -Prompt "Enter a new CSV file name" -DirectoryPath $DirectoryPath
    }

    if (-not $choice.ToLowerInvariant().EndsWith(".csv")) {
        $choice = "$choice.csv"
    }

    $candidatePath = (Join-Path -Path $DirectoryPath -ChildPath $choice)
    if (Test-Path -LiteralPath $candidatePath) {
        $overwrite = Read-YesNo -Prompt "WARNING: '$choice' already exists and all data in it will be deleted if you continue. Overwrite it?" -DefaultYes $false
        if ($overwrite) {
            Remove-Item -LiteralPath $candidatePath -Force
            return $candidatePath
        }

        Write-Host "Choose another file name or select an existing file." -ForegroundColor Yellow
        return Read-CsvFileName -Prompt "Enter a different CSV file name" -DirectoryPath $DirectoryPath
    }

    return $candidatePath
}

function Get-ComputerNumber {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CsvPath
    )

    while ($true) {
        $rows = @()
        if (Test-Path -LiteralPath $CsvPath) {
            try {
                $rows = @(Import-Csv -LiteralPath $CsvPath -ErrorAction Stop)
            }
            catch {
                Write-Host "Could not parse existing CSV. Starting numbering from 1." -ForegroundColor Yellow
                $rows = @()
            }
        }

        $maxNumber = 0
        foreach ($row in $rows) {
            if ($null -eq $row.computer_number) {
                continue
            }

            $candidate = 0
            if ([int]::TryParse(($row.computer_number.ToString().Trim()), [ref]$candidate) -and $candidate -gt $maxNumber) {
                $maxNumber = $candidate
            }
        }

        $suggested = if ($maxNumber -ge 1) { $maxNumber + 1 } else { 1 }
        $selected = $null

        if ($rows.Count -eq 0) {
            $ok = Read-YesNo -Prompt "No existing entries found. Use computer number $suggested?" -DefaultYes $true
            if ($ok) {
                $selected = $suggested
            }
            else {
                $selected = Read-PositiveInteger -Prompt "Enter computer number" -DefaultValue $suggested
            }
        }
        else {
            $ok = Read-YesNo -Prompt "Use computer number $suggested for this scan?" -DefaultYes $true
            if ($ok) {
                $selected = $suggested
            }
            else {
                $selected = Read-PositiveInteger -Prompt "Enter computer number" -DefaultValue $suggested
            }
        }

        $existingRow = $rows | Where-Object {
            $null -ne $_.computer_number -and
            $_.computer_number.ToString().Trim() -eq $selected.ToString()
        } | Select-Object -First 1

        if ($existingRow) {
            $overwrite = Read-YesNo -Prompt "WARNING: computer number $selected already exists. Overwriting it will replace the existing row. Continue?" -DefaultYes $false
            if ($overwrite) {
                return $selected
            }

            Write-Host "Choose a different computer number." -ForegroundColor Yellow
            continue
        }

        return $selected
    }
}

function Get-DriveTypeName {
    param([uint32]$DriveTypeCode)

    switch ($DriveTypeCode) {
        0 { "Unknown" }
        1 { "NoRootDirectory" }
        2 { "Removable" }
        3 { "Fixed" }
        4 { "Network" }
        5 { "CDROM" }
        6 { "RAMDisk" }
        default { "Unknown" }
    }
}

function Test-PendingReboot {
    $paths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired",
        "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager"
    )

    if (Test-Path -LiteralPath $paths[0]) { return 1 }
    if (Test-Path -LiteralPath $paths[1]) { return 1 }

    try {
        $sessionManager = Get-ItemProperty -LiteralPath $paths[2] -Name "PendingFileRenameOperations" -ErrorAction Stop
        if ($null -ne $sessionManager.PendingFileRenameOperations) {
            return 1
        }
    }
    catch {
    }

    return 0
}

function Get-WindowsUpdatePendingCount {
    try {
        $session = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $result = $searcher.Search("IsInstalled=0 and Type='Software'")
        return [int]$result.Updates.Count
    }
    catch {
        return $null
    }
}

$scriptDirectory = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) { (Get-Location).Path } else { $PSScriptRoot }
$csvPath = Resolve-TargetCsvPath -DirectoryPath $scriptDirectory
$computerNumber = Get-ComputerNumber -CsvPath $csvPath

$collectionStatus = "OK"
$notes = New-Object System.Collections.Generic.List[string]

$timestamp = Get-Date
$computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem
$bios = Get-CimInstance -ClassName Win32_BIOS
$os = Get-CimInstance -ClassName Win32_OperatingSystem
$cpu = Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1
$gpu = Get-CimInstance -ClassName Win32_VideoController | Select-Object -First 1

$systemDriveLetter = $env:SystemDrive.TrimEnd("\")
$systemDrive = Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $systemDriveLetter)

$uptimeHours = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalHours, 2)
$ramTotalGb = [math]::Round($os.TotalVisibleMemorySize / 1MB, 2)
$ramFreeGb = [math]::Round($os.FreePhysicalMemory / 1MB, 2)

$driveTotalGb = $null
$driveFreeGb = $null
$driveFreePercent = $null
$driveType = $null
if ($null -ne $systemDrive) {
    $driveTotalGb = [math]::Round($systemDrive.Size / 1GB, 2)
    $driveFreeGb = [math]::Round($systemDrive.FreeSpace / 1GB, 2)
    if ($systemDrive.Size -gt 0) {
        $driveFreePercent = [math]::Round(($systemDrive.FreeSpace / $systemDrive.Size) * 100, 2)
    }
    $driveType = Get-DriveTypeName -DriveTypeCode $systemDrive.DriveType
}
else {
    $collectionStatus = "PARTIAL"
    $notes.Add("System drive information not available.")
}

$diskHealthCode = 0
$diskHealthDetail = "Unknown"
try {
    if (Get-Command -Name Get-PhysicalDisk -ErrorAction SilentlyContinue) {
        $physicalDisks = @(Get-PhysicalDisk -ErrorAction Stop)
        if ($physicalDisks.Count -gt 0) {
            $healthStates = $physicalDisks | Select-Object -ExpandProperty HealthStatus -Unique
            $diskHealthDetail = ($healthStates -join ";")

            if ($healthStates -contains "Unhealthy") {
                $diskHealthCode = 3
            }
            elseif ($healthStates -contains "Warning") {
                $diskHealthCode = 2
            }
            elseif ($healthStates -contains "Healthy") {
                $diskHealthCode = 1
            }
        }
    }
    else {
        $notes.Add("Get-PhysicalDisk not available on this system.")
        $collectionStatus = "PARTIAL"
    }
}
catch {
    $notes.Add("Disk health query failed: $($_.Exception.Message)")
    $collectionStatus = "PARTIAL"
}

$networkAdapterUpCount = $null
$networkAdapterTotalCount = $null
$networkAdapterName = $null
$networkAdapterType = $null
$networkIpAddress = $null
$networkSubnetMask = $null
$networkDefaultGateway = $null
$networkDhcpEnabled = $null
$networkDnsServers = $null
$networkConnected = 0
$canPingGateway = 0
$canResolveDns = 0
$wifiSignalPercent = $null

try {
    $activeAdapter = $null
    if (Get-Command -Name Get-NetAdapter -ErrorAction SilentlyContinue) {
        $adapters = @(Get-NetAdapter -ErrorAction Stop | Where-Object { $_.HardwareInterface -eq $true })
        $networkAdapterTotalCount = $adapters.Count
        $networkAdapterUpCount = @($adapters | Where-Object { $_.Status -eq "Up" }).Count
        $activeAdapter = @($adapters | Where-Object { $_.Status -eq "Up" } | Sort-Object Status, InterfaceDescription | Select-Object -First 1)[0]
    }
    else {
        $legacyAdapters = @(Get-CimInstance Win32_NetworkAdapter | Where-Object { $_.PhysicalAdapter -eq $true })
        $networkAdapterTotalCount = $legacyAdapters.Count
        $networkAdapterUpCount = @($legacyAdapters | Where-Object { $_.NetEnabled -eq $true }).Count
        $activeAdapter = @($legacyAdapters | Where-Object { $_.NetEnabled -eq $true } | Sort-Object Index | Select-Object -First 1)[0]
    }

    if ($null -ne $activeAdapter) {
        $networkAdapterName = $activeAdapter.Name
        $networkAdapterType = if ($activeAdapter.InterfaceDescription -match "Wireless|802.11|Wi-Fi") { "WiFi" } elseif ($activeAdapter.InterfaceDescription -match "Ethernet|LAN") { "Ethernet" } else { "Unknown" }
        $networkConnected = if ($activeAdapter.Status -eq "Up" -or $activeAdapter.NetEnabled -eq $true) { 1 } else { 0 }

        $config = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter ("InterfaceIndex = '{0}'" -f $activeAdapter.InterfaceIndex) -ErrorAction SilentlyContinue
        if ($null -ne $config) {
            $networkIpAddress = if ($config.IPAddress) { ($config.IPAddress | Select-Object -First 1) } else { $null }
            $networkSubnetMask = if ($config.IPSubnet) { ($config.IPSubnet | Select-Object -First 1) } else { $null }
            $networkDefaultGateway = if ($config.DefaultIPGateway) { ($config.DefaultIPGateway | Select-Object -First 1) } else { $null }
            $networkDhcpEnabled = if ($null -ne $config.DHCPEnabled) { [int]$config.DHCPEnabled } else { $null }
            $networkDnsServers = if ($config.DNSServerSearchOrder) { ($config.DNSServerSearchOrder -join ';') } else { $null }
        }

        if ($networkConnected -eq 1 -and $networkDefaultGateway) {
            $canPingGateway = if (Test-Connection -ComputerName $networkDefaultGateway -Count 1 -Quiet -ErrorAction SilentlyContinue) { 1 } else { 0 }
        }

        if ($networkConnected -eq 1) {
            try {
                $null = Resolve-DnsName -Name "google.com" -QuickTimeout -ErrorAction Stop
                $canResolveDns = 1
            }
            catch {
                $canResolveDns = 0
            }
        }

        if ($networkAdapterType -eq "WiFi") {
            try {
                $wifiInfo = Get-CimInstance -Namespace root\wmi -ClassName MSNdis_80211_ReceivedSignalStrength -ErrorAction Stop
                if ($null -ne $wifiInfo) {
                    $wifiSignalPercent = [math]::Clamp($wifiInfo.Ndis80211ReceivedSignalStrength, 0, 100)
                }
            }
            catch {
                $wifiSignalPercent = $null
            }
        }
    }
}
catch {
    $notes.Add("Network adapter query failed: $($_.Exception.Message)")
    $collectionStatus = "PARTIAL"
}

$keyboardPresent = 0
$mousePresent = 0
$monitorCount = 0
$audioOutputPresent = 0
$audioInputPresent = 0

try {
    $keyboardPresent = if (@(Get-CimInstance Win32_Keyboard).Count -gt 0) { 1 } else { 0 }
}
catch {
    $notes.Add("Keyboard query failed.")
    $collectionStatus = "PARTIAL"
}

try {
    $mousePresent = if (@(Get-CimInstance Win32_PointingDevice).Count -gt 0) { 1 } else { 0 }
}
catch {
    $notes.Add("Mouse query failed.")
    $collectionStatus = "PARTIAL"
}

try {
    $monitorCount = @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -ErrorAction Stop).Count
}
catch {
    try {
        $monitorCount = @(Get-CimInstance Win32_DesktopMonitor -ErrorAction Stop).Count
    }
    catch {
        $notes.Add("Monitor query failed.")
        $collectionStatus = "PARTIAL"
    }
}

try {
    $soundDevices = @(Get-CimInstance Win32_SoundDevice -ErrorAction Stop)
    $hasSound = ($soundDevices.Count -gt 0)
    $audioOutputPresent = if ($hasSound) { 1 } else { 0 }
    $audioInputPresent = if ($hasSound) { 1 } else { 0 }
}
catch {
    $notes.Add("Sound device query failed.")
    $collectionStatus = "PARTIAL"
}

$unknownDeviceCount = $null
try {
    $unknownDeviceCount = @(Get-CimInstance Win32_PnPEntity -ErrorAction Stop | Where-Object { $_.ConfigManagerErrorCode -ne 0 }).Count
}
catch {
    $notes.Add("Unknown device query failed.")
    $collectionStatus = "PARTIAL"
}

$eventError24h = $null
$eventWarning24h = $null
try {
    $startTime = (Get-Date).AddHours(-24)
    $eventError24h = @(Get-WinEvent -FilterHashtable @{ LogName = "System"; StartTime = $startTime; Level = 2 } -ErrorAction Stop).Count
    $eventWarning24h = @(Get-WinEvent -FilterHashtable @{ LogName = "System"; StartTime = $startTime; Level = 3 } -ErrorAction Stop).Count
}
catch {
    $notes.Add("System event query failed.")
    $collectionStatus = "PARTIAL"
}

$pendingReboot = Test-PendingReboot
$windowsUpdatePendingCount = Get-WindowsUpdatePendingCount
if ($null -eq $windowsUpdatePendingCount) {
    $notes.Add("Windows Update pending count not available.")
    $collectionStatus = "PARTIAL"
}

$row = [ordered]@{
    computer_number               = $computerNumber
    scan_timestamp                = $timestamp.ToString("s")
    collection_status             = $collectionStatus
    hostname                      = $env:COMPUTERNAME
    manufacturer                  = $computerSystem.Manufacturer
    model                         = $computerSystem.Model
    serial_number                 = $bios.SerialNumber
    os_caption                    = $os.Caption
    os_version                    = $os.Version
    os_build                      = $os.BuildNumber
    os_architecture               = $os.OSArchitecture
    last_boot_time                = ([datetime]$os.LastBootUpTime).ToString("s")
    uptime_hours                  = $uptimeHours
    cpu_model                     = $cpu.Name
    cpu_logical_cores             = $cpu.NumberOfLogicalProcessors
    cpu_max_clock_mhz             = $cpu.MaxClockSpeed
    ram_total_gb                  = $ramTotalGb
    ram_free_gb                   = $ramFreeGb
    system_drive_letter           = $systemDriveLetter
    system_drive_type             = $driveType
    system_drive_total_gb         = $driveTotalGb
    system_drive_free_gb          = $driveFreeGb
    system_drive_free_percent     = $driveFreePercent
    disk_health_code              = $diskHealthCode
    disk_health_detail            = $diskHealthDetail
    gpu_name                      = $gpu.Name
    network_adapter_name          = $networkAdapterName
    network_adapter_type          = $networkAdapterType
    network_adapter_up_count      = $networkAdapterUpCount
    network_adapter_total_count   = $networkAdapterTotalCount
    network_connected            = $networkConnected
    network_ip_address           = $networkIpAddress
    network_subnet_mask          = $networkSubnetMask
    network_default_gateway      = $networkDefaultGateway
    network_dhcp_enabled         = $networkDhcpEnabled
    network_dns_servers          = $networkDnsServers
    can_ping_gateway             = $canPingGateway
    can_resolve_dns              = $canResolveDns
    wifi_signal_percent          = $wifiSignalPercent
    keyboard_present              = $keyboardPresent
    mouse_present                 = $mousePresent
    monitor_count                 = $monitorCount
    audio_output_present          = $audioOutputPresent
    audio_input_present           = $audioInputPresent
    unknown_device_count          = $unknownDeviceCount
    event_error_24h               = $eventError24h
    event_warning_24h             = $eventWarning24h
    pending_reboot                = $pendingReboot
    windows_update_pending_count  = $windowsUpdatePendingCount
    notes                         = ($notes -join " | ")
}

$rowObject = New-Object PSObject -Property $row
$existingRows = @()
if (Test-Path -LiteralPath $csvPath) {
    try {
        $existingRows = @(Import-Csv -LiteralPath $csvPath -ErrorAction Stop)
    }
    catch {
        Write-Host "Could not read existing CSV. Recreating file from scratch." -ForegroundColor Yellow
        $existingRows = @()
    }
}

$filteredRows = @(
    $existingRows | Where-Object {
        $null -eq $_.computer_number -or $_.computer_number.ToString().Trim() -ne $computerNumber.ToString()
    }
)

$allRows = @($filteredRows)
$allRows += $rowObject
$allRows | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "Scan complete." -ForegroundColor Green
Write-Host "CSV: $csvPath"
Write-Host "Computer number: $computerNumber"
Write-Host "Collection status: $collectionStatus"
