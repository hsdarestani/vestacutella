#!/usr/bin/env bash
# Host checks every five minutes; static swap occupancy is not memory pressure.
set -uo pipefail
umask 077
STATE=/var/lib/vesta-resource-watchdog
mode="${1:-}"
now=$(date +%s)
mem_kb=$(awk '$1=="MemAvailable:"{print $2}' /proc/meminfo)
mem_total=$(awk '$1=="MemTotal:"{print $2}' /proc/meminfo)
swap_total=$(awk '$1=="SwapTotal:"{print $2}' /proc/meminfo)
swap_free=$(awk '$1=="SwapFree:"{print $2}' /proc/meminfo)
swap_used=$((swap_total-swap_free))
swap_pct=0
(( swap_total>0 )) && swap_pct=$((swap_used*100/swap_total))
disk=$(df -P / | awk 'END{gsub(/%/,"",$5);print $5}')
disk_free_kb=$(df -Pk / | awk 'END{print $4}')
inodes=$(df -Pi / | awk 'END{gsub(/%/,"",$5);print $5}')
load=$(awk '{print int($1)}' /proc/loadavg)
read -r pagein pageout < <(awk '$1=="pswpin"{i=$2} $1=="pswpout"{o=$2} END{print i+0,o+0}' /proc/vmstat)
page_kb=$(( $(getconf PAGESIZE) / 1024 ))
swap_activity_mb=0
if [ "$mode" != "--dry-run" ];then
  mkdir -p "$STATE";chmod 700 "$STATE"
fi
# Recent swap I/O (page-in + page-out). Use sampled deltas, never lifetime totals.
if [ -s "$STATE/swap_sample" ];then
  prev_time=0 prev_in=0 prev_out=0
  read -r prev_time prev_in prev_out < "$STATE/swap_sample" || true
  if [[ "$prev_time" =~ ^[0-9]+$ && "$prev_in" =~ ^[0-9]+$ &&
        "$prev_out" =~ ^[0-9]+$ ]] &&
       (( now>prev_time && now-prev_time<=1200 &&
          pagein>=prev_in && pageout>=prev_out ));then
    swap_activity_mb=$(( (pagein-prev_in+pageout-prev_out)*page_kb/1024 ))
  fi
fi
if [ "$mode" != "--dry-run" ] && [ "$mode" != "--test-alert" ];then
  printf '%s %s %s\n' "$now" "$pagein" "$pageout" > "$STATE/.swap_sample.$$"
  mv -f "$STATE/.swap_sample.$$" "$STATE/swap_sample"
fi
issues=()
keys=()
add(){ keys+=("$1");issues+=("$2"); }
if (( mem_kb<524288 ));then
  add "ram-critical" "CRITICAL RAM available: $((mem_kb/1024)) MB"
elif (( mem_kb<1048576 ));then
  add "ram-low" "RAM available low: $((mem_kb/1024)) MB"
fi
if (( swap_total>0 && swap_used>0 ));then
  if (( swap_pct>=90 ));then
    add "swap-near-full" "Swap nearly full: $((swap_used/1024)) MB ($swap_pct%)"
  elif (( swap_activity_mb>=64 ));then
    add "swap-active" "Swap I/O: $swap_activity_mb MB since previous check"
  elif (( swap_used>=524288 && mem_kb<1572864 ));then
    add "swap-with-low-ram" "Swap $((swap_used/1024)) MB with RAM available $((mem_kb/1024)) MB"
  fi
fi
psi60=$(awk '$1=="some"{for(i=2;i<=NF;i++)if($i~/^avg60=/){split($i,a,"=");print a[2];exit}}' /proc/pressure/memory 2>/dev/null)
if [ -n "$psi60" ] && awk -v p="$psi60" 'BEGIN{exit !(p>=10)}';then
  add "memory-stalls" "High memory pressure stalls (avg60): $psi60%"
fi
if (( disk>=92 ));then
  add "disk-critical" "CRITICAL root disk: $disk% ($((disk_free_kb/1024)) MB free)"
elif (( disk>=85 || disk_free_kb<6291456 ));then
  add "disk-low" "Root disk: $disk% ($((disk_free_kb/1024)) MB free)"
fi
(( inodes>=90 )) && add "inodes-low" "Root inode use: $inodes%"
(( load>=18 )) && add "load-high" "CPU/load average: $load"
for c in vc-vesta vc-cutella vc-db-vesta vc-db-cutella vc-nginx vc-redis vc-vestaapp-web;do
  status=$(timeout 5 docker inspect --format '{{.State.Status}}' "$c" 2>/dev/null)
  [ "$status" = running ] || add "docker:$c" "$c state: ${status:-unknown}"
done
for d in vesta-cosmetics.ir cutellashop.ir;do
  status=$(timeout 12 curl -ksS --connect-timeout 4 --max-time 10 --resolve "$d:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$d/" 2>/dev/null)
  [ "$status" = 200 ] || add "http:$d" "$d origin HTTP ${status:-000}"
done
if [ "$mode" = "--test-alert" ];then
  issues=("Explicit watchdog delivery test")
  keys=("manual-test")
fi
if (( ${#issues[@]}==0 ));then
  echo "$(date -Is) HEALTHY available_mb=$((mem_kb/1024)) passive_swap_mb=$((swap_used/1024)) swap_activity_mb=$swap_activity_mb load=$load disk=$disk%"
  if [ "$mode" != "--dry-run" ];then
    if [ -s "$STATE/active_keys" ] || [ -s "$STATE/active" ];then
      logger -t vesta-resource-watchdog "Resource and service incident recovered"
    fi
    rm -f "$STATE/active_keys" "$STATE/active"
  fi
  exit 0
fi
signature=$(printf '%s\n' "${keys[@]}" | LC_ALL=C sort -u | paste -sd, -)
summary=$(printf '%s; ' "${issues[@]:0:4}")
if (( ${#issues[@]}>4 ));then summary+="+$((${#issues[@]}-4)) additional problems";fi
echo "$(date -Is) WARNING $summary"
if [ "$mode" = "--dry-run" ];then
  echo "DRY_RUN_ALERT_KEYS=$signature (no writes or Telegram)"
  exit 0
fi
logger -t vesta-resource-watchdog "WARNING $summary"
previous=0
[ -s "$STATE/last_sent" ] && read -r previous < "$STATE/last_sent" || true
[[ "$previous" =~ ^[0-9]+$ ]] || previous=0
old_signature=""
[ -s "$STATE/active_keys" ] && old_signature=$(cat "$STATE/active_keys")
# New issue notifies immediately. Unchanged incident: reminder at most every 6h.
if [ "$mode" != "--test-alert" ] &&
   [ "$signature" = "$old_signature" ] && (( now-previous<21600 ));then
  echo "ALERT_UNCHANGED_COOLDOWN_6H"
  exit 0
fi
message="⚠️ Vesta server monitoring
$(date -u '+UTC %Y-%m-%d %H:%M')
$summary
Available RAM: $((mem_kb/1024)) / $((mem_total/1024)) MB
Swap: $((swap_used/1024)) MB ($swap_pct%), activity $swap_activity_mb MB/check
Load: $load | Disk: $disk%
Production: vesta-cosmetics.ir"
if [ "$mode" = "--test-alert" ];then
  message="✅ Vesta watchdog delivery test. Every 5 minutes: RAM, swap pressure, disk, Docker, site HTTPS."
fi
if [ -f /usr/local/lib/vesta-resource-telegram.php ];then
  result=$(timeout 45 docker exec -e VESTA_RESOURCE_ALERT_TEXT="$message" -u www-data -i vc-vesta php -d display_errors=0 < /usr/local/lib/vesta-resource-telegram.php 2>&1)
  rc=$?
  echo "ALERT_RESULT rc=$rc $result"
  if [ "$rc" = 0 ] && [ "$mode" != "--test-alert" ];then
    printf '%s\n' "$now" > "$STATE/.last_sent.$$"
    mv -f "$STATE/.last_sent.$$" "$STATE/last_sent"
    printf '%s\n' "$signature" > "$STATE/.active_keys.$$"
    mv -f "$STATE/.active_keys.$$" "$STATE/active_keys"
    printf '%s\n' "$summary" > "$STATE/.active.$$"
    mv -f "$STATE/.active.$$" "$STATE/active"
  fi
else
  echo "ALERT_TELEGRAM_SCRIPT_MISSING"
fi
exit 0
