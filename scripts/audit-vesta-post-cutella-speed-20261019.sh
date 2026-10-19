#!/usr/bin/env bash
# Read-only, bounded production speed regression audit after 2026-10-18 catalog import.
set -uo pipefail
export LC_ALL=C
echo "AUDIT_AT_UTC=$(date -u +%FT%TZ)"
echo "=== HOST_HEALTH ==="
uptime | sed -E 's/.*(load average:.*)/\1/'
free -m | head -4
df -h / | tail -1
docker stats --no-stream --format 'container={{.Name}} cpu={{.CPUPerc}} mem={{.MemUsage}}' vc-nginx vc-vesta vc-db-vesta vc-redis vc-cutella 2>/dev/null || true
echo "=== ORIGIN_URL_TIMINGS ==="
for entry in 'vesta-cosmetics.ir /' 'vesta-cosmetics.ir /shop/' 'vesta-cosmetics.ir /product-category/decorative/' 'vesta-cosmetics.ir /wp-login.php' 'cutellashop.ir /'; do
  read -r d p <<<"$entry"
  for n in 1 2; do
    curl --noproxy '*' -kLfsS --max-time 20 --resolve "$d:443:127.0.0.1" -o /dev/null -w "url=$d$p run=$n status=%{http_code} ttfb=%{time_starttransfer} total=%{time_total} bytes=%{size_download}\n" "https://$d$p" || echo "ORIGIN_PROBE_FAILED $d$p run=$n"
  done
done
echo "=== UNCACHED_2_REQUESTS_VESTA ==="
for p in / /shop/; do
  curl --noproxy '*' -kLfsS --max-time 25 --resolve 'vesta-cosmetics.ir:443:127.0.0.1' -o /dev/null -w "url=$p cache_bypass_query status=%{http_code} ttfb=%{time_starttransfer} total=%{time_total} bytes=%{size_download}\n" "https://vesta-cosmetics.ir$p?vc_speed_audit=$(date +%s%N)" || true
done
echo "=== RESPONSE_CACHE_HEADERS ==="
for p in / /shop/; do
  tmp=$(mktemp)
  curl --noproxy '*' -kLsS --max-time 25 --resolve 'vesta-cosmetics.ir:443:127.0.0.1' -D "$tmp" -o /dev/null "https://vesta-cosmetics.ir$p" || true
  echo "headers_path=$p"
  grep -Ei '^(HTTP/|cache-control:|x-cache:|x-rocket:|x-vc-|x-fastcgi-cache:|age:|content-encoding:|vary:|server:)' "$tmp" | head -14 || true
  rm -f "$tmp"
done
echo "=== CATALOG_IMAGE_STORAGE ==="
du -sh /srv/vestacutella/runtime/vesta/wp-content/uploads/cutella-import 2>/dev/null || true
find /srv/vestacutella/runtime/vesta/wp-content/uploads/cutella-import -type f -printf '%s\n' 2>/dev/null | awk '{n++;sum+=$1;if($1>1024*1024)big++} END{printf "imported_media_files=%d total_MB=%.1f over_1MB=%d\n",n,sum/1048576,big}'
echo "=== DB_AGGREGATES ==="
if test -r /srv/vestacutella/.env; then
  set -a
  source /srv/vestacutella/.env
  set +a
  docker exec vc-db-vesta mariadb -uroot -p"$VESTA_DB_ROOT_PASSWORD" vestacos_m -N -e "
SELECT 'product_post_counts',post_type,post_status,COUNT(*) FROM wp_posts WHERE post_type IN ('product','product_variation') GROUP BY post_type,post_status;
SELECT 'imported_cutella_products',COUNT(*) FROM wp_postmeta WHERE meta_key='_vc_cutella_source_product_id';
SELECT 'imported_cutella_variations',COUNT(*) FROM wp_postmeta WHERE meta_key='_vc_cutella_source_variation_id';
SELECT 'autoload_option_rows_bytes',COUNT(*),COALESCE(SUM(LENGTH(option_value)),0) FROM wp_options WHERE autoload IN ('yes','on','auto','auto-on');
SELECT 'scheduler_status',status,COUNT(*) FROM wp_actionscheduler_actions GROUP BY status;
SELECT 'table_size',table_name,ROUND((data_length+index_length)/1024/1024,1) FROM information_schema.tables WHERE table_schema='vestacos_m' AND table_name IN ('wp_posts','wp_postmeta','wp_options','wp_term_relationships','wp_actionscheduler_actions','wp_actionscheduler_logs');
SHOW GLOBAL STATUS WHERE Variable_name IN ('Threads_running','Slow_queries','Created_tmp_disk_tables');
" 2>&1 | grep -v -iE '(password on the command line|VESTA_DB_ROOT_PASSWORD|denied)' | tail -45 || true
  unset VESTA_DB_ROOT_PASSWORD
else echo "VESTA_ENV_NOT_READABLE"; fi
echo "=== OBJECT_CACHE_AND_SCHEDULER ==="
docker exec vc-redis redis-cli -n 1 dbsize 2>/dev/null || true
docker exec vc-redis redis-cli info memory 2>/dev/null | grep -E '^(used_memory_human|maxmemory_human|evicted_keys)' | head -4 || true
echo "=== CACHES_PRESENT ==="
for p in /srv/vestacutella/runtime/vesta/wp-content/cache/wp-rocket/vesta-cosmetics.ir /srv/vestacutella/runtime/vesta/wp-content/cache/wp-rocket/vesta-cosmetics.ir/shop; do
 if test -d "$p"; then echo "cache_path=$p files=$(find "$p" -maxdepth 1 -type f | wc -l)"; else echo "cache_path=$p absent";fi
done
echo "=== RECENT_RUNTIME_FATAL_COUNTS ==="
docker logs --since 15m vc-vesta 2>&1 | grep -Eic 'PHP Fatal error|Allowed memory size|Out of memory|Maximum execution time|AH[0-9]+:.*error' || true
docker exec vc-nginx nginx -t 2>&1 | tail -2 || true
echo "AUDIT_READ_ONLY_COMPLETED"


echo "=== REDIS_EVICTION_AND_HIT_RATE ==="
docker exec vc-redis redis-cli info stats 2>/dev/null | grep -E '^(evicted_keys|keyspace_hits|keyspace_misses|expired_keys|total_error_replies):' || true
docker exec vc-redis redis-cli info keyspace 2>/dev/null | grep '^db[01]:' || true
echo "=== POST_IMPORT_STATUS_AND_RECENT_ACTIONS ==="
if test -r /srv/vestacutella/.env; then
  set -a; source /srv/vestacutella/.env; set +a
  docker exec vc-db-vesta mariadb -uroot -p"$VESTA_DB_ROOT_PASSWORD" vestacos_m -N -e "
SELECT 'imported_product_publication_status',p.post_status,COUNT(*)
  FROM wp_posts p JOIN wp_postmeta pm ON p.ID=pm.post_id
 WHERE pm.meta_key='_vc_cutella_source_product_id' GROUP BY p.post_status;
SELECT 'actions_created_last_48h',status,COUNT(*)
  FROM wp_actionscheduler_actions WHERE scheduled_date_gmt >= UTC_TIMESTAMP() - INTERVAL 48 HOUR
 GROUP BY status;
" 2>&1 | grep -v -iE '(password on the command line|denied)' || true
  unset VESTA_DB_ROOT_PASSWORD
fi
echo "=== HOME_HTML_COMPONENT_COUNTS ==="
tmp=$(mktemp)
curl -kLsS --noproxy '*' --max-time 20 --resolve vesta-cosmetics.ir:443:127.0.0.1 "https://vesta-cosmetics.ir/" -o "$tmp"
python3 - "$tmp" <<'PY'
import sys,re
s=open(sys.argv[1],encoding='utf-8',errors='replace').read()
for name,regex in [('html_bytes',r'(?s)^.*$'),('img_elements',r'<img\b'),('webp_picture_sources',r'<source\b[^>]+image/webp'),('lazy_img',r'<img\b[^>]+loading=["\x27]lazy'),('cutella_image_links',r'cutella-import/'),('products_markup',r'\bproduct-wrapper\b'),('script_src',r'<script[^>]+src='),('stylesheet_links',r'<link[^>]+stylesheet')]:
 print(name,len(s.encode()) if name=='html_bytes' else len(re.findall(regex,s,re.I)))
PY
rm -f "$tmp"
echo "AUDIT_FOLLOWUP_READONLY_COMPLETED"
