#!/usr/bin/env bash
set -uo pipefail
echo '=== DB REPAIR PREFLIGHT READ ONLY ==='
date -Is; uptime; df -h /; free -h
for c in vc-db-vesta vc-db-cutella; do
 echo "DB_CONTAINER $c"
 timeout 8 docker inspect --format 'running={{.State.Running}} oom={{.State.OOMKilled}}' "$c"
done
echo '=== TARGET TABLE ENGINES AND FILES ==='
timeout 30 docker exec vc-db-vesta sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb -uroot --batch --skip-column-names "$MARIADB_DATABASE" -e "SHOW TABLE STATUS LIKE '\''wp_commentmeta'\''; SHOW TABLE STATUS LIKE '\''wp_wsal_metadata'\'';"' | cut -c 1-280
echo '=== TABLE FILE METADATA ==='
for t in wp_commentmeta wp_wsal_metadata; do
 timeout 8 docker exec vc-db-vesta sh -c 'for f in /var/lib/mysql/vestacos_m/'"$t"'.*; do test ! -f "$f" || stat -c "%n %s bytes" "$f"; done'
done
echo '=== TARGET QUICK CHECK ==='
for t in wp_commentmeta wp_wsal_metadata; do
 echo "TABLE=$t"
 timeout 40 docker exec vc-db-vesta sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb-check --check --quick -uroot "$MARIADB_DATABASE" '"$t"'' 2>&1 | tail -12
done
echo '=== GLOBAL ENGINE CORRUPTION COUNTS (SELECT ONLY) ==='
timeout 15 docker exec vc-db-vesta sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb -uroot --batch --skip-column-names -e "SELECT ENGINE,COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA=\x27vestacos_m\x27 GROUP BY ENGINE;"' 2>&1 | tail -10
echo '=== SERVICE PROBES ==='
for h in vesta-cosmetics.ir cutellashop.ir app.vesta-cosmetics.ir; do timeout 12 curl -ksS --connect-timeout 4 --max-time 10 --resolve "$h:443:127.0.0.1" -o /dev/null -w "$h HTTP=%{http_code}\n" "https://$h/" || true;done
echo '=== DB PREFLIGHT END ==='
