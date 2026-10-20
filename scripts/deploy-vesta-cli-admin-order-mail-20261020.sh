#!/usr/bin/env bash
# Install low-volume CLI-based admin new-order email transport for Vesta only.
set -euo pipefail
umask 077
SRC=/tmp/vesta-admin-order-mail-cli-worker-20261020.php
DEST=/srv/vestacutella/repo/scripts/vesta-admin-order-mail-cli-worker-20261020.php
CRON=/etc/cron.d/vesta-admin-order-mail-cli
SAVE="/srv/backups/vesta-cli-admin-email-$(date -u +%Y%m%dT%H%M%SZ)"
test -s "$SRC"
test ! -e "$CRON" || { echo "CLI_MAIL_CRON_ALREADY_EXISTS_ABORT";exit 10; }
test ! -e "$DEST" || { echo "CLI_MAIL_WORKER_ALREADY_EXISTS_ABORT";exit 11; }
systemctl is-active --quiet cron || { echo "SYSTEM_CRON_INACTIVE";exit 12; }
status(){ curl --noproxy '*' -kLsS --max-time 30 --resolve "$1:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$1$2"; }
for d in vesta-cosmetics.ir cutellashop.ir app.vesta-cosmetics.ir;do
 r="$(status "$d" /)";echo "PRECHECK $d $r";[[ "$r" == 200 ]] || exit 13
done
mkdir -m 700 -p "$SAVE"
cp -p "$SRC" "$SAVE/worker.php"
new=0;enabled=0;finished=0
rollback(){
 rc=$?
 trap - EXIT
 if [[ "$finished" != 1 ]];then
  echo "CLI_ADMIN_ORDER_MAIL_ROLLBACK rc=$rc"
  rm -f "$CRON"
  if [[ "$new" == 1 ]];then rm -f "$DEST";fi
  if [[ "$enabled" == 1 ]];then docker exec -u www-data vc-vesta php -d display_errors=0 -r 'require "/var/www/html/wp-load.php";delete_option("vc_vesta_cli_admin_mail_start_20261020");' >/dev/null 2>&1 || true;fi
  systemctl reload cron 2>/dev/null || true
 fi
 exit "$rc"
}
trap rollback EXIT
install -m 600 "$SRC" "$DEST"
new=1
docker exec -u www-data -i vc-vesta php -d display_errors=0 -l < "$DEST"
docker exec -u www-data vc-vesta php -d display_errors=0 -r '
require "/var/www/html/wp-load.php";
if(get_option("vc_vesta_cli_admin_mail_start_20261020",false)!==false){echo "EXISTING_ACTIVATION_ABORT\n";exit(21);}
$s=get_option("wp_mail_smtp",[]);$c=(array)($s["smtp"]??[]);
if(($c["encryption"]??"")!=="ssl"||(int)($c["port"]??0)!==465){echo "SMTP_SSL_CONFIG_INVALID\n";exit(22);}
if(!function_exists("WC"))exit(23);
echo "MAIL_CLI_START_PREFLIGHT_OK\n";
'
docker exec -u www-data vc-vesta php -d display_errors=0 -r '
require "/var/www/html/wp-load.php";
$t=time();
if(!add_option("vc_vesta_cli_admin_mail_start_20261020",$t,"",false))exit(30);
echo "CLI_ORDER_MAIL_START_UTC=".gmdate("c",$t)."\n";
'
enabled=1
docker exec -u www-data -e VC_VESTA_MAIL_DRY_RUN=1 -i vc-vesta php -d display_errors=0 < "$DEST"
# One-minute worker with lock; does NOT touch Cutella, Nginx, emails to customers, or site sessions.
cat >"$CRON" <<'CRONTAB'
* * * * * root /usr/bin/flock -n /run/lock/vesta-admin-order-mail-cli.lock /usr/bin/timeout 100 /bin/bash -c '/usr/bin/docker exec -u www-data -i vc-vesta php -d display_errors=0 < /srv/vestacutella/repo/scripts/vesta-admin-order-mail-cli-worker-20261020.php' >>/var/log/vesta-admin-order-mail-cli.log 2>&1
CRONTAB
chmod 644 "$CRON"
grep -Fq '* * * * * root /usr/bin/flock' "$CRON"
systemctl reload cron 2>/dev/null || systemctl restart cron
# Initial no-op smoke test; only eligible orders created after activation may send.
docker exec -u www-data -i vc-vesta php -d display_errors=0 < "$DEST"
for d in vesta-cosmetics.ir cutellashop.ir app.vesta-cosmetics.ir;do
 r="$(status "$d" /)";echo "POSTCHECK $d $r";[[ "$r" == 200 ]] || exit 40
done
for p in /shop/ /cart/ /checkout/ /my-account/ /wp-login.php;do
 r="$(status vesta-cosmetics.ir "$p")";echo "VESTA_ROUTE $p $r"
 [[ "$r" == 200 || "$r" == 301 || "$r" == 302 ]] || exit 41
done
finished=1;trap - EXIT
echo "VESTA_CLI_ADMIN_MAIL_WORKER_ACTIVE cron=once_per_minute created_after_activation_only=yes backup=$SAVE"
