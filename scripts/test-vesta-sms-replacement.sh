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
echo '=== Create isolated WP database for SMS OTP replacement test ==='
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
echo '=== Build isolated plugin directory using hardlinks (no writes to source files) ==='
cp -al "$RUNTIME/wp-content/plugins" "$STAGE/plugins"
# Keep legacy ionCube files under their disabled names to prevent PHP fatals.
mkdir -p "$STAGE/plugins/vesta-sms-login"
cp /tmp/vesta-sms-login.php "$STAGE/plugins/vesta-sms-login/vesta-sms-login.php"
echo '=== Start isolated site. Production WordPress files mounted read-only ==='
docker run -d --name "$CT" --network "$NET" -p 127.0.0.1:18087:80 --memory 1000m \
  -v "$RUNTIME:/var/www/html:ro" \
  -v "$STAGE/wp-config.php:/var/www/html/wp-config.php:ro" \
  -v "$STAGE/plugins:/var/www/html/wp-content/plugins:ro" \
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
echo '=== Activate replacement only in staging DB ==='
docker exec "$CT" php -l /var/www/html/wp-content/plugins/vesta-sms-login/vesta-sms-login.php
docker exec "$CT" php -r '
require "/var/www/html/wp-load.php";
require_once ABSPATH."wp-admin/includes/plugin.php";
$r=activate_plugin("vesta-sms-login/vesta-sms-login.php","",false,true);
if (is_wp_error($r)) { echo "activate_failed"; exit(2); }
echo "replacement_active=".(is_plugin_active("vesta-sms-login/vesta-sms-login.php")?"yes":"no").PHP_EOL;
echo "gateway_ready=".(function_exists("vesta_otp_ready") && vesta_otp_ready()?"yes":"no").PHP_EOL;
'
echo '=== Browser flow smoke ==='
curl -sS --max-time 40 -H 'Host: vesta-cosmetics.ir' -o "$STAGE/page.html" -D "$STAGE/headers.txt" -w 'staging_account_http=%{http_code} bytes=%{size_download}\n' http://127.0.0.1:18087/my-account/
grep -q 'vesta-otp-login' "$STAGE/page.html" && echo "OTP_FORM_VISIBLE" || { echo "OTP_FORM_MISSING"; exit 41; }
echo '=== Test OTP send using in-process mocked SMS.ir HTTP response, no real SMS ==='
cat > "$STAGE/send.php" <<'PHP'
<?php
require "/var/www/html/wp-load.php";
add_filter('pre_http_request',function($unused,$args,$url) {
 if($url!=='https://api.sms.ir/v1/send/verify') return $unused;
 $req=json_decode($args['body'],true);
 if(empty($req['parameters'][0]['value'])) return new WP_Error('test_error','no code');
 file_put_contents('/tmp/vesta-mock-otp', $req['parameters'][0]['value']);
 return array('headers'=>array(),'body'=>'{"status":1,"message":"test"}','response'=>array('code'=>200,'message'=>'OK'),'cookies'=>array());
},10,3);
$_POST=array('phone'=>'09120000000','nonce'=>wp_create_nonce('vesta_otp_login'));
$_REQUEST=$_POST;
vesta_otp_send();
PHP
docker exec -i "$CT" php < "$STAGE/send.php" > "$STAGE/send.json" 2> "$STAGE/send.err" || { tail -n 5 "$STAGE/send.err"; exit 42; }
TOKEN="$(python3 - "$STAGE/send.json" <<'PY'
import json,sys
s=open(sys.argv[1]).read()
try:
 o=json.loads(s)
 assert o.get('success')
 print(o['data']['token'])
except Exception as exc:
 print('invalid mock send response',s[:180],file=sys.stderr)
 raise
PY
)"
echo MOCK_SEND_OK
CODE="$(docker exec "$CT" cat /tmp/vesta-mock-otp)"
echo '=== Test OTP verification and customer creation in isolated DB ==='
cat > "$STAGE/verify.php" <<'PHP'
<?php
require "/var/www/html/wp-load.php";
$_POST=array('phone'=>'09120000000','nonce'=>wp_create_nonce('vesta_otp_login'),'token'=>getenv('TOKEN'),'code'=>getenv('CODE'));
$_REQUEST=$_POST;
vesta_otp_verify();
PHP
docker exec -e TOKEN="$TOKEN" -e CODE="$CODE" -i "$CT" php < "$STAGE/verify.php" > "$STAGE/verify.json" 2> "$STAGE/verify.err" || { tail -n 5 "$STAGE/verify.err"; exit 43; }
python3 - "$STAGE/verify.json" <<'PY'
import json,sys
s=open(sys.argv[1]).read()
try:
 o=json.loads(s); assert o.get("success"); print("MOCK_VERIFY_AND_REGISTER_OK")
except Exception:
 print("mock verify failed",s[:180],file=sys.stderr); raise
PY
docker exec "$CT" php -r '
require "/var/www/html/wp-load.php";
$u=vesta_otp_existing_user("09120000000");
if (!$u || is_wp_error($u)) exit(31);
$x=get_user_by("id",$u);
if (!$x || !in_array("customer",(array)$x->roles,true)) exit(32);
echo "CUSTOMER_PHONE_LINK_OK\n";
'
echo '=== Sanitized staging PHP fatal report ==='
docker exec "$CT" sh -lc 'test ! -f /tmp/vesta-staging-fatal.json || cat /tmp/vesta-staging-fatal.json' || true
echo STAGING_SMSIR_REPLACEMENT_TEST_PASSED
echo '=== Live remains unchanged ==='
for p in / /my-account/ /shop/; do
 curl -ksS --max-time 20 --resolve vesta-cosmetics.ir:443:127.0.0.1 -o /dev/null -w "$p live_http=%{http_code}\n" "https://vesta-cosmetics.ir$p" || true
done
echo VESTA_SMS_REPLACEMENT_SANDBOX_OK
