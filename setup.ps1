# One-command installer. Runs both the WSL and Windows sides.
#
# Run this in your REGULAR PowerShell — NOT as Administrator. The script
# will self-elevate only the Windows-side commands (portproxy + firewall).
# This ensures WSL is invoked as your current user (not a different admin
# account), so it targets the right distro/user.
#
# Usage:
#   .\setup.ps1                                       # classic mode, auto-detects distro+user
#   .\setup.ps1 -Mirrored                             # mirrored networking (no portproxy)
#   .\setup.ps1 -WslDistro Ubuntu -WslUser alice      # explicit targets (skips confirmation)
#   .\setup.ps1 -Yes                                  # skip the confirmation prompt
#   .\setup.ps1 -ListenPort 2222                      # expose on a non-default Windows port
#   .\setup.ps1 -AllowAdmin                           # proceed even if already elevated (NOT recommended)
#
# Remote:
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
    [switch]$AllowAdmin,
    [string]$RepoRawBase = "https://raw.githubusercontent.com/Bedatty-Engineering/wsl-ssh-setup/main",

    # Internal — used when the script re-invokes itself elevated to run only the Windows-admin bits.
    [switch]$AdminPhase,
    [string]$WslIp = ""
)

$ErrorActionPreference = "Stop"

function Test-IsAdmin {
    $current = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    return $current.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Wsl {
    if (-not (Get-Command wsl -ErrorAction SilentlyContinue)) {
        Write-Error "wsl.exe not found. Is WSL installed?"
        exit 1
    }
}

function Get-WslDistros {
    $prev = [Console]::OutputEncoding
    [Console]::OutputEncoding = [System.Text.Encoding]::Unicode
    try { $raw = wsl --list --verbose 2>$null } finally { [Console]::OutputEncoding = $prev }
    if (-not $raw) { return @() }
    $lines = $raw -split "`r?`n" | Where-Object { $_ -match "\S" }
    $lines | Select-Object -Skip 1 | ForEach-Object {
        $line = $_
        $default = $line.TrimStart() -match "^\*"
        $clean = $line -replace "^\s*\*?\s*", ""
        $parts = $clean -split "\s+"
        if ($parts.Count -ge 3) {
            [PSCustomObject]@{ Name=$parts[0]; State=$parts[1]; Version=$parts[2]; Default=$default }
        }
    }
}

function Resolve-WslTarget {
    $distros = @(Get-WslDistros)
    if ($distros.Count -eq 0) {
        Write-Error "No WSL distros found. Install one first (e.g. 'wsl --install -d Ubuntu')."
        exit 1
    }

    $distro = $WslDistro; $distroAuto = $false
    if (-not $distro) {
        $default = $distros | Where-Object { $_.Default } | Select-Object -First 1
        if (-not $default) { $default = $distros[0] }
        $distro = $default.Name; $distroAuto = $true
    } elseif (-not ($distros | Where-Object { $_.Name -eq $distro })) {
        Write-Error "Distro '$distro' not found. Available: $($distros.Name -join ', ')"
        exit 1
    }

    $user = $WslUser; $userAuto = $false
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
        $userAuto = $true
    }

    Write-Host ""
    Write-Host "About to install into:" -ForegroundColor Cyan
    Write-Host ("  Distro : {0}{1}" -f $distro, $(if ($distroAuto) { " (auto-detected default)" } else { "" }))
    Write-Host ("  User   : {0}{1}" -f $user,   $(if ($userAuto)   { " (auto-detected)" }         else { "" }))
    Write-Host ("  Mode   : {0}" -f $(if ($Mirrored) { "mirrored" } else { "classic (portproxy)" }))
    Write-Host ("  Ports  : Windows {0} -> WSL {1}" -f $ListenPort, $ConnectPort)
    Write-Host ""

    if (($distroAuto -or $userAuto) -and -not $Yes) {
        $ans = Read-Host "Proceed? [y/N]"
        if ($ans -notmatch '^[Yy]') { Write-Host "Aborted." -ForegroundColor Yellow; exit 1 }
    }
    return @{ Distro = $distro; User = $user }
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
        "[wsl2]`r`nnetworkingMode=mirrored`r`n" | Set-Content -Path $cfg -NoNewline
    }
    Write-Host "==> Shutting down WSL so the new networking mode takes effect" -ForegroundColor Cyan
    wsl --shutdown
    Start-Sleep -Seconds 2
}

function Invoke-WslSetup($distro, $user) {
    Write-Host "==> Running setup-wsl.sh inside WSL ($distro / $user) — sudo may prompt for password" -ForegroundColor Cyan
    $url = "$RepoRawBase/setup-wsl.sh"
    wsl -d $distro -u $user -e bash -c "set -e; tmp=`$(mktemp); curl -fsSL '$url' -o `"`$tmp`"; bash `"`$tmp`"; rm -f `"`$tmp`""
    if ($LASTEXITCODE -ne 0) { Write-Error "WSL setup failed (exit $LASTEXITCODE)."; exit 1 }
}

function Get-WslIp($distro, $user) {
    $ip = (wsl -d $distro -u $user -e hostname -I 2>$null | Out-String).Trim().Split(" ")[0]
    if ([string]::IsNullOrWhiteSpace($ip)) { Write-Error "Could not get WSL IP."; exit 1 }
    return $ip
}

function Invoke-AdminPhase($distro, $user) {
    # Spawn an elevated PowerShell that re-runs THIS script with -AdminPhase and the
    # already-computed values. Prompts UAC once.
    $argList = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", $PSCommandPath,
        "-AdminPhase",
        "-ListenPort", $ListenPort,
        "-ConnectPort", $ConnectPort,
        "-RuleName", $RuleName
    )
    if ($Mirrored) { $argList += "-Mirrored" }
    if (-not $Mirrored) { $argList += @("-WslIp", $WslIp) }

    Write-Host "==> Requesting Windows admin elevation (UAC prompt)" -ForegroundColor Cyan
    $p = Start-Process powershell -ArgumentList $argList -Verb RunAs -Wait -PassThru
    if ($p.ExitCode -ne 0) { Write-Error "Admin phase failed (exit $($p.ExitCode))."; exit 1 }
}

# ===== Admin phase (runs elevated, only does Windows-side work) =====
function Invoke-AdminWork {
    if (-not (Test-IsAdmin)) {
        Write-Error "AdminPhase invoked but not running as Administrator."
        exit 1
    }
    if (-not $Mirrored) {
        if ([string]::IsNullOrWhiteSpace($WslIp)) { Write-Error "AdminPhase needs -WslIp in classic mode."; exit 1 }
        Write-Host "==> [admin] Ensuring iphlpsvc service is running" -ForegroundColor Cyan
        Set-Service -Name iphlpsvc -StartupType Automatic
        Start-Service -Name iphlpsvc -ErrorAction SilentlyContinue

        Write-Host ("==> [admin] Creating portproxy ({0} -> {1}:{2})" -f $ListenPort, $WslIp, $ConnectPort) -ForegroundColor Cyan
        netsh interface portproxy delete v4tov4 listenport=$ListenPort listenaddress=0.0.0.0 2>$null | Out-Null
        netsh interface portproxy add    v4tov4 listenport=$ListenPort listenaddress=0.0.0.0 connectport=$ConnectPort connectaddress=$WslIp
    }
    Write-Host "==> [admin] Creating firewall rule '$RuleName' on port $ListenPort" -ForegroundColor Cyan
    Remove-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue
    New-NetFirewallRule -DisplayName $RuleName `
        -Direction Inbound -LocalPort $ListenPort -Protocol TCP `
        -Action Allow -Profile Any | Out-Null

    Write-Host "==> [admin] Done." -ForegroundColor Green
}

function Show-Summary($user) {
    $hostIp = (Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.InterfaceAlias -notmatch "Loopback|vEthernet|WSL" -and $_.IPAddress -notmatch "^169\." } |
        Select-Object -First 1).IPAddress
    Write-Host ""
    Write-Host "==> Done." -ForegroundColor Green
    Write-Host ("    Networking mode: {0}" -f $(if ($Mirrored) { "mirrored (no portproxy)" } else { "classic (portproxy)" }))
    Write-Host ""
    Write-Host "    Connect from another machine on the LAN:"
    Write-Host "      ssh $user@$hostIp -p $ListenPort"
}

# ===== entrypoint =====

if ($AdminPhase) {
    Invoke-AdminWork
    exit 0
}

# Main (non-admin) phase
if ((Test-IsAdmin) -and -not $AllowAdmin) {
    Write-Error @"
Do not run this script as Administrator.

When elevated through UAC with a different admin account, wsl.exe runs in
that other user's context and will target the WRONG WSL distro/user.

Run it in a normal PowerShell window — the script will request elevation
only for the Windows-side commands (portproxy + firewall) via a UAC prompt.

If you really know what you're doing, re-run with -AllowAdmin.
"@
    exit 1
}

Assert-Wsl
$target = Resolve-WslTarget
$distro = $target.Distro
$user   = $target.User

if ($Mirrored) { Set-MirroredMode }

Invoke-WslSetup -distro $distro -user $user

if (-not $Mirrored) {
    $script:WslIp = Get-WslIp -distro $distro -user $user
    Write-Host "    WSL IP: $WslIp"
}

if (Test-IsAdmin) {
    # User forced -AllowAdmin: do the admin work inline without re-elevating.
    Invoke-AdminWork
} else {
    Invoke-AdminPhase -distro $distro -user $user
}

Show-Summary -user $user
