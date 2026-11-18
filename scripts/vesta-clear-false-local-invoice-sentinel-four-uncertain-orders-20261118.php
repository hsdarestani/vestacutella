<?php
/**
 * Local-only correction of a known fake vendor acknowledgment for four
 * already-submitted uncertain orders. Never replays invoices, touches ERP,
 * payment, stock or identity data, or changes outbox states.
 */
error_reporting(E_ERROR|E_PARSE);ini_set('display_errors','0');
$_SERVER['HTTP_HOST']='vesta-cosmetics.ir';$_SERVER['SERVER_NAME']='vesta-cosmetics.ir';$_SERVER['HTTPS']='on';$_SERVER['SERVER_PORT']='443';$_SERVER['REQUEST_URI']='/';
require '/var/www/html/wp-load.php';global $wpdb;
$orders=[105540,105535,105482,105369];$sentinel='54323444';
$commit=getenv('VESTA_CLEAR_FALSE_ACK_COMMIT')==='yes';
if($commit && getenv('VESTA_FALSE_ACK_BACKUP_VERIFIED')!=='yes')exit(9);
$lock=null;$began=false;
try {
  $lockFile='/tmp/vesta-bazara-order-sync.lock';
  $lock=is_file($lockFile)?fopen($lockFile,'r'):fopen($lockFile,'x+');
  if(!$lock || !flock($lock,LOCK_EX|LOCK_NB))throw new RuntimeException('accounting_worker_busy');
  $api=new BazaraApi(true);$cloud=Vesta_Accounting_Reliability::cloud($api);
  $plan=[];$outbox=Vesta_Accounting_Reliability::table();
  foreach($orders as $id){
    $o=wc_get_order($id);if(!$o || !vcar_eligible($o))throw new RuntimeException('not_paid_'.$id);
    $q=$wpdb->get_row($wpdb->prepare("SELECT state,reason,attempts,submitted_at,remote_id FROM $outbox WHERE order_id=%d",$id),ARRAY_A);
    if(!$q || $q['state']!=='uncertain' || $q['reason']!=='submitted_without_remote_ack' ||
       (int)$q['attempts']<1 || (int)$q['submitted_at']<1 || (int)$q['remote_id']!==0)
      throw new RuntimeException('protected_uncertain_guard_changed_'.$id);
    if(count($cloud['orders'][$id]??[])!==0)throw new RuntimeException('cloud_invoice_now_exists_'.$id);
    $metaRows=$wpdb->get_results($wpdb->prepare("SELECT meta_id,meta_value FROM {$wpdb->postmeta} WHERE post_id=%d AND meta_key='mahak_id'",$id),ARRAY_A);
    if(count($metaRows)!==1 || (string)$metaRows[0]['meta_value']!==$sentinel ||
       (string)$o->get_meta('mahak_id')!==$sentinel)
      throw new RuntimeException('local_reference_not_exact_fake_marker_'.$id);
    $plan[]=['order_id'=>$id,'state'=>$q['state'],'remote_count'=>0,
      'old_local_reference'=>(int)$sentinel,'prior_submissions'=>(int)$q['attempts'],
      'will_preserve_uncertain_and_attempt_reservation'=>true];
  }
  echo 'FOUR_FALSE_INVOICE_ACK_PRECHECK='.json_encode($plan,JSON_UNESCAPED_UNICODE).PHP_EOL;
  if(!$commit){echo "FOUR_FALSE_ACK_DRYRUN_NO_WRITES=yes\n";exit(0);}
  $wpdb->query('START TRANSACTION');$began=true;
  foreach($orders as $id){
    $n=$wpdb->query($wpdb->prepare("DELETE FROM {$wpdb->postmeta} WHERE post_id=%d AND meta_key='mahak_id' AND meta_value=%s",$id,$sentinel));
    if($n!==1)throw new RuntimeException('exact_single_fake_meta_expected_'.$id);
  }
  foreach($orders as $id){
    $r=$wpdb->get_row($wpdb->prepare("SELECT state,reason,attempts,submitted_at,remote_id FROM $outbox WHERE order_id=%d",$id),ARRAY_A);
    $n=(int)$wpdb->get_var($wpdb->prepare("SELECT COUNT(*) FROM {$wpdb->postmeta} WHERE post_id=%d AND meta_key='mahak_id'",$id));
    if($n!==0 || !$r || $r['state']!=='uncertain'||$r['reason']!=='submitted_without_remote_ack'||
       (int)$r['submitted_at']<1 || (int)$r['attempts']<1 || (int)$r['remote_id']!==0)
      throw new RuntimeException('original_outbox_reservation_not_preserved_'.$id);
  }
  $wpdb->query('COMMIT');$began=false;
  foreach($orders as $id){
    wp_cache_delete($id,'post_meta');clean_post_cache($id);
    if(metadata_exists('post',$id,'mahak_id'))throw new RuntimeException('fake_reference_persisted_'.$id);
  }
  echo 'FOUR_UNCERTAIN_LOCAL_FAKE_INVOICE_IDS_CLEARED_WITHOUT_RESUBMISSION=yes'.PHP_EOL;
  echo 'ALL_FOUR_OUTBOX_STATES_REMAIN_UNCERTAIN_AND_UNTOUCHED=yes'.PHP_EOL;
  echo 'ZERO_ERP_INVOICES_RECEIPTS_STOCK_CUSTOMERS_WRITTEN=yes'.PHP_EOL;
}catch(Throwable $e){
  if($began)$wpdb->query('ROLLBACK');
  echo 'FALSE_ACK_CLEANUP_ABORT_REASON='.preg_replace('/[^a-z0-9_]/i','',$e->getMessage()).PHP_EOL;exit(30);
}finally{if($lock){flock($lock,LOCK_UN);fclose($lock);}}
