#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
export LC_ALL=C
echo "=== CONSISTENT DATA BACKUP BEFORE ACTION SCHEDULER REPAIR ==="
dir=/srv/backups/vesta-action-scheduler-pre-repair-20261024
mkdir -p "$dir";chmod 700 "$dir"
free_kb=$(df -Pk "$dir" | awk 'END{print $4}')
test "$free_kb" -ge 8388608 || { echo INSUFFICIENT_DISK;exit 29; }
for name in vc-db-vesta vc-db-cutella;do
  test "$(docker inspect -f '{{.State.Running}}' "$name")" = true
done
echo "=== TARGET TABLE ENGINE AND MEDIUM CHECK ==="
docker exec vc-db-vesta sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb -uroot -e "CHECK TABLE wp_actionscheduler_actions MEDIUM;" "$MARIADB_DATABASE"'
echo "=== BACK UP REMAINING VESTA TABLES ==="
file="$dir/vesta-excluding-action-scheduler.sql.gz"
tmp="$file.partial"
rm -f "$tmp"
timeout 600 docker exec vc-db-vesta sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb-dump -uroot --single-transaction --quick --hex-blob --routines --events --triggers --ignore-table="$MARIADB_DATABASE.wp_actionscheduler_actions" --databases "$MARIADB_DATABASE"' | gzip -1 > "$tmp"
gzip -t "$tmp"
test "$(stat -c %s "$tmp")" -gt 25000
mv "$tmp" "$file"
sha256sum "$file" > "$dir/SHA256SUMS"
echo "VERIFIED_VESTA_UNDAMAGED_TABLES bytes=$(stat -c %s "$file")"
echo "=== BACK UP CUTELLA ==="
f2="$dir/cutella-database.sql.gz"
t2="$f2.partial"
rm -f "$t2"
timeout 400 docker exec vc-db-cutella sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb-dump -uroot --single-transaction --quick --hex-blob --routines --events --triggers --databases "$MARIADB_DATABASE"' | gzip -1 > "$t2"
gzip -t "$t2"
test "$(stat -c %s "$t2")" -gt 25000
mv "$t2" "$f2"
sha256sum "$f2" >> "$dir/SHA256SUMS"
echo "VERIFIED_CUTELLA_DB bytes=$(stat -c %s "$f2")"
echo "=== CHECK SHOP ==="
for h in vesta-cosmetics.ir cutellashop.ir;do timeout 15 curl -ksS --connect-timeout 4 --max-time 12 --resolve "$h:443:127.0.0.1" -o /dev/null -w "$h HTTP=%{http_code}\n" "https://$h/" || true;done
echo "SQL_BACKUP_GATE_OK dir=$dir"
