#!/usr/bin/env bash
set -euo pipefail
BASE=/srv/vestacutella
ENVFILE=$BASE/.env
set -a
source "$ENVFILE"
set +a

extract_plugins() {
  local db="$1"
  val="$(docker exec vc-db-vesta mariadb -uroot -p"$VESTA_DB_ROOT_PASSWORD" "$db" -N -B -e "SELECT option_value FROM wp_options WHERE option_name='active_plugins' LIMIT 1;")"
  DBLABEL="$db" RAW="$val" php -r '
    $a=@unserialize(getenv("RAW"));
    if(!is_array($a)){fwrite(STDERR,"UNSERIALIZE_FAILED ".getenv("DBLABEL")."\n"); exit(2);}
    foreach($a as $p) echo $p.PHP_EOL;
  '
}

mkdir -p /tmp/vesta-compare
extract_plugins vestacos_m | sort > /tmp/vesta-compare/main.txt
extract_plugins vestacos_candidate | sort > /tmp/vesta-compare/candidate.txt

echo "=== MAIN ACTIVE PLUGINS ==="
cat /tmp/vesta-compare/main.txt
echo "=== CANDIDATE ACTIVE PLUGINS ==="
cat /tmp/vesta-compare/candidate.txt
echo "=== ONLY IN CANDIDATE ==="
comm -13 /tmp/vesta-compare/main.txt /tmp/vesta-compare/candidate.txt || true
echo "=== ONLY IN MAIN ==="
comm -23 /tmp/vesta-compare/main.txt /tmp/vesta-compare/candidate.txt || true

echo "=== candidate freshness ==="
docker exec vc-db-vesta mariadb -uroot -p"$VESTA_DB_ROOT_PASSWORD" vestacos_candidate -N -e "SELECT CONCAT('orders=',COUNT(*),' latest=',MAX(post_date_gmt)) FROM wp_posts WHERE post_type='shop_order';
 SELECT CONCAT('products=',COUNT(*),' latest_modified=',MAX(post_modified_gmt)) FROM wp_posts WHERE post_type='product';
 SELECT CONCAT(option_name,'=',option_value) FROM wp_options WHERE option_name IN ('home','siteurl','stylesheet','template') ORDER BY option_name;"

echo "VESTA_CANDIDATE_INSPECT_OK"
