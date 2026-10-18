#!/usr/bin/env bash
set -euo pipefail
MODE="${1:---dry-run}"
case "$MODE" in --dry-run|--apply) ;; *) exit 2;; esac
BASE=/srv/vestacutella
set -a; source "$BASE/.env"; set +a
test -s /tmp/cutella-remove-korean-food.php
docker cp /tmp/cutella-remove-korean-food.php vc-cutella:/tmp/cutella-remove-korean-food.php
# Cutella's older ionCube PHP may segfault on php -l; use PHP -r with include.
docker exec vc-cutella php -d memory_limit=512M -r 'include "/tmp/cutella-remove-korean-food.php";' -- dry-run
if [[ "$MODE" == "--dry-run" ]]; then echo "CUTELLA_KOREAN_CLEANUP_PREVIEW_OK";exit 0;fi
umask 077
BACKUP="/srv/backups/cutella-korean-food-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -m 0700 "$BACKUP"
docker exec vc-db-cutella mariadb-dump -uroot -p"$CUTELLA_DB_ROOT_PASSWORD" --single-transaction --quick vestacos_cutella | gzip -1 > "$BACKUP/cutella-before-food-cleanup.sql.gz"
test -s "$BACKUP/cutella-before-food-cleanup.sql.gz"
echo "CUTELLA_BACKUP_OK $BACKUP"
docker exec vc-cutella php -d memory_limit=512M -r 'include "/tmp/cutella-remove-korean-food.php";' -- apply
docker exec vc-cutella php -r '
require "/var/www/html/wp-load.php";
$t=get_term(27,"product_cat");
if($t && !is_wp_error($t))exit(32);
foreach(array(12911,27942,27945,27948,28454) as $id)
 if(get_post_status($id)!=="trash")exit(33);
echo "CUTELLA_KOREAN_TRASH_VERIFIED\n";
'
for host in vesta-cosmetics.ir cutellashop.ir; do
  code="$(curl -kLsS --max-time 45 -o /dev/null -w '%{http_code}' "https://$host/")"
  echo "STORE_ALIVE host=$host status=$code"
  [[ "$code" == 200 ]]
done
echo "CUTELLA_KOREAN_SOURCE_CLEANUP_SUCCESS"
