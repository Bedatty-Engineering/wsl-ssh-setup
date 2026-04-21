# One-command installer. Runs both the WSL and Windows sides.
# Must be run as Administrator in PowerShell.
#
# Usage:
#   .\setup.ps1                    # classic mode: portproxy + firewall
#   .\setup.ps1 -Mirrored          # mirrored networking: no portproxy, immune to WSL IP changes
#   .\setup.ps1 -ListenPort 2222   # expose on a non-default Windows port
#
# Remote (from a fresh shell):
#   $u = "https://raw.githubusercontent.com/Bedatty-Engineering/wsl-ssh-setup/main/setup.ps1"
#   irm $u -OutFile "$env:TEMP\setup.ps1"; & "$env:TEMP\setup.ps1" [-Mirrored]

param(
    [switch]$Mirrored,
    [int]$ListenPort = 22,
    [int]$ConnectPort = 22,
    [string]$RuleName = "WSL SSH",
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

function Assert-Wsl {
    if (-not (Get-Command wsl -ErrorAction SilentlyContinue)) {
        Write-Error "wsl.exe not found. Is WSL installed?"
        exit 1
    }
}

function Warn-WindowsSshd {
    $svc = Get-Service -Name sshd -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq "Running" -and $ListenPort -eq 22) {
        Write-Warning "Windows OpenSSH Server (sshd) is running on port 22."
        Write-Warning "In mirrored mode, WSL shares the Windows IP stack and will conflict with it."
        Write-Warning "Either stop the Windows sshd or pick a different -ListenPort / -ConnectPort."
        $ans = Read-Host "Continue anyway? [y/N]"
        if ($ans -notmatch '^[Yy]') { exit 1 }
    }
}

function Set-MirroredMode {
    $cfg = Join-Path $env:USERPROFILE ".wslconfig"
    Write-Host "==> Writing $cfg with networkingMode=mirrored" -ForegroundColor Cyan

    if (Test-Path $cfg) {
        $content = Get-Content $cfg -Raw
        if ($content -match "networkingMode\s*=") {
            $content = [regex]::Replace($content, "networkingMode\s*=.*", "networkingMode=mirrored")
        } elseif ($content -match "\[wsl2\]") {
            $content = $content -replace "(\[wsl2\][^\[]*)", "`$1networkingMode=mirrored`r`n"
        } else {
            $content += "`r`n[wsl2]`r`nnetworkingMode=mirrored`r`n"
        }
        Set-Content -Path $cfg -Value $content -NoNewline
    } else {
        @"
[wsl2]
networkingMode=mirrored
"@ | Set-Content -Path $cfg
    }

    Write-Host "==> Shutting down WSL so the new networking mode takes effect" -ForegroundColor Cyan
    wsl --shutdown
    Start-Sleep -Seconds 2
}

function Invoke-WslSetup {
    Write-Host "==> Running setup-wsl.sh inside WSL" -ForegroundColor Cyan
    $url = "$RepoRawBase/setup-wsl.sh"
    wsl -e bash -c "curl -fsSL '$url' | bash"
    if ($LASTEXITCODE -ne 0) {
        Write-Error "WSL setup failed (exit $LASTEXITCODE)."
        exit 1
    }
}

function Set-Portproxy {
    Write-Host "==> Ensuring iphlpsvc service is running" -ForegroundColor Cyan
    Set-Service -Name iphlpsvc -StartupType Automatic
    Start-Service -Name iphlpsvc -ErrorAction SilentlyContinue

    Write-Host "==> Fetching WSL IP" -ForegroundColor Cyan
    $wslIp = (wsl hostname -I).Trim().Split(" ")[0]
    if ([string]::IsNullOrWhiteSpace($wslIp)) {
        Write-Error "Could not get WSL IP."
        exit 1
    }
    Write-Host "    WSL IP: $wslIp"

    Write-Host "==> Creating portproxy ($ListenPort -> ${wslIp}:${ConnectPort})" -ForegroundColor Cyan
    netsh interface portproxy delete v4tov4 listenport=$ListenPort listenaddress=0.0.0.0 2>$null | Out-Null
    netsh interface portproxy add    v4tov4 listenport=$ListenPort listenaddress=0.0.0.0 connectport=$ConnectPort connectaddress=$wslIp
}

function Set-Firewall {
    Write-Host "==> Creating firewall rule '$RuleName' on port $ListenPort" -ForegroundColor Cyan
    Remove-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName $RuleName `
        -Direction Inbound -LocalPort $ListenPort -Protocol TCP `
        -Action Allow -Profile Any | Out-Null
}

function Show-Summary {
    $hostIp = (Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.InterfaceAlias -notmatch "Loopback|vEthernet|WSL" -and $_.IPAddress -notmatch "^169\." } |
        Select-Object -First 1).IPAddress
    $wslUser = (wsl whoami).Trim()

    Write-Host ""
    Write-Host "==> Done." -ForegroundColor Green
    if ($Mirrored) {
        Write-Host "    Networking mode: mirrored (no portproxy needed)"
    } else {
        Write-Host "    Networking mode: classic (portproxy)"
        netsh interface portproxy show all
    }
    Write-Host ""
    Write-Host "    Connect from another machine on the LAN:"
    Write-Host "      ssh $wslUser@$hostIp -p $ListenPort"
}

# --- main ---

Assert-Admin
Assert-Wsl

if ($Mirrored) {
    Warn-WindowsSshd
    Set-MirroredMode
}

Invoke-WslSetup

if (-not $Mirrored) {
    Set-Portproxy
}
Set-Firewall

Show-Summary
