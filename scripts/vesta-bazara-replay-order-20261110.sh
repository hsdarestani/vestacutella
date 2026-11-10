#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
order_id="$1"
case "$order_id" in 105052|105053|105204|105205|105206|105207) ;; *) echo NOT_ALLOWLISTED;exit 10;;esac
BASE=/srv/backups/vesta-bazara-replay-$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p -m 0700 "$BASE"
exec 9>/run/lock/vesta-bazara-replay-20261110.lock
flock -n 9 || { echo ANOTHER_REPLAY_ACTIVE;exit 11; }
test "$(docker inspect -f '{{.State.Running}}' vc-vesta)" = true
test "$(docker inspect -f '{{.State.Running}}' vc-db-vesta)" = true
test -s /tmp/vesta-bazara-replay-order-20261110.php
cp -p /tmp/vesta-bazara-replay-order-20261110.php "$BASE/replay-logic.php"
docker exec -i vc-vesta php -l < "$BASE/replay-logic.php"
echo "AUDIT_BACKUP=$BASE"
for hostname in vesta-cosmetics.ir cutellashop.ir app.vesta-cosmetics.ir;do
  status=$(curl --noproxy '*' -ksS --max-time 20 --connect-timeout 6 --resolve "$hostname:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$hostname/")
  echo "PREFLIGHT_HOST=$hostname HTTP=$status"
  test "$status" = 200
done
# Baseline of the exact order metadata and local ERP-reference entry, not private customer data.
docker exec -i vc-db-vesta sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb -uroot -D "$MARIADB_DATABASE" --batch --raw --default-character-set=utf8mb4' > "$BASE/order-before.tsv" <<SQL
SELECT post_id,meta_key,meta_value FROM wp_postmeta WHERE post_id=$order_id AND meta_key IN ('mahak_id','mahak_error');
SELECT OrderId,OrderClientId,OrderCode FROM wp_bazara_orders WHERE OrderClientId=$order_id;
SQL
echo "BEFORE_SNAPSHOT_DONE=yes"
docker exec -i -e VC_ORDER_ID="$order_id" -e VC_SEND_ORDER=no vc-vesta php -d memory_limit=512M < "$BASE/replay-logic.php" 2> "$BASE/preflight-stderr.log" | tee "$BASE/preflight.log"
grep -Eq 'ACTION=(check_only|skipped_existing_erp_reference)' "$BASE/preflight.log" || { echo PREFLIGHT_FAILED;exit 14; }
if grep -Fq 'ACTION=skipped_existing_erp_reference' "$BASE/preflight.log"; then
  echo EXISTING_REMOTE_REFERENCE_SKIP=yes
  exit 0
fi
echo "EXECUTING_ALLOWLISTED_ORDER=$order_id"
set +e
docker exec -i -e VC_ORDER_ID="$order_id" -e VC_SEND_ORDER=yes vc-vesta php -d memory_limit=512M < "$BASE/replay-logic.php" >"$BASE/send.log" 2>"$BASE/send-stderr.log"
rc=$?
set -e
cat "$BASE/send.log"
echo "SEND_EXIT_CODE=$rc"
echo "BACKUP=$BASE"
if [[ "$rc" != 0 ]];then
  echo "REPLAY_NOT_VERIFIED_NO_AUTOMATIC_RETRY=yes"
  exit "$rc"
fi
grep -Fq 'VERDICT=verified_local_order_synced' "$BASE/send.log" || { echo VERIFICATION_MISSING;exit 15; }
echo "ORDER_REPLAY_VERIFIED=yes"
