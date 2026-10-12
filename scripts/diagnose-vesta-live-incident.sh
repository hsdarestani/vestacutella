#!/usr/bin/env bash
set -euo pipefail

BASE=/srv/vestacutella
ENVFILE=$BASE/.env
set -a
source "$ENVFILE"
set +a

echo "=== PUBLIC DNS ==="
getent ahostsv4 vesta-cosmetics.ir 2>/dev/null | awk '{print $1}' | sort -u || true
getent ahostsv6 vesta-cosmetics.ir 2>/dev/null | awk '{print $1}' | sort -u || true

echo "=== CONTAINERS ==="
docker ps -a --format 'table {{.Names}}	{{.Status}}	{{.Ports}}'
echo "=== RESTART COUNTS ==="
for c in vc-vesta vc-db-vesta vc-nginx; do
  echo -n "$c "; docker inspect -f 'restart={{.RestartCount}} status={{.State.Status}} oom={{.State.OOMKilled}} started={{.State.StartedAt}}' "$c" || true
done

echo "=== LOCAL HTTPS ==="
for p in / /shop/ /wp-login.php /wp-content/cache/min/1/wp-content/plugins/js_composer/assets/css/js_composer.min.css; do
  for i in 1 2 3; do
    curl --max-time 20 -ksS --resolve vesta-cosmetics.ir:443:127.0.0.1 -o /dev/null       -w "$p run=$i code=%{http_code} ttfb=%{time_starttransfer} total=%{time_total} bytes=%{size_download}\n"       "https://vesta-cosmetics.ir$p" || true
  done
done

echo "=== PUBLIC HTTPS ==="
for p in / /shop/ /wp-login.php; do
  for i in 1 2 3; do
    curl --max-time 20 -ksS -o /dev/null       -w "$p run=$i code=%{http_code} remote=%{remote_ip} ttfb=%{time_starttransfer} total=%{time_total} bytes=%{size_download}\n"       "https://vesta-cosmetics.ir$p" || true
  done
done

echo "=== PUBLIC HEADERS ==="
curl --max-time 20 -ksSI https://vesta-cosmetics.ir/ | head -40 || true

echo "=== WP DB CONNECT ==="
docker exec vc-vesta php -r '
require "/var/www/html/wp-config.php";
$m=@new mysqli(DB_HOST,DB_USER,DB_PASSWORD,DB_NAME);
echo $m->connect_errno ? "DB_ERROR=".$m->connect_error.PHP_EOL : "DB_OK".PHP_EOL;
' || true

echo "=== NGINX CONFIG ==="
docker exec vc-nginx nginx -t || true

echo "=== NGINX LOGS ==="
docker logs --since 15m vc-nginx 2>&1 | tail -120 || true

echo "=== VESTA APACHE/PHP LOGS ==="
docker logs --since 15m vc-vesta 2>&1 | tail -180 || true

echo "=== SYSTEM ==="
free -h
df -h /
uptime
docker stats --no-stream vc-vesta vc-db-vesta vc-nginx

echo "VESTA_INCIDENT_DIAG_OK"
