#!/usr/bin/env bash
# Fix only outgoing Bazara order payload. Backup, strict preflight, source diff check, PHP syntax, Woo price parity, health.
# Does NOT alter prior sent ERP orders, site product prices, order statuses or stock.
set -Eeuo pipefail
umask 077
target=/srv/vestacutella/runtime/vesta/wp-content/plugins/bazara/classes/class.bazara.api.php
exec 9>/run/lock/vesta-bazara-financial-payload-deploy.lock
flock -n 9 || { echo DEPLOY_BUSY;exit 10; }
test -s "$target"
backup=/srv/backups/vesta-bazara-financial-payload-$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p -m 0700 "$backup"
cp -p "$target" "$backup/class.bazara.api.php"
echo "PLUGIN_BACKUP=$backup/class.bazara.api.php"
changed=0
complete=0
on_exit(){
 status=$?
 trap - EXIT
 if [[ "$complete" != 1 && "$changed" == 1 ]];then
   cp -p "$backup/class.bazara.api.php" "$target"
   echo "FINANCIAL_PATCH_ROLLED_BACK=yes EXIT=$status"
 fi
 exit "$status"
}
trap on_exit EXIT
test "$(docker inspect -f '{{.State.Running}}' vc-vesta)" = true

# Required code and settings exact preflight.
docker exec -i vc-vesta php -d display_errors=0 -d memory_limit=256M <<'PHP'
<?php
$_SERVER['HTTP_HOST']='vesta-cosmetics.ir';$_SERVER['SERVER_NAME']='vesta-cosmetics.ir';
$_SERVER['HTTPS']='on';$_SERVER['SERVER_PORT']='443';$_SERVER['REQUEST_URI']='/';
require '/var/www/html/wp-load.php';
$s=get_option('bazara_visitor_settings',[]);
if(get_woocommerce_currency()!=='IRT'||($s['selectCurrencySoftware']??'')!=='toman'||
   ($s['selectCurrencyPlugin']??'')!=='toman'){
 echo "FINANCIAL_PATCH_UNEXPECTED_CURRENCY_SETTINGS\n";exit(22);
}
echo "CURRENCY_PREFLIGHT=IRT_TO_RIAL_OUTBOUND_PREVIOUS_PATCH\n";
PHP

# Hash price and order options (read-only data) to guarantee no changes after deploy.
before=$(docker exec -i vc-db-vesta sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb -uroot -D "$MARIADB_DATABASE" --batch --raw' <<'SQL'
SELECT SHA2(GROUP_CONCAT(CONCAT(post_id,':',meta_key,':',meta_value) ORDER BY post_id,meta_key SEPARATOR ';'),256)
FROM wp_postmeta WHERE post_id IN(105052,105225,105317,105316,105313,105228,102250,42807)
AND meta_key IN('_price','_regular_price','_sale_price','_order_total','_order_shipping');
SQL
)
echo "FINANCIAL_SNAPSHOT_PREPARED=yes"

TARGET="$target" python3 - <<'PY'
from pathlib import Path
import os,re,stat,tempfile
p=Path(os.environ['TARGET'])
raw=p.read_bytes()
s=raw.decode('utf-8')
marker='VC_BAZARA_FINANCIAL_PAYLOAD_V1_20261112'
if marker in s:
  print('FINANCIAL_PAYLOAD_PATCH_ALREADY_INSTALLED=yes')
  raise SystemExit(0)
if 'VC_BAZARA_OUTBOUND_RIAL_ONLY_20261110' not in s:
  raise SystemExit('MISSING_PREVIOUS_CURRENCY_PATCH')
a=s.index('public function bazara_save_order(')
b=s.index('    private function get_selected_bank_id(',a)
head,part,tail=s[:a],s[a:b],s[b:]
original=part

def once(old,new,name):
 global part
 n=part.count(old)
 if n!=1:raise SystemExit('ABORT_PATTERN_'+name+'_COUNT_'+str(n))
 part=part.replace(old,new,1)

# Coupon total should be applied exactly once, at the line item, from immutable order values.
once(
"""        $db_item_discount = get_order_item_discount($order_id);
        $total_discount = isset($db_item_discount->discount) ? (float)$db_item_discount->discount : 0;""",
"""        // VC_BAZARA_FINANCIAL_PAYLOAD_V1_20261112
        // Woo order item discount is applied once to each ERP orderDetail; never again to order header.
        $total_discount = 0;""",
'HEADER_DISCOUNT')

once(
"""            $total_row_discount = 0;

            $unit_price = $item->get_subtotal() / $quantity;

            if ($product->get_sale_price() > 0 && !$role_base && !class_exists('wholeSalePermium')) {
                $unit_price = $product->get_regular_price();
                $total_row_discount = ($product->get_regular_price() - $product->get_sale_price()) * $quantity;
                $total_discount += $total_row_discount;
            }""",
"""            // Invoice uses immutable Woo order item values. Current catalog prices may have changed.
            if ((float)$quantity <= 0) {
                return array('success' => false, 'message' => 'Invalid quantity in Woo order');
            }
            $unit_price = (float)$item->get_subtotal() / (float)$quantity;
            $total_row_discount = max(0, (float)$item->get_subtotal() - (float)$item->get_total());""",
'LINE_PRICE_AND_DISCOUNT')

once(
"""        if ($sendShipping) {
            $shippingPerson = $this->get_selected_shipping_person_id($ShippingMethod);""",
"""        // Always send customer-paid shipping as a separate ERP freight amount.
        // A configured carrier may additionally attach carrier metadata; it must not gate the amount.
        if ((float)$order_shipping_cost > 0) {
            $product_orders['orders']['sendCost'] = round((float)$order_shipping_cost, 2);
        }
        if ($sendShipping) {
            $shippingPerson = $this->get_selected_shipping_person_id($ShippingMethod);""",
'UNCONDITIONAL_SHIPPING_AMOUNT')

once(
"""        $description = $order->get_customer_note();
        if (empty($description)) {
            $description = $order->get_meta( 'info' );
        }""",
"""        $description = $order->get_customer_note();
        if (empty($description)) {
            $description = $order->get_meta( 'info' );
        }
        // Visible and searchable payment source on the received ERP order (not a cash settlement claim).
        $vc_gateway_labels = array(
            'WC_Gateway_SnappPay' => 'اسنپ پی (اقساطی)',
            'WC_Gateway_TorobPay' => 'ترب پی (اقساطی)',
            'WCDigiPay' => 'دیجی پی (اقساطی)',
            'shopino' => 'شاپینو',
            'wc_zibal' => 'زیبال',
            'pcs_smart_cardpay' => 'کارت به کارت',
        );
        $vc_payment_method = (string)$order->get_payment_method();
        $vc_gateway_label = isset($vc_gateway_labels[$vc_payment_method])
            ? $vc_gateway_labels[$vc_payment_method] : $vc_payment_method;
        if ($vc_gateway_label !== '') {
            $description = trim((string)$description);
            $description .= ($description !== '' ? ' | ' : '') . 'درگاه سایت: ' . $vc_gateway_label;
        }""",
'PAYMENT_GATEWAY_LABEL')

# Financial invariant guard before calling SetAll; no ERP submission if Woo total does not reconcile.
# Same SetAll call also exists in wallet top-up path. Guard only the final regular Woo order call.
vc_set_all_call = """        $result = $this->set_all_data($token, $data);"""
vc_guarded_call = """        // Financial invariant: do not send a document whose line items do not sum to Woo total.
        // Tax and fee handling is not implemented by the vendor plugin; reject such exceptional orders.
        $vc_expected_irt = (float)$order->get_total();
        $vc_item_sum_irt = 0.0;
        foreach ($order->get_items('line_item') as $vc_line) {
            $vc_item_sum_irt += (float)$vc_line->get_total();
        }
        $vc_has_fee = count($order->get_items('fee')) > 0;
        if (abs((float)$order->get_total_tax()) > 0.01 || $vc_has_fee ||
            abs($vc_expected_irt - ($vc_item_sum_irt + (float)$order->get_shipping_total())) > 0.51) {
            return array('success' => false,
                'message' => 'Bazara financial guard: nonreconciling tax, fee, or order totals');
        }
        $result = $this->set_all_data($token, $data);"""
if part.count(vc_set_all_call)!=2:
  raise SystemExit('ABORT_UNEXPECTED_SET_ALL_CALL_COUNT_'+str(part.count(vc_set_all_call)))
i=part.rfind(vc_set_all_call)
part=part[:i]+vc_guarded_call+part[i+len(vc_set_all_call):]

if original==part:raise SystemExit('NO_SOURCE_CHANGES')
next_content=(head+part+tail).encode()
st=p.stat()
with tempfile.NamedTemporaryFile(prefix='.bazara-finance-',dir=p.parent,delete=False) as f:
 tmp=Path(f.name)
 f.write(next_content);f.flush();os.fsync(f.fileno())
os.chmod(tmp,stat.S_IMODE(st.st_mode));os.chown(tmp,st.st_uid,st.st_gid);os.replace(tmp,p)
print('FINANCIAL_OUTBOUND_SOURCE_PATCH_APPLIED=yes')
print('PATCH_SECTIONS=HEADER_DISCOUNT,LINE_PRICE_AND_DISCOUNT,UNCONDITIONAL_SHIPPING_AMOUNT,PAYMENT_GATEWAY_LABEL,FINANCIAL_PARITY_GUARD')
PY
changed=1
docker exec vc-vesta php -l /var/www/html/wp-content/plugins/bazara/classes/class.bazara.api.php
grep -Fq VC_BAZARA_FINANCIAL_PAYLOAD_V1_20261112 "$target"
grep -Fq VC_BAZARA_OUTBOUND_RIAL_ONLY_20261110 "$target"
after=$(docker exec -i vc-db-vesta sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb -uroot -D "$MARIADB_DATABASE" --batch --raw' <<'SQL'
SELECT SHA2(GROUP_CONCAT(CONCAT(post_id,':',meta_key,':',meta_value) ORDER BY post_id,meta_key SEPARATOR ';'),256)
FROM wp_postmeta WHERE post_id IN(105052,105225,105317,105316,105313,105228,102250,42807)
AND meta_key IN('_price','_regular_price','_sale_price','_order_total','_order_shipping');
SQL
)
if [[ "$before" != "$after" ]];then echo ORDER_OR_PRICE_DATA_CHANGED_ABORT=yes;exit 24;fi
echo "STOREFRONT_PRICES_AND_EXISTING_ORDER_TOTALS_UNCHANGED=yes"
for host in vesta-cosmetics.ir cutellashop.ir app.vesta-cosmetics.ir;do
 code=$(curl --noproxy '*' -ksS --connect-timeout 8 --max-time 25 --resolve "$host:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$host/")
 echo "HOST=$host HTTP=$code"
 test "$code" = 200
done
complete=1
trap - EXIT
echo "BAZARA_FINANCE_OUTBOUND_DEPLOY_SUCCESS=yes"
echo "NO_ORDER_REPLAYS_OR_ERP_WRITES_IN_DEPLOY=yes"
