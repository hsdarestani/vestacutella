<?php
/**
 * Exact two-order outbox recheck after mapping SKU 70337. Never force a
 * second invoice on ambiguous ack. Uses the existing guarded sender only.
 * Dry-run by default, no new product or inventory writes.
 */
error_reporting(E_ERROR|E_PARSE);ini_set('display_errors','0');
$_SERVER['HTTP_HOST']='vesta-cosmetics.ir';$_SERVER['SERVER_NAME']='vesta-cosmetics.ir';$_SERVER['HTTPS']='on';$_SERVER['SERVER_PORT']='443';$_SERVER['REQUEST_URI']='/';
require '/var/www/html/wp-load.php';global $wpdb;
$ids=[105364,105428];$commit=getenv('VC_2_WASHBAG_COMMIT')==='yes';
if($commit&&getenv('VC_2_WASHBAG_BACKUP_VERIFIED')!=='yes')exit(11);
$t=Vesta_Accounting_Reliability::table();
try{
 if(!get_option('vcar_sender_enabled',false))throw new RuntimeException('sender_disabled');
 $api=new BazaraApi(true);$cloud=Vesta_Accounting_Reliability::cloud($api);
 $setting=get_option('bazara_visitor_settings',[]);
 $out=[];$needsRetry=[];
 foreach($ids as $id){
  $o=wc_get_order($id);
  if(!$o||!vcar_eligible($o))throw new RuntimeException('order_not_paid_or_ineligible_'.$id);
  $q=$wpdb->get_row($wpdb->prepare("SELECT * FROM $t WHERE order_id=%d",$id),ARRAY_A);
  if(!$q)throw new RuntimeException('outbox_missing_'.$id);
  if(!empty($cloud['orders'][$id])){
    if(count($cloud['orders'][$id])!==1)throw new RuntimeException('multiple_cloud_invoices_'.$id);
    $out[]=['woo_id'=>$id,'outbox_state'=>$q['state'],'already_in_cloud'=>true];continue;
  }
  $local=(int)$o->get_meta('mahak_id');
  $cache=(int)$wpdb->get_var($wpdb->prepare("SELECT COUNT(*) FROM {$wpdb->prefix}bazara_orders WHERE OrderClientId=%d",$id));
  if($q['state']!=='blocked'||$q['reason']!=='missing_product_mapping' ||
     (int)$q['attempts']!==0 ||(int)$q['submitted_at']!==0||(int)$q['remote_id']!==0 ||
     $local!==0 ||$cache!==0)
    throw new RuntimeException('unverified_historic_attempt_or_duplicate_risk_'.$id);
  $missing=[];foreach($o->get_items('line_item') as $item){
    $pid=$item->get_variation_id()?:$item->get_product_id();
    if((int)get_post_meta($pid,'mahak_id',true)<1||
       (int)get_post_meta($pid,'mahak_product_detail_id',true)<1)$missing[]=$pid;
  }
  if($missing)throw new RuntimeException('another_line_still_missing_mapping_'.$id);
  $bank=vcar_bank($setting,$o->get_payment_method());
  $preflight=Vesta_Accounting_Reliability::preflight($o,$bank);
  if($preflight!=='')throw new RuntimeException('strict_order_preflight_still_blocked_'.$id.'_'.$preflight);
  $out[]=['woo_id'=>$id,'outbox_state'=>$q['state'],'already_in_cloud'=>false,
    'ever_submitted'=>false,'ready_strict_preflight'=>true];
  $needsRetry[]=$id;
 }
 echo 'TWO_WASHBAG_ORDERS_POST_MAPPING_PLAN='.json_encode($out,JSON_UNESCAPED_UNICODE).PHP_EOL;
 if(!$commit){echo "WASHBAG_TWO_ORDERS_RECHECK_DRYRUN_NO_WRITES=yes\n";exit(0);}
 foreach($needsRetry as $id){
   $modified=$wpdb->query($wpdb->prepare("UPDATE $t SET state='retry',reason='exact_erp_variation_mapping_repaired',
     next_attempt=0,updated_at=%d WHERE order_id=%d AND state='blocked' AND reason='missing_product_mapping'
     AND submitted_at=0 AND attempts=0 AND remote_id=0",time(),$id));
   if($modified!==1)throw new RuntimeException('outbox_safe_release_failed_'.$id);
 }
 echo 'EXACT_UNSUBMITTED_WASHBAG_ORDERS_RELEASED_TO_PROTECTED_SENDER='.json_encode($needsRetry).PHP_EOL;
 // Existing protected sender performs its own cloud preflight and durable
 // "sending" reservation before attempting any ERP invoice.
 $attempt=Vesta_Accounting_Reliability::tick(true,2);
 echo 'PROTECTED_SENDER_PASS='.json_encode($attempt,JSON_UNESCAPED_UNICODE).PHP_EOL;
 $api=new BazaraApi(true);$fresh=Vesta_Accounting_Reliability::cloud($api);
 foreach($ids as $id){
   $q=$wpdb->get_row($wpdb->prepare("SELECT state,reason,attempts,remote_id,submitted_at FROM $t WHERE order_id=%d",$id),ARRAY_A);
   $o=wc_get_order($id);
   $match=$fresh['orders'][$id]??[];
   echo 'WASHBAG_ORDER_AFTER_GUARDED_PASS='.json_encode([
    'woo_id'=>$id,'state'=>$q['state'],'reason'=>$q['reason'],'attempts'=>(int)$q['attempts'],
    'remote_count'=>count($match),'outbox_remote_id'=>(int)$q['remote_id'],
    'local_invoice'=>(int)$o->get_meta('mahak_id')],JSON_UNESCAPED_UNICODE).PHP_EOL;
   if(count($match)>1)throw new RuntimeException('ambiguous_erp_multiple_invoices_'.$id);
 }
 echo "NO_DIRECT_ERP_REPLAY_OR_STOCK_MUTATIONS_BY_RECOVERY_SCRIPT=yes\n";
}catch(Throwable $e){
 echo 'TWO_WASHBAG_RECHECK_STOP_REASON='.preg_replace('/[^a-z0-9_]/i','',$e->getMessage()).PHP_EOL;
 exit(21);
}
