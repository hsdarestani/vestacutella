#!/usr/bin/env bash
set -euo pipefail

BASE=/srv/vestacutella
RUNTIME=$BASE/runtime/vesta
ENVFILE=$BASE/.env
set -a
source "$ENVFILE"
set +a

echo "=== confirm PHP 7.4 ==="
phpv="$(docker exec vc-vesta php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
echo "php=$phpv"
[[ "$phpv" == "7.4" ]] || exit 20

rollback() {
  echo "ROLLBACK plugins"
  [[ -d "$RUNTIME/wp-content/plugins/smsir" ]] && mv "$RUNTIME/wp-content/plugins/smsir" "$RUNTIME/wp-content/plugins/smsir.disabled-for-migration" || true
  [[ -d "$RUNTIME/wp-content/plugins/xcart" ]] && mv "$RUNTIME/wp-content/plugins/xcart" "$RUNTIME/wp-content/plugins/xcart.disabled-for-migration" || true
  docker restart vc-vesta >/dev/null 2>&1 || true
}
trap 'rc=$?; if [[ $rc -ne 0 ]]; then rollback; fi; exit $rc' EXIT

echo "=== restore plugin directory names ==="
[[ -d "$RUNTIME/wp-content/plugins/smsir.disabled-for-migration" ]] && mv "$RUNTIME/wp-content/plugins/smsir.disabled-for-migration" "$RUNTIME/wp-content/plugins/smsir"
[[ -d "$RUNTIME/wp-content/plugins/xcart.disabled-for-migration" ]] && mv "$RUNTIME/wp-content/plugins/xcart.disabled-for-migration" "$RUNTIME/wp-content/plugins/xcart"

echo "=== restore original checkout settings ==="
docker exec vc-vesta php -r '
require "/var/www/html/wp-load.php";
update_option("woocommerce_enable_guest_checkout","no");
update_option("woocommerce_enable_signup_and_login_from_checkout","yes");
if (function_exists("rocket_clean_domain")) rocket_clean_domain();
echo "guest=".get_option("woocommerce_enable_guest_checkout").PHP_EOL;
echo "signup=".get_option("woocommerce_enable_signup_and_login_from_checkout").PHP_EOL;
'

docker restart vc-vesta >/dev/null
sleep 7

echo "=== local smoke ==="
for p in / /my-account/ /shop/ /checkout/; do
  code="$(curl -ksS --max-time 40 --resolve vesta-cosmetics.ir:443:127.0.0.1 -o /tmp/vesta-check -w '%{http_code}' "https://vesta-cosmetics.ir$p" || true)"
  echo "$p HTTP=$code"
  case "$p:$code" in
    /:200|/my-account/:200|/shop/:200|/checkout/:200|/checkout/:302) ;;
    *) exit 31 ;;
  esac
done

echo "=== verify old login markers ==="
curl -ksS --max-time 40 --resolve vesta-cosmetics.ir:443:127.0.0.1 -o /tmp/my-account.html https://vesta-cosmetics.ir/my-account/
grep -q 'smsir-login-app' /tmp/my-account.html || { echo "smsir marker missing"; exit 41; }
grep -q '/wp-content/plugins/smsir/' /tmp/my-account.html || { echo "smsir assets missing"; exit 42; }
grep -q '/wp-content/plugins/xcart/' /tmp/my-account.html || { echo "xcart assets missing"; exit 43; }

echo "=== active plugin state ==="
docker exec vc-vesta php -r '
require "/var/www/html/wp-load.php";
require_once ABSPATH."wp-admin/includes/plugin.php";
foreach(["smsir/index.php","xcart/xcart.php"] as $p) echo $p."=".(is_plugin_active($p)?"active":"inactive").PHP_EOL;
'

echo "=== public smoke ==="
for p in / /my-account/ /shop/; do
  curl -ksS --max-time 40 -o /dev/null -w "$p HTTP=%{http_code} TTFB=%{time_starttransfer} TOTAL=%{time_total}\n" "https://vesta-cosmetics.ir$p"
done

trap - EXIT
echo "VESTA_ORIGINAL_PLUGINS_RESTORED_OK"
