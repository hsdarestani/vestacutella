#!/usr/bin/env bash
set +e
export LC_ALL=C
echo "==== VESTA DISK INCIDENT FORENSICS ===="
date -Is;uptime
echo "=== RECENT KERNEL WARNINGS WITH TIMES ==="
timeout 18 journalctl -k -b --since '2026-10-24 19:10:00' -o short-iso --no-pager 2>/dev/null | grep -Ei 'blocked for more|task:|jbd2|writepages|ext4|vda|I/O error|blk_|nvme|virtio|reset|timeout|hung_task|oom|throttl' | tail -95 | cut -c1-270
echo "=== LIVE DISK IOPS AND LATENCY ==="
if command -v iostat >/dev/null; then timeout 12 iostat -dx 1 5; else echo 'iostat unavailable'; fi
echo "=== HISTORICAL DISK IO STATS ==="
if command -v sar >/dev/null; then timeout 8 sar -d -p -s 19:00:00 | tail -23;fi
echo "=== BLOCK DEVICES ==="
lsblk -o NAME,SIZE,ROTA,TYPE,FSTYPE,MOUNTPOINTS 2>/dev/null | head -20
echo "=== IO AND MEMORY PRESSURE ==="
for x in /proc/pressure/{io,cpu,memory}; do echo "$x";cat "$x";done
echo "=== EXT4 MOUNT OPTIONS ===";findmnt -n -o TARGET,SOURCE,FSTYPE,OPTIONS / | cut -c1-250
echo "=== RECENT VESTA MONITOR OUTPUT ===";timeout 5 tail -n 16 /var/log/vesta-resource-watchdog.log 2>/dev/null | cut -c1-240
echo "=== LAST SERVICE LOGS ===";timeout 8 journalctl -u docker -b --since '-10 minutes' --no-pager -o short-iso 2>/dev/null | grep -Ei 'error|fail|timeout|restart' | tail -15 | cut -c1-240
echo "=== HOST SERVICE HEALTH ==="
free -h;timeout 8 docker ps --format '{{.Names}} {{.Status}}' | head -15
echo "=== FINAL DISK PRESSURE SUMMARY ==="
cat /proc/pressure/io
echo "==== FORENSICS COMPLETED ===="
