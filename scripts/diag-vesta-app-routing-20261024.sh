#!/usr/bin/env bash
set -uo pipefail
echo "=== APP ROUTING READ-ONLY ==="
for c in vc-nginx vc-vestaapp-web vc-vestaapp-account vc-vestaapp-market; do
 echo "=== $c ==="
 timeout 7 docker inspect --format 'state={{.State.Status}} exit={{.State.ExitCode}} restarts={{.RestartCount}} networks={{range.NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$c" 2>/dev/null || true
done
echo "=== WEB RESOLVER ==="
timeout 8 docker exec vc-vestaapp-web nginx -t 2>&1 | tail -8 || true
timeout 8 docker exec vc-nginx nginx -t 2>&1 | tail -8 || true
echo "=== MAIN PROXY ERROR ==="
timeout 8 docker logs --since 4m vc-nginx 2>&1 | grep -E 'app.vesta|upstream.*(unreachable|refused)|connect\(\) failed' | tail -15 | sed -E 's/(authorization:|password=|token=)[^ ]+/\1[REDACTED]/gi' | cut -c1-380 || true
echo "=== APP PROXY ERROR ==="
timeout 8 docker logs --since 4m vc-vestaapp-web 2>&1 | grep -Ei 'error|emerg|upstream|connect|host not found' | tail -18 | cut -c1-380 || true
echo "=== APP ACCOUNT LAST LINES ==="
timeout 8 docker logs --tail 15 vc-vestaapp-account 2>&1 | grep -Ei 'error|warn|listening|start|ready|connection' | tail -10 | cut -c1-200 || true
echo "=== APP MARKET LAST LINES ==="
timeout 8 docker logs --tail 15 vc-vestaapp-market 2>&1 | grep -Ei 'error|warn|listening|start|ready|connection' | tail -10 | cut -c1-200 || true
echo "=== APP HTTP INTERNAL ==="
timeout 14 curl -ksS --connect-timeout 4 --max-time 11 --resolve app.vesta-cosmetics.ir:443:127.0.0.1 -o /dev/null -w 'app=%{http_code}\n' https://app.vesta-cosmetics.ir/ || true
echo "=== CHECK END ==="
