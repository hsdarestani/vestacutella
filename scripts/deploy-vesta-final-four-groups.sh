#!/usr/bin/env bash
set -euo pipefail
MODE="${1:---dry-run}"
case "$MODE" in --dry-run|--apply) ;; *) echo INVALID_MODE;exit 2;; esac
BASE=/srv/vestacutella
SOURCE=/tmp/vesta-final-four-groups.php
test -s "$SOURCE"
set -a; source "$BASE/.env"; set +a
docker ps --filter name='^/vc-vesta$' --format '{{.Names}}' | grep -qx vc-vesta
docker ps --filter name='^/vc-db-vesta$' --format '{{.Names}}' | grep -qx vc-db-vesta
docker cp "$SOURCE" vc-vesta:/tmp/vesta-final-four-groups.php
echo "FOUR_GROUP_MODE=$MODE"
docker exec vc-vesta php -d memory_limit=768M -r 'include "/tmp/vesta-final-four-groups.php";' -- dry-run
if [[ "$MODE" == '--dry-run' ]]; then echo "FOUR_GROUP_DRY_RUN_OK";exit 0; fi
for path in / /shop/ /my-account/; do
  status="$(curl -kLsS --max-time 40 --noproxy '*' --resolve vesta-cosmetics.ir:443:127.0.0.1 -o /dev/null -w '%{http_code}' "https://vesta-cosmetics.ir$path")"
  [[ "$status" == 200 ]] || { echo "BEFORE_UNHEALTHY $path $status";exit 7; }
done
umask 077
backup="/srv/backups/vesta-final-four-groups-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -m 0700 "$backup"
docker exec vc-db-vesta mariadb-dump -uroot -p"$VESTA_DB_ROOT_PASSWORD" --single-transaction --quick vestacos_m | gzip -1 > "$backup/vesta-before-categories.sql.gz"
test -s "$backup/vesta-before-categories.sql.gz"
echo "FULL_VESTA_DB_BACKUP_SAVED $backup"
docker exec vc-vesta php -d memory_limit=768M -r 'include "/tmp/vesta-final-four-groups.php";' -- apply
docker exec vc-vesta php -r '
require "/var/www/html/wp-load.php";
foreach(array(1772,1777,1774,1769,1719,1783) as $id)if(get_term($id,"product_cat")&&!is_wp_error(get_term($id,"product_cat")))exit(30);
foreach(array(1731,1767,946,1053,950) as $id)if(!get_term($id,"product_cat"))exit(31);
if((int)get_term_meta(1731,"order",true)!==2 || (int)get_term_meta(1767,"order",true)!==3)exit(32);
$group=get_post(102454);
if($group && $group->post_status!=="trash")exit(33);
global $wpdb;
$published=(int)$wpdb->get_var("SELECT COUNT(DISTINCT p.ID) FROM {$wpdb->posts} p JOIN {$wpdb->postmeta} m ON m.post_id=p.ID AND m.meta_key=\"_vc_cutella_source_product_id\" WHERE p.post_status=\"publish\"");
if($published<100 || $published>107)exit(34);
echo "FOUR_GROUP_DB_VERIFY_OK published_imports=".$published.PHP_EOL;
'
for path in / /shop/ /my-account/; do
  status="$(curl -kLsS --max-time 45 --noproxy '*' --resolve vesta-cosmetics.ir:443:127.0.0.1 -o /dev/null -w '%{http_code}' "https://vesta-cosmetics.ir$path")"
  echo "AFTER_STATUS path=$path status=$status"
  [[ "$status" == 200 ]] || exit 41
done
echo "FOUR_GROUP_DEPLOY_SUCCESS"
