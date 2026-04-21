#!/usr/bin/env bash
set -euo pipefail

# Runs inside WSL. Installs and configures sshd on port 22, listening on all interfaces.

SSH_PORT=22

echo "==> Updating apt and installing openssh-server"
sudo apt update
sudo apt install -y openssh-server

echo "==> Configuring /etc/ssh/sshd_config"
sudo sed -i "s/^#\?Port .*/Port ${SSH_PORT}/" /etc/ssh/sshd_config
if ! grep -qE "^ListenAddress 0\.0\.0\.0" /etc/ssh/sshd_config; then
    echo "ListenAddress 0.0.0.0" | sudo tee -a /etc/ssh/sshd_config > /dev/null
fi
sudo sed -i "s/^#\?PasswordAuthentication .*/PasswordAuthentication yes/" /etc/ssh/sshd_config

echo "==> (Re)starting sshd"
sudo service ssh restart

echo "==> Verifying sshd is listening on 0.0.0.0:${SSH_PORT}"
sudo ss -tlnp | grep ":${SSH_PORT}" || {
    echo "ERROR: sshd is not listening on port ${SSH_PORT}" >&2
    exit 1
}

echo "==> WSL internal IP (use this in the Windows portproxy):"
hostname -I | awk '{print $1}'

echo "==> Done. sshd is ready in WSL."
