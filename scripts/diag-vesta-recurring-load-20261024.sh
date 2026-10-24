#!/usr/bin/env bash
set +e
export LC_ALL=C
echo "===== LIVE HIGH-LOAD TRIAGE ====="; date -Is; uptime; free -h; df -h /
echo "===== CPU CAPACITY ====="; nproc; grep -m1 '^cpu ' /proc/stat; cat /proc/loadavg
echo "===== PRESSURE STALL ====="; for x in /proc/pressure/{cpu,io,memory};do echo "$x";cat "$x";done
echo "===== VMSTAT 1S x3 ====="; timeout 7 vmstat 1 4
echo "===== TOP PROCESSES CPU ====="; timeout 6 ps -eo pid,ppid,stat,pcpu,rss,wchan:22,comm --sort=-pcpu | head -36
echo "===== TOP PROCESSES RSS ====="; timeout 6 ps -eo pid,ppid,stat,pcpu,rss,wchan:22,comm --sort=-rss | head -28
echo "===== UNINTERRUPTIBLE D TASKS ====="; timeout 6 ps -eo pid,ppid,stat,pcpu,wchan:28,comm | awk 'NR==1 || $3 ~ /D/' | head -35
echo "===== RUNNABLE R TASKS ====="; timeout 6 ps -eo pid,ppid,stat,pcpu,wchan:28,comm | awk 'NR==1 || $3 ~ /R/' | head -35
echo "===== CONTAINER CPU ====="; timeout 25 docker stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}|{{.PIDs}}'
echo "===== DOCKER STATE ====="; timeout 12 docker ps -a --format '{{.Names}}|{{.Status}}'
echo "===== NETWORK ====="; timeout 5 ss -s
echo "===== CRON TASKS ====="; timeout 5 sh -c "for f in /etc/cron.d/*; do [ -f \"\$f\" ] || continue; echo \"\$f\"; grep -vE '^#|^$' \"\$f\" | sed -E 's/(TOKEN|PASS|SECRET)=[^ ]+/\\1=REDACTED/gi' | head -3; done" | head -50
echo "===== PHP APACHE WORKERS =====";for c in vc-vesta vc-cutella;do echo "$c";timeout 5 docker exec "$c" sh -c "grep -E '^[[:space:]]*(StartServers|MaxRequestWorkers|MaxConnectionsPerChild)' /etc/apache2/mods-available/mpm_prefork.conf" || true;done
echo "===== HTTP REQUEST TYPE COUNTS LAST 3 MIN ====="
timeout 9 docker logs --since 3m vc-nginx 2>&1 | awk -F '"' '/" (200|301|302|304|400|403|404|429|499|500|502|503|504) / { split($2,r," "); route=r[2];sub(/\?.*$/,"",route); if (route ~ /wp-admin\/admin-ajax\.php/) route="admin-ajax";else if(route ~ /wc-ajax/)route="wc-ajax";else if(route ~ /wp-cron/)route="wp-cron";else if(route ~ /\/product\//)route="product";else if(route ~ /\/shop/)route="shop";else if(route ~ /\/cart/)route="cart";else if(route ~ /\/checkout/)route="checkout";else if(route ~ /\.(webp|jpg|png|gif|svg|css|js)$/)route="static";else if(route!="/")route="other";split($3,s," "); k=route" status="s[1]; ct[k]++} END {for(k in ct)print ct[k],k}' | sort -rn | head -32
echo "===== SYSTEM OOM AND BLOCKED TASK LOGS =====";timeout 7 journalctl -k -b --since '-45 min' -o cat --no-pager 2>/dev/null | grep -iE 'out of memory|oom-kill|killed process|blocked for more|ext4|i/o error' | tail -16
echo "===== FINAL SITE HEALTH ====="
for d in vesta-cosmetics.ir cutellashop.ir app.vesta-cosmetics.ir; do timeout 12 curl -ksS --connect-timeout 4 --max-time 11 --resolve "$d:443:127.0.0.1" -o /dev/null -w "$d origin_status=%{http_code} ttfb=%{time_starttransfer}s total=%{time_total}s\n" "https://$d/" || true;done
echo "===== HIGH LOAD TRIAGE END ====="
