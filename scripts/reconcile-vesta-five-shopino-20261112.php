<?php
// One-time seven recent paid orders, no manual retries, cloud deduplication and live financial verification.
// Shopino linked to explicitly verified Mahak BankId 471168; ambiguous 105309 excluded.
error_reporting(E_ERROR|E_PARSE);ini_set('display_errors','0');set_time_limit(0);
$_SERVER['HTTP_HOST']='vesta-cosmetics.ir';$_SERVER['SERVER_NAME']='vesta-cosmetics.ir';
$_SERVER['HTTPS']='on';$_SERVER['SERVER_PORT']='443';$_SERVER['REQUEST_URI']='/wp-cron.php';
require '/var/www/html/wp-load.php';
global $wpdb;
$ids=[105302,105310,105311,105312,105317];
$lock=fopen('/tmp/vesta-bazara-order-sync.lock','r');
if(!$lock){echo "RECONCILE_SHARED_LOCK_UNAVAILABLE_ABORT=yes\n";exit(20);}
$locked=false;for($i=0;$i<120;$i++){if(flock($lock,LOCK_EX|LOCK_NB)){$locked=true;break;}usleep(250000);}
if(!$locked){echo "RECONCILE_SHARED_LOCK_BUSY_NO_SEND=yes\n";exit(21);}
echo "EXCLUSIVE_BAZARA_SEND_MUTEX_ACQUIRED=yes\n";
$source=file_get_contents('/var/www/html/wp-content/plugins/bazara/classes/class.bazara.api.php');
if(strpos($source,'VC_BAZARA_FINANCIAL_PAYLOAD_V1_20261112')===false||strpos($source,'VC_BAZARA_OUTBOUND_RIAL_ONLY_20261110')===false){
 echo "OUTBOUND_FINANCE_PATCH_MISSING_ABORT=yes\n";exit(22);
}
// All Shopino receiving funds must map to its existing dedicated ERP bank.
$opts=get_option('bazara_visitor_settings',[]);
$bankSettings=json_decode(stripslashes($opts['banksMethods']??''),true);
$bankFound=0;
foreach(is_array($bankSettings)?$bankSettings:[] as $map){
 if(($map['method']??'')==='shopino' && (string)($map['name']??'')==='471168')$bankFound++;
}
if($bankFound!==1){echo "SHOPINO_RECEIPT_BANK_NOT_VERIFIED_NO_SEND=yes\\n";exit(30);}
$api=new BazaraApi(true);
function cloud_read($api){
 $r=$api->get_all_data('',[
  'fromOrderVersion'=>5144000000,'fromOrderDetailVersion'=>5144000000,
  'fromReceiptVersion'=>5144000000
 ]);
 if(!is_array($r)||empty($r['success'])||!is_array($r['message']['Orders']??null)){
  echo "REMOTE_CLOUD_READ_UNAVAILABLE_NO_NEW_SEND=yes\n";exit(23);
 }
 return $r['message'];
}
$remote=cloud_read($api);
$login=$api->login_token();
if(!is_array($login)||empty($login['success'])||!is_string($login['message'])){
 echo "REMOTE_LOGIN_FAILED_NO_NEW_SEND=yes\n";exit(24);
}
$n=0;$already=0;$skipped=0;
foreach($ids as $id){
 $o=wc_get_order($id);
 if(!$o||$o->get_status()!=='processing'||!$o->get_date_paid()||$o->get_currency()!=='IRT'){
  echo "ORDER=$id UNEXPECTED_STATUS_OR_PAYMENT_SKIPPED=yes\n";$skipped++;continue;
 }
 $remoteOrder=null;
 foreach($remote['Orders'] as $x)if((int)($x['OrderClientId']??0)===$id){$remoteOrder=$x;break;}
 $ack=(int)$o->get_meta('mahak_id');
 $cached=(int)$wpdb->get_var($wpdb->prepare("SELECT COUNT(*) FROM {$wpdb->prefix}bazara_orders WHERE OrderClientId=%d",$id));
 if($remoteOrder || $ack || $cached){
  echo "ORDER=$id ALREADY_ACKNOWLEDGED_OR_REMOTE_EXISTS=yes NO_SEND=yes\n";$already++;continue;
 }
 if(!in_array($o->get_payment_method(),['shopino'],true)){
  echo "ORDER=$id UNMAPPED_PAYMENT_ACCOUNT_METHOD_SKIPPED=yes\n";$skipped++;continue;
 }
 foreach($o->get_items('line_item') as $item){
  $pid=(int)($item->get_variation_id()?:$item->get_product_id());
  if((int)get_post_meta($pid,'mahak_id',true)<=0||(int)get_post_meta($pid,'mahak_product_detail_id',true)<=0){
   echo "ORDER=$id NOT_ALL_PRODUCTS_EXACTLY_MAPPED_ABORT=yes\n";exit(25);
  }
 }
 $ship=(float)$o->get_shipping_total();
 $total=(float)$o->get_total();
 $lines=0;
 foreach($o->get_items('line_item') as $item)$lines+=(float)$item->get_total();
 if(abs(($lines+$ship)-$total)>0.51||abs((float)$o->get_total_tax())>0.01||
   count($o->get_items('fee'))>0){
  echo "ORDER=$id WOO_ACCOUNTING_PARITY_FAILED_ABORT=yes\n";exit(26);
 }
 echo "ORDER=$id CAN_SEND_SINGLE_ATTEMPT=yes SHIP_IRT=".$ship." TOTAL_IRT=".$total."\n";
 $result=$api->bazara_save_order($id,$login['message']);
 $ack=(int)get_post_meta($id,'mahak_id',true);
 if(!is_array($result)||empty($result['success'])||$ack<=0){
  echo "ORDER=$id AMBIGUOUS_API_RESULT_STOP_ALL=yes LOCAL_ACK=".$ack." NO_RETRY=yes\n";exit(27);
 }
 $remote=cloud_read($api);
 $row=null;
 foreach($remote['Orders'] as $x)if((int)($x['OrderClientId']??0)===$id){$row=$x;break;}
 if(!$row){
  echo "ORDER=$id REMOTE_ACK_MISSING_CLOUD_STOP_ALL=yes\n";exit(28);
 }
 $erp=(int)($row['OrderId']??0);
 $erpShip=(float)($row['SendCost']??0);
 $erpDiscount=(float)($row['Discount']??0);
 $tag=str_contains((string)($row['Description']??''),'درگاه سایت:');
 $gross=0;$disc=0;$num=0;
 foreach($remote['OrderDetails']??[] as $it)if((int)($it['OrderId']??0)===$erp){
  $gross+=(float)($it['Price']??0)*(float)($it['Count1']??0);
  $disc+=(float)($it['Discount']??0);
  $num++;
 }
 $calculated=$gross-$disc-$erpDiscount+$erpShip;
 if($erp!==$ack||!$tag||abs($erpShip-$ship*10)>0.51||
   abs($calculated-$total*10)>0.51 || $num<=0){
  echo "ORDER=$id CLOUD_AMOUNT_SHIPPING_OR_GATEWAY_MISMATCH_STOP_ALL=yes ERP_ID=$erp".
   " SEND_COST=".$erpShip." REMOTE_CALCULATED=".$calculated." EXPECTED=".($total*10).
   " TAG=".($tag?'yes':'no')."\n";exit(29);
 }
 $receiptFound=false;
 foreach($remote['Receipts']??[] as $rr)if((int)($rr['OrderId']??0)===$erp){
  $receiptFound=true;break;
 }
 echo "ORDER=$id VERIFIED_CLOUD_ERP_ID=$erp SHIPPING_RIAL=$erpShip TOTAL_RIAL=$calculated".
   " PAYMENT_SOURCE_TAG=yes REMOTE_RECEIPT_LINK=".($receiptFound?'yes':'not_in_version_window')."\n";
 $n++;
}
echo "RECONCILE_CONFIRMED_NEW=".$n." ALREADY_EXIST=".$already." SKIPPED=".$skipped."\n";
echo "NO_RETRIES_OR_OLD_ORDER_REPLAYS=yes\n";
echo "FIVE_SHOPINO_BAZARA_RECONCILIATION_FINISHED=yes\n";
