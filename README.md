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
- **Mirrored** (`-Mirrored`) — ⭐ **recommended.** WSL shares the Windows IP stack (`networkingMode=mirrored` in `.wslconfig`). No portproxy needed, immune to WSL IP changes. Requires Windows 11 + a recent WSL 2.

## Requirements

- Windows 10/11 with WSL 2 and at least one Linux distro installed (`wsl --install -d Ubuntu`).
- Windows 11 + recent WSL 2 for `-Mirrored` mode.
- **A WSL terminal must be open (or the distro otherwise running) when you try to SSH in.** WSL 2 shuts the distro's VM down after an idle timeout, and with it `sshd` stops. As long as at least one WSL session is active (any terminal window, VS Code remote, etc.), `sshd` keeps running and the SSH connection works. See [Keep WSL running in the background](#keep-wsl-running-in-the-background) below for ways to make this automatic.

Placeholders used throughout this README:

| Placeholder | What it means | Example |
|---|---|---|
| `<GH_USER>/<GH_REPO>` | Your GitHub `user/repo` hosting the scripts | `Bedatty-Engineering/wsl-ssh-setup` |
| `<WSL_USER>` | Your username inside WSL | `ubuntu` |
| `<WINDOWS_LAN_IP>` | Windows host IP on the LAN (from `ipconfig`) | `192.168.x.y` |

## One-command install (recommended)

Run in a **regular Windows PowerShell window — NOT as Administrator**. The script self-elevates only the Windows-side commands (portproxy + firewall) via a UAC prompt. This guarantees WSL is invoked under your real user session, targeting the correct distro/user. Running elevated with a different admin account (a common case when UAC asks for credentials) would point `wsl.exe` at the wrong user's WSL instance.

**Classic mode:**
```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
$p = "$env:TEMP\setup.ps1"
irm https://raw.githubusercontent.com/Bedatty-Engineering/wsl-ssh-setup/main/setup.ps1 -OutFile $p
& $p
```

**Mirrored mode (⭐ recommended — immune to WSL IP changes):**
```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
$p = "$env:TEMP\setup.ps1"
irm https://raw.githubusercontent.com/Bedatty-Engineering/wsl-ssh-setup/main/setup.ps1 -OutFile $p
& $p -Mirrored
```

> `Set-ExecutionPolicy -Scope Process` loosens the policy only for the current PowerShell window (nothing persists). This works regardless of your machine/user policy and avoids needing `Unblock-File`. Close the window and the policy reverts automatically.

Options:
```powershell
& "$env:TEMP\setup.ps1" -ListenPort 2222                       # non-default Windows port
& "$env:TEMP\setup.ps1" -Mirrored -ConnectPort 2222
& "$env:TEMP\setup.ps1" -WslDistro Ubuntu -WslUser alice       # target a specific WSL distro/user
& "$env:TEMP\setup.ps1" -Yes                                   # skip the confirmation prompt
```

Before installing, the script shows which WSL distro and user it will target and asks for confirmation. Pass both `-WslDistro` and `-WslUser` (or `-Yes`) to make it fully non-interactive.

> `sudo` inside WSL will prompt for your WSL password interactively. Keep the terminal focused.

> ⚠️ Piping remote scripts into a shell runs code blindly. For stronger guarantees, pin a specific commit (`/main/` → `/<commit-sha>/`) or download and inspect before executing.

## One-command uninstall

Removes sshd from WSL, the portproxy, the firewall rule, and `networkingMode=mirrored` from `.wslconfig` (if present — skipped silently otherwise).

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
$p = "$env:TEMP\teardown.ps1"
irm https://raw.githubusercontent.com/Bedatty-Engineering/wsl-ssh-setup/main/teardown.ps1 -OutFile $p
& $p -DisableMirrored
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

## Keep WSL running in the background

WSL 2 shuts down the distro VM after a short idle period when no processes are running. When the VM is down, `sshd` isn't listening and new SSH connections fail with `Connection refused` or timeout. You need at least one active session keeping the distro alive. Options, from simplest to most automatic:

**Option 1 — just keep a WSL terminal window open.** Works out of the box. The moment you close every terminal and wait a couple of minutes, the VM stops.

**Option 2 — disable the idle shutdown entirely.** Add to `C:\Users\<you>\.wslconfig`:
```ini
[wsl2]
vmIdleTimeout=-1
```
Then `wsl --shutdown` and reopen WSL once. The VM will stay alive until you reboot Windows.

**Option 3 — auto-start WSL at Windows logon.** Create a shortcut to `wsl.exe -d <YourDistro> -e bash -c "sudo service ssh start && sleep infinity"` in `shell:startup` (run `explorer shell:startup` in the Run dialog). This launches a hidden WSL session on logon and keeps it running indefinitely, with sshd started.

Option 2 is the lowest-friction for a machine you SSH into regularly.

## Files

Orchestrators (run from Windows, drive both sides):
- `setup.ps1` — installer. Runs the WSL setup via `wsl -e`, plus portproxy/firewall on Windows.
- `teardown.ps1` — uninstaller. Mirror image of `setup.ps1`.

Building blocks under `lib/` (run directly if you prefer):
- `lib/setup-wsl.sh` — inside WSL. Installs openssh-server, configures sshd on `0.0.0.0:22`.
- `lib/setup-windows.ps1` — Windows side only: portproxy + firewall.
- `lib/teardown-wsl.sh` — inside WSL. Purges openssh-server.
- `lib/teardown-windows.ps1` — Windows side only: removes portproxy and firewall.

## Manual step by step

If you'd rather not use the orchestrator:

**Inside WSL:**
```bash
curl -fsSL https://raw.githubusercontent.com/Bedatty-Engineering/wsl-ssh-setup/main/lib/setup-wsl.sh | bash
```

**On Windows (PowerShell as Administrator):**
```powershell
$u = "https://raw.githubusercontent.com/Bedatty-Engineering/wsl-ssh-setup/main/lib/setup-windows.ps1"
irm $u -OutFile "$env:TEMP\setup-windows.ps1"; & "$env:TEMP\setup-windows.ps1"
```

## Troubleshooting

### SSH still fails right after a "successful" setup run

If the install finished with no errors but you still can't reach the WSL from another machine, work through these checks in order — each one isolates a different layer.

**1. Confirm the target IP.**
You need the **Windows LAN IP**, not the WSL internal one.
```powershell
ipconfig | Select-String IPv4
```
Use the address that matches your network (e.g. `192.168.x.y`). `172.*` addresses are WSL-internal and not routable from other machines.

**2. Confirm the client is on the same network.**
```bash
# from the client
ping <WINDOWS_LAN_IP>
```
If ping fails: both machines aren't on the same LAN, or the router has client/AP isolation enabled (common on guest networks).

**3. Confirm the port is open from the client.**
```bash
# Linux/macOS
nc -zv <WINDOWS_LAN_IP> 22
# Windows (from the client)
Test-NetConnection -ComputerName <WINDOWS_LAN_IP> -Port 22
```
- **timeout** → Windows firewall is blocking. Check network profile (see below) and re-run `setup.ps1`.
- **refused** → nothing listening. Either portproxy is missing (classic mode) or sshd died.

**4. Check the Windows network profile.**
Firewall rules with `Profile Any` still need a reachable profile. `Public` is frequently restrictive.
```powershell
Get-NetConnectionProfile
# If Public, switch to Private:
Set-NetConnectionProfile -InterfaceIndex <N> -NetworkCategory Private
```

**5. Test locally from Windows.**
```powershell
ssh <WSL_USER>@localhost -p 22
```
- If this works from Windows but not from the LAN: the problem is on the firewall/routing side.
- If this fails too: sshd in WSL isn't reachable; continue.

**6. Verify sshd inside WSL is actually running.**
```bash
sudo service ssh status
sudo ss -tlnp | grep :22
```
Must show `LISTEN 0 128 0.0.0.0:22 sshd`. If it's `127.0.0.1:22`, sshd only accepts local connections — fix `/etc/ssh/sshd_config` to `ListenAddress 0.0.0.0` and `sudo service ssh restart`.

**7. (Classic mode) Check portproxy is pointing at the current WSL IP.**
The WSL IP changes on every Windows reboot.
```powershell
netsh interface portproxy show all
wsl hostname -I
```
The `Connect Address` must match `wsl hostname -I`. If not, re-run `setup.ps1`.

**8. (Mirrored mode) Check for port-22 conflict.**
```powershell
Get-Service sshd -ErrorAction SilentlyContinue
Get-NetTCPConnection -LocalPort 22 -ErrorAction SilentlyContinue
```
If Windows OpenSSH Server is running, it owns port 22 and WSL's sshd can't bind there. Stop it or use a different port (see the section below).

**9. Check the Hyper-V firewall (Windows 11 only).**
```powershell
Get-NetFirewallHyperVProfile
Set-NetFirewallHyperVProfile -Name Public,Private,Domain -Enabled False
```

**10. Look at sshd logs in WSL.**
```bash
sudo journalctl -u ssh -n 50    # if systemd is enabled
sudo tail -n 50 /var/log/auth.log
```
Failed login attempts (wrong key, wrong user) show up here.

---

### Symptom → cause reference

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

(requires editing `/etc/ssh/sshd_config` in WSL to `Port 2222` — or just re-run `lib/setup-wsl.sh` after adjusting the port manually in the config)

## License

MIT — see [`LICENSE`](LICENSE).
