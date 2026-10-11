#!/usr/bin/env bash
set -euo pipefail
BASE=/srv/vestacutella
INCOMING=/srv/migration/current
ENVFILE=$BASE/.env
DB="$INCOMING/cutella-db.sql.gz"

[[ -s "$DB" ]] || { echo "Missing $DB"; exit 2; }

set -a
source "$ENVFILE"
set +a

echo "=== uploaded Cutella dump ==="
ls -lh --time-style=long-iso "$DB"

echo "=== backing up current Hetzner Cutella DB ==="
mkdir -p /srv/backups/pre-refresh
ts="$(date -u +%Y%m%dT%H%M%SZ)"
docker exec vc-db-cutella mariadb-dump -uroot -p"$CUTELLA_DB_ROOT_PASSWORD" --single-transaction --routines --triggers vestacos_cutella   | gzip -1 > "/srv/backups/pre-refresh/cutella-$ts.sql.gz"

echo "=== stopping Cutella staging app ==="
docker stop vc-cutella >/dev/null || true

echo "=== importing latest Cutella DB ==="
docker exec vc-db-cutella mariadb -uroot -p"$CUTELLA_DB_ROOT_PASSWORD" -e   "DROP DATABASE IF EXISTS \`vestacos_cutella\`; CREATE DATABASE \`vestacos_cutella\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; GRANT ALL PRIVILEGES ON \`vestacos_cutella\`.* TO 'vestacos_cutella'@'%'; FLUSH PRIVILEGES;"

gzip -cd "$DB"   | sed -E 's/DEFINER=\`[^\`]+\`@\`[^\`]+\`//g'   | docker exec -i vc-db-cutella mariadb -uroot -p"$CUTELLA_DB_ROOT_PASSWORD" vestacos_cutella

echo "=== starting Cutella staging app ==="
docker start vc-cutella >/dev/null
sleep 5

echo "=== verify latest order/product timestamps ==="
docker exec vc-cutella php -r '
require "/var/www/html/wp-config.php";
$db=new mysqli(DB_HOST,DB_USER,DB_PASSWORD,DB_NAME);
if($db->connect_errno){fwrite(STDERR,"DB connect failed\n"); exit(2);}
$p=$table_prefix ?? "wp_";
$q=$db->query("SELECT COUNT(*) c, MAX(post_date_gmt) m FROM `".$p."posts` WHERE post_type=\"shop_order\"");
if($q && ($r=$q->fetch_assoc())) echo "legacy_orders=".$r["c"]." latest_legacy_order_gmt=".$r["m"].PHP_EOL;
$t=$p."wc_orders";
$q=$db->query("SHOW TABLES LIKE \"".$db->real_escape_string($t)."\"");
if($q && $q->num_rows){
  $q2=$db->query("SELECT COUNT(*) c, MAX(date_created_gmt) m FROM `".$t."`");
  if($q2 && ($r=$q2->fetch_assoc())) echo "hpos_orders=".$r["c"]." latest_hpos_order_gmt=".$r["m"].PHP_EOL;
}
$q=$db->query("SELECT COUNT(*) c, MAX(post_modified_gmt) m FROM `".$p."posts` WHERE post_type=\"product\"");
if($q && ($r=$q->fetch_assoc())) echo "products=".$r["c"]." latest_product_modified_gmt=".$r["m"].PHP_EOL;
'

echo "=== smoke tests ==="
for p in / /wp-login.php /wp-admin/; do
  code="$(curl --max-time 30 -ksS --resolve cutellashop.ir:443:127.0.0.1 -o /dev/null -w '%{http_code}' "https://cutellashop.ir$p" || true)"
  echo "cutellashop.ir $p HTTP=$code"
done

echo "CUTELLA_CURRENT_DB_REFRESH_OK"
