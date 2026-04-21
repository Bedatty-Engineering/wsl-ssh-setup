# One-command uninstall. Undoes both the WSL and Windows sides.
# Must be run as Administrator in PowerShell.
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

function Get-WslDistros {
    $prev = [Console]::OutputEncoding
    [Console]::OutputEncoding = [System.Text.Encoding]::Unicode
    try {
        $raw = wsl --list --verbose 2>$null
    } finally {
        [Console]::OutputEncoding = $prev
    }
    if (-not $raw) { return @() }
    $lines = $raw -split "`r?`n" | Where-Object { $_ -match "\S" }
    $lines | Select-Object -Skip 1 | ForEach-Object {
        $line = $_
        $default = $line.TrimStart() -match "^\*"
        $clean = $line -replace "^\s*\*?\s*", ""
        $parts = $clean -split "\s+"
        if ($parts.Count -ge 3) {
            [PSCustomObject]@{
                Name = $parts[0]; State = $parts[1]; Version = $parts[2]; Default = $default
            }
        }
    }
}

function Resolve-WslTarget {
    $distros = @(Get-WslDistros)
    if ($distros.Count -eq 0) { return $null }  # nothing to tear down on WSL side

    $distro = $WslDistro
    $distroAuto = $false
    if (-not $distro) {
        $default = $distros | Where-Object { $_.Default } | Select-Object -First 1
        if (-not $default) { $default = $distros[0] }
        $distro = $default.Name
        $distroAuto = $true
    }

    $user = $WslUser
    $userAuto = $false
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
        if ($ans -notmatch '^[Yy]') {
            Write-Host "Aborted." -ForegroundColor Yellow
            exit 1
        }
    }

    return @{ Distro = $distro; User = $user }
}

Assert-Admin

$target = Resolve-WslTarget

if ($target) {
    Write-Host "==> Running teardown-wsl.sh inside WSL (sudo may prompt for your WSL password)" -ForegroundColor Cyan
    $url = "$RepoRawBase/teardown-wsl.sh"
    wsl -d $target.Distro -u $target.User -e bash -c "set -e; tmp=`$(mktemp); curl -fsSL '$url' -o `"`$tmp`"; bash `"`$tmp`"; rm -f `"`$tmp`""
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "WSL teardown returned non-zero (WSL may be off or already clean). Continuing."
    }
} else {
    Write-Host "==> No WSL distros detected — skipping WSL teardown." -ForegroundColor Yellow
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
