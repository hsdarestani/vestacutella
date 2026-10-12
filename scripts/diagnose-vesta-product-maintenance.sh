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
