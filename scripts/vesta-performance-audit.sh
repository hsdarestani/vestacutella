#!/usr/bin/env bash
set -euo pipefail
BASE=/srv/vestacutella
ENVFILE=$BASE/.env
set -a
source "$ENVFILE"
set +a

echo "=== SYSTEM ==="
uptime
free -h
df -h /
docker stats --no-stream vc-vesta vc-db-vesta vc-nginx

echo "=== PHP / OPCACHE ==="
docker exec vc-vesta php -r '
echo "php=".PHP_VERSION.PHP_EOL;
echo "memory_limit=".ini_get("memory_limit").PHP_EOL;
echo "opcache.enable=".ini_get("opcache.enable").PHP_EOL;
echo "opcache.memory_consumption=".ini_get("opcache.memory_consumption").PHP_EOL;
echo "opcache.max_accelerated_files=".ini_get("opcache.max_accelerated_files").PHP_EOL;
echo "realpath_cache_size=".ini_get("realpath_cache_size").PHP_EOL;
'

echo "=== MARIADB ==="
docker exec vc-db-vesta mariadb -uroot -p"$VESTA_DB_ROOT_PASSWORD" -N -e "
SHOW VARIABLES WHERE Variable_name IN ('innodb_buffer_pool_size','innodb_log_file_size','max_connections','tmp_table_size','max_heap_table_size');
SHOW GLOBAL STATUS WHERE Variable_name IN ('Threads_connected','Threads_running','Created_tmp_disk_tables','Created_tmp_tables','Innodb_buffer_pool_reads','Innodb_buffer_pool_read_requests','Slow_queries');
"

echo "=== WORDPRESS DB ==="
docker exec vc-db-vesta mariadb -uroot -p"$VESTA_DB_ROOT_PASSWORD" vestacos_m -N -e "
SELECT CONCAT('options_rows=',COUNT(*)) FROM wp_options;
SELECT CONCAT('autoload_bytes=',COALESCE(SUM(LENGTH(option_value)),0)) FROM wp_options WHERE autoload IN ('yes','on','auto','auto-on');
SELECT CONCAT('transients=',COUNT(*),' bytes=',COALESCE(SUM(LENGTH(option_value)),0)) FROM wp_options WHERE option_name LIKE '_transient_%' OR option_name LIKE '_site_transient_%';
SELECT CONCAT('action_scheduler_pending=',COUNT(*)) FROM wp_actionscheduler_actions WHERE status='pending';
SELECT CONCAT('posts=',COUNT(*)) FROM wp_posts;
SELECT CONCAT('postmeta=',COUNT(*)) FROM wp_postmeta;
SELECT CONCAT('options_table_mb=',ROUND((data_length+index_length)/1024/1024,1)) FROM information_schema.tables WHERE table_schema='vestacos_m' AND table_name='wp_options';
SELECT CONCAT('postmeta_table_mb=',ROUND((data_length+index_length)/1024/1024,1)) FROM information_schema.tables WHERE table_schema='vestacos_m' AND table_name='wp_postmeta';
" 2>/dev/null || true

echo "=== LOCAL RESPONSE TIMINGS ==="
for u in / /shop/ /wp-login.php; do
  for i in 1 2 3; do
    curl -ksS --resolve vesta-cosmetics.ir:443:127.0.0.1 -o /dev/null       -w "$u run=$i code=%{http_code} dns=%{time_namelookup} connect=%{time_connect} tls=%{time_appconnect} ttfb=%{time_starttransfer} total=%{time_total} size=%{size_download}\n"       "https://vesta-cosmetics.ir$u" || true
  done
done

echo "=== PUBLIC RESPONSE TIMINGS ==="
for u in / /shop/ /wp-login.php; do
  for i in 1 2 3; do
    curl -ksS -o /dev/null       -w "$u run=$i code=%{http_code} dns=%{time_namelookup} connect=%{time_connect} tls=%{time_appconnect} ttfb=%{time_starttransfer} total=%{time_total} size=%{size_download}\n"       "https://vesta-cosmetics.ir$u" || true
  done
done

echo "=== HEADERS ==="
curl -ksSI https://vesta-cosmetics.ir/ | grep -Ei '^(HTTP/|server:|content-type:|content-length:|content-encoding:|cache-control:|expires:|vary:|x-|strict-transport-security:)' || true

echo "=== NGINX CONFIG TEST ==="
docker exec vc-nginx nginx -t

echo "PERF_AUDIT_OK"
