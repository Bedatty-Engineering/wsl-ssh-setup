# SSH to WSL over the local network

Sets up SSH access from another machine on the local network to a WSL (Ubuntu)
instance running on a Windows host. Runs on Windows via a single PowerShell
command — it drives the WSL side too through `wsl -e bash -c`.

```
┌──────────────┐      ┌──────────────────────┐       ┌────────────┐
│ other machine│──SSH▶│ Windows host (:22)   │──────▶│ WSL (:22)  │
│   (client)   │      │ firewall (+portproxy)│       │  sshd      │
└──────────────┘      └──────────────────────┘       └────────────┘
```

Two networking modes are supported:

- **Classic** (default) — `netsh portproxy` forwards Windows:22 → WSL:22. Works everywhere, but the WSL IP changes on every Windows reboot, so the portproxy needs to be recreated (just re-run `setup.ps1`).
- **Mirrored** (`-Mirrored`) — WSL shares the Windows IP stack (`networkingMode=mirrored` in `.wslconfig`). No portproxy needed, immune to WSL IP changes. Requires Windows 11 + a recent WSL 2.

Placeholders used throughout this README:

| Placeholder | What it means | Example |
|---|---|---|
| `<GH_USER>/<GH_REPO>` | Your GitHub `user/repo` hosting the scripts | `Bedatty-Engineering/wsl-ssh-setup` |
| `<WSL_USER>` | Your username inside WSL | `ubuntu` |
| `<WINDOWS_LAN_IP>` | Windows host IP on the LAN (from `ipconfig`) | `192.168.x.y` |

## One-command install (recommended)

Run in **Windows PowerShell as Administrator**. This is the only thing you need — it installs `openssh-server` inside WSL, configures sshd, sets up the portproxy (or mirrored mode) and opens the firewall.

**Classic mode:**
```powershell
$u = "https://raw.githubusercontent.com/Bedatty-Engineering/wsl-ssh-setup/main/setup.ps1"
irm $u -OutFile "$env:TEMP\setup.ps1"; & "$env:TEMP\setup.ps1"
```

**Mirrored mode (immune to WSL IP changes):**
```powershell
$u = "https://raw.githubusercontent.com/Bedatty-Engineering/wsl-ssh-setup/main/setup.ps1"
irm $u -OutFile "$env:TEMP\setup.ps1"; & "$env:TEMP\setup.ps1" -Mirrored
```

Options:
```powershell
& "$env:TEMP\setup.ps1" -ListenPort 2222     # expose on a non-default Windows port
& "$env:TEMP\setup.ps1" -Mirrored -ConnectPort 2222
```

> `sudo` inside WSL will prompt for your WSL password interactively. Keep the terminal focused.

> ⚠️ Piping remote scripts into a shell runs code blindly. For stronger guarantees, pin a specific commit (`/main/` → `/<commit-sha>/`) or download and inspect before executing.

## One-command uninstall

```powershell
$u = "https://raw.githubusercontent.com/Bedatty-Engineering/wsl-ssh-setup/main/teardown.ps1"
irm $u -OutFile "$env:TEMP\teardown.ps1"; & "$env:TEMP\teardown.ps1"
```

Also remove `networkingMode=mirrored` from `.wslconfig`:
```powershell
& "$env:TEMP\teardown.ps1" -DisableMirrored
```

## Connect from another machine

```bash
ssh <WSL_USER>@<WINDOWS_LAN_IP>
```

Find the Windows IP with `ipconfig` (IPv4 of the LAN adapter).

### Passwordless access (recommended)

```bash
ssh-keygen -t ed25519   # if you don't have a key yet
ssh-copy-id <WSL_USER>@<WINDOWS_LAN_IP>
```

Shortcut in `~/.ssh/config` on the client:
```
Host wsl-remote
    HostName <WINDOWS_LAN_IP>
    User <WSL_USER>
```
Connect with: `ssh wsl-remote`.

## Files

Orchestrators (run from Windows, drive both sides):
- `setup.ps1` — installer. Runs the WSL setup via `wsl -e`, plus portproxy/firewall on Windows.
- `teardown.ps1` — uninstaller. Mirror image of `setup.ps1`.

Building blocks (run directly if you prefer):
- `setup-wsl.sh` — inside WSL. Installs openssh-server, configures sshd on `0.0.0.0:22`.
- `setup-windows.ps1` — Windows side only: portproxy + firewall.
- `teardown-wsl.sh` — inside WSL. Purges openssh-server.
- `teardown-windows.ps1` — Windows side only: removes portproxy and firewall.

## Manual step by step

If you'd rather not use the orchestrator:

**Inside WSL:**
```bash
curl -fsSL https://raw.githubusercontent.com/Bedatty-Engineering/wsl-ssh-setup/main/setup-wsl.sh | bash
```

**On Windows (PowerShell as Administrator):**
```powershell
$u = "https://raw.githubusercontent.com/Bedatty-Engineering/wsl-ssh-setup/main/setup-windows.ps1"
irm $u -OutFile "$env:TEMP\setup-windows.ps1"; & "$env:TEMP\setup-windows.ps1"
```

## Troubleshooting

| Symptom | Likely cause | Action |
|---|---|---|
| `Connection timed out` (plain) | Windows firewall / wrong network | Re-run `setup.ps1`, check the client is on the same LAN |
| `Connection refused` | sshd not running or wrong port | In WSL: `sudo service ssh status` and `sudo ss -tlnp \| grep :22` |
| `Connection timed out during banner exchange` | Portproxy points to a stale WSL IP (classic mode) | Re-run `setup.ps1`, or switch to `-Mirrored` |
| `Connection reset` | Hyper-V Firewall, iptables in WSL, or TCP wrappers | See checks below |
| `Permission denied` | Wrong user/password or key not authorized | The user is the WSL user, not the Windows user |

**Check from Windows whether WSL is reachable (classic mode):**
```powershell
ssh <WSL_USER>@(wsl hostname -I).Trim()
```

**Check Hyper-V Firewall (recent Windows 11):**
```powershell
Get-NetFirewallHyperVProfile
Set-NetFirewallHyperVProfile -Name Public,Private,Domain -Enabled False
```

**Check network profile:**
```powershell
Get-NetConnectionProfile
# If Public, switch to Private:
Set-NetConnectionProfile -InterfaceIndex <N> -NetworkCategory Private
```

**Show current portproxy rules:**
```powershell
netsh interface portproxy show all
```

**sshd logs in WSL:**
```bash
sudo journalctl -u ssh -n 50   # if systemd is enabled
sudo tail -f /var/log/auth.log # fallback
```

### Mirrored mode: port 22 conflict with Windows OpenSSH

In mirrored mode WSL binds to the Windows IP stack directly. If the Windows OpenSSH Server is running on port 22, sshd in WSL cannot use the same port. Either stop the Windows sshd (`Stop-Service sshd; Set-Service sshd -StartupType Disabled`) or run WSL's sshd on another port:

```powershell
& "$env:TEMP\setup.ps1" -Mirrored -ConnectPort 2222 -ListenPort 2222
```

(requires editing `/etc/ssh/sshd_config` in WSL to `Port 2222` — or just re-run `setup-wsl.sh` after adjusting the port manually in the config)
