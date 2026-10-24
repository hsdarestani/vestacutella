#!/usr/bin/env bash
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
echo "=== UBUNTU UPGRADE PREFLIGHT ==="
date -Is; cat /etc/os-release | grep -E '^(NAME|VERSION|VERSION_ID|PRETTY_NAME)=';uname -a
echo "=== BOOT ==="; uptime -s; uptime; cat /proc/pressure/io
echo "=== SYSTEM ===";free -h;df -h / /boot /srv/backups 2>/dev/null;df -ih /
echo "=== BOOT CONFIG ===";ls -l /boot/vmlinuz* 2>/dev/null | tail -9;uname -r;dpkg --audit | head -50
echo "=== APT HOLD ===";apt-mark showhold;echo "=== BACKUP INVENTORY (NAME ONLY) ===";find /srv/backups -mindepth 1 -maxdepth 1 -printf '%TY-%Tm-%Td %TH:%TM %f\n' 2>/dev/null | sort -r | head -15
echo "=== DATABASE SIZES ===";du -sh /srv/vestacutella/runtime/db-vesta /srv/vestacutella/runtime/db-cutella 2>/dev/null
echo "=== APT UPDATE METADATA ===";timeout 150 apt-get update -qq;echo "APT_UPDATE_RC=$?"
echo "=== APT DRY RUN ===";timeout 100 apt-get -s -o Debug::NoLocking=1 full-upgrade 2>&1 | tail -95
echo "=== APT UPGRADABLE COUNT ===";apt list --upgradable 2>/dev/null | tail -n +2 | wc -l
echo "=== DOCKER SERVICES ===";timeout 18 docker ps -a --format '{{.Names}} {{.Status}}' | head -20
echo "=== HOST HTTP ===";for h in vesta-cosmetics.ir cutellashop.ir app.vesta-cosmetics.ir;do timeout 13 curl -ksS --connect-timeout 4 --max-time 11 --resolve "$h:443:127.0.0.1" -o /dev/null -w "$h HTTP=%{http_code}\n" "https://$h/" || true;done
echo "=== PREFLIGHT END ==="
