#!/usr/bin/env bash
set -euo pipefail
ROOT=/srv/vestacutella/runtime/vesta
echo '=== CURRENT LIVE STATUS (READ ONLY) ==='
docker exec vc-vesta php -r 'echo "PHP=".PHP_VERSION.PHP_EOL; echo "ionCube=".(extension_loaded("ionCube Loader")?"yes":"no").PHP_EOL;'
docker exec vc-vesta php -r '
require "/var/www/html/wp-load.php";
require_once ABSPATH."wp-admin/includes/plugin.php";
foreach (["smsir/index.php","xcart/xcart.php"] as $p) echo "$p=". (is_plugin_active($p)?"active":"inactive").PHP_EOL;
echo "signup=".get_option("woocommerce_enable_signup_and_login_from_checkout").PHP_EOL;
'
echo '=== PLUGIN DISK STATUS ==='
for p in smsir xcart; do
  for suffix in "" .disabled-for-migration; do
    f="$ROOT/wp-content/plugins/$p$suffix"
    if [[ -d "$f" ]]; then
      echo "$p$suffix: exists"
      find "$f" -maxdepth 2 -type f -name '*.php' | sed "s#^$f/##" | head -n 30
      for entry in index.php xcart.php; do
        [[ ! -f "$f/$entry" ]] || docker exec vc-vesta php -l "/var/www/html/wp-content/plugins/$p$suffix/$entry" 2>&1 | head -n 3 || true
      done
    fi
  done
done
echo '=== SELECTED PHP ERRORS ONLY (no stack dump, credentials or user records) ==='
python3 - "$ROOT/wp-content/debug.log" <<'PY'
import os,re,sys
p=sys.argv[1]
if not os.path.isfile(p):
  print("wordpress_debug_log=missing")
else:
  with open(p,encoding='utf-8',errors='replace') as f:
    f.seek(max(0,os.path.getsize(p)-300000))
    ls=f.readlines()
  pattern=re.compile(r'PHP (?:Fatal error|Parse error)|Uncaught|ionCube|Allowed memory size|Call to undefined|Failed opening required',re.I)
  matching=[x.strip() for x in ls if pattern.search(x) and ('12-Oct-2026' in x or '2026-10-12' in x)]
  print("today_fatal_lines=",len(matching))
  for x in matching[-24:]:
    x=re.sub(r'\b[\w.+-]+@[\w.-]+\.[a-zA-Z]{2,}\b','[email]',x)
    x=re.sub(r'\b\+?\d{10,15}\b','[number]',x)
    print(x[:300])
PY
echo '=== APACHE ERROR SUMMARY ==='
docker logs --since 2026-10-12T07:55:00Z vc-vesta 2>&1 | grep -Ei 'PHP (Fatal|Parse)|Uncaught|ionCube|AH[0-9]+|invalid command' | tail -n 25 | cut -c1-300 || true
echo '=== HEALTH CHECK ==='
for p in / /shop/ /my-account/ /checkout/; do
  curl -ksS --max-time 25 --resolve vesta-cosmetics.ir:443:127.0.0.1 -o /dev/null -w "$p http=%{http_code} seconds=%{time_total}\n" "https://vesta-cosmetics.ir$p" || true
done

echo '=== LEGACY SMS OPTIONS AND CUSTOMER PHONE META COUNTS (NAMES AND COUNTS ONLY) ==='
ENVFILE=/srv/vestacutella/.env
set -a
source "$ENVFILE"
set +a
docker exec vc-db-vesta mariadb -uroot -p"$VESTA_DB_ROOT_PASSWORD" -N vestacos_m -e "SELECT option_name FROM wp_options WHERE option_name REGEXP 'smsir|sms_ir|otp|phone|mobile|xcart' ORDER BY option_name LIMIT 90;" | head -n 90
docker exec vc-db-vesta mariadb -uroot -p"$VESTA_DB_ROOT_PASSWORD" -N vestacos_m -e "SELECT meta_key, COUNT(*) FROM wp_usermeta WHERE meta_key REGEXP 'smsir|sms_ir|otp|phone|mobile' GROUP BY meta_key ORDER BY COUNT(*) DESC LIMIT 30;" | head -n 30
echo '=== SMSIR_SETTINGS STRUCTURE (KEY NAMES AND VALUE TYPES ONLY) ==='
docker exec vc-vesta php -r '
require "/var/www/html/wp-load.php";
$o=get_option("smsir_settings");
if (!is_array($o)) {echo "settings_not_array\n";exit;}
foreach($o as $k=>$v) {
  if (is_scalar($v)) echo "$k=scalar_set_".(strlen((string)$v)>0?"yes":"no").PHP_EOL;
  elseif (is_array($v)) echo "$k=array_keys(".implode(",",array_slice(array_keys($v),0,30)).")".PHP_EOL;
  else echo "$k=other".PHP_EOL;
}
'
echo SETTINGS_STRUCTURE_COMPLETE

echo SMS_OPTIONS_METADATA_ONLY_DONE

echo VESTA_LOGIN_DIAGNOSTIC_COMPLETE
