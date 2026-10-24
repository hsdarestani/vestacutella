#!/usr/bin/env bash
# Start only previously installed Vesta app service dependencies, without rebuilding.
set -Eeuo pipefail
precheck() { curl -ksS --connect-timeout 4 --max-time 18 --resolve "$1:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$1/"; }
echo "=== STORES PRECHECK ==="
test "$(precheck vesta-cosmetics.ir)" = 200
test "$(precheck cutellashop.ir)" = 200
echo "=== APP EXISTING SERVICES ==="
for c in vc-vestaapp-account vc-vestaapp-market vc-vestaapp-web; do
  timeout 8 docker inspect --format '{{.Name}} image={{.Config.Image}} state={{.State.Status}} restarts={{.RestartCount}}' "$c"
done
for c in vc-vestaapp-account vc-vestaapp-market; do
  current=$(timeout 8 docker inspect --format '{{.State.Status}}' "$c")
  if [ "$current" != running ]; then
    echo "STARTING $c"
    timeout 35 docker start "$c"
  fi
done
sleep 6
echo "=== APP SERVICE STATE ==="
for c in vc-vestaapp-account vc-vestaapp-market; do
  current=$(timeout 8 docker inspect --format '{{.State.Status}}' "$c")
  echo "$c=$current"
  if [ "$current" != running ]; then
    echo "APP_SERVICE_START_FAILED $c"
    timeout 8 docker logs --tail 12 "$c" 2>&1 | tail -12 | cut -c1-180 || true
    exit 31
  fi
done
if [ "$(timeout 8 docker inspect --format '{{.State.Status}}' vc-vestaapp-web)" != running ]; then
 timeout 30 docker restart vc-vestaapp-web >/dev/null
fi
sleep 6
echo "=== APP PROBE ==="
app=$(precheck app.vesta-cosmetics.ir || true)
echo "APP_LOCAL_HTTP=$app"
case "$app" in 200|301|302|303) ;; *) exit 32;; esac
echo "=== STORE REGRESSION ==="
test "$(precheck vesta-cosmetics.ir)" = 200
test "$(precheck cutellashop.ir)" = 200
echo "=== MEMORY SNAPSHOT ==="
free -m
timeout 18 docker stats --no-stream --format '{{.Name}}|{{.MemUsage}}' vc-vestaapp-account vc-vestaapp-market vc-vestaapp-web
echo "VESTA_APP_SERVICES_RESTORED"
