<?php
/**
 * Bounded, one-shot, fail-closed Mahak person registration for confirmed Woo users.
 * It NEVER submits/replays invoices, edits historic People or merges customer accounts.
 * Remote person creation is reserved in usermeta before the first attempt; ambiguous results never auto-retry.
 */
error_reporting(E_ERROR|E_PARSE);ini_set('display_errors','0');set_time_limit(0);
$_SERVER['HTTP_HOST']='vesta-cosmetics.ir';$_SERVER['SERVER_NAME']='vesta-cosmetics.ir';
$_SERVER['HTTPS']='on';$_SERVER['SERVER_PORT']='443';$_SERVER['REQUEST_URI']='/';
require '/var/www/html/wp-load.php';
if(!class_exists('BazaraApi')||!class_exists('Vesta_Channel_Customers')||!function_exists('vesta_otp_phone')||
   !function_exists('vesta_otp_existing_user')||!function_exists('vcar_identity_guard'))exit(20);
global $wpdb;
$max=max(1,min(5,(int)(getenv('VC_PERSON_MAX_BATCH')?:1)));
$globalLock='vesta_ma_hak_person_provision';
if((int)$wpdb->get_var($wpdb->prepare('SELECT GET_LOCK(%s, 3)',$globalLock))!==1){echo "PERSON_WORKER_BUSY=yes\n";exit(0);}
try{
 $api=new BazaraApi(true);
 $r=$api->get_all_data('',array('fromPersonVersion'=>0));
 $people=$r['message']['People']??null;
 if(!is_array($r)||empty($r['success'])||!is_array($people))throw new RuntimeException('cloud_people_unavailable');
 $cloud=[];
 foreach($people as $p){
   if(!empty($p['Deleted']))continue;
   $client=(int)($p['PersonClientID']??$p['PersonClientId']??0);
   if($client>0)$cloud['client'][$client][]=$p;
   $phone=vesta_otp_phone((string)($p['Mobile']??''));
   if($phone)$cloud['mobile'][$phone][]=$p;
 }
 $ids=$wpdb->get_col("SELECT ID FROM {$wpdb->posts} WHERE post_type='shop_order' AND post_date_gmt>='2026-11-01 00:00:00' ORDER BY ID DESC LIMIT 700");
 $n=0;$review=0;$reserved=0;$seen=[];
 foreach($ids as $id){
    if($n>=$max)break;
    $o=wc_get_order((int)$id);if(!vcar_eligible($o))continue;
    $uid=(int)$o->get_customer_id();if(!$uid||isset($seen[$uid]))continue;$seen[$uid]=1;
    if((int)get_user_meta($uid,'mahak_id',true)>0 || get_user_meta($uid,'_vesta_person_provision_attempt',true))continue;
    if(!Vesta_Channel_Customers::customer($uid))continue;
    $u=get_user_by('id',$uid);if(!$u)continue;
    $bill=vcar_identity_normalize_name($o->get_billing_first_name().' '.$o->get_billing_last_name());
    $personName=vcar_identity_normalize_name($u->first_name.' '.$u->last_name);
    if($bill===''||$personName!==$bill){$review++;continue;}
    $phone=vesta_otp_phone((string)$o->get_billing_phone());
    $profilePhone=vesta_otp_phone((string)get_user_meta($uid,'billing_phone',true));
    if(!$phone||$profilePhone!==$phone){$review++;continue;}
    $owner=vesta_otp_existing_user($phone);
    if(is_wp_error($owner)||(int)$owner!==$uid){$review++;continue;}
    $email=trim((string)$o->get_billing_email());
    if($email!=='' && is_email($email)){
       $emailOwner=get_user_by('email',$email);
       if($emailOwner && (int)$emailOwner->ID!==$uid){$review++;continue;}
    }
    $byClient=$cloud['client'][$uid]??[];$byPhone=$cloud['mobile'][$phone]??[];
    if(count($byClient)>1||count($byPhone)>1){$review++;continue;}
    if(count($byClient)===1){
        $person=$byClient[0];$pid=(int)($person['PersonId']??0);
        $name=vcar_identity_normalize_name(($person['FirstName']??'').' '.($person['LastName']??''));
        $ph=vesta_otp_phone((string)($person['Mobile']??''));
        if($pid<=0||$name!==$bill||$ph!==$phone){$review++;continue;}
        update_user_meta($uid,'mahak_id',$pid);
        update_user_meta($uid,'_vesta_erp_cloud_verified_person_id',$pid);
        update_user_meta($uid,'_vesta_erp_cloud_verified_person_name',$name);
        update_user_meta($uid,'_vesta_erp_cloud_verified_person_at',gmdate('c'));
        echo 'EXISTING_PERSON_RELINKED_WOO_UID='.$uid.' PERSON_ID='.$pid.PHP_EOL;
        $n++;continue;
    }
    if(count($byPhone)>0){$review++;continue;}
    if(getenv('VC_PERSON_WORKER_COMMIT')!=='yes'){
        echo 'PERSON_WORKER_ELIGIBLE ORDER='.(int)$id.' UID='.$uid.' NO_WRITES=yes'.PHP_EOL;
        $n++;continue;
    }
    // A durable marker precedes remote mutation; no automatic retry if response becomes uncertain.
    update_user_meta($uid,'_vesta_person_provision_attempt',gmdate('c'));
    $reserved++;
    $token=$api->login_token();
    if(!is_array($token)||empty($token['success'])||!is_string($token['message'])||$token['message']===''){
       echo 'LOGIN_ERROR_RESERVED_NO_REMOTE_WRITE UID='.$uid.PHP_EOL;break;
    }
    $api->register_user_in_order($token['message'],$u);
    $r2=$api->get_all_data('',array('fromPersonVersion'=>0));
    $new=$r2['message']['People']??null;
    if(!is_array($new)){echo 'PERSON_WRITE_ACK_UNCERTAIN UID='.$uid.PHP_EOL;break;}
    $matches=[];$phMatches=0;
    foreach($new as $p) {
        if(!empty($p['Deleted']))continue;
        if((int)($p['PersonClientID']??$p['PersonClientId']??0)===$uid)$matches[]=$p;
        if(vesta_otp_phone((string)($p['Mobile']??''))===$phone)$phMatches++;
    }
    if(count($matches)!==1 || $phMatches!==1){echo 'PERSON_WRITE_IDENTITY_UNVERIFIED_UID='.$uid.' NO_RETRY=yes'.PHP_EOL;break;}
    $p=$matches[0];$pid=(int)($p['PersonId']??0);
    $name=vcar_identity_normalize_name(($p['FirstName']??'').' '.($p['LastName']??''));
    if($pid<=0||$name!==$bill){echo 'PERSON_WRITE_NAME_UNVERIFIED_UID='.$uid.' NO_RETRY=yes'.PHP_EOL;break;}
    $stored=(int)get_user_meta($uid,'mahak_id',true);
    if($stored && $stored!==$pid){echo 'PERSON_VENDOR_ID_CONFLICT_UID='.$uid.' NO_RETRY=yes'.PHP_EOL;break;}
    update_user_meta($uid,'mahak_id',$pid);
    update_user_meta($uid,'_vesta_erp_cloud_verified_person_id',$pid);
    update_user_meta($uid,'_vesta_erp_cloud_verified_person_name',$name);
    update_user_meta($uid,'_vesta_erp_cloud_verified_person_at',gmdate('c'));
    $cloud['client'][$uid]=[$p];$cloud['mobile'][$phone]=[$p];
    $n++;
    echo 'PERSON_WORKER_CLOUD_VERIFIED ORDER='.(int)$id.' UID='.$uid.' PERSON_ID='.$pid.' FINANCIAL_WRITES=no'.PHP_EOL;
 }
 echo 'PERSON_WORKER_SUMMARY='.json_encode(['processed'=>$n,'review'=>$review,'reserved'=>$reserved,'max'=>$max]).' NO_INVOICE_WRITES=yes'.PHP_EOL;
} catch(Throwable $e) {
 echo 'PERSON_WORKER_EXCEPTION_CLASS='.preg_replace('/[^A-Za-z]/','',get_class($e)).' NO_AUTO_RETRY=yes'.PHP_EOL;
 exit(31);
} finally {
 $wpdb->get_var($wpdb->prepare('SELECT RELEASE_LOCK(%s)',$globalLock));
}
