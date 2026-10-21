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

function Get-DefaultGateway {
    $route = Get-CimInstance Win32_IP4RouteTable -ErrorAction SilentlyContinue |
        Where-Object { $_.DestinationPrefix -eq "0.0.0.0/0" } |
        Sort-Object Metric1 |
        Select-Object -First 1

    if ($null -ne $route -and $route.NextHop) {
        return $route.NextHop
    }

    $netRoute = Get-NetRoute -ErrorAction SilentlyContinue |
        Where-Object { $_.DestinationPrefix -eq "0.0.0.0/0" } |
        Sort-Object RouteMetric |
        Select-Object -First 1

    if ($null -ne $netRoute -and $netRoute.NextHop) {
        return $netRoute.NextHop
    }

    return $null
}

function Get-NetworkType {
    $adapter = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq "Up" } | Sort-Object InterfaceDescription | Select-Object -First 1

    if ($null -eq $adapter) {
        $adapter = Get-NetAdapter -ErrorAction SilentlyContinue | Select-Object -First 1
    }

    if ($null -eq $adapter) {
        return "Unknown"
    }

    if ($adapter.InterfaceDescription -match "Wireless|Wi-Fi|802\.11") {
        return "WiFi"
    }

    if ($adapter.InterfaceDescription -match "Ethernet|LAN") {
        return "Ethernet"
    }

    return "Unknown"
}

$scriptDirectory = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) { (Get-Location).Path } else { $PSScriptRoot }
$csvPath = Join-Path -Path $scriptDirectory -ChildPath "network_site_health.csv"

Write-Host "Network site health audit" -ForegroundColor Cyan
Write-Host "CSV file: $csvPath" -ForegroundColor Cyan

$existingRows = @()
if (Test-Path -LiteralPath $csvPath) {
    try {
        $existingRows = @(Import-Csv -LiteralPath $csvPath -ErrorAction Stop)
    }
    catch {
        Write-Host "Existing CSV could not be read. A new file will be created." -ForegroundColor Yellow
        $existingRows = @()
    }
}

while ($true) {
    $siteName = (Read-Host "Enter the site name").Trim()

    if ([string]::IsNullOrWhiteSpace($siteName)) {
        Write-Host "Site name cannot be empty." -ForegroundColor Yellow
        continue
    }

    $duplicate = $existingRows | Where-Object {
        $null -ne $_.site_name -and $_.site_name.ToString().Trim().ToLowerInvariant() -eq $siteName.ToLowerInvariant()
    } | Select-Object -First 1

    if ($null -eq $duplicate) {
        break
    }

    $action = (Read-Host "A row for '$siteName' already exists. Type 'overwrite', 'new', or 'cancel'" ).Trim().ToLowerInvariant()

    switch ($action) {
        "overwrite" {
            $existingRows = @($existingRows | Where-Object {
                $null -eq $_.site_name -or $_.site_name.ToString().Trim().ToLowerInvariant() -ne $siteName.ToLowerInvariant()
            })
            break
        }
        "new" {
            continue
        }
        "cancel" {
            Write-Host "Cancelled." -ForegroundColor Yellow
            exit 0
        }
        default {
            Write-Host "Please type overwrite, new, or cancel." -ForegroundColor Yellow
        }
    }

    break
}

$gateway = Get-DefaultGateway
$gatewayReachable = 0
$dnsReachable = 0
$internetReachable = 0
$internalReachable = $null
$gatewayLatencyMs = $null
$networkType = Get-NetworkType
$internalHost = ""

if ($gateway) {
    $gatewayPing = Test-Connection -ComputerName $gateway -Count 2 -ErrorAction SilentlyContinue
    if ($gatewayPing) {
        $gatewayReachable = 1
        $avgLatency = @($gatewayPing | Measure-Object -Property ResponseTime -Average).Average
        if ($null -ne $avgLatency) {
            $gatewayLatencyMs = [math]::Round($avgLatency, 0)
        }
    }
}

try {
    $dnsCheck = Resolve-DnsName -Name "google.com" -QuickTimeout -ErrorAction Stop
    if ($dnsCheck) {
        $dnsReachable = 1
    }
}
catch {
    $dnsReachable = 0
}

$internetPing = Test-Connection -ComputerName "8.8.8.8" -Count 2 -ErrorAction SilentlyContinue
if ($internetPing) {
    $internetReachable = 1
}

$internalHost = (Read-Host "Enter an internal host or IP to test (optional; press Enter to skip)").Trim()
if (-not [string]::IsNullOrWhiteSpace($internalHost)) {
    $internalPing = Test-Connection -ComputerName $internalHost -Count 2 -ErrorAction SilentlyContinue
    if ($internalPing) {
        $internalReachable = 1
    }
    else {
        $internalReachable = 0
    }
}

if (-not $gateway) {
    $overallStatus = "black"
    $notes = "No default gateway was found on this machine."
}
elseif ($gatewayReachable -eq 0) {
    $overallStatus = "red"
    $notes = "Gateway is not reachable."
}
elseif ($dnsReachable -eq 0 -or $internetReachable -eq 0) {
    $overallStatus = "red"
    $notes = "DNS or internet connectivity is failing."
}
elseif ($null -ne $internalReachable -and $internalReachable -eq 0) {
    $overallStatus = "orange"
    $notes = "The site is reachable, but an internal target is failing."
}
else {
    $overallStatus = "green"
    $notes = "Site connectivity looks healthy."
}

$row = [ordered]@{
    site_name                = $siteName
    scan_timestamp           = (Get-Date).ToString("s")
    gateway_ip               = $gateway
    network_type             = $networkType
    gateway_reachable        = $gatewayReachable
    dns_reachable            = $dnsReachable
    internet_reachable       = $internetReachable
    internal_host            = $internalHost
    internal_host_reachable  = $internalReachable
    gateway_latency_ms       = $gatewayLatencyMs
    overall_status           = $overallStatus
    notes                    = $notes
}

$allRows = @($existingRows)
$allRows += [pscustomobject]$row
$allRows | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "Site saved successfully." -ForegroundColor Green
Write-Host "CSV: $csvPath"
Write-Host "Site: $siteName"
Write-Host "Status: $overallStatus"
