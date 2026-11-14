#!/usr/bin/env bash
# Vesta November 14: eliminate head-of-line blocking while preserving cloud dedup and single-order lock.
set -Eeuo pipefail
umask 077
target=/srv/vestacutella/runtime/vesta/wp-content/plugins/bazara/classes/class.bazara.api.php
base=/srv/backups/vesta-bazara-catchup-unblock-$(date -u +%Y%m%dT%H%M%SZ)
exec 9>/run/lock/vesta-bazara-recent-catchup-deploy.lock
flock -n 9 || { echo DEPLOY_LOCK_BUSY;exit 13; }
test -s "$target"
mkdir -p -m 0700 "$base"
cp -p "$target" "$base/class.bazara.api.php"
echo "BACKUP_SAVED=yes"
changed=no
verified=no
rollback() {
  rc=$?
  trap - EXIT
  if [[ "$changed" == yes && "$verified" != yes ]];then
    cp -p "$base/class.bazara.api.php" "$target"
    echo "BAZARA_CATCHUP_PATCH_ROLLED_BACK=yes"
  fi
  exit "$rc"
}
trap rollback EXIT
for host in vesta-cosmetics.ir cutellashop.ir app.vesta-cosmetics.ir;do
  code=$(curl --noproxy '*' -ksS --connect-timeout 8 --max-time 25 --resolve "$host:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$host/")
  echo "BEFORE_HOST=$host HTTP=$code"
  test "$code" = 200
done
TARGET="$target" python3 - <<'PY'
import os,pathlib,re
p=pathlib.Path(os.environ['TARGET'])
src=p.read_text(encoding='utf8',errors='surrogateescape')
oldmarker='VC_RECENT_BAZARA_CATCHUP_20261110'
marker='VC_CATCHUP_SKIP_UNMAPPED_AND_DEDUP_20261114'
if marker in src:
 print("CATCHUP_ROTATING_DEDUP_PATCH_ALREADY_INSTALLED=yes")
 raise SystemExit(0)
if src.count(oldmarker)!=1:raise SystemExit('OLD_CATCHUP_MARKER_NOT_UNIQUE')
m=re.search(r'public function start_sync_orders\(\$token\s*=\s*null\)\s*\{',src)
if not m:raise SystemExit('ORDER_SYNC_METHOD_MISSING')
start=m.end()
end=src.find('public function ',start)
if end<0:raise SystemExit('METHOD_BOUNDARY_MISSING')
block=src[start:end]
if 'VC_RECENT_BAZARA_CATCHUP_20261110' not in block: raise SystemExit('MISSING_EXISTING_PATCH_BLOCK')
if block.count('ORDER BY p.ID ASC LIMIT 1",')!=1: raise SystemExit('OLD_QUERY_NOT_UNIQUE')
if block.count('if (!empty($left_behind_orders)) {')<1: raise SystemExit('SELECTION_HOOK_MISSING')
if block.count('$all_orders = array_merge($left_behind_orders, $orders);')!=1: raise SystemExit('MERGE_ANCHOR_NOT_UNIQUE')
# Bounded scan only: previous query picked a single permanently unmappable old order forever.
block=block.replace('ORDER BY p.ID ASC LIMIT 1",','ORDER BY p.ID ASC LIMIT 250",',1)
needle='            if (!empty($left_behind_orders)) {'
replacement=r'''
            // VC_CATCHUP_SKIP_UNMAPPED_AND_DEDUP_20261114
            // Fail closed when cloud existence cannot be checked. Never retry an ambiguously accepted invoice.
            $vc_cloud = $this->get_all_data('', array('fromOrderVersion' => 5144000000));
            if (!is_array($vc_cloud) || empty($vc_cloud['success']) ||
                !is_array($vc_cloud['message']['Orders'] ?? null)) {
                error_log('VC_BAZARA_QUEUE_CLOUD_PREFLIGHT_FAILED');
                return array('success' => false, 'message' => 'Cloud order existence precheck unavailable');
            }
            $vc_cloud_clients = array();
            foreach ($vc_cloud['message']['Orders'] as $vc_cloud_order) {
                $vc_client = (int)($vc_cloud_order['OrderClientId'] ?? 0);
                $vc_remote_id = (int)($vc_cloud_order['OrderId'] ?? 0);
                if ($vc_client > 0 && $vc_remote_id > 0) $vc_cloud_clients[$vc_client] = true;
            }
            $vc_cursor = (int)get_option('vc_bazara_catchup_cursor_20261114', 0);
            $vc_after = array();
            $vc_before = array();
            foreach ($left_behind_orders as $vc_candidate_id) {
                $vc_candidate_id = (int)$vc_candidate_id;
                if (isset($vc_cloud_clients[$vc_candidate_id])) {
                    error_log('VC_BAZARA_QUEUE_ALREADY_IN_CLOUD order=' . $vc_candidate_id);
                    continue;
                }
                $vc_order = wc_get_order($vc_candidate_id);
                if (!$vc_order || !$vc_order->get_date_paid() || $vc_order->get_currency() !== 'IRT') continue;
                $vc_items = $vc_order->get_items('line_item');
                if (empty($vc_items)) continue;
                $vc_fully_mapped = true;
                foreach ($vc_items as $vc_item) {
                    $vc_pid = (int)($vc_item->get_variation_id() ?: $vc_item->get_product_id());
                    if ($vc_pid <= 0 ||
                        (int)get_post_meta($vc_pid, 'mahak_id', true) <= 0 ||
                        (int)get_post_meta($vc_pid, 'mahak_product_detail_id', true) <= 0) {
                        $vc_fully_mapped = false;
                        break;
                    }
                }
                if (!$vc_fully_mapped) continue;
                if ($vc_candidate_id > $vc_cursor) $vc_after[] = $vc_candidate_id;
                else $vc_before[] = $vc_candidate_id;
            }
            $vc_eligible = array_merge($vc_after, $vc_before);
            $left_behind_orders = empty($vc_eligible) ? array() : array((int)$vc_eligible[0]);
            if (!empty($left_behind_orders)) {
                // Advance even if the vendor sender fails, so one failed order never blocks the queue.
                update_option('vc_bazara_catchup_cursor_20261114', (int)$left_behind_orders[0], false);
            }
'''
qpos=block.index('ORDER BY p.ID ASC LIMIT 250",')
mergepos=block.index('$all_orders = array_merge($left_behind_orders, $orders);')
needlepos=block.find(needle,qpos,mergepos)
if needlepos<0: raise SystemExit('CATCHUP_SELECTION_HOOK_MISSING_AFTER_QUERY')
block=block[:needlepos]+replacement+block[needlepos:]
if block.count(marker)!=1:raise SystemExit('PATCH_VALIDATION_FAILED')
result=src[:start]+block+src[end:]
p.write_text(result,encoding='utf8',errors='surrogateescape')
print('PATCHED_ONE_SYNC_FUNCTION=yes')
PY
if ! cmp -s "$target" "$base/class.bazara.api.php";then changed=yes;fi
docker exec vc-vesta php -l /var/www/html/wp-content/plugins/bazara/classes/class.bazara.api.php
grep -Fq 'VC_CATCHUP_SKIP_UNMAPPED_AND_DEDUP_20261114' "$target"
for host in vesta-cosmetics.ir cutellashop.ir app.vesta-cosmetics.ir;do
  code=$(curl --noproxy '*' -ksS --connect-timeout 8 --max-time 25 --resolve "$host:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$host/")
  echo "AFTER_HOST=$host HTTP=$code"
  test "$code" = 200
done
verified=yes
trap - EXIT
echo "SAFE_CATCHUP_SELECTOR_DEPLOYED=yes"
echo "REMOTE_DUPLICATE_PREFLIGHT=enabled"
echo "UNMAPPED_ORDERS_SKIP_AND_ROTATE=enabled"
echo "SINGLE_ORDER_PER_CRON_UNCHANGED=yes"
echo "BEFORE_NOV8_REPLAY_UNCHANGED=yes"
