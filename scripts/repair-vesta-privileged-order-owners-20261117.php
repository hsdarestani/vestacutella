<?php
/**
 * Reassign only three ALREADY CONFIRMED paid orders that were incorrectly tied to
 * the WordPress administrator rather than their uniquely OTP-verified customers.
 *
 * This script NEVER changes the accounting person, any invoice, receipt,
 * payment, line-item, tax, shipping, discount, stock, or site account role.
 * Dry-run unless VC_PRIV_OWNER_COMMIT=yes and VC_PRIV_BACKUP_VERIFIED=yes.
 * Existing remote invoices must be reconciled separately, not resubmitted.
 */
error_reporting(E_ERROR|E_PARSE);ini_set('display_errors','0');
$_SERVER['HTTP_HOST']='vesta-cosmetics.ir';$_SERVER['SERVER_NAME']='vesta-cosmetics.ir';
$_SERVER['HTTPS']='on';$_SERVER['SERVER_PORT']='443';$_SERVER['REQUEST_URI']='/';
require '/var/www/html/wp-load.php';
if(!class_exists('Vesta_Channel_Customers')||!function_exists('vesta_otp_phone')||
 !function_exists('vesta_otp_existing_user')||!function_exists('vcar_identity_normalize_name'))exit(20);
global $wpdb;
if(get_option('vcar_sender_enabled',false)){echo "SENDER_NOT_PAUSED_NO_WRITES=yes\n";exit(21);}
$commit=getenv('VC_PRIV_OWNER_COMMIT')==='yes';
if($commit && getenv('VC_PRIV_BACKUP_VERIFIED')!=='yes'){echo "BACKUP_REQUIRED_NO_WRITES=yes\n";exit(22);}
$ids=[105208,105203,105052];
$stats=['ready'=>0,'repaired'=>0,'already_repaired'=>0,'skipped'=>0,'blocked'=>0];
foreach($ids as $id){
 $lock='vesta_channel_order_'.$id;
 if((int)$wpdb->get_var($wpdb->prepare('SELECT GET_LOCK(%s, 5)',$lock))!==1){echo "BUSY_ORDER=$id\n";$stats['blocked']++;continue;}
 try{
  $o=wc_get_order($id);
  if(!$o||!vcar_eligible($o)||$o->get_type()!=='shop_order'){$stats['skipped']++;echo "ORDER_INELIGIBLE=$id\n";continue;}
  $name=vcar_identity_normalize_name($o->get_billing_first_name().' '.$o->get_billing_last_name());
  $phone=vesta_otp_phone((string)$o->get_billing_phone());
  $old=(int)$o->get_customer_id();
  $owner=$phone?vesta_otp_existing_user($phone):false;
  if(!$phone||!is_numeric($owner)||(int)$owner<=0||is_wp_error($owner)){$stats['blocked']++;echo "PHONE_NOT_UNIQUE=$id\n";continue;}
  $target=(int)$owner;$user=get_user_by('id',$target);
  $targetName=$user?vcar_identity_normalize_name($user->first_name.' '.$user->last_name):'';
  $storedPhone=vesta_otp_phone((string)get_user_meta($target,'billing_phone',true));
  $email=trim((string)$o->get_billing_email());
  $emailOwner=$email?get_user_by('email',$email):false;
  if($target===1 || !$user || !Vesta_Channel_Customers::customer($target) || $name==='' ||
     $targetName!==$name || $storedPhone!==$phone || ($email!==''&&!is_email($email)) ||
     ($emailOwner && (int)$emailOwner->ID!==$target && (int)$emailOwner->ID!==1)){
     $stats['blocked']++;echo "IDENTITY_CONFLICT=$id\n";continue;
  }
  if($old===$target){
    $stats['already_repaired']++;echo "ALREADY_CORRECT=$id\n";continue;
  }
  if($old!==1){$stats['blocked']++;echo "OLD_OWNER_DRIFT=$id\n";continue;}
  $oldUser=get_user_by('id',$old);
  if(!$oldUser||!array_intersect((array)$oldUser->roles,['administrator','shop_manager'])){
     $stats['blocked']++;echo "EXPECTED_ADMIN_NOT_PRIVILEGED=$id\n";continue;
  }
  $existingCloudInvoice=(int)$o->get_meta('mahak_id')>0;
  $stats['ready']++;
  echo "PLAN_PRIV_ORDER=$id ADMIN_UID=1 VERIFIED_CUSTOMER_UID=$target EXISTING_ACCOUNTING_INVOICE=".(int)$existingCloudInvoice." NO_ERP_WRITES=yes\n";
  if(!$commit)continue;
  if(get_option('vcar_sender_enabled',false)){echo "SENDER_REENABLED_ABORT=yes\n";exit(31);}
  $before=[(float)$o->get_total(),(float)$o->get_shipping_total(),(float)$o->get_discount_total(),
     $o->get_payment_method(),$o->get_currency(),$o->get_status(),count($o->get_items('line_item')),
     (int)$o->get_meta('mahak_id')];
  $o->set_customer_id($target);
  $o->update_meta_data('_vesta_identity_previous_customer_id',1);
  $o->update_meta_data('_vesta_identity_repaired_at',gmdate('c'));
  $o->update_meta_data('_vesta_identity_repair_reason','legacy_admin_customer_assignment');
  $o->update_meta_data('_vesta_accounting_erp_customer_reconciliation','required');
  if($emailOwner && (int)$emailOwner->ID===1)$o->update_meta_data('_vesta_customer_billing_email_review','legacy_admin_email_in_order');
  $o->delete_meta_data('_vesta_account_issue');
  $o->save();
  $after=wc_get_order($id);
  $post=[(float)$after->get_total(),(float)$after->get_shipping_total(),(float)$after->get_discount_total(),
     $after->get_payment_method(),$after->get_currency(),$after->get_status(),count($after->get_items('line_item')),
     (int)$after->get_meta('mahak_id')];
  if((int)$after->get_customer_id()!==$target || $before!==$post) {
    echo "POST_REPAIR_INVARIANT_FAILED=$id\n";exit(40);
  }
  $stats['repaired']++;
  echo "REPAIRED_PRIV_ORDER=$id TARGET_UID=$target CUSTOMER_OWNER_READBACK=yes FINANCES_AND_ACCOUNTING_IDS_UNCHANGED=yes\n";
 }finally{$wpdb->get_var($wpdb->prepare('SELECT RELEASE_LOCK(%s)',$lock));}
}
echo 'PRIV_OWNER_REPAIR_SUMMARY='.json_encode($stats).' COMMIT='.(int)$commit.' NO_ERP_FINANCIAL_WRITES=yes'.PHP_EOL;
