#!/usr/bin/env bash
# Read only: do not print licence keys, tokens, cookies or customer data.
set -euo pipefail
RUNTIME=/srv/vestacutella/runtime/vesta
test -f "$RUNTIME/wp-config.php"
echo "=== Runtime and print plugin candidates ==="
docker ps --filter name=vc-vesta --format '{{.Names}} {{.Status}}'
find "$RUNTIME/wp-content/plugins" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' |
  grep -Ei '(print|invoice|factor|pdf|packing|shipping|license|woocommerce)' | sort || true
echo "=== WP context (no credentials or customer records) ==="
docker exec vc-vesta php -d display_errors=stderr -r '
require "/var/www/html/wp-load.php";
echo "home_url=".home_url("/").PHP_EOL;
echo "siteurl=".get_option("siteurl").PHP_EOL;
echo "php=".PHP_VERSION.PHP_EOL;
echo "woocommerce=". (defined("WC_VERSION") ? WC_VERSION : "absent").PHP_EOL;
$active=(array)get_option("active_plugins",array());
foreach ($active as $p) if (preg_match("/print|invoice|factor|pdf|woocommerce|shipping|license/i", $p)) echo "active_plugin=".$p.PHP_EOL;
if (function_exists("wc_get_container") && class_exists("\\Automattic\\WooCommerce\\Internal\\DataStores\\Orders\\CustomOrdersTableController")) {
    $c=wc_get_container()->get("\\Automattic\\WooCommerce\\Internal\\DataStores\\Orders\\CustomOrdersTableController");
    echo "hpos=".($c->custom_orders_table_usage_is_enabled()?"enabled":"disabled").PHP_EOL;
}
' 2>&1 | head -100
echo "=== Licensing-related option NAMES only ==="
docker exec vc-vesta php -d display_errors=stderr -r '
require "/var/www/html/wp-load.php";
global $wpdb;
$names=$wpdb->get_col("SELECT option_name FROM {$wpdb->options}");
foreach ($names as $name) if (preg_match("/license|invoice|print|factor/i",$name)) echo preg_replace("/[^a-zA-Z0-9_\\-]/","?",$name).PHP_EOL;
' 2>&1 | head -125
echo '=== WordPress and server clocks ==='
date -u
docker exec vc-vesta php -r 'echo "runtime_utc=".gmdate("c")." timestamp=".time().PHP_EOL;'
echo '=== Invoice component file names ==='
find /srv/vestacutella/runtime/vesta/wp-content/plugins/woocommerce-invoice-pro1 -maxdepth 2 -type f -name '*.php' -printf '%P\n' | head -45
echo "=== SOAP module ==="
docker exec vc-vesta php -r 'echo extension_loaded("soap")?"soap_present\n":"soap_missing\n";'
echo '=== Invoice plugin source structure ==='
find /srv/vestacutella/runtime/vesta/wp-content/plugins/woocommerce-invoice-pro1 -maxdepth 2 -type f -name '*.php' -printf '%P %s bytes\n' | head -35
echo '=== Invoice code readability ==='
for name in core.php woocommerce-invoice-pro.php classes/helper.php; do
  f="/srv/vestacutella/runtime/vesta/wp-content/plugins/woocommerce-invoice-pro1/$name"
  if test -f "$f"; then
    if head -c 400 "$f" | grep -qi ioncube; then echo "$name:encoded"; else echo "$name:plain-or-unknown"; fi
  fi
done
echo '=== License-related scheduled hook count ==='
docker exec vc-vesta php -r 'require "/var/www/html/wp-load.php"; $a=get_option("cron");$n=0;foreach((array)$a as $e)if(is_array($e))foreach(array_keys($e) as $hook)if(preg_match("/invoice|pws|license|validat/i",$hook)){$n++;echo "hook=".$hook.PHP_EOL;}echo "matching_hooks=".$n.PHP_EOL;'

echo '=== Observer installed and dated events in Apache logs (observer lines only) ==='
OBSERVER="$RUNTIME/wp-content/mu-plugins/vc-vesta-license-observer.php"
test -f "$OBSERVER" && echo 'observer=present' || echo 'observer=missing'
docker logs --since 96h vc-vesta 2>&1 | grep -F '[vesta-invoice-validation]' | tail -120 || true
echo '=== Observer events in WordPress PHP logs, if available (observer lines only) ==='
for lf in "$RUNTIME/wp-content/debug.log" "$RUNTIME/wp-content/vc-debug.log"; do
  if [[ -f "$lf" ]]; then
    grep -F '[vesta-invoice-validation]' "$lf" | tail -60 || true
  fi
done
echo '=== Validator schedule (timestamps only) ==='
docker exec vc-vesta php -r '
require "/var/www/html/wp-load.php";
echo "now_utc=".gmdate("c").PHP_EOL;
$cron = get_option("cron", array());
foreach ((array) $cron as $stamp => $events) {
 if (!is_numeric($stamp) || !is_array($events)) continue;
 foreach (array("wip-guard-reg_daily_validator", "popup_maker_license_status_check") as $hook) {
  if (isset($events[$hook])) {
    foreach ((array)$events[$hook] as $instance) {
      $schedule = isset($instance["schedule"]) ? preg_replace("/[^a-z0-9_-]/i","",(string)$instance["schedule"]) : "single";
      echo "cron=".$hook." next_utc=".gmdate("c", (int)$stamp)." recurrence=".$schedule.PHP_EOL;
    }
  }
 }
}
foreach (array("wip-guard-reg_daily_validator", "popup_maker_license_status_check") as $h) {
 echo "registered_hook=".$h." callbacks=".(has_action($h)===false?"no":"yes").PHP_EOL;
}
' 2>&1 | grep -E '^(now_utc=|cron=|registered_hook=|PHP |Fatal error:)' | head -60

echo '=== Identify daily validator callback owners (read-only) ==='
docker exec vc-vesta php -r '
require "/var/www/html/wp-load.php";
foreach(array("wip-guard-reg_daily_validator", "popup_maker_license_status_check") as $hook) {
 global $wp_filter;
 echo "event=".$hook.PHP_EOL;
 if (empty($wp_filter[$hook])) continue;
 foreach ($wp_filter[$hook]->callbacks as $priority=>$callbacks) {
  foreach ($callbacks as $item) {
   $cb=$item["function"];
   try {
    if (is_array($cb)) {
     $ref=new ReflectionMethod($cb[0],$cb[1]);
     $name=(is_object($cb[0])?get_class($cb[0]):$cb[0])."::".$cb[1];
    } elseif (is_string($cb)) {
     $ref=new ReflectionFunction($cb);
     $name=$cb;
    } else {
     $ref=new ReflectionFunction($cb);
     $name="anonymous";
    }
    $filename=$ref->getFileName();
    $owner=is_string($filename) ? str_replace("/var/www/html/wp-content/", "", $filename) : "unknown";
    echo "callback=".substr(preg_replace("/[^a-zA-Z0-9_.:\\-]/","",$name),0,120)." source=".substr($owner,0,180)." priority=".(int)$priority.PHP_EOL;
   } catch (Exception $e) { echo "callback_unreadable".PHP_EOL; }
  }
 }
}
' 2>&1 | head -60
echo '=== Relevant option names and transient expiry metadata (never values) ==='
docker exec vc-vesta php -r '
require "/var/www/html/wp-load.php";
global $wpdb;
$names=$wpdb->get_col("SELECT option_name FROM {$wpdb->options}");
$count=0;
foreach ((array)$names as $name) {
 if(!preg_match("/wip.guard|wip_guard|invoice.pro|invoice_pro|licen|validator|_transient_timeout_/i",$name)) continue;
 if(strlen($name)>100 || preg_match("/[a-f0-9]{18,}/i",$name)) continue;
 if(++$count>80) break;
 $value=get_option($name);
 if (preg_match("/^_transient_timeout_/",$name) && is_numeric($value)) {
   echo "expiry_option=".$name." date_utc=".gmdate("c",(int)$value).PHP_EOL;
 } else {
   echo "state_option=".$name." data_type=".gettype($value).PHP_EOL;
 }
}
echo "state_key_matches=".$count.PHP_EOL;
' 2>&1 | head -95
echo "VESTA_PRINT_LICENSE_DIAGNOSTIC_COMPLETED"