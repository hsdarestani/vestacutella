#!/usr/bin/env bash
# Read-only inventory preflight before any Cutella -> Vesta catalog migration.
set -euo pipefail
set -a
source /srv/vestacutella/.env
set +a
sql_cutella() {
  docker exec vc-db-cutella mariadb --batch --skip-column-names -uroot -p"$CUTELLA_DB_ROOT_PASSWORD" vestacos_cutella -e "$1" 2>/dev/null
}
sql_vesta() {
  docker exec vc-db-vesta mariadb --batch --skip-column-names -uroot -p"$VESTA_DB_ROOT_PASSWORD" vestacos_m -e "$1" 2>/dev/null
}
echo "=== service presence ==="
for name in vc-db-cutella vc-db-vesta vc-cutella vc-vesta; do
  docker ps --filter name="^/$name$" --format '{{.Names}} {{.Status}}' | head -1
done
echo "=== source: published product stock and types ==="
sql_cutella "
SELECT COALESCE(ty.name,'(no type)'), COALESCE(ss.meta_value,'(unset)') stock_status, COUNT(DISTINCT p.ID)
FROM wp_posts p
LEFT JOIN wp_postmeta ss ON ss.post_id=p.ID AND ss.meta_key='_stock_status'
LEFT JOIN wp_term_relationships tr ON tr.object_id=p.ID
LEFT JOIN wp_term_taxonomy tt ON tt.term_taxonomy_id=tr.term_taxonomy_id AND tt.taxonomy='product_type'
LEFT JOIN wp_terms ty ON ty.term_id=tt.term_id
WHERE p.post_type='product' AND p.post_status='publish'
GROUP BY ty.name, ss.meta_value ORDER BY COUNT(DISTINCT p.ID) DESC;
SELECT 'source_variations',COUNT(*),SUM(CASE WHEN pm.meta_value='instock' THEN 1 ELSE 0 END)
FROM wp_posts p LEFT JOIN wp_postmeta pm ON pm.post_id=p.ID AND pm.meta_key='_stock_status'
WHERE p.post_type='product_variation' AND p.post_status='publish';
SELECT 'source_categories',COUNT(*) FROM wp_term_taxonomy WHERE taxonomy='product_cat';
SELECT 'source_product_attachments',COUNT(DISTINCT pm.meta_value)
FROM wp_posts p JOIN wp_postmeta pm ON p.ID=pm.post_id AND pm.meta_key='_thumbnail_id'
WHERE p.post_type='product' AND p.post_status='publish';
SELECT 'source_products_with_sku',COUNT(DISTINCT p.ID)
FROM wp_posts p JOIN wp_postmeta sku ON sku.post_id=p.ID AND sku.meta_key='_sku' AND sku.meta_value <> ''
WHERE p.post_type IN ('product','product_variation') AND p.post_status='publish';
"
echo "=== destination: current products and categories ==="
sql_vesta "
SELECT 'destination_published_products',COUNT(*) FROM wp_posts WHERE post_type='product' AND post_status='publish';
SELECT 'destination_categories',COUNT(*) FROM wp_term_taxonomy WHERE taxonomy='product_cat';
SELECT 'destination_with_sku',COUNT(DISTINCT p.ID)
FROM wp_posts p JOIN wp_postmeta sku ON sku.post_id=p.ID AND sku.meta_key='_sku' AND sku.meta_value <> ''
WHERE p.post_type IN ('product','product_variation') AND p.post_status='publish';
SELECT 'currency',option_value FROM wp_options WHERE option_name='woocommerce_currency';
"
echo "=== source currency ==="
sql_cutella "SELECT 'currency',option_value FROM wp_options WHERE option_name='woocommerce_currency';"
echo "=== source categories with products (first 60) ==="
sql_cutella "
SELECT t.name,tt.parent,tt.count FROM wp_terms t
JOIN wp_term_taxonomy tt ON tt.term_id=t.term_id
WHERE tt.taxonomy='product_cat' AND tt.count>0
ORDER BY tt.count DESC LIMIT 60;"
echo "=== source WooCommerce CLI smoke (read only) ==="
timeout 50 docker exec vc-cutella php -d memory_limit=512M -r 'require "/var/www/html/wp-load.php"; echo "woocommerce=".(class_exists("WooCommerce")?"yes":"no")." version=".(defined("WC_VERSION")?WC_VERSION:"unknown").PHP_EOL; $p=wc_get_products(array("status"=>"publish","limit"=>1)); foreach($p as $x) echo "one_product_type=".$x->get_type().PHP_EOL;' 2>&1 | tail -20 || echo "SOURCE_PHP_CLI_NOT_READY"
echo "=== destination WooCommerce CLI smoke (read only) ==="
timeout 50 docker exec vc-vesta php -d memory_limit=512M -r 'require "/var/www/html/wp-load.php"; echo "woocommerce=".(class_exists("WooCommerce")?"yes":"no")." version=".(defined("WC_VERSION")?WC_VERSION:"unknown").PHP_EOL; $p=wc_get_products(array("status"=>"publish","limit"=>1)); foreach($p as $x) echo "one_product_type=".$x->get_type().PHP_EOL;' 2>&1 | tail -20 || echo "DEST_PHP_CLI_NOT_READY"
echo "=== source product attribute taxonomies ==="
sql_cutella "SELECT 'attribute_taxonomies',COUNT(*) FROM wp_woocommerce_attribute_taxonomies;"
echo "=== source term count by product attributes ==="
sql_cutella "SELECT taxonomy,COUNT(*) FROM wp_term_taxonomy WHERE taxonomy LIKE 'pa_%' GROUP BY taxonomy ORDER BY COUNT(*) DESC LIMIT 20;"
echo "=== destination relevant menu names (no settings) ==="
sql_vesta "SELECT t.name,tt.term_id FROM wp_terms t JOIN wp_term_taxonomy tt ON tt.term_id=t.term_id WHERE tt.taxonomy='nav_menu' LIMIT 20;"
echo "CUTELLA_TO_VESTA_READONLY_AUDIT_OK"
