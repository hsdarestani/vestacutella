#!/usr/bin/env bash
set -euo pipefail
source /srv/vestacutella/.env
TARGET=/srv/vestacutella/repo/infra/nginx.conf
BACKUP="/srv/backups/nginx-fresh-products-$(date -u +%Y%m%dT%H%M%SZ).conf"
cp "$TARGET" "$BACKUP"
install -m 644 /tmp/nginx.conf "$TARGET"
docker exec vc-nginx nginx -t
docker exec vc-nginx nginx -s reload
sleep 3

vslug="$(docker exec vc-db-vesta mariadb -uroot -p"$VESTA_DB_ROOT_PASSWORD" vestacos_m -N -e "SELECT post_name FROM wp_posts WHERE post_type='product' AND post_status='publish' ORDER BY post_modified_gmt DESC LIMIT 1;")"
cslug="$(docker exec vc-db-cutella mariadb -uroot -p"$CUTELLA_DB_ROOT_PASSWORD" vestacos_cutella -N -e "SELECT post_name FROM wp_posts WHERE post_type='product' AND post_status='publish' ORDER BY post_modified_gmt DESC LIMIT 1;")"

echo "=== Vesta product ==="
curl -ksSI --max-time 30 "https://vesta-cosmetics.ir/product/$vslug/" | grep -Ei '^(HTTP/|cache-control:|pragma:|expires:|cf-cache-status:|server:)' || true
curl -ksS --max-time 30 -o /dev/null -w 'ttfb=%{time_starttransfer} total=%{time_total}\n' "https://vesta-cosmetics.ir/product/$vslug/" || true

echo "=== Cutella product ==="
curl -ksSI --max-time 30 "https://cutellashop.ir/product/$cslug/" | grep -Ei '^(HTTP/|cache-control:|pragma:|expires:|cf-cache-status:|server:)' || true
curl -ksS --max-time 30 -o /dev/null -w 'ttfb=%{time_starttransfer} total=%{time_total}\n' "https://cutellashop.ir/product/$cslug/" || true

echo "FRESH_PRODUCT_HEADERS_OK"
