#!/usr/bin/env bash
set -euo pipefail
BASE=/srv/vestacutella/runtime/vesta
echo "=== DigiPay phone processing source, keys excluded ==="
sed -n '1,80p' "$BASE/wp-content/plugins/wp-digipay-V1.6.17/Utilities.php"
sed -n '192,260p' "$BASE/wp-content/plugins/wp-digipay-V1.6.17/WCDigiPay.php"
echo "=== billing field handlers by file and line (no personal data) ==="
grep -RnlE --include='*.php' 'billing_phone|woocommerce_checkout_fields|woocommerce_checkout_posted_data' \
 "$BASE/wp-content/mu-plugins" "$BASE/wp-content/themes/woodmart-child" \
 "$BASE/wp-content/plugins/xcart" 2>/dev/null | head -40 || true
echo "=== active payment validation hooks ==="
docker exec vc-vesta php -r '
require "/var/www/html/wp-load.php";
foreach(array("woocommerce_checkout_process","woocommerce_checkout_posted_data","woocommerce_checkout_create_order","woocommerce_checkout_update_order_meta") as $hook) {
 global $wp_filter;
 $found=0;
 if(isset($wp_filter[$hook])) foreach($wp_filter[$hook]->callbacks as $callbacks) $found+=count($callbacks);
 echo $hook." handlers=".$found.PHP_EOL;
}
' 2>&1 | tail -20
echo "=== imported image path permission chains ==="
f="$(find "$BASE/wp-content/uploads/cutella-import" -type f -name '*.jpg' -print -quit)"
if [[ -n "$f" ]]; then
  namei -l "$f" | tail -12
fi
echo "PHONE_MEDIA_CODE_AUDIT_OK"
