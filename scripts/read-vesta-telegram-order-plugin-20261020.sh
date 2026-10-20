#!/usr/bin/env bash
set -euo pipefail
P=/srv/vestacutella/runtime/vesta/wp-content/plugins/order-notification-for-telegram-bot
for entry in "includes/App.php:75:185" "includes/common/helper/WooCommerce.php:50:145" "includes/admin/OrdersSection.php:15:95" "includes/common/helper/TelegramBot.php:20:165" "includes/common/Shortcodes.php:5:115"; do
 IFS=: read -r f a b <<< "$entry"
 echo "=== PLUGIN_SOURCE $f ==="
 sed -n "$a,$b""p" "$P/$f" | cut -c1-230
done
docker exec vc-vesta php -d display_errors=0 -r '
require "/var/www/html/wp-load.php";
$statuses=get_option("onftb_order_statuses",[]);
echo "TELEGRAM_ORDER_STATUS_LIST=".implode(",",array_map(function($x){return preg_replace("/[^a-z0-9_-]/i","",(string)$x);},(array)$statuses))."\n";
foreach(["onftb_send_after_order_status_changed","onftb_setting_is_use_google_script"] as $k)echo "SETTING_BOOL ".$k." value=".preg_replace("/[^a-z0-9_-]/i","",(string)get_option($k,"unset"))."\n";
'
echo "SOURCE_AND_SETTINGS_COMPLETE"
