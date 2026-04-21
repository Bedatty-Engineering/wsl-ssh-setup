# One-command uninstall. Undoes both the WSL and Windows sides.
#
# Run this in your REGULAR PowerShell - NOT as Administrator. The script
# will self-elevate only the Windows-side commands.
#
# Usage:
#   .\teardown.ps1
#   .\teardown.ps1 -DisableMirrored
#   .\teardown.ps1 -WslDistro Ubuntu -WslUser alice
#   .\teardown.ps1 -Yes

param(
    [int[]]$ListenPort = @(22, 8888),
    [string[]]$RuleName = @("WSL SSH", "WSL SSH 22", "WSL SSH 8888"),
    [switch]$DisableMirrored,
    [string]$WslDistro = "",
    [string]$WslUser = "",
    [switch]$Yes,
    [switch]$AllowAdmin,
    [string]$RepoRawBase = "https://raw.githubusercontent.com/Bedatty-Engineering/wsl-ssh-setup/main",

    # Internal admin phase
    [switch]$AdminPhase
)

$ErrorActionPreference = "Stop"

function Test-IsAdmin {
    $current = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    return $current.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
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
    if ($distros.Count -eq 0) { return $null }
    $distro = $WslDistro; $distroAuto = $false
    if (-not $distro) {
        $default = $distros | Where-Object { $_.Default } | Select-Object -First 1
        if (-not $default) { $default = $distros[0] }
        $distro = $default.Name; $distroAuto = $true
    }
    $user = $WslUser; $userAuto = $false
    if (-not $user) {
        $user = (wsl -d $distro -e whoami 2>$null | Out-String).Trim()
        if (-not $user) { $user = "root" }
        $userAuto = $true
    }
    Write-Host ""
    Write-Host "About to run WSL teardown on:" -ForegroundColor Cyan
    Write-Host ("  Distro : {0}{1}" -f $distro, $(if ($distroAuto) { " (auto-detected)" } else { "" }))
    Write-Host ("  User   : {0}{1}" -f $user,   $(if ($userAuto)   { " (auto-detected)" } else { "" }))
    Write-Host ""
    if (($distroAuto -or $userAuto) -and -not $Yes) {
        $ans = Read-Host "Proceed? [y/N]"
        if ($ans -notmatch '^[Yy]') { Write-Host "Aborted." -ForegroundColor Yellow; exit 1 }
    }
    return @{ Distro = $distro; User = $user }
}

function Invoke-WslTeardown($distro, $user) {
    Write-Host "==> Running teardown-wsl.sh inside WSL (sudo may prompt for your WSL password)" -ForegroundColor Cyan
    $url = "$RepoRawBase/teardown-wsl.sh"
    wsl -d $distro -u $user -e bash -c "set -e; tmp=`$(mktemp); curl -fsSL '$url' -o `"`$tmp`"; bash `"`$tmp`"; rm -f `"`$tmp`""
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "WSL teardown returned non-zero. Continuing with Windows-side cleanup."
    }
}

function Invoke-AdminWork {
    if (-not (Test-IsAdmin)) { Write-Error "AdminPhase invoked but not running as Administrator."; exit 1 }
    Write-Host "==> [admin] Removing portproxy rules" -ForegroundColor Cyan
    foreach ($port in $ListenPort) {
        Write-Host "    - listenport=$port"
        netsh interface portproxy delete v4tov4 listenport=$port listenaddress=0.0.0.0 2>$null | Out-Null
    }
    Write-Host "==> [admin] Removing firewall rules" -ForegroundColor Cyan
    foreach ($name in $RuleName) {
        if (Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue) {
            Write-Host "    - $name"
            Remove-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue
        }
    }
    Write-Host "==> [admin] Current portproxy state:" -ForegroundColor Green
    netsh interface portproxy show all
}

function Invoke-AdminPhase {
    $argList = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", $PSCommandPath,
        "-AdminPhase"
    )
    foreach ($p in $ListenPort) { $argList += @("-ListenPort", $p) }
    foreach ($n in $RuleName)   { $argList += @("-RuleName",   $n) }
    Write-Host "==> Requesting Windows admin elevation (UAC prompt)" -ForegroundColor Cyan
    $p = Start-Process powershell -ArgumentList $argList -Verb RunAs -Wait -PassThru
    if ($p.ExitCode -ne 0) { Write-Warning "Admin phase exit code: $($p.ExitCode)" }
}

# ===== entrypoint =====

if ($AdminPhase) {
    Invoke-AdminWork
    exit 0
}

if ((Test-IsAdmin) -and -not $AllowAdmin) {
    Write-Error @"
Do not run this script as Administrator.

When elevated through UAC with a different admin account, wsl.exe runs in
that other user's context and will target the WRONG WSL distro/user.

Run it in a normal PowerShell window - the script will request elevation
only for the Windows-side commands via a UAC prompt.

If you really know what you're doing, re-run with -AllowAdmin.
"@
    exit 1
}

$target = Resolve-WslTarget
if ($target) {
    Invoke-WslTeardown -distro $target.Distro -user $target.User
} else {
    Write-Host "==> No WSL distros detected - skipping WSL teardown." -ForegroundColor Yellow
}

if (Test-IsAdmin) { Invoke-AdminWork } else { Invoke-AdminPhase }

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
Write-Host "==> Done. Everything cleaned up." -ForegroundColor Green
