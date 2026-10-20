#!/usr/bin/env bash
# Deploy autonomous admin-only Telegram catch-up for Vesta orders containing Cutella catalog items.
set -euo pipefail
umask 077
SRC=/tmp/vesta-cutella-telegram-order-worker-20261020.php
DEST=/srv/vestacutella/repo/scripts/vesta-cutella-telegram-order-worker-20261020.php
CRON=/etc/cron.d/vesta-cutella-telegram-orders
BACKUP="/srv/backups/vesta-cutella-telegram-orders-$(date -u +%Y%m%dT%H%M%SZ)"
test -s "$SRC"
test ! -e "$CRON" || { echo "CUTELLA_TG_CRON_ALREADY_EXISTS_ABORT"; exit 10; }
test ! -e "$DEST" || { echo "CUTELLA_TG_WORKER_ALREADY_EXISTS_ABORT"; exit 11; }
systemctl is-active --quiet cron || exit 12
systemctl is-active --quiet vesta-telegram-strato-tunnel || exit 13
http(){ curl --noproxy '*' -kLsS --max-time 30 --resolve "$1:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$1$2"; }
for site in vesta-cosmetics.ir cutellashop.ir app.vesta-cosmetics.ir;do
 c="$(http "$site" /)"
 echo "BEFORE $site $c"
 [[ "$c" == 200 ]] || exit 14
done
mkdir -p "$BACKUP";chmod 700 "$BACKUP"
cp -p "$SRC" "$BACKUP/worker.php"
created=0
enabled=0
complete=0
rollback(){
 rc=$?
 trap - EXIT
 if [[ "$complete" != 1 ]];then
  echo "CUTELLA_ORDER_BOT_DEPLOY_ROLLBACK rc=$rc"
  rm -f "$CRON"
  if [[ "$created" == 1 ]];then rm -f "$DEST";fi
  if [[ "$enabled" == 1 ]];then
   docker exec -u www-data vc-vesta php -d display_errors=0 -r 'require "/var/www/html/wp-load.php";delete_option("vc_vesta_cutella_order_telegram_active_since_20261020");' >/dev/null 2>&1 || true
  fi
 fi
 exit "$rc"
}
trap rollback EXIT
install -m 644 "$SRC" "$DEST"
created=1
docker exec -u www-data -i vc-vesta php -d display_errors=0 -l < "$DEST"
echo "=== CUTELLA_ORDER_BOT_DRY_RUN ==="
docker exec -u www-data -i vc-vesta php -d display_errors=0 -- --dry-run < "$DEST"
docker exec -u www-data vc-vesta php -d display_errors=0 -r '
require "/var/www/html/wp-load.php";
$k="vc_vesta_cutella_order_telegram_active_since_20261020";
if(get_option($k,false)!==false){echo "ALREADY_ENABLED_ABORT\n";exit(21);}
$token=(string)get_option("onftb_setting_token","");
$ids=array_values(array_filter(array_map("trim",explode(",",(string)get_option("onftb_setting_chatid","")))));
if(!preg_match("/^[0-9]{6,}:[a-zA-Z0-9_-]{25,}$/D",$token) || count($ids)<1 || count($ids)>5)exit(22);
if(!add_option($k,time(),"",false))exit(23);
echo "CUTELLA_TG_WORKER_ENABLED_UTC=".gmdate("c")." chats=".count($ids)."\n";
'
enabled=1
cat > "$CRON" <<'CRONTAB'
* * * * * root /usr/bin/flock -n /run/lock/vesta-cutella-telegram-orders.lock /usr/bin/timeout 115 /bin/bash -c '/usr/bin/docker exec -u www-data -i vc-vesta php -d display_errors=0 -- --send < /srv/vestacutella/repo/scripts/vesta-cutella-telegram-order-worker-20261020.php' >>/var/log/vesta-cutella-telegram-orders.log 2>&1
CRONTAB
chmod 644 "$CRON"
grep -Fq '* * * * * root /usr/bin/flock' "$CRON"
# Cron detects /etc/cron.d updates automatically. Don't restart any store service.
echo "=== FIRST_PROCESSING_PASS ==="
# Prevent concurrent minute cron while first sending. Failed chats will retry next minute.
flock -n /run/lock/vesta-cutella-telegram-orders.lock timeout 115 bash -c '/usr/bin/docker exec -u www-data -i vc-vesta php -d display_errors=0 -- --send < /srv/vestacutella/repo/scripts/vesta-cutella-telegram-order-worker-20261020.php' || echo "FIRST_PASS_PARTIAL_OR_BUSY_RETRY_BY_CRON"
for site in vesta-cosmetics.ir cutellashop.ir app.vesta-cosmetics.ir;do
 c="$(http "$site" /)";echo "AFTER $site $c"
 [[ "$c" == 200 ]] || exit 40
done
for p in /shop/ /cart/ /checkout/ /my-account/ /wp-login.php;do
 c="$(http vesta-cosmetics.ir "$p")"
 echo "VESTA_PATH $p $c"
 [[ "$c" == 200 || "$c" == 301 || "$c" == 302 ]] || exit 41
done
complete=1
trap - EXIT
echo "VESTA_CUTELLA_ORDER_TELEGRAM_DEPLOYED scan=once_per_minute only_imported_or_mixed=yes"
