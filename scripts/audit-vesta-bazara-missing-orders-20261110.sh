#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C
echo "CHECK_UTC=$(date -u +%FT%TZ)"
echo "CRON_ACTIVE=$(systemctl is-active cron)"
echo "BAZARA_PLUGIN=$(test -d /srv/vestacutella/runtime/vesta/wp-content/plugins/bazara && echo present || echo missing)"
echo "PATCH_PRESENT=$(grep -c 'vc_bazara_defer_historical_backfill' /srv/vestacutella/runtime/vesta/wp-content/plugins/bazara/classes/class.bazara.api.php || true)"
db() { docker exec -i vc-db-vesta sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb -uroot -D "$MARIADB_DATABASE" --batch --raw --default-character-set=utf8mb4'; }
echo '===== RECENT ORDER SYNC STATUS ====='
cat <<'SQL' | db
SELECT p.ID, p.post_date_gmt, p.post_status,
       CASE WHEN EXISTS (SELECT 1 FROM wp_postmeta pm WHERE pm.post_id=p.ID AND pm.meta_key='mahak_id' AND pm.meta_value<>'') THEN 'marked_synced' ELSE 'unmarked' END as sync_status,
       CASE WHEN EXISTS (SELECT 1 FROM wp_bazara_orders b WHERE b.OrderId=p.ID OR b.OrderCode=p.ID) THEN 'local_bazara_order_found' ELSE 'none_local' END AS bazara_reference
FROM wp_posts p WHERE p.post_type='shop_order' AND p.post_date_gmt >= UTC_TIMESTAMP() - INTERVAL 21 DAY
ORDER BY p.ID DESC LIMIT 65;
SELECT 'LAST_7_DAYS_UNMARKED',
 COUNT(*) FROM wp_posts p
 WHERE p.post_type='shop_order' AND p.post_status IN ('wc-completed','wc-processing','wc-processing5','wc-pws-packaged','wc-pws-shipping','wc-arrival-shipment')
 AND p.post_date_gmt >= UTC_TIMESTAMP()-INTERVAL 7 DAY
 AND NOT EXISTS (SELECT 1 FROM wp_postmeta pm WHERE pm.post_id=p.ID AND pm.meta_key='mahak_id');
SELECT 'LAST_30_DAYS_UNMARKED',
 COUNT(*) FROM wp_posts p
 WHERE p.post_type='shop_order' AND p.post_status IN ('wc-completed','wc-processing','wc-processing5','wc-pws-packaged','wc-pws-shipping','wc-arrival-shipment')
 AND p.post_date_gmt >= UTC_TIMESTAMP()-INTERVAL 30 DAY
 AND NOT EXISTS (SELECT 1 FROM wp_postmeta pm WHERE pm.post_id=p.ID AND pm.meta_key='mahak_id');
SELECT 'BAZARA_STORED_LINKS',COUNT(DISTINCT OrderId),COUNT(DISTINCT OrderCode),COUNT(*) FROM wp_bazara_orders;
SELECT status,COUNT(*),MAX(last_attempt_gmt) FROM wp_actionscheduler_actions WHERE hook='bazara_run_sending_orders' GROUP BY status;
SQL
echo '===== BAZARA CONFIG CURSORS ====='
db <<'SQL' | docker exec -i vc-vesta php -r '
$s=trim(stream_get_contents(STDIN));$v=@unserialize(base64_decode(preg_replace("/\s+/","",implode("",array_slice(explode("\n",$s),1)))),["allowed_classes"=>false]);foreach(["order_id_greater_than","left_behind_sync_limit"] as $k){echo "$k=".(isset($v[$k])?(int)$v[$k]:"unset")."\n";}'
SELECT TO_BASE64(option_value) FROM wp_options WHERE option_name='bazara_visitor_settings' LIMIT 1;
SQL
echo '===== BAZARA RELEVANT CODE LINES (SANITIZED) ====='
python3 - <<'PY'
import re
p='/srv/vestacutella/runtime/vesta/wp-content/plugins/bazara/classes/class.bazara.api.php'
l=open(p,encoding='utf-8',errors='ignore').read().splitlines()
for i in range(2750,min(3850,len(l))):
 s=l[i]
 if re.search(r'mahak_id|bazara_save_order|order_id|OrderId|order_code|save_order|set_all_data|update_meta_data|http_post|return array|return \[|is_wp_error|status_code|result|response|insert|already|duplicate|success',s,re.I):
  s=re.sub(r'(["\x27])https?://.*?\1',r'\1[URL]\1',s)
  s=re.sub(r'(token|password|secret|api[_-]?key)\s*(=|=>)\s*[^,;)]+',r'\1\2[REDACTED]',s,flags=re.I)
  s=re.sub(r'([0-9]{8,})','[NUMBER]',s)
  print(i+1,re.sub(r'\s+',' ',s).strip()[:185])
PY
echo '===== HELPER MARKER LINES ====='
grep -Rn 'function get_left_behind_orders_from_limit\|function get_orders(\|mahak_id' /srv/vestacutella/runtime/vesta/wp-content/plugins/bazara/classes/functions.php | head -28 || true
echo AUDIT_FINISHED=yes
