#!/usr/bin/env bash
set -uo pipefail
echo "=== INTEGRATION PREFLIGHT ==="
echo "== Named host settings (keys only, no values) =="
if test -f /srv/vestacutella/.env; then sed -nE 's/^([A-Za-z_][A-Za-z_0-9]*)=.*/\1/p' /srv/vestacutella/.env | grep -Ei 'TELEGRAM|BOT|CHAT|ALERT|SMTP|MAIL|WEBHOOK' | sort -u; fi
echo "== Telegram-related env files (filenames only) =="
find /etc/default /etc/cron.d /srv/vestacutella -maxdepth 3 -type f \( -iname '*telegram*' -o -iname '*monitor*' -o -iname '*alert*' \) -print 2>/dev/null | head -35
echo "== WP cron state =="; ls -l /etc/cron.d/*vesta* 2>/dev/null | head -15
echo "== app web recent errors =="; timeout 10 docker logs --tail 75 vc-vestaapp-web 2>&1 | sed -E 's/(token|password|secret|apikey|api_key)=([^ ,;]+)/\1=[REDACTED]/gi' | tail -34 | cut -c1-220
echo "== App service startup config =="; timeout 6 docker inspect --format '{{.Name}}|{{.Config.Image}}|{{.HostConfig.RestartPolicy.Name}}|{{.State.Status}}' vc-vestaapp-web vc-vestaapp-account vc-vestaapp-market 2>/dev/null || true
echo "== apache configs source =="; for c in vc-vesta vc-cutella; do echo "$c"; timeout 4 docker exec "$c" apache2ctl -t 2>&1 | tail -3; done
echo "== preflight complete =="
