# Fully removes the portproxy + firewall rules created by setup-windows.ps1.
# Must be run as Administrator in PowerShell.
#
# Usage:
#   .\teardown-windows.ps1
#   .\teardown-windows.ps1 -ListenPort 2222   # if you used a non-default port

param(
    [int[]]$ListenPort = @(22, 8888),
    [string[]]$RuleName = @("WSL SSH", "WSL SSH 22", "WSL SSH 8888")
)

function Assert-Admin {
    $current = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $current.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Error "This script must be run as Administrator."
        exit 1
    }
}

Assert-Admin

Write-Host "==> Removing portproxy rules" -ForegroundColor Cyan
foreach ($port in $ListenPort) {
    Write-Host "    - listenport=$port"
    netsh interface portproxy delete v4tov4 listenport=$port listenaddress=0.0.0.0 2>$null | Out-Null
}

Write-Host "==> Removing firewall rules" -ForegroundColor Cyan
foreach ($name in $RuleName) {
    if (Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue) {
        Write-Host "    - $name"
        Remove-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue
    }
}

Write-Host "==> Current portproxy state:" -ForegroundColor Green
netsh interface portproxy show all

Write-Host ""
Write-Host "==> Done. Windows is clean." -ForegroundColor Green
