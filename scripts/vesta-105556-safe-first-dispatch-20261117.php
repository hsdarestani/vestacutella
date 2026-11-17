<?php
/**
 * Allow one verified paid order 105556 to become eligible for the existing
 * protected accounting worker after its exact cosmetic billing alias was
 * canonicalized. Never calls Bazara save_order directly.
 *
 * Zero prior attempts, no remote invoice, no local Bazara invoice cache,
 * exact customer/amount/gateway/name/ERP requirements, backup required.
 */
error_reporting(E_ERROR|E_PARSE);ini_set('display_errors','0');
$_SERVER['HTTP_HOST']='vesta-cosmetics.ir';$_SERVER['SERVER_NAME']='vesta-cosmetics.ir';
$_SERVER['HTTPS']='on';$_SERVER['SERVER_PORT']='443';$_SERVER['REQUEST_URI']='/';
require '/var/www/html/wp-load.php';global $wpdb;
$id=105556;$uid=2918;$pid=12706969;
$commit=getenv('VC_105556_RELEASE_COMMIT')==='yes';
if($commit&&getenv('VC_105556_RELEASE_BACKUP_VERIFIED')!=='yes')exit(21);
$o=wc_get_order($id);
if(!$o || !vcar_eligible($o) || $o->get_currency()!=='IRT' ||
 $o->get_payment_method()!=='wc_zibal'||!$o->get_transaction_id()||
 (int)$o->get_customer_id()!==$uid||
 (int)get_user_meta($uid,'mahak_id',true)!==$pid ||
 (int)get_user_meta(1,'mahak_id',true)!==0||
 abs((float)$o->get_total()-2250)>0.01||
 abs((float)$o->get_discount_total()-447750)>0.01 ||
 abs((float)$o->get_shipping_total())>0.01 ||
 (int)$o->get_meta('mahak_id')!==0 ||
 (int)$o->get_meta('_vcar_cloud_invoice_id')!==0 ||
 (string)$o->get_meta('_vesta_original_billing_last_name_105556')!== 'علوی (زیبایی)' ||
 vcar_identity_guard($o)!==''){
 echo "VERIFIED_IDENTITY_AMOUNT_OR_ALIAS_GUARD_FAILED_NO_WRITES=yes\n";exit(22);
}
$settings=get_option('bazara_visitor_settings',[]);
$bank=vcar_bank($settings,$o->get_payment_method());
$pre=Vesta_Accounting_Reliability::preflight($o,$bank);
if($pre!==''){echo "INVOICE_PREFLIGHT_NOT_CLEAN_NO_WRITES=".sanitize_key($pre).PHP_EOL;exit(23);}
$api=new BazaraApi(true);
$res=$api->get_all_data('',array('fromOrderVersion'=>0,'fromPersonVersion'=>0));
if(empty($res['success']) || !is_array($res['message']['Orders']??null) || !is_array($res['message']['People']??null))exit(24);
$invoiceCount=0;$personCount=0;$personNameMatches=false;
foreach($res['message']['Orders'] as $r)
 if(empty($r['Deleted'])&&(int)($r['OrderClientId']??0)===$id)$invoiceCount++;
foreach($res['message']['People'] as $p)if(empty($p['Deleted'])&&(int)($p['PersonId']??0)===$pid){
 $personCount++;
 $personNameMatches=(vcar_identity_normalize_name(($p['FirstName']??'').' '.($p['LastName']??''))===
  vcar_identity_normalize_name($o->get_billing_first_name().' '.$o->get_billing_last_name()));
}
if($invoiceCount!==0||$personCount!==1||!$personNameMatches){
 echo "REMOTE_EXISTING_INVOICE_OR_PERSON_CONFLICT_NO_WRITES=yes\n";exit(25);
}
$local=(int)$wpdb->get_var($wpdb->prepare("SELECT COUNT(*) FROM {$wpdb->prefix}bazara_orders WHERE OrderClientId=%d",$id));
if($local!==0)exit(26);
$t=Vesta_Accounting_Reliability::table();
$q=$wpdb->get_row($wpdb->prepare("SELECT state,reason,attempts,submitted_at,remote_id FROM $t WHERE order_id=%d",$id),ARRAY_A);
if(!$q || $q['state']!=='blocked' || $q['reason']!=='customer_erp_name_mismatch' ||
 (int)$q['attempts']!==0||(int)$q['submitted_at']!==0||(int)$q['remote_id']!==0){
 echo "OUTBOX_STILL_NOT_EXACT_NO_SUBMISSION_BLOCK_NO_WRITES=yes\n";exit(27);
}
echo 'FIRST_DISPATCH_105556_PLAN='.json_encode([
 'order_id'=>$id,'customer_uid'=>$uid,'person_id'=>$pid,
 'paid_amount_toman'=>2250,'original_subtotal_toman'=>450000,
 'coupon_discount_toman'=>447750,
 'cloud_invoice_count'=>$invoiceCount,'previous_attempts'=>0,
 'exact_historical_name_block_only'=>true
],JSON_UNESCAPED_UNICODE).PHP_EOL;
if(!$commit){echo "SAFE_105556_RELEASE_PREVIEW_NO_WRITES=yes\n";exit(0);}
$lock='vesta_105556_exact_queue_release';
if((int)$wpdb->get_var($wpdb->prepare("SELECT GET_LOCK(%s,5)",$lock))!==1)exit(28);
try{
 $n=$wpdb->query($wpdb->prepare(
  "UPDATE $t SET state='pending',reason='',next_attempt=%d,updated_at=%d WHERE order_id=%d AND state='blocked' AND reason='customer_erp_name_mismatch' AND attempts=0 AND submitted_at=0 AND remote_id=0",
  time()-1,time(),$id
 ));
 if($n!==1){echo "EXPECTED_ONE_QUEUE_ROW_NOT_UPDATED_NO_SEND=yes\n";exit(29);}
 $q2=$wpdb->get_row($wpdb->prepare("SELECT state,reason,attempts,submitted_at,remote_id FROM $t WHERE order_id=%d",$id),ARRAY_A);
 if(!$q2 || $q2['state']!=='pending' || $q2['reason']!=='' ||
 (int)$q2['attempts']!==0 || (int)$q2['submitted_at']!==0 ||
 (int)$q2['remote_id']!==0)exit(30);
 echo "ONLY_105556_QUEUED_FOR_EXISTING_SAFE_SENDER=yes INVOICE_NOT_DIRECTLY_SUBMITTED=yes\n";
}finally{$wpdb->get_var($wpdb->prepare("SELECT RELEASE_LOCK(%s)",$lock));}
