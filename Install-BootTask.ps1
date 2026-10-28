# Install-BootTask.ps1
#
# Registers a scheduled task that runs ApplyPortProxy.ps1 right after boot, so the
# netsh portproxy rules get their listening sockets back once the NICs are up.
#
# Run this from an ELEVATED PowerShell prompt.
#
#   powershell -ExecutionPolicy Bypass -File .\Install-BootTask.ps1
#
# Note: the task runs as NT AUTHORITY\SYSTEM with the highest privileges. Such tasks are
# not visible in Task Scheduler unless you open it as administrator.

[CmdletBinding()]
param(
    [string]$TaskName = 'PortProxyBoot',
    # Delay before the task starts (ISO 8601 duration, e.g. PT20S).
    [string]$Delay = 'PT20S'
)

$ErrorActionPreference = 'Continue'

$root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$log  = Join-Path $root 'task_install_log.txt'
$ps   = Join-Path $root 'ApplyPortProxy.ps1'

function Log {
    param([string]$m)
    try { Add-Content -LiteralPath $log -Value ('{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) -Encoding UTF8 -ErrorAction Stop } catch { }
}

if ((Test-Path -LiteralPath $log) -and ((Get-Item -LiteralPath $log).Length -gt 262144)) {
    Move-Item -LiteralPath $log -Destination "$log.old" -Force -ErrorAction SilentlyContinue
}

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$pr = New-Object Security.Principal.WindowsPrincipal($id)
if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Log 'NOT ELEVATED - abort'
    Write-Error 'This script must run as administrator.'
    exit 1
}
Log "elevated as $($id.Name)"

if (-not (Test-Path -LiteralPath $ps)) {
    Log "ERROR script not found: $ps"
    Write-Error "ApplyPortProxy.ps1 not found next to this script: $ps"
    exit 1
}

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $ps)

$trigger = New-ScheduledTaskTrigger -AtStartup
$trigger.Delay = $Delay

$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 20) `
    -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings `
    -Description 'Re-create netsh portproxy listening sockets after boot' -Force | Out-Null

$t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($t) {
    Log ("task created: state=$($t.State) user=$($t.Principal.UserId) runlevel=$($t.Principal.RunLevel)")
    Log ("action: $($t.Actions[0].Execute) $($t.Actions[0].Arguments)")
    Log ("trigger: at startup, delay=$($t.Triggers[0].Delay)")
    Write-Host "Task '$TaskName' registered."
} else {
    Log 'ERROR task not created'
    Write-Error "Failed to register task '$TaskName'."
    exit 1
}

# run once now so the rules become active without waiting for a reboot
Log '--- running apply script now ---'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ps
$code = $LASTEXITCODE
Log ('apply exit=' + $code)
Log '=== install done ==='

if ($code -ne 0) {
    Write-Warning "ApplyPortProxy.ps1 reported problems (exit $code). See $root\apply_log.txt"
}
exit $code
