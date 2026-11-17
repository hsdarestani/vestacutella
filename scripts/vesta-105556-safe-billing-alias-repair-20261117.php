<?php
/**
 * Vesta order 105556 exact identity correction:
 * Strip ONLY legacy display suffix " (زیبایی)" from this specific order's
 * billing last_name when OTP owner, original name, ERP cloud and cache all
 * match unique existing verified customer 2918 and person 12706969.
 *
 * Dry-run unless VC_105556_COMMIT=yes and backup and protected sender gate.
 * Does not send invoices, change price/discount/coupon/payment, or change
 * any customer profile or cloud People record.
 */
error_reporting(E_ERROR|E_PARSE);ini_set('display_errors','0');
$_SERVER['HTTP_HOST']='vesta-cosmetics.ir';$_SERVER['SERVER_NAME']='vesta-cosmetics.ir';$_SERVER['HTTPS']='on';$_SERVER['SERVER_PORT']='443';$_SERVER['REQUEST_URI']='/';
require '/var/www/html/wp-load.php';
global $wpdb;
$id=105556;$uid=2918;$pid=12706969;
$commit=getenv('VC_105556_COMMIT')==='yes';
if($commit && (getenv('VC_105556_BACKUP_VERIFIED')!=='yes' || get_option('vcar_sender_enabled',false))) {
 echo "BACKUP_OR_SENDER_GUARD_FAILED_NO_CHANGES=yes\n";exit(20);
}
$o=wc_get_order($id);$u=get_user_by('id',$uid);
if(!$o || !$u || (int)$o->get_customer_id()!==$uid || !vcar_eligible($o) ||
 $o->get_payment_method()!=='wc_zibal' || $o->get_currency()!=='IRT' ||
 $o->get_status()!=='processing' || !$o->get_date_paid() ||
 !$o->get_transaction_id() ||
 abs((float)$o->get_total()-2250)>0.01 ||
 abs((float)$o->get_discount_total()-447750)>0.01 ||
 abs((float)$o->get_shipping_total())>0.01 ||
 (int)$o->get_meta('mahak_id')!==0 ||
 (int)$o->get_meta('_vcar_cloud_invoice_id')!==0 ||
 (int)get_user_meta($uid,'mahak_id',true)!==$pid ||
 (int)get_user_meta(1,'mahak_id',true)!==0){
 echo "EXPECTED_ORDER_PAYMENT_OR_OWNER_INVARIANT_FAILED_NO_CHANGES=yes\n";exit(21);
}
$items=$o->get_items('line_item');
if(count($items)!==1)exit(22);
$item=reset($items);
if((float)$item->get_quantity()!==6.0 ||
 abs((float)$item->get_subtotal()-450000)>0.01||
 abs((float)$item->get_total()-2250)>0.01 ||
 count($o->get_items('fee'))!==0)exit(23);
if(!Vesta_Channel_Customers::customer($uid))exit(24);
$first=vcar_identity_normalize_name($o->get_billing_first_name());
$last=vcar_identity_normalize_name($o->get_billing_last_name());
$firstProfile=vcar_identity_normalize_name($u->first_name);
$lastProfile=vcar_identity_normalize_name($u->last_name);
$suffix=' (زیبایی)';
if($first!==$firstProfile || $last!==$lastProfile.$suffix ||
 $lastProfile==='' || vcar_identity_normalize_name($u->first_name.' '.$u->last_name)!==
    vcar_identity_normalize_name('منا علوی')) {
 echo "BILLING_ALIAS_NOT_EXACT_EXPECTED_VALUE_NO_CHANGES=yes\n";exit(25);
}
$phone=vesta_otp_phone((string)$o->get_billing_phone());$owner=$phone?vesta_otp_existing_user($phone):false;
if(!$phone||is_wp_error($owner)||(int)$owner!==$uid||
  vesta_otp_phone((string)get_user_meta($uid,'billing_phone',true))!==$phone) {
 echo "OTP_UNIQUE_OWNER_NOT_VERIFIED_NO_CHANGES=yes\n";exit(26);
}
$api=new BazaraApi(true);
$data=$api->get_all_data('',array('fromPersonVersion'=>0,'fromOrderVersion'=>0));
if(empty($data['success'])||!is_array($data['message']['People']??null)||!is_array($data['message']['Orders']??null))exit(27);
$person=[];$phoneCount=0;$remoteOrderCount=0;
foreach($data['message']['People'] as $p){
 if(!empty($p['Deleted']))continue;
 if((int)($p['PersonId']??0)===$pid)$person[]=$p;
 if(vesta_otp_phone((string)($p['Mobile']??''))===$phone)$phoneCount++;
}
foreach($data['message']['Orders'] as $r)
 if(empty($r['Deleted'])&&(int)($r['OrderClientId']??0)===$id)$remoteOrderCount++;
if(count($person)!==1||$phoneCount!==1||$remoteOrderCount!==0||
 vcar_identity_normalize_name(($person[0]['FirstName']??'').' '.($person[0]['LastName']??''))!==
 vcar_identity_normalize_name($u->first_name.' '.$u->last_name)) {
 echo "MAHAK_CLOUD_PERSON_OR_INVOICE_NOT_UNIQUE_NO_CHANGES=yes\n";exit(28);
}
$cache=$wpdb->get_row($wpdb->prepare("SELECT FirstName,LastName,Deleted FROM {$wpdb->prefix}bazara_persons WHERE PersonId=%d",$pid),ARRAY_A);
if(!$cache||!empty($cache['Deleted'])||
 vcar_identity_normalize_name($cache['FirstName'].' '.$cache['LastName'])!==
 vcar_identity_normalize_name($u->first_name.' '.$u->last_name))exit(29);
$t=Vesta_Accounting_Reliability::table();
$q=$wpdb->get_row($wpdb->prepare("SELECT state,reason,attempts,submitted_at,remote_id FROM $t WHERE order_id=%d",$id),ARRAY_A);
if(!$q || $q['state']!=='blocked'||$q['reason']!=='customer_erp_name_mismatch'||
 (int)$q['attempts']!==0||(int)$q['submitted_at']!==0||(int)$q['remote_id']!==0||
 (int)$wpdb->get_var($wpdb->prepare("SELECT COUNT(*) FROM {$wpdb->prefix}bazara_orders WHERE OrderClientId=%d",$id))!==0){
 echo "ORDER_ALREADY_IN_DELIVERY_OR_CLOUD_CACHE_NO_CHANGES=yes\n";exit(30);
}
$settings=get_option('bazara_visitor_settings',[]);
$bank=vcar_bank($settings,$o->get_payment_method());
if(!$bank)exit(31);
if(vcar_identity_guard($o)!=='customer_erp_name_mismatch')exit(32);
echo 'CANARY_105556_PREVIEW='.json_encode([
 'order_id'=>$id,'buyer_uid'=>$uid,'erp_person_id'=>$pid,
 'otp_phone_unique'=>true,'matched_name_without_alias'=>true,
 'discount_toman'=>447750,'paid_total_toman'=>2250,'shipping_toman'=>0,
 'cloud_invoice_count'=>0,'prior_submission_attempts'=>0,
 'billing_name_correction_only'=>true
],JSON_UNESCAPED_UNICODE).PHP_EOL;
if(!$commit){echo "BILLING_ALIAS_FIX_READONLY_PREVIEW_OK=yes\n";exit(0);}
$lock='vesta_105556_billing_alias_fix';
if((int)$wpdb->get_var($wpdb->prepare("SELECT GET_LOCK(%s,5)",$lock))!==1)exit(33);
try {
 if(get_option('vcar_sender_enabled',false))exit(34);
 $before=[(float)$o->get_total(),(float)$o->get_discount_total(),(float)$o->get_shipping_total(),
  (float)$item->get_total(),$o->get_payment_method(),$o->get_transaction_id(),$o->get_status(),
  (int)$o->get_customer_id(),(int)$o->get_meta('mahak_id')];
 $o->update_meta_data('_vesta_original_billing_last_name_105556',$o->get_billing_last_name());
 $o->update_meta_data('_vesta_accounting_identity_name_fix_reason','verified_otp_owner_checkout_alias_20261117');
 $o->set_billing_last_name($u->last_name);
 $o->save();
 $read=wc_get_order($id);$line=reset($read->get_items('line_item'));
 $after=[(float)$read->get_total(),(float)$read->get_discount_total(),(float)$read->get_shipping_total(),
  (float)$line->get_total(),$read->get_payment_method(),$read->get_transaction_id(),$read->get_status(),
  (int)$read->get_customer_id(),(int)$read->get_meta('mahak_id')];
 if($before!==$after || vcar_identity_guard($read)!=='' ||
    Vesta_Accounting_Reliability::preflight($read,$bank)!=='') {
  echo "POST_EDIT_INVARIANT_FAILED_REVIEW_REQUIRED=yes\n";exit(35);
 }
 echo "ORDER_105556_BILLING_NAME_CANONICALIZED_AND_READBACK_VERIFIED=yes ALL_FINANCIAL_AND_BUYER_FIELDS_UNCHANGED=yes\n";
}finally{$wpdb->get_var($wpdb->prepare("SELECT RELEASE_LOCK(%s)",$lock));}
