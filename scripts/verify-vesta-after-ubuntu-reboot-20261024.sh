#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C
echo "=== POST UPDATE BOOT REPORT ==="
. /etc/os-release
echo "OS=$PRETTY_NAME"
echo "CURRENT_KERNEL=$(uname -r)"
expected=$(basename "$(readlink -f /boot/vmlinuz)" | sed 's/^vmlinuz-//')
echo "EXPECTED_KERNEL=$expected"
test "$ID" = ubuntu
test "$VERSION_ID" = 24.04
test "$(uname -r)" = "$expected" || { echo ERROR_NEW_KERNEL_NOT_RUNNING;exit 40; }
echo "UPGRADE_STATUS="
cat /srv/backups/ubuntu-maintenance-20261024/status
test -z "$(dpkg --audit)"
echo "SYSTEMD_DOCKER="
systemctl is-active docker
echo "=== RESTORE STOPPED EXISTING CONTAINERS WITHOUT RECREATE ==="
for name in vc-db-vesta vc-db-cutella vc-redis vc-vesta vc-cutella vc-vestaapp-account vc-vestaapp-market vc-vestaapp-web vc-nginx;do
    status=$(timeout 7 docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || true)
    echo "BEFORE $name=$status"
    if [ "$status" != running ];then
      echo "START $name"
      timeout 50 docker start "$name" >/dev/null || true
    fi
done
sleep 7
if [ "$(timeout 8 docker inspect -f '{{.State.Running}}' vc-vestaapp-web)" != true ];then
 timeout 50 docker restart vc-vestaapp-web >/dev/null || true
fi
for c in vc-db-vesta vc-db-cutella vc-vesta vc-cutella vc-nginx;do
    test "$(timeout 10 docker inspect -f '{{.State.Running}}' "$c")" = true || { echo "CONTAINER_NOT_RUNNING $c";exit 41; }
done
echo "=== REFRESH PROXY UPSTREAM DNS ==="
timeout 12 docker exec vc-nginx nginx -t
timeout 12 docker exec vc-nginx nginx -s reload
echo "=== SHOP ORIGIN CHECK ==="
failed=0
for host in vesta-cosmetics.ir cutellashop.ir app.vesta-cosmetics.ir;do
 ok=0
 for attempt in 1 2 3 4 5;do
   code=$(timeout 20 curl -ksS --connect-timeout 5 --max-time 18 --resolve "$host:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$host/" || true)
   echo "TEST $host attempt=$attempt HTTP=$code"
   [ "$code" = 200 ] && { ok=1;break; }
   sleep 8
 done
 if [ "$ok" != 1 ];then failed=1;fi
done
echo "=== SYSTEM RESOURCES ==="
uptime;free -h;df -h /
echo "=== CONTAINERS ==="
timeout 18 docker ps --format '{{.Names}} {{.Status}}' | head -20
echo "=== STATUS ==="
if [ "$failed" != 0 ];then echo POSTBOOT_PARTIAL_FAILURE;exit 42;fi
echo "POSTBOOT_NEW_KERNEL_AND_3_SITES_HEALTHY"
