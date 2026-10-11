#!/usr/bin/env bash
set -euo pipefail

BASE=/srv/vestacutella
REPO=$BASE/repo
RUNTIME=$BASE/runtime
ENVFILE=$BASE/.env
COMPOSE=$REPO/infra/docker-compose.yml
BACKUP=/srv/backups/cutella-production
ts="$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$BACKUP/$ts"

set -a
source "$ENVFILE"
set +a

echo "=== Preflight current Cutella data ==="
docker exec vc-db-cutella mariadb -uroot -p"$CUTELLA_DB_ROOT_PASSWORD" vestacos_cutella -N -e "
SELECT CONCAT('products=',COUNT(*),' latest_product=',COALESCE(MAX(post_modified_gmt),'')) FROM wp_posts WHERE post_type='product';
SELECT CONCAT('hpos_orders=',COUNT(*),' latest_order=',COALESCE(MAX(date_created_gmt),'')) FROM wp_wc_orders;
"

echo "=== Backup current production candidate DB/config ==="
docker exec vc-db-cutella mariadb-dump -uroot -p"$CUTELLA_DB_ROOT_PASSWORD" --single-transaction --routines --triggers vestacos_cutella   | gzip -1 > "$BACKUP/$ts/cutella-before-production.sql.gz"
cp "$RUNTIME/cutella/wp-config.php" "$BACKUP/$ts/wp-config.php"
cp "$REPO/infra/nginx.conf" "$BACKUP/$ts/nginx.conf"

echo "=== Install current optimized nginx config ==="
install -m 644 /tmp/nginx.conf "$REPO/infra/nginx.conf"
docker exec vc-nginx nginx -t

echo "=== Productionize Cutella WordPress ==="
WP_FILE="$RUNTIME/cutella/wp-config.php" python3 <<'PY'
import os,re
p=os.environ["WP_FILE"]
s=open(p,"r",encoding="utf-8",errors="surrogateescape").read()
s=re.sub(r"define\(\s*['\"]WP_ENVIRONMENT_TYPE['\"]\s*,\s*['\"][^'\"]+['\"]\s*\)\s*;",
         "define('WP_ENVIRONMENT_TYPE', 'production');",s)
s=re.sub(r"define\(\s*['\"]DISABLE_WP_CRON['\"]\s*,\s*(?:true|false)\s*\)\s*;",
         "define('DISABLE_WP_CRON', false);",s,flags=re.I)
for key in ("WP_DEBUG","WP_DEBUG_DISPLAY","WP_DEBUG_LOG"):
    pat=r"define\(\s*['\"]"+key+r"['\"]\s*,\s*[^;]+\)\s*;"
    if re.search(pat,s):
        s=re.sub(pat,"define('"+key+"', false);",s)
open(p,"w",encoding="utf-8",errors="surrogateescape").write(s)
PY
rm -f "$RUNTIME/cutella/wp-content/mu-plugins/00-vestacutella-migration-safety.php"
rm -f "$RUNTIME/cutella/wp-content/debug.log" "$RUNTIME/cutella/wp-content/vc-debug.log"
chown 33:33 "$RUNTIME/cutella/wp-config.php"

echo "=== Recreate Cutella with tuned PHP image ==="
cd "$REPO/infra"
docker compose --env-file "$ENVFILE" up -d --no-deps cutella
sleep 8

echo "=== Reload nginx direct to Cutella backend ==="
docker exec vc-nginx nginx -t
docker exec vc-nginx nginx -s reload
sleep 4

echo "=== Verify Cutella PHP tuning ==="
docker exec vc-cutella php -r '
echo "memory_limit=".ini_get("memory_limit").PHP_EOL;
echo "opcache.memory_consumption=".ini_get("opcache.memory_consumption").PHP_EOL;
echo "opcache.max_accelerated_files=".ini_get("opcache.max_accelerated_files").PHP_EOL;
echo "realpath_cache_size=".ini_get("realpath_cache_size").PHP_EOL;
require "/var/www/html/wp-config.php";
echo "env=".(defined("WP_ENVIRONMENT_TYPE")?WP_ENVIRONMENT_TYPE:"<none>").PHP_EOL;
echo "cron_disabled=".(defined("DISABLE_WP_CRON") && DISABLE_WP_CRON ? "true":"false").PHP_EOL;
'

echo "=== Local smoke ==="
for p in / /wp-login.php /wp-admin/; do
  code="$(curl --max-time 35 -ksS --resolve cutellashop.ir:443:127.0.0.1 -o /dev/null -w '%{http_code}' "https://cutellashop.ir$p" || true)"
  echo "$p HTTP=$code"
  case "$p:$code" in
    /:200|/wp-login.php:200|/wp-admin/:302|/wp-admin/:200) ;;
    *) echo "Unexpected local response"; exit 31 ;;
  esac
done

echo "=== Public Cloudflare smoke ==="
for p in / /wp-login.php; do
  curl --max-time 35 -ksS -D /tmp/cutella-headers -o /tmp/cutella-body     -w "$p HTTP=%{http_code} TTFB=%{time_starttransfer} TOTAL=%{time_total} BYTES=%{size_download}\n"     "https://cutellashop.ir$p"
done
grep -Ei '^(server:|cf-ray:|cf-cache-status:|content-encoding:|cache-control:)' /tmp/cutella-headers || true
grep -Eio '<title>[^<]{0,200}</title>' /tmp/cutella-body | head -1 || true

echo "=== Final data check ==="
docker exec vc-db-cutella mariadb -uroot -p"$CUTELLA_DB_ROOT_PASSWORD" vestacos_cutella -N -e "SELECT CONCAT('hpos_orders=',COUNT(*),' latest=',COALESCE(MAX(date_created_gmt),'')) FROM wp_wc_orders;"

echo "CUTELLA_PRODUCTION_OK"
