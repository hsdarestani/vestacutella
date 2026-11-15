<?php
error_reporting(E_ERROR|E_PARSE);
$_SERVER['HTTP_HOST']='vesta-cosmetics.ir';$_SERVER['SERVER_NAME']='vesta-cosmetics.ir';
$_SERVER['HTTPS']='on';$_SERVER['SERVER_PORT']='443';$_SERVER['REQUEST_URI']='/';
require '/var/www/html/wp-load.php';
set_time_limit(0);
register_shutdown_function(function(){ $e=error_get_last(); if($e && in_array($e['type'],[E_ERROR,E_PARSE,E_CORE_ERROR,E_COMPILE_ERROR],true)) echo 'CHANNEL_ACCEPTANCE_FATAL_TYPE='.$e['type'].' FILE='.basename($e['file']).' LINE='.$e['line']."\n"; });
function require_channel($ok,$reason){if(!$ok)throw new RuntimeException($reason);}
function snapshot_channel_order($o){
 $items=[];foreach($o->get_items() as $i)$items[]=[(int)$i->get_id(),(int)$i->get_product_id(),(int)$i->get_variation_id(),(float)$i->get_quantity(),(float)$i->get_subtotal(),(float)$i->get_total(),(float)$i->get_total_tax()];
 return [$o->get_total(),$o->get_shipping_total(),$o->get_discount_total(),$o->get_total_tax(),$o->get_currency(),$o->get_status(),$o->get_payment_method(),$o->get_meta('mahak_id'),$o->get_meta('_vcar_money_multiplier'),$o->get_date_paid()?$o->get_date_paid()->getTimestamp():0,$o->get_address('billing'),$o->get_address('shipping'),$items];
}
require_channel(class_exists('Vesta_Channel_Customers')&&function_exists('vesta_otp_resolve_customer')&&vesta_otp_ready(),'login_adapter_not_ready');
$apply=getenv('VESTA_CHANNEL_ACCOUNTS_APPLY')==='yes';
$since=strtotime('2026-11-01T00:00:00Z');
$ids=wc_get_orders(['type'=>'shop_order','customer_id'=>0,'status'=>Vesta_Channel_Customers::statuses(),'date_created'=>'>='.$since,'limit'=>200,'orderby'=>'ID','order'=>'DESC','return'=>'ids']);
require_channel(count($ids)<200,'guest_backlog_exceeds_reviewed_bound');
$preview=[];$issues=[];
foreach($ids as $id){$o=wc_get_order($id);if(!Vesta_Channel_Customers::eligible($o))continue;
 $phone=vesta_otp_phone($o->get_billing_phone());
 $existing=$phone?vesta_otp_existing_user($phone):new WP_Error('invalid_mobile');
 $reason=is_wp_error($existing)?$existing->get_error_code():($existing&&!Vesta_Channel_Customers::customer($existing)?'non_customer_account':'ready');
 $preview[$id]=$reason;if($reason!=='ready')$issues[$reason]=($issues[$reason]??0)+1;
}
echo 'RECENT_GUEST_CANDIDATES='.count($preview).' PRECHECK_ISSUES='.json_encode($issues)."\n";
if(!$apply){echo "PREVIEW_ONLY_NO_CUSTOMER_OR_ORDER_WRITES=yes\n";exit(0);}
update_option('vesta_channel_accounts_since',$since,false);
update_option('vesta_channel_accounts_enabled',true,false);
$canary=[];$count=0;$result=[];$gateways=[];
foreach($preview as $id=>$precheck){
 $o=wc_get_order($id);$before=snapshot_channel_order($o);$gateway=$o->get_payment_method();
 // Real Woo order lifecycle hook, with an existing real purchase. No synthetic paid order, payment or message.
 if($precheck==='ready' && !isset($canary[$gateway])){
   $o->save();$canary[$gateway]=true;
 }
 $out=Vesta_Channel_Customers::attach($id);
 $fresh=wc_get_order($id);
 require_channel($before===snapshot_channel_order($fresh),'order_financial_or_contact_data_changed_'.$id);
 if($fresh->get_customer_id()){
   $user=(int)$fresh->get_customer_id();require_channel(Vesta_Channel_Customers::customer($user),'invalid_customer_role_'.$id);
   $phone=vesta_otp_phone($fresh->get_billing_phone());
   if($phone)require_channel(vesta_otp_existing_user($phone)===$user,'otp_resolver_disagrees_'.$id);
   $panel=wc_get_orders(['customer_id'=>$user,'include'=>[$id],'limit'=>1,'return'=>'ids']);
   require_channel(in_array((int)$id,array_map('intval',$panel),true),'order_not_in_customer_panel_'.$id);
   $count++;$gateways[$gateway]=($gateways[$gateway]??0)+1;
   echo 'PANEL_VERIFIED_ORDER='.(int)$id.' SOURCE='.$gateway.' OTP_IDENTITY_MATCH=yes FINANCIAL_SNAPSHOT_UNCHANGED=yes' ."\n";
 }else{$result[$out]=($result[$out]??0)+1;echo 'ACCOUNT_REVIEW_ORDER='.(int)$id.' REASON='.$out."\n";}
}
echo 'CHANNEL_PANELS_LINKED='.$count.' BY_GATEWAY='.json_encode($gateways).' REVIEW_REQUIRED='.json_encode($result)."\n";
require_channel($count>0,'no_real_panel_verified');
require_channel(has_action('woocommerce_after_order_object_save',['Vesta_Channel_Customers','saved'])!==false,'universal_order_save_hook_missing');
require_channel(has_action('woocommerce_payment_complete',['Vesta_Channel_Customers','attach'])!==false,'payment_complete_hook_missing');
echo 'HOOK_CANARIES='.json_encode(array_keys($canary))."\n";
echo 'MY_ACCOUNT_URL='.wc_get_page_permalink('myaccount')."\n";
echo 'NO_OTP_SMS_OR_EMAIL_SENT_BY_ACCEPTANCE=yes; REAL_INTERACTIVE_OTP_CHALLENGE_NOT_RUN=yes' ."\n";
echo "CHANNEL_ACCOUNT_ACCEPTANCE=passed\n";
