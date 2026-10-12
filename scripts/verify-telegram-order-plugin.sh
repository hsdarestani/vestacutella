#!/usr/bin/env bash
set -euo pipefail
echo '=== Telegram plugin static hooks (no settings values) ==='
PL=/srv/vestacutella/runtime/vesta/wp-content/plugins/order-notification-for-telegram-bot
F="$PL/includes/common/helper/TelegramBot.php"
if [[ -f "$F" ]];then
 grep -nE '(function |wp_remote_post|api.telegram.org|wp_remote_get)' "$F" | sed -E 's#(https://api.telegram.org/bot)[^/ "'\''{}]+#\1[redacted]#g' | head -n 55
fi
echo '=== WordPress bot settings keys and configured recipient status ==='
docker exec vc-vesta php -d display_errors=0 -r '
require "/var/www/html/wp-load.php";
global $wpdb;
$names=$wpdb->get_col("SELECT option_name FROM {$wpdb->options} WHERE option_name LIKE \"%onftb%\" OR option_name LIKE \"%telegram%\" OR option_name LIKE \"%bot_%\" ORDER BY option_name LIMIT 120");
foreach($names as $name){$v=get_option($name,null);
echo "option=".preg_replace("/[^A-Za-z0-9_-]/","",$name)." type=".gettype($v)." populated=".(!empty($v)?"yes":"no")."\n";
if(is_array($v))foreach($v as $k=>$vv){
  echo "option_field=".preg_replace("/[^a-z0-9_-]/i","",(string)$k)." type=".gettype($vv)." populated=".(!empty($vv)?"yes":"no")."\n";
}
}
'
echo '=== Non-mutating bot network verification ==='
docker exec vc-vesta php -d display_errors=0 -r '
require "/var/www/html/wp-load.php";
$u="https://api.telegram.org/";
$r=wp_remote_get($u,array("timeout"=>12,"redirection"=>0));
echo "bot_api_network=". (is_wp_error($r)?$r->get_error_code():wp_remote_retrieve_response_code($r))."\n";
'
echo '=== Ensure SSH service and site remain healthy ==='
systemctl is-active vesta-telegram-strato-tunnel
for p in / /my-account/ /shop/; do
  curl -ksS --max-time 28 --resolve vesta-cosmetics.ir:443:127.0.0.1 -o /dev/null -w "$p HTTP=%{http_code}\n" "https://vesta-cosmetics.ir$p"
done
echo BOT_ORDER_PLUGIN_AUDIT_OK
