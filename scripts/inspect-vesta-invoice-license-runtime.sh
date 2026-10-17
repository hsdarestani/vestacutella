#!/usr/bin/env bash
# Safe read-only diagnosis of intermittent WooCommerce invoice licence validation.
# NEVER print license values, raw remote responses, customer records, auth headers or API tokens.
set -euo pipefail
ROOT=/srv/vestacutella/runtime/vesta
PLUG="$ROOT/wp-content/plugins/woocommerce-invoice-pro1"
test -d "$PLUG"
echo '=== Clock ==='
date -u '+host_utc=%Y-%m-%dT%H:%M:%SZ epoch=%s'
docker exec vc-vesta php -r 'echo "php_utc=".gmdate("c")." php_epoch=".time()." TZ=".date_default_timezone_get().PHP_EOL;'
echo '=== Plugin files and entry metadata ==='
find "$PLUG" -maxdepth 3 -type f \( -name '*.php' -o -name '*.inc' \) -printf '%P bytes=%s\n' | head -90
docker exec vc-vesta php -r '
require "/var/www/html/wp-load.php";
$p="/var/www/html/wp-content/plugins/woocommerce-invoice-pro1/woocommerce-invoice-pro.php";
require_once ABSPATH."wp-admin/includes/plugin.php";
$info=get_plugin_data($p,false,false);
foreach (array("Name","Version","Author","PluginURI") as $k) {
 $v=isset($info[$k])?(string)$info[$k]:"";
 // Avoid URLs and any string likely to include an embedded credential.
 if ($k==="PluginURI") { $v=parse_url($v,PHP_URL_HOST) ?: "(unknown)"; }
 echo $k."=".$v.PHP_EOL;
}
echo "wp_timezone=".wp_timezone_string().PHP_EOL;
echo "wp_cron_enabled=".(defined("DISABLE_WP_CRON") && DISABLE_WP_CRON ? "no":"yes").PHP_EOL;
echo "external_http_blocked=".(defined("WP_HTTP_BLOCK_EXTERNAL") && WP_HTTP_BLOCK_EXTERNAL ? "yes":"no").PHP_EOL;
echo "external_object_cache=".(wp_using_ext_object_cache()?"yes":"no").PHP_EOL;
'
echo '=== Source locations and sanitized logic related to licensing ==='
PLUG="$PLUG" python3 - <<'PY'
import os,re
base=os.environ['PLUG']
terms=re.compile(r'license|licence|validat|activat|expire|domain|repair|refresh|cron|transient|update_option|delete_option|set_transient|wp_remote_|wp_safe_remote_|wp_schedule_|wp_clear_scheduled_|wp_http_validate_url|server_time',re.I)
shown=0
for root,ds,fs in os.walk(base):
    ds[:]=[d for d in ds if d not in ('vendor','assets','languages','node_modules','js','css')]
    for f in fs:
        if not f.lower().endswith(('.php','.inc')): continue
        fn=os.path.join(root,f)
        if os.stat(fn).st_size>1500000: continue
        try: lines=open(fn,encoding='utf-8',errors='ignore').read().splitlines()
        except Exception: continue
        for n,line in enumerate(lines,1):
            if len(line)>800 or not terms.search(line): continue
            # Sanitize ALL quoted strings and literal URLs to avoid exposing licence codes,
            # tokens or third-party source text. Preserve structure only.
            safe=re.sub(r'("(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\')','"[redacted]"',line)
            safe=re.sub(r'https?://\S+','[url]',safe)
            safe=safe.strip()[:230]
            if safe and shown<170:
                print(os.path.relpath(fn,base)+':'+str(n)+': '+safe)
                shown+=1
print('SOURCE_MATCH_COUNT_SHOWN='+str(shown))
PY
echo '=== Option names, lengths and safe value types ==='
docker exec vc-vesta php -d display_errors=stderr -r '
require "/var/www/html/wp-load.php";
global $wpdb;
$names=$wpdb->get_col("SELECT option_name FROM {$wpdb->options} WHERE option_name LIKE \\'%invoice%\\' OR option_name LIKE \\'%pws%\\' OR option_name LIKE \\'%factor%\\' OR option_name LIKE \\'%license%\\' OR option_name LIKE \\'%licence%\\'");
foreach ($names as $name) {
 $n=(string)$name;
 if (preg_match("/[A-Fa-f0-9]{16,}/",$n)) continue;
 $v=get_option($n);
 $type=gettype($v);
 $len=is_scalar($v)?strlen((string)$v):0;
 echo "option=".$n." value_type=".$type." size=".$len.PHP_EOL;
}
$cron=get_option("cron", array());
foreach ($cron as $ts=>$entries) {
 if(!is_numeric($ts)||!is_array($entries)) continue;
 foreach(array_keys($entries) as $hook)
   if(preg_match("/invoice|license|pws|factor|activat|validate/i",$hook))
      echo "cron_hook=".$hook." next_utc=".gmdate("c",(int)$ts).PHP_EOL;
}
' 2>&1 | head -135
echo '=== PHP error evidence (exclude request query strings) ==='
docker logs --since 18h vc-vesta 2>&1 |
  grep -Ei 'invoice-pro|license|licence|ssl|curl error|timed out' |
  sed -E 's/[?][^ ]+/[query-redacted]/g' | tail -35 || true
echo 'VESTA_INVOICE_RUNTIME_DIAGNOSTIC_COMPLETE'
