#!/usr/bin/env bash
# Deploy isolated WooCommerce admin mail watchdog and queued Telegram stock alerts.
# No stock/order changes, no emails to customers, no PHP/DB container restarts.
set -euo pipefail
umask 077
RUNTIME=/srv/vestacutella/runtime/vesta
MU="$RUNTIME/wp-content/mu-plugins"
ORDER="$MU/vc-vesta-order-mail-watchdog.php"
STOCK="$MU/vc-vesta-stock-telegram.php"
SRC_ORDER=/tmp/vc-vesta-order-mail-watchdog.php
SRC_STOCK=/tmp/vc-vesta-stock-telegram.php
BACKUP="/srv/backups/vesta-order-mail-stock-$(date -u +%Y%m%dT%H%M%SZ)"
http(){ curl --noproxy '*' -kLsS --max-time 28 --resolve "$1:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$1$2"; }
test -s "$SRC_ORDER" && test -s "$SRC_STOCK"
test -d "$MU"
[[ ! -e "$ORDER" && ! -e "$STOCK" ]] || { echo "ABORT_EXISTING_RUNTIME_HELPER";exit 11; }
systemctl is-active --quiet cron || { echo "CRON_INACTIVE";exit 12; }
systemctl is-active --quiet vesta-telegram-strato-tunnel || { echo "TELEGRAM_TUNNEL_INACTIVE";exit 13; }
for domain in vesta-cosmetics.ir cutellashop.ir app.vesta-cosmetics.ir;do
 code="$(http "$domain" /)"
 echo "PRECHECK $domain HTTP=$code"
 [[ "$code" == 200 ]] || exit 14
done
echo "=== CORE_EMAIL_HOOK_COMPATIBILITY ==="
# Native WooCommerce marks accepted new order mail using this action.
grep -Rqs 'woocommerce_email_sent' "$RUNTIME/wp-content/plugins/woocommerce/includes/emails/class-wc-email.php" || { echo "ABORT_WOO_MAIL_SENT_HOOK_MISSING";exit 15; }
echo "WOO_EMAIL_SENT_HOOK_PRESENT"
docker exec vc-vesta php -d display_errors=0 -r '
require "/var/www/html/wp-load.php";
if (!function_exists("wc_get_product")||!function_exists("wc_get_orders"))exit(20);
$o=get_option("wp_mail_smtp",[]);$smtp=(array)($o["smtp"]??[]);
if(($smtp["host"]??"")!=="server135s.irwebspace.com"||($smtp["encryption"]??"")!=="tls"||(int)($smtp["port"]??0)!==587)exit(21);
$token=(string)get_option("onftb_setting_token","");
$chat=(string)get_option("onftb_setting_chatid","");
if(!preg_match("/^[0-9]{6,}:[A-Za-z0-9_-]{25,}$/",$token))exit(22);
$dest=array_values(array_filter(array_map("trim",explode(",",$chat))));
if(count($dest)<1||count($dest)>5)exit(23);
foreach($dest as $d)if(!preg_match("/^-?[0-9]{3,20}$/",$d))exit(24);
$m=WC()->mailer()->get_emails();$e=null;
foreach($m as $x)if(($x->id??"")==="new_order")$e=$x;
if(!$e||!$e->is_enabled()||count(array_filter(explode(",",$e->get_recipient())))!==1)exit(25);
echo "PRECHECK_WOO_SMTP_TLS_BOT_OK chat_count=".count($dest)."\n";
'
mkdir -p "$BACKUP";chmod 700 "$BACKUP"
changed=0
start_set=0
finished=0
rollback(){
 rc=$?
 trap - EXIT
 if [[ "$changed" == 1 && "$finished" != 1 ]];then
  echo "ORDER_MAIL_STOCK_ROLLBACK code=$rc"
  rm -f "$ORDER" "$STOCK"
  if [[ "$start_set" == 1 ]];then
    docker exec vc-vesta php -d display_errors=0 -r 'require "/var/www/html/wp-load.php";delete_option("vc_vesta_order_mail_watchdog_start");' >/dev/null 2>&1 || true
  fi
 fi
 exit "$rc"
}
trap rollback EXIT
changed=1
install -m 644 "$SRC_ORDER" "$ORDER"
install -m 644 "$SRC_STOCK" "$STOCK"
chown 33:33 "$ORDER" "$STOCK"
docker exec vc-vesta php -l /var/www/html/wp-content/mu-plugins/vc-vesta-order-mail-watchdog.php
docker exec vc-vesta php -l /var/www/html/wp-content/mu-plugins/vc-vesta-stock-telegram.php
echo "=== RUNTIME_HOOKS_AND_ONE_TELEGRAM_TEST ==="
docker exec vc-vesta php -d display_errors=0 -r '
require "/var/www/html/wp-load.php";
foreach(["vc_vesta_order_mail_retry","vc_vesta_stock_bot_send","vc_vesta_stock_bot_queue","vc_vesta_stock_bot_dispatch"] as $f)if(!function_exists($f)){echo "RUNTIME_MISSING_FUNCTION\n";exit(31);}
foreach(["vc_vesta_admin_new_order_watchdog","woocommerce_email_sent","woocommerce_new_order","woocommerce_product_set_stock","woocommerce_variation_set_stock","woocommerce_product_set_stock_status","vc_vesta_stock_bot_dispatch"] as $hook)if(!has_action($hook)){echo "MISSING_HOOK ".preg_replace("/[^a-z_]/i","",$hook)."\n";exit(32);}
echo "ORDER_AND_STOCK_HOOKS_REGISTERED\n";
$txt="✅ ربات موجودی وستا فعال شد.\nاز این پس برای محصول ناموجود و محصولی که فقط ۲ عدد از آن مانده، در همین گفتگو هشدار ارسال می‌شود.\nاین یک پیام آزمایشی است و موجودی هیچ محصولی تغییر نکرده.";
$ok=vc_vesta_stock_bot_send($txt,0,"test");
echo "TELEGRAM_STOCK_TEST_ACCEPTED=".($ok?"yes":"no")."\n";
if(!$ok)exit(33);
'
echo "=== ENABLE_WATCHDOG_FOR_NEW_ORDERS_ONLY ==="
docker exec vc-vesta php -d display_errors=0 -r '
require "/var/www/html/wp-load.php";
$key="vc_vesta_order_mail_watchdog_start";
if(get_option($key,false)!==false){echo "WATCHDOG_ALREADY_INITIALIZED_ABORT\n";exit(41);}
$now=time();
if(!add_option($key,$now,"","no"))exit(42);
echo "WATCHDOG_ENABLED_AT_UTC=".gmdate("Y-m-d H:i:s",$now)."\n";
'
start_set=1
for domain in vesta-cosmetics.ir cutellashop.ir app.vesta-cosmetics.ir;do
 code="$(http "$domain" /)"
 echo "POSTCHECK $domain HTTP=$code"
 [[ "$code" == 200 ]] || exit 45
done
for path in /shop/ /cart/ /checkout/ /my-account/ /wp-login.php;do
 code="$(http vesta-cosmetics.ir "$path")"
 echo "VESTA_ROUTE $path HTTP=$code"
 [[ "$code" == 200 || "$code" == 301 || "$code" == 302 ]] || exit 46
done
finished=1
trap - EXIT
echo "VESTA_ORDER_MAIL_AND_STOCK_BOT_DEPLOYED admin_email_watchdog=enabled low_stock_threshold=2"
