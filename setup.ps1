# One-command installer. Runs both the WSL and Windows sides.
# Must be run as Administrator in PowerShell.
#
# Usage:
#   .\setup.ps1                                       # classic mode, auto-detects distro+user
#   .\setup.ps1 -Mirrored                             # mirrored networking (no portproxy)
#   .\setup.ps1 -WslDistro Ubuntu -WslUser alice      # explicit targets (skips confirmation)
#   .\setup.ps1 -Yes                                  # skip confirmation even on auto-detection
#   .\setup.ps1 -ListenPort 2222                      # expose on a non-default Windows port
#
# Remote (from a fresh shell):
#   $u = "https://raw.githubusercontent.com/Bedatty-Engineering/wsl-ssh-setup/main/setup.ps1"
#   irm $u -OutFile "$env:TEMP\setup.ps1"; & "$env:TEMP\setup.ps1" [-Mirrored]

param(
    [switch]$Mirrored,
    [int]$ListenPort = 22,
    [int]$ConnectPort = 22,
    [string]$RuleName = "WSL SSH",
    [string]$WslDistro = "",
    [string]$WslUser = "",
    [switch]$Yes,
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

function Get-WslDistros {
    # wsl --list outputs UTF-16LE; read it as raw bytes then decode.
    $prev = [Console]::OutputEncoding
    [Console]::OutputEncoding = [System.Text.Encoding]::Unicode
    try {
        $raw = wsl --list --verbose 2>$null
    } finally {
        [Console]::OutputEncoding = $prev
    }
    if (-not $raw) { return @() }

    $lines = $raw -split "`r?`n" | Where-Object { $_ -match "\S" }
    # Skip header line
    $lines | Select-Object -Skip 1 | ForEach-Object {
        $line = $_
        $default = $line.TrimStart() -match "^\*"
        $clean = $line -replace "^\s*\*?\s*", ""
        $parts = $clean -split "\s+"
        if ($parts.Count -ge 3) {
            [PSCustomObject]@{
                Name    = $parts[0]
                State   = $parts[1]
                Version = $parts[2]
                Default = $default
            }
        }
    }
}

function Resolve-WslTarget {
    $distros = @(Get-WslDistros)
    if ($distros.Count -eq 0) {
        Write-Error "No WSL distros found. Install one first (e.g. 'wsl --install -d Ubuntu')."
        exit 1
    }

    # Resolve distro
    $distro = $WslDistro
    $distroAutoDetected = $false
    if (-not $distro) {
        $default = $distros | Where-Object { $_.Default } | Select-Object -First 1
        if (-not $default) { $default = $distros[0] }
        $distro = $default.Name
        $distroAutoDetected = $true
    } else {
        if (-not ($distros | Where-Object { $_.Name -eq $distro })) {
            Write-Error "Distro '$distro' not found. Available: $($distros.Name -join ', ')"
            exit 1
        }
    }

    # Resolve user inside that distro
    $user = $WslUser
    $userAutoDetected = $false
    if (-not $user) {
        $user = (wsl -d $distro -e whoami 2>$null | Out-String).Trim()
        if (-not $user -or $user -eq "root") {
            Write-Error @"
Auto-detected WSL user is '$user' in distro '$distro'. Refusing to proceed with root.
Pass -WslUser <username>, or set a non-root default in the distro:

  wsl -d $distro -u root -e bash -c "printf '[user]\ndefault=<username>\n' > /etc/wsl.conf"
  wsl --shutdown
"@
            exit 1
        }
        $userAutoDetected = $true
    }

    # Confirmation when anything was auto-detected
    Write-Host ""
    Write-Host "About to install into:" -ForegroundColor Cyan
    Write-Host ("  Distro : {0}{1}" -f $distro, $(if ($distroAutoDetected) { " (auto-detected default)" } else { "" }))
    Write-Host ("  User   : {0}{1}" -f $user,   $(if ($userAutoDetected)   { " (auto-detected)" }         else { "" }))
    Write-Host ("  Mode   : {0}" -f $(if ($Mirrored) { "mirrored" } else { "classic (portproxy)" }))
    Write-Host ("  Ports  : Windows {0} -> WSL {1}" -f $ListenPort, $ConnectPort)
    Write-Host ""

    $needsConfirm = ($distroAutoDetected -or $userAutoDetected) -and -not $Yes
    if ($needsConfirm) {
        $ans = Read-Host "Proceed? [y/N]"
        if ($ans -notmatch '^[Yy]') {
            Write-Host "Aborted." -ForegroundColor Yellow
            exit 1
        }
    }

    return @{ Distro = $distro; User = $user }
}

function Warn-WindowsSshd {
    $svc = Get-Service -Name sshd -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq "Running" -and $ListenPort -eq 22) {
        Write-Warning "Windows OpenSSH Server (sshd) is running on port 22."
        Write-Warning "In mirrored mode, WSL shares the Windows IP stack and will conflict with it."
        Write-Warning "Either stop the Windows sshd or pick a different -ListenPort / -ConnectPort."
        if (-not $Yes) {
            $ans = Read-Host "Continue anyway? [y/N]"
            if ($ans -notmatch '^[Yy]') { exit 1 }
        }
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

function Invoke-WslSetup($distro, $user) {
    Write-Host "==> Running setup-wsl.sh inside WSL ($distro / $user) — sudo may prompt for password" -ForegroundColor Cyan
    $url = "$RepoRawBase/setup-wsl.sh"
    # Download to a file first so bash doesn't consume stdin — sudo needs the TTY.
    wsl -d $distro -u $user -e bash -c "set -e; tmp=`$(mktemp); curl -fsSL '$url' -o `"`$tmp`"; bash `"`$tmp`"; rm -f `"`$tmp`""
    if ($LASTEXITCODE -ne 0) {
        Write-Error "WSL setup failed (exit $LASTEXITCODE)."
        exit 1
    }
}

function Set-Portproxy($distro, $user) {
    Write-Host "==> Ensuring iphlpsvc service is running" -ForegroundColor Cyan
    Set-Service -Name iphlpsvc -StartupType Automatic
    Start-Service -Name iphlpsvc -ErrorAction SilentlyContinue

    Write-Host "==> Fetching WSL IP" -ForegroundColor Cyan
    $wslIp = (wsl -d $distro -u $user -e hostname -I 2>$null | Out-String).Trim().Split(" ")[0]
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

function Show-Summary($user) {
    $hostIp = (Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.InterfaceAlias -notmatch "Loopback|vEthernet|WSL" -and $_.IPAddress -notmatch "^169\." } |
        Select-Object -First 1).IPAddress

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
    Write-Host "      ssh $user@$hostIp -p $ListenPort"
}

# --- main ---

Assert-Admin
Assert-Wsl

$target = Resolve-WslTarget
$distro = $target.Distro
$user   = $target.User

if ($Mirrored) {
    Warn-WindowsSshd
    Set-MirroredMode
}

Invoke-WslSetup -distro $distro -user $user

if (-not $Mirrored) {
    Set-Portproxy -distro $distro -user $user
}
Set-Firewall

Show-Summary -user $user
