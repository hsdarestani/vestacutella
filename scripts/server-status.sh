#!/usr/bin/env bash
set -u
echo "=== time ==="; date
echo "=== relevant processes ==="; ps -eo pid,etime,cmd | grep -E 'restore-staging|tar -xzf|rsync|mariadb|docker compose' | grep -v grep || true
echo "=== staging/runtime sizes ==="; du -sh /srv/vestacutella/staging /srv/vestacutella/runtime 2>/dev/null || true
echo "=== markers ==="; find /srv/vestacutella -maxdepth 3 -type f \( -name '.extracted' -o -name '.imported' \) -print 2>/dev/null || true
echo "=== containers ==="; docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null || true
echo "=== disk ==="; df -h /
