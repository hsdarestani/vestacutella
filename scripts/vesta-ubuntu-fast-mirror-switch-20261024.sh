#!/usr/bin/env bash
# Switch Ubuntu mirror only when original apt-get is still fetching and dpkg is idle.
set -Eeuo pipefail
umask 077
LOG=/srv/backups/ubuntu-maintenance-20261024/apt-full-upgrade.log
BACK=/srv/backups/ubuntu-maintenance-20261024/mirror-switch
mkdir -p "$BACK";chmod 700 "$BACK"
echo "=== SAFE MIRROR ADAPTATION ==="
test -s "$LOG" || { echo NO_APT_LOG; exit 20; }
if grep -Eq '^Unpacking |^Setting up |^Preparing to unpack|^Processing triggers' "$LOG";then
  echo "NO_CHANGE_DPKG_INSTALL_HAS_STARTED"
  exit 0
fi
if pgrep -x dpkg >/dev/null || pgrep -x 'dpkg-deb' >/dev/null;then
  echo "NO_CHANGE_DPKG_CURRENTLY_ACTIVE"
  exit 0
fi
pid=$(ps -eo pid,comm,args | awk '$2=="apt-get" && /full-upgrade/ {print $1;exit}')
if [ -z "$pid" ];then echo "NO_CHANGE_UPGRADE_NOT_CURRENTLY_DOWNLOADING";exit 0;fi
echo "APT_DOWNLOAD_PID=$pid"
test "$(grep -c '^Get:' "$LOG")" -ge 20
url=https://mirror.iranserver.com/ubuntu/dists/noble-updates/InRelease
timeout 15 curl -fsSL --connect-timeout 5 --max-time 12 -o "$BACK/local-InRelease" "$url"
test "$(stat -c %s "$BACK/local-InRelease")" -gt 50000
grep '^Date:' "$BACK/local-InRelease" | head -1
echo "=== STOP CURRENT DOWNLOAD CLEANLY ==="
kill -TERM "$pid"
for i in $(seq 1 35);do
  if ! kill -0 "$pid" 2>/dev/null;then break;fi
  sleep 1
done
if kill -0 "$pid" 2>/dev/null;then echo "APT_STILL_RUNNING_ABORT_NO_SOURCE_CHANGE";exit 31;fi
if pgrep -x dpkg >/dev/null;then echo "DPKG_ACTIVE_ABORT_NO_SOURCE_CHANGE";exit 32;fi
echo "APT_DOWNLOAD_STOPPED"
echo "=== SAFE SOURCE EDIT (KEEP SIGNATURE VERIFICATION) ==="
changed=0
while IFS= read -r -d '' file;do
  if grep -q 'de.archive.ubuntu.com/ubuntu' "$file";then
     dst="$BACK/$(basename "$file").backup"
     cp -p "$file" "$dst"
     sed -i 's#http://de.archive.ubuntu.com/ubuntu#https://mirror.iranserver.com/ubuntu#g;s#https://de.archive.ubuntu.com/ubuntu#https://mirror.iranserver.com/ubuntu#g' "$file"
     echo "UPDATED_FILE=$(basename "$file")"
     changed=$((changed+1))
  fi
done < <(find /etc/apt -maxdepth 3 -type f \( -name '*.sources' -o -name 'sources.list' \) -print0)
test "$changed" -gt 0 || { echo NO_SOURCE_MATCH;exit 33; }
echo "=== VALIDATE SIGNED APT REPOSITORY ==="
if ! timeout 210 apt-get -o DPkg::Lock::Timeout=60 update -qq;then
  echo "MIRROR_APT_UPDATE_FAILED"
  for f in "$BACK/"*.backup;do
    test -f "$f" || continue
    b=$(basename "$f" .backup)
    if [ "$b" = sources.list ];then cp -p "$f" /etc/apt/sources.list;else cp -p "$f" "/etc/apt/sources.list.d/$b";fi
  done
  exit 34
fi
echo "MIRROR_SWITCH_SUCCESS"
