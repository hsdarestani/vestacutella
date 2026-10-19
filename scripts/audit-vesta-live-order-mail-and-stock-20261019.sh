#!/usr/bin/env bash
# Read-only order-trigger and Telegram-stock preflight, no secrets/order data in output.
set -uo pipefail
echo "CHECK_UTC=$(date -u +%FT%TZ)"
echo "=== MAIL_TRANSPORT_AND_LOGS ==="
docker exec vc-vesta php -d display_errors=0 -r '
require "/var/www/html/wp-load.php";
global $wpdb;
$s=get_option("wp_mail_smtp",[]);
$c=(array)($s["smtp"]??[]);
echo "SMTP_STATE host=".preg_replace("/[^a-z0-9.-]/i","",(string)($c["host"]??""))." port=".(int)($c["port"]??0)." tls=".preg_replace("/[^a-z0-9_-]/i","",(string)($c["encryption"]??""))."\n";
$e=WC()->mailer()->get_emails();$new=null;
foreach($e as $item)if(($item->id??"")==="new_order")$new=$item;
echo "NEW_ORDER_ENABLED=".($new&&$new->is_enabled()?"yes":"no")." recipients=".($new?count(array_filter(explode(",",$new->get_recipient()))):0)."\n";
foreach(["woocommerce_new_order","woocommerce_order_status_processing","woocommerce_order_status_pending_to_processing_notification","woocommerce_order_status_on-hold_to_processing_notification","woocommerce_order_status_completed_notification","woocommerce_email_enabled_new_order","woocommerce_email_recipient_new_order","pre_wp_mail","wp_mail","phpmailer_init"] as $name){
 $h=$GLOBALS["wp_filter"][$name]??null;
 $count=0;if($h)foreach($h->callbacks as $group)$count+=count($group);
 echo "HOOK ".$name."=".$count."\n";
}
$tbl=$wpdb->prefix."wpmailsmtp_debug_events";
if($wpdb->get_var($wpdb->prepare("SHOW TABLES LIKE %s",$tbl))===$tbl){
  foreach($wpdb->get_results("SELECT DATE_FORMAT(created_at, \"%Y-%m-%d %H:00\") bucket,event_type,COUNT(*) n FROM $tbl WHERE created_at >= UTC_TIMESTAMP()-INTERVAL 6 HOUR GROUP BY bucket,event_type ORDER BY bucket DESC",ARRAY_A) as $r){
    echo "MAIL_EVENT_BUCKET utc=".$r["bucket"]." event_type=".(int)$r["event_type"]." n=".(int)$r["n"]."\n";
  }
}
$store=wc_get_container()->get("\\Automattic\\WooCommerce\\Utilities\\OrderUtil");
echo "HPOS_ENABLED=".($store::custom_orders_table_usage_is_enabled()?"yes":"no")."\n";
$orders=wc_get_orders(["limit"=>20,"orderby"=>"date","order"=>"DESC","type"=>"shop_order"]);
$n=0;
foreach($orders as $order) {
 if(!$order)continue;$date=$order->get_date_created();
 $st=$order->get_status();
 echo "RECENT_ORDER index=".$n." created_utc=".($date?$date->date("Y-m-d H:i:s"):"unknown")." status=".preg_replace("/[^a-z0-9_-]/i","",$st)." payment_method=".preg_replace("/[^a-z0-9_-]/i","",(string)$order->get_payment_method())." created_via=".preg_replace("/[^a-z0-9_-]/i","",(string)$order->get_created_via())."\n";$n++;
}
echo "WC_STOCK_OPTIONS low_stock_threshold=".get_option("woocommerce_notify_low_stock_amount","unset")." low_stock_notify=".get_option("woocommerce_notify_low_stock","unset")." no_stock_notify=".get_option("woocommerce_notify_no_stock","unset")."\n";
foreach(["woocommerce_low_stock","woocommerce_no_stock","woocommerce_product_set_stock","woocommerce_variation_set_stock","woocommerce_product_set_stock_status","woocommerce_variation_set_stock_status","woocommerce_reduce_order_stock"] as $hook){
 $h=$GLOBALS["wp_filter"][$hook]??null;$count=0;if($h)foreach($h->callbacks as $group)$count+=count($group);
 echo "STOCK_HOOK ".$hook."=".$count."\n";
}
echo "TELEGRAM_WOO_PLUGIN=". (is_plugin_active("order-notification-for-telegram-bot/order-notification-for-telegram-bot.php")?"yes":"check_path")."\n";
foreach(["onftb_setting_token","onftb_setting_chatid","onftb_setting_is_use_google_script"] as $k) {
 $v=trim((string)get_option($k,""));echo "TELEGRAM_CONFIG ".$k." set=".($v!=""?"yes":"no");
 if($k==="onftb_setting_chatid")echo " recipients=".count(array_filter(array_map("trim",explode(",",$v))));
 echo "\n";
}
';
echo "=== TELEGRAM_TUNNEL ==="
systemctl is-active vesta-telegram-strato-tunnel 2>/dev/null || true
ss -ltn '( sport = :11443 )' | sed -n '1,2p'
echo "=== ORDER_PLUGIN_HOOK_NAMES ==="
dir=/srv/vestacutella/runtime/vesta/wp-content/plugins/order-notification-for-telegram-bot
if [[ -d "$dir" ]];then
 grep -RhoE --include='*.php' "woocommerce_(new_order|order_status_[a-z_-]+|low_stock|no_stock|product_set_stock|variation_set_stock)" "$dir" 2>/dev/null |sort -u |head -35
fi
echo "=== WP_CRON ==="
systemctl is-active cron 2>/dev/null || true
grep -c 'vesta-cosmetics.ir/wp-cron.php' /etc/cron.d/vestacutella-wp-cron 2>/dev/null || true
echo ORDER_MAIL_TELEGRAM_STOCK_AUDIT_DONE
