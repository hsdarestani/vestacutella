#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
export LC_ALL=C
exec 9>/run/lock/vesta-full-backup.lock
flock -n 9 || { echo BACKUP_ALREADY_RUNNING; exit 1; }
site=/srv/vestacutella/runtime/vesta
stamp=$(date -u +%Y%m%dT%H%M%SZ)
dest="/srv/backups/vesta-before-mahak-images-$stamp"
test -d "$site/wp-content/uploads"
test "$(docker inspect -f '{{.State.Running}}' vc-db-vesta)" = true
mkdir -p /srv/backups
need=$(du -sk "$site" | awk '{print $1}')
free=$(df -Pk /srv/backups | awk 'END {print $4}')
echo "SITE_MIB=$((need/1024)) FREE_MIB=$((free/1024))"
(( free > need + 3145728 )) || { echo INSUFFICIENT_DISK_SPACE; exit 1; }
mkdir -m 700 "$dest"
echo "BACKUP_DIRECTORY=$dest"
date -u +%FT%TZ > "$dest/STARTED_UTC"
docker exec vc-db-vesta sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb-dump -uroot --databases "$MARIADB_DATABASE" --single-transaction --quick --hex-blob --routines --events --triggers' | gzip -1 > "$dest/database.sql.gz.partial"
gzip -t "$dest/database.sql.gz.partial"
test "$(stat -c %s "$dest/database.sql.gz.partial")" -gt 25000
mv "$dest/database.sql.gz.partial" "$dest/database.sql.gz"
echo DATABASE_EXPORT_VERIFIED
set +e
tar --numeric-owner --exclude='vesta/wp-content/vc-debug.log' -czf "$dest/wordpress.tar.gz.partial" -C /srv/vestacutella/runtime vesta 2>"$dest/tar-warnings.txt"
tar_rc=$?
set -e
if (( tar_rc != 0 )); then
  if (( tar_rc != 1 )) || grep -vE 'file changed as we read it|Removing leading' "$dest/tar-warnings.txt" | grep -q .; then
    echo ARCHIVE_CREATION_FAILED; exit 1
  fi
  echo LIVE_FILE_CHANGES_RECORDED
fi
tar -tzf "$dest/wordpress.tar.gz.partial" > "$dest/archive-files.txt"
for required in vesta/wp-config.php vesta/wp-content/uploads/ vesta/wp-content/plugins/ vesta/wp-content/themes/; do
  grep -Fxq "$required" "$dest/archive-files.txt"
done
mv "$dest/wordpress.tar.gz.partial" "$dest/wordpress.tar.gz"
# A separate image-relationship export allows recovery without reverting later orders.
docker exec vc-db-vesta sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb -uroot "$MARIADB_DATABASE" --batch --raw -e "SELECT post_id,meta_key,meta_value FROM wp_postmeta WHERE meta_key IN (\x27_thumbnail_id\x27,\x27_product_image_gallery\x27,\x27_wp_attached_file\x27,\x27_wp_attachment_metadata\x27);"' | gzip -1 > "$dest/image-relationships.tsv.gz.partial"
gzip -t "$dest/image-relationships.tsv.gz.partial"
mv "$dest/image-relationships.tsv.gz.partial" "$dest/image-relationships.tsv.gz"
(cd "$dest" && sha256sum database.sql.gz wordpress.tar.gz image-relationships.tsv.gz > SHA256SUMS && sha256sum -c SHA256SUMS)
printf '%s\n' 'Full Vesta WordPress files (except active vc-debug.log), uploads, plugins, themes, wp-config and transaction-consistent MariaDB dump.' 'Live site stayed online. Files were archived live; inspect tar-warnings.txt for concurrent file changes.' 'Restore to isolated staging first. For missing product images restore selected media and image relationships, preserving later orders and financial records.' 'This backup is on the origin server; no independent off-server copy has been verified.' > "$dest/RESTORE-INFO.txt"
date -u +%FT%TZ > "$dest/VERIFIED_UTC"
chmod 600 "$dest"/*
echo "ARCHIVED_ENTRIES=$(wc -l < "$dest/archive-files.txt")"
echo "UPLOAD_ENTRIES=$(grep -c '^vesta/wp-content/uploads/' "$dest/archive-files.txt")"
du -h "$dest/database.sql.gz" "$dest/wordpress.tar.gz" "$dest/image-relationships.tsv.gz"
echo "BACKUP_VERIFIED=$dest"
for host in vesta-cosmetics.ir cutellashop.ir app.vesta-cosmetics.ir; do
 code=$(curl -ksS --connect-timeout 5 --max-time 20 --resolve "$host:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$host/" || true)
 echo "$host HTTP=$code"
done
