#!/usr/bin/env bash
set -euo pipefail

docker exec vc-vesta php -r '
require "/var/www/html/wp-load.php";
update_option("woocommerce_enable_guest_checkout","yes");
update_option("woocommerce_enable_signup_and_login_from_checkout","no");
if (function_exists("rocket_clean_domain")) {
  rocket_clean_domain();
}
echo "guest_checkout=".get_option("woocommerce_enable_guest_checkout").PHP_EOL;
echo "signup_checkout=".get_option("woocommerce_enable_signup_and_login_from_checkout").PHP_EOL;
'

docker restart vc-vesta >/dev/null
sleep 5

curl -ksS --max-time 30 -o /dev/null -w 'checkout_http=%{http_code} ttfb=%{time_starttransfer} total=%{time_total}\n' https://vesta-cosmetics.ir/checkout/ || true

echo "VESTA_CHECKOUT_NO_EMAIL_FIX_OK"
