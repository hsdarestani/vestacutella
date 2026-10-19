#!/usr/bin/env bash
# Send grouped recovery reports to the existing WooCommerce New Order admin recipient only.
# Never resends mail to customers or creates orders.
set -euo pipefail
umask 077
SCRIPT=/tmp/vesta-order-outage-admin-digests-20261019.php
LOCK=/var/lock/vesta-order-outage-admin-digests-20261019.lock
test -s "$SCRIPT"
exec 9>"$LOCK"
flock -n 9 || { echo "ANOTHER_BACKFILL_RUNNING";exit 30; }
echo "BACKFILL_PREFLIGHT_UTC=$(date -u +%FT%TZ)"
for path in / /shop/ /wp-login.php;do
 code="$(curl --noproxy '*' -kLsS --max-time 25 --resolve vesta-cosmetics.ir:443:127.0.0.1 -o /dev/null -w '%{http_code}' "https://vesta-cosmetics.ir$path")"
 echo "SITE_HEALTH path=$path code=$code"
 [[ "$code" == 200 ]] || exit 11
done
docker cp "$SCRIPT" vc-vesta:/tmp/vesta-order-outage-admin-digests-20261019.php
trap 'docker exec vc-vesta rm -f /tmp/vesta-order-outage-admin-digests-20261019.php >/dev/null 2>&1 || true' EXIT
docker exec vc-vesta php -l /tmp/vesta-order-outage-admin-digests-20261019.php
echo "=== PREVIEW_ORDER_COUNTS_NO_MAIL ==="
docker exec vc-vesta php -d display_errors=0 /tmp/vesta-order-outage-admin-digests-20261019.php --dry-run
echo "=== SEND_DAILY_ORDER_DIGESTS ==="
docker exec vc-vesta php -d display_errors=0 /tmp/vesta-order-outage-admin-digests-20261019.php --send
echo "=== CONFIRM_DURABLE_SENT_MARKERS ==="
docker exec vc-vesta php -d display_errors=0 /tmp/vesta-order-outage-admin-digests-20261019.php --dry-run
echo "VESTA_OUTAGE_ORDER_ADMIN_DIGESTS_DONE"
