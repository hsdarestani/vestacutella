#!/usr/bin/env bash
set -euo pipefail
BASE=/srv/vestacutella
ENVFILE=$BASE/.env
set -a
source "$ENVFILE"
set +a

echo "=== checkout HTTP ==="
curl -ksS --max-time 30 -D /tmp/checkout.h -o /tmp/checkout.b   -w 'code=%{http_code} ttfb=%{time_starttransfer} total=%{time_total} bytes=%{size_download}\n'   https://vesta-cosmetics.ir/checkout/ || true
grep -Ei '^(HTTP/|cache-control:|cf-cache-status:|server:)' /tmp/checkout.h || true
grep -Eio 'Forbidden|خطای درگاه|فیلترشکن|زرین|دیجی|اسنپ|کارت.?به.?کارت' /tmp/checkout.b | sort -u | head -50 || true

echo "=== WooCommerce payment gateways (no secrets) ==="
docker exec vc-vesta php -r '
require "/var/www/html/wp-load.php";
if (!class_exists("WC_Payment_Gateways")) { echo "woocommerce_not_loaded\n"; exit; }
foreach (WC()->payment_gateways()->payment_gateways() as $id=>$g) {
  $enabled = isset($g->enabled) ? $g->enabled : "";
  $title = isset($g->title) ? wp_strip_all_tags($g->title) : "";
  $avail = method_exists($g,"is_available") ? ($g->is_available() ? "yes":"no") : "unknown";
  echo $id." | enabled=".$enabled." | available=".$avail." | title=".$title.PHP_EOL;
}
' 2>&1 | tail -120

echo "=== provider domains referenced by payment plugins ==="
for p in   persian-cardpay-smart   snapppay-woocommerce-gateway   wp-digipay-V1.6.17   xcart   woocommerce   persian-woocommerce; do
  d="$BASE/runtime/vesta/wp-content/plugins/$p"
  [[ -d "$d" ]] || continue
  echo "--- $p ---"
  grep -RhoE 'https?://[A-Za-z0-9._:-]+' "$d" 2>/dev/null     | sed -E 's#https?://##' | cut -d/ -f1 | sort -u     | grep -Ev 'wordpress|w3.org|github|example|schema.org|jquery|googleapis|gstatic|gravatar'     | head -80 || true
done

echo "=== recent PHP/Apache errors related to gateways ==="
docker logs --since 60m vc-vesta 2>&1   | grep -Ei 'forbidden|403|payment|gateway|zibal|digipay|snapp|cardpay|curl|timeout|ssl|certificate'   | tail -220 || true

echo "=== WP logs ==="
for f in "$BASE/runtime/vesta/wp-content/debug.log" "$BASE/runtime/vesta/wp-content/vc-debug.log"; do
  [[ -f "$f" ]] || continue
  echo "--- $f ---"
  grep -Ei 'forbidden|403|payment|gateway|zibal|digipay|snapp|cardpay|curl|timeout|ssl|certificate' "$f"     | tail -180 || true
done

echo "=== outbound IP ==="
curl -4fsS --max-time 10 https://api.ipify.org || true
echo

echo "PAYMENT_GATEWAY_DIAG_OK"
