#!/usr/bin/env bash
# Safe, bounded live Apache concurrency protection; no databases/uploads are touched.
set -Eeuo pipefail
umask 077
exec 9>/run/lock/vesta-stability-install.lock
flock -n 9 || { echo GUARD_LOCK_BUSY;exit 15; }
BASE=/srv/vestacutella
BACKUP=/srv/backups/vesta-stability-$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "$BACKUP"
chmod 700 "$BACKUP"
status() { timeout 18 curl -ksS --connect-timeout 5 --max-time 16 --resolve "$1:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$1$2" || true; }
echo "== PREFLIGHT =="
test "$(status vesta-cosmetics.ir /)" = 200
test "$(status cutellashop.ir /)" = 200
available=$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)
test "$available" -ge 1048576
for c in vc-vesta vc-cutella; do
 test "$(timeout 10 docker inspect --format '{{.State.Running}}' "$c")" = true
 docker cp "$c:/etc/apache2/mods-available/mpm_prefork.conf" "$BACKUP/$c.mpm.conf"
 timeout 10 docker exec "$c" apache2ctl -t 2>&1 | grep -q 'Syntax OK'
done
echo "BACKUP=$BACKUP"
old_vesta=$(docker inspect --format '{{.HostConfig.Memory}}' vc-vesta)
old_cutella=$(docker inspect --format '{{.HostConfig.Memory}}' vc-cutella)
old_vesta_swap=$(docker inspect --format '{{.HostConfig.MemorySwap}}' vc-vesta)
old_cutella_swap=$(docker inspect --format '{{.HostConfig.MemorySwap}}' vc-cutella)
echo "OLD_LIMITS vesta=$old_vesta cutella=$old_cutella"
test "$old_vesta" = 0 || test "$old_vesta" = 3040870400
test "$old_cutella" = 0 || test "$old_cutella" = 1572864000
for c in vc-vesta vc-cutella; do
  if [ "$c" = vc-vesta ]; then workers=12; else workers=6; fi
  python3 - "$BACKUP/$c.mpm.conf" "$BACKUP/$c.new.conf" "$workers" <<'PY'
import sys,re
from pathlib import Path
s=Path(sys.argv[1]).read_text()
n=int(sys.argv[3])
values={"StartServers":2,"MinSpareServers":2,"MaxSpareServers":4,"MaxRequestWorkers":n,"MaxConnectionsPerChild":400}
for k,v in values.items():
 pattern=r"(?m)^(\s*)("+re.escape(k)+r")(\s+)\d+([ \t]*)$"
 if len(re.findall(pattern,s))!=1:raise SystemExit("Unsafe Apache config drift for "+k)
 s=re.sub(pattern,lambda m: m.group(1)+m.group(2)+m.group(3)+str(v)+m.group(4),s)
Path(sys.argv[2]).write_text(s)
PY
done
changed_vesta=0
changed_cutella=0
limits_changed=0
finished=0
rollback() {
 rc=$?
 trap - ERR EXIT
 if [ "$finished" != 1 ]; then
   echo "ROLLBACK rc=$rc"
   if [ "$changed_vesta" = 1 ]; then docker cp "$BACKUP/vc-vesta.mpm.conf" vc-vesta:/etc/apache2/mods-available/mpm_prefork.conf || true;timeout 20 docker exec vc-vesta apache2ctl -k graceful || true;fi
   if [ "$changed_cutella" = 1 ]; then docker cp "$BACKUP/vc-cutella.mpm.conf" vc-cutella:/etc/apache2/mods-available/mpm_prefork.conf || true;timeout 20 docker exec vc-cutella apache2ctl -k graceful || true;fi
   if [ "$limits_changed" = 1 ]; then
     timeout 20 docker update --memory "$old_vesta" --memory-swap "$old_vesta_swap" vc-vesta || true
     timeout 20 docker update --memory "$old_cutella" --memory-swap "$old_cutella_swap" vc-cutella || true
   fi
 fi
 exit "$rc"
}
trap rollback ERR EXIT
for c in vc-vesta vc-cutella; do
  docker cp "$BACKUP/$c.new.conf" "$c:/etc/apache2/mods-available/mpm_prefork.conf"
  if [ "$c" = vc-vesta ]; then changed_vesta=1; else changed_cutella=1; fi
  timeout 12 docker exec "$c" apache2ctl -t
  timeout 18 docker exec "$c" apache2ctl -k graceful
  sleep 2
  if [ "$c" = vc-vesta ]; then d=vesta-cosmetics.ir; else d=cutellashop.ir; fi
  code=$(status "$d" /)
  echo "AFTER_APACHE $d HTTP=$code"
  test "$code" = 200
done
# Exact byte values avoid platform-specific suffix interpretation.
limits_changed=1
timeout 20 docker update --memory 3040870400 --memory-swap 3670016000 vc-vesta
timeout 20 docker update --memory 1572864000 --memory-swap 1939865600 vc-cutella
echo "== MEMORY CAPS =="
for c in vc-vesta vc-cutella; do docker inspect --format '{{.Name}} ram_cap={{.HostConfig.Memory}} swap_total={{.HostConfig.MemorySwap}}' "$c";done
for d in vesta-cosmetics.ir cutellashop.ir; do
 for path in / /shop/ /cart/ /checkout/ /my-account/ /wp-login.php; do
  code=$(status "$d" "$path")
  echo "SMOKE $d$path HTTP=$code"
  case "$code" in 200|301|302) ;; *) exit 40;;esac
 done
done
echo "== PERSISTENT REAPPLICATION SCRIPT =="
install -m 700 /tmp/vesta-runtime-limits-enforcer-20261024.sh /usr/local/sbin/vesta-runtime-limits-enforcer
mkdir -p /etc/cron.d
cat > /etc/cron.d/vesta-runtime-limits <<'CRON'
*/5 * * * * root /usr/bin/flock -n /run/lock/vesta-runtime-limits.lock /usr/bin/timeout 45 /usr/local/sbin/vesta-runtime-limits-enforcer >/dev/null 2>>/var/log/vesta-runtime-limits-errors.log
CRON
chmod 644 /etc/cron.d/vesta-runtime-limits
systemctl reload cron 2>/dev/null || true
finished=1
trap - ERR EXIT
echo "STABILITY_GUARDS_APPLIED backup=$BACKUP workers=vesta12_cutella6"
