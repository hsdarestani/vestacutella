<?php
// Recover only the admin summary of orders placed between the SMTP repair
// and activation of the future-order watchdog. Never emails customers.
if (PHP_SAPI !== 'cli') exit(90);
require '/var/www/html/wp-load.php';
global $wpdb;
$begin='2026-10-19 13:48:00';
$activation=(int)get_option('vc_vesta_order_mail_watchdog_start',0);
if($activation<strtotime('2026-10-19 15:20:00 UTC') || $activation>time()){
 echo "WATCHDOG_START_UNEXPECTED\n";exit(11);
}
$end=gmdate('Y-m-d H:i:s',$activation);
$mailer=WC()->mailer()->get_emails();$new=null;
foreach($mailer as $e)if(($e->id??'')==='new_order')$new=$e;
if(!$new||!$new->is_enabled())exit(12);
$rec=array_values(array_filter(array_map('trim',explode(',',$new->get_recipient())),'is_email'));
if(count($rec)!==1)exit(13);
$opt=get_option('wp_mail_smtp',[]);$s=(array)($opt['smtp']??[]);
if(($s['encryption']??'')!=='tls'||(int)($s['port']??0)!==587)exit(14);
$key='vc_vesta_admin_gap_report_20261019';
if(get_option($key,false)){echo "GAP_REPORT_ALREADY_SUBMITTED\n";exit(0);}
$rows=$wpdb->get_col($wpdb->prepare("SELECT ID FROM {$wpdb->posts} WHERE post_type='shop_order' AND post_date_gmt >= %s AND post_date_gmt < %s ORDER BY post_date_gmt ASC, ID ASC LIMIT 250",$begin,$end));
$lines=array();
foreach($rows as $id){
 $o=wc_get_order((int)$id);if(!$o)continue;
 $name=sanitize_text_field((string)$o->get_order_number());
 $status=sanitize_text_field((string)$o->get_status());
 $link=$o->get_edit_order_url();
 $lines[]='#'.$name.' | '.$status.' | '.$link;
}
$n=count($lines);
echo "GAP_SUMMARY begin_utc=$begin end_utc=$end orders=$n recipient_domain=".substr(strrchr($rec[0],'@'),1)."\n";
if(!$n){add_option($key,array('count'=>0,'utc'=>gmdate('c')),'','no');echo "NO_GAP_ORDERS\n";exit(0);}
$subject='Vesta | سفارش‌های جدید بین اصلاح SMTP و فعال‌سازی اعلان خودکار | '.$n.' سفارش';
$body="گزارش تکمیلی سفارش‌های وستا\n\n".
"این سفارش‌ها بین زمان اصلاح SMTP و فعال‌سازی سیستم جدید کنترل اعلان سفارش ثبت شده‌اند.\n".
"این گزارش فقط برای مدیر فروشگاه ارسال شده و ممکن است برخی سفارش‌ها قبلاً اعلان جداگانه دریافت کرده باشند.\n".
"تعداد: $n\n\n".implode("\n",$lines)."\n";
$accepted=wp_mail($rec,$subject,$body,array('Content-Type: text/plain; charset=UTF-8'));
echo "GAP_REPORT_SMTP_ACCEPTED=".($accepted?'yes':'no')."\n";
if(!$accepted)exit(20);
add_option($key,array('count'=>$n,'utc'=>gmdate('c'),'kind'=>'admin_gap_summary'),'','no');
echo "GAP_ADMIN_ORDER_REPORT_COMPLETED\n";
