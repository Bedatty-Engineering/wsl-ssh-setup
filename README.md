# SSH to WSL over the local network

Sets up SSH access from another machine on the local network to a WSL (Ubuntu)
instance running on a Windows host. Works via `netsh portproxy`: Windows listens
on port 22 and forwards traffic to the WSL sshd.

```
┌──────────────┐      ┌──────────────────────┐       ┌────────────┐
│ other machine│──SSH▶│ Windows host (:22)   │──NAT─▶│ WSL (:22)  │
│   (client)   │      │ portproxy + firewall │       │  sshd      │
└──────────────┘      └──────────────────────┘       └────────────┘
```

Placeholders used throughout this README:

| Placeholder | What it means | Example |
|---|---|---|
| `<GH_USER>/<GH_REPO>` | Your GitHub `user/repo` hosting the scripts | `Bedatty-Engineering/wsl-ssh-setup` |
| `<WSL_USER>` | Your username inside WSL | `ubuntu` |
| `<WINDOWS_LAN_IP>` | Windows host IP on the LAN (from `ipconfig`) | `192.168.x.y` |
| `<WSL_INTERNAL_IP>` | WSL internal IP (from `hostname -I`) | `172.x.x.x` |

## Files

- `setup-wsl.sh` — runs **inside WSL**. Installs openssh-server, configures and starts sshd.
- `setup-windows.ps1` — runs **in Windows PowerShell as Administrator**. Creates the portproxy rule and firewall rule.

## Quick install (run remotely from GitHub)

**In WSL:**
```bash
curl -fsSL https://raw.githubusercontent.com/Bedatty-Engineering/wsl-ssh-setup/main/setup-wsl.sh | bash
```

**In Windows (PowerShell as Administrator):**
```powershell
$u = "https://raw.githubusercontent.com/Bedatty-Engineering/wsl-ssh-setup/main/setup-windows.ps1"
irm $u -OutFile "$env:TEMP\setup-windows.ps1"
& "$env:TEMP\setup-windows.ps1"
# Pass args if needed:
# & "$env:TEMP\setup-windows.ps1" -ListenPort 2222
# & "$env:TEMP\setup-windows.ps1" -Remove
```

> ⚠️ Piping remote scripts into a shell runs code blindly. For stronger guarantees, pin a specific commit (`/main/` → `/<commit-sha>/`) or download and inspect before executing.

## Step by step (manual)

### 1. Inside WSL

```bash
cd wsl-ssh-setup
chmod +x setup-wsl.sh
./setup-wsl.sh
```

At the end, the script prints the internal WSL IP (something like `<WSL_INTERNAL_IP>`). The Windows script detects it automatically, but it's handy for debugging.

### 2. On the Windows host (PowerShell as Administrator)

Copy `setup-windows.ps1` to the Windows side (via `\\wsl$\Ubuntu\...` or any other means) and run:

```powershell
.\setup-windows.ps1
```

Expected output at the end:

```
Address         Port        Address              Port
------------------------------------------------------
0.0.0.0         22          <WSL_INTERNAL_IP>    22
```

Options:

```powershell
.\setup-windows.ps1 -ListenPort 2222   # expose on a different external port
.\setup-windows.ps1 -Remove            # tear down portproxy and firewall rule
```

### 3. Connect from the other machine

```bash
ssh <WSL_USER>@<WINDOWS_LAN_IP>
```

Find the Windows IP with `ipconfig` (IPv4 of the LAN adapter).

## Persistence across reboots

The WSL internal IP **changes on every Windows reboot**, so the portproxy breaks. Options:

**Option A — run the script manually after boot:**
```powershell
.\setup-windows.ps1
```

**Option B — run it automatically at boot (Task Scheduler):**

1. Open "Task Scheduler" → Create Task.
2. **General**: check "Run with highest privileges".
3. **Triggers**: New → "At startup".
4. **Actions**: New → Program: `powershell.exe`, Arguments:
   ```
   -ExecutionPolicy Bypass -File "C:\path\to\setup-windows.ps1"
   ```
5. **Conditions**: uncheck "Start the task only if the computer is on AC power" if on a laptop.

The task will recreate the portproxy with the new WSL IP on every boot.

## Passwordless access (recommended)

From the client:
```bash
ssh-keygen -t ed25519   # if you don't have a key yet
ssh-copy-id <WSL_USER>@<WINDOWS_LAN_IP>
```

Optional — shortcut in `~/.ssh/config` on the client:
```
Host wsl-remote
    HostName <WINDOWS_LAN_IP>
    User <WSL_USER>
```
Connect with: `ssh wsl-remote`.

## Troubleshooting

| Symptom | Likely cause | Action |
|---|---|---|
| `Connection timed out` (plain) | Windows firewall / wrong network | Run `setup-windows.ps1`, check the client is on the same LAN |
| `Connection refused` | sshd not running or wrong port | In WSL: `sudo service ssh status` and `sudo ss -tlnp \| grep :22` |
| `Connection timed out during banner exchange` | Portproxy points to a stale WSL IP | Re-run `setup-windows.ps1` |
| `Connection reset` from Windows itself | Hyper-V Firewall, iptables in WSL, or TCP wrappers | See sections below |
| `Permission denied` | Wrong user/password or key not authorized | The user is the WSL user, not the Windows user |

**Check from Windows whether WSL is reachable:**
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
