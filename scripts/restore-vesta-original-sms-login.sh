#!/usr/bin/env bash
set -euo pipefail

BASE=/srv/vestacutella
REPO=$BASE/repo
RUNTIME=$BASE/runtime/vesta
ENVFILE=$BASE/.env
BACKUP=/srv/backups/vesta-original-plugins
ts="$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$BACKUP/$ts"

set -a
source "$ENVFILE"
set +a

echo "=== Ensure Vesta is on source-compatible PHP 7.4 ==="
cd "$REPO/infra"
docker compose --env-file "$ENVFILE" build vesta
docker compose --env-file "$ENVFILE" up -d --no-deps vesta
sleep 8
PHPVER="$(docker exec vc-vesta php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
echo "php=$PHPVER"
[[ "$PHPVER" == "7.4" ]] || { echo "Vesta is not on PHP 7.4"; exit 20; }

echo "=== Backup current plugin/account state ==="
docker exec vc-db-vesta mariadb-dump -uroot -p"$VESTA_DB_ROOT_PASSWORD" vestacos_m wp_options   | gzip -1 > "$BACKUP/$ts/wp_options.sql.gz"

orig_guest="$(docker exec vc-vesta php -r 'require "/var/www/html/wp-load.php"; echo get_option("woocommerce_enable_guest_checkout");')"
orig_signup="$(docker exec vc-vesta php -r 'require "/var/www/html/wp-load.php"; echo get_option("woocommerce_enable_signup_and_login_from_checkout");')"

rollback() {
  echo "=== ROLLBACK ==="
  docker exec vc-vesta php -r '
    require "/var/www/html/wp-load.php";
    require_once ABSPATH."wp-admin/includes/plugin.php";
    deactivate_plugins(["smsir/index.php","xcart/xcart.php"], true);
  ' >/dev/null 2>&1 || true
  [[ -d "$RUNTIME/wp-content/plugins/smsir" ]] && mv "$RUNTIME/wp-content/plugins/smsir" "$RUNTIME/wp-content/plugins/smsir.disabled-for-migration" || true
  [[ -d "$RUNTIME/wp-content/plugins/xcart" ]] && mv "$RUNTIME/wp-content/plugins/xcart" "$RUNTIME/wp-content/plugins/xcart.disabled-for-migration" || true
  docker exec vc-vesta php -r '
    require "/var/www/html/wp-load.php";
    update_option("woocommerce_enable_guest_checkout", getenv("ORIG_GUEST"));
    update_option("woocommerce_enable_signup_and_login_from_checkout", getenv("ORIG_SIGNUP"));
    if (function_exists("rocket_clean_domain")) rocket_clean_domain();
  ' >/dev/null 2>&1 || true
  docker restart vc-vesta >/dev/null 2>&1 || true
}
export ORIG_GUEST="$orig_guest" ORIG_SIGNUP="$orig_signup"
trap 'rc=$?; if [[ $rc -ne 0 ]]; then rollback; fi; exit $rc' EXIT

restore_one() {
  local name="$1" file="$2"
  local disabled="$RUNTIME/wp-content/plugins/$name.disabled-for-migration"
  local enabled="$RUNTIME/wp-content/plugins/$name"

  if [[ -d "$disabled" && ! -d "$enabled" ]]; then
    mv "$disabled" "$enabled"
  fi
  [[ -d "$enabled" ]] || { echo "Missing plugin directory: $name"; exit 31; }

  docker exec vc-vesta php -r '
    require "/var/www/html/wp-load.php";
    require_once ABSPATH."wp-admin/includes/plugin.php";
    $file=getenv("PLUGIN_FILE");
    $r=activate_plugin($file, "", false, true);
    if (is_wp_error($r)) {
      fwrite(STDERR,$r->get_error_message().PHP_EOL);
      exit(2);
    }
    echo "activated=".$file.PHP_EOL;
  ' 2>&1
}

echo "=== Restore SMS.ir ==="
docker exec -e PLUGIN_FILE="smsir/index.php" vc-vesta true
PLUGIN_FILE="smsir/index.php" restore_one "smsir" "smsir/index.php"

sleep 3
for p in / /my-account/ /checkout/; do
  code="$(curl -ksS --max-time 40 --resolve vesta-cosmetics.ir:443:127.0.0.1 -o /tmp/vesta-page -w '%{http_code}' "https://vesta-cosmetics.ir$p" || true)"
  echo "after_smsir $p HTTP=$code"
  [[ "$code" == "200" || "$p" == "/checkout/" && "$code" == "302" ]] || exit 41
done

echo "=== Restore XCart ==="
PLUGIN_FILE="xcart/xcart.php" restore_one "xcart" "xcart/xcart.php"
sleep 3
for p in / /my-account/ /checkout/; do
  code="$(curl -ksS --max-time 40 --resolve vesta-cosmetics.ir:443:127.0.0.1 -o /tmp/vesta-page -w '%{http_code}' "https://vesta-cosmetics.ir$p" || true)"
  echo "after_xcart $p HTTP=$code"
  [[ "$code" == "200" || "$p" == "/checkout/" && "$code" == "302" ]] || exit 42
done

echo "=== Restore original checkout account behavior from source DB ==="
docker exec vc-vesta php -r '
require "/var/www/html/wp-load.php";
update_option("woocommerce_enable_guest_checkout","no");
update_option("woocommerce_enable_signup_and_login_from_checkout","yes");
if (function_exists("rocket_clean_domain")) rocket_clean_domain();
echo "guest_checkout=".get_option("woocommerce_enable_guest_checkout").PHP_EOL;
echo "signup_checkout=".get_option("woocommerce_enable_signup_and_login_from_checkout").PHP_EOL;
'

docker restart vc-vesta >/dev/null
sleep 6

echo "=== Verify old login behavior is back ==="
curl -ksS --max-time 40 --resolve vesta-cosmetics.ir:443:127.0.0.1 -o /tmp/my-current.html https://vesta-cosmetics.ir/my-account/
grep -q 'smsir-login-app' /tmp/my-current.html || { echo "SMS.ir login app marker missing"; exit 51; }
grep -q '/wp-content/plugins/smsir/' /tmp/my-current.html || { echo "SMS.ir assets missing"; exit 52; }
grep -q '/wp-content/plugins/xcart/' /tmp/my-current.html || { echo "XCart assets missing"; exit 53; }

echo "=== Public smoke ==="
for p in / /my-account/ /shop/; do
  curl -ksS --max-time 40 -o /tmp/public-page -w "$p HTTP=%{http_code} TTFB=%{time_starttransfer} TOTAL=%{time_total}\n" "https://vesta-cosmetics.ir$p"
done

echo "=== Active restored plugins ==="
docker exec vc-vesta php -r '
require "/var/www/html/wp-load.php";
require_once ABSPATH."wp-admin/includes/plugin.php";
foreach (["smsir/index.php","xcart/xcart.php"] as $p) echo $p."=".(is_plugin_active($p)?"active":"inactive").PHP_EOL;
'

trap - EXIT
echo "VESTA_ORIGINAL_SMS_LOGIN_RESTORED_OK"
