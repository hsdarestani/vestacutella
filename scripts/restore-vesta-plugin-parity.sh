#!/usr/bin/env bash
set -euo pipefail

BASE=/srv/vestacutella
RUNTIME="$BASE/runtime/vesta"
BACKUP="/srv/backups/vesta-plugin-parity-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$BACKUP"

echo "=== backup active plugin state ==="
docker exec vc-vesta php -r '
require "/var/www/html/wp-load.php";
echo base64_encode(serialize(get_option("active_plugins",[])));
' > "$BACKUP/active_plugins.b64"

rollback() {
  echo "=== rollback plugin parity ==="
  local raw
  raw="$(cat "$BACKUP/active_plugins.b64" 2>/dev/null || true)"
  if [[ -n "$raw" ]]; then
    docker exec -e AP="$raw" vc-vesta php -r '
      require "/var/www/html/wp-load.php";
      $a=@unserialize(base64_decode(getenv("AP")));
      if (is_array($a)) update_option("active_plugins",$a);
    ' || true
  fi
  [[ -d "$RUNTIME/wp-content/plugins/smsir" && ! -d "$RUNTIME/wp-content/plugins/smsir.disabled-for-migration" ]] && mv "$RUNTIME/wp-content/plugins/smsir" "$RUNTIME/wp-content/plugins/smsir.disabled-for-migration" || true
  [[ -d "$RUNTIME/wp-content/plugins/xcart" && ! -d "$RUNTIME/wp-content/plugins/xcart.disabled-for-migration" ]] && mv "$RUNTIME/wp-content/plugins/xcart" "$RUNTIME/wp-content/plugins/xcart.disabled-for-migration" || true
  docker restart vc-vesta >/dev/null 2>&1 || true
}
trap 'rc=$?; if [[ $rc -ne 0 ]]; then rollback; fi; exit $rc' EXIT

restore_plugin_dir() {
  local name="$1"
  if [[ -d "$RUNTIME/wp-content/plugins/$name.disabled-for-migration" && ! -e "$RUNTIME/wp-content/plugins/$name" ]]; then
    mv "$RUNTIME/wp-content/plugins/$name.disabled-for-migration" "$RUNTIME/wp-content/plugins/$name"
  fi
}

activate_one() {
  local file="$1"
  docker exec -e PLUGIN_FILE="$file" vc-vesta php -d display_errors=1 -r '
    require "/var/www/html/wp-load.php";
    require_once ABSPATH."wp-admin/includes/plugin.php";
    $p=getenv("PLUGIN_FILE");
    if (!is_plugin_active($p)) {
      $r=activate_plugin($p,"",false,true);
      if (is_wp_error($r)) {
        fwrite(STDERR,$r->get_error_message().PHP_EOL);
        exit(2);
      }
    }
    echo $p." active=".(is_plugin_active($p)?"yes":"no").PHP_EOL;
  '
}

smoke() {
  local label="$1"
  echo "=== smoke $label ==="
  for p in / /my-account/ /checkout/; do
    code="$(curl -ksS --max-time 35 -o /tmp/vesta-smoke -w '%{http_code}' "https://vesta-cosmetics.ir$p" || true)"
    echo "$p HTTP=$code bytes=$(wc -c </tmp/vesta-smoke 2>/dev/null || echo 0)"
    case "$code" in
      200|302) ;;
      *) return 1 ;;
    esac
  done
}

echo "=== restore and activate SMSIR ==="
restore_plugin_dir smsir
activate_one "smsir/index.php"
docker restart vc-vesta >/dev/null
sleep 5
smoke "after SMSIR"

echo "=== verify SMSIR login markup ==="
curl -ksS --max-time 30 https://vesta-cosmetics.ir/my-account/ -o /tmp/my-account.html
grep -q 'smsir-login-app' /tmp/my-account.html
echo "smsir_login_markup=present"

echo "=== restore and activate XCart ==="
restore_plugin_dir xcart
activate_one "xcart/xcart.php"
docker restart vc-vesta >/dev/null
sleep 5
smoke "after XCart"

echo "=== clear caches ==="
docker exec vc-vesta php -r '
require "/var/www/html/wp-load.php";
if (function_exists("rocket_clean_domain")) rocket_clean_domain();
' || true
docker restart vc-vesta >/dev/null
sleep 5

echo "=== final parity checks ==="
curl -ksS --max-time 30 https://vesta-cosmetics.ir/my-account/ -o /tmp/my-account-final.html
grep -q 'smsir-login-app' /tmp/my-account-final.html
grep -q '/wp-content/plugins/xcart/' /tmp/my-account-final.html
echo "smsir_markup=present"
echo "xcart_assets=present"

docker exec vc-vesta php -r '
require "/var/www/html/wp-load.php";
require_once ABSPATH."wp-admin/includes/plugin.php";
foreach (["smsir/index.php","xcart/xcart.php"] as $p) {
  echo $p."=".(is_plugin_active($p)?"active":"inactive").PHP_EOL;
}
'

trap - EXIT
echo "VESTA_PLUGIN_PARITY_OK"
