#!/usr/bin/env bash
# Guarded production hotfix: defer unsafe historical Mahak replay while keeping new orders flowing.
# Does not touch WooCommerce order state, remote integrations, cron cadence, or database settings.
set -Eeuo pipefail
umask 077
ROOT=/srv/vestacutella/runtime/vesta
TARGET="$ROOT/wp-content/plugins/bazara/classes/class.bazara.api.php"
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
SAVE="/srv/backups/vesta-bazara-bounded-$STAMP"
[[ -s "$TARGET" ]] || { echo BAZARA_FILE_MISSING; exit 10; }
[[ "$(docker inspect -f '{{.State.Running}}' vc-vesta)" == true ]] || exit 11
[[ "$(docker inspect -f '{{.State.Running}}' vc-db-vesta)" == true ]] || exit 12
for host in vesta-cosmetics.ir cutellashop.ir app.vesta-cosmetics.ir; do
  status=$(curl --noproxy '*' -ksS --connect-timeout 6 --max-time 35 \
     --resolve "$host:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$host/")
  echo "BEFORE_HOST=$host HTTP=$status"
  [[ "$status" == 200 ]] || exit 13
done
mkdir -p -m 0700 "$SAVE"
cp -p "$TARGET" "$SAVE/class.bazara.api.php"
echo "BACKUP=$SAVE"
CHANGED=no
DONE=no
rollback() {
  rc=$?
  trap - EXIT
  if [[ "$CHANGED" == yes && "$DONE" != yes ]];then
    cp -p "$SAVE/class.bazara.api.php" "$TARGET"
    echo "BAZARA_FILE_ROLLED_BACK rc=$rc"
  fi
  exit "$rc"
}
trap rollback EXIT
TARGET="$TARGET" python3 - <<'PY'
import os,pathlib
path=pathlib.Path(os.environ["TARGET"])
source=path.read_text(encoding="utf-8",errors="surrogateescape")
marker="vc_bazara_defer_historical_backfill"
start=source.find("function start_sync_orders(")
if start < 0: raise SystemExit("START_SYNC_NOT_FOUND")
end=source.find("public function ",start+16)
if end<0:end=len(source)
block=source[start:end]
if marker in block:
    print("BAZARA_RECOVERY_ALREADY_PRESENT")
    raise SystemExit(0)
legacy="if ($left_behind_sync_limit !== null && $left_behind_sync_limit > 0 && $max_id > 0)"
merge="$all_orders = array_merge($left_behind_orders, $orders);"
if block.count(legacy)!=1 or block.count(merge)!=1:
    raise SystemExit("BAZARA_UNEXPECTED_VENDOR_CODE_NO_WRITE")
insert_legacy="""// Vesta safety guard: old orders may already exist in Mahak without local mahak_id.
        // Preserve the recorded backfill cursor; do not send historical orders automatically.
        if (get_option('vc_bazara_defer_historical_backfill', true)) {
            $left_behind_sync_limit = $max_id;
        }
        """
insert_new="""// Bound each run to one new order. Action Scheduler previously timed out at 300s.
        // Unprocessed orders keep their original WooCommerce state and remain eligible.
        $orders = array_slice($orders, 0, 1);
        """
block=block.replace(legacy,insert_legacy+legacy,1)
block=block.replace(merge,insert_new+merge,1)
new=source[:start]+block+source[end:]
if new.count(marker)!=1:raise SystemExit("BAZARA_PATCH_MARKER_MISMATCH")
path.write_text(new,encoding="utf-8",errors="surrogateescape")
print("BAZARA_BOUNDED_PATCH_WRITTEN")
PY
if cmp -s "$TARGET" "$SAVE/class.bazara.api.php"; then
  echo "BAZARA_ALREADY_INSTALLED_OR_UNCHANGED"
else
  CHANGED=yes
fi
docker exec vc-vesta php -l /var/www/html/wp-content/plugins/bazara/classes/class.bazara.api.php
grep -Fq 'vc_bazara_defer_historical_backfill' "$TARGET"
grep -Fq 'array_slice($orders, 0, 1)' "$TARGET"
for host in vesta-cosmetics.ir cutellashop.ir app.vesta-cosmetics.ir; do
  status=$(curl --noproxy '*' -ksS --connect-timeout 6 --max-time 35 \
     --resolve "$host:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$host/")
  echo "AFTER_HOST=$host HTTP=$status"
  [[ "$status" == 200 ]] || exit 15
done
DONE=yes
trap - EXIT
echo BAZARA_NEW_ORDERS_PRIORITIZED=yes
echo BAZARA_HISTORICAL_ORDERS_DEFERRED=yes
echo BAZARA_DATABASE_CHANGED=no
echo BAZARA_CRON_CADENCE_CHANGED=no
echo BAZARA_REPAIR_DEPLOYED=yes
