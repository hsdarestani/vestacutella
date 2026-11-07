#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
export LC_ALL=C

backup_root=/srv/backups
mkdir -p "$backup_root"
chmod 700 "$backup_root"
exec 9>/run/lock/vesta-installer-preparation.lock
flock -n 9 || { echo "ABORT_ALREADY_RUNNING"; exit 30; }

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
dest="$backup_root/vesta-before-installer-$timestamp"
site=/srv/vestacutella/runtime/vesta
database_container=vc-db-vesta
installer=vesta-installer

echo "BACKUP_START_UTC=$timestamp"
test -d "$site/wp-content" || { echo "ABORT_VESTA_SITE_NOT_FOUND"; exit 31; }
test -f "$site/wp-config.php" || { echo "ABORT_WP_CONFIG_NOT_FOUND"; exit 32; }
test "$(docker inspect -f '{{.State.Running}}' "$database_container")" = true || { echo "ABORT_VESTA_DATABASE_NOT_RUNNING"; exit 33; }

site_kib="$(du -sk "$site" | awk '{print $1}')"
available_kib="$(df -Pk "$backup_root" | awk 'END {print $4}')"
reserve_kib=2097152
echo "SITE_UNCOMPRESSED_MIB=$((site_kib/1024))"
echo "DISK_AVAILABLE_MIB=$((available_kib/1024))"
# Conservative preflight: leave 2 GiB free even if the tar archive barely compresses.
if (( available_kib < site_kib + reserve_kib )); then
  echo "ABORT_INSUFFICIENT_SPACE_FOR_SAFE_FULL_BACKUP"
  exit 34
fi
mkdir -m 700 "$dest"
echo "BACKUP_DIR=$dest"

echo "DATABASE_BACKUP_START"
sql_tmp="$dest/vesta-mariadb.sql.gz.partial"
timeout 850 docker exec "$database_container" sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb-dump -uroot --databases "$MARIADB_DATABASE" --single-transaction --quick --hex-blob --routines --events --triggers' | gzip -1 > "$sql_tmp"
gzip -t "$sql_tmp"
test "$(stat -c '%s' "$sql_tmp")" -gt 25000 || { echo "ABORT_DB_BACKUP_TOO_SMALL"; exit 35; }
test "$(gzip -dc "$sql_tmp" | head -c 100 | wc -c)" -ge 100 || { echo "ABORT_DB_BACKUP_UNREADABLE"; exit 36; }
mv "$sql_tmp" "$dest/vesta-mariadb.sql.gz"
echo "DATABASE_BACKUP_VERIFIED"

# Re-check free space before archiving media and WordPress files.
available_kib="$(df -Pk "$backup_root" | awk 'END {print $4}')"
if (( available_kib < site_kib + 1048576 )); then
  echo "ABORT_NOT_ENOUGH_SPACE_FOR_SITE_ARCHIVE"
  exit 37
fi
echo "WORDPRESS_BACKUP_START"
tar --numeric-owner -czf "$dest/vesta-wordpress.tar.gz.partial" -C /srv/vestacutella/runtime vesta
tar -tzf "$dest/vesta-wordpress.tar.gz.partial" > /dev/null
tar -tzf "$dest/vesta-wordpress.tar.gz.partial" | grep -qx 'vesta/wp-config.php' || { echo "ABORT_MISSING_WP_CONFIG"; exit 38; }
tar -tzf "$dest/vesta-wordpress.tar.gz.partial" | grep -q '^vesta/wp-content/' || { echo "ABORT_MISSING_WP_CONTENT"; exit 39; }
mv "$dest/vesta-wordpress.tar.gz.partial" "$dest/vesta-wordpress.tar.gz"
echo "WORDPRESS_BACKUP_VERIFIED"

# Save non-secret code and runtime references privately alongside the backup.
printf 'Site: vesta-cosmetics.ir\nWordPress: /srv/vestacutella/runtime/vesta\nMariaDB: vc-db-vesta\nRepository: hsdarestani/vestacutella\nBackup created: %s\n' "$timestamp" > "$dest/RESTORE-INFO.txt"
(cd "$dest" && sha256sum vesta-mariadb.sql.gz vesta-wordpress.tar.gz > SHA256SUMS && sha256sum -c SHA256SUMS)
chmod 600 "$dest"/*
echo "BACKUP_CHECKSUMS_VERIFIED"
du -h "$dest/vesta-mariadb.sql.gz" "$dest/vesta-wordpress.tar.gz"

# User exists but is not given password or SSH key until installer identity is supplied.
# No sudo, docker membership or access to the service groups is granted.
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
# Disable password authentication and keep the account inaccessible until key provisioning.
passwd -l "$installer" >/dev/null 2>&1 || true
# Do not overwrite any existing SSH authorized keys; report presence to avoid falsely claiming restricted access.
if test -s "/home/$installer/.ssh/authorized_keys"; then
  echo "WARNING_EXISTING_INSTALLER_SSH_KEYS_PRESENT"
else
  echo "INSTALLER_USER_NO_SSH_KEYS"
fi
if id -nG "$installer" | grep -Eq '(^| )(sudo|docker|adm|www-data)( |$)'; then
  echo "ABORT_UNEXPECTED_INSTALLER_PRIVILEGES"
  exit 40
fi
echo "INSTALLER_USER_GROUPS=$(id -nG "$installer")"
echo "BACKUP_AND_USER_PREPARATION_COMPLETE=$dest"
