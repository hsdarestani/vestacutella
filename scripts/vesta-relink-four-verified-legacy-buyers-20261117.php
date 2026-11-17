<?php
/**
 * Correct only four existing historic paid Woo order/customer relations
 * when billing name, exact OTP-owner, profile mobile, role and cloud absence
 * independently prove the real customer. This NEVER creates or edits a Mahak
 * person, product, cloud invoice, receipt, payment, discount or order line.
 * Dry run unless VC_FOUR_BUYERS_COMMIT=yes with verified backup and sender stopped.
 */
error_reporting(E_ERROR|E_PARSE);ini_set('display_errors','0');
$_SERVER['HTTP_HOST']='vesta-cosmetics.ir';$_SERVER['SERVER_NAME']='vesta-cosmetics.ir';$_SERVER['HTTPS']='on';$_SERVER['SERVER_PORT']='443';$_SERVER['REQUEST_URI']='/';
require '/var/www/html/wp-load.php';global $wpdb;
$plan=[102983=>[0,6061,'customer_account_unassigned'],
       102933=>[3055,6035,'customer_phone_owner_mismatch'],
       102918=>[3055,5981,'customer_phone_owner_mismatch'],
       102789=>[0,5983,'customer_account_unassigned']];
$commit=getenv('VC_FOUR_BUYERS_COMMIT')==='yes';
if($commit && (getenv('VC_FOUR_BUYERS_BACKUP_VERIFIED')!=='yes'||
 get_option('vcar_sender_enabled',false))){echo "BACKUP_OR_SENDER_GATE_FAILED_NO_CHANGES=yes\n";exit(10);}
$api=new BazaraApi(true);$r=$api->get_all_data('',array('fromPersonVersion'=>0,'fromOrderVersion'=>0));
if(empty($r['success'])||!is_array($r['message']['Orders']??null)||!is_array($r['message']['People']??null))exit(11);
$remote=[];$persons=[];
foreach($r['message']['Orders'] as $inv)if(empty($inv['Deleted']) && isset($plan[(int)($inv['OrderClientId']??0)]))
 $remote[(int)$inv['OrderClientId']][]=$inv;
foreach($r['message']['People'] as $p)if(empty($p['Deleted']))$persons[(int)($p['PersonId']??0)]=$p;
$orders=[];$t=Vesta_Accounting_Reliability::table();$results=[];
foreach($plan as $id=>$spec){
  [$oldUid,$newUid,$reason]=$spec;$o=wc_get_order($id);$u=get_user_by('id',$newUid);
  if(!$o||!$u||!vcar_eligible($o)||(int)$o->get_customer_id()!==$oldUid||
    !array_intersect((array)$u->roles,['customer','subscriber'])||
    array_intersect((array)$u->roles,['administrator','shop_manager','editor','author']))exit(12);
  $billing=vcar_identity_normalize_name($o->get_billing_first_name().' '.$o->get_billing_last_name());
  $profile=vcar_identity_normalize_name($u->first_name.' '.$u->last_name);
  $phone=vesta_otp_phone((string)$o->get_billing_phone());
  $owner=$phone?vesta_otp_existing_user($phone):false;
  if(!$phone||!$profile||$billing!==$profile||is_wp_error($owner)||
     !is_numeric($owner)||(int)$owner!==$newUid||
     $phone!==vesta_otp_phone((string)get_user_meta($newUid,'billing_phone',true)))exit(13);
  if($oldUid>0 && $oldUid===$newUid)exit(14);
  $q=$wpdb->get_row($wpdb->prepare("SELECT state,reason,attempts,submitted_at,remote_id FROM $t WHERE order_id=%d",$id),ARRAY_A);
  if(!$q||$q['state']!=='blocked'||$q['reason']!==$reason||
   (int)$q['attempts']!==0||(int)$q['submitted_at']!==0||(int)$q['remote_id']!==0||
   (int)$o->get_meta('mahak_id')>0||(int)$o->get_meta('_vcar_cloud_invoice_id')>0||
   !empty($remote[$id])||
   (int)$wpdb->get_var($wpdb->prepare("SELECT COUNT(*) FROM {$wpdb->prefix}bazara_orders WHERE OrderClientId=%d",$id))!==0)exit(15);
  $personId=(int)get_user_meta($newUid,'mahak_id',true);
  if($personId>0){
    $p=$persons[$personId]??null;
    if(!$p || vcar_identity_normalize_name(($p['FirstName']??'').' '.($p['LastName']??''))!==$billing ||
       vesta_otp_phone((string)($p['Mobile']??''))!==$phone ||
       (int)($p['PersonClientID']??$p['PersonClientId']??0)!==$newUid)exit(16);
  }
  $orders[$id]=$o;
  $results[]=['order_id'=>$id,'old_user_id'=>$oldUid,'verified_user_id'=>$newUid,
    'cloud_person_exists'=>$personId>0,'finance_untouched'=>true];
}
echo 'VERIFIED_LEGACY_BUYERS_PLAN='.json_encode($results,JSON_UNESCAPED_UNICODE).PHP_EOL;
if(!$commit){echo "FOUR_LEGACY_BUYER_RELINK_DRY_RUN_OK_NO_WRITES=yes\n";exit(0);}
$path='/tmp/vesta-bazara-order-sync.lock';$lock=is_file($path)?fopen($path,'r'):fopen($path,'x+');
if(!$lock || !flock($lock,LOCK_EX|LOCK_NB)){echo "WORKER_BUSY_NO_WRITES=yes\n";exit(17);}
try{
 if(get_option('vcar_sender_enabled',false))exit(18);
 $wpdb->query('START TRANSACTION');
 try{
   foreach($plan as $id=>$spec){
     [$oldUid,$newUid,$reason]=$spec;
     $o=$orders[$id];
     $before=[(float)$o->get_total(),(float)$o->get_discount_total(),(float)$o->get_shipping_total(),
       $o->get_payment_method(),$o->get_status(),(int)$o->get_meta('mahak_id')];
     if($o->get_meta('_vesta_legacy_original_customer_user_20261117',true)!=='')throw new RuntimeException('already_changed');
     $o->update_meta_data('_vesta_legacy_original_customer_user_20261117',$oldUid===0?'0':(string)$oldUid);
     $o->update_meta_data('_vesta_legacy_relink_reason_20261117','exact_otp_owner_and_full_profile_name');
     $o->set_customer_id($newUid);$o->save();
     $read=wc_get_order($id);
     $after=[(float)$read->get_total(),(float)$read->get_discount_total(),(float)$read->get_shipping_total(),
       $read->get_payment_method(),$read->get_status(),(int)$read->get_meta('mahak_id')];
     if($before!==$after || (int)$read->get_customer_id()!==$newUid)throw new RuntimeException('financial_or_buyer_readback_mismatch');
     $affected=$wpdb->query($wpdb->prepare(
       "UPDATE $t SET next_attempt=%d,updated_at=%d WHERE order_id=%d AND state='blocked' AND reason=%s AND attempts=0 AND submitted_at=0 AND remote_id=0",
        time(),time(),$id,$reason));
     if($affected!==1)throw new RuntimeException('outbox_invariant_changed');
   }
   $wpdb->query('COMMIT');
   echo "FOUR_WOO_CUSTOMER_LINKS_CORRECTED_WITHOUT_ERP_INVOICE_OR_RECEIPT_WRITES=yes\n";
 }catch(Throwable $e){
   $wpdb->query('ROLLBACK');
   echo "TRANSACTION_ROLLED_BACK_CHECK_BACKUP_REQUIRED=yes\n";exit(19);
 }
}finally{flock($lock,LOCK_UN);fclose($lock);}
