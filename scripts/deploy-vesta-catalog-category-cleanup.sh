#!/usr/bin/env bash
set -euo pipefail
BASE=/srv/vestacutella
SCRIPT=/tmp/vesta-flatten-catalog-categories.php
[[ -s "$SCRIPT" ]]
set -a; source "$BASE/.env"; set +a
umask 077
BACKUP="/srv/backups/vesta-catalog-category-cleanup-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -m 0700 "$BACKUP"
for path in / /shop/ /my-account/; do
  code="$(curl -kLsS --max-time 40 --noproxy '*' --resolve vesta-cosmetics.ir:443:127.0.0.1 -o /dev/null -w '%{http_code}' "https://vesta-cosmetics.ir$path")"
  echo "BEFORE $path $code"
  [[ "$code" == 200 ]]
done
echo "BACKUP_STARTED"
docker exec vc-db-vesta mariadb-dump -uroot -p"$VESTA_DB_ROOT_PASSWORD" --single-transaction --quick vestacos_m | gzip -1 > "$BACKUP/vesta-before-categories.sql.gz"
test -s "$BACKUP/vesta-before-categories.sql.gz"
echo "CATEGORY_BACKUP_SAVED"
docker cp "$SCRIPT" vc-vesta:/tmp/vesta-flatten-catalog-categories.php
docker exec vc-vesta php -d memory_limit=768M -r 'include "/tmp/vesta-flatten-catalog-categories.php";'
echo "=== verify taxonomy, navigation and in-stock product availability ==="
docker exec vc-vesta php -r '
require "/var/www/html/wp-load.php";
$root=get_term_by("slug","cutella-products","product_cat");
if ($root) { echo "BRANDED_ROOT_STILL_EXISTS\n";exit(20); }
$menus=array_unique(array_filter(array_map("intval",get_nav_menu_locations())));
$group=0;
foreach ($menus as $menuid) {
 foreach((array)wp_get_nav_menu_items($menuid) as $item) {
   if(trim((string)$item->title)==="کیوتلا") {echo "BRANDED_MENU_STILL_EXISTS\n";exit(21);}
   if((string)get_post_meta((int)$item->ID,"_vc_vesta_catalog_group",true)==="1") $group=(int)$item->ID;
 }
}
if(!$group){echo "NEUTRAL_MENU_MISSING\n";exit(22);}
global $wpdb;
$missing=(int)$wpdb->get_var("SELECT COUNT(DISTINCT p.ID) FROM {$wpdb->posts} p
JOIN {$wpdb->postmeta} pm ON pm.post_id=p.ID AND pm.meta_key=\"_vc_cutella_source_product_id\"
WHERE p.post_status<>\"publish\"");
$total=(int)$wpdb->get_var("SELECT COUNT(DISTINCT p.ID) FROM {$wpdb->posts} p JOIN {$wpdb->postmeta} pm ON pm.post_id=p.ID
WHERE p.post_type=\"product\" AND p.post_status=\"publish\" AND pm.meta_key=\"_vc_cutella_source_product_id\"");
echo "LIVE_MIGRATED_PRODUCTS ".$total." not_published=".$missing." neutral_menu=".$group.PHP_EOL;
if($missing!==0 || $total!==107) exit(23);
echo "CATEGORY_NAVIGATION_DB_VERIFIED\n";
'
for path in / /shop/ /my-account/; do
  code="$(curl -kLsS --max-time 45 --noproxy '*' --resolve vesta-cosmetics.ir:443:127.0.0.1 -o /dev/null -w '%{http_code}' "https://vesta-cosmetics.ir$path")"
  echo "AFTER $path $code"
  [[ "$code" == 200 ]]
done
echo "VESTA_CATALOG_BRAND_REMOVAL_SUCCESS"
