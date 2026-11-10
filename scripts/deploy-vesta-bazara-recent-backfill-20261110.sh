#!/usr/bin/env bash
# Live guarded fix. Only considers orders newer than Nov 8, 2026 and unsent by local ERP evidence.
set -Eeuo pipefail
umask 077
target=/srv/vestacutella/runtime/vesta/wp-content/plugins/bazara/classes/class.bazara.api.php
base=/srv/backups/vesta-bazara-recent-catchup-$(date -u +%Y%m%dT%H%M%SZ)
exec 9>/run/lock/vesta-bazara-recent-catchup-deploy.lock
flock -n 9 || exit 13
test -s "$target"
test "$(docker inspect -f '{{.State.Running}}' vc-vesta)" = true
test "$(docker inspect -f '{{.State.Running}}' vc-db-vesta)" = true
for host in vesta-cosmetics.ir cutellashop.ir app.vesta-cosmetics.ir; do
  code=$(curl --noproxy '*' -ksS --connect-timeout 8 --max-time 25 --resolve "$host:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$host/")
  echo "BEFORE_HOST=$host STATUS=$code"
  test "$code" = 200
done
mkdir -p -m 0700 "$base"
cp -p "$target" "$base/class.bazara.api.php"
echo "FILE_BACKUP=$base/class.bazara.api.php"
cp -p /etc/cron.d/vestacutella-wp-cron "$base/vestacutella-wp-cron"
CHANGED=no
FINISHED=no
rollback(){
 rc=$?
 trap - EXIT
 if [[ "$CHANGED" == yes && "$FINISHED" != yes ]];then
   cp -p "$base/class.bazara.api.php" "$target"
   echo "BAZARA_PATCH_ROLLED_BACK rc=$rc"
 fi
 exit "$rc"
}
trap rollback EXIT
TARGET="$target" python3 - <<'PY'
import os,re,pathlib
p=pathlib.Path(os.environ["TARGET"]);original=p.read_text(encoding="utf8",errors="surrogateescape")
marker="VC_RECENT_BAZARA_CATCHUP_20261110"
if marker in original:
 print("CATCHUP_PATCH_ALREADY_INSTALLED");raise SystemExit(0)
m=re.search(r'public function start_sync_orders\(\$token\s*=\s*null\)\s*\{',original)
if not m: raise SystemExit("UNKNOWN_BAZARA_FUNCTION_SIGNATURE")
pos=m.end()
end=original.find("public function ",pos)
if end<0:raise SystemExit("UNABLE_TO_FIND_METHOD_BOUNDARY")
block=original[pos:end]
merge="$all_orders = array_merge($left_behind_orders, $orders);"
if block.count(merge)!=1 or block.count("$orders = array_slice($orders, 0, 1);")!=1:
 raise SystemExit("UNKNOWN_BAZARA_PATCH_STATE")
if block.count("$result = $this->bazara_save_order($order_id, $token);")!=2:
 raise SystemExit("BAZARA_DISPATCH_SHAPE_CHANGED")
lock="""
        // VC_RECENT_BAZARA_CATCHUP_20261110: shared Apache-process lock.
        $vc_replay_lock = fopen('/tmp/vesta-bazara-order-sync.lock', 'c');
        if (!$vc_replay_lock || !flock($vc_replay_lock, LOCK_EX | LOCK_NB)) {
            return array('success' => false, 'message' => 'Vesta order-sync runner already active');
        }
"""
catchup="""
        // Existing historical backfill flag remains on. Restrict recovery to confirmed
        // recent, WooCommerce-eligible, locally unacknowledged orders. Older records
        // cannot safely be assumed missing in the remote ERP.
        if (get_option('vc_bazara_defer_historical_backfill', true)) {
            global $wpdb;
            $vc_bazara_ref_table = $wpdb->prefix . 'bazara_orders';
            $vc_cutoff_date = '2026-11-08 00:00:00';
            $left_behind_orders = $wpdb->get_col($wpdb->prepare(
                "SELECT p.ID FROM {$wpdb->posts} p
                 LEFT JOIN {$wpdb->postmeta} pm
                     ON pm.post_id=p.ID AND pm.meta_key='mahak_id' AND pm.meta_value <> ''
                 LEFT JOIN {$vc_bazara_ref_table} b ON b.OrderClientId=p.ID
                 WHERE p.post_type='shop_order'
                     AND p.post_status IN ('wc-completed','wc-processing','wc-processing5','wc-pws-packaged','wc-pws-shipping','wc-arrival-shipment')
                     AND p.post_date_gmt >= %s
                     AND p.ID < %d
                     AND pm.meta_id IS NULL
                     AND b.OrderClientId IS NULL
                 ORDER BY p.ID ASC LIMIT 1",
                $vc_cutoff_date, (int)$max_id
            ));
            if (!empty($left_behind_orders)) {
                // Never send a catch-up order plus a new order in one job.
                $orders = array();
            }
        }
"""
logging="""
            // No messages or customer data in production logs: result and order ID only.
            $vc_failed = !is_array($result) || empty($result['success']);
            error_log('VC_BAZARA_CATCHUP order=' . (int)$order_id . ' ok=' . ($vc_failed ? 'no' : 'yes'));
"""
block=block.replace(merge,catchup+"\n        "+merge,1)
block=block.replace("$result = $this->bazara_save_order($order_id, $token);","$result = $this->bazara_save_order($order_id, $token);"+logging)
result=original[:pos]+lock+block+original[end:]
if result.count(marker)!=1: raise SystemExit("PATCH_VALIDATION_FAILED")
p.write_text(result,encoding="utf8",errors="surrogateescape")
print("CATCHUP_FILE_PATCHED=yes")
PY
if ! cmp -s "$target" "$base/class.bazara.api.php";then CHANGED=yes;fi
docker exec vc-vesta php -l /var/www/html/wp-content/plugins/bazara/classes/class.bazara.api.php
grep -Fq 'VC_RECENT_BAZARA_CATCHUP_20261110' "$target"
for host in vesta-cosmetics.ir cutellashop.ir app.vesta-cosmetics.ir; do
  code=$(curl --noproxy '*' -ksS --connect-timeout 8 --max-time 25 --resolve "$host:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$host/")
  echo "AFTER_HOST=$host STATUS=$code"
  test "$code" = 200
done
FINISHED=yes
trap - EXIT
echo "BAZARA_BOUNDED_RECENT_REPLAY_PATCH_DEPLOYED=yes"
echo "HISTORICAL_REPLAY_PRE_2026_11_08_DISABLED=yes"
echo "BAZARA_CRON_INTERVAL_UNCHANGED=yes"
echo "BACKUP=$base"
