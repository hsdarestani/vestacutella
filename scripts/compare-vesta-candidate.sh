#!/usr/bin/env bash
set -euo pipefail
BASE=/srv/vestacutella
INCOMING=/srv/migration/current
ENVFILE=$BASE/.env
DUMP="$INCOMING/vestacos_m.sql.gz"
[[ -s "$DUMP" ]] || DUMP="$INCOMING/vesta-db.sql.gz"
set -a
source "$ENVFILE"
set +a

echo "=== build candidate DB without touching live staging DB ==="
docker exec vc-db-vesta mariadb -uroot -p"$VESTA_DB_ROOT_PASSWORD" -e   "DROP DATABASE IF EXISTS vestacos_candidate; CREATE DATABASE vestacos_candidate CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"

DUMP_PATH="$DUMP" python3 - <<'PY' | docker exec -i vc-db-vesta mariadb -uroot -p"$VESTA_DB_ROOT_PASSWORD" vestacos_candidate
import gzip, os, re, sys
with gzip.open(os.environ["DUMP_PATH"],"rt",encoding="utf-8",errors="surrogateescape") as f:
    for line in f:
        line=re.sub(r"DEFINER=`[^`]+`@`[^`]+`","",line)
        sys.stdout.write(line)
PY

echo "=== candidate freshness ==="
docker exec vc-db-vesta mariadb -uroot -p"$VESTA_DB_ROOT_PASSWORD" vestacos_candidate -N -e "SELECT CONCAT('tables=',COUNT(*)) FROM information_schema.tables WHERE table_schema='vestacos_candidate';
 SELECT CONCAT('legacy_orders=',COUNT(*),' latest=',COALESCE(MAX(post_date_gmt),'')) FROM wp_posts WHERE post_type='shop_order';
 SELECT IF((SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='vestacos_candidate' AND table_name='wp_wc_orders')>0,
   (SELECT CONCAT('hpos_orders=',COUNT(*),' latest=',COALESCE(MAX(date_created_gmt),'')) FROM wp_wc_orders),
   'hpos_absent');
 SELECT CONCAT('products=',COUNT(*),' latest_modified=',COALESCE(MAX(post_modified_gmt),'')) FROM wp_posts WHERE post_type='product';
 SELECT CONCAT(option_name,'=',option_value) FROM wp_options WHERE option_name IN ('home','siteurl','stylesheet','template');"

echo "=== active plugin diff main vs candidate ==="
for db in vestacos_m vestacos_candidate; do
  val="$(docker exec vc-db-vesta mariadb -uroot -p"$VESTA_DB_ROOT_PASSWORD" "$db" -N -B -e "SELECT option_value FROM wp_options WHERE option_name='active_plugins' LIMIT 1;")"
  DBLABEL="$db" RAW="$val" php -r '
    $a=@unserialize(getenv("RAW"));
    echo "DB=".getenv("DBLABEL").PHP_EOL;
    if(!is_array($a)){echo "UNSERIALIZE_FAILED".PHP_EOL; exit;}
    foreach($a as $p) echo $p.PHP_EOL;
  '
done

echo "=== candidate recent orders IDs/status ==="
docker exec vc-db-vesta mariadb -uroot -p"$VESTA_DB_ROOT_PASSWORD" vestacos_candidate -N -e "SELECT id,status,date_created_gmt FROM wp_wc_orders ORDER BY date_created_gmt DESC LIMIT 10;" 2>/dev/null || true

echo "CANDIDATE_COMPARE_OK"
