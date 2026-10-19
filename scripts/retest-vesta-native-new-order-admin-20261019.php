<?php
// Resend exactly one real processing order to its existing admin recipient.
// No customer mail, no fake order; marker prevents replay on CI retry.
if (PHP_SAPI !== 'cli') exit(95);
require '/var/www/html/wp-load.php';
if (!function_exists('wc_get_orders')) exit(20);
$emails=WC()->mailer()->get_emails();
$new=null;
foreach($emails as $email)if(($email->id??'')==='new_order')$new=$email;
if (!$new || !$new->is_enabled())exit(21);
$to=array_values(array_filter(array_map('trim',explode(',',$new->get_recipient())),'is_email'));
if(count($to)!==1){echo "ABORT_RECIPIENT_CHANGED\n";exit(22);}
echo "RECIPIENT_DOMAIN=".substr(strrchr($to[0],'@'),1)."\n";
$orders=wc_get_orders(array('limit'=>10,'status'=>array('processing','completed'),'orderby'=>'date','order'=>'DESC'));
$order=null;
foreach($orders as $o) {
  if($o && $o->get_date_created() && $o->get_date_created()->getTimestamp()>=strtotime('2026-10-19 13:48:00 UTC')){$order=$o;break;}
}
if(!$order){echo "NO_RECENT_ORDER_TO_TEST\n";exit(23);}
$key='vc_vesta_order_admin_retest_20261019_'.(int)$order->get_id();
if(get_option($key,false)){echo "ORDER_EMAIL_RETEST_ALREADY_SUBMITTED\n";exit(0);}
echo "TEST_NEW_ORDER status=".$order->get_status()." payment=".preg_replace('/[^a-z0-9_-]/i','',(string)$order->get_payment_method())." created_via=".preg_replace('/[^a-z0-9_-]/i','',(string)$order->get_created_via())."\n";
$successful=0;$failed=0;
add_action('wp_mail_succeeded',function($args)use(&$successful){
 $s=(string)($args['subject']??'');
 if($s!==''){$successful++;echo "ADMIN_WP_MAIL_SUCCEEDED\n";}
},10,1);
add_action('wp_mail_failed',function($error)use(&$failed){
 $failed++;
 $s=strtolower((string)$error->get_error_message());
 $why=strpos($s,'auth')!==false?'auth':(strpos($s,'connect')!==false?'connect':(strpos($s,'tls')!==false?'tls':'other'));
 echo "ADMIN_WP_MAIL_FAILED category=".$why."\n";
},10,1);
// Trigger WooCommerce's OWN formatted New Order email; do not directly email the customer.
try {$new->trigger($order->get_id(),$order);}
catch(Throwable $e){echo "NATIVE_NEW_ORDER_TRIGGER_EXCEPTION\n";exit(24);}
echo "TRIGGER_RESULT mail_succeeded=".$successful." mail_failed=".$failed."\n";
if($failed || $successful!==1){exit(25);}
add_option($key,array('utc'=>gmdate('c'),'kind'=>'native_admin_new_order_test'),'', 'no');
echo "NATIVE_NEW_ORDER_ADMIN_EMAIL_ACCEPTED\n";
