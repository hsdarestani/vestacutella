<?php
/**
 * Resolve a stale no-person block only for paid Woo order 105557 after its
 * existing ERP person and mobile are independently confirmed. This never
 * creates persons, orders, invoices or receipts; the existing protected
 * accounting sender is responsible for the only possible remote mutation.
 */
error_reporting(E_ERROR|E_PARSE); ini_set('display_errors','0');
$_SERVER['HTTP_HOST']='vesta-cosmetics.ir';$_SERVER['SERVER_NAME']='vesta-cosmetics.ir';$_SERVER['HTTPS']='on';$_SERVER['SERVER_PORT']='443';$_SERVER['REQUEST_URI']='/';
require '/var/www/html/wp-load.php';global $wpdb;
$id=105557;$uid=6416;$pid=12770247;
$commit=getenv('VC_105557_COMMIT')==='yes';
if($commit && getenv('VC_105557_BACKUP_VERIFIED')!=='yes')exit(20);
$o=wc_get_order($id);$u=get_user_by('id',$uid);
if(!$o||!$u||!vcar_eligible($o)||!$o->get_date_paid()||
 (int)$o->get_customer_id()!==$uid ||
 (int)get_user_meta($uid,'mahak_id',true)!==$pid||
 (int)$o->get_meta('mahak_id')>0||
 (int)$o->get_meta('_vcar_cloud_invoice_id')>0||
 (float)$o->get_total()!==749000.0||
 (float)$o->get_shipping_total()!==150000.0||
 !get_option('vcar_sender_enabled',false)||
 (bool)array_intersect((array)$u->roles,['administrator','shop_manager','editor','author']))
 exit(21);
$billing=vcar_identity_normalize_name($o->get_billing_first_name().' '.$o->get_billing_last_name());
$profile=vcar_identity_normalize_name($u->first_name.' '.$u->last_name);
$phone=vesta_otp_phone((string)$o->get_billing_phone());
$phoneOwner=$phone?vesta_otp_existing_user($phone):false;
if(!$billing||$billing!==$profile||!$phone||is_wp_error($phoneOwner)||(int)$phoneOwner!==$uid||
 $phone!==vesta_otp_phone((string)get_user_meta($uid,'billing_phone',true)))exit(22);
$settings=get_option('bazara_visitor_settings',[]);
$bank=vcar_bank($settings,$o->get_payment_method());
if(Vesta_Accounting_Reliability::preflight($o,$bank)!=='')exit(23);
$api=new BazaraApi(true);
$r=$api->get_all_data('',array('fromOrderVersion'=>0,'fromPersonVersion'=>0));
if(empty($r['success'])||!is_array($r['message']['People']??null)||
 !is_array($r['message']['Orders']??null))exit(24);
$byPhone=[];$byPerson=[];$byClient=[];$byOrder=[];
foreach($r['message']['People'] as $p){
 if(!empty($p['Deleted']))continue;
 if((int)($p['PersonId']??0)===$pid)$byPerson[]=$p;
 if(vesta_otp_phone((string)($p['Mobile']??''))===$phone)$byPhone[]=$p;
 if((int)($p['PersonClientID']??$p['PersonClientId']??0)===$uid)$byClient[]=$p;
}
foreach($r['message']['Orders'] as $remote)
 if(empty($remote['Deleted'])&&(int)($remote['OrderClientId']??0)===$id)$byOrder[]=$remote;
if(count($byPhone)!==1||count($byPerson)!==1||count($byClient)!==1||count($byOrder)!==0||
 (int)($byPhone[0]['PersonId']??0)!==$pid||
 (int)($byClient[0]['PersonId']??0)!==$pid||
 vcar_identity_normalize_name(($byPerson[0]['FirstName']??'').' '.($byPerson[0]['LastName']??''))!==$billing)exit(25);
$local=$wpdb->get_row($wpdb->prepare(
 "SELECT FirstName,LastName,Mobile,Deleted FROM {$wpdb->prefix}bazara_persons WHERE PersonId=%d LIMIT 1",$pid),ARRAY_A);
if(!$local || (int)$local['Deleted']!==0||
 vcar_identity_normalize_name($local['FirstName'].' '.$local['LastName'])!==$billing||
 vesta_otp_phone((string)$local['Mobile'])!==$phone)exit(26);
if((int)$wpdb->get_var($wpdb->prepare("SELECT COUNT(*) FROM {$wpdb->prefix}bazara_orders WHERE OrderClientId=%d",$id))!==0)exit(27);
$t=Vesta_Accounting_Reliability::table();
$q=$wpdb->get_row($wpdb->prepare(
 "SELECT state,reason,attempts,submitted_at,remote_id FROM $t WHERE order_id=%d",$id),ARRAY_A);
if(!$q || $q['state']!=='blocked' || $q['reason']!=='customer_erp_person_unmapped' ||
 (int)$q['attempts']!==0||(int)$q['submitted_at']!==0||(int)$q['remote_id']!==0)exit(28);
echo 'EXACT_105557_RELEASE_PLAN='.json_encode(['order_id'=>$id,'woo_uid'=>$uid,
 'erp_person_id'=>$pid,'paid_total_toman'=>(float)$o->get_total(),
 'shipping_toman'=>(float)$o->get_shipping_total(),
 'unique_otp_owner'=>true,'cloud_existing_invoice_count'=>0,'previous_send_attempts'=>0,
 'safe_to_requeue'=>true],JSON_UNESCAPED_UNICODE).PHP_EOL;
if(!$commit){echo "EXACT_105557_DRYRUN_PASSED_NO_WRITES=yes\n";exit(0);}
$lock='vesta_105557_erp_person_unmapped_recovery';
if((int)$wpdb->get_var($wpdb->prepare('SELECT GET_LOCK(%s,5)',$lock))!==1)exit(29);
try{
 $n=$wpdb->query($wpdb->prepare(
 "UPDATE $t SET state='pending',reason='',next_attempt=%d,updated_at=%d WHERE order_id=%d AND state='blocked' AND reason='customer_erp_person_unmapped' AND attempts=0 AND submitted_at=0 AND remote_id=0",
 time()-1,time(),$id));
 if($n!==1)exit(30);
 $new=$wpdb->get_row($wpdb->prepare("SELECT state,reason,attempts,submitted_at,remote_id FROM $t WHERE order_id=%d",$id),ARRAY_A);
 if(!$new||$new['state']!=='pending'||$new['reason']!==''||(int)$new['attempts']!==0||
 (int)$new['submitted_at']!==0||(int)$new['remote_id']!==0)exit(31);
 echo "EXACT_105557_OUTBOX_UNBLOCKED_NO_DUPLICATE_SEND=yes\n";
}finally{$wpdb->get_var($wpdb->prepare('SELECT RELEASE_LOCK(%s)',$lock));}
