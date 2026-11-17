<?php
/**
 * Fill ONLY missing Woo customer profile first/last name and billing phone from a
 * verified, paid, OTP-owned customer order. No order, invoice, Mahak, inventory
 * or product writes. Dry run by default; explicit, bounded commit only.
 * Use only after a verified private DB backup.
 */
error_reporting(E_ERROR|E_PARSE);ini_set('display_errors','0');set_time_limit(0);
$_SERVER['HTTP_HOST']='vesta-cosmetics.ir';$_SERVER['SERVER_NAME']='vesta-cosmetics.ir';
$_SERVER['HTTPS']='on';$_SERVER['SERVER_PORT']='443';$_SERVER['REQUEST_URI']='/';
require '/var/www/html/wp-load.php';
if(!class_exists('Vesta_Channel_Customers') || !function_exists('vesta_otp_phone') ||
   !function_exists('vesta_otp_existing_user') || !function_exists('vcar_identity_normalize_name') ||
   !function_exists('vcar_eligible'))exit(20);
global $wpdb;
$commit=getenv('VC_PROFILE_ENRICH_COMMIT')==='yes';
$max=max(1,min(10,(int)(getenv('VC_PROFILE_ENRICH_MAX')?:5)));
$lock='vesta_verified_profile_enrichment';
if((int)$wpdb->get_var($wpdb->prepare('SELECT GET_LOCK(%s,3)',$lock))!==1){echo "PROFILE_LOCK_UNAVAILABLE=yes\n";exit(21);}
$stats=['review'=>0,'skipped'=>0,'eligible'=>0,'updated'=>0,'missing_name'=>0,'conflict'=>0];
try {
 $ids=$wpdb->get_col("SELECT ID FROM {$wpdb->posts} WHERE post_type='shop_order' AND post_date_gmt >= '2026-11-01 00:00:00' ORDER BY ID DESC LIMIT 700");
 $seen=[];
 foreach($ids as $id) {
   if($stats['eligible'] >= $max)break;
   $o=wc_get_order((int)$id);if(!vcar_eligible($o))continue;
   $uid=(int)$o->get_customer_id();
   if(!$uid||isset($seen[$uid]))continue;$seen[$uid]=true;
   if(!Vesta_Channel_Customers::customer($uid)){$stats['skipped']++;continue;}
   if((int)get_user_meta($uid,'mahak_id',true)>0 ||
      get_user_meta($uid,'_vesta_person_provision_attempt',true)){$stats['skipped']++;continue;}
   $u=get_user_by('id',$uid);
   if(!$u||strtotime((string)$u->user_registered.' UTC')<strtotime('2026-11-01 00:00:00 UTC')){$stats['skipped']++;continue;}
   $first=trim((string)$o->get_billing_first_name());$last=trim((string)$o->get_billing_last_name());
   $name=vcar_identity_normalize_name($first.' '.$last);
   if($first===''||$last===''||$name===''){$stats['missing_name']++;continue;}
   if(trim((string)get_user_meta($uid,'first_name',true))!=='' ||
      trim((string)get_user_meta($uid,'last_name',true))!==''){$stats['conflict']++;continue;}
   $profileBillName=vcar_identity_normalize_name((string)get_user_meta($uid,'billing_first_name',true).' '.(string)get_user_meta($uid,'billing_last_name',true));
   if($profileBillName!=='' && $profileBillName!==$name){$stats['conflict']++;continue;}
   $phone=vesta_otp_phone((string)$o->get_billing_phone());
   if(!$phone){$stats['review']++;continue;}
   $owner=vesta_otp_existing_user($phone);
   if(is_wp_error($owner)||(int)$owner!==$uid){$stats['review']++;continue;}
   $storedRaw=trim((string)get_user_meta($uid,'billing_phone',true));
   if($storedRaw!=='' && vesta_otp_phone($storedRaw)!==$phone){$stats['conflict']++;continue;}
   $email=trim((string)$o->get_billing_email());
   if($email!==''&&(!is_email($email)||(($eu=get_user_by('email',$email))&&(int)$eu->ID!==$uid))){$stats['review']++;continue;}
   // Require every associated order (up to 99) to agree on name and phone; no ambiguous account correction.
   $linked=wc_get_orders(['customer_id'=>$uid,'limit'=>100,'return'=>'ids','orderby'=>'ID','order'=>'DESC']);
   if(count($linked)===100){$stats['review']++;continue;}
   $allAgree=true;
   foreach($linked as $linkedId) {
     $x=wc_get_order($linkedId);if(!$x)continue;
     $xn=vcar_identity_normalize_name($x->get_billing_first_name().' '.$x->get_billing_last_name());
     $xp=vesta_otp_phone((string)$x->get_billing_phone());
     if(($xn!==''&&$xn!==$name)||($xp&&$xp!==$phone)){$allAgree=false;break;}
   }
   if(!$allAgree){$stats['conflict']++;continue;}
   $stats['eligible']++;
   echo 'PROFILE_SAFE_CANDIDATE ORDER='.(int)$id.' UID='.$uid.' BILLING_PHONE_EMPTY='.(int)($storedRaw==='').PHP_EOL;
   if(!$commit)continue;
   // Revalidate OTP ownership immediately before any local profile write.
   $again=vesta_otp_existing_user($phone);
   if(is_wp_error($again)||(int)$again!==$uid)throw new RuntimeException('OTP_OWNER_CHANGED');
   if(get_user_meta($uid,'first_name',true)!==''||get_user_meta($uid,'last_name',true)!=='')throw new RuntimeException('PROFILE_CHANGED_DURING_ENRICH');
   if(update_user_meta($uid,'first_name',$first)===false && get_user_meta($uid,'first_name',true)!==$first)throw new RuntimeException('FIRST_NAME_WRITE_FAILED');
   if(update_user_meta($uid,'last_name',$last)===false && get_user_meta($uid,'last_name',true)!==$last)throw new RuntimeException('LAST_NAME_WRITE_FAILED');
   if(!get_user_meta($uid,'billing_first_name',true))update_user_meta($uid,'billing_first_name',$first);
   if(!get_user_meta($uid,'billing_last_name',true))update_user_meta($uid,'billing_last_name',$last);
   if($storedRaw==='')update_user_meta($uid,'billing_phone',$o->get_billing_phone());
   update_user_meta($uid,'_vesta_profile_verified_order_id',(int)$id);
   update_user_meta($uid,'_vesta_profile_verified_at',gmdate('c'));
   $nu=get_user_by('id',$uid);
   if(vcar_identity_normalize_name($nu->first_name.' '.$nu->last_name)!==$name ||
      vesta_otp_phone((string)get_user_meta($uid,'billing_phone',true))!==$phone)
      throw new RuntimeException('READBACK_FAILED');
   $stats['updated']++;
   echo 'PROFILE_VERIFIED_ENRICHED ORDER='.(int)$id.' UID='.$uid.' NO_ORDER_OR_FINANCIAL_WRITES=yes'.PHP_EOL;
 }
 echo 'PROFILE_ENRICH_SUMMARY='.json_encode($stats).' COMMIT='.(int)$commit.' NO_MAHAK_INVOICE_PRODUCT_OR_MEDIA_WRITES=yes'.PHP_EOL;
} catch(Throwable $e) {
 echo 'PROFILE_ENRICH_FAILED_CLASS='.preg_replace('/[^A-Za-z]/','',get_class($e)).PHP_EOL;exit(30);
} finally {
 $wpdb->get_var($wpdb->prepare('SELECT RELEASE_LOCK(%s)',$lock));
}
