#!/usr/bin/env bash
set -euo pipefail
BASE=/srv/vestacutella
RUNTIME="$BASE/runtime/vesta"
TARGET="$RUNTIME/wp-content/plugins/vesta-sms-login"
SOURCE=/tmp/vesta-sms-login.php
BACKUP="/srv/backups/vesta-otp-replacement-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -m 700 -p "$BACKUP"
[[ -f "$SOURCE" ]] || { echo "Missing approved replacement plugin"; exit 2; }
echo '=== Production baseline (no changes yet) ==='
[[ -d "$RUNTIME/wp-content/plugins/smsir.disabled-for-migration" ]] || { echo "Legacy SMS.ir disabled directory not found, abort to avoid conflict"; exit 3; }
[[ ! -d "$RUNTIME/wp-content/plugins/smsir" ]] || { echo "Legacy SMS.ir folder unexpectedly active, abort"; exit 4; }
[[ ! -d "$RUNTIME/wp-content/plugins/xcart" ]] || { echo "Legacy XCart folder unexpectedly active, abort"; exit 5; }
docker exec vc-vesta php -r 'if (PHP_VERSION_ID < 70400) exit(5); echo "PHP=".PHP_VERSION.PHP_EOL;' || exit 6
for p in / /shop/ /my-account/; do
  code="$(curl -ksS --max-time 35 --resolve vesta-cosmetics.ir:443:127.0.0.1 -o /dev/null -w '%{http_code}' "https://vesta-cosmetics.ir$p" || true)"
  echo "baseline $p HTTP=$code"
  [[ "$code" == "200" ]] || exit 7
done

# Back up only replaced files and the previous plugin activation; never restore DB orders or tables.
already_active="$(docker exec vc-vesta php -r '
require "/var/www/html/wp-load.php";
require_once ABSPATH."wp-admin/includes/plugin.php";
echo is_plugin_active("vesta-sms-login/vesta-sms-login.php")?"yes":"no";
')"
echo "$already_active" > "$BACKUP/was-active"
had_file=0
if [[ -f "$TARGET/vesta-sms-login.php" ]]; then
  had_file=1
  cp -p "$TARGET/vesta-sms-login.php" "$BACKUP/vesta-sms-login.php"
fi
echo "$had_file" > "$BACKUP/had-file"
rollback() {
  echo '=== ROLLING BACK ONLY OTP REPLACEMENT ==='
  docker exec vc-vesta php -r '
    require "/var/www/html/wp-load.php";
    require_once ABSPATH."wp-admin/includes/plugin.php";
    deactivate_plugins(array("vesta-sms-login/vesta-sms-login.php"), true);
  ' >/dev/null 2>&1 || true
  if [[ "$had_file" == 1 ]]; then
    cp -p "$BACKUP/vesta-sms-login.php" "$TARGET/vesta-sms-login.php" || true
  else
    rm -f "$TARGET/vesta-sms-login.php" || true
    rmdir "$TARGET" 2>/dev/null || true
  fi
  if [[ "$already_active" == "yes" && "$had_file" == 1 ]]; then
    docker exec vc-vesta php -r '
      require "/var/www/html/wp-load.php";
      require_once ABSPATH."wp-admin/includes/plugin.php";
      activate_plugin("vesta-sms-login/vesta-sms-login.php","",false,true);
    ' >/dev/null 2>&1 || true
  fi
  docker exec vc-vesta php -r '
     require "/var/www/html/wp-load.php";
     if (function_exists("rocket_clean_domain")) rocket_clean_domain();
  ' >/dev/null 2>&1 || true
  for p in / /shop/ /my-account/; do
     curl -ksS --max-time 30 --resolve vesta-cosmetics.ir:443:127.0.0.1 -o /dev/null -w "rollback $p HTTP=%{http_code}\n" "https://vesta-cosmetics.ir$p" || true
  done
}
trap 'rc=$?; if [[ $rc -ne 0 ]]; then rollback; fi; exit $rc' EXIT
echo '=== Deploy new unencoded replacement ==='
mkdir -p "$TARGET"
install -m 644 "$SOURCE" "$TARGET/vesta-sms-login.php"
docker exec vc-vesta php -l /var/www/html/wp-content/plugins/vesta-sms-login/vesta-sms-login.php
echo '=== Activate replacement (do not touch SMSIR/XCart files) ==='
docker exec vc-vesta php -r '
require "/var/www/html/wp-load.php";
require_once ABSPATH."wp-admin/includes/plugin.php";
$p="vesta-sms-login/vesta-sms-login.php";
if (!is_plugin_active($p)) {
 $r=activate_plugin($p,"",false,true);
 if (is_wp_error($r)) { fwrite(STDERR,"Activate error: ".$r->get_error_message()); exit(30); }
}
echo "replacement_active=".(is_plugin_active($p)?"yes":"no").PHP_EOL;
echo "gateway_ready=".(function_exists("vesta_otp_ready") && vesta_otp_ready()?"yes":"no").PHP_EOL;
if (!is_plugin_active($p) || !vesta_otp_ready()) exit(31);
'
echo '=== Cache clear ==='
docker exec vc-vesta php -r 'require "/var/www/html/wp-load.php"; if (function_exists("rocket_clean_domain")) rocket_clean_domain();'
echo '=== Verify account page and no loss of store availability ==='
for p in / /shop/ /my-account/ /checkout/; do
  code="$(curl -ksS --max-time 45 --resolve vesta-cosmetics.ir:443:127.0.0.1 -o /tmp/vesta-otp-response.html -w '%{http_code}' "https://vesta-cosmetics.ir$p" || true)"
  echo "after_deploy $p HTTP=$code"
  case "$p:$code" in
     /:200|/shop/:200|/my-account/:200|/checkout/:200|/checkout/:302) ;;
     *) exit 40 ;;
  esac
  if [[ "$p" == "/my-account/" ]]; then
    grep -q 'vesta-otp-login' /tmp/vesta-otp-response.html || { echo "Replacement OTP form missing from My Account HTML"; exit 41; }
  fi
done
echo '=== Check error logs after activation ==='
if docker logs --since 2m vc-vesta 2>&1 | grep -Eqi 'PHP Fatal error.*vesta-sms-login|Uncaught .*vesta-sms-login'; then
 echo "Replacement plugin PHP fatal observed"; exit 42
fi
trap - EXIT
echo "VESTA_SMS_LOGIN_REPLACEMENT_LIVE_OK"
