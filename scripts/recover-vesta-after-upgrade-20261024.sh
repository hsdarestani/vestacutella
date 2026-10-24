#!/usr/bin/env bash
set -uo pipefail
echo "=== RECOVERY HOST ==="
date -Is
uptime
free -h
df -h /
echo "=== BEFORE ==="
timeout 20 docker ps -a --format 'table {{.Names}}\t{{.Status}}'
echo "=== START DEPENDENCIES ==="
for c in vc-redis vc-db-vesta vc-db-cutella; do
  status=$(timeout 8 docker inspect --format '{{.State.Status}}' "$c" 2>/dev/null || true)
  echo "$c state=$status"
  if [[ "$status" == "exited" || "$status" == "created" ]]; then
    timeout 35 docker start "$c" || true
  fi
done
sleep 5
echo "=== START STORES ==="
for c in vc-vesta vc-cutella vc-vestaapp-web; do
  status=$(timeout 8 docker inspect --format '{{.State.Status}}' "$c" 2>/dev/null || true)
  echo "$c state=$status"
  if [[ "$status" == "exited" || "$status" == "created" ]]; then
    timeout 35 docker start "$c" || true
  fi
done
sleep 6
echo "=== NGINX ==="
status=$(timeout 8 docker inspect --format '{{.State.Status}}' vc-nginx 2>/dev/null || true)
echo "vc-nginx state=$status"
if [[ "$status" == "exited" || "$status" == "created" ]]; then timeout 35 docker start vc-nginx || true; fi
echo "=== AFTER ==="
timeout 20 docker ps -a --format 'table {{.Names}}\t{{.Status}}'
for host in vesta-cosmetics.ir cutellashop.ir app.vesta-cosmetics.ir; do
 timeout 22 curl -ksS --max-time 20 --resolve "$host:443:127.0.0.1" -o /dev/null -w "LOCAL $host HTTP=%{http_code} TTFB=%{time_starttransfer}s\n" "https://$host/" || true
done
echo "=== NGINX LOGS ==="
timeout 12 docker logs --tail 25 vc-nginx 2>&1 || true
echo "=== COMPLETE ==="
