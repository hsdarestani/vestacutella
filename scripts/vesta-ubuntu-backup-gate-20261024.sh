#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
exec 9>/run/lock/vesta-ubuntu-upgrade-20261024.lock
flock -n 9 || { echo 'UPGRADE_LOCK_BUSY'; exit 30; }
echo '=== DATABASE BACKUP GATE ==='
date -Is
df -h / /srv/backups
free -h
avail=$(df -Pk /srv/backups | awk 'END {print $4}')
[ "$avail" -ge 12582912 ] || { echo 'ABORT_DISK_FREE_BELOW_12_GIB'; exit 31; }
test -d /srv/vestacutella/runtime/vesta
test -d /srv/vestacutella/runtime/cutella
for c in vc-db-vesta vc-db-cutella vc-vesta vc-cutella; do
 st=$(timeout 10 docker inspect --format '{{.State.Running}}' "$c")
 [ "$st" = true ] || { echo "ABORT_NOT_RUNNING $c";exit 32; }
done
dest=/srv/backups/ubuntu-upgrade-20261024
mkdir -p "$dest";chmod 700 "$dest"
for item in 'vc-db-vesta:vesta-database' 'vc-db-cutella:cutella-database'; do
 IFS=: read -r c name <<< "$item"
 out="$dest/$name.sql.gz"
 if [ -s "$out" ];then
  gzip -t "$out" && echo "REUSE_VERIFIED_BACKUP $name bytes=$(stat -c %s "$out")" && continue
 fi
 echo "START_BACKUP $name"
 tmp="$out.partial"
 rm -f "$tmp"
 timeout 450 docker exec "$c" sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb-dump -uroot --databases "$MARIADB_DATABASE" --single-transaction --quick --routines --events --triggers --hex-blob' | gzip -1 > "$tmp"
 gzip -t "$tmp"
 [ "$(stat -c %s "$tmp")" -gt 25000 ] || { echo "ABORT_BACKUP_TOO_SMALL $name"; exit 33; }
 mv -f "$tmp" "$out"
 echo "BACKUP_VALIDATED $name bytes=$(stat -c %s "$out")"
done
echo "BACKUP_CONFIGS"
tar -czf "$dest/host-config-and-wp-config.tgz.partial"  /etc/ssh /etc/docker /etc/cron.d /etc/apt /etc/systemd/system  /srv/vestacutella/.env /srv/vestacutella/repo/infra  /srv/vestacutella/runtime/vesta/wp-config.php  /srv/vestacutella/runtime/cutella/wp-config.php  2>"$dest/tar-warnings.log"
tar -tzf "$dest/host-config-and-wp-config.tgz.partial" >/dev/null
mv -f "$dest/host-config-and-wp-config.tgz.partial" "$dest/host-config-and-wp-config.tgz"
sha256sum "$dest"/*.gz "$dest"/*.tgz > "$dest/SHA256SUMS"
chmod -R go-rwx "$dest"
echo "VERIFIED_BACKUPS"
ls -lh "$dest"/*.gz "$dest"/*.tgz
echo "=== END DATABASE BACKUP GATE ==="
