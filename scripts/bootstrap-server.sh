#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

echo "=== OS ==="
cat /etc/os-release || true

echo "=== installing base packages ==="
apt-get update
apt-get install -y ca-certificates curl git rsync jq unzip tar gzip openssl ufw fail2ban

if ! command -v docker >/dev/null 2>&1; then
  echo "=== installing Docker ==="
  curl -fsSL https://get.docker.com | sh
fi

systemctl enable --now docker

mkdir -p /srv/vestacutella /srv/migration /srv/backups
chmod 700 /srv/migration /srv/backups

echo "=== firewall ==="
ufw allow OpenSSH >/dev/null || true
ufw allow 80/tcp >/dev/null || true
ufw allow 443/tcp >/dev/null || true
ufw --force enable >/dev/null || true

echo "=== versions ==="
docker --version
docker compose version
git --version

echo "=== capacity ==="
free -h || true
df -hT / /srv/migration

echo "SERVER_BOOTSTRAP_OK"
