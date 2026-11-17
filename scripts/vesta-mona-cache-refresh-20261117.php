<?php
/**
 * Refresh exactly one stale WEB Bazara cache person name, only after exact
 * live Mahak Cloud identity readback. No cloud, order, invoice or receipt writes.
 * Dry-run by default. Called under paused protected sender and after DB backup.
 * It intentionally does not modify the legacy remote PersonClientId; that
 * must not be guessed or silently changed outside a confirmed vendor contract.
 */
error_reporting(E_ERROR|E_PARSE);ini_set('display_errors','0');
$_SERVER['HTTP_HOST']='vesta-cosmetics.ir';$_SERVER['SERVER_NAME']='vesta-cosmetics.ir';
$_SERVER['HTTPS']='on';$_SERVER['SERVER_PORT']='443';$_SERVER['REQUEST_URI']='/';
require '/var/www/html/wp-load.php';
global $wpdb;
$pid=12706969;$uid=2918;$orderId=105554;$admin=1;
$commit=getenv('VC_MONA_CACHE_COMMIT')==='yes';
if($commit && (getenv('VC_MONA_CACHE_BACKUP_OK')!=='yes' || get_option('vcar_sender_enabled',false))){
  echo "BACKUP_OR_SENDER_GUARD_NO_WRITES=yes\n";exit(21);
}
$o=wc_get_order($orderId);$user=get_user_by('id',$uid);
if(!$o||!$user||!vcar_eligible($o)||(int)$o->get_customer_id()!==$uid||!Vesta_Channel_Customers::customer($uid)){
  echo "WOO_ACCOUNT_ORDER_GUARD_NO_WRITES=yes\n";exit(22);
}
$actual=vcar_identity_normalize_name($o->get_billing_first_name().' '.$o->get_billing_last_name());
$profile=vcar_identity_normalize_name($user->first_name.' '.$user->last_name);
$phone=vesta_otp_phone((string)$o->get_billing_phone());
$owner=$phone?vesta_otp_existing_user($phone):false;
if(!$phone||$actual!==$profile || $actual===''||is_wp_error($owner)||(int)$owner!==$uid ||
  vesta_otp_phone((string)get_user_meta($uid,'billing_phone',true))!==$phone){
  echo "BILLING_PROFILE_PHONE_GUARD_NO_WRITES=yes\n";exit(23);
}
$api=new BazaraApi(true);$r=$api->get_all_data('',array('fromPersonVersion'=>0,'fromOrderVersion'=>0));
if(empty($r['success']) || !is_array($r['message']['People']??null)||!is_array($r['message']['Orders']??null)){
  echo "CLOUD_UNAVAILABLE_NO_WRITES=yes\n";exit(24);
}
$matches=[];$phoneMatches=[];$clientOther=[];$newOrders=[];
foreach($r['message']['People'] as $p){
 if(!empty($p['Deleted']))continue;
 if((int)($p['PersonId']??0)===$pid)$matches[]=$p;
 if(vesta_otp_phone((string)($p['Mobile']??''))===$phone)$phoneMatches[]=$p;
 if((int)($p['PersonClientId']??$p['PersonClientID']??0)===$uid)$clientOther[]=$p;
}
foreach($r['message']['Orders'] as $remote)if(empty($remote['Deleted']) && (int)($remote['OrderClientId']??0)===$orderId)$newOrders[]=$remote;
if(count($matches)!==1 || count($phoneMatches)!==1 || (int)($phoneMatches[0]['PersonId']??0)!==$pid ||
   count($clientOther)!==0 || count($newOrders)!==0){
 echo "EXISTING_CLOUD_PERSON_OR_INVOICE_CONFLICT_NO_WRITES=yes\n";exit(25);
}
$p=$matches[0];$cloud=vcar_identity_normalize_name(($p['FirstName']??'').' '.($p['LastName']??''));
$client=(int)($p['PersonClientID']??$p['PersonClientId']??0);
if($cloud!==$actual || $client!==$admin ||
  (int)get_user_meta($admin,'mahak_id',true)!==$pid ||
  (int)get_user_meta($uid,'mahak_id',true)>0) {
 echo "CLOUD_NAME_OR_LEGACY_ADMIN_LINK_CHANGED_NO_WRITES=yes\n";exit(26);
}
$table=$wpdb->prefix.'bazara_persons';
$local=$wpdb->get_row($wpdb->prepare("SELECT PersonId, PersonClientID, FirstName,LastName,Mobile,Deleted FROM $table WHERE PersonId=%d LIMIT 1",$pid),ARRAY_A);
if(!$local || (int)$local['Deleted']!==0 ||
   (int)$local['PersonClientID']!==$admin ||
   vesta_otp_phone((string)$local['Mobile'])!==$phone) {
 echo "LOCAL_PERSON_CACHE_IDENTITY_MISMATCH_NO_WRITES=yes\n";exit(27);
}
$old=vcar_identity_normalize_name($local['FirstName'].' '.$local['LastName']);
$newFirst=(string)$p['FirstName'];$newLast=(string)$p['LastName'];
echo 'CLOUD_AND_CACHE_RECONCILE_PLAN='.json_encode([
  'target_person_id'=>$pid,'buyer_uid'=>$uid,
  'cloud_name_correct'=>true,
  'cache_name_matches_cloud'=>$old===$cloud,
  'local_client_still_admin'=>(int)$local['PersonClientID']===$admin,
  'cloud_client_still_admin'=>true,
  'no_new_order_invoice'=>true,
  'no_person_duplicates'=>true
],JSON_UNESCAPED_UNICODE).PHP_EOL;
if($old===$cloud){
 echo "CACHE_ALREADY_MATCHES_CLOUD=yes\n";exit(0);
}
if($old!==vcar_identity_normalize_name('وستا علوی') || $newFirst==='' || $newLast===''){
 echo "OLD_CACHE_NAME_UNEXPECTED_NO_WRITES=yes\n";exit(28);
}
if(!$commit){echo "CACHE_REFRESH_DRYRUN_NO_WRITES=yes\n";exit(0);}
$lock='vesta_person_cache_correct_'.$pid;
if((int)$wpdb->get_var($wpdb->prepare('SELECT GET_LOCK(%s,5)',$lock))!==1){echo "LOCK_NOT_ACQUIRED_NO_WRITES=yes\n";exit(29);}
try {
  if(get_option('vcar_sender_enabled',false))exit(31);
  $updated=$wpdb->query($wpdb->prepare(
     "UPDATE $table SET FirstName=%s,LastName=%s WHERE PersonId=%d AND PersonClientID=%d AND Deleted=0 AND FirstName=%s AND LastName=%s",
     $newFirst,$newLast,$pid,$admin,$local['FirstName'],$local['LastName']
  ));
  if($updated!==1){echo "EXACT_ONE_PERSON_UPDATE_EXPECTED_ACTUAL=".(int)$updated." NO_OTHER_WRITES=yes\n";exit(32);}
  $after=$wpdb->get_row($wpdb->prepare("SELECT FirstName,LastName,PersonClientID FROM $table WHERE PersonId=%d AND Deleted=0",$pid),ARRAY_A);
  if(!$after || vcar_identity_normalize_name($after['FirstName'].' '.$after['LastName'])!==$cloud ||
      (int)$after['PersonClientID']!==$admin)exit(33);
  echo "EXACT_ONE_LOCAL_CACHE_PERSON_NAME_UPDATED_AND_VERIFIED=yes NO_INVOICE_ORDER_OR_CLOUD_WRITES=yes\n";
}finally{$wpdb->get_var($wpdb->prepare('SELECT RELEASE_LOCK(%s)',$lock));}
