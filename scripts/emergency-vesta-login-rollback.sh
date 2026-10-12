#!/usr/bin/env bash
set -euo pipefail
R=/srv/vestacutella/runtime/vesta
echo "=== emergency rollback experimental login plugins ==="
docker exec vc-vesta php -r '
require "/var/www/html/wp-load.php";
require_once ABSPATH."wp-admin/includes/plugin.php";
deactivate_plugins(["smsir/index.php","xcart/xcart.php"], true);
echo "deactivated\n";
' >/dev/null 2>&1 || true
[[ -d "$R/wp-content/plugins/smsir" ]] && mv "$R/wp-content/plugins/smsir" "$R/wp-content/plugins/smsir.disabled-for-migration" || true
[[ -d "$R/wp-content/plugins/xcart" ]] && mv "$R/wp-content/plugins/xcart" "$R/wp-content/plugins/xcart.disabled-for-migration" || true
docker restart vc-vesta >/dev/null
sleep 5
for p in / /my-account/ /shop/; do
  code="$(curl -ksS --max-time 30 --resolve vesta-cosmetics.ir:443:127.0.0.1 -o /dev/null -w '%{http_code}' "https://vesta-cosmetics.ir$p" || true)"
  echo "$p HTTP=$code"
done
echo "ROLLBACK_LOGIN_EXPERIMENTS_OK"
