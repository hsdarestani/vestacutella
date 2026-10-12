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
