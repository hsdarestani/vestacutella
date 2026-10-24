#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
echo "== INSTALL WATCHDOG =="
test -s /tmp/vesta-health-watchdog-20261024.sh
test -s /tmp/vesta-resource-telegram-20261024.php
test "$(docker inspect --format '{{.State.Running}}' vc-vesta)" = true
B=/srv/backups/vesta-monitor-$(date -u +%Y%m%dT%H%M%SZ)
mkdir -m 700 -p "$B"
for p in /usr/local/sbin/vesta-resource-watchdog /usr/local/lib/vesta-resource-telegram.php /etc/cron.d/vesta-resource-watchdog; do
 [ -f "$p" ] && cp -p "$p" "$B/$(basename "$p")" || true
done
bash -n /tmp/vesta-health-watchdog-20261024.sh
timeout 8 docker exec -i vc-vesta php -l < /tmp/vesta-resource-telegram-20261024.php
install -m 700 /tmp/vesta-health-watchdog-20261024.sh /usr/local/sbin/vesta-resource-watchdog
install -m 600 /tmp/vesta-resource-telegram-20261024.php /usr/local/lib/vesta-resource-telegram.php
cat >/etc/cron.d/vesta-resource-watchdog <<'CRON'
*/5 * * * * root /usr/bin/flock -n /run/lock/vesta-resource-watchdog.lock /usr/bin/timeout 90 /usr/local/sbin/vesta-resource-watchdog >>/var/log/vesta-resource-watchdog.log 2>&1
CRON
chmod 644 /etc/cron.d/vesta-resource-watchdog
cat >/etc/logrotate.d/vesta-resource-watchdog <<'ROTATE'
/var/log/vesta-resource-watchdog.log /var/log/vesta-runtime-limits-errors.log {
    weekly
    rotate 6
    missingok
    notifempty
    compress
    copytruncate
}
ROTATE
systemctl reload cron 2>/dev/null || true
echo "== LOCAL FIRST CHECK =="
timeout 85 /usr/local/sbin/vesta-resource-watchdog
echo "== TELEGRAM DELIVERY TEST =="
timeout 55 /usr/local/sbin/vesta-resource-watchdog --test-alert
echo "WATCHDOG_INSTALLED_BACKUP=$B"
