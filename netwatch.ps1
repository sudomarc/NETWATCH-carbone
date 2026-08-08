#Requires -Version 5.1
<#
.SYNOPSIS
    netwatch — Network monitor & control tool (Windows port)
.DESCRIPTION
    Windows/PowerShell port of netwatch.sh. Scan, identify, block, throttle
    devices on your local network. Run as Administrator for write actions
    (block/unblock/throttle/unthrottle/reset).
.NOTES
    Differences vs Linux version (see README "Windows notes"):
      - block  -> Windows Firewall rules (this machine), not iptables FORWARD.
                  No ARP-spoof LAN kick (needs Npcap — not implemented).
      - throttle -> New-NetQosPolicy. Same router/ICS constraint as Linux tc.
#>

# ─── State ─────────────────────────────────────────────────────────────────

$Script:Version      = "1.2"
$Script:UpdateUrl    = "https://raw.githubusercontent.com/sudomarc/NETWATCH-carbone/main/netwatch.ps1"
$Script:ConfigDir    = if ($env:NETWATCH_CONFIG) { $env:NETWATCH_CONFIG } else { Join-Path $HOME ".netwatch" }
$Script:BlockFile    = Join-Path $Script:ConfigDir "blocked_macs.txt"
$Script:BlockedIps   = Join-Path $Script:ConfigDir "blocked_ips.txt"
$Script:ThrottleFile = Join-Path $Script:ConfigDir "throttled_macs.txt"
$Script:ScanLog      = Join-Path $Script:ConfigDir "scan_history.log"
$Script:Subnet       = $null
$Script:Gateway      = $null
$Script:IfaceAlias   = $null
$Script:IfIndex      = $null
$Script:DryRun       = $false
$Script:Persistent   = $false

# ─── Utilities ─────────────────────────────────────────────────────────────

function Info  { param([string]$Msg) Write-Host "[.] $Msg" -ForegroundColor Cyan }
function Ok    { param([string]$Msg) Write-Host "[OK] $Msg" -ForegroundColor Green }
function Warn  { param([string]$Msg) Write-Host "[!] $Msg" -ForegroundColor Yellow }
function Err   { param([string]$Msg) Write-Host "[X] $Msg" -ForegroundColor Red }
function Die   { param([string]$Msg) Err $Msg; exit 1 }

function Log {
    param([string]$Msg)
    New-Item -ItemType Directory -Force -Path $Script:ConfigDir | Out-Null
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -Path $Script:ScanLog -Value "[$stamp] $Msg"
}

function Require-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Die "This command requires Administrator. Re-run PowerShell as Admin."
    }
}

function Check-Deps {
    $missing = @()
    foreach ($cmd in @("Get-NetRoute", "Get-NetNeighbor", "Get-NetAdapter", "Get-NetIPAddress")) {
        if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) { $missing += $cmd }
    }
    if ($missing.Count -gt 0) {
        Die "Missing required cmdlets: $($missing -join ', '). Needs Windows 8 / Server 2012+ (NetTCPIP module)."
    }
    if (-not (Get-Command nmap.exe -ErrorAction SilentlyContinue)) {
        Warn "nmap not found - using native ping sweep (slower, no OS fingerprint). Install: winget install Insecure.Nmap"
    }
}

# ─── Automatic Updates ─────────────────────────────────────────────────────

function Invoke-CheckUpdate {
    param([bool]$Silent = $false)

    New-Item -ItemType Directory -Force -Path $Script:ConfigDir | Out-Null

    $lastCheckFile = Join-Path $Script:ConfigDir ".last_update_check"
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    Set-Content -Path $lastCheckFile -Value $now -ErrorAction SilentlyContinue

    $remoteVersion = $null
    try {
        if ($Silent) {
            $response = Invoke-RestMethod -Uri $Script:UpdateUrl -TimeoutSec 3 -ErrorAction Stop
        } else {
            Info "Checking for updates..."
            $response = Invoke-RestMethod -Uri $Script:UpdateUrl -TimeoutSec 8 -ErrorAction Stop
        }

        if ($response -match '\$Script:Version\s*=\s*"([^"]+)"') {
            $remoteVersion = $Matches[1]
        }
    } catch {
        if (-not $Silent) { Err "Failed to check for updates: $($_.Exception.Message)" }
        return $false
    }

    if (-not $remoteVersion) {
        if (-not $Silent) { Err "Failed to parse remote version information." }
        return $false
    }

    try {
        if ([version]$remoteVersion -gt [version]$Script:Version) {
            if ($Silent) {
                Write-Host ""
                Write-Host "[!] A new version of netwatch is available: v$remoteVersion (current: v$($Script:Version))" -ForegroundColor Yellow
                Write-Host "[!] Run '.\netwatch.ps1 update' or select 'U' in the menu to update." -ForegroundColor Yellow
                Write-Host ""
            } else {
                Ok "A new version of netwatch is available: v$remoteVersion (current: v$($Script:Version))"
            }
            return $true
        } else {
            if (-not $Silent) { Ok "netwatch is up-to-date (v$($Script:Version))." }
            return $false
        }
    } catch {
        if (-not $Silent) { Err "Error comparing version numbers." }
        return $false
    }
}

function Invoke-ApplyUpdate {
    $updateAvailable = Invoke-CheckUpdate -Silent $false
    if (-not $updateAvailable) {
        return
    }

    try {
        $response = Invoke-RestMethod -Uri $Script:UpdateUrl -TimeoutSec 10 -ErrorAction Stop
        if ($response -match '\$Script:Version\s*=\s*"([^"]+)"') {
            $remoteVersion = $Matches[1]
        }
    } catch {
        Die "Failed to fetch update script."
    }

    if (-not $remoteVersion) {
        Die "Failed to parse remote version."
    }

    $scriptPath = $MyInvocation.MyCommand.Path
    if (-not $scriptPath) {
        $scriptPath = Join-Path $pwd "netwatch.ps1"
    }

    try {
        $testFileStream = [System.IO.File]::OpenWrite($scriptPath)
        $testFileStream.Close()
    } catch {
        Err "No write permissions to update '$scriptPath'."
        Err "Please run PowerShell as Administrator to update."
        return
    }

    Info "Downloading netwatch v$remoteVersion..."
    $tmpFile = [System.IO.Path]::GetTempFileName()
    try {
        Invoke-WebRequest -Uri $Script:UpdateUrl -OutFile $tmpFile -TimeoutSec 15 -ErrorAction Stop
    } catch {
        if (Test-Path $tmpFile) { Remove-Item $tmpFile -Force }
        Die "Failed to download update script."
    }

    $content = Get-Content $tmpFile -Raw
    if ($content -notmatch '\$Script:Version\s*=') {
        Remove-Item $tmpFile -Force
        Die "Downloaded file is invalid (missing version definition)."
    }

    $backupPath = $scriptPath + ".bak"
    Info "Backing up current script to $backupPath..."
    try {
        Copy-Item -Path $scriptPath -Destination $backupPath -Force -ErrorAction Stop
    } catch {
        Remove-Item $tmpFile -Force
        Die "Failed to create backup: $($_.Exception.Message)"
    }

    Info "Applying update..."
    try {
        Move-Item -Path $tmpFile -Destination $scriptPath -Force -ErrorAction Stop
        Ok "Successfully updated netwatch to v$remoteVersion!"
        if (Test-Path $backupPath) { Remove-Item $backupPath -Force }
    } catch {
        if (Test-Path $backupPath) {
            Copy-Item -Path $backupPath -Destination $scriptPath -Force
            Remove-Item $backupPath -Force
        }
        Die "Failed to apply update. Restored backup."
    }

    Info "Restarting netwatch..."
    if ($host.Name -eq 'ConsoleHost') {
        $engine = if ($PSVersionTable.PSEdition -eq 'Core') { "pwsh" } else { "powershell" }
        Start-Process $engine -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
        exit
    } else {
        & $scriptPath
        exit
    }
}

function Invoke-AutoCheckUpdate {
    $lastCheckFile = Join-Path $Script:ConfigDir ".last_update_check"
    $lastCheck = 0
    if (Test-Path $lastCheckFile) {
        $content = Get-Content $lastCheckFile -Raw -ErrorAction SilentlyContinue
        if ($content -match '^\d+$') {
            $lastCheck = [int64]$content
        }
    }

    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if ($now - $lastCheck -gt 86400) {
        Set-Content -Path $lastCheckFile -Value $now -ErrorAction SilentlyContinue
        Invoke-CheckUpdate -Silent $true
    }
}

function Test-ValidMac   { param([string]$Mac)   return $Mac -match '^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$' }
function Test-ValidSpeed { param([string]$Speed) return $Speed -match '^[0-9]+(kbit|mbit|gbit|kbps|mbps)$' }
function Normalize-Mac   { param([string]$Mac)   return $Mac.ToUpper() }

function Get-VendorFromMac {
    param([string]$Mac)
    if (-not $Mac -or $Mac.Length -lt 8) { return "Unknown" }
    $oui = $Mac.ToUpper().Substring(0, 8)
    switch -Regex ($oui) {
        '^(00:1A:2B|00:50:56|00:0C:29|00:05:69)$'             { return "VMware" }
        '^00:1C:42$'                                          { return "Parallels" }
        '^(00:03:93|A4:4C:C8|00:26:9E|00:0D:93|3C:07:54|A8:86:DD)$' { return "Apple" }
        '^(00:1E:58|00:1F:3A|00:21:5C|14:18:77)$'             { return "Dell" }
        '^(00:1A:A0|00:1E:4C|00:24:E8|30:8D:99)$'             { return "HP" }
        '^(00:25:90|00:1B:21|00:1D:09|8C:EC:4B)$'             { return "Intel" }
        '^(00:16:E9|00:18:7D|00:1F:33|F8:7B:20)$'             { return "Cisco" }
        '^(20:CF:30|2C:B0:5D|64:B4:73)$'                      { return "Xiaomi" }
        '^(00:1F:82|D4:61:9D|00:E0:FC)$'                      { return "Huawei" }
        '^(A4:77:33|AC:CF:85|40:B0:34|B4:79:A7)$'             { return "Samsung" }
        '^(AC:22:0B|B8:5A:73|F0:F6:1C|04:D9:F5)$'             { return "Asus" }
        '^(18:B4:30|FC:D7:33|48:45:20|54:AF:97)$'             { return "TP-Link" }
        '^(00:26:B6|00:27:0E|9C:5C:8E|20:4E:7F)$'             { return "Netgear" }
        '^(B8:27:EB|DC:A6:32|E4:5F:01)$'                      { return "Raspberry Pi" }
        '^00:15:5D$'                                          { return "Hyper-V" }
        default                                               { return "Unknown" }
    }
}

# ─── Network detection ─────────────────────────────────────────────────────

function Detect-Network {
    $route = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
        Sort-Object -Property RouteMetric | Select-Object -First 1
    if (-not $route) { Die "No default gateway found." }
    $Script:Gateway = $route.NextHop
    $Script:IfIndex = $route.InterfaceIndex

    $adapter = Get-NetAdapter -InterfaceIndex $Script:IfIndex -ErrorAction SilentlyContinue
    if (-not $adapter) { Die "No default interface found." }
    $Script:IfaceAlias = $adapter.Name

    $ipcfg = Get-NetIPAddress -InterfaceIndex $Script:IfIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike "169.254.*" } | Select-Object -First 1
    if (-not $ipcfg) { Die "No local IP on interface $($Script:IfaceAlias)." }

    # Compute subnet address dynamically based on IP and PrefixLength
    $ipBytes = [System.Net.IPAddress]::Parse($ipcfg.IPAddress).GetAddressBytes()
    $maskBytes = New-Object byte[] 4
    $pl = $ipcfg.PrefixLength
    for ($i = 0; $i -lt 4; $i++) {
        if ($pl -ge 8) {
            $maskBytes[$i] = 255
            $pl -= 8
        } elseif ($pl -gt 0) {
            $maskBytes[$i] = [byte](256 - [Math]::Pow(2, 8 - $pl))
            $pl = 0
        } else {
            $maskBytes[$i] = 0
        }
    }
    $netBytes = New-Object byte[] 4
    for ($i = 0; $i -lt 4; $i++) {
        $netBytes[$i] = $ipBytes[$i] -band $maskBytes[$i]
    }
    $subnetIp = $netBytes -join "."
    $Script:Subnet = "$subnetIp/$($ipcfg.PrefixLength)"

    Info "Interface: $($Script:IfaceAlias) | Subnet: $($Script:Subnet) | Gateway: $($Script:Gateway)"
}

# ─── Resolve target (ip|mac) -> {IP, MAC} ────────────────────────────────────

function Resolve-IpMac {
    param([string]$Target)
    if ($null -eq $Script:IfIndex) { Detect-Network }
    $ip = $null
    $mac = $null
    if (Test-ValidMac $Target) {
        $mac = Normalize-Mac $Target
        $neigh = Get-NetNeighbor -InterfaceIndex $Script:IfIndex -ErrorAction SilentlyContinue |
            Where-Object { ($_.LinkLayerAddress -replace '-', ':').ToUpper() -eq $mac } |
            Select-Object -First 1
        if ($neigh) { $ip = $neigh.IPAddress }
    } else {
        $ip = $Target
        $neigh = Get-NetNeighbor -IPAddress $ip -InterfaceIndex $Script:IfIndex -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($neigh -and $neigh.LinkLayerAddress -and $neigh.LinkLayerAddress -ne "00-00-00-00-00-00") {
            $mac = Normalize-Mac ($neigh.LinkLayerAddress -replace '-', ':')
        }
        if (-not $mac) {
            # Try to ping target to populate ARP cache/neighbor table
            try {
                $ping = New-Object System.Net.NetworkInformation.Ping
                $ping.Send($ip, 200) | Out-Null
            } catch {}
            $neigh = Get-NetNeighbor -IPAddress $ip -InterfaceIndex $Script:IfIndex -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($neigh -and $neigh.LinkLayerAddress -and $neigh.LinkLayerAddress -ne "00-00-00-00-00-00") {
                $mac = Normalize-Mac ($neigh.LinkLayerAddress -replace '-', ':')
            }
        }
    }
    return [PSCustomObject]@{ IP = $ip; MAC = $mac }
}

# ─── Scan ──────────────────────────────────────────────────────────────────

function Show-DeviceTable {
    param([array]$Devices)
    if ($Devices.Count -eq 0) { Warn "No devices found. Run a scan first."; return }
    Write-Host ""
    $fmt = "{0,-4} {1,-16} {2,-18} {3,-20} {4,-12} {5,-10} {6,-10}"
    Write-Host ($fmt -f "#", "IP", "MAC", "Hostname", "Vendor", "Blocked", "Throttled")
    Write-Host ("-" * 92)
    $i = 1
    foreach ($d in $Devices) {
        $color = "Gray"
        if ($d.Blocked -eq "BLOCKED") { $color = "Red" }
        elseif ($d.Throttled -ne "-") { $color = "Yellow" }
        $h = $d.Hostname; if (-not $h) { $h = "-" } elseif ($h.Length -gt 20) { $h = $h.Substring(0, 20) }
        $v = $d.Vendor;   if (-not $v) { $v = "-" } elseif ($v.Length -gt 12) { $v = $v.Substring(0, 12) }
        Write-Host ($fmt -f $i, $d.IP, $d.MAC, $h, $v, $d.Blocked, $d.Throttled) -ForegroundColor $color
        $i++
    }
    Write-Host ""
}

function Invoke-Scan {
    param([string]$Format = "table")
    Info "Scanning $($Script:Subnet) ..."
    New-Item -ItemType Directory -Force -Path $Script:ConfigDir | Out-Null

    $netPart = ($Script:Subnet -split '/')[0]
    $base = $netPart.Substring(0, $netPart.LastIndexOf('.'))

    $hasNmap = [bool](Get-Command nmap.exe -ErrorAction SilentlyContinue)
    $upHosts = New-Object System.Collections.Generic.List[string]

    if ($hasNmap) {
        $nmapOut = & nmap -sn -PR $Script:Subnet --max-retries 2 --host-timeout 8s -oG - 2>$null
        foreach ($line in $nmapOut) {
            if ($line -match '^Host:\s+(\S+).*Status:\s+Up') { $upHosts.Add($Matches[1]) }
        }
    } else {
        $pings = @{}
        for ($n = 1; $n -le 254; $n++) {
            $target = "$base.$n"
            $pings[$target] = (New-Object System.Net.NetworkInformation.Ping).SendPingAsync($target, 400)
        }
        foreach ($kv in $pings.GetEnumerator()) {
            try {
                $reply = $kv.Value.GetAwaiter().GetResult()
                if ($reply.Status -eq 'Success') { $upHosts.Add($kv.Key) }
            } catch {}
        }
    }

    $results = @()
    foreach ($ip in $upHosts) {
        if ($ip -eq $Script:Gateway) { continue }

        $neigh = Get-NetNeighbor -IPAddress $ip -InterfaceIndex $Script:IfIndex -ErrorAction SilentlyContinue | Select-Object -First 1
        $mac = "--"
        if ($neigh -and $neigh.LinkLayerAddress -and $neigh.LinkLayerAddress -ne "00-00-00-00-00-00") {
            $mac = Normalize-Mac ($neigh.LinkLayerAddress -replace '-', ':')
        }

        $hostname = "-"
        try {
            $he = [System.Net.Dns]::GetHostEntry($ip)
            if ($he.HostName) { $hostname = $he.HostName }
        } catch {}

        $vendor = "-"
        if ($mac -ne "--") { $vendor = Get-VendorFromMac $mac }

        $blocked = "-"
        if ($mac -ne "--" -and (Test-Path $Script:BlockFile)) {
            $pat = "^" + [regex]::Escape($mac) + "$"
            if (Select-String -Path $Script:BlockFile -Pattern $pat -Quiet -ErrorAction SilentlyContinue) { $blocked = "BLOCKED" }
        }

        $throttled = "-"
        if ($mac -ne "--" -and (Test-Path $Script:ThrottleFile)) {
            $pat = "^" + [regex]::Escape($mac) + "\|"
            $m = Select-String -Path $Script:ThrottleFile -Pattern $pat -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($m) { $throttled = ($m.Line -split '\|')[1] }
        }

        $results += [PSCustomObject]@{ IP = $ip; MAC = $mac; Hostname = $hostname; Vendor = $vendor; Blocked = $blocked; Throttled = $throttled }
    }

    Log "scan: $($results.Count) devices on $($Script:Subnet)"

    switch ($Format) {
        "raw_objects" { return $results }
        "json" { Write-Output ($results | ConvertTo-Json) }
        "csv"  { Write-Output ($results | ConvertTo-Csv -NoTypeInformation) }
        "raw"  { $results | ForEach-Object { Write-Output "$($_.IP)|$($_.MAC)|$($_.Hostname)|$($_.Vendor)|$($_.Blocked)|$($_.Throttled)" } }
        default {
            Show-DeviceTable $results
            Ok "$($results.Count) device(s) found."
        }
    }
}

# ─── Monitor ───────────────────────────────────────────────────────────────

function Invoke-Monitor {
    param([int]$Interval = 30)
    Info "Monitor mode: scanning every ${Interval}s. Press Ctrl+C to stop."
    while ($true) {
        Clear-Host
        Write-Host "================================" -ForegroundColor Cyan
        Write-Host ("  NETWATCH - {0}" -f (Get-Date -Format 'HH:mm:ss')) -ForegroundColor Cyan
        Write-Host "================================" -ForegroundColor Cyan
        Invoke-Scan -Format table
        Start-Sleep -Seconds $Interval
    }
}

# ─── Block / Unblock ───────────────────────────────────────────────────────

function Invoke-Block {
    param([string]$Target)
    Require-Admin
    if (-not $Target) { Die "Usage: netwatch.ps1 block <ip|mac>" }

    $res = Resolve-IpMac $Target
    $ip = $res.IP
    $mac = $res.MAC
    if (-not $ip) { Die "Cannot resolve IP for $Target. Run scan first." }

    New-Item -ItemType Directory -Force -Path $Script:ConfigDir | Out-Null

    $forwarding = $false
    $ipIf = Get-NetIPInterface -InterfaceIndex $Script:IfIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
    if ($ipIf -and $ipIf.Forwarding -eq "Enabled") { $forwarding = $true }

    if ($forwarding) {
        Info "Router/ICS mode - blocking forwarded traffic via Windows Firewall"
    } else {
        Info "Client mode - blocking via Windows Firewall (this machine only)"
        Warn "LAN-wide kick (ARP spoof) needs Npcap + a dedicated tool - not implemented natively on Windows."
    }

    if ($Script:DryRun) {
        Warn "[DRY-RUN] Firewall block for $ip / $mac"
    } else {
        New-NetFirewallRule -DisplayName "netwatch-block-out-$ip" -Direction Outbound -RemoteAddress $ip -Action Block -ErrorAction SilentlyContinue | Out-Null
        New-NetFirewallRule -DisplayName "netwatch-block-in-$ip"  -Direction Inbound  -RemoteAddress $ip -Action Block -ErrorAction SilentlyContinue | Out-Null
    }

    if ($mac) {
        $existing = @()
        if (Test-Path $Script:BlockFile) { $existing = Get-Content $Script:BlockFile }
        if ($existing -notcontains $mac) { Add-Content -Path $Script:BlockFile -Value $mac }
    }
    if ($ip) {
        $existingIps = @()
        if (Test-Path $Script:BlockedIps) { $existingIps = Get-Content $Script:BlockedIps }
        if ($existingIps -notcontains $ip) { Add-Content -Path $Script:BlockedIps -Value $ip }
    }

    $macSuffix = ""
    if ($mac) { $macSuffix = " ($mac)" }
    Log "block: $ip ($mac)"
    Ok "Blocked: $ip$macSuffix"
}

function Invoke-Unblock {
    param([string]$Target)
    Require-Admin
    if (-not $Target) { Die "Usage: netwatch.ps1 unblock <ip|mac>" }

    $res = Resolve-IpMac $Target
    $ip = $res.IP
    $mac = $res.MAC

    if ($Script:DryRun) {
        Warn "[DRY-RUN] Would remove firewall rules for $ip"
    } else {
        Get-NetFirewallRule -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like "netwatch-block-*-$ip" } |
            Remove-NetFirewallRule -ErrorAction SilentlyContinue
    }

    if ($mac -and (Test-Path $Script:BlockFile)) {
        (Get-Content $Script:BlockFile) | Where-Object { $_ -ne $mac } | Set-Content $Script:BlockFile
    }
    if ($ip -and (Test-Path $Script:BlockedIps)) {
        (Get-Content $Script:BlockedIps) | Where-Object { $_ -ne $ip } | Set-Content $Script:BlockedIps
    }

    Log "unblock: $ip ($mac)"
    Ok "Unblocked: $ip"
}

# ─── Throttle / Unthrottle ─────────────────────────────────────────────────

function Convert-SpeedToBps {
    param([string]$Speed)
    if ($Speed -match '^([0-9]+)(kbit|mbit|gbit|kbps|mbps)$') {
        $num = [double]$Matches[1]
        switch ($Matches[2]) {
            "kbit" { return [int64]($num * 1000) }
            "mbit" { return [int64]($num * 1000000) }
            "gbit" { return [int64]($num * 1000000000) }
            "kbps" { return [int64]($num * 1000 * 8) }
            "mbps" { return [int64]($num * 1000000 * 8) }
        }
    }
    return $null
}

function Invoke-Throttle {
    param([string]$MacTarget, [string]$Speed)
    Require-Admin
    $mac = Normalize-Mac $MacTarget
    if (-not (Test-ValidMac $mac))     { Die "Invalid MAC: '$MacTarget'" }
    if (-not (Test-ValidSpeed $Speed)) { Die "Invalid speed '$Speed'. Examples: 512kbit, 2mbit" }

    $res = Resolve-IpMac $mac
    $ip = $res.IP
    if (-not $ip) { Die "Cannot resolve IP for $mac. Run scan first." }

    $bps = Convert-SpeedToBps $Speed
    $policyName = "netwatch-throttle-$mac"
    Info "Throttling $mac ($ip) -> $Speed (policy: $policyName) ..."

    if ($Script:DryRun) {
        Warn "[DRY-RUN] Would set QoS policy limiting $ip to $Speed"
    } else {
        Get-NetQosPolicy -Name $policyName -ErrorAction SilentlyContinue | Remove-NetQosPolicy -Confirm:$false -ErrorAction SilentlyContinue
        try {
            New-NetQosPolicy -Name $policyName -IPDstPrefixMatchCondition "$ip/32" -ThrottleRateActionBitsPerSecond $bps -ErrorAction Stop | Out-Null
        } catch {
            Warn "New-NetQosPolicy failed: $($_.Exception.Message)"
            Warn "QoS Packet Scheduler may need enabling on the adapter, or this requires router/ICS mode (same constraint as 'tc' on Linux)."
        }
    }

    New-Item -ItemType Directory -Force -Path $Script:ConfigDir | Out-Null
    if (Test-Path $Script:ThrottleFile) {
        $pat = "^" + [regex]::Escape($mac) + "\|"
        (Get-Content $Script:ThrottleFile) | Where-Object { $_ -notmatch $pat } | Set-Content $Script:ThrottleFile
    }
    Add-Content -Path $Script:ThrottleFile -Value "$mac|$Speed"

    Log "throttle: $mac -> $Speed"
    Ok "Throttled $mac to $Speed"
}

function Invoke-Unthrottle {
    param([string]$MacTarget)
    Require-Admin
    $mac = Normalize-Mac $MacTarget
    if (-not (Test-ValidMac $mac)) { Die "Invalid MAC: '$MacTarget'" }

    if ($Script:DryRun) {
        Warn "[DRY-RUN] Would remove throttle policy for $mac"
    } else {
        Get-NetQosPolicy -Name "netwatch-throttle-$mac" -ErrorAction SilentlyContinue | Remove-NetQosPolicy -Confirm:$false -ErrorAction SilentlyContinue
    }

    if (Test-Path $Script:ThrottleFile) {
        $pat = "^" + [regex]::Escape($mac) + "\|"
        (Get-Content $Script:ThrottleFile) | Where-Object { $_ -notmatch $pat } | Set-Content $Script:ThrottleFile
    }

    Log "unthrottle: $mac"
    Ok "Unthrottled $mac"
}

# ─── List ──────────────────────────────────────────────────────────────────

function Show-List {
    Write-Host ""
    Write-Host "Blocked MACs:" -ForegroundColor Red
    $shown = $false
    if (Test-Path $Script:BlockFile) {
        $lines = Get-Content $Script:BlockFile | Where-Object { $_ }
        $i = 1
        foreach ($l in $lines) { Write-Host "  $i  $l"; $i++; $shown = $true }
    }
    if (-not $shown) { Write-Host "  (none)" }

    Write-Host ""
    Write-Host "Throttled MACs:" -ForegroundColor Yellow
    $shown = $false
    if (Test-Path $Script:ThrottleFile) {
        $lines = Get-Content $Script:ThrottleFile | Where-Object { $_ }
        if ($lines.Count -gt 0) {
            Write-Host ("  {0,-3} {1,-20} {2,-10}" -f "#", "MAC", "Speed")
            $i = 1
            foreach ($l in $lines) {
                $parts = $l -split '\|'
                Write-Host ("  {0,-3} {1,-20} {2,-10}" -f $i, $parts[0], $parts[1])
                $i++
                $shown = $true
            }
        }
    }
    if (-not $shown) { Write-Host "  (none)" }
    Write-Host ""
}

# ─── Export ────────────────────────────────────────────────────────────────

function Invoke-Export {
    param([string]$Fmt = "csv")
    New-Item -ItemType Directory -Force -Path $Script:ConfigDir | Out-Null
    Detect-Network
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $outFile = Join-Path $Script:ConfigDir "export_$stamp.$Fmt"
    Info "Exporting scan as $Fmt -> $outFile"
    $results = Invoke-Scan -Format "raw_objects"
    if ($Fmt -eq "json") {
        $results | ConvertTo-Json | Out-File -Encoding utf8 $outFile
    } else {
        $results | ConvertTo-Csv -NoTypeInformation | Out-File -Encoding utf8 $outFile
    }
    Ok "Saved to $outFile"
}

# ─── Identify ──────────────────────────────────────────────────────────────

function Invoke-Identify {
    param([string]$Target)
    if (-not $Target) { Die "Usage: netwatch.ps1 identify <ip|mac>" }

    $res = Resolve-IpMac $Target
    $ip = $res.IP
    $mac = $res.MAC
    if (-not $ip) { Die "Cannot find IP for $Target in ARP cache. Run 'scan' first." }

    Write-Host ""
    Write-Host ("=" * 50) -ForegroundColor Cyan
    Write-Host "  Device Profile: $ip" -ForegroundColor White
    Write-Host ("=" * 50) -ForegroundColor Cyan

    Write-Host "`n[1/5] Basic Identity" -ForegroundColor White
    Write-Host "  IP Address : $ip"
    $macDisplay = "--"; if ($mac) { $macDisplay = $mac }
    Write-Host "  MAC Address: $macDisplay"

    $rdns = "(none)"
    try {
        $he = [System.Net.Dns]::GetHostEntry($ip)
        if ($he.HostName) { $rdns = $he.HostName }
    } catch {}
    Write-Host "  rDNS       : $rdns"

    Write-Host "`n[2/5] Hardware Vendor" -ForegroundColor White
    $vendor = ""
    if ($mac -and $mac.Length -ge 8) {
        $oui = $mac.Substring(0, 8)
        try {
            $vendor = Invoke-RestMethod -Uri "https://api.macvendors.com/$oui" -TimeoutSec 3 -ErrorAction Stop
        } catch { $vendor = "" }
        if (-not $vendor) { $vendor = Get-VendorFromMac $mac }
    }
    $vendorDisplay = "(unknown)"; if ($vendor) { $vendorDisplay = $vendor }
    Write-Host "  OUI Vendor : $vendorDisplay"

    Write-Host "`n[3/5] NetBIOS / SMB Name" -ForegroundColor White
    $nbt = "(none)"
    try {
        $nbtOut = & nbtstat -A $ip 2>$null
        $line = $nbtOut | Where-Object { $_ -match '<00>\s+UNIQUE' } | Select-Object -First 1
        if ($line) { $nbt = ($line.Trim() -split '\s+')[0] }
    } catch {}
    Write-Host "  NetBIOS    : $nbt"

    Write-Host "`n[4/5] Open Ports & Services" -ForegroundColor White
    $hasNmap = [bool](Get-Command nmap.exe -ErrorAction SilentlyContinue)
    if ($hasNmap) {
        Write-Host "  (nmap version/OS scan, may take ~30s)"
        $nmapOut = & nmap -sV -O --osscan-guess --version-intensity 5 --max-retries 1 --host-timeout 30s -T4 $ip 2>$null
        $ports = $nmapOut | Where-Object { $_ -match '^\d+/tcp' }
        if ($ports) { $ports | ForEach-Object { Write-Host "  $_" } } else { Write-Host "  (no open TCP ports detected)" }

        Write-Host "`n[5/5] OS Fingerprint" -ForegroundColor White
        $osLines = $nmapOut | Where-Object { $_ -match '^(OS:|Running:|OS details:)' } | Select-Object -First 3
        if ($osLines) { $osLines | ForEach-Object { Write-Host "  $_" } } else { Write-Host "  (insufficient data for OS detection)" }
    } else {
        Warn "  nmap not found - falling back to TCP connect scan on common ports."
        $commonPorts = 21, 22, 23, 25, 53, 80, 110, 135, 139, 143, 443, 445, 993, 995, 1723, 3306, 3389, 5900, 8080
        $open = @()
        foreach ($p in $commonPorts) {
            $t = Test-NetConnection -ComputerName $ip -Port $p -WarningAction SilentlyContinue -InformationLevel Quiet -ErrorAction SilentlyContinue
            if ($t) { $open += $p }
        }
        if ($open.Count -gt 0) { $open | ForEach-Object { Write-Host "  $_/tcp open" } } else { Write-Host "  (no open TCP ports detected)" }

        Write-Host "`n[5/5] OS Fingerprint" -ForegroundColor White
        Write-Host "  (requires nmap for OS detection - install: winget install Insecure.Nmap)"
    }

    Write-Host ""
    Write-Host ("=" * 50) -ForegroundColor Cyan
    $tipTarget = $ip; if ($mac) { $tipTarget = $mac }
    Write-Host "  Tip: netwatch.ps1 block $tipTarget to block this device" -ForegroundColor White
    Write-Host ("=" * 50) -ForegroundColor Cyan
    Write-Host ""
    Log "identify: $ip ($mac)"
}

# ─── Reset ─────────────────────────────────────────────────────────────────

function Invoke-Reset {
    Require-Admin
    Warn "This will remove all netwatch firewall rules and QoS policies. Continue? [y/N]"
    $yn = Read-Host
    if (-not $yn -or $yn.ToLower() -ne "y") { Info "Aborted."; return }

    Info "Resetting all rules ..."
    Get-NetFirewallRule -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like "netwatch-block-*" } |
        Remove-NetFirewallRule -ErrorAction SilentlyContinue
    Get-NetQosPolicy -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "netwatch-throttle-*" } |
        Remove-NetQosPolicy -Confirm:$false -ErrorAction SilentlyContinue

    if (Test-Path $Script:BlockFile)    { Clear-Content $Script:BlockFile }
    if (Test-Path $Script:ThrottleFile) { Clear-Content $Script:ThrottleFile }
    if (Test-Path $Script:BlockedIps)   { Clear-Content $Script:BlockedIps }

    Log "reset: all rules cleared"
    Ok "All rules cleared."
}

# ─── Interactive Menu ──────────────────────────────────────────────────────

function Show-Banner {
    param([array]$Devices)
    Clear-Host
    Write-Host @"
  ███╗   ██╗███████╗████████╗██╗    ██╗ █████╗ ████████╗ ██████╗██╗  ██╗
  ████╗  ██║██╔════╝╚══██╔══╝██║    ██║██╔══██╗╚══██╔══╝██╔════╝██║  ██║
  ██╔██╗ ██║█████╗     ██║   ██║ █╗ ██║███████║   ██║   ██║     ███████║
  ██║╚██╗██║██╔══╝     ██║   ██║███╗██║██╔══██║   ██║   ██║     ██╔══██║
  ██║ ╚████║███████╗   ██║   ╚███╔███╔╝██║  ██║   ██║   ╚██████╗██║  ██║
  ╚═╝  ╚═══╝╚══════╝   ╚═╝    ╚══╝╚══╝ ╚═╝  ╚═╝   ╚═╝    ╚═════╝╚═╝  ╚═╝
"@ -ForegroundColor Cyan
    Write-Host "  Interface: $($Script:IfaceAlias)   Subnet: $($Script:Subnet)   Gateway: $($Script:Gateway)"
    Write-Host "  Devices found: $($Devices.Count)   Time: $(Get-Date -Format 'HH:mm:ss')"
    Write-Host ("  " + ("-" * 70))
    Write-Host ""
}

function Select-Device {
    param([array]$Devices, [string]$Prompt = "Select a device")
    Show-DeviceTable $Devices
    if ($Devices.Count -eq 0) { return $null }
    while ($true) {
        $choice = Read-Host "$Prompt [1-$($Devices.Count)] or 0 to cancel"
        if ($choice -eq "0") { return $null }
        if ($choice -match '^[0-9]+$' -and [int]$choice -ge 1 -and [int]$choice -le $Devices.Count) {
            return $Devices[[int]$choice - 1]
        }
        Warn "Invalid choice. Enter a number between 1 and $($Devices.Count)."
    }
}

function Invoke-Menu {
    Check-Deps
    Detect-Network
    Invoke-AutoCheckUpdate
    Info "Running initial scan..."
    $Devices = Invoke-Scan -Format "raw_objects"

    while ($true) {
        Show-Banner $Devices
        Write-Host "  MAIN MENU"
        Write-Host ""
        Write-Host "  [1] Scan network"
        Write-Host "  [2] Show devices"
        Write-Host "  [3] Identify / probe a device"
        Write-Host "  [4] Block a device"
        Write-Host "  [5] Unblock a device"
        Write-Host "  [6] Throttle a device"
        Write-Host "  [7] Unthrottle a device"
        Write-Host "  [8] Monitor mode"
        Write-Host "  [9] Export scan"
        Write-Host "  [L] List blocked/throttled"
        Write-Host "  [R] Reset all rules"
        Write-Host "  [U] Check for updates / Update"
        Write-Host "  [Q] Quit"
        Write-Host ""
        $choice = Read-Host "  Choice"
        if (-not $choice) { continue }

        switch ($choice.ToLower()) {
            "1" {
                $Devices = Invoke-Scan -Format "raw_objects"
                Ok "$($Devices.Count) device(s) found. Press Enter to continue."
                Read-Host | Out-Null
            }
            "2" {
                Clear-Host
                Show-DeviceTable $Devices
                Read-Host "Press Enter to continue" | Out-Null
            }
            "3" {
                $d = Select-Device $Devices "Select device to identify"
                if ($d) {
                    Invoke-Identify $d.IP
                    Read-Host "Press Enter to continue" | Out-Null
                }
            }
            "4" {
                $d = Select-Device $Devices "Select device to BLOCK"
                if ($d) {
                    $target = $d.IP; if ($d.MAC -ne "--") { $target = $d.MAC }
                    $yn = Read-Host "Block $($d.IP) ($target)? [y/N]"
                    if ($yn -and $yn.ToLower() -eq "y") {
                        Invoke-Block $target
                        $Devices = Invoke-Scan -Format "raw_objects"
                    }
                }
                Read-Host "Press Enter to continue" | Out-Null
            }
            "5" {
                $d = Select-Device $Devices "Select device to UNBLOCK"
                if ($d) {
                    $target = $d.IP; if ($d.MAC -ne "--") { $target = $d.MAC }
                    Invoke-Unblock $target
                    $Devices = Invoke-Scan -Format "raw_objects"
                }
                Read-Host "Press Enter to continue" | Out-Null
            }
            "6" {
                $d = Select-Device $Devices "Select device to THROTTLE"
                if ($d) {
                    if ($d.MAC -eq "--") {
                        Warn "Cannot throttle: MAC address unknown for $($d.IP)"
                    } else {
                        Write-Host "  Speed examples: 512kbit, 1mbit, 2mbit, 5mbit"
                        $speed = Read-Host "  Enter speed limit"
                        if (Test-ValidSpeed $speed) {
                            Invoke-Throttle $d.MAC $speed
                            $Devices = Invoke-Scan -Format "raw_objects"
                        } else {
                            Warn "Invalid speed format."
                        }
                    }
                }
                Read-Host "Press Enter to continue" | Out-Null
            }
            "7" {
                $d = Select-Device $Devices "Select device to UNTHROTTLE"
                if ($d) {
                    if ($d.MAC -eq "--") {
                        Warn "Cannot unthrottle: MAC address unknown."
                    } else {
                        Invoke-Unthrottle $d.MAC
                        $Devices = Invoke-Scan -Format "raw_objects"
                    }
                }
                Read-Host "Press Enter to continue" | Out-Null
            }
            "8" {
                $interval = Read-Host "  Refresh interval in seconds [30]"
                if (-not $interval) { $interval = 30 }
                if ($interval -match '^[0-9]+$') {
                    Invoke-Monitor -Interval ([int]$interval)
                } else {
                    Warn "Interval must be a positive integer."
                    Start-Sleep -Seconds 1
                }
            }
            "9" {
                Write-Host "  [1] CSV   [2] JSON"
                $fmtChoice = Read-Host "  Format [1]"
                if ($fmtChoice -eq "2") { Invoke-Export -Fmt "json" } else { Invoke-Export -Fmt "csv" }
                Read-Host "Press Enter to continue" | Out-Null
            }
            "l" {
                Clear-Host
                Show-List
                Read-Host "Press Enter to continue" | Out-Null
            }
            "r" {
                Invoke-Reset
                $Devices = Invoke-Scan -Format "raw_objects"
                Read-Host "Press Enter to continue" | Out-Null
            }
            "u" {
                Invoke-ApplyUpdate
                Read-Host "Press Enter to continue" | Out-Null
            }
            "q" {
                Write-Host "`nGoodbye!`n" -ForegroundColor Green
                exit 0
            }
            default {
                Warn "Unknown option. Try again."
                Start-Sleep -Seconds 1
            }
        }
    }
}

# ─── Help ──────────────────────────────────────────────────────────────────

function Show-Help {
    Write-Host @"

netwatch.ps1 -- Network monitor & control (Windows)

Usage: netwatch.ps1 [--dry-run] [--persistent] <command> [args]

Commands:
  menu                        Interactive menu (default)
  scan [table|json|csv]       Scan local network
  monitor [interval]          Auto-refresh every N seconds (default: 30)
  identify <ip|mac>           Deep fingerprint a device
  block <ip|mac>              Block a device (Admin required)
  unblock <ip|mac>            Remove a block
  throttle <mac> <speed>      Limit bandwidth (e.g. 512kbit, 2mbit)
  unthrottle <mac>            Remove bandwidth limit
  list                        Show blocked/throttled MACs
  export [csv|json]           Export scan to $($Script:ConfigDir)
  reset                       Clear all firewall/QoS rules
  update                      Check and apply automatic updates
  help                        Show this help

Flags:
  --dry-run                   Preview without applying changes
  --persistent                No-op on Windows: Firewall/QoS rules already persist

Examples:
  .\netwatch.ps1                               # Launch interactive menu
  .\netwatch.ps1 scan
  .\netwatch.ps1 block AA:BB:CC:DD:EE:FF
  .\netwatch.ps1 throttle AA:BB:CC:DD:EE:FF 1mbit
  .\netwatch.ps1 --dry-run block 192.168.1.50

Limitations vs Linux version:
  - block: Windows Firewall blocks THIS machine's traffic to/from the target.
    No ARP-spoof LAN-wide kick (needs Npcap, not implemented). Full LAN block
    requires this PC to be the gateway (ICS) -- same constraint as iptables
    FORWARD mode on Linux.
  - throttle: uses New-NetQosPolicy. Same router/ICS constraint as Linux tc.

Config: $($Script:ConfigDir)
"@
}

# ─── Argument parsing & dispatch ───────────────────────────────────────────

$filteredArgs = @()
foreach ($a in $args) {
    switch ($a) {
        "--dry-run"    { $Script:DryRun = $true }
        "--persistent" { $Script:Persistent = $true }
        default        { $filteredArgs += $a }
    }
}

$Cmd = "menu"
if ($filteredArgs.Count -ge 1) { $Cmd = $filteredArgs[0] }
$rest = @($filteredArgs | Select-Object -Skip 1)

switch ($Cmd) {
    "menu" {
        Invoke-Menu
    }
    "update" {
        Invoke-ApplyUpdate
    }
    "scan" {
        Check-Deps; Detect-Network
        $fmt = "table"; if ($rest.Count -ge 1) { $fmt = $rest[0] }
        Invoke-Scan -Format $fmt
    }
    "monitor" {
        Check-Deps; Detect-Network
        $interval = 30; if ($rest.Count -ge 1) { $interval = [int]$rest[0] }
        Invoke-Monitor -Interval $interval
    }
    "block" {
        if ($rest.Count -lt 1) { Die "Usage: netwatch.ps1 block <ip|mac>" }
        Check-Deps; Detect-Network; Invoke-Block $rest[0]
    }
    "unblock" {
        if ($rest.Count -lt 1) { Die "Usage: netwatch.ps1 unblock <ip|mac>" }
        Check-Deps; Detect-Network; Invoke-Unblock $rest[0]
    }
    "throttle" {
        if ($rest.Count -lt 2) { Die "Usage: netwatch.ps1 throttle <mac> <speed>" }
        Check-Deps; Detect-Network; Invoke-Throttle $rest[0] $rest[1]
    }
    "unthrottle" {
        if ($rest.Count -lt 1) { Die "Usage: netwatch.ps1 unthrottle <mac>" }
        Check-Deps; Detect-Network; Invoke-Unthrottle $rest[0]
    }
    "list" {
        Show-List
    }
    "identify" {
        if ($rest.Count -lt 1) { Die "Usage: netwatch.ps1 identify <ip|mac>" }
        Check-Deps; Detect-Network; Invoke-Identify $rest[0]
    }
    "info" {
        if ($rest.Count -lt 1) { Die "Usage: netwatch.ps1 identify <ip|mac>" }
        Check-Deps; Detect-Network; Invoke-Identify $rest[0]
    }
    "probe" {
        if ($rest.Count -lt 1) { Die "Usage: netwatch.ps1 identify <ip|mac>" }
        Check-Deps; Detect-Network; Invoke-Identify $rest[0]
    }
    "export" {
        Check-Deps
        $fmt = "csv"; if ($rest.Count -ge 1) { $fmt = $rest[0] }
        Invoke-Export -Fmt $fmt
    }
    "reset" {
        Check-Deps; Detect-Network; Invoke-Reset
    }
    "help" { Show-Help }
    "-h"   { Show-Help }
    "--help" { Show-Help }
    default {
        Err "Unknown command: $Cmd"
        Write-Host "Run 'netwatch.ps1 help' for usage."
        exit 1
    }
}
