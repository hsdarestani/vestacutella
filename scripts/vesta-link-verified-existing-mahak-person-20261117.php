<?php
/**
 * Fail-closed relinking of one known legacy admin-linked Mahak person to one OTP owner.
 * Runs read-only by default. Requires remote AND local Mahak names corrected first.
 * NEVER changes remote People, financial documents, customer names, or sends invoices.
 */
error_reporting(E_ERROR|E_PARSE);ini_set('display_errors','0');
$_SERVER['HTTP_HOST']='vesta-cosmetics.ir';$_SERVER['SERVER_NAME']='vesta-cosmetics.ir';$_SERVER['HTTPS']='on';$_SERVER['SERVER_PORT']='443';$_SERVER['REQUEST_URI']='/';
require '/var/www/html/wp-load.php';
global $wpdb;
$admin=1;$buyer=2918;$person=12706969;$orderId=105554;$legacyInvoiceOrder=105203;
$commit=getenv('VC_RELINK_COMMIT')==='yes';
if($commit && (getenv('VC_RELINK_BACKUP_VERIFIED')!=='yes' || get_option('vcar_sender_enabled',false))){
 echo "RELINK_BACKUP_OR_SENDER_GATE_FAILED_NO_WRITES=yes\n";exit(21);
}
$o=wc_get_order($orderId);$old=wc_get_order($legacyInvoiceOrder);
$user=get_user_by('id',$buyer);$adminUser=get_user_by('id',$admin);
if(!$o || !$old || !$user || !$adminUser || !Vesta_Channel_Customers::customer($buyer) ||
   !array_intersect((array)$adminUser->roles,['administrator','shop_manager']) ||
   (int)$o->get_customer_id()!==$buyer || (int)$old->get_customer_id()!==$buyer ||
   !vcar_eligible($o) || !vcar_eligible($old)){
 echo "ORDER_CUSTOMER_ROLE_OR_PAID_GUARD_FAILED_NO_WRITES=yes\n";exit(22);
}
$name=vcar_identity_normalize_name($o->get_billing_first_name().' '.$o->get_billing_last_name());
$profile=vcar_identity_normalize_name($user->first_name.' '.$user->last_name);
$oldName=vcar_identity_normalize_name($old->get_billing_first_name().' '.$old->get_billing_last_name());
$phone=vesta_otp_phone((string)$o->get_billing_phone());
$profilePhone=vesta_otp_phone((string)get_user_meta($buyer,'billing_phone',true));
$oldPhone=vesta_otp_phone((string)$old->get_billing_phone());
$owner=$phone?vesta_otp_existing_user($phone):false;
if(!$phone || !$name || $profile!==$name || $oldName!==$name || $profilePhone!==$phone || $oldPhone!==$phone ||
   !is_numeric($owner) || (int)$owner!==$buyer || is_wp_error($owner)){
 echo "BUYER_PHONE_OR_NAME_NOT_UNIQUELY_VERIFIED_NO_WRITES=yes\n";exit(23);
}
$currentAdminPerson=(int)get_user_meta($admin,'mahak_id',true);
$currentBuyerPerson=(int)get_user_meta($buyer,'mahak_id',true);
if(($currentAdminPerson!==$person && $currentAdminPerson!==0) ||
   ($currentBuyerPerson>0 && $currentBuyerPerson!==$person)){
 echo "LOCAL_PERSON_LINK_CHANGED_REQUIRE_REVIEW_NO_WRITES=yes\n";exit(24);
}
$existing=$wpdb->get_col($wpdb->prepare("SELECT DISTINCT user_id FROM {$wpdb->usermeta} WHERE meta_key='mahak_id' AND meta_value=%s",strval($person)));
foreach($existing as $uid)if(!in_array((int)$uid,[$admin,$buyer],true)){echo "ERP_PERSON_ALREADY_USED_BY_ANOTHER_USER_NO_WRITES=yes\n";exit(25);}
$api=new BazaraApi(true);
$r=$api->get_all_data('',array('fromPersonVersion'=>0,'fromOrderVersion'=>0));
$m=$r['message']??[];
if(empty($r['success']) || !is_array($m['People']??null) || !is_array($m['Orders']??null)){
 echo "CLOUD_READ_UNAVAILABLE_NO_WRITES=yes\n";exit(26);
}
$matches=[];$samePhone=[];
foreach($m['People'] as $p){
 if(!empty($p['Deleted']))continue;
 if((int)($p['PersonId']??0)===$person)$matches[]=$p;
 if(vesta_otp_phone((string)($p['Mobile']??''))===$phone)$samePhone[]=$p;
}
if(count($matches)!==1 || count($samePhone)!==1 || (int)$samePhone[0]['PersonId']!==$person){
 echo "CLOUD_PERSON_OR_PHONE_DUPLICATE_OR_MISSING_NO_WRITES=yes\n";exit(27);
}
$p=$matches[0];$cloudName=vcar_identity_normalize_name(($p['FirstName']??'').' '.($p['LastName']??''));
$client=(int)($p['PersonClientID']??$p['PersonClientId']??0);
if(!in_array($client,[$admin,$buyer],true)){
 echo "CLOUD_CLIENT_OWNER_CHANGED_NO_WRITES=yes\n";exit(28);
}
$legacyCloudInvoiceCount=0;$newCloudInvoiceCount=0;$personCount=0;
foreach($m['Orders'] as $r){
 if(!empty($r['Deleted']))continue;
 if((int)($r['PersonId']??0)===$person){$personCount++;}
 if((int)($r['OrderClientId']??0)===$legacyInvoiceOrder&&(int)($r['PersonId']??0)===$person)$legacyCloudInvoiceCount++;
 if((int)($r['OrderClientId']??0)===$orderId)$newCloudInvoiceCount++;
}
if($legacyCloudInvoiceCount!==1 || $newCloudInvoiceCount!==0 || (int)$o->get_meta('mahak_id')>0){
 echo "CLOUD_INVOICE_PRECONDITIONS_FAILED_NO_WRITES=yes\n";exit(29);
}
$local=$wpdb->get_row($wpdb->prepare("SELECT PersonId,FirstName,LastName,PersonClientId,Mobile FROM {$wpdb->prefix}bazara_persons WHERE PersonId=%d AND Deleted=0 LIMIT 1",$person),ARRAY_A);
if(!$local) {$local=$wpdb->get_row($wpdb->prepare("SELECT PersonId,FirstName,LastName,PersonClientID,Mobile FROM {$wpdb->prefix}bazara_persons WHERE PersonId=%d AND Deleted=0 LIMIT 1",$person),ARRAY_A);}
$localName=$local?vcar_identity_normalize_name(($local['FirstName']??'').' '.($local['LastName']??'')):'';
echo 'RELINK_VERIFIED_PLAN='.json_encode([
 'order_id'=>$orderId,'buyer_uid'=>$buyer,'existing_person_id'=>$person,
 'cloud_name_matches_real_buyer'=>$cloudName===$name,'local_cache_name_matches_real_buyer'=>$localName===$name,
 'cloud_client_id_legacy_admin'=>$client===$admin,'legacy_cloud_invoice_count'=>$legacyCloudInvoiceCount,
 'all_invoices_on_person'=>$personCount,'new_order_cloud_invoices'=>$newCloudInvoiceCount,
 'admin_meta_present'=>$currentAdminPerson===$person,'buyer_meta_present'=>$currentBuyerPerson===$person,
 'ready_to_link'=>($cloudName===$name && $localName===$name)
],JSON_UNESCAPED_UNICODE).' NO_ERP_FINANCIAL_WRITES=yes'.PHP_EOL;
if($cloudName!==$name || $localName!==$name){
 echo "AWAITING_CONFIRMED_CORRECTION_IN_CLOUD_AND_LOCAL_PERSON_CACHE_NO_WRITES=yes\n";
 exit(0);
}
if(!$commit){echo "SAFE_PERSON_RELINK_DRYRUN_READY=yes NO_WRITES=yes\n";exit(0);}
$lock='vesta_safe_existing_person_relink_'.$person;
if((int)$wpdb->get_var($wpdb->prepare("SELECT GET_LOCK(%s, 6)",$lock))!==1){echo "LINK_LOCK_BUSY_NO_WRITES=yes\n";exit(30);}
try{
 if(get_option('vcar_sender_enabled',false)){echo "SENDER_RESUMED_ABORT_NO_WRITES=yes\n";exit(31);}
 if((int)get_user_meta($buyer,'mahak_id',true)>0 && (int)get_user_meta($buyer,'mahak_id',true)!==$person)exit(32);
 if((int)get_user_meta($admin,'mahak_id',true)===$person)delete_user_meta($admin,'mahak_id',(string)$person);
 update_user_meta($buyer,'mahak_id',$person);
 update_user_meta($buyer,'_vesta_erp_cloud_verified_person_id',$person);
 update_user_meta($buyer,'_vesta_erp_cloud_verified_person_name',$cloudName);
 update_user_meta($buyer,'_vesta_erp_cloud_verified_person_at',gmdate('c'));
 update_user_meta($buyer,'_vesta_erp_person_legacy_client_uid',$client);
 if((int)get_user_meta($admin,'mahak_id',true)===$person ||
    (int)get_user_meta($buyer,'mahak_id',true)!==$person ||
    vcar_identity_guard(wc_get_order($orderId))!==''){
    echo "PERSON_LINK_READBACK_GUARD_FAILED_REQUIRE_REVIEW=yes\n";exit(33);
 }
 echo "EXISTING_ERP_PERSON_LINKED_TO_UNIQUELY_VERIFIED_BUYER=yes REMOTE_PERSON_AND_INVOICES_UNCHANGED=yes\n";
}finally{$wpdb->get_var($wpdb->prepare("SELECT RELEASE_LOCK(%s)",$lock));}
