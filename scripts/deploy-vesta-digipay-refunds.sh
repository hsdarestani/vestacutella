#!/usr/bin/env bash
# Vesta only. Do not change WooCommerce gateways, financial records or existing checkout.
set -euo pipefail
SOURCE=/tmp/vc-vesta-digipay-refunds.php
ROOT=/srv/vestacutella/runtime/vesta
TARGET="$ROOT/wp-content/mu-plugins/vc-vesta-digipay-refunds.php"
BACKUP="/srv/backups/vesta-digipay-refunds-$(date -u +%Y%m%dT%H%M%SZ)"
test -f "$SOURCE" && test -f "$ROOT/wp-config.php" && test -d "$(dirname "$TARGET")"
docker ps --filter name=vc-vesta --format '{{.Names}} {{.Status}}' | grep -q '^vc-vesta '
docker exec vc-vesta php -r 'require "/var/www/html/wp-load.php"; if (!function_exists("wc_get_order")) exit(12); echo "WOOCOMMERCE_OK\n";'
for path in / /shop/ /my-account/; do
  code=$(curl -ksS --max-time 40 --resolve vesta-cosmetics.ir:443:127.0.0.1 -o /dev/null -w '%{http_code}' "https://vesta-cosmetics.ir$path")
  echo "baseline $path HTTP=$code"
  [[ "$code" == "200" ]] || exit 13
done
mkdir -p -m 700 "$BACKUP"
had_original=no
if [[ -f "$TARGET" ]]; then cp -p "$TARGET" "$BACKUP/previous.php"; had_original=yes; fi
changed=no
finished=no
restore() {
  rc=$?
  trap - EXIT
  if [[ "$changed" == yes && "$finished" != yes ]]; then
    if [[ "$had_original" == yes ]]; then cp -p "$BACKUP/previous.php" "$TARGET"; else rm -f "$TARGET"; fi
    echo "ROLLBACK_COMPLETED rc=$rc"
  fi
  exit "$rc"
}
trap restore EXIT
install -m 0644 "$SOURCE" "$TARGET"
changed=yes
docker exec vc-vesta php -l /var/www/html/wp-content/mu-plugins/vc-vesta-digipay-refunds.php
docker exec vc-vesta php -d display_errors=stderr -r '
require "/var/www/html/wp-load.php";
if (!function_exists("vc_dp_api") || !function_exists("vc_dp_attempts") ||
    !has_action("admin_post_vc_dp_manage") ||
    !has_action("woocommerce_admin_order_data_after_order_details", "vc_dp_box")) exit(20);
$found = false; $credentials = false;
foreach (WC()->payment_gateways()->payment_gateways() as $gateway) {
  if (stripos($gateway->id, "digipay") !== false || stripos($gateway->get_title(), "دیجی") !== false) {
    $found = true;
    $o = new WC_Order();
    $o->set_payment_method($gateway->id);
    if (vc_dp_credentials($o)) { $credentials = true; }
  }
}
echo "REFUND_HOOKS_OK\n";
echo "DIGIPAY_GATEWAY_PRESENT=" . ($found ? "yes" : "no") . "\n";
echo "DIGIPAY_CREDENTIALS_PRESENT=" . ($credentials ? "yes" : "no") . "\n";
'
for path in / /shop/ /my-account/ /wp-login.php; do
  code=$(curl -ksS --max-time 40 --resolve vesta-cosmetics.ir:443:127.0.0.1 -o /dev/null -w '%{http_code}' "https://vesta-cosmetics.ir$path")
  echo "after_install $path HTTP=$code"
  [[ "$code" == "200" ]] || exit 30
done
code=$(curl -ksS --max-time 30 --resolve vesta-cosmetics.ir:443:127.0.0.1 -o /dev/null -w '%{http_code}' 'https://vesta-cosmetics.ir/wp-admin/admin-post.php?action=vc_dp_manage')
echo "anonymous_admin_endpoint HTTP=$code"
case "$code" in 400|401|403|302) ;; *) exit 32;; esac
if docker logs --since 2m vc-vesta 2>&1 | grep -Eqi 'PHP Fatal error.*vc-vesta-digipay-refunds|Uncaught .*vc-vesta-digipay-refunds'; then
  echo "PLUGIN_FATAL_DETECTED"
  exit 33
fi
finished=yes
trap - EXIT
echo "VESTA_DIGIPAY_REFUNDS_DEPLOYED backup=$BACKUP"
