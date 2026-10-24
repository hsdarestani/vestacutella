#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
exec 9>/run/lock/vesta-ubuntu-upgrade-20261024.lock
flock -n 9 || exit 30
echo "=== CORRUPTION ASSESSMENT ==="
date -Is;uptime;free -h
for c in vc-db-vesta vc-db-cutella;do
 echo "=== $c STORAGE ENGINES ==="
 docker exec "$c" sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb -uroot --batch --skip-column-names -e "SELECT TABLE_NAME,ENGINE,ROUND((DATA_LENGTH+INDEX_LENGTH)/1024/1024,1) MB,TABLE_ROWS FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME=\x27wp_commentmeta\x27" "$MARIADB_DATABASE"' || true
done
echo "=== VESTA TABLE ENGINE ==="
docker exec vc-db-vesta sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb -uroot --batch --skip-column-names -e "SELECT TABLE_NAME,ENGINE,TABLE_ROWS,DATA_LENGTH,INDEX_LENGTH FROM information_schema.TABLES WHERE TABLE_SCHEMA=\x27vestacos_m\x27 AND TABLE_NAME=\x27wp_commentmeta\x27"' || true
echo "=== BACKUP SALVAGE WITH CORRUPT TABLE EXCLUDED ==="
dest=/srv/backups/ubuntu-upgrade-20261024
mkdir -p "$dest";chmod 700 "$dest"
for e in vc-db-vesta:vesta-safe-minus-commentmeta vc-db-cutella:cutella-database;do
 IFS=: read -r c name <<< "$e"
 out="$dest/$name.sql.gz"
 if [ -s "$out" ] && gzip -t "$out";then echo "REUSE_VERIFIED $name";continue;fi
 tmp="$out.partial";rm -f "$tmp"
 if [ "$c" = vc-db-vesta ]; then
  timeout 480 docker exec "$c" sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb-dump -uroot --single-transaction --quick --routines --events --triggers --hex-blob --ignore-table="$MARIADB_DATABASE.wp_commentmeta" --databases "$MARIADB_DATABASE"' | gzip -1 > "$tmp"
 else
  timeout 480 docker exec "$c" sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb-dump -uroot --single-transaction --quick --routines --events --triggers --hex-blob --databases "$MARIADB_DATABASE"' | gzip -1 > "$tmp"
 fi
 gzip -t "$tmp"
 test "$(stat -c %s "$tmp")" -gt 25000
 mv "$tmp" "$out"
 echo "VERIFIED $name bytes=$(stat -c %s "$out")"
done
echo "=== CORRUPTION READ ONLY CHECK ==="
timeout 80 docker exec vc-db-vesta sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb -uroot --batch -e "CHECK TABLE wp_commentmeta QUICK" "$MARIADB_DATABASE"' || true
echo "=== END CORRUPTION ASSESSMENT ==="
