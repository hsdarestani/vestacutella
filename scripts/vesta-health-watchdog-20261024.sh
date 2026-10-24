#!/usr/bin/env bash
# Production host resource health watchdog. Only reads state; sends Telegram alerts when needed.
set -uo pipefail
umask 077
STATE=/var/lib/vesta-resource-watchdog
mkdir -p "$STATE"
chmod 700 "$STATE"
now=$(date +%s)
mem_kb=$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)
mem_total=$(awk '/MemTotal:/ {print $2}' /proc/meminfo)
swap_total=$(awk '/SwapTotal:/ {print $2}' /proc/meminfo)
swap_free=$(awk '/SwapFree:/ {print $2}' /proc/meminfo)
swap_used=$((swap_total-swap_free))
disk=$(df -P / | awk 'END {gsub(/%/,"",$5); print $5}')
load=$(awk '{print int($1)}' /proc/loadavg)
issues=()
(( mem_kb < 1048576 )) && issues+=("RAM available low: $((mem_kb/1024)) MB")
(( swap_used > 524288 )) && issues+=("Swap in use: $((swap_used/1024)) MB")
(( disk >= 85 )) && issues+=("Disk usage: $disk%")
(( load >= 18 )) && issues+=("CPU/load average: $load")
for c in vc-vesta vc-cutella vc-db-vesta vc-db-cutella vc-nginx vc-redis vc-vestaapp-web; do
 status=$(timeout 5 docker inspect --format '{{.State.Status}}' "$c" 2>/dev/null)
 if [ "$status" != running ]; then issues+=("$c state: ${status:-unknown}");fi
done
for d in vesta-cosmetics.ir cutellashop.ir; do
 status=$(timeout 12 curl -ksS --connect-timeout 4 --max-time 10 --resolve "$d:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$d/" 2>/dev/null)
 [ "$status" = 200 ] || issues+=("$d origin HTTP ${status:-000}")
done
if [ "${1:-}" = --test-alert ]; then
 issues=("Monitor activated: Vesta resource and service alerts are installed.")
fi
if [ "${#issues[@]}" = 0 ]; then
 echo "$(date -Is) HEALTHY available_mb=$((mem_kb/1024)) swap_used_mb=$((swap_used/1024)) load=$load disk=$disk"
 if [ -f "$STATE/active" ]; then
   rm -f "$STATE/active"
   logger -t vesta-resource-watchdog "Resource and service checks recovered"
 fi
 exit 0
fi
summary=$(printf '%s; ' "${issues[@]}")
echo "$(date -Is) WARNING $summary"
logger -t vesta-resource-watchdog "WARNING $summary"
previous=0
[ -f "$STATE/last_sent" ] && read -r previous < "$STATE/last_sent" || true
if [ "${1:-}" != --test-alert ] && (( now - previous < 1800 )); then
 echo "ALERT_COOLDOWN_ACTIVE"
 exit 0
fi
message="⚠️ Vesta server monitoring
$(date -u '+UTC %Y-%m-%d %H:%M')
$summary
Available RAM: $((mem_kb/1024)) MB / $((mem_total/1024)) MB
Swap in use: $((swap_used/1024)) MB
Load: $load | Disk: $disk%
Production: vesta-cosmetics.ir"
if [ "${1:-}" = --test-alert ]; then
 message="✅ Vesta resource watchdog enabled (5-minute checks). RAM, Swap, Load, Disk, Docker and shop HTTPS are monitored."
fi
if [ -f /usr/local/lib/vesta-resource-telegram.php ]; then
  result=$(timeout 45 docker exec -e VESTA_RESOURCE_ALERT_TEXT="$message" -u www-data -i vc-vesta php -d display_errors=0 < /usr/local/lib/vesta-resource-telegram.php 2>&1)
  rc=$?
  echo "ALERT_RESULT rc=$rc $result"
  if [ "$rc" = 0 ]; then
    echo "$now" > "$STATE/last_sent"
    echo "$summary" > "$STATE/active"
  fi
fi
exit 0
