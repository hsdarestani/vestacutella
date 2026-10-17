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
echo "VESTA_PRINT_LICENSE_DIAGNOSTIC_COMPLETED"