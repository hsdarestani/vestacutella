#!/usr/bin/env bash
set -u

probe() {
  local site="$1" domain="$2" plugin="$3"
  local root="/srv/vestacutella/runtime/$site/wp-content/plugins"
  local disabled="$root/$plugin.disabled-for-migration"
  local active="$root/$plugin"

  echo "=== $site / $plugin ==="
  if [[ ! -d "$disabled" ]]; then
    echo "not disabled; skipping"
    return 0
  fi
  if [[ -e "$active" ]]; then
    echo "active path already exists; skipping safety test"
    return 0
  fi

  mv "$disabled" "$active"
  sleep 1

  : > /tmp/vc-plugin-body
  code=$(curl --max-time 25 -ksS --resolve "$domain:443:127.0.0.1" -o /tmp/vc-plugin-body -w '%{http_code}' "https://$domain/wp-login.php" || true)
  bytes=$(wc -c < /tmp/vc-plugin-body 2>/dev/null || echo 0)
  echo "login HTTP=$code bytes=$bytes"

  code2=$(curl --max-time 25 -ksS --resolve "$domain:443:127.0.0.1" -o /tmp/vc-plugin-home -w '%{http_code}' "https://$domain/" || true)
  bytes2=$(wc -c < /tmp/vc-plugin-home 2>/dev/null || echo 0)
  echo "home HTTP=$code2 bytes=$bytes2"

  echo "recent relevant log:"
  docker logs --since 45s "vc-$site" 2>&1 | grep -Ei 'fatal|uncaught|ioncube|requires|encoded|loader|error' | tail -n 60 || true

  mv "$active" "$disabled"
  sleep 1
}

probe cutella cutellashop.ir zhaket-updater
probe vesta vesta-cosmetics.ir zhaket-updater
probe vesta vesta-cosmetics.ir xcart
probe vesta vesta-cosmetics.ir smsir

echo "PLUGIN_RUNTIME_PROBE_DONE"
