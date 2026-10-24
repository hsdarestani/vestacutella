#!/usr/bin/env bash
# Preserve MyISAM files under table-specific READ locks before targeted REPAIR.
# Never touches WooCommerce orders, app data, or other tables.
set -Eeuo pipefail
umask 077
export LC_ALL=C
exec 9>/run/lock/vesta-myisam-repair.lock
flock -n 9 || { echo REPAIR_ALREADY_RUNNING; exit 20; }
backup="/srv/backups/vesta-myisam-repair-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$backup"
chmod 700 "$backup"
echo "BACKUP_PATH=$backup"
locked=0
lock_pid=""
cleanup() {
  rc=$?
  trap - EXIT
  if [ "$locked" = 1 ]; then
    printf 'UNLOCK TABLES;\n' >&8 2>/dev/null || true
    exec 8>&- || true
    wait "$lock_pid" 2>/dev/null || true
  fi
  if [ "$rc" -ne 0 ]; then echo "REPAIR_STOPPED rc=$rc BACKUP_PATH=$backup"; fi
  exit "$rc"
}
trap cleanup EXIT
echo "=== PRECHECK ==="
test "$(docker inspect -f '{{.State.Running}}' vc-db-vesta)" = true
test "$(docker inspect -f '{{.State.Running}}' vc-db-cutella)" = true
free_kb=$(df -Pk /srv/backups | awk 'END {print $4}')
test "$free_kb" -ge 8388608 || { echo ABORT_LESS_THAN_8GB_FREE; exit 21; }
mem_kb=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
test "$mem_kb" -ge 1048576 || { echo ABORT_INSUFFICIENT_RAM; exit 22; }
io_full=$(awk '/full/ {sub("avg10=","",$2);print $2}' /proc/pressure/io)
awk -v x="$io_full" 'BEGIN {exit !(x < 10.0)}' || { echo ABORT_HIGH_IO_PRESSURE; exit 23; }
for site in vesta-cosmetics.ir cutellashop.ir app.vesta-cosmetics.ir; do
  code=$(timeout 15 curl -ksS --connect-timeout 5 --max-time 12 --resolve "$site:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$site/" || true)
  echo "PRECHECK_SITE $site HTTP=$code"
  test "$code" = 200 || exit 24
done
echo "=== VERIFY TARGETS ARE MYISAM ==="
for table in wp_commentmeta wp_wsal_metadata; do
  engine=$(timeout 14 docker exec vc-db-vesta sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb -uroot --batch --skip-column-names "$MARIADB_DATABASE" -e "SHOW TABLE STATUS"' | awk -v t="$table" '$1==t {print $2}')
  echo "$table ENGINE=$engine"
  test "$engine" = MyISAM || { echo ABORT_UNEXPECTED_ENGINE; exit 25; }
done
echo "=== BACKUP ALL OTHER SQL TABLES FIRST ==="
for entry in 'vc-db-cutella:cutella-all' 'vc-db-vesta:vesta-excluding-two-targets'; do
  IFS=: read -r c label <<< "$entry"
  tmp="$backup/$label.sql.gz.partial"
  if [ "$c" = vc-db-cutella ]; then
    timeout 500 docker exec "$c" sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb-dump -uroot --single-transaction --quick --hex-blob --routines --events --triggers --databases "$MARIADB_DATABASE"' | gzip -1 > "$tmp"
  else
    timeout 500 docker exec "$c" sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb-dump -uroot --single-transaction --quick --hex-blob --routines --events --triggers --ignore-table="$MARIADB_DATABASE.wp_commentmeta" --ignore-table="$MARIADB_DATABASE.wp_wsal_metadata" --databases "$MARIADB_DATABASE"' | gzip -1 > "$tmp"
  fi
  gzip -t "$tmp"
  test "$(stat -c %s "$tmp")" -gt 25000
  mv -f "$tmp" "$backup/$label.sql.gz"
  echo "VALIDATED_SQL_BACKUP $label bytes=$(stat -c %s "$backup/$label.sql.gz")"
done
echo "=== LOCK TARGETS FOR CONSISTENT PHYSICAL BACKUP ==="
fifo="$backup/mariadb-lock-input.fifo"
mkfifo -m 600 "$fifo"
timeout 150 docker exec -i vc-db-vesta sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb --unbuffered --batch --skip-column-names -uroot "$MARIADB_DATABASE"' < "$fifo" > "$backup/lock-session.log" 2>&1 &
lock_pid=$!
exec 8>"$fifo"
locked=1
printf 'LOCK TABLES wp_commentmeta READ, wp_wsal_metadata READ;\nSELECT "BACKUP_LOCK_READY";\n' >&8
ready=0
for i in $(seq 1 80); do
  if grep -q BACKUP_LOCK_READY "$backup/lock-session.log"; then ready=1;break;fi
  if ! kill -0 "$lock_pid" 2>/dev/null;then break;fi
  sleep 0.25
done
if [ "$ready" != 1 ];then echo ABORT_UNCONFIRMED_TABLE_LOCK;tail -12 "$backup/lock-session.log";exit 26;fi
echo TABLES_READ_LOCKED
for table in wp_commentmeta wp_wsal_metadata;do
  for ext in frm MYD MYI;do
    timeout 35 docker cp "vc-db-vesta:/var/lib/mysql/vestacos_m/$table.$ext" "$backup/$table.$ext"
    test -s "$backup/$table.$ext" || exit 27
  done
done
printf 'UNLOCK TABLES;\n' >&8
exec 8>&-
locked=0
wait "$lock_pid" || { echo LOCK_SESSION_ERROR; exit 28; }
rm -f "$fifo"
sha256sum "$backup/"*.frm "$backup/"*.MYD "$backup/"*.MYI "$backup/"*.sql.gz > "$backup/SHA256SUMS"
echo "MYISAM_RAW_BACKUP_VERIFIED"
echo "=== TARGETED REPAIR MYISAM TABLES ==="
for table in wp_commentmeta wp_wsal_metadata;do
  echo "REPAIRING $table"
  timeout 450 docker exec vc-db-vesta sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb -uroot --batch "$MARIADB_DATABASE" -e "REPAIR TABLE $1;"' sh "$table" | tee "$backup/$table.repair-result.txt"
  if grep -Eiq 'error|failed|corrupt|crashed' "$backup/$table.repair-result.txt";then echo "REPAIR_REPORTED_ERROR $table";exit 29;fi
  timeout 120 docker exec vc-db-vesta sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb -uroot --batch "$MARIADB_DATABASE" -e "CHECK TABLE $1 EXTENDED;"' sh "$table" | tee "$backup/$table.check-result.txt"
  grep -Eqi '[[:space:]]OK[[:space:]]*$' "$backup/$table.check-result.txt" || { echo "CHECK_DID_NOT_PASS $table";exit 30; }
done
echo "=== NEW COMPLETE VESTA SQL BACKUP ==="
timeout 600 docker exec vc-db-vesta sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb-dump -uroot --single-transaction --quick --hex-blob --routines --events --triggers --databases "$MARIADB_DATABASE"' | gzip -1 > "$backup/vesta-complete-repaired.sql.gz.partial"
gzip -t "$backup/vesta-complete-repaired.sql.gz.partial"
test "$(stat -c %s "$backup/vesta-complete-repaired.sql.gz.partial")" -gt 25000
mv "$backup/vesta-complete-repaired.sql.gz.partial" "$backup/vesta-complete-repaired.sql.gz"
sha256sum "$backup/vesta-complete-repaired.sql.gz" >> "$backup/SHA256SUMS"
echo "COMPLETE_VESTA_SQL_BACKUP_OK bytes=$(stat -c %s "$backup/vesta-complete-repaired.sql.gz")"
echo "=== FINAL CHECKS ==="
for site in vesta-cosmetics.ir cutellashop.ir app.vesta-cosmetics.ir; do
  code=$(timeout 20 curl -ksS --connect-timeout 5 --max-time 17 --resolve "$site:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$site/" || true)
  echo "POSTCHECK_SITE $site HTTP=$code"
  test "$code" = 200 || exit 32
done
for c in vc-db-vesta vc-db-cutella;do test "$(docker inspect -f '{{.State.Running}}' "$c")" = true;done
echo "MYISAM_REPAIR_AND_FULL_BACKUP_SUCCESS $backup"
