<?php
/**
 * Register one verified Woo customer as one Mahak person, never an invoice.
 * Safety: sender paused, paid order, unique OTP owner, matched billing name,
 * no PersonClientID or Mobile conflicts in live cloud, one-shot reservation,
 * full cloud readback required. No retries after ambiguous outcome.
 */
error_reporting(E_ERROR|E_PARSE);ini_set('display_errors','0');
$_SERVER['HTTP_HOST']='vesta-cosmetics.ir';$_SERVER['SERVER_NAME']='vesta-cosmetics.ir';
$_SERVER['HTTPS']='on';$_SERVER['SERVER_PORT']='443';$_SERVER['REQUEST_URI']='/';
require '/var/www/html/wp-load.php';
$id=absint(getenv('VC_PERSON_ORDER_ID')?:0);
if(!$id || !in_array($id,[105458,105456,105454,105452,105450,105361],true)){echo 'ORDER_NOT_ALLOWLISTED'.PHP_EOL;exit(20);}
if(get_option('vcar_sender_enabled',false)){echo 'SENDER_MUST_REMAIN_PAUSED'.PHP_EOL;exit(21);}
$o=wc_get_order($id);
if(!vcar_eligible($o)||!$o->get_meta('_vesta_identity_repaired_at')){echo 'ORDER_NOT_REPAIRED_OR_NOT_PAID'.PHP_EOL;exit(22);}
$uid=(int)$o->get_customer_id();$user=get_user_by('id',$uid);
if(!$uid||!$user||!Vesta_Channel_Customers::customer($uid)){echo 'INVALID_CUSTOMER_ACCOUNT'.PHP_EOL;exit(23);}
if((int)get_user_meta($uid,'mahak_id',true)){echo 'CUSTOMER_ALREADY_MAPPED_REQUIRE_VERIFICATION'.PHP_EOL;exit(0);}
$billName=vcar_identity_normalize_name($o->get_billing_first_name().' '.$o->get_billing_last_name());
$userName=vcar_identity_normalize_name($user->first_name.' '.$user->last_name);
$phone=vesta_otp_phone($o->get_billing_phone());
$owner=$phone?vesta_otp_existing_user($phone):false;
if(!$phone||is_wp_error($owner)||(int)$owner!==$uid||$billName===''||$billName!==$userName){
    echo 'ACCOUNT_NAME_OR_PHONE_NOT_PROVEN'.PHP_EOL;exit(24);
}
$storedPhone=vesta_otp_phone((string)get_user_meta($uid,'billing_phone',true));
if($storedPhone!==$phone){echo 'CUSTOMER_PROFILE_PHONE_NOT_EQ_BILLING_ABORT'.PHP_EOL;exit(25);}
$api=new BazaraApi(true);
$scan=function()use($api,$uid,$phone,$billName) {
    $res=$api->get_all_data('',array('fromPersonVersion'=>0));
    if(!is_array($res)||empty($res['success'])||!is_array($res['message']['People']??null))throw new RuntimeException('cloud_people_not_available');
    $people=$res['message']['People'];$sameClient=[];$mobileMatches=[];
    foreach($people as $p){
        if(!empty($p['Deleted']))continue;
        $client=(int)($p['PersonClientID']??$p['PersonClientId']??0);
        if($client===$uid)$sameClient[]=$p;
        $pm=vesta_otp_phone((string)($p['Mobile']??''));
        if($pm && $pm===$phone)$mobileMatches[]=$p;
    }
    return [$sameClient,$mobileMatches];
};
try{[$byClient,$byPhone]=$scan();}catch(Throwable $e){echo 'CLOUD_PREFLIGHT_UNAVAILABLE_NO_WRITES'.PHP_EOL;exit(26);}
echo 'PREFLIGHT ORDER='.$id.' UID='.$uid.' CLIENT_MATCHES='.count($byClient).' MOBILE_MATCHES='.count($byPhone).' USER_NAME_MATCH=1'.PHP_EOL;
if(count($byClient)>1||count($byPhone)>0){echo 'PERSON_ALREADY_PRESENT_OR_MOBILE_CONFLICT_ABORT'.PHP_EOL;exit(27);}
if(getenv('VC_PERSON_COMMIT')!=='yes'){echo 'PERSON_PROVISION_DRYRUN_NO_WRITES=yes'.PHP_EOL;exit(0);}
if(getenv('VC_PERSON_BACKUP_VERIFIED')!=='yes'){echo 'BACKUP_REQUIRED_NO_WRITES'.PHP_EOL;exit(28);}
global $wpdb;
$lock='vesta_erp_person_'.$uid;
if((int)$wpdb->get_var($wpdb->prepare('SELECT GET_LOCK(%s, 10)',$lock))!==1){echo 'PERSON_PROVISION_LOCK_BUSY'.PHP_EOL;exit(29);}
try {
    if(get_option('vcar_sender_enabled',false))throw new RuntimeException('sender_reenabled');
    if(get_user_meta($uid,'_vesta_person_provision_attempt',true)){echo 'PERSON_PRIOR_ATTEMPT_NO_RETRY'.PHP_EOL;exit(30);}
    // Verify cloud absence again immediately before reservation.
    [$byClient,$byPhone]=$scan();
    if($byClient||$byPhone){echo 'PERSON_CONCURRENTLY_APPEARED_NO_RETRY'.PHP_EOL;exit(31);}
    update_user_meta($uid,'_vesta_person_provision_attempt',gmdate('c'));
    $login=$api->login_token();
    if(!is_array($login)||empty($login['success'])||!is_string($login['message'])||$login['message']===''){
       echo 'ERP_LOGIN_FAILED_NO_PERSON_WRITE'.PHP_EOL;exit(32);
    }
    echo 'PERSON_SINGLE_SUBMISSION_STARTED ORDER='.$id.' UID='.$uid.PHP_EOL;
    $out=$api->register_user_in_order($login['message'],$user);
    // Never retry on timeout/false; read back to reconcile ambiguous response.
    [$byClient,$byPhone]=$scan();
    if(count($byClient)!==1) {
        echo 'PERSON_CLOUD_ACK_UNCERTAIN CLIENT_COUNT='.count($byClient).' NO_RETRY=yes'.PHP_EOL;exit(33);
    }
    $p=$byClient[0];$personId=(int)($p['PersonId']??0);
    $erpName=vcar_identity_normalize_name(($p['FirstName']??'').' '.($p['LastName']??''));
    $cloudPhone=vesta_otp_phone((string)($p['Mobile']??''));
    if($personId<=0||$erpName!==$billName||$cloudPhone!==$phone||count($byPhone)!==1){
        echo 'PERSON_CLOUD_IDENTITY_READBACK_MISMATCH_NO_RETRY=yes'.PHP_EOL;exit(34);
    }
    $mapped=(int)get_user_meta($uid,'mahak_id',true);
    if($mapped>0 && $mapped!==$personId){echo 'VENDOR_LOCAL_PERSON_ID_CONFLICT_NO_RETRY'.PHP_EOL;exit(35);}
    if(!$mapped)update_user_meta($uid,'mahak_id',$personId);
    // Source-backed identity proof if vendor local Person table is asynchronously refreshed.
    update_user_meta($uid,'_vesta_erp_cloud_verified_person_id',$personId);
    update_user_meta($uid,'_vesta_erp_cloud_verified_person_name',$erpName);
    update_user_meta($uid,'_vesta_erp_cloud_verified_person_at',gmdate('c'));
    echo 'PERSON_CREATED_AND_READBACK_VERIFIED ORDER='.$id.' UID='.$uid.' PERSON_ID='.$personId.' NO_INVOICE_WRITES=yes'.PHP_EOL;
} catch(Throwable $e) {
    echo 'PERSON_PROVISION_EXCEPTION_NO_AUTOMATIC_RETRY CLASS='.preg_replace('/[^A-Za-z]/','',get_class($e)).PHP_EOL;exit(36);
} finally {
    $wpdb->get_var($wpdb->prepare('SELECT RELEASE_LOCK(%s)',$lock));
}
