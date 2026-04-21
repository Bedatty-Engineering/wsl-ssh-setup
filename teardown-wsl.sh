#!/usr/bin/env bash
set -euo pipefail

# Runs inside WSL. Fully removes the sshd setup created by setup-wsl.sh.

SSH_PORT=22

echo "==> Stopping sshd (if running)"
sudo service ssh stop 2>/dev/null || true

echo "==> Purging openssh-server"
sudo apt purge -y openssh-server || true
sudo apt autoremove -y

echo "==> Removing leftover config"
sudo rm -rf /etc/ssh/sshd_config /etc/ssh/sshd_config.d /etc/ssh/ssh_host_* 2>/dev/null || true

echo "==> Verifying nothing is listening on port ${SSH_PORT}"
if sudo ss -tlnp | grep -q ":${SSH_PORT}"; then
    echo "WARNING: something is still listening on port ${SSH_PORT}:" >&2
    sudo ss -tlnp | grep ":${SSH_PORT}" >&2
else
    echo "    OK — nothing listening on :${SSH_PORT}"
fi

echo "==> Done. WSL is clean."
