#!/usr/bin/env bash
set -euo pipefail
BASE=/srv/vestacutella
ENVFILE=$BASE/.env
set -a
source "$ENVFILE"
set +a

echo "=== active plugins ==="
docker exec vc-vesta php -r '
require "/var/www/html/wp-config.php";
$db=new mysqli(DB_HOST,DB_USER,DB_PASSWORD,DB_NAME);
$p=$table_prefix ?? "wp_";
$q=$db->query("SELECT option_value FROM `".$p."options` WHERE option_name=\"active_plugins\" LIMIT 1");
$r=$q?$q->fetch_assoc():null;
$a=$r?@unserialize($r["option_value"]):[];
if(is_array($a)) foreach($a as $x) echo $x.PHP_EOL;
'

echo "=== maintenance related options ==="
docker exec vc-db-vesta mariadb -uroot -p"$VESTA_DB_ROOT_PASSWORD" vestacos_m -N -e "
SELECT option_name,LEFT(option_value,500)
FROM wp_options
WHERE option_name LIKE '%maint%' OR option_name LIKE '%coming%' OR option_name LIKE '%under%'
ORDER BY option_name;
" || true

echo "=== maintenance files/plugins ==="
ls -la "$BASE/runtime/vesta/.maintenance" 2>/dev/null || true
find "$BASE/runtime/vesta/wp-content/plugins" -maxdepth 2 -type f \( -iname '*maintenance*' -o -iname '*coming*soon*' \) -printf '%p\n' | head -80 || true
find "$BASE/runtime/vesta/wp-content/plugins" -maxdepth 1 -type d -printf '%f\n' | grep -Ei 'maint|coming|under' || true

echo "=== sample product URLs from DB ==="
docker exec vc-db-vesta mariadb -uroot -p"$VESTA_DB_ROOT_PASSWORD" vestacos_m -N -e "
SELECT ID,post_name FROM wp_posts
WHERE post_type='product' AND post_status='publish'
ORDER BY post_modified_gmt DESC LIMIT 8;
"

echo "=== product response timings/signatures ==="
docker exec vc-db-vesta mariadb -uroot -p"$VESTA_DB_ROOT_PASSWORD" vestacos_m -N -e "
SELECT post_name FROM wp_posts
WHERE post_type='product' AND post_status='publish'
ORDER BY post_modified_gmt DESC LIMIT 5;
" | while read -r slug; do
  url="https://vesta-cosmetics.ir/product/$slug/"
  echo "--- $url ---"
  curl -ksS --max-time 30 -D /tmp/h -o /tmp/b -w 'code=%{http_code} ttfb=%{time_starttransfer} total=%{time_total} bytes=%{size_download}\n' "$url" || true
  grep -Eio '<title>[^<]{0,250}</title>' /tmp/b | head -1 || true
  grep -Eio 'maintenance|تعمیر|نگهداری|به.?روزرسانی|under construction|coming soon' /tmp/b | sort -u | head -20 || true
done

echo "=== recent product requests ==="
docker logs --since 20m vc-nginx 2>&1 | grep 'GET /product/' | tail -80 || true

echo "MAINTENANCE_DIAG_OK"
