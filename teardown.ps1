# One-command uninstall. Undoes both the WSL and Windows sides.
# Must be run as Administrator in PowerShell.
#
# Usage:
#   .\teardown.ps1
#   .\teardown.ps1 -DisableMirrored   # also remove networkingMode=mirrored from .wslconfig

param(
    [int[]]$ListenPort = @(22, 8888),
    [string[]]$RuleName = @("WSL SSH", "WSL SSH 22", "WSL SSH 8888"),
    [switch]$DisableMirrored,
    [string]$RepoRawBase = "https://raw.githubusercontent.com/Bedatty-Engineering/wsl-ssh-setup/main"
)

$ErrorActionPreference = "Stop"

function Assert-Admin {
    $current = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $current.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Error "This script must be run as Administrator."
        exit 1
    }
}

Assert-Admin

Write-Host "==> Running teardown-wsl.sh inside WSL" -ForegroundColor Cyan
$url = "$RepoRawBase/teardown-wsl.sh"
wsl -e bash -c "curl -fsSL '$url' | bash" 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Warning "WSL teardown returned non-zero (WSL may be off or already clean). Continuing."
}

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

if ($DisableMirrored) {
    $cfg = Join-Path $env:USERPROFILE ".wslconfig"
    if (Test-Path $cfg) {
        Write-Host "==> Removing networkingMode=mirrored from $cfg" -ForegroundColor Cyan
        $content = Get-Content $cfg -Raw
        $content = [regex]::Replace($content, "(?m)^\s*networkingMode\s*=.*\r?\n?", "")
        Set-Content -Path $cfg -Value $content -NoNewline
        Write-Host "==> Shutting down WSL so the change takes effect" -ForegroundColor Cyan
        wsl --shutdown
    }
}

Write-Host ""
Write-Host "==> Current portproxy state:" -ForegroundColor Green
netsh interface portproxy show all
Write-Host ""
Write-Host "==> Done. Everything cleaned up." -ForegroundColor Green
