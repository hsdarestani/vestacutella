#!/usr/bin/env bash
set -euo pipefail
BASE=/srv/vestacutella
RUNTIME="$BASE/runtime/vesta"
ENVFILE="$BASE/.env"
STAMP="$(date -u +%Y%m%d%H%M%S)"
STAGE="/srv/vestacutella/vesta-login-diagnostic-$STAMP"
DB="vestacos_login_test_$STAMP"
CT="vc-vesta-login-test-$STAMP"
mkdir -m 700 -p "$STAGE"
set -a
source "$ENVFILE"
set +a
cleanup() {
  docker rm -f "$CT" >/dev/null 2>&1 || true
  docker exec vc-db-vesta mariadb -uroot -p"$VESTA_DB_ROOT_PASSWORD" -e "DROP DATABASE IF EXISTS \`$DB\`; REVOKE ALL PRIVILEGES ON \`$DB\`.* FROM 'vestacos_m'@'%'; FLUSH PRIVILEGES;" >/dev/null 2>&1 || true
  rm -rf "$STAGE"
}
trap cleanup EXIT
echo '=== Create isolated minimal WordPress database (schema, options and page data, no orders) ==='
docker exec vc-db-vesta mariadb -uroot -p"$VESTA_DB_ROOT_PASSWORD" -e "CREATE DATABASE \`$DB\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; GRANT ALL PRIVILEGES ON \`$DB\`.* TO 'vestacos_m'@'%'; FLUSH PRIVILEGES;"
docker exec vc-db-vesta mariadb-dump -uroot -p"$VESTA_DB_ROOT_PASSWORD" --single-transaction --no-data --skip-triggers --skip-comments vestacos_m | docker exec -i vc-db-vesta mariadb -uroot -p"$VESTA_DB_ROOT_PASSWORD" "$DB"
docker exec vc-db-vesta mariadb -uroot -p"$VESTA_DB_ROOT_PASSWORD" -e "INSERT INTO \`$DB\`.wp_options SELECT * FROM vestacos_m.wp_options; INSERT INTO \`$DB\`.wp_posts SELECT * FROM vestacos_m.wp_posts WHERE post_type IN ('page','wp_template','wp_template_part'); INSERT INTO \`$DB\`.wp_postmeta SELECT pm.* FROM vestacos_m.wp_postmeta pm INNER JOIN \`$DB\`.wp_posts p ON p.ID=pm.post_id;"
echo '=== Build PHP-safe isolated wp-config (never change production config) ==='
cp "$RUNTIME/wp-config.php" "$STAGE/wp-config.php"
python3 - "$STAGE/wp-config.php" "$DB" <<'PY'
import re,sys
p,db=sys.argv[1:]
s=open(p).read()
pattern=r"""(define\s*\(\s*['"]DB_NAME['"]\s*,\s*)['"][^'"]+['"](\s*\)\s*;)"""
s,n=re.subn(pattern,lambda m:m.group(1)+"'"+db+"'"+m.group(2),s,count=1)
if n!=1: raise SystemExit("DB_NAME replacement failed: stage aborted")
hook="""@ini_set('log_errors','1');
@ini_set('error_log','/tmp/vesta-staging-php-errors.log');
@ini_set('display_errors','0');
if (!defined('DISABLE_WP_CRON')) define('DISABLE_WP_CRON', true);
$_SERVER['HTTPS'] = 'on';
register_shutdown_function(function() {
  $e=error_get_last();
  if ($e && in_array($e['type'], array(E_ERROR,E_PARSE,E_CORE_ERROR,E_COMPILE_ERROR,E_USER_ERROR), true))
    @file_put_contents('/tmp/vesta-staging-fatal.json', json_encode(array('type'=>$e['type'],'message'=>$e['message'],'file'=>$e['file'],'line'=>$e['line'])));
});
"""
s,n=re.subn(r"(?=require_once\s+ABSPATH\s*\.\s*['\"]wp-settings\.php['\"]\s*;)", lambda m:hook, s,count=1)
if n!=1: raise SystemExit("wp-settings insertion anchor missing: stage aborted")
open(p,"w").write(s)
PY
chmod 600 "$STAGE/wp-config.php"
IMAGE="$(docker inspect vc-vesta -f '{{.Config.Image}}')"
NET="$(docker inspect vc-vesta -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}')"
echo "image=$IMAGE network=$NET"
docker run --rm --entrypoint php -v "$STAGE/wp-config.php:/tmp/test-wp-config.php:ro" "$IMAGE" -l /tmp/test-wp-config.php
echo '=== Start isolated site. Production WordPress files mounted read-only ==='
docker run -d --name "$CT" --network "$NET" -p 127.0.0.1:18087:80 --memory 1000m \
  -v "$RUNTIME:/var/www/html:ro" \
  -v "$STAGE/wp-config.php:/var/www/html/wp-config.php:ro" \
  -v "$RUNTIME/wp-content/plugins/smsir.disabled-for-migration:/var/www/html/wp-content/plugins/smsir:ro" \
  -v "$RUNTIME/wp-content/plugins/xcart.disabled-for-migration:/var/www/html/wp-content/plugins/xcart:ro" \
  "$IMAGE" >/dev/null
sleep 8
request() {
  local label="$1" path="$2"
  echo "=== $label ==="
  curl -sS --max-time 40 -H 'Host: vesta-cosmetics.ir' -H 'X-Forwarded-Proto: https' -o "$STAGE/response.html" -D "$STAGE/headers.txt" -w 'HTTP=%{http_code} seconds=%{time_total} bytes=%{size_download}\n' "http://127.0.0.1:18087$path" || true
  head -n 8 "$STAGE/headers.txt" | tr -d '\r' | grep -Ei 'HTTP/|location:|content-type:' || true
  grep -Eio 'smsir-login-app|login-app|ورود با کد|ورود با رمز|critical error|خطای مهم' "$STAGE/response.html" | sort -u | head -n 15 || true
  docker exec "$CT" sh -lc 'if [ -f /tmp/vesta-staging-fatal.json ]; then cat /tmp/vesta-staging-fatal.json; else echo no_shutdown_fatal; fi; if [ -f /tmp/vesta-staging-php-errors.log ]; then grep -E "PHP (Fatal|Parse)|Uncaught|ionCube" /tmp/vesta-staging-php-errors.log | tail -n 7 | cut -c1-260 || true; fi'
}
echo '=== Stage activation state ==='
docker exec "$CT" php -r 'require "/var/www/html/wp-load.php"; require_once ABSPATH."wp-admin/includes/plugin.php"; foreach(["smsir/index.php","xcart/xcart.php"] as $p) echo "$p=".(is_plugin_active($p)?"active":"inactive").PHP_EOL;' || true
request "isolated SMS.ir account flow" "/my-account/"
echo '=== Stage XCart activation (sandbox DB only) ==='
docker exec "$CT" php -r 'require "/var/www/html/wp-load.php"; require_once ABSPATH."wp-admin/includes/plugin.php"; $r=activate_plugin("xcart/xcart.php","",false,true); if(is_wp_error($r)){fwrite(STDERR,$r->get_error_message().PHP_EOL);exit(2);} echo "xcart_stage_active=". (is_plugin_active("xcart/xcart.php")?"yes":"no").PHP_EOL;' 2>&1 | head -n 10 || true
request "isolated SMS.ir + XCart account flow" "/my-account/"
echo '=== Sanitized staging PHP runtime error lines ==='
docker logs --tail 50 "$CT" 2>&1 | grep -Ei 'PHP (Fatal|Parse)|Uncaught|ionCube|GET /my-account' | cut -c1-260 | tail -n 14 || true
echo '=== Live remains unchanged ==='
for p in / /my-account/ /shop/; do
 curl -ksS --max-time 20 --resolve vesta-cosmetics.ir:443:127.0.0.1 -o /dev/null -w "$p live_http=%{http_code}\n" "https://vesta-cosmetics.ir$p" || true
done
echo VESTA_ISOLATED_LOGIN_TEST_DONE
