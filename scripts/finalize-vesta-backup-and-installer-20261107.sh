#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
export LC_ALL=C
exec 9>/run/lock/vesta-installer-preparation.lock
flock -n 9 || { echo "ABORT_ALREADY_RUNNING"; exit 30; }

dest=/srv/backups/vesta-before-installer-20261107T072902Z
installer=vesta-installer
test -d "$dest" || { echo "ABORT_ARCHIVE_DIR_MISSING"; exit 31; }
test -f "$dest/vesta-mariadb.sql.gz" || { echo "ABORT_DB_ARCHIVE_MISSING"; exit 32; }
test -f "$dest/vesta-wordpress.tar.gz.partial" || { echo "ABORT_SITE_ARCHIVE_MISSING"; exit 33; }

echo "START_VALIDATING_EXISTING_BACKUP"
gzip -t "$dest/vesta-mariadb.sql.gz"
test "$(stat -c '%s' "$dest/vesta-mariadb.sql.gz")" -gt 25000
echo "DATABASE_VERIFIED size_bytes=$(stat -c '%s' "$dest/vesta-mariadb.sql.gz")"

echo "VERIFY_WORDPRESS_ARCHIVE_COMPLETE"
gzip -t "$dest/vesta-wordpress.tar.gz.partial"
tar -tzf "$dest/vesta-wordpress.tar.gz.partial" > "$dest/vesta-files.list"
for required in \
  'vesta/wp-config.php' \
  'vesta/wp-content/' \
  'vesta/wp-content/uploads/' \
  'vesta/wp-content/plugins/' \
  'vesta/wp-content/themes/'; do
  grep -Fqx "$required" "$dest/vesta-files.list" || { echo "ABORT_MISSING_REQUIRED_SITE_ENTRY=$required"; exit 34; }
done
file_count="$(wc -l < "$dest/vesta-files.list")"
echo "SITE_ARCHIVE_ENTRIES=$file_count"
test "$file_count" -gt 2000 || { echo "ABORT_SITE_ARCHIVE_TOO_FEW_ENTRIES"; exit 35; }
mv "$dest/vesta-wordpress.tar.gz.partial" "$dest/vesta-wordpress.tar.gz"
printf 'Site: vesta-cosmetics.ir\nWordPress: /srv/vestacutella/runtime/vesta\nMariaDB: vc-db-vesta\nRepository: hsdarestani/vestacutella\nBackup created: 20261107T072902Z\nLive log vesta/wp-content/vc-debug.log and wp-content directory changed during archive creation; archive verified via full gzip/tar stream and required paths.\n' > "$dest/RESTORE-INFO.txt"
(cd "$dest" && sha256sum vesta-mariadb.sql.gz vesta-wordpress.tar.gz > SHA256SUMS && sha256sum -c SHA256SUMS)
chmod 600 "$dest"/*
chmod 700 "$dest"
echo "BACKUP_VERIFIED_DIR=$dest"
du -h "$dest/vesta-mariadb.sql.gz" "$dest/vesta-wordpress.tar.gz"

if id "$installer" >/dev/null 2>&1; then
  echo "INSTALLER_USER_ALREADY_EXISTS"
else
  useradd --create-home --user-group --shell /bin/bash --comment 'Temporary third-party software installer - Vesta' "$installer"
  echo "INSTALLER_USER_CREATED"
fi
install -d -m 700 -o "$installer" -g "$installer" "/home/$installer/install"
install -d -m 700 -o "$installer" -g "$installer" "/home/$installer/.ssh"
touch "/home/$installer/.ssh/authorized_keys"
chown "$installer:$installer" "/home/$installer/.ssh/authorized_keys"
chmod 600 "/home/$installer/.ssh/authorized_keys"
passwd -l "$installer" >/dev/null 2>&1 || true
if test -s "/home/$installer/.ssh/authorized_keys"; then
  echo "WARNING_EXISTING_INSTALLER_SSH_KEYS_PRESENT"
else
  echo "INSTALLER_ACCOUNT_LOCKED_NO_SSH_KEYS"
fi
if id -nG "$installer" | grep -Eq '(^| )(sudo|docker|adm|www-data)( |$)'; then
  echo "ABORT_UNEXPECTED_INSTALLER_PRIVILEGES"
  exit 40
fi
echo "INSTALLER_USER_GROUPS=$(id -nG "$installer")"
echo "SITE_AND_APP_HEALTHCHECK"
for host in vesta-cosmetics.ir cutellashop.ir app.vesta-cosmetics.ir; do
  code="$(timeout 15 curl -ksS --connect-timeout 3 --max-time 12 --resolve "$host:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$host/" || true)"
  echo "$host HTTP=$code"
done
echo "VESTA_BACKUP_AND_RESTRICTED_USER_SETUP_SUCCESS"
