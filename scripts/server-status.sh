#!/usr/bin/env bash
set -u
echo "=== time ==="; date
echo "=== relevant processes ==="
ps -eo pid,etime,comm | grep -E 'restore-staging|tar|rsync|mariadb|docker' || true
echo "=== staging/runtime sizes ==="; du -sh /srv/vestacutella/staging /srv/vestacutella/runtime 2>/dev/null || true
echo "=== markers ==="; find /srv/vestacutella -maxdepth 3 -type f \( -name '.extracted' -o -name '.imported' -o -name '.app-passwords-rotated' \) -print 2>/dev/null || true
echo "=== containers ==="; docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null || true
echo "=== disk ==="; df -h /
