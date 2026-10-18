#!/usr/bin/env bash
# Read-only operational progress of one-way Cutella catalog staging.
set -euo pipefail
set -a; source /srv/vestacutella/.env; set +a
echo "=== product/variation progress ==="
echo "observed_at_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
docker exec vc-db-vesta mariadb -uroot -p"$VESTA_DB_ROOT_PASSWORD" vestacos_m -N -e "
SELECT 'imported_parents',COUNT(DISTINCT post_id) FROM wp_postmeta WHERE meta_key='_vc_cutella_source_product_id';
SELECT 'imported_variations',COUNT(DISTINCT post_id) FROM wp_postmeta WHERE meta_key='_vc_cutella_source_variation_id';
SELECT 'imported_parent_status',p.post_status,COUNT(*) FROM wp_posts p JOIN wp_postmeta pm ON pm.post_id=p.ID AND pm.meta_key='_vc_cutella_source_product_id' GROUP BY p.post_status;
SELECT 'root_category',COUNT(*) FROM wp_terms t JOIN wp_term_taxonomy tt ON tt.term_id=t.term_id WHERE tt.taxonomy='product_cat' AND t.slug='cutella-products';
" 2>/dev/null
echo "=== imported category taxonomy (read only) ==="
docker exec vc-db-vesta mariadb -uroot -p"$VESTA_DB_ROOT_PASSWORD" vestacos_m -N -e "
SELECT 'source_category_terms',COUNT(DISTINCT term_id) FROM wp_termmeta WHERE meta_key='_vc_cutella_source_category_id';
SELECT 'root_assigned_products',COUNT(DISTINCT tr.object_id)
FROM wp_term_relationships tr JOIN wp_term_taxonomy tt ON tt.term_taxonomy_id=tr.term_taxonomy_id
JOIN wp_terms t ON t.term_id=tt.term_id JOIN wp_posts p ON p.ID=tr.object_id
WHERE tt.taxonomy='product_cat' AND t.slug='cutella-products' AND p.post_status='publish';
" 2>/dev/null
echo "=== navigation menu slots (read only) ==="
docker exec vc-vesta php -r '
require "/var/www/html/wp-load.php";
foreach (get_nav_menu_locations() as $location=>$id) {
  if (preg_match("/main|mobile|primary|header|menu/i", $location)) {
    $items=wp_get_nav_menu_items((int)$id);
    $found=0;
    foreach ((array)$items as $item) if ($item->object==="product_cat" && $item->title==="کیوتلا") $found++;
    echo "MENU ".$location." assigned=".$id." cutella_links=".$found.PHP_EOL;
  }
}
' 2>&1 | tail -35
echo "=== image-copy size ==="
du -sh /srv/vestacutella/runtime/vesta/wp-content/uploads/cutella-import 2>/dev/null || true
echo "=== PHP processes (no commands or credentials) ==="
ps -eo comm,etime,pcpu,rss | grep -E '^(php|mariadb|mysqld)' | tail -20 || true
echo "CATALOG_PROGRESS_READONLY_OK"
