#!/usr/bin/env bash
set -uo pipefail
echo "== HOST INTERNATIONAL ROUTE DIAGNOSTIC =="
date -Is
uptime
free -h
echo "== ADDRESSES =="; timeout 7 ip -4 -brief addr
echo "== ROUTES =="; timeout 7 ip -4 route
echo "== FIREWALL =="; timeout 8 ufw status verbose 2>&1 | head -45
echo "== FILTER INPUT =="; timeout 9 iptables -S INPUT 2>&1 | head -70
echo "== DOCKER =="; timeout 10 docker ps --format '{{.Names}} {{.Status}}' | head -20
echo "== LISTEN =="; timeout 8 ss -lntp | grep -E ':(80|443|22)\s' | head -18
echo "== CF EGRESS SAMPLE =="; for ip in 104.21.70.180 172.67.138.42; do timeout 7 ip route get "$ip" || true; done
echo "== CONTAINER LAST ERRORS =="; timeout 10 docker logs --tail 20 vc-nginx 2>&1 | tail -20
echo "== LOCAL ENDPOINT =="; curl -ksS --resolve vesta-cosmetics.ir:443:127.0.0.1 --connect-timeout 3 --max-time 10 -o /dev/null -w 'LOCAL_HTTP=%{http_code} time=%{time_total}\n' https://vesta-cosmetics.ir/ || true
echo "== DONE =="
