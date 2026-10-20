<?php
/**
 * Vesta order-admin mail transport recovery via PHP CLI.
 * One existing real order; never touches customer mail, payment or inventory.
 */
if (PHP_SAPI!=='cli') exit(90);
require '/var/www/html/wp-load.php';
if(!function_exists('wc_get_orders')) exit(10);
$options=get_option('wp_mail_smtp',array());
$s=(array)($options['smtp']??array());
if(($s['encryption']??'')!=='ssl'||(int)($s['port']??0)!==465)exit(11);
$new=null;
foreach(WC()->mailer()->get_emails() as $e)if(($e->id??'')==='new_order')$new=$e;
if(!$new||!$new->is_enabled())exit(12);
$to=array_values(array_filter(array_map('trim',explode(',',(string)$new->get_recipient())),'is_email'));
if(count($to)!==1)exit(13);
$orders=wc_get_orders(array('limit'=>40,'status'=>array('processing','completed','on-hold'),'orderby'=>'date','order'=>'DESC'));
$chosen=null;
foreach($orders as $o){
 $dt=$o->get_date_created();
 if(!$dt||$dt->getTimestamp()<strtotime('2026-10-20 00:00:00 UTC'))continue;
 if($o->get_meta('_vc_vesta_admin_new_order_accepted',true))continue;
 if($o->get_meta('_vc_vesta_admin_cli_mail_canary_20261020',true))continue;
 $chosen=$o;break;
}
if(!$chosen){echo "CLI_ORDER_MAIL_CANARY_NO_UNSENT_ORDER\n";exit(0);}
$id=(int)$chosen->get_id();
echo "CLI_ORDER_MAIL_CANARY order_status=".$chosen->get_status()." recipient_domain=".substr(strrchr($to[0],'@'),1)."\n";
$success=0;$failure=0;
add_action('wp_mail_succeeded',function($args)use(&$success){$success++;},10,1);
add_action('wp_mail_failed',function($err)use(&$failure){
 $failure++;
 $m=strtolower((string)$err->get_error_message());
 $why=preg_match('/authenticat|535|invalid login/',$m)?'authentication':(preg_match('/starttls|ssl|tls|certificate/',$m)?'tls':'other');
 echo "CLI_ORDER_MAIL_FAILURE category=$why\n";
},10,1);
try {$new->trigger($id,$chosen);}
catch(Throwable $e){echo "CLI_ORDER_MAIL_EXCEPTION\n";exit(20);}
echo "CLI_ORDER_MAIL_CANARY_DELIVERY accepted_hooks=$success failed_hooks=$failure\n";
if($success!==1||$failure){exit(21);}
$chosen=wc_get_order($id);
$chosen->update_meta_data('_vc_vesta_admin_new_order_accepted','cli:'.gmdate('c'));
$chosen->update_meta_data('_vc_vesta_admin_cli_mail_canary_20261020','accepted');
$chosen->save_meta_data();
echo "CLI_ORDER_MAIL_CANARY_SMTP_ACCEPTED\n";
