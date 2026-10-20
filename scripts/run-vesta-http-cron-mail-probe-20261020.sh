#!/usr/bin/env bash
# One safe wp-cron HTTP mail context probe; one admin-only test, no real order touched.
set -euo pipefail
umask 077
SOURCE=/tmp/vesta-http-cron-mail-probe-20261020.php
LIVE=/srv/vestacutella/runtime/vesta/wp-content/mu-plugins/vc-mail-probe-oct20.php
test -s "$SOURCE"
test ! -e "$LIVE" || { echo "PROBE_ALREADY_PRESENT_ABORT";exit 11; }
trap 'rm -f "$LIVE"; docker exec vc-vesta php -d display_errors=0 -r '\''require "/var/www/html/wp-load.php";wp_clear_scheduled_hook("vc_vesta_internal_mail_context_probe_20261020");'\'' >/dev/null 2>&1 || true' EXIT
install -m 644 "$SOURCE" "$LIVE"
chown 33:33 "$LIVE"
docker exec vc-vesta php -l /var/www/html/wp-content/mu-plugins/vc-mail-probe-oct20.php
docker exec vc-vesta php -d display_errors=0 -r '
require "/var/www/html/wp-load.php";
$key="vc_vesta_mail_context_result_20261020";
if(get_option($key,false)!==false){echo "PREEXISTING_PROBE_RESULT_ABORT\n";exit(12);}
$ok=wp_schedule_single_event(time()-2,"vc_vesta_internal_mail_context_probe_20261020");
echo "ONE_SHOT_CRON_SCHEDULED=".($ok?"yes":"no")."\n";
if(!$ok)exit(13);
'
for i in 1 2 3 4 5 6 7;do
 code="$(curl --noproxy '*' -kLsS --max-time 95 --resolve vesta-cosmetics.ir:443:127.0.0.1 -o /dev/null -w '%{http_code}' 'https://vesta-cosmetics.ir/wp-cron.php?doing_wp_cron=vc_mail_debug' || true)"
 echo "HTTP_CRON_TRIGGER attempt=$i code=$code"
 result="$(docker exec vc-vesta php -d display_errors=0 -r 'require "/var/www/html/wp-load.php";$v=get_option("vc_vesta_mail_context_result_20261020",false);echo (is_array($v)?($v["state"]??"unknown"):"none");' 2>/dev/null || true)"
 echo "PROBE_STATUS=$result"
 if [[ "$result" == finished ]];then break;fi
 sleep 4
done
docker exec vc-vesta php -d display_errors=0 -r '
require "/var/www/html/wp-load.php";$v=get_option("vc_vesta_mail_context_result_20261020",false);
if(!is_array($v)||($v["state"]??"")!=="finished"){echo "HTTP_MAIL_PROBE_INCOMPLETE\n";exit(21);}
foreach($v as $k=>$value)echo "HTTP_MAIL_CONTEXT_".preg_replace("/[^a-z0-9_]/i","",$k)."=".preg_replace("/[^a-z0-9_:-]/i","",(string)$value)."\n";
delete_option("vc_vesta_mail_context_result_20261020");
'
echo "HTTP_MAIL_CONTEXT_PROBE_FINISHED"
