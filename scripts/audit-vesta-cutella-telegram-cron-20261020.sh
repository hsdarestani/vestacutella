#!/usr/bin/env bash
set -euo pipefail
echo "AUDIT_UTC=$(date -u +%FT%TZ)"
# Second check after at least one retry window for transient Telegram transport errors.
test -s /etc/cron.d/vesta-cutella-telegram-orders
echo "ORDER_BOT_CRON_PRESENT=yes"
systemctl is-active --quiet cron
systemctl is-active --quiet vesta-telegram-strato-tunnel
echo "TELEGRAM_TUNNEL_AND_CRON_ACTIVE=yes"
if [[ -f /var/log/vesta-cutella-telegram-orders.log ]];then
 echo "=== RECENT_WORKER_CYCLES ==="
 tail -45 /var/log/vesta-cutella-telegram-orders.log |grep -E 'CUTELLA_TG_(SCAN|SEND|RESULT|WORKER)' || true
fi
echo "=== CURRENT_PENDING_IMPORTED_ORDERS ==="
docker exec -u www-data -i vc-vesta php -d display_errors=0 -- --dry-run < /srv/vestacutella/repo/scripts/vesta-cutella-telegram-order-worker-20261020.php
echo "CUTELLA_TELEGRAM_CRON_VERIFIED"
