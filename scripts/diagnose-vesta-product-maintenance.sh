#!/usr/bin/env bash
set -euo pipefail
BASE=/srv/vestacutella
ENVFILE=$BASE/.env
set -a
source "$ENVFILE"
set +a

echo "=== checkout HTTP ==="
curl -ksS --max-time 30 -D /tmp/checkout.h -o /tmp/checkout.b -w 'code=%{http_code} ttfb=%{time_starttransfer} total=%{time_total} bytes=%{size_download}\n' https://vesta-cosmetics.ir/checkout/ || true
grep -Ei '^(HTTP/|cache-control:|cf-cache-status:|server:)' /tmp/checkout.h || true
grep -Eio 'Forbidden|خطای درگاه|فیلترشکن|زرین|دیجی|اسنپ|کارت.?به.?کارت' /tmp/checkout.b | sort -u | head -50 || true

echo "=== WooCommerce payment gateways ==="
docker exec vc-vesta php -r '
require "/var/www/html/wp-load.php";
foreach (WC()->payment_gateways()->payment_gateways() as $id=>$g) {
  $enabled = isset($g->enabled) ? $g->enabled : "";
  $title = isset($g->title) ? wp_strip_all_tags($g->title) : "";
  $avail = method_exists($g,"is_available") ? ($g->is_available() ? "yes":"no") : "unknown";
  echo $id." | enabled=".$enabled." | available=".$avail." | title=".$title.PHP_EOL;
}
' 2>&1 | tail -120

echo "=== payment provider domains in plugins ==="
for p in persian-cardpay-smart snapppay-woocommerce-gateway wp-digipay-V1.6.17 xcart; do
  d="$BASE/runtime/vesta/wp-content/plugins/$p"
  [[ -d "$d" ]] || continue
  echo "--- $p ---"
  grep -RhoE 'https?://[A-Za-z0-9._:-]+' "$d" 2>/dev/null | sed -E 's#https?://##' | sort -u | head -80 || true
done

echo "=== recent gateway errors ==="
docker logs --since 90m vc-vesta 2>&1 | grep -Ei 'forbidden|403|payment|gateway|zibal|digipay|snapp|cardpay|curl|timeout|ssl|certificate' | tail -220 || true

for f in "$BASE/runtime/vesta/wp-content/debug.log" "$BASE/runtime/vesta/wp-content/vc-debug.log"; do
  [[ -f "$f" ]] || continue
  echo "--- $f ---"
  grep -Ei 'forbidden|403|payment|gateway|zibal|digipay|snapp|cardpay|curl|timeout|ssl|certificate' "$f" | tail -180 || true
done

echo "=== outbound IPv4 ==="
curl -4fsS --max-time 10 https://api.ipify.org || true
echo

echo "PAYMENT_GATEWAY_DIAG_OK"


echo "=== gateway source references for Forbidden / API calls ==="
for p in snapppay-woocommerce-gateway wp-digipay-V1.6.17 persian-cardpay-smart; do
  d="$BASE/runtime/vesta/wp-content/plugins/$p"
  [[ -d "$d" ]] || continue
  echo "--- $p ---"
  grep -RniE 'Forbidden|خطای درگاه|wp_remote_(get|post|request)|curl_exec|api\.snapppay\.ir|api\.mydigipay\.com|merchant|whitelist|ip address|آی.?پی' "$d" 2>/dev/null     | head -220 || true
done

echo "=== provider reachability from new server ==="
for u in https://api.snapppay.ir/ https://api.mydigipay.com/ https://www.mydigipay.com/; do
  echo "--- $u ---"
  curl -ksS --max-time 20 -D /tmp/provider.h -o /tmp/provider.b -w 'code=%{http_code} remote=%{remote_ip} total=%{time_total}\n' "$u" || true
  head -n 15 /tmp/provider.h || true
  head -c 500 /tmp/provider.b | tr '\n' ' '; echo
done

echo "=== options names for payment plugins (values hidden) ==="
docker exec vc-db-vesta mariadb -uroot -p"$VESTA_DB_ROOT_PASSWORD" vestacos_m -N -e "
SELECT option_name
FROM wp_options
WHERE option_name REGEXP 'snap|digipay|zibal|cardpay|gateway'
ORDER BY option_name;
" | head -160 || true

echo "PAYMENT_GATEWAY_DEEP_DIAG_OK"


echo "=== SnappPay live eligibility check (no transaction) ==="
docker exec vc-vesta php -r '
require "/var/www/html/wp-load.php";
if (!class_exists("SnappPayAPI")) {
  echo "SnappPayAPI class missing".PHP_EOL;
  exit;
}
$r=(new SnappPayAPI())->is_merchant_eligible(7180000);
if (is_wp_error($r)) {
  echo "snappay_error_code=".$r->get_error_code().PHP_EOL;
  echo "snappay_error_message=".$r->get_error_message().PHP_EOL;
} else {
  echo "snappay_result=".wp_json_encode($r).PHP_EOL;
}
' 2>&1 | tail -80

echo "=== SnappPay stored web-server IP status ==="
docker exec vc-vesta php -r '
require "/var/www/html/wp-load.php";
$stored=(string)get_option("snapppay-web-server-ip","");
$ctx=stream_context_create(["http"=>["timeout"=>8],"ssl"=>["verify_peer"=>true,"verify_peer_name"=>true]]);
$current=@file_get_contents("https://api.ipify.org",false,$ctx);
$current=is_string($current)?trim($current):"";
echo "stored_ip_present=".($stored!==""?"yes":"no").PHP_EOL;
echo "stored_matches_current=".(($stored!=="" && $current!=="" && trim($stored)===$current)?"yes":"no").PHP_EOL;
' 2>&1 | tail -40

echo "=== SnappPay source around eligibility ==="
sed -n '55,115p' "$BASE/runtime/vesta/wp-content/plugins/snapppay-woocommerce-gateway/class-snapppay-api.php" || true
sed -n '155,205p' "$BASE/runtime/vesta/wp-content/plugins/snapppay-woocommerce-gateway/hooks.php" || true

echo "SNAPPAY_DIAG_OK"


echo "=== SnappPay IP tracking implementation ==="
sed -n '330,470p' "$BASE/runtime/vesta/wp-content/plugins/snapppay-woocommerce-gateway/functions.php" || true
grep -Rni "snapppay-web-server-ip" "$BASE/runtime/vesta/wp-content/plugins/snapppay-woocommerce-gateway" 2>/dev/null | head -80 || true

echo "SNAPPAY_IP_TRACKING_DIAG_OK"


echo "=== SnappPay gateway admin IP field ==="
sed -n '80,115p' "$BASE/runtime/vesta/wp-content/plugins/snapppay-woocommerce-gateway/class-wc-gateway-snapppay.php" || true


echo "=== refresh SnappPay detected server IP and bearer token, then retest ==="
docker exec vc-vesta php -r '
require "/var/www/html/wp-load.php";
if (function_exists("snapppay_get_ip")) {
  snapppay_get_ip();
  echo "server_ip_refreshed".PHP_EOL;
}
delete_transient("snapppay_bearer_token");
echo "bearer_token_cleared".PHP_EOL;
$r=(new SnappPayAPI())->is_merchant_eligible(7180000);
if (is_wp_error($r)) {
  echo "retest_error_code=".$r->get_error_code().PHP_EOL;
  echo "retest_error_message=".$r->get_error_message().PHP_EOL;
} else {
  echo "retest_ok".PHP_EOL;
}
' 2>&1 | tail -80


echo "=== checkout billing fields ==="
docker exec vc-vesta php -r '
require "/var/www/html/wp-load.php";
$checkout=WC()->checkout();
$fields=$checkout->get_checkout_fields("billing");
foreach($fields as $k=>$v){
  $req=!empty($v["required"])?"yes":"no";
  $type=$v["type"]??"";
  $class=isset($v["class"])?implode(",",(array)$v["class"]):"";
  $label=$v["label"]??"";
  echo $k." | required=".$req." | type=".$type." | class=".$class." | label=".$label.PHP_EOL;
}
' 2>&1 | tail -100

echo "=== checkout field editor related options ==="
docker exec vc-db-vesta mariadb -uroot -p"$VESTA_DB_ROOT_PASSWORD" vestacos_m -N -e "
SELECT option_name,LEFT(option_value,1200)
FROM wp_options
WHERE option_name REGEXP 'checkout.*field|field.*checkout|wcfe|thwcfe|billing_email'
ORDER BY option_name;
" | head -120 || true

echo "CHECKOUT_FIELD_DIAG_OK"


echo "=== compare current vs old-origin My Account ==="
for target in current old; do
  echo "--- $target ---"
  if [[ "$target" == "current" ]]; then
    curl -ksS --max-time 30 -D /tmp/my.h -o /tmp/my.b "https://vesta-cosmetics.ir/my-account/" || true
  else
    curl -ksS --max-time 30 --resolve vesta-cosmetics.ir:443:93.95.27.75 -D /tmp/my.h -o /tmp/my.b "https://vesta-cosmetics.ir/my-account/" || true
  fi
  echo "bytes=$(wc -c < /tmp/my.b 2>/dev/null || echo 0)"
  grep -Eio 'ورود با[^<]{0,80}|کد یک.?بار مصرف|رمز یک.?بار مصرف|otp|sms|شماره موبایل|تلفن همراه|نام کاربری یا آدرس ایمیل|ثبت نام' /tmp/my.b | sort -u | head -80 || true
done

echo "=== OTP/SMS login implementation candidates on current filesystem ==="
for root in "$BASE/runtime/vesta/wp-content/plugins" "$BASE/runtime/vesta/wp-content/mu-plugins" "$BASE/runtime/vesta/wp-content/themes"; do
  [[ -d "$root" ]] || continue
  grep -Rli --exclude='*.map' -E 'SMSIR_API|103808|vestaland_send_otp|woocommerce_login_form|one.?time|otp|کد یک.?بار مصرف|شماره موبایل' "$root" 2>/dev/null | head -160 || true
done

echo "=== SMSIR plugin directories/status ==="
find "$BASE/runtime/vesta/wp-content/plugins" -maxdepth 1 -type d -iname '*sms*' -printf '%f\n' | sort || true
docker exec vc-vesta php -r '
require "/var/www/html/wp-load.php";
require_once ABSPATH."wp-admin/includes/plugin.php";
foreach (get_plugins() as $file=>$data) {
  if (stripos($file,"sms")!==false || stripos($data["Name"]??"","sms")!==false) {
    echo $file." | ".($data["Name"]??"")." | active=".(is_plugin_active($file)?"yes":"no").PHP_EOL;
  }
}
' 2>&1 | tail -100

echo "=== custom MU plugins ==="
find "$BASE/runtime/vesta/wp-content/mu-plugins" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | sort || true

echo "LOGIN_OTP_AUDIT_OK"


echo "=== old-origin My Account plugin assets ==="
curl -ksS --max-time 30 --resolve vesta-cosmetics.ir:443:93.95.27.75 -o /tmp/old-my.html "https://vesta-cosmetics.ir/my-account/" || true
grep -Eo '/wp-content/plugins/[^/"?]+' /tmp/old-my.html | sort -u | head -220 || true

echo "=== old-origin OTP related asset lines ==="
grep -Ein 'xcart|smsir|otp|login.min.js|login.css|mobile|phone' /tmp/old-my.html | head -160 || true

echo "OLD_LOGIN_ASSET_AUDIT_OK"


echo "=== SMSIR/XCart PHP compatibility lint on PHP 8.1 ==="
for p in smsir.disabled-for-migration xcart.disabled-for-migration; do
  d="$BASE/runtime/vesta/wp-content/plugins/$p"
  echo "--- $p headers ---"
  find "$d" -maxdepth 1 -type f -name '*.php' -print -exec sed -n '1,50p' {} \; | grep -E 'Plugin Name:|Version:|Requires PHP:|Requires at least:' || true
  echo "--- $p lint failures ---"
  find "$d" -type f -name '*.php' -print0 | while IFS= read -r -d '' file; do
    out="$(docker exec vc-vesta php -l "${file#$BASE/runtime/vesta}" 2>&1 || true)"
    echo "$out" | grep -v 'No syntax errors detected' && echo "FILE=$file" || true
  done | head -240
  echo "--- $p PHP8 risk patterns ---"
  grep -RniE 'create_function\s*\(|get_magic_quotes_gpc\s*\(|each\s*\(|\{\$[^}]+\}|\$[A-Za-z_][A-Za-z0-9_]*\{[^}]+\}' "$d" 2>/dev/null | head -160 || true
done

echo "PLUGIN_PHP81_AUDIT_OK"


echo "=== SMSIR plugin config/API references ==="
SMSD="$BASE/runtime/vesta/wp-content/plugins/smsir.disabled-for-migration"
grep -RniE 'api\.sms\.ir|send/verify|template|api.?key|get_option\(|update_option\(|wp_ajax|smsir-login-app|loginWithOtp|sendOtp' "$SMSD" 2>/dev/null | head -320 || true

echo "=== SMSIR encoded PHP detection ==="
find "$SMSD" -type f -name '*.php' -maxdepth 5 -print0 | while IFS= read -r -d '' f; do
  if head -c 200 "$f" | grep -aq 'ionCube\|005'; then echo "$f"; fi
done | head -120

echo "SMSIR_SOURCE_AUDIT_OK"
