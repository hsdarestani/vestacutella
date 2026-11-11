<?php
// Reconcile 8 unacknowledged WooCommerce orders safely: remote cloud precheck, no duplicate submits, mapping verified.
// Uses existing BazaraApi send path; no edits to prices, stock, status, plugin settings, or historical orders.
error_reporting(E_ERROR|E_PARSE);ini_set('display_errors','0');set_time_limit(0);
$_SERVER['HTTP_HOST']='vesta-cosmetics.ir';$_SERVER['SERVER_NAME']='vesta-cosmetics.ir';
$_SERVER['HTTPS']='on';$_SERVER['SERVER_PORT']='443';$_SERVER['REQUEST_URI']='/wp-cron.php';
require '/var/www/html/wp-load.php';
global $wpdb;
$orderIds=[105220,105221,105223,105225,105226,105227,105228,105230];
$lock=fopen('/tmp/vesta-bazara-order-sync.lock','c');
if(!$lock||!flock($lock,LOCK_EX|LOCK_NB)){
 echo "BAZARA_RUNNER_BUSY_NO_ACTION=yes\n";exit(16);
}
$plugin='/var/www/html/wp-content/plugins/bazara/classes/class.bazara.api.php';
$source=file_get_contents($plugin);
if(strpos($source,'VC_BAZARA_OUTBOUND_RIAL_ONLY_20261110')===false ||
 strpos($source,'VC_RECENT_BAZARA_CATCHUP_20261110')===false){
 echo "OUTBOUND_RIAL_OR_CATCHUP_PATCH_MISSING_ABORT=yes\n";exit(17);
}
$opts=get_option('bazara_visitor_settings',[]);
if(!is_array($opts)||
 ($opts['selectCurrencySoftware']??'')!=='toman' ||
 ($opts['selectCurrencyPlugin']??'')!=='toman'||
 get_woocommerce_currency()!=='IRT'){
 echo "UNEXPECTED_CURRENCY_CONFIGURATION_ABORT=yes\n";exit(18);
}
$api=new BazaraApi(true);
$remote=$api->get_all_data('',array('fromOrderVersion'=>5144000000));
if(!is_array($remote) || empty($remote['success']) ||
 !isset($remote['message']['Orders']) || !is_array($remote['message']['Orders'])){
 echo "BAZARA_CLOUD_UNAVAILABLE_ABORT_ALL=yes\n";exit(19);
}
$remoteClients=[];$remoteRows=$remote['message']['Orders'];
foreach($remoteRows as $r){
 if(!is_array($r))continue;
 $id=(int)($r['OrderClientId']??0);
 if($id>0)$remoteClients[$id]=(int)($r['OrderId']??0);
}
echo "CLOUD_READ_OK=yes CLOUD_RECENT_COUNT=".count($remoteRows)."\n";
$token=$api->login_token();
if(!is_array($token)||empty($token['success'])||empty($token['message'])){
 echo "BAZARA_TOKEN_UNAVAILABLE_ABORT_ALL=yes\n";exit(20);
}
$success=0;$fail=0;$exists=0;$invalid=0;
foreach($orderIds as $id){
 $order=wc_get_order($id);
 if(!$order || !$order->has_status(['processing','completed','processing5','pws-packaged','pws-shipping','arrival-shipment'])){
  echo "ORDER=$id SKIPPED_UNEXPECTED_ORDER_STATUS=yes\n";$invalid++;continue;
 }
 $ack=(int)$order->get_meta('mahak_id');
 $dbRemote=(int)$wpdb->get_var($wpdb->prepare(
   "SELECT COUNT(*) FROM {$wpdb->prefix}bazara_orders WHERE OrderClientId=%d",$id));
 if($ack>0 || $dbRemote>0 || isset($remoteClients[$id])){
  echo "ORDER=$id ALREADY_EXISTS_WOO_ACK=$ack LOCAL_REMOTE_ROWS=$dbRemote CLOUD_REMOTE_ID=".($remoteClients[$id]??0)." NO_RESEND=yes\n";
  $exists++;continue;
 }
 $lines=$order->get_items('line_item');
 if(!$lines){echo "ORDER=$id SKIPPED_NO_ITEMS=yes\n";$invalid++;continue;}
 $bad=[];
 foreach($lines as $item){
  $variation=(int)$item->get_variation_id();$product=(int)$item->get_product_id();
  $key=$variation?:$product;
  if((int)get_post_meta($key,'mahak_id',true)<=0||(int)get_post_meta($key,'mahak_product_detail_id',true)<=0){
   $bad[]=$key;
  }
 }
 if($bad){echo "ORDER=$id SKIPPED_UNMAPPED_PRODUCTS=".implode(',',$bad)."\n";$invalid++;continue;}
 echo "ORDER=$id PREFLIGHT=remote_absent_all_items_mapped ACTIVE_RIAL_CONVERSION=yes\n";
 try{
  $result=$api->bazara_save_order($id,(string)$token['message']);
  $ackNow=(int)$order->get_meta('mahak_id');
  $fresh=wc_get_order($id);
  $ackNew=$fresh?(int)$fresh->get_meta('mahak_id'):0;
  if($ackNew<=0)$ackNew=(int)get_post_meta($id,'mahak_id',true);
  if($ackNew>0 && is_array($result) && !empty($result['success'])){
   echo "ORDER=$id SUBMIT_CONFIRMED=yes NEW_ERP_ID=$ackNew\n";$success++;
  }else{
   $rtype=is_array($result)?(empty($result['success'])?'api_rejected':'success_without_positive_id'):'unexpected_return_type';
   echo "ORDER=$id SUBMIT_CONFIRMED=no REASON=$rtype ERP_MARKER=$ackNew STOP_RETRY=yes\n";$fail++;
  }
 }catch(Throwable $e){
  echo "ORDER=$id SUBMIT_EXCEPTION=yes CLASS=".get_class($e)." STOP_RETRY=yes\n";$fail++;
 }
}
echo "RECONCILE_COUNTS confirmed=$success already_exists=$exists failed=$fail skipped=$invalid\n";
echo "NO_SECOND_ATTEMPTS=yes\n";
echo "NO_STOREFRONT_PRICE_OR_STOCK_CHANGES=yes\n";
echo "ONE_TIME_RECONCILIATION_COMPLETE=yes\n";
