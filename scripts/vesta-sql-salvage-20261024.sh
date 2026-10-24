#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
exec 9>/run/lock/vesta-ubuntu-upgrade-20261024.lock
flock -n 9 || exit 30
echo '=== CHECK TABLE ENGINES ==='
date -Is;uptime
docker exec vc-db-vesta sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb -uroot --batch --skip-column-names "$MARIADB_DATABASE" -e "SHOW TABLE STATUS"' | awk '$1=="wp_commentmeta" || $1=="wp_wsal_metadata" {print "TABLE="$1,"ENGINE="$2,"ROWS="$5,"DATA_BYTES="$7,"INDEX_BYTES="$9,"STATUS="$17}'
echo '=== CREATE SALVAGE ARCHIVES ==='
dest=/srv/backups/ubuntu-upgrade-20261024
mkdir -p "$dest"; chmod 700 "$dest"
for tuple in vc-db-cutella:cutella-database vc-db-vesta:vesta-minus-damaged-audit;do
 IFS=: read -r c name <<< "$tuple";out="$dest/$name.sql.gz"
 if test -s "$out" && gzip -t "$out";then echo "VERIFIED_ALREADY $name bytes=$(stat -c %s "$out")";continue;fi
 echo "START_BACKUP $name";tmp="$out.partial";rm -f "$tmp"
 if [ "$c" = vc-db-vesta ]; then
  timeout 450 docker exec "$c" sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb-dump -uroot --single-transaction --quick --routines --events --triggers --hex-blob --ignore-table="$MARIADB_DATABASE.wp_commentmeta" --ignore-table="$MARIADB_DATABASE.wp_wsal_metadata" --databases "$MARIADB_DATABASE"' | gzip -1 > "$tmp"
 else
  timeout 450 docker exec "$c" sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb-dump -uroot --single-transaction --quick --routines --events --triggers --hex-blob --databases "$MARIADB_DATABASE"' | gzip -1 > "$tmp"
 fi
 gzip -t "$tmp"
 test "$(stat -c %s "$tmp")" -gt 25000
 mv -f "$tmp" "$out"
 echo "VERIFIED_BACKUP $name bytes=$(stat -c %s "$out")"
done
echo '=== INTEGRITY CHECK TARGETS (QUICK READ ONLY) ==='
timeout 80 docker exec vc-db-vesta sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb-check --check --quick -uroot "$MARIADB_DATABASE" wp_commentmeta wp_wsal_metadata' || true
echo "=== SAFE SALVAGE COMPLETE ==="
