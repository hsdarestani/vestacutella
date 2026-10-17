#!/usr/bin/env bash
# Vesta ONLY. Installs an independent print feature; does not alter licensed invoice code,
# licence keys, WooCommerce settings, orders, databases, Cutella, or the isolated app.
set -euo pipefail
RUNTIME=/srv/vestacutella/runtime/vesta
SOURCE=/tmp/vc-vesta-reliable-print.php
TARGET="$RUNTIME/wp-content/mu-plugins/vc-vesta-reliable-order-print.php"
BACKUP="/srv/backups/vesta-order-print-$(date -u +%Y%m%dT%H%M%SZ)"
test -f "$SOURCE"
test -f "$RUNTIME/wp-config.php"
test -d "$RUNTIME/wp-content/mu-plugins"
docker ps --filter name=vc-vesta --format '{{.Names}} {{.Status}}' | grep -q '^vc-vesta '
echo '=== CHECK (NO WRITES) ==='
docker exec vc-vesta php -v | head -n 2
docker exec vc-vesta php -l /var/www/html/wp-config.php
docker exec vc-vesta php -r '
require "/var/www/html/wp-load.php";
if (!function_exists("wc_get_order")) exit(10);
echo "WP_AND_WOOCOMMERCE_LOADED".PHP_EOL;
'
for p in / /shop/ /my-account/; do
    code=$(curl -ksS --max-time 40 --resolve vesta-cosmetics.ir:443:127.0.0.1 -o /dev/null -w '%{http_code}' "https://vesta-cosmetics.ir$p")
    echo "baseline $p HTTP=$code"
    [[ "$code" == 200 ]] || exit 11
done
mkdir -m 700 -p "$BACKUP"
had_target=no
if [[ -f "$TARGET" ]]; then
    cp -p "$TARGET" "$BACKUP/old-vesta-reliable-order-print.php"
    had_target=yes
fi
changed=no
completed=no
rollback() {
    rc=$?
    trap - EXIT
    if [[ "$changed" == yes && "$completed" != yes ]]; then
        echo "ROLLBACK: restoring only independent print mu-plugin, rc=$rc"
        if [[ "$had_target" == yes ]]; then
            cp -p "$BACKUP/old-vesta-reliable-order-print.php" "$TARGET"
        else
            rm -f "$TARGET"
        fi
        for p in / /shop/ /my-account/; do
            curl -ksS --max-time 30 --resolve vesta-cosmetics.ir:443:127.0.0.1 -o /dev/null -w "rollback $p HTTP=%{http_code}\n" "https://vesta-cosmetics.ir$p" || true
        done
    fi
    exit "$rc"
}
trap rollback EXIT
echo '=== INSTALL INDEPENDENT PRINT (NO CONTAINER RESTART) ==='
install -m 0644 "$SOURCE" "$TARGET"
changed=yes
docker exec vc-vesta php -l /var/www/html/wp-content/mu-plugins/vc-vesta-reliable-order-print.php
echo '=== BOOTSTRAP AND FUNCTIONAL SMOKE WITHOUT CUSTOMER RECORDS ==='
docker exec vc-vesta php -d display_errors=stderr -r '
require "/var/www/html/wp-load.php";
if (!function_exists("vc_vesta_print_orders")) exit(20);
if (!has_action("admin_post_vc_vesta_print_orders", "vc_vesta_print_orders")) exit(21);
if (has_filter("bulk_actions-edit-shop_order","vc_vesta_print_bulk_choices") === false) exit(22);
if (has_filter("bulk_actions-woocommerce_page_wc-orders","vc_vesta_print_bulk_choices") === false) exit(23);
if (!class_exists("WC_Order")) exit(24);
$o = new WC_Order();
$o->set_billing_first_name("VestaTest");
$o->set_billing_last_name("Receiver");
$o->set_billing_address_1("TestAddress");
if (strpos(vc_vesta_print_address_html($o),"TestAddress") === false) exit(25);
echo "PRINT_HOOKS_AND_SYNTHETIC_ADDRESS_OK".PHP_EOL;
'
for p in / /shop/ /my-account/ /wp-login.php; do
    code=$(curl -ksS --max-time 40 --resolve vesta-cosmetics.ir:443:127.0.0.1 -o /dev/null -w '%{http_code}' "https://vesta-cosmetics.ir$p")
    echo "after_install $p HTTP=$code"
    [[ "$code" == 200 ]] || exit 30
done
# Without an authenticated admin session the private print endpoint must not reveal orders.
private_code=$(curl -ksS --max-time 30 --resolve vesta-cosmetics.ir:443:127.0.0.1 -o /dev/null -w '%{http_code}' 'https://vesta-cosmetics.ir/wp-admin/admin-post.php?action=vc_vesta_print_orders&mode=address&order_ids=1')
echo "anonymous_print_endpoint HTTP=$private_code"
case "$private_code" in 400|401|403|302) ;; *) echo 'Unexpected anonymous print endpoint response'; exit 32;; esac
if docker logs --since 2m vc-vesta 2>&1 | grep -Eqi 'PHP Fatal error.*vc-vesta-reliable-order-print|Uncaught .*vc-vesta-reliable-order-print'; then
    echo 'New print plugin PHP fatal error detected'
    exit 31
fi
completed=yes
trap - EXIT
echo "VESTA_RELIABLE_PRINT_LIVE_OK backup=$BACKUP"
