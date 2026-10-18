#!/usr/bin/env bash
# Replace ONLY Vesta's host-driven PHP CLI cron with a normal HTTPS loopback.
# No licence changes, no vendor modifications, no WP settings or DB writes beyond
# WordPress's ordinary cron execution, and no Cutella cron changes.
set -euo pipefail
CRON=/etc/cron.d/vestacutella-wp-cron
BASE=/srv/vestacutella/runtime/vesta
SAVE="/srv/backups/vesta-cron-http-context-$(date -u +%Y%m%dT%H%M%SZ)"
OLD='* * * * * root flock -n /run/lock/vesta-wp-cron.lock docker exec vc-vesta php /var/www/html/wp-cron.php >/dev/null 2>&1'
NEW='* * * * * root flock -n /run/lock/vesta-wp-cron.lock curl --silent --show-error --fail --connect-timeout 10 --max-time 110 --resolve vesta-cosmetics.ir:443:127.0.0.1 https://vesta-cosmetics.ir/wp-cron.php >/dev/null 2>>/var/log/vesta-wp-cron-errors.log'
CUT='* * * * * root flock -n /run/lock/cutella-wp-cron.lock docker exec vc-cutella php /var/www/html/wp-cron.php >/dev/null 2>&1'
test -f "$CRON" && test -f "$BASE/wp-config.php"
test "$(grep -Fc "$CUT" "$CRON")" -eq 1 || { echo 'Cutella cron line differs; abort'; exit 10; }
if grep -Fxq "$NEW" "$CRON"; then
  echo 'Vesta HTTPS cron already installed; verifying only.'
  ALREADY=1
elif [[ "$(grep -Fxc "$OLD" "$CRON")" == 1 ]]; then
  echo 'Verified exact legacy Vesta cron command.'
  ALREADY=0
else
  echo 'Unknown Vesta host-cron configuration; leaving unchanged.'
  exit 11
fi
test "$(systemctl is-active cron)" = active
docker exec vc-vesta php -r '
require "/var/www/html/wp-config.php";
if (!defined("DISABLE_WP_CRON") || !DISABLE_WP_CRON) exit(12);
echo "REQUEST_DRIVEN_CRON_DISABLED_OK".PHP_EOL;
'
# Baseline with public paths only, never place orders or use a logged-in session.
for host in vesta-cosmetics.ir cutellashop.ir app.vesta-cosmetics.ir; do
  code=$(curl -ksS --connect-timeout 8 --max-time 35 --resolve "$host:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$host/")
  echo "before $host HTTP=$code"
  [[ "$code" == 200 ]] || exit 13
done
if [[ "$ALREADY" == 1 ]]; then
  exit 0
fi
mkdir -m 700 -p "$SAVE"
cp -p "$CRON" "$SAVE/vestacutella-wp-cron"
chmod 600 "$SAVE/vestacutella-wp-cron"
CHANGED=no
FINISHED=no
rollback() {
  code=$?
  trap - EXIT
  if [[ "$CHANGED" == yes && "$FINISHED" != yes ]]; then
     cp -p "$SAVE/vestacutella-wp-cron" "$CRON"
     chmod 644 "$CRON"
     systemctl reload cron 2>/dev/null || true
     echo "RESTORED_OLD_CRON rc=$code"
  fi
  exit "$code"
}
trap rollback EXIT
# Exact match replacement, preserves the other website and all custom cron entries.
SOURCE_CRON="$CRON" OLD_CRON="$OLD" NEW_CRON="$NEW" python3 - <<'PY'
import os
from pathlib import Path
p=Path(os.environ["SOURCE_CRON"])
text=p.read_text()
old=os.environ["OLD_CRON"]
new=os.environ["NEW_CRON"]
if text.splitlines().count(old)!=1:
    raise SystemExit("Legacy cron line missing or duplicated")
if "docker exec vc-cutella php /var/www/html/wp-cron.php" not in text:
    raise SystemExit("Cutella cron preservation guard failed")
p.write_text(text.replace(old,new,1))
PY
CHANGED=yes
chmod 644 "$CRON"
grep -Fxq "$NEW" "$CRON"
grep -Fxq "$CUT" "$CRON"
systemctl reload cron 2>/dev/null || systemctl restart cron
# Canonical Host and SNI are now supplied by an actual HTTPS request.
# WordPress officially supports direct wp-cron.php even with DISABLE_WP_CRON=true.
status=$(curl -ksS --connect-timeout 8 --max-time 110 --resolve vesta-cosmetics.ir:443:127.0.0.1 -o /dev/null -w '%{http_code}' https://vesta-cosmetics.ir/wp-cron.php)
echo "http_cron_smoke=$status"
[[ "$status" == 200 ]] || exit 20
for host in vesta-cosmetics.ir cutellashop.ir app.vesta-cosmetics.ir; do
  code=$(curl -ksS --connect-timeout 8 --max-time 35 --resolve "$host:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$host/")
  echo "after $host HTTP=$code"
  [[ "$code" == 200 ]] || exit 21
done
test "$(systemctl is-active cron)" = active
FINISHED=yes
trap - EXIT
echo "VESTA_CANONICAL_HOST_CRON_DEPLOYED backup=$SAVE"
