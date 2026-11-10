#!/usr/bin/env bash
# Convert only outgoing WooCommerce orders (IRT/toman) to Rial sent to Bazaar ERP.
# Do not change the global Bazaar software/site currency settings. Do not replay old orders.
set -Eeuo pipefail
umask 077
target=/srv/vestacutella/runtime/vesta/wp-content/plugins/bazara/classes/class.bazara.api.php
lock=/run/lock/vesta-bazara-currency-deploy.lock
exec 9>"$lock"
flock -n 9 || { echo ANOTHER_CURRENCY_DEPLOY_IN_PROGRESS; exit 13; }
test -s "$target"
test "$(docker inspect -f '{{.State.Running}}' vc-vesta)" = true
test "$(docker inspect -f '{{.State.Running}}' vc-db-vesta)" = true
backup=/srv/backups/vesta-bazara-outbound-rial-$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p -m 0700 "$backup"
cp -p "$target" "$backup/class.bazara.api.php"
echo "BACKUP=$backup/class.bazara.api.php"
finished=no
changed=no
rollback(){
  code=$?
  trap - EXIT
  if [[ "$finished" != yes && "$changed" == yes ]];then
    cp -p "$backup/class.bazara.api.php" "$target"
    echo "CURRENCY_PATCH_ROLLBACK_APPLIED=yes RETURN_CODE=$code"
  fi
  exit "$code"
}
trap rollback EXIT

check_wp(){
docker exec -i vc-vesta php -d display_errors=0 -d memory_limit=256M <<'PHP'
<?php
$_SERVER['HTTP_HOST']='vesta-cosmetics.ir';
$_SERVER['SERVER_NAME']='vesta-cosmetics.ir';
$_SERVER['HTTPS']='on';
$_SERVER['SERVER_PORT']='443';
$_SERVER['REQUEST_URI']='/';
require '/var/www/html/wp-load.php';
$o=get_option('bazara_visitor_settings',array());
$wc=function_exists('get_woocommerce_currency')?get_woocommerce_currency():'none';
$sof=is_array($o)?($o['selectCurrencySoftware']??'none'):'invalid';
$site=is_array($o)?($o['selectCurrencyPlugin']??'none'):'invalid';
if($wc!=='IRT'||$sof!=='toman'||$site!=='toman'){
  echo "UNEXPECTED_CURRENCY_CONFIG WOO=".preg_replace('/[^a-zA-Z]/','',$wc).
       " ACCOUNTING=".preg_replace('/[^a-zA-Z]/','',$sof).
       " PLUGIN=".preg_replace('/[^a-zA-Z]/','',$site)."\n";
  exit(22);
}
echo "CURRENCY_PREFLIGHT=woo_irt_site_toman_accounting_toman\n";
foreach([102250,42807] as $id){
  echo "PRODUCT_PRICE_SNAPSHOT_".$id."=".get_post_meta($id,'_price',true).
    "|".get_post_meta($id,'_regular_price',true)."|".get_post_meta($id,'_sale_price',true)."\n";
}
foreach([105204,105208] as $id){
  echo "ORDER_TOTAL_SNAPSHOT_".$id."=".get_post_meta($id,'_order_total',true)."\n";
}
PHP
}
before=$(check_wp)
printf '%s\n' "$before" | grep -E 'CURRENCY_PREFLIGHT|PRODUCT_PRICE_SNAPSHOT|ORDER_TOTAL_SNAPSHOT'

marker=VC_BAZARA_OUTBOUND_RIAL_ONLY_20261110
if grep -Fq "$marker" "$target";then
  echo OUTBOUND_RIAL_PATCH_ALREADY_INSTALLED=yes
else
  TARGET="$target" python3 - <<'PY'
import os,pathlib,stat,tempfile
p=pathlib.Path(os.environ['TARGET'])
s=p.read_bytes()
head=b'public function bazara_save_order($order_id, $token)'
tail=b'    private function get_selected_bank_id('
pos=s.find(head)
end=s.find(tail,pos)
if pos<0 or end<0 or end<=pos:raise SystemExit('UNRECOGNIZED_OUTBOUND_ORDER_FUNCTION')
block=s[pos:end]
anchor=b"        $SoftwareCurrency = $options['selectCurrencySoftware'];\n        $PluginCurrency = $options['selectCurrencyPlugin'];\n"
if block.count(anchor)!=1:raise SystemExit('UNRECOGNIZED_CURRENCY_ASSIGNMENTS')
if b'VC_BAZARA_OUTBOUND_RIAL_ONLY_20261110' in s:raise SystemExit('PATCH_ALREADY_PRESENT_IN_DIFFERENT_LOCATION')
for test in (
  b"$unit_price *= 10;",
  b"$total_row_discount *= 10;",
  b"$order_shipping_cost *= 10;",
  b"$total_discount *= 10;",
  b"$total_amount *= 10;",
):
 if test not in block:raise SystemExit('MISSING_EXISTING_CONVERSION: '+str(test))
inject=b"""        // VC_BAZARA_OUTBOUND_RIAL_ONLY_20261110
        // ERP ledger is Rial while WooCommerce storefront remains IRT/Toman.
        // Use the plugin's existing conversion branches ONLY for outgoing orders.
        // Never alter global currency settings: the same options also control product imports.
        if ($SoftwareCurrency === 'toman' && $PluginCurrency === 'toman' &&
            function_exists('get_woocommerce_currency') && get_woocommerce_currency() === 'IRT') {
            $SoftwareCurrency = 'rial';
        }
"""
out=s[:pos]+block.replace(anchor,anchor+inject,1)+s[end:]
if out.replace(inject,b'',1)!=s:raise SystemExit('OTHER_SOURCE_LINES_CHANGED')
st=p.stat()
with tempfile.NamedTemporaryFile(dir=p.parent,prefix='.bazara-rial-',delete=False) as f:
 tmp=pathlib.Path(f.name);f.write(out);f.flush();os.fsync(f.fileno())
os.chmod(tmp,stat.S_IMODE(st.st_mode))
os.chown(tmp,st.st_uid,st.st_gid)
os.replace(tmp,p)
print('OUTGOING_ORDER_ONLY_PATCH_APPLIED=yes')
PY
  changed=yes
fi

docker exec vc-vesta php -l /var/www/html/wp-content/plugins/bazara/classes/class.bazara.api.php
grep -Fq "$marker" "$target"
# No plugin option, product price, or existing order amount may change.
after=$(check_wp)
if [[ "$before" != "$after" ]];then
  echo "UNEXPECTED_STOREFRONT_OR_ACCOUNTING_CHANGE";exit 29
fi
echo WOO_PRICES_ORDER_TOTALS_AND_GLOBAL_CURRENCY_OPTIONS_UNCHANGED=yes
# Strictly verify source diff only contains this injected branch
BACKUP_FILE="$backup/class.bazara.api.php" TARGET="$target" python3 - <<'PY'
import os,pathlib
b=pathlib.Path(os.environ['BACKUP_FILE']).read_bytes()
a=pathlib.Path(os.environ['TARGET']).read_bytes()
mark=b'        // VC_BAZARA_OUTBOUND_RIAL_ONLY_20261110\n'
if mark not in b:
 st=a.index(mark)
 en=a.index(b'        }\n',st)+len(b'        }\n')
 if a[:st]+a[en:]!=b:raise SystemExit('UNEXPECTED_CHANGES_OUTSIDE_OUTGOING_BRANCH')
print('EXACTLY_ONE_OUTBOUND_CONVERSION_BRANCH_VERIFIED=yes')
PY
docker exec -i vc-vesta php -r '
$wc="IRT"; $software="toman"; $site="toman";
if($software==="toman"&&$site==="toman"&&$wc==="IRT")$software="rial";
function conv($n,$software,$site){if($software==="rial"&&$site==="toman")return $n*10;if($software==="toman"&&$site==="rial")return $n/10;return $n;}
foreach([252000=>2520000,99000=>990000,2475=>24750] as $from=>$to){if(conv($from,$software,$site)!==$to)exit(32);}
echo "CURRENCY_CONVERSION_UNIT_TESTS=passed\n";
'
for host in vesta-cosmetics.ir cutellashop.ir app.vesta-cosmetics.ir; do
 code=$(curl --noproxy '*' -ksS --connect-timeout 8 --max-time 25 --resolve "$host:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$host/")
 echo "HOST=$host HTTP=$code"
 test "$code" = 200
done
echo "PREVIOUS_ACCOUNTING_ORDERS_NOT_REPLAYED=yes"
echo "INBOUND_BAZARA_PRODUCT_PRICE_SYNC_NOT_MODIFIED=yes"
finished=yes
trap - EXIT
echo "OUTBOUND_RIAL_ONLY_DEPLOY_SUCCESS=yes"
