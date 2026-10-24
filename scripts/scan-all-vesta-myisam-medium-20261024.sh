#!/usr/bin/env bash
set -uo pipefail
echo "=== ALL MYISAM MEDIUM CHECK ==="
date -Is
echo "=== RESOURCE PRECHECK ==="
free -h; uptime
tables=$(timeout 18 docker exec vc-db-vesta sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb -uroot --batch --skip-column-names -e "SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA=0x7665737461636f735f6d AND ENGINE=0x4d794953414d ORDER BY DATA_LENGTH DESC"' 2>/dev/null)
echo "TOTAL_MYISAM_TABLES=$(printf '%s\n' "$tables" | grep -c '^wp_')"
count=0;bad=0;timeouts=0
while IFS= read -r table;do
 [[ "$table" =~ ^[a-zA-Z0-9_]+$ ]] || continue
 count=$((count+1))
 result=$(timeout 45 docker exec vc-db-vesta sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb -uroot --batch "$MARIADB_DATABASE" -e "CHECK TABLE $1 MEDIUM;"' sh "$table" 2>&1);rc=$?
 if [[ "$rc" -eq 124 ]];then echo "UNTESTED_TIMEOUT $table";timeouts=$((timeouts+1))
 elif [[ "$rc" -ne 0 ]] || echo "$result" | grep -Eiq '(^|[[:space:]])(error|Corrupt|crashed)([[:space:]]|$)';then
   echo "BAD_TABLE $table status=$rc"
   echo "$result" | tail -4 | cut -c1-280
   bad=$((bad+1))
 elif ! echo "$result" | grep -q -E '[[:space:]]OK[[:space:]]*$';then
   echo "UNVERIFIED $table status=$rc"
 else
   if (( count%12==0 ));then echo "CHECK_PROGRESS count=$count";fi
 fi
 sleep 0.07
done <<< "$tables"
echo "CHECK_SUMMARY checked=$count bad=$bad timedout=$timeouts"
for d in vesta-cosmetics.ir cutellashop.ir;do timeout 12 curl -ksS --connect-timeout 5 --max-time 10 --resolve "$d:443:127.0.0.1" -o /dev/null -w "$d HTTP=%{http_code}\n" "https://$d/" || true;done
echo "ALL_MYISAM_SCAN_COMPLETE"
