#!/usr/bin/env bash
set -uo pipefail
echo "=== HOST RESOURCE BASELINE ==="
date -Is; uptime; free -h; df -h /; df -ih /
echo "=== RAM PRESSURE ==="
cat /proc/pressure/memory 2>/dev/null || true
echo "=== CPU PRESSURE ==="
cat /proc/pressure/cpu 2>/dev/null || true
echo "=== PROCESS RESIDENT MEMORY TOP 25 ==="
ps -eo pid,ppid,stat,rss,pcpu,comm --sort=-rss | head -26
echo "=== PROCESS COUNTS ==="
ps -eo comm= | sort | uniq -c | sort -nr | head -24
echo "=== DOCKER STATE ==="
timeout 12 docker ps -a --format '{{.Names}}|{{.Status}}' || true
echo "=== CONTAINER MEMORY CPU ONE SHOT ==="
timeout 30 docker stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}|{{.PIDs}}' || true
echo "=== DOCKER MEMORY LIMITS AND OOM ==="
for c in vc-vesta vc-cutella vc-db-vesta vc-db-cutella vc-redis vc-nginx vc-vestaapp-web vc-vestaapp-market vc-vestaapp-account; do
timeout 4 docker inspect --format '{{.Name}}|state={{.State.Status}}|oom={{.State.OOMKilled}}|restart={{.RestartCount}}|mem_limit={{.HostConfig.Memory}}' "$c" 2>/dev/null || true
done
echo "=== OOM HISTORY (NO USER DATA) ==="
timeout 8 journalctl -k --since '48 hours ago' -o cat --no-pager 2>/dev/null | grep -iE 'out of memory|oom-kill|killed process' | tail -25 || true
echo "=== CRON COUNTS ==="
echo "root crontab jobs:"; crontab -l 2>/dev/null | grep -cvE '^($|#)' || true
echo "=== APACHE PHP LIMITS ==="
for c in vc-vesta vc-cutella; do
echo "$c processes:"; timeout 8 docker top "$c" -eo comm 2>/dev/null | sort | uniq -c | head -15 || true
echo "$c memory_limit:"; timeout 8 docker exec "$c" php -r 'echo ini_get("memory_limit").PHP_EOL;' 2>/dev/null || true
done
echo "=== HOST HTTP HEALTH ==="
for d in vesta-cosmetics.ir cutellashop.ir; do timeout 10 curl -ksS --connect-timeout 4 --max-time 8 --resolve "$d:443:127.0.0.1" -o /dev/null -w "$d http=%{http_code} ttfb=%{time_starttransfer}\n" "https://$d/" || true; done
echo "=== RESOURCE BASELINE COMPLETE ==="
