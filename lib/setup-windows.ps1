# Sets up port forwarding from Windows:22 -> WSL:22 and opens the firewall.
# Must be run as Administrator in PowerShell.
#
# Usage:
#   .\setup-windows.ps1            # create/update the rule using the current WSL IP
#   .\setup-windows.ps1 -Remove    # tear everything down

param(
    [int]$ListenPort = 22,
    [int]$ConnectPort = 22,
    [string]$RuleName = "WSL SSH",
    [switch]$Remove
)

function Assert-Admin {
    $current = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $current.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Error "This script must be run as Administrator."
        exit 1
    }
}

Assert-Admin

if ($Remove) {
    Write-Host "==> Removing portproxy on port $ListenPort" -ForegroundColor Cyan
    netsh interface portproxy delete v4tov4 listenport=$ListenPort listenaddress=0.0.0.0 2>$null

    Write-Host "==> Removing firewall rule '$RuleName'" -ForegroundColor Cyan
    Remove-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue

    Write-Host "==> Done. Current portproxy state:" -ForegroundColor Green
    netsh interface portproxy show all
    exit 0
}

Write-Host "==> Ensuring iphlpsvc service is running (required by portproxy)" -ForegroundColor Cyan
Set-Service -Name iphlpsvc -StartupType Automatic
Start-Service -Name iphlpsvc -ErrorAction SilentlyContinue

Write-Host "==> Fetching WSL IP" -ForegroundColor Cyan
$wslIp = (wsl hostname -I).Trim().Split(" ")[0]
if ([string]::IsNullOrWhiteSpace($wslIp)) {
    Write-Error "Could not get the WSL IP. Is WSL running?"
    exit 1
}
Write-Host "    WSL IP: $wslIp"

Write-Host ("==> Recreating portproxy rule ({0} -> {1}:{2})" -f $ListenPort, $wslIp, $ConnectPort) -ForegroundColor Cyan
netsh interface portproxy delete v4tov4 listenport=$ListenPort listenaddress=0.0.0.0 2>$null | Out-Null
netsh interface portproxy add    v4tov4 listenport=$ListenPort listenaddress=0.0.0.0 connectport=$ConnectPort connectaddress=$wslIp

Write-Host "==> Configuring firewall" -ForegroundColor Cyan
Remove-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName $RuleName `
    -Direction Inbound -LocalPort $ListenPort -Protocol TCP `
    -Action Allow -Profile Any | Out-Null

Write-Host "==> Current portproxy state:" -ForegroundColor Green
netsh interface portproxy show all

Write-Host ""
Write-Host "==> Ready. Test from another machine:" -ForegroundColor Green
$hostIp = (Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.InterfaceAlias -notmatch "Loopback|vEthernet|WSL" -and $_.IPAddress -notmatch "^169\." } |
    Select-Object -First 1).IPAddress
Write-Host "    ssh user@$hostIp -p $ListenPort"
