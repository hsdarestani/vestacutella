#!/usr/bin/env bash
set -uo pipefail
echo "=== APACHE PROCESS LIMITS ==="
for c in vc-vesta vc-cutella; do
  echo "CONTAINER=$c"
  timeout 8 docker exec "$c" sh -c 'cat /etc/apache2/mods-enabled/mpm_prefork.conf 2>/dev/null | grep -Ei "StartServers|MinSpareServers|MaxSpareServers|MaxRequestWorkers|MaxConnectionsPerChild"' || true
  timeout 8 docker exec "$c" sh -c 'grep -RE "MaxRequestWorkers|MaxConnectionsPerChild|ServerLimit" /etc/apache2/sites-enabled /etc/apache2/conf-enabled 2>/dev/null | head -10' || true
done
echo "=== APP RESTART ROOT CAUSE (SAFE SHORT ERRORS) ==="
timeout 7 docker inspect --format 'status={{.State.Status}} exit={{.State.ExitCode}} error={{.State.Error}} restarts={{.RestartCount}}' vc-vestaapp-web || true
timeout 10 docker logs --tail 85 vc-vestaapp-web 2>&1 | grep -iE 'traceback|error|fail|cannot|refused|connect|missing|fatal|import' | head -20 | cut -c1-220 || true
echo "=== WP CRON CONFIG FLAGS ==="
for s in vesta cutella; do
  echo "site=$s"
  grep -E "DISABLE_WP_CRON|ALTERNATE_WP_CRON" "/srv/vestacutella/runtime/$s/wp-config.php" 2>/dev/null | sed -E "s/(define\([^)]+\)).*/\1/" | head -4 || true
done
echo "=== PREVIOUS BOOT OOM EVENTS ==="
timeout 8 journalctl -b -1 -k --no-pager -o cat 2>/dev/null | grep -iE 'oom|out of memory|killed process' | tail -12 | cut -c1-230 || true
echo "=== DOCKER LOGGING DRIVER ==="
timeout 8 docker info --format '{{.LoggingDriver}}' || true
echo DONE
