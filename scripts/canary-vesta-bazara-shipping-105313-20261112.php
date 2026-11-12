<?php
// One genuinely paid unacknowledged Woo order, with cloud deduplication + the shared mutex.
// Never submit twice, never modify existing Woo order totals, taxes, or product mappings.
error_reporting(E_ERROR|E_PARSE);ini_set('display_errors','0');set_time_limit(0);
$_SERVER['HTTP_HOST']='vesta-cosmetics.ir';$_SERVER['SERVER_NAME']='vesta-cosmetics.ir';
$_SERVER['HTTPS']='on';$_SERVER['SERVER_PORT']='443';$_SERVER['REQUEST_URI']='/wp-cron.php';
require '/var/www/html/wp-load.php';
global $wpdb;
$id=105313;
$lock=fopen('/tmp/vesta-bazara-order-sync.lock','r');
if(!$lock){echo "CANARY_SHARED_LOCK_OPEN_FAILED=yes\n";exit(21);}
$locked=false;
for($x=0;$x<180;$x++){
 if(flock($lock,LOCK_EX|LOCK_NB)){$locked=true;break;}
 usleep(250000);
}
if(!$locked){echo "CANARY_SHARED_ORDER_LOCK_BUSY_NO_WRITES=yes\n";exit(21);}
echo "CANARY_EXCLUSIVE_ORDER_LOCK_ACQUIRED=yes\n";
$source=file_get_contents('/var/www/html/wp-content/plugins/bazara/classes/class.bazara.api.php');
if(strpos($source,'VC_BAZARA_FINANCIAL_PAYLOAD_V1_20261112')===false ||
 strpos($source,'VC_BAZARA_OUTBOUND_RIAL_ONLY_20261110')===false){
 echo "CURRENCY_OR_FINANCE_PATCH_NOT_PRESENT_ABORT=yes\n";exit(22);
}
$o=wc_get_order($id);
if(!$o||$o->get_status()!=='processing'||!$o->get_date_paid()||$o->get_currency()!=='IRT'){
 echo "CANARY_ORDER_NOT_PAID_PROCESSING_ABORT=yes\n";exit(23);
}
$opts=get_option('bazara_visitor_settings',[]);
if(($opts['selectCurrencySoftware']??'')!=='toman'||($opts['selectCurrencyPlugin']??'')!=='toman'){
 echo "CANARY_UNEXPECTED_BAZARA_OPTIONS_ABORT=yes\n";exit(24);
}
if((int)$o->get_meta('mahak_id')>0||
 (int)$wpdb->get_var($wpdb->prepare("SELECT COUNT(*) FROM {$wpdb->prefix}bazara_orders WHERE OrderClientId=%d",$id))>0){
 echo "CANARY_ALREADY_SYNCED_NO_RESEND=yes\n";exit(25);
}
foreach($o->get_items('line_item') as $item){
 $pid=(int)($item->get_variation_id()?:$item->get_product_id());
 if((int)get_post_meta($pid,'mahak_id',true)<=0||(int)get_post_meta($pid,'mahak_product_detail_id',true)<=0){
  echo "CANARY_UNMAPPED_PRODUCT_ID=".$pid." NO_SEND=yes\n";exit(26);
 }
}
$grand=(float)$o->get_total();$ship=(float)$o->get_shipping_total();$disc=(float)$o->get_discount_total();
if(abs($ship-150000)>0.001 || $grand<=0 || abs($disc)>0.001 ||
 $o->get_payment_method()!=='WC_Gateway_SnappPay'){
 echo "CANARY_FINANCIAL_EXPECTATION_CHANGED_ABORT=yes\n";exit(27);
}
$api=new BazaraApi(true);
$r=$api->get_all_data('',['fromOrderVersion'=>5144000000]);
if(!is_array($r)||empty($r['success'])||!is_array($r['message']['Orders']??null)){
 echo "CANARY_CLOUD_PRECHECK_UNAVAILABLE_NO_SEND=yes\n";exit(28);
}
foreach($r['message']['Orders'] as $row)if((int)($row['OrderClientId']??0)===$id){
 echo "CANARY_PRESENT_IN_CLOUD_NO_RESEND ERP_ENTITY=".(int)($row['OrderId']??0)."\n";exit(29);
}
echo "CANARY_CLOUD_ABSENT=yes TOTAL_IRT=".$grand." SHIPPING_IRT=".$ship." DISCOUNT_IRT=".$disc."\n";
$login=$api->login_token();
if(!is_array($login)||empty($login['success'])||!is_string($login['message'])){
 echo "CANARY_TOKEN_UNAVAILABLE_NO_SEND=yes\n";exit(30);
}
echo "CANARY_SINGLE_ATTEMPT_START=yes\n";
$result=$api->bazara_save_order($id,$login['message']);
$ack=(int)get_post_meta($id,'mahak_id',true);
$apiSucceeded=is_array($result) && !empty($result['success']) && $ack>0;
echo "CANARY_API_SUCCESS_FLAG=".($apiSucceeded?'yes':'no')." LOCAL_MARKER=".$ack." NO_RETRY=yes\n";
// Read back directly from the cloud; do not trust the local marker as proof.
$remote=$api->get_all_data('',['fromOrderVersion'=>5144000000,
 'fromOrderDetailVersion'=>5144000000,
 'fromReceiptVersion'=>5144000000]);
if(!is_array($remote)||empty($remote['success'])){echo "CANARY_CLOUD_READ_AFTER_SEND_FAILED=yes\n";exit(32);}
$ro=null;
foreach($remote['message']['Orders']??[] as $row)if((int)($row['OrderClientId']??0)===$id){$ro=$row;break;}
if(!$ro){echo "CANARY_NOT_IN_CLOUD_AFTER_ACK=yes\n";exit(33);}
$erpId=(int)($ro['OrderId']??0);
$erpShipping=(float)($ro['SendCost']??0);
$erpDiscount=(float)($ro['Discount']??0);
$description=(string)($ro['Description']??'');
$gatewayTagged=(strpos($description,'درگاه سایت: اسنپ پی (اقساطی)')!==false);
$priceSum=0.0;$detailDiscountSum=0.0;$lineCount=0;
foreach($remote['message']['OrderDetails']??[] as $d)if((int)($d['OrderId']??0)===$erpId){
 $priceSum+=(float)($d['Price']??0)*(float)($d['Count1']??0);
 $detailDiscountSum+=(float)($d['Discount']??0);
 $lineCount++;
}
echo "CANARY_ERP_ORDER_ID=$erpId\n";
echo "CANARY_REMOTE_SHIPPING_RIAL=$erpShipping EXPECTED=".($ship*10)."\n";
echo "CANARY_REMOTE_HEADER_DISCOUNT=$erpDiscount EXPECTED=0\n";
echo "CANARY_REMOTE_DETAIL_PRICE_SUM=$priceSum\n";
echo "CANARY_REMOTE_DETAIL_DISCOUNTS=$detailDiscountSum\n";
echo "CANARY_REMOTE_DETAIL_COUNT=$lineCount\n";
echo "CANARY_REMOTE_GATEWAY_LABEL_PRESENT=".($gatewayTagged?'yes':'no')."\n";
$expected=(float)$o->get_total()*10;
$sum=$priceSum-$detailDiscountSum-$erpDiscount+$erpShipping;
echo "CANARY_FINANCIAL_RECONCILIATION_RIAL=$sum EXPECTED=$expected DIFF=".abs($sum-$expected)."\n";
if(!$apiSucceeded || $erpId!==$ack||!$gatewayTagged||abs($erpShipping-$ship*10)>0.51||
  abs($sum-$expected)>0.51 ||$lineCount!==count($o->get_items('line_item'))){
 echo "CANARY_ERP_FINANCIAL_OR_SHIPPING_MISMATCH=YES MUST_NOT_BULK_REPLAY\n";exit(34);
}
echo "CANARY_CLOUD_ACCOUNTING_SHIPPING_GATEWAY_AND_TOTALS_VERIFIED=yes\n";
