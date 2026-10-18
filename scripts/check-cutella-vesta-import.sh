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
echo "=== image-copy size ==="
du -sh /srv/vestacutella/runtime/vesta/wp-content/uploads/cutella-import 2>/dev/null || true
echo "=== PHP processes (no commands or credentials) ==="
ps -eo comm,etime,pcpu,rss | grep -E '^(php|mariadb|mysqld)' | tail -20 || true
echo "CATALOG_PROGRESS_READONLY_OK"
