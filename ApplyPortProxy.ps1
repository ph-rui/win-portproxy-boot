# ApplyPortProxy.ps1
#
# Re-creates the listening sockets for existing "netsh interface portproxy" rules.
#
# Why this is needed:
#   * portproxy rules are persistent (they live in
#     HKLM\SYSTEM\CurrentControlSet\Services\PortProxy\v4tov4\tcp) and are loaded by
#     the "IP Helper" (iphlpsvc) service at boot.
#   * if iphlpsvc loads them before the local IP addresses are actually assigned to a
#     NIC, binding fails silently: "netsh interface portproxy show all" still lists the
#     rule, but nothing listens and traffic is not forwarded.
#   * re-running "netsh ... add" for a rule that already exists is a NO-OP, so it does
#     not repair the state. The rule has to be deleted and added again (or the service
#     restarted) to force a fresh bind.
#
# This script:
#   1. reads every v4tov4 rule from the registry
#   2. waits until all listen addresses exist on the machine (default: 5 minutes)
#   3. re-adds the rules, then verifies a real listening socket per rule
#   4. for rules without a listener: delete + add, retry (8 rounds)
#   5. if still broken: restart iphlpsvc and retry (4 rounds)
#   6. writes a log and a rules backup next to this script
#
# Exit code is 0 when every rule ends up LISTENING, 1 otherwise.

[CmdletBinding()]
param(
    # How long to wait for the listen IPs to appear (seconds).
    [int]$IpWaitSeconds = 300,

    # Where to write the log. Default: apply_log.txt next to this script.
    [string]$LogPath
)

$ErrorActionPreference = 'Continue'

$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $LogPath) { $LogPath = Join-Path $root 'apply_log.txt' }
$log = $LogPath
$key = 'HKLM:\SYSTEM\CurrentControlSet\Services\PortProxy\v4tov4\tcp'

function Log {
    param([string]$Message)
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    try { Add-Content -LiteralPath $log -Value $line -Encoding UTF8 -ErrorAction Stop } catch { }
}

try {
    if ((Test-Path -LiteralPath $log) -and ((Get-Item -LiteralPath $log).Length -gt 1048576)) {
        Move-Item -LiteralPath $log -Destination "$log.old" -Force -ErrorAction SilentlyContinue
    }
} catch { }

Log '=== apply start ==='

$rulePattern = '^(\d{1,3}(\.\d{1,3}){3})/(\d+)$'

# ---------- load rules from registry ----------
$rules = @()
try {
    $props = (Get-ItemProperty -LiteralPath $key -ErrorAction Stop).PSObject.Properties
    foreach ($p in $props) {
        $lm = [regex]::Match($p.Name, $rulePattern)
        if (-not $lm.Success) { continue }
        $cm = [regex]::Match([string]$p.Value, $rulePattern)
        if (-not $cm.Success) { continue }
        $rules += [pscustomobject]@{
            ListenIp    = $lm.Groups[1].Value
            ListenPort  = [int]$lm.Groups[3].Value
            ConnectIp   = $cm.Groups[1].Value
            ConnectPort = [int]$cm.Groups[3].Value
        }
    }
} catch {
    Log ('ERROR reading registry: ' + $_.Exception.Message)
}
Log ('rules loaded: ' + $rules.Count)
if ($rules.Count -eq 0) { Log 'nothing to do'; exit 0 }

function Get-LocalIPv4 {
    @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object { $_.IPAddress })
}

function Get-ListeningPairs {
    @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
      ForEach-Object { '{0}:{1}' -f $_.LocalAddress, $_.LocalPort })
}

function Get-MissingRules {
    $pairs = Get-ListeningPairs
    @($rules | Where-Object { $pairs -notcontains ('{0}:{1}' -f $_.ListenIp, $_.ListenPort) })
}

function Add-Rule {
    param($r)
    $nargs = @('interface', 'portproxy', 'add', 'v4tov4',
               "listenaddress=$($r.ListenIp)", "listenport=$($r.ListenPort)",
               "connectaddress=$($r.ConnectIp)", "connectport=$($r.ConnectPort)")
    $out = & netsh.exe @nargs 2>&1
    if ($LASTEXITCODE -ne 0) {
        Log ('add failed {0}:{1} -> {2}:{3} : {4}' -f $r.ListenIp, $r.ListenPort, $r.ConnectIp, $r.ConnectPort, ($out -join ' '))
    }
}

function Remove-Rule {
    param($r)
    $nargs = @('interface', 'portproxy', 'delete', 'v4tov4',
               "listenaddress=$($r.ListenIp)", "listenport=$($r.ListenPort)")
    $out = & netsh.exe @nargs 2>&1
    if ($LASTEXITCODE -ne 0) {
        Log ('delete failed {0}:{1} : {2}' -f $r.ListenIp, $r.ListenPort, ($out -join ' '))
    }
}

function Add-Rules {
    foreach ($r in $rules) { Add-Rule $r }
}

# "netsh add" on an existing rule is a no-op and never re-binds the socket,
# so delete + add is the only way to repair a rule that is not listening.
function Repair-Rules {
    param($list)
    foreach ($r in $list) {
        Remove-Rule $r
        Start-Sleep -Milliseconds 500
        Add-Rule $r
    }
}

# ---------- wait for the listen addresses to exist ----------
$needIps = @($rules | ForEach-Object { $_.ListenIp } | Sort-Object -Unique)
Log ('waiting for local ips (timeout {0}s): {1}' -f $IpWaitSeconds, ($needIps -join ','))
$deadline = (Get-Date).AddSeconds($IpWaitSeconds)
while ((Get-Date) -lt $deadline) {
    $have = Get-LocalIPv4
    $missing = @($needIps | Where-Object { $have -notcontains $_ })
    if ($missing.Count -eq 0) { break }
    Start-Sleep -Seconds 5
}
$have = Get-LocalIPv4
$missing = @($needIps | Where-Object { $have -notcontains $_ })
if ($missing.Count -gt 0) {
    Log ('WARN local ip still missing: ' + ($missing -join ','))
} else {
    Log ('local ips ready: ' + ($needIps -join ','))
}

# ---------- apply + verify ----------
$backup = Join-Path $root 'rules_backup.txt'
$rules | ForEach-Object {
    'netsh interface portproxy add v4tov4 listenaddress={0} listenport={1} connectaddress={2} connectport={3}' -f $_.ListenIp, $_.ListenPort, $_.ConnectIp, $_.ConnectPort
} | Set-Content -LiteralPath $backup -Encoding ASCII -ErrorAction SilentlyContinue
Log ('rules backup written: ' + $backup)

Start-Sleep -Seconds 3
Add-Rules
Start-Sleep -Seconds 3
$missingRules = @(Get-MissingRules)

for ($i = 1; $i -le 8 -and $missingRules.Count -gt 0; $i++) {
    Log ('missing listeners (round {0}): {1}' -f $i, (($missingRules | ForEach-Object { '{0}:{1}' -f $_.ListenIp, $_.ListenPort }) -join ','))
    Repair-Rules $missingRules
    Start-Sleep -Seconds 4
    $missingRules = @(Get-MissingRules)
}

if ($missingRules.Count -gt 0) {
    for ($i = 1; $i -le 4 -and $missingRules.Count -gt 0; $i++) {
        Log ("restarting iphlpsvc (attempt $i)")
        & sc.exe stop  iphlpsvc | Out-Null
        Start-Sleep -Seconds 5
        & sc.exe start iphlpsvc | Out-Null
        Start-Sleep -Seconds 5
        if ((Get-Service -Name iphlpsvc).Status -eq 'Running') {
            Repair-Rules $missingRules
            Start-Sleep -Seconds 4
        }
        $missingRules = @(Get-MissingRules)
    }
}

# ---------- report ----------
$pairs = Get-ListeningPairs
$failed = 0
foreach ($r in $rules) {
    if ($pairs -contains ('{0}:{1}' -f $r.ListenIp, $r.ListenPort)) {
        $state = 'LISTENING'
    } else {
        $state = 'NOT-LISTENING'
        $failed++
    }
    Log ('{0}  {1}:{2} -> {3}:{4}' -f $state, $r.ListenIp, $r.ListenPort, $r.ConnectIp, $r.ConnectPort)
}
Log '=== apply done ==='

if ($failed -gt 0) { exit 1 } else { exit 0 }
