#!/usr/bin/env bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l UCF_FORCE_CONFFOLD=1 APT_LISTCHANGES_FRONTEND=none
umask 077
exec 9>/run/lock/vesta-ubuntu-maintenance.lock
flock -n 9 || { echo UPGRADE_LOCK_BUSY;exit 20; }
OUT=/srv/backups/ubuntu-maintenance-20261024
mkdir -p "$OUT";chmod 700 "$OUT"
echo "MAINTENANCE_STARTED $(date -Is)"
echo "CURRENT_KERNEL=$(uname -r)"
. /etc/os-release
test "$ID" = ubuntu && test "$VERSION_ID" = 24.04 || { echo ABORT_UNEXPECTED_RELEASE;exit 21; }
test -s /srv/backups/vesta-full-db-verify-20261024/vestacos_m-full.sql.gz || { echo ABORT_NO_VESTA_SQL_BACKUP;exit 22; }
test -s /srv/backups/vesta-action-scheduler-pre-repair-20261024/cutella-database.sql.gz || { echo ABORT_NO_CUTELLA_SQL_BACKUP;exit 23; }
timeout 120 gzip -t /srv/backups/vesta-full-db-verify-20261024/vestacos_m-full.sql.gz
timeout 120 gzip -t /srv/backups/vesta-action-scheduler-pre-repair-20261024/cutella-database.sql.gz
(cd /srv/backups/vesta-full-db-verify-20261024 && sha256sum -c SHA256SUMS)
for c in vc-vesta vc-cutella vc-db-vesta vc-db-cutella vc-nginx;do
 test "$(timeout 12 docker inspect -f '{{.State.Running}}' "$c")" = true || { echo "ABORT_CONTAINER_NOT_RUNNING $c";exit 24; }
done
test "$(df -Pk / | awk 'END{print $4}')" -ge 10485760 || { echo ABORT_DISK_FREE_LT_10G;exit 25; }
test "$(awk '/MemAvailable/ {print $2}' /proc/meminfo)" -ge 1048576 || { echo ABORT_MEM_LOW;exit 26; }
io_pressure=$(awk '/^full / {split($2,a,"=");print a[2]}' /proc/pressure/io)
awk -v x="$io_pressure" 'BEGIN {exit !(x < 5.0)}' || { echo ABORT_IO_STALL;exit 27; }
for h in vesta-cosmetics.ir cutellashop.ir app.vesta-cosmetics.ir;do
 status=$(timeout 14 curl -ksS --connect-timeout 5 --max-time 12 --resolve "$h:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$h/" || true)
 echo "PRE_SITE $h http=$status"
 test "$status" = 200 || exit 28
done
echo BACKUPS_AND_SERVICES_VERIFIED
echo APT_SOURCE_UPDATE
timeout 210 apt-get -o DPkg::Lock::Timeout=120 update -qq
echo APT_DRY_RUN
timeout 100 apt-get -s -o Debug::NoLocking=1 full-upgrade > "$OUT/apt-full-upgrade-simulated.txt"
if grep -E '^Remv ' "$OUT/apt-full-upgrade-simulated.txt" > "$OUT/proposed-removals.txt";then
 echo ABORT_UPGRADE_WOULD_REMOVE_PACKAGES
 head -60 "$OUT/proposed-removals.txt"
 exit 29
fi
if [ -n "$(dpkg --audit)" ];then echo ABORT_DPKG_NOT_CLEAN;dpkg --audit;exit 30;fi
echo "BEGIN_FULL_UPGRADE $(date -Is)"
timeout 1320 apt-get -y -o DPkg::Lock::Timeout=180 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold full-upgrade >"$OUT/apt-full-upgrade.log" 2>&1 || {
  rc=$?
  echo "FULL_UPGRADE_FAILED rc=$rc"
  tail -65 "$OUT/apt-full-upgrade.log" | cut -c1-210
  exit "$rc"
}
echo "FULL_UPGRADE_APT_SUCCESS $(date -Is)"
if [ -n "$(dpkg --audit)" ];then dpkg --audit;exit 31;fi
echo KERNEL_PACKAGES_INSTALLED
dpkg -l 'linux-image-*generic' 2>/dev/null | grep '^ii' | tail -12 || true
ls -l /boot/vmlinuz /boot/initrd.img
test -e /boot/vmlinuz
test -e /boot/initrd.img
echo DOCKER_STATUS
timeout 12 systemctl is-active docker
for h in vesta-cosmetics.ir cutellashop.ir app.vesta-cosmetics.ir;do
 status=$(timeout 17 curl -ksS --connect-timeout 5 --max-time 15 --resolve "$h:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$h/" || true)
 echo "AFTER_UPGRADE_SITE $h http=$status"
done
printf '%s\n' UPGRADE_APT_SUCCESS > "$OUT/status"
echo "UPGRADE_COMPLETE_READY_FOR_CONTROLLED_REBOOT $(date -Is)"
