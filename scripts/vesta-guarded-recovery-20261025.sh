#!/usr/bin/env bash
# Conservative internal service recovery with incident evidence and cooldowns.
set -uo pipefail
STATE=/var/lib/vesta-guarded-recovery
DRY=${VESTA_DRY_RUN:-0}
mkdir -p "$STATE/incidents"
chmod 700 "$STATE" "$STATE/incidents"
exec 9>"$STATE/lock"
flock -n 9 || exit 0
probe(){ timeout 10 curl --noproxy '*' -sk -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 8 --resolve "$1:443:127.0.0.1" "https://$1/" 2>/dev/null || true; }
v=$(probe vesta-cosmetics.ir); c=$(probe cutellashop.ir)
case "$v" in 200|301|302) vf=0;; *) vf=1;; esac
case "$c" in 200|301|302) cf=0;; *) cf=1;; esac
now=$(date +%s)
uptime_sec=$(awk '{print int($1)}' /proc/uptime)
if ((uptime_sec<900));then logger -t vesta-recovery "BOOT_GRACE uptime=$uptime_sec";exit 0;fi
readnum(){ local n=0; [ -f "$1" ] && read -r n < "$1"; [[ "$n" =~ ^[0-9]+$ ]] || n=0;echo "$n"; }
if ((vf==0 && cf==0));then echo 0 >"$STATE/fail";echo 0 >"$STATE/both";exit 0;fi
fail=$(( $(readnum "$STATE/fail")+1 ));echo "$fail" >"$STATE/fail"
both=0
if ((vf==1 && cf==1));then both=$(( $(readnum "$STATE/both")+1 ));fi
echo "$both" >"$STATE/both"
logger -t vesta-recovery "Degraded: vesta=$v cutella=$c consecutive=$fail simultaneous=$both"
if ((fail==2 || both==3 || both==6));then
  p="$STATE/incidents/$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$p";chmod 700 "$p"
  (date -Is;uptime;free -h;df -h /;cat /proc/pressure/io;ps -eo stat,pcpu,rss,wchan:20,comm | head -50;timeout 6 docker ps -a) >"$p/host.txt" 2>&1
  timeout 8 journalctl -k -n 80 --no-pager >"$p/kernel.txt" 2>&1 || true
fi
if ((fail>=3 && both==0));then
  for entry in "vc-vesta:$vf" "vc-cutella:$cf";do
    name=${entry%%:*};bad=${entry#*:}
    [ "$bad" = 1 ] || continue
    marker="$STATE/restart_$name"
    last=$(readnum "$marker")
    if ((now-last>=1800));then
      echo "$now" >"$marker"
      logger -t vesta-recovery "Container restart planned: $name"
      if [ "$DRY" != 1 ];then timeout 30 docker restart -t 15 "$name" >/dev/null 2>&1 || true;fi
    fi
  done
fi
if ((both==3));then
  logger -t vesta-recovery "Reverse proxy restart planned"
  if [ "$DRY" != 1 ];then timeout 30 docker restart -t 15 vc-nginx >/dev/null 2>&1 || true;fi
fi
if ((both>=6));then
  last=$(readnum "$STATE/reboot_at")
  uptime_sec=$(awk '{print int($1)}' /proc/uptime)
  if (( now-last>=28800 && uptime_sec>=900 ));then
    if ! pgrep -f '[m]ariadb-dump|[m]ysqldump|[m]ariabackup' >/dev/null;then
      findmnt -n -o OPTIONS / | grep -Eq '(^|,)rw(,|$)' || exit 0
      disk=$(df -P / | awk 'END{gsub(/%/,"",$5);print $5}')
      if [[ "$disk" =~ ^[0-9]+$ ]] && ((disk>=95));then exit 0;fi
      v2=$(probe vesta-cosmetics.ir);c2=$(probe cutellashop.ir)
      case "$v2:$c2" in 200:*|301:*|302:*|*:200|*:301|*:302) exit 0;; esac
      if [ "$DRY" = 1 ];then logger -t vesta-recovery "DRY_RUN_WOULD_REBOOT";exit 0;fi
      echo "$now" >"$STATE/reboot_at";sync
      logger -t vesta-recovery "Host reboot requested after six confirmed origin failures"
      systemctl reboot --no-block
    fi
  fi
fi
