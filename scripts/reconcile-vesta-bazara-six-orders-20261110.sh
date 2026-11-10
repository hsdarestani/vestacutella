#!/usr/bin/env bash
# Reconcile ONLY five confirmed recent orders after exact product-variant repair.
# Never change order state, pricing, or stock. Stop immediately on any ambiguous result.
set -Eeuo pipefail
umask 077
exec 9>/run/lock/vesta-bazara-reconcile-20261110.lock
flock -n 9 || { echo RUNNER_ALREADY_ACTIVE;exit 11; }
db() { docker exec -i vc-db-vesta sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb -uroot -D "$MARIADB_DATABASE" --batch --raw --default-character-set=utf8mb4'; }
num() { printf '%s\n' "$1" | db | tail -1 | tr -d '\r'; }
echo "RUN_UTC=$(date -u +%FT%TZ)"
status=$(num "SELECT COALESCE(MAX(CAST(meta_value AS SIGNED)),0) FROM wp_postmeta WHERE post_id=105052 AND meta_key='mahak_id';")
ref=$(num "SELECT COUNT(*) FROM wp_bazara_orders WHERE OrderClientId=105052;")
echo "REFERENCE_ORDER_105052_REMOTE_ACK=$status CACHED_REF_COUNT=$ref"
[[ "$status" =~ ^[0-9]+$ ]] && (( status>0 )) && (( ref>0 )) || { echo FIRST_ORDER_NOT_VERIFIED;exit 12; }
for expected in 105053 105204 105205 105206 105207;do
  echo "===== ORDER=$expected ====="
  ack=$(num "SELECT COALESCE(MAX(CAST(meta_value AS SIGNED)),0) FROM wp_postmeta WHERE post_id=$expected AND meta_key='mahak_id';")
  cached=$(num "SELECT COUNT(*) FROM wp_bazara_orders WHERE OrderClientId=$expected;")
  if [[ "$ack" =~ ^[0-9]+$ ]] && ((ack>0));then
    echo "ORDER=$expected STATUS=confirmed_positive_remote_ack ERP_ENTITY=$ack CACHED=$cached"
    continue
  fi
  if [[ "$ack" != 0 || "$cached" != 0 ]];then
    echo "ORDER=$expected ERROR=ambiguous_partial_ack NO_RETRY=yes"
    exit 13
  fi
  # The hotfix selects the oldest unmarked recent order, so verify selection order
  # and never skip a failed submission to send a newer one blindly.
  first=$(num "SELECT COALESCE(MIN(p.ID),0) FROM wp_posts p
    LEFT JOIN wp_postmeta m ON m.post_id=p.ID AND m.meta_key='mahak_id' AND CAST(m.meta_value AS SIGNED)>0
    LEFT JOIN wp_bazara_orders b ON b.OrderClientId=p.ID
    WHERE p.post_type='shop_order'
      AND p.post_date_gmt>='2026-11-08 00:00:00'
      AND p.post_status IN ('wc-completed','wc-processing','wc-processing5','wc-pws-packaged','wc-pws-shipping','wc-arrival-shipment')
      AND m.meta_id IS NULL AND b.OrderClientId IS NULL;")
  echo "EARLIEST_UNCONFIRMED_ELIGIBLE=$first"
  [[ "$first" == "$expected" ]] || { echo "ORDER=$expected ERROR=priority_mismatch STOP=yes";exit 14; }
  order_status=$(num "SELECT COUNT(*) FROM wp_posts WHERE ID=$expected AND post_type='shop_order' AND post_status='wc-processing';")
  [[ "$order_status" == 1 ]] || { echo "ORDER=$expected ERROR=unexpected_status";exit 15; }
  docker exec -i vc-vesta php -d display_errors=0 -d memory_limit=384M <<'PHP'
<?php
$_SERVER['HTTP_HOST']='vesta-cosmetics.ir';
$_SERVER['SERVER_NAME']='vesta-cosmetics.ir';
$_SERVER['HTTPS']='on';
$_SERVER['SERVER_PORT']='443';
$_SERVER['REQUEST_URI']='/wp-cron.php';
require '/var/www/html/wp-load.php';
if(!has_action('bazara_run_sending_orders')){echo "HOOK_MISSING\n";exit(20);}
$result=wp_schedule_single_event(time()-1,'bazara_run_sending_orders',[],true);
if(is_wp_error($result)||$result===false){echo "HOOK_SCHEDULE_FAIL\n";exit(21);}
echo "BAZARA_HOOK_QUEUED=yes\n";
PHP
  http=$(curl --noproxy '*' -kLsS --connect-timeout 10 --max-time 120 --resolve vesta-cosmetics.ir:443:127.0.0.1 -o /dev/null -w '%{http_code}' https://vesta-cosmetics.ir/wp-cron.php)
  echo "WP_CRON_HTTP=$http"
  [[ "$http" == 200 ]] || { echo "ORDER=$expected ERROR=HTTP_CRON_FAILURE";exit 16; }
  confirmed=no
  for attempt in $(seq 1 18);do
    sleep 5
    ack=$(num "SELECT COALESCE(MAX(CAST(meta_value AS SIGNED)),0) FROM wp_postmeta WHERE post_id=$expected AND meta_key='mahak_id';")
    cached=$(num "SELECT COUNT(*) FROM wp_bazara_orders WHERE OrderClientId=$expected;")
    if [[ "$ack" =~ ^[0-9]+$ ]] && ((ack>0));then confirmed=yes;break;fi
    if [[ "$ack" != 0 || "$cached" != 0 ]];then
      echo "ORDER=$expected ERROR=partial_confirmation ACK=$ack CACHED=$cached STOP=yes"
      exit 17
    fi
  done
  echo "ORDER=$expected CONFIRMED=$confirmed ACK=$ack CACHED=$cached"
  if [[ "$confirmed" != yes ]];then
    echo "ORDER=$expected ERROR=not_confirmed_without_retry STOP=yes"
    exit 18
  fi
done
echo '===== FINAL SIX RECENT ORDER ACKS ====='
cat <<'SQL' | db
SELECT p.ID, COALESCE(MAX(CASE WHEN m.meta_key='mahak_id' THEN CAST(m.meta_value AS SIGNED) END),0) ERP_ID,
       (SELECT COUNT(*) FROM wp_bazara_orders b WHERE b.OrderClientId=p.ID) CACHED_COUNT
FROM wp_posts p LEFT JOIN wp_postmeta m ON m.post_id=p.ID AND m.meta_key='mahak_id'
WHERE p.ID IN (105052,105053,105204,105205,105206,105207)
GROUP BY p.ID ORDER BY p.ID;
SQL
echo "SIX_ORDER_RECONCILIATION_COMPLETE=yes"
