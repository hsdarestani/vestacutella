#!/usr/bin/env bash
set -u

check() {
  local domain="$1" path="$2" label="$3"
  printf '%-18s %-32s ' "$domain" "$label"
  curl --max-time 30 -ksS --resolve "$domain:443:127.0.0.1"     -o /tmp/vc-preflight-body     -w 'HTTP=%{http_code} bytes=%{size_download} redirect=%{redirect_url}\n'     "https://$domain$path" || echo "REQUEST_FAILED"
}

echo "=== containers ==="
docker ps --format 'table {{.Names}}\t{{.Status}}' | grep -E 'vc-|NAMES' || true

for d in cutellashop.ir vesta-cosmetics.ir; do
  echo "=== $d ==="
  check "$d" "/" "home"
  check "$d" "/wp-login.php" "wp-login"
  check "$d" "/wp-json/" "REST API"
  check "$d" "/wp-admin/" "wp-admin"
done

echo "=== database import markers ==="
for f in /srv/vestacutella/runtime/db-cutella/.vc-import-complete /srv/vestacutella/runtime/db-vesta/.vc-import-complete; do
  if [[ -f "$f" ]]; then echo "OK $f"; else echo "MISSING $f"; fi
done

echo "=== recent PHP/Apache fatal errors ==="
for c in vc-cutella vc-vesta; do
  echo "--- $c ---"
  docker logs --since 10m "$c" 2>&1 | grep -Ei 'fatal|uncaught|ioncube|allowed memory|parse error' | tail -n 50 || true
done

echo "=== disk/memory ==="
df -h /
free -h
