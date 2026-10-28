# Uninstall-BootTask.ps1
#
# Removes the scheduled task created by Install-BootTask.ps1.
# The portproxy rules themselves are NOT touched.
#
#   powershell -ExecutionPolicy Bypass -File .\Uninstall-BootTask.ps1

[CmdletBinding()]
param(
    [string]$TaskName = 'PortProxyBoot'
)

$ErrorActionPreference = 'Continue'

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$pr = New-Object Security.Principal.WindowsPrincipal($id)
if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error 'This script must run as administrator.'
    exit 1
}

$t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if (-not $t) {
    Write-Host "Task '$TaskName' not found - nothing to do."
    exit 0
}

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
Write-Host "Task '$TaskName' removed. portproxy rules are unchanged."
exit 0
