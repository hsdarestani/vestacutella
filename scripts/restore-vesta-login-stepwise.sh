#!/usr/bin/env bash
set -euo pipefail
BASE=/srv/vestacutella
RUNTIME="$BASE/runtime/vesta"

echo "=== PHP ==="
docker exec vc-vesta php -v | head -2

echo "=== remove stale active flags while directories are disabled ==="
docker exec vc-vesta php -r '
require "/var/www/html/wp-load.php";
require_once ABSPATH."wp-admin/includes/plugin.php";
deactivate_plugins(["smsir/index.php","xcart/xcart.php"], true);
echo "stale_flags_removed\n";
'

restore_plugin() {
  local name="$1" file="$2"
  local disabled="$RUNTIME/wp-content/plugins/$name.disabled-for-migration"
  local enabled="$RUNTIME/wp-content/plugins/$name"

  [[ -d "$enabled" ]] || mv "$disabled" "$enabled"

  set +e
  out="$(docker exec -e PLUGIN_FILE="$file" vc-vesta php -d display_errors=1 -d error_reporting=E_ALL -r '
    require "/var/www/html/wp-load.php";
    require_once ABSPATH."wp-admin/includes/plugin.php";
    $p=getenv("PLUGIN_FILE");
    $r=activate_plugin($p, "", false, true);
    if (is_wp_error($r)) { echo "ACTIVATE_ERROR=".$r->get_error_message()."\n"; exit(2); }
    echo "ACTIVE=".(is_plugin_active($p)?"yes":"no")."\n";
  ' 2>&1)"
  rc=$?
  set -e
  echo "$out"
  if [[ $rc -ne 0 ]]; then
    echo "$name activation failed, disabling safely"
    docker exec -e PLUGIN_FILE="$file" vc-vesta php -r '
      require "/var/www/html/wp-load.php";
      require_once ABSPATH."wp-admin/includes/plugin.php";
      deactivate_plugins([getenv("PLUGIN_FILE")], true);
    ' >/dev/null 2>&1 || true
    [[ -d "$enabled" ]] && mv "$enabled" "$disabled" || true
    docker restart vc-vesta >/dev/null || true
    return 1
  fi
  return 0
}

echo "=== SMSIR ==="
restore_plugin smsir smsir/index.php || exit 30
sleep 4
for p in / /my-account/; do
  code="$(curl -ksS --max-time 30 --resolve vesta-cosmetics.ir:443:127.0.0.1 -o /tmp/p -w '%{http_code}' "https://vesta-cosmetics.ir$p" || true)"
  echo "smsir $p HTTP=$code"
  [[ "$code" == "200" ]] || exit 31
done
grep -q 'smsir-login-app' /tmp/p || { echo "SMSIR login marker missing"; exit 32; }

echo "=== XCART ==="
xcart_ok=1
restore_plugin xcart xcart/xcart.php || xcart_ok=0
sleep 4
if [[ "$xcart_ok" == 1 ]]; then
  for p in / /my-account/ /shop/; do
    code="$(curl -ksS --max-time 30 --resolve vesta-cosmetics.ir:443:127.0.0.1 -o /tmp/x -w '%{http_code}' "https://vesta-cosmetics.ir$p" || true)"
    echo "xcart $p HTTP=$code"
    if [[ "$code" != "200" ]]; then xcart_ok=0; break; fi
  done
fi
if [[ "$xcart_ok" != 1 ]]; then
  echo "XCart failed runtime smoke; keeping it disabled, SMSIR stays restored"
  docker exec vc-vesta php -r '
    require "/var/www/html/wp-load.php";
    require_once ABSPATH."wp-admin/includes/plugin.php";
    deactivate_plugins(["xcart/xcart.php"], true);
  ' >/dev/null 2>&1 || true
  [[ -d "$RUNTIME/wp-content/plugins/xcart" ]] && mv "$RUNTIME/wp-content/plugins/xcart" "$RUNTIME/wp-content/plugins/xcart.disabled-for-migration" || true
  docker restart vc-vesta >/dev/null || true
  sleep 4
fi

echo "=== restore source checkout behavior ==="
docker exec vc-vesta php -r '
require "/var/www/html/wp-load.php";
update_option("woocommerce_enable_guest_checkout","no");
update_option("woocommerce_enable_signup_and_login_from_checkout","yes");
if (function_exists("rocket_clean_domain")) rocket_clean_domain();
echo "guest=".get_option("woocommerce_enable_guest_checkout")." signup=".get_option("woocommerce_enable_signup_and_login_from_checkout").PHP_EOL;
'
docker restart vc-vesta >/dev/null
sleep 6

echo "=== final verification ==="
curl -ksS --max-time 30 --resolve vesta-cosmetics.ir:443:127.0.0.1 -o /tmp/my.html -w 'my-account HTTP=%{http_code} TTFB=%{time_starttransfer} TOTAL=%{time_total}\n' https://vesta-cosmetics.ir/my-account/
grep -q 'smsir-login-app' /tmp/my.html
grep -q '/wp-content/plugins/smsir/' /tmp/my.html
echo "smsir_ui=present"
if grep -q '/wp-content/plugins/xcart/' /tmp/my.html; then echo "xcart_ui=present"; else echo "xcart_ui=absent"; fi

docker exec vc-vesta php -r '
require "/var/www/html/wp-load.php";
require_once ABSPATH."wp-admin/includes/plugin.php";
foreach(["smsir/index.php","xcart/xcart.php"] as $p) echo $p."=".(is_plugin_active($p)?"active":"inactive").PHP_EOL;
'

for p in / /shop/ /my-account/; do
  curl -ksS --max-time 30 -o /dev/null -w "public $p HTTP=%{http_code} TTFB=%{time_starttransfer} TOTAL=%{time_total}\n" "https://vesta-cosmetics.ir$p"
done
echo "VESTA_LOGIN_RESTORE_FINISHED"
