#!/usr/bin/env bash
set -u
echo "=== time ==="; date
echo "=== migration files ==="; ls -lh /srv/migration 2>/dev/null || true
echo "=== staging markers ==="; find /srv/vestacutella/staging -maxdepth 1 -type f -printf '%f %s bytes\n' 2>/dev/null || true
echo "=== staging size ==="; du -sh /srv/vestacutella/staging 2>/dev/null || true
echo "=== runtime size ==="; du -sh /srv/vestacutella/runtime 2>/dev/null || true
echo "=== containers ==="; docker ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null || true
echo "=== restore processes ==="; ps -eo pid,etimes,%cpu,%mem,cmd | grep -E 'restore-staging|tar -xzf|mariadb|docker compose|rsync' | grep -v grep || true
echo "=== disk ==="; df -h /
