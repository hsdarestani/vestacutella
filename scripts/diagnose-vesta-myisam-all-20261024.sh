#!/usr/bin/env bash
set -uo pipefail
echo "=== VESTA MYISAM INVENTORY ==="
date -Is
timeout 8 docker inspect --format 'db_vesta={{.State.Status}} oom={{.State.OOMKilled}}' vc-db-vesta || true
echo "TABLE_METADATA: name engine data_mb index_mb rows"
timeout 25 docker exec vc-db-vesta sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb -uroot --batch --skip-column-names -e "SELECT TABLE_NAME, ENGINE,ROUND(DATA_LENGTH/1048576,1),ROUND(INDEX_LENGTH/1048576,1),TABLE_ROWS FROM information_schema.TABLES WHERE TABLE_SCHEMA=0x7665737461636f735f6d AND ENGINE=0x4d794953414d ORDER BY DATA_LENGTH DESC"' | head -75
echo "=== TARGET TABLES MEDIUM CHECK READ ONLY ==="
for t in wp_commentmeta wp_wsal_metadata wp_wsal_occurrences; do
  echo "CHECKING=$t"
  timeout 110 docker exec vc-db-vesta sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb -uroot --batch "$MARIADB_DATABASE" -e "CHECK TABLE $1 MEDIUM;"' sh "$t" 2>&1 | tail -10
done
echo "=== BACKUPS ALREADY CREATED ==="
find /srv/backups/vesta-myisam-repair-20261024T192458Z -maxdepth 1 -type f -printf '%f %s bytes\n' 2>/dev/null | head -20
echo "=== STATUS ==="
for d in vesta-cosmetics.ir cutellashop.ir;do timeout 10 curl -ksS --connect-timeout 3 --max-time 8 --resolve "$d:443:127.0.0.1" -o /dev/null -w "$d HTTP=%{http_code}\n" "https://$d/" || true; done
echo "MYISAM_INVENTORY_END"
