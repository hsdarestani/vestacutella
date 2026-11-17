<?php
/**
 * One-use guarded release of paid Woo order 105556 from an obsolete customer
 * legacy checkout gateway suffix mismatch, using verified OTP and ERP identity.
 * Does NOT itself invoke vendor invoice send. Leaves delivery to existing
 * lock-protected accounting worker; no automatic retry after ambiguous send.
 * Defaults to no-writes, commits only with backup and explicit opt-in.
 */
error_reporting(E_ERROR|E_PARSE);ini_set('display_errors','0');
$_SERVER['HTTP_HOST']='vesta-cosmetics.ir';$_SERVER['SERVER_NAME']='vesta-cosmetics.ir';$_SERVER['HTTPS']='on';$_SERVER['SERVER_PORT']='443';$_SERVER['REQUEST_URI']='/';
require '/var/www/html/wp-load.php';
global $wpdb;
$id=105556;$pid=12706969;$uid=2918;
$commit=getenv('VC_RELEASE_ZIBAL_COMMIT')==='yes';
if($commit && getenv('VC_RELEASE_ZIBAL_BACKUP_VERIFIED')!=='yes'){echo "BACKUP_REQUIRED_NO_WRITES=yes\n";exit(20);}
$o=wc_get_order($id);
if(!$o || !vcar_eligible($o) || $o->get_currency()!=='IRT' || !$o->get_date_paid() ||
   (int)$o->get_customer_id()!==$uid || (int)get_user_meta($uid,'mahak_id',true)!==$pid ||
   (int)get_user_meta(1,'mahak_id',true)!==0 ||
   (float)$o->get_total()!==2250.0 || (float)$o->get_shipping_total()!==0.0 ||
   (float)$o->get_discount_total()!==447750.0 ||
   $o->get_payment_method()!=='wc_zibal' || !$o->get_transaction_id() ||
   (int)$o->get_meta('mahak_id')>0 || (int)$o->get_meta('_vcar_cloud_invoice_id')>0){
 echo "EXPECTED_BUYER_OR_FINANCIAL_INVARIANT_FAILED_NO_WRITES=yes\n";exit(21);
}
if(!get_option('vcar_sender_enabled',false)){echo "GUARDED_SENDER_NOT_ENABLED_NO_WRITES=yes\n";exit(22);}
$settings=get_option('bazara_visitor_settings',[]);
$bank=vcar_bank($settings,$o->get_payment_method());
$pre=Vesta_Accounting_Reliability::preflight($o,$bank);
if($pre!==''){echo "ORDER_PREFLIGHT_BLOCKED=".sanitize_key($pre)." NO_WRITES=yes\n";exit(23);}
$api=new BazaraApi(true);
$all=$api->get_all_data('',array('fromPersonVersion'=>0,'fromOrderVersion'=>0));
$m=$all['message']??[];
if(empty($all['success']) || !is_array($m['People']??null) || !is_array($m['Orders']??null)){
 echo "CLOUD_PRESUBMISSION_READ_UNAVAILABLE_NO_WRITES=yes\n";exit(24);
}
$person=[];$duplicates=0;$existsInvoice=0;$phoneCount=0;
$phone=vesta_otp_phone((string)$o->get_billing_phone());
foreach($m['People'] as $p) {
 if(!empty($p['Deleted']))continue;
 if((int)($p['PersonId']??0)===$pid)$person[]=$p;
 if(vesta_otp_phone((string)($p['Mobile']??''))===$phone)$phoneCount++;
}
foreach($m['Orders'] as $remote)if(empty($remote['Deleted'])&&(int)($remote['OrderClientId']??0)===$id)$existsInvoice++;
if(count($person)!==1 || $phoneCount!==1 || $existsInvoice!==0 ||
 vcar_identity_normalize_name(($person[0]['FirstName']??'').' '.($person[0]['LastName']??''))!==
 vcar_identity_normalize_name(get_user_by('id',$uid)->first_name.' '.get_user_by('id',$uid)->last_name) ||
 !vcar_checkout_has_gateway_suffix($o,$person[0]['FirstName']??'',$person[0]['LastName']??'')){
 echo "REMOTE_PERSON_OR_ORDER_CONFLICT_NO_WRITES=yes\n";exit(25);
}
$t=Vesta_Accounting_Reliability::table();
$q=$wpdb->get_row($wpdb->prepare("SELECT state,reason,attempts,submitted_at,remote_id,next_attempt FROM $t WHERE order_id=%d",$id),ARRAY_A);
if(!$q || (int)$q['attempts']!==0 || (int)$q['submitted_at']!==0 || (int)$q['remote_id']!==0 ||
   $q['state']!=='blocked' || $q['reason']!=='customer_erp_name_mismatch'){
 echo "OUTBOX_NOT_EXACT_STALE_IDENTITY_BLOCK_NO_WRITES=yes\n";exit(26);
}
if((int)$wpdb->get_var($wpdb->prepare("SELECT COUNT(*) FROM {$wpdb->prefix}bazara_orders WHERE OrderClientId=%d",$id))!==0){
 echo "LOCAL_VENDOR_INVOICE_CACHE_EXISTS_NO_WRITES=yes\n";exit(27);
}
echo 'RELEASE_105556_PLAN='.json_encode([
  'id'=>$id,'buyer_uid'=>$uid,'person_id'=>$pid,'gateway'=>$o->get_payment_method(),
  'coupon_discount_toman'=>(float)$o->get_discount_total(),
  'total_toman'=>(float)$o->get_total(),'shipping_toman'=>(float)$o->get_shipping_total(),
  'cloud_invoice_count'=>$existsInvoice,'vendor_attempts'=>(int)$q['attempts'],
  'identity_guard'=>'verified','safe_to_release'=>true
],JSON_UNESCAPED_UNICODE).PHP_EOL;
if(!$commit){echo "ORDER_REQUEUE_DRY_RUN_NO_WRITES=yes\n";exit(0);}
$lock='vesta_mona_105556_queue_release';
if((int)$wpdb->get_var($wpdb->prepare('SELECT GET_LOCK(%s,5)',$lock))!==1){echo "QUEUE_RELEASE_LOCK_BUSY_NO_WRITES=yes\n";exit(28);}
try{
 if(!get_option('vcar_sender_enabled',false))exit(29);
 $now=time();
 $n=$wpdb->query($wpdb->prepare(
   "UPDATE $t SET state='pending',reason='',next_attempt=%d,updated_at=%d WHERE order_id=%d AND state='blocked' AND reason='customer_erp_name_mismatch' AND attempts=0 AND submitted_at=0 AND remote_id=0",
   $now-1,$now,$id
 ));
 if($n!==1){echo "EXACT_QUEUE_ROW_NOT_UPDATED_NO_INVOICE_SENT=yes\n";exit(30);}
 $after=$wpdb->get_row($wpdb->prepare("SELECT state,reason,attempts,submitted_at,remote_id FROM $t WHERE order_id=%d",$id),ARRAY_A);
 if(!$after || $after['state']!=='pending' || $after['reason']!=='' || (int)$after['attempts']!==0 ||
    (int)$after['submitted_at']!==0 || (int)$after['remote_id']!==0)exit(31);
 echo "ONLY_ORDER_105556_RELEASED_TO_PROTECTED_SENDER=yes NO_INVOICE_SUBMISSION_BY_REQUEUE_SCRIPT=yes\n";
}finally{$wpdb->get_var($wpdb->prepare('SELECT RELEASE_LOCK(%s)',$lock));}
