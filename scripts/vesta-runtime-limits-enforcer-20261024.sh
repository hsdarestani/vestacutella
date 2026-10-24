#!/usr/bin/env bash
# Restore tuned limits after container image re-creation. Never touches database.
set -u
for entry in "vc-vesta:3040870400:3670016000" "vc-cutella:1572864000:1939865600"; do
 IFS=: read -r c m s <<< "$entry"
 [ "$(timeout 6 docker inspect --format '{{.State.Running}}' "$c" 2>/dev/null)" = true ] || continue
 cur="$(timeout 6 docker inspect --format '{{.HostConfig.Memory}}' "$c" 2>/dev/null)"
 [ "$cur" = "$m" ] || timeout 14 docker update --memory "$m" --memory-swap "$s" "$c" >/dev/null || true
 target="$( [ "$c" = vc-vesta ] && echo 12 || echo 6 )"
 conf="$(timeout 5 docker exec "$c" sh -c 'grep -E "^[[:space:]]*MaxRequestWorkers[[:space:]]+" /etc/apache2/mods-available/mpm_prefork.conf | head -1' 2>/dev/null)"
 current="$(echo "$conf" | awk '{print $2}')"
 if [ "$current" != "$target" ] && [ -s /srv/vestacutella/runtime/guards/"$c".conf ]; then
  timeout 12 docker cp /srv/vestacutella/runtime/guards/"$c".conf "$c:/etc/apache2/mods-available/mpm_prefork.conf" >/dev/null &&
  timeout 9 docker exec "$c" apache2ctl -t >/dev/null 2>&1 &&
  timeout 14 docker exec "$c" apache2ctl -k graceful >/dev/null 2>&1 || true
 fi
done
