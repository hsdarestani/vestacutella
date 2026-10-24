#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
echo "=== FULL VESTA LOGICAL BACKUP AND VALIDATION ==="
dest=/srv/backups/vesta-full-db-verify-20261024
mkdir -p "$dest"
chmod 700 "$dest"
test "$(timeout 10 docker inspect -f '{{.State.Running}}' vc-db-vesta)" = true
test "$(timeout 10 docker inspect -f '{{.State.Running}}' vc-db-cutella)" = true
free_kb=$(df -Pk "$dest" | awk 'END{print $4}')
test "$free_kb" -gt 8388608 || exit 31
echo "=== ALL VESTA TABLES INCLUDING ACTION SCHEDULER ==="
tmp="$dest/vestacos_m-full.sql.gz.partial"
rm -f "$tmp"
timeout 600 docker exec vc-db-vesta sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb-dump -uroot --single-transaction --quick --hex-blob --routines --events --triggers --databases "$MARIADB_DATABASE"' | gzip -1 > "$tmp"
gzip -t "$tmp"
test "$(stat -c %s "$tmp")" -gt 25000
mv -f "$tmp" "$dest/vestacos_m-full.sql.gz"
echo "FULL_VESTA_BACKUP_VERIFIED bytes=$(stat -c %s "$dest/vestacos_m-full.sql.gz")"
echo "=== CHECK ALL PREVIOUSLY AFFECTED TABLES ==="
for table in wp_commentmeta wp_wsal_metadata wp_wsal_occurrences wp_actionscheduler_actions; do
  out=$(timeout 120 docker exec vc-db-vesta sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb -uroot --batch "$MARIADB_DATABASE" -e "CHECK TABLE $1 MEDIUM;"' sh "$table")
  echo "TABLE=$table"
  echo "$out" | tail -3
  echo "$out" | grep -Eq '[[:space:]]check[[:space:]]status[[:space:]]OK[[:space:]]*$' || exit 35
done
echo "=== VERIFY GZIP INTEGRITY AND MANIFEST ==="
gzip -t "$dest/vestacos_m-full.sql.gz"
sha256sum "$dest/vestacos_m-full.sql.gz" > "$dest/SHA256SUMS"
(cd "$dest" && sha256sum -c SHA256SUMS)
echo "=== NO DATA MODIFIED ==="
for d in vesta-cosmetics.ir cutellashop.ir app.vesta-cosmetics.ir;do
 code=$(timeout 18 curl -ksS --connect-timeout 4 --max-time 16 --resolve "$d:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$d/" || true)
 echo "SITE $d HTTP=$code"
 test "$code" = 200 || exit 36
done
echo "COMPLETE_VESTA_DB_VERIFICATION_SUCCESS $dest"
