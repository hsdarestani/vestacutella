<?php
/**
 * Vesta WooCommerce New Order mail recovery worker.
 * CLI only; admin new_order email only; no checkout/customer/order mutations.
 * A separate host cron invokes this through docker exec -u www-data.
 */
if(PHP_SAPI!=='cli')exit(90);
require '/var/www/html/wp-load.php';
if(!function_exists('wc_get_orders')||!function_exists('WC'))exit(11);
$since=(int)get_option('vc_vesta_cli_admin_mail_start_20261020',0);
if($since<strtotime('2026-10-20 00:00:00 UTC')||$since>time()){
    echo "MAIL_CLI_WORKER_NOT_ACTIVATED\n";exit(12);
}
$cfg=get_option('wp_mail_smtp',array());$smtp=(array)($cfg['smtp']??array());
if(($smtp['host']??'')!=='server135s.irwebspace.com'||(int)($smtp['port']??0)!==465||($smtp['encryption']??'')!=='ssl'){
    echo "MAIL_CLI_SMTP_CONFIG_DRIFT_ABORT\n";exit(13);
}
$mail=null;
foreach(WC()->mailer()->get_emails() as $e)if(($e->id??'')==='new_order')$mail=$e;
if(!$mail||!$mail->is_enabled()){echo "MAIL_CLI_ADMIN_NOTIFICATION_DISABLED\n";exit(14);}
$rec=array_values(array_filter(array_map('trim',explode(',',(string)$mail->get_recipient())),'is_email'));
if(count($rec)!==1){echo "MAIL_CLI_RECIPIENT_CHANGED_ABORT\n";exit(15);}
$dry=(getenv('VC_VESTA_MAIL_DRY_RUN')==='1');
$all=wc_get_orders(array('type'=>'shop_order','limit'=>180,'status'=>array('processing','completed','on-hold'),'orderby'=>'date','order'=>'ASC'));
$eligible=array();
foreach($all as $order){
 if(!$order || !$order->get_date_created())continue;
 $created=$order->get_date_created()->getTimestamp();
 if($created<$since||$created>time()+60)continue;
 if($order->get_meta('_vc_vesta_admin_new_order_accepted',true))continue;
 if((int)$order->get_meta('_vc_vesta_admin_cli_failures',true)>=5)continue;
 $last=(int)$order->get_meta('_vc_vesta_admin_cli_last_attempt_at',true);
 if($last && time()-$last<180)continue;
 $eligible[]=$order;
}
echo "MAIL_CLI mode=".($dry?'dry':'send')." eligible=".count($eligible)." admin_count=1\n";
if($dry){echo "MAIL_CLI_DRY_RUN_COMPLETE\n";exit(0);}
$maxPerRun=2;$sent=0;$failed=0;$processed=0;
foreach($eligible as $order){
 if($processed >= $maxPerRun)break;
 $id=(int)$order->get_id();
 $lock='vc_vesta_cli_order_mail_guard_'.$id;
 $lockTime=(int)get_option($lock,0);
 if($lockTime && time()-$lockTime>600)delete_option($lock);
 if(!add_option($lock,time(),'','no'))continue;
 $processed++;
 $ok=0;$error=0;$category='none';
 $successFn=function()use(&$ok){$ok++;};
 $failedFn=function($e)use(&$error,&$category){
    $error++;
    $msg=strtolower((string)$e->get_error_message());
    $category=preg_match('/authenticat|535|invalid login/',$msg)?'auth':(preg_match('/starttls|ssl|tls|certificate/',$msg)?'tls':'other');
 };
 add_action('wp_mail_succeeded',$successFn,10,1);
 add_action('wp_mail_failed',$failedFn,10,1);
 try{
    $order->update_meta_data('_vc_vesta_admin_cli_last_attempt_at',time());
    $order->save_meta_data();
    $mail->trigger($id,$order);
 }catch(Throwable $e){
    $error++;
    $category='exception';
 }finally{
    remove_action('wp_mail_succeeded',$successFn,10);
    remove_action('wp_mail_failed',$failedFn,10);
 }
 $order=wc_get_order($id);
 if($ok===1 && $error===0){
    $order->update_meta_data('_vc_vesta_admin_new_order_accepted','cli-worker:'.gmdate('c'));
    $order->save_meta_data();
    $sent++;
    echo "MAIL_CLI result=accepted status=".$order->get_status()."\n";
 }else{
    $f=(int)$order->get_meta('_vc_vesta_admin_cli_failures',true)+1;
    $order->update_meta_data('_vc_vesta_admin_cli_failures',$f);
    $order->save_meta_data();
    $failed++;
    echo "MAIL_CLI result=failed category=$category retry=$f\n";
 }
 delete_option($lock);
 usleep(1000000);
}
echo "MAIL_CLI_SUMMARY examined=$processed accepted=$sent failed=$failed\n";
if($failed)exit(21);
echo "MAIL_CLI_WORKER_FINISHED\n";
