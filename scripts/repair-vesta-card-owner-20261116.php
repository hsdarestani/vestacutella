<?php
/**
 * Conservative repair of seven verified card-transfer Woo order-account collisions.
 * Does NOT alter ERP invoices/receipts, prices, inventory, gateway settlements or dates.
 * Dry run by default; commit only behind VC_OWNER_REPAIR_COMMIT=yes and paused sender.
 */
error_reporting(E_ERROR|E_PARSE);ini_set('display_errors','0');
$_SERVER['HTTP_HOST']='vesta-cosmetics.ir';$_SERVER['SERVER_NAME']='vesta-cosmetics.ir';
$_SERVER['HTTPS']='on';$_SERVER['SERVER_PORT']='443';$_SERVER['REQUEST_URI']='/';
require '/var/www/html/wp-load.php';
if (!class_exists('Vesta_Channel_Customers') || !function_exists('vesta_otp_existing_user') ||
    !function_exists('vesta_otp_phone') || !function_exists('vcar_identity_guard')) {
    echo "REPAIR_DEPENDENCY_MISSING\n";exit(20);
}
if (get_option('vcar_sender_enabled', false)) {echo "SENDER_NOT_PAUSED_ABORT\n";exit(21);}
$commit=(getenv('VC_OWNER_REPAIR_COMMIT')==='yes');
$target=array(105460,105458,105456,105454,105452,105450,105361);
$expectedOldUser=3055;$expectedOldPerson=12761457;
$run=['candidates'=>0,'eligible'=>0,'planned_new'=>0,'planned_existing'=>0,'skipped'=>0,'updated'=>0,'errors'=>0];
$normal=function($v){return vcar_identity_normalize_name($v);};
$plans=[];
foreach($target as $id){
 $o=wc_get_order($id);
 if(!$o||!vcar_eligible($o)||$o->get_payment_method()!=='pcs_smart_cardpay'){
   echo 'SKIP_INVALID_ORDER='.$id."\n";$run['skipped']++;continue;
 }
 $run['candidates']++;
 $old=(int)$o->get_customer_id();
 if($old!==$expectedOldUser) {
   echo 'SKIP_NOT_ORIGINAL_OWNER='.$id.' OWNER_ID='.$old."\n";$run['skipped']++;continue;
 }
 $recordedPerson=(int)get_user_meta($old,'mahak_id',true);
 if($recordedPerson!==$expectedOldPerson){echo 'SKIP_SOURCE_PERSON_CHANGED='.$id."\n";$run['skipped']++;continue;}
 $name=$normal($o->get_billing_first_name().' '.$o->get_billing_last_name());
 $phone=vesta_otp_phone($o->get_billing_phone());
 if(!$phone || !$name){echo 'SKIP_MISSING_VERIFIABLE_BILLING='.$id."\n";$run['skipped']++;continue;}
 $owner=vesta_otp_existing_user($phone);
 if(is_wp_error($owner)){echo 'SKIP_AMBIGUOUS_PHONE='.$id."\n";$run['skipped']++;continue;}
 if((int)$owner===$old){echo 'SKIP_PHONE_STILL_OWNED_BY_ORIGINAL='.$id."\n";$run['skipped']++;continue;}
 $email=trim((string)$o->get_billing_email());
 if($email!=='' && !is_email($email)){echo 'SKIP_INVALID_EMAIL='.$id."\n";$run['skipped']++;continue;}
 $emailOwner=$email?get_user_by('email',$email):false;
 if($emailOwner && $owner && (int)$emailOwner->ID!==(int)$owner){
   echo 'SKIP_PHONE_EMAIL_CONFLICT='.$id."\n";$run['skipped']++;continue;
 }
 if($emailOwner && !$owner){echo 'SKIP_EMAIL_EXISTING_WITH_NEW_PHONE='.$id."\n";$run['skipped']++;continue;}
 $hasExisting=(int)$owner>0;
 if($hasExisting){
   if(!Vesta_Channel_Customers::customer((int)$owner)){echo 'SKIP_NON_CUSTOMER_OWNER='.$id."\n";$run['skipped']++;continue;}
   $u=get_user_by('id',(int)$owner);
   $existingName=$normal($u->first_name.' '.$u->last_name);
   if($existingName!=='' && $existingName!==$name){
     echo 'SKIP_EXISTING_PHONE_NAME_MISMATCH='.$id."\n";$run['skipped']++;continue;
   }
 }
 $plans[$id]=['owner'=>$old,'newOwner'=>$hasExisting?(int)$owner:0,'new'=>$hasExisting?false:true,'billName'=>$name,'phone'=>$phone];
 $run['eligible']++;$run[$hasExisting?'planned_existing':'planned_new']++;
 echo 'PLAN ORDER='.$id.' PREVIOUS_WOO_UID='.$old.' TARGET='.($hasExisting?'existing':'new').' EXPECTED_ERP_PERSON_REQUIRES_REVIEW=yes'."\n";
}
if(!$commit){echo 'DRY_RUN='.json_encode($run).' NO_WRITES=yes'.PHP_EOL;exit(0);}
if(count($plans)<1){echo 'NO_SAFE_REASSIGNMENTS=yes'.PHP_EOL;exit(0);}
if(!getenv('VC_OWNER_BACKUP_VERIFIED')){echo 'BACKUP_FLAG_REQUIRED_ABORT=yes'.PHP_EOL;exit(22);}
global $wpdb;
foreach($plans as $id=>$plan){
 $lock='vesta_identity_repair_'.$id;
 if((int)$wpdb->get_var($wpdb->prepare('SELECT GET_LOCK(%s, 5)',$lock))!==1){$run['errors']++;echo 'LOCK_FAILED='.$id.PHP_EOL;continue;}
 try{
   $o=wc_get_order($id);
   if(!$o || (int)$o->get_customer_id()!==$expectedOldUser){$run['skipped']++;continue;}
   if(get_option('vcar_sender_enabled',false)){echo 'SENDER_REENABLED_ABORT'.PHP_EOL;exit(30);}
   $financial=[$o->get_total(),$o->get_shipping_total(),$o->get_discount_total(),$o->get_payment_method(),$o->get_currency(),$o->get_status(),count($o->get_items('line_item'))];
   // Re-run resolution under an order lock, allowing reuse of uniquely verified existing OTP account.
   $resolved=Vesta_Channel_Customers::resolve($o);
   if(is_wp_error($resolved)||!(int)$resolved||!Vesta_Channel_Customers::customer((int)$resolved)){
      echo 'RESOLUTION_BLOCKED='.$id.' REASON='.(is_wp_error($resolved)?sanitize_key($resolved->get_error_code()):'invalid_customer').PHP_EOL;
      $run['errors']++;continue;
   }
   $newId=(int)$resolved;
   if($newId===$expectedOldUser){echo 'OLD_ACCOUNT_REUSED_ABORT='.$id.PHP_EOL;$run['errors']++;continue;}
   $existing=$plan['newOwner']>0;
   if($existing&&$newId!==$plan['newOwner']){echo 'RESOLVED_ACCOUNT_DRIFT='.$id.PHP_EOL;$run['errors']++;continue;}
   $fname=trim((string)get_user_meta($newId,'first_name',true));
   $lname=trim((string)get_user_meta($newId,'last_name',true));
   $expectedF=trim((string)$o->get_billing_first_name());
   $expectedL=trim((string)$o->get_billing_last_name());
   $currName=$normal($fname.' '.$lname);
   $expectName=$normal($expectedF.' '.$expectedL);
   if($currName!=='' && $currName!==$expectName){echo 'TARGET_NAME_DRIFT='.$id.PHP_EOL;$run['errors']++;continue;}
   // First/last names are populated only where absent, never replacing existing customer data.
   if($fname==='')update_user_meta($newId,'first_name',$expectedF);
   if($lname==='')update_user_meta($newId,'last_name',$expectedL);
   if(!get_user_meta($newId,'billing_first_name',true))update_user_meta($newId,'billing_first_name',$expectedF);
   if(!get_user_meta($newId,'billing_last_name',true))update_user_meta($newId,'billing_last_name',$expectedL);
   $o->set_customer_id($newId);
   $o->update_meta_data('_vesta_identity_previous_customer_id',$expectedOldUser);
   $o->update_meta_data('_vesta_identity_repaired_at',gmdate('c'));
   $o->update_meta_data('_vesta_identity_repair_reason','cardpay_wrong_legacy_woo_customer');
   $o->update_meta_data('_vesta_accounting_erp_customer_reconciliation','required');
   $o->save();
   $after=wc_get_order($id);
   $newFinancial=[$after->get_total(),$after->get_shipping_total(),$after->get_discount_total(),$after->get_payment_method(),$after->get_currency(),$after->get_status(),count($after->get_items('line_item'))];
   if((int)$after->get_customer_id()!==$newId || $financial!=$newFinancial) {
     echo 'POST_REPAIR_FINANCIAL_OR_OWNER_INVARIANT_FAILED='.$id.PHP_EOL;exit(40);
   }
   $run['updated']++;
   echo 'REPAIRED_WOO_ORDER='.$id.' OLD_UID='.$expectedOldUser.' NEW_UID='.$newId.' FINANCIAL_INVARIANTS=yes ERP_INVOICE_UNCHANGED=yes'.PHP_EOL;
 }finally{$wpdb->get_var($wpdb->prepare('SELECT RELEASE_LOCK(%s)',$lock));}
}
echo 'REPAIR_RESULT='.json_encode($run).' ERP_INVOICES_UNCHANGED=yes'.PHP_EOL;
