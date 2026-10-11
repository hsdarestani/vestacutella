#!/usr/bin/env bash
set -u

BASE=/srv/vestacutella/runtime/cutella
MU="$BASE/wp-content/mu-plugins/01-vc-admin-diagnostic.php"

cat > "$MU" <<'PHP'
<?php
/*
Plugin Name: VC Admin Diagnostic
*/
if (!empty($_SERVER['HTTP_X_VC_DIAG']) && $_SERVER['HTTP_X_VC_DIAG'] === 'no-plugins') {
    add_filter('option_active_plugins', function ($plugins) { return []; }, PHP_INT_MIN);
    add_filter('site_option_active_sitewide_plugins', function ($plugins) { return []; }, PHP_INT_MIN);
}
PHP
chown 33:33 "$MU"

req() {
  local label="$1"; shift
  echo "=== $label ==="
  /usr/bin/time -f 'ELAPSED=%e CPU=%P MAXRSS=%MKB'     curl --max-time 45 -ksS -D /tmp/vc-h -o /tmp/vc-b       --resolve cutellashop.ir:443:127.0.0.1 "$@"       https://cutellashop.ir/wp-admin/ || true
  head -n 20 /tmp/vc-h || true
  echo "BODY_BYTES=$(wc -c < /tmp/vc-b 2>/dev/null || echo 0)"
}

rm -f "$BASE/wp-content/debug.log" || true
req "normal admin request"

req "admin request with regular plugins bypassed" -H 'X-VC-Diag: no-plugins'

echo "=== recent apache log ==="
docker logs --since 3m vc-cutella 2>&1 | tail -n 120 || true

echo "=== debug log ==="
tail -n 150 "$BASE/wp-content/debug.log" 2>/dev/null || true

echo "=== active plugins from DB ==="
docker exec vc-db-cutella mariadb -uvestacos_cutella -p"$(grep '^CUTELLA_DB_PASSWORD=' /srv/vestacutella/.env | cut -d= -f2-)" vestacos_cutella -N -e "SELECT option_value FROM wp_options WHERE option_name='active_plugins';" 2>/dev/null | php -r '
$s=stream_get_contents(STDIN);
$v=@unserialize($s);
if (is_array($v)) foreach($v as $p) echo $p,"\n";
' 2>/dev/null || true

rm -f "$MU"
echo "CUTELLA_ADMIN_DIAGNOSTIC_DONE"
