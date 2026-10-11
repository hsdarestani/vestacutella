#!/usr/bin/env bash
set -euo pipefail

REPO=/srv/vestacutella/repo
INFRA="$REPO/infra"
BACKUP=/srv/backups/perf-tuning
ts="$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$BACKUP/$ts"

cp "$INFRA/nginx.conf" "$BACKUP/$ts/nginx.conf"
cp "$INFRA/wordpress/Dockerfile" "$BACKUP/$ts/Dockerfile"
[[ -f "$INFRA/wordpress/zz-performance.ini" ]] && cp "$INFRA/wordpress/zz-performance.ini" "$BACKUP/$ts/zz-performance.ini" || true

OLD_IMAGE="$(docker inspect vc-vesta --format '{{.Image}}')"
echo "old_vesta_image=$OLD_IMAGE"
docker tag "$OLD_IMAGE" "vestacutella-wordpress:rollback-$ts"

rollback() {
  echo "=== ROLLBACK PERFORMANCE DEPLOY ==="
  cp "$BACKUP/$ts/nginx.conf" "$INFRA/nginx.conf"
  cp "$BACKUP/$ts/Dockerfile" "$INFRA/wordpress/Dockerfile"
  if [[ -f "$BACKUP/$ts/zz-performance.ini" ]]; then
    cp "$BACKUP/$ts/zz-performance.ini" "$INFRA/wordpress/zz-performance.ini"
  else
    rm -f "$INFRA/wordpress/zz-performance.ini"
  fi
  docker tag "vestacutella-wordpress:rollback-$ts" vestacutella-wordpress:php8.1-ioncube || true
  (cd "$INFRA" && docker compose up -d --no-deps vesta) || true
  docker exec vc-nginx nginx -t >/dev/null 2>&1 && docker exec vc-nginx nginx -s reload || true
}

trap 'rc=$?; if [[ $rc -ne 0 ]]; then rollback; fi; exit $rc' EXIT

echo "=== Install tuned config files ==="
install -m 644 /tmp/perf-nginx.conf "$INFRA/nginx.conf"
install -m 644 /tmp/perf-Dockerfile "$INFRA/wordpress/Dockerfile"
install -m 644 /tmp/perf-zz-performance.ini "$INFRA/wordpress/zz-performance.ini"

echo "=== Validate nginx before reload ==="
docker exec vc-nginx nginx -t

echo "=== Rebuild PHP image ==="
cd "$INFRA"
docker compose build vesta

echo "=== Restart Vesta with tuned PHP ==="
docker compose up -d --no-deps vesta
sleep 8

echo "=== Reload nginx ==="
docker exec vc-nginx nginx -t
docker exec vc-nginx nginx -s reload
sleep 3

echo "=== Verify PHP tuning ==="
docker exec vc-vesta php -r '
echo "memory_limit=".ini_get("memory_limit").PHP_EOL;
echo "opcache.memory_consumption=".ini_get("opcache.memory_consumption").PHP_EOL;
echo "opcache.max_accelerated_files=".ini_get("opcache.max_accelerated_files").PHP_EOL;
echo "realpath_cache_size=".ini_get("realpath_cache_size").PHP_EOL;
'

echo "=== Smoke ==="
for p in / /shop/ /wp-login.php; do
  code="$(curl --max-time 35 -ksS --resolve vesta-cosmetics.ir:443:127.0.0.1 -o /dev/null -w '%{http_code}' "https://vesta-cosmetics.ir$p" || true)"
  echo "$p HTTP=$code"
  case "$p:$code" in
    /:200|/shop/:200|/shop/:301|/shop/:302|/wp-login.php:200) ;;
    *) exit 31 ;;
  esac
done

echo "=== Compression check ==="
curl --max-time 30 -ksS -H 'Accept-Encoding: gzip' -D - -o /dev/null https://vesta-cosmetics.ir/   | grep -Ei '^(HTTP/|content-encoding:|vary:|cache-control:|server:)' || true

echo "=== Static browser cache check ==="
asset="$(curl -ksS https://vesta-cosmetics.ir/ | grep -Eo 'https://vesta-cosmetics\.ir/[^"'"'"' ]+\.(css|js)(\?[^"'"'"' ]*)?' | head -1 || true)"
if [[ -n "$asset" ]]; then
  echo "asset=$asset"
  curl -ksSI "$asset" | grep -Ei '^(HTTP/|cache-control:|expires:)' || true
fi

echo "=== Quick public timings ==="
for i in 1 2 3; do
  curl -ksS -o /dev/null -w "home run=$i ttfb=%{time_starttransfer} total=%{time_total} bytes=%{size_download}\n" https://vesta-cosmetics.ir/
done

trap - EXIT
echo "VESTA_PERF_DEPLOY_OK"
