#!/usr/bin/env bash
set -uo pipefail
echo "AUDIT_UTC=$(date -u +%FT%TZ)"
docker exec vc-vesta php -d display_errors=0 -r '
require "/var/www/html/wp-load.php";
global $wpdb;
$since=time()-21600;$start=(int)get_option("vc_vesta_order_mail_watchdog_start",0);
echo "WATCHDOG_START_UTC=".($start?gmdate("c",$start):"missing")."\n";
$ids=wc_get_orders(["type"=>"shop_order","status"=>["processing","completed","on-hold"],"limit"=>40,"orderby"=>"date","order"=>"DESC","return"=>"ids"]);
$total=0;$native=0;$watchdog=0;$missing=0;$scheduled=0;
foreach($ids as $id){
 $o=wc_get_order($id);if(!$o||!$o->get_date_created())continue;
 $created=$o->get_date_created()->getTimestamp();
 if($created<$start||$created<$since)continue;
 $total++;
 $marker=(string)$o->get_meta("_vc_vesta_admin_new_order_accepted",true);
 $try=(int)$o->get_meta("_vc_vesta_admin_new_order_retries",true);
 $next=wp_next_scheduled("vc_vesta_admin_new_order_watchdog",[$id]);
 if(strpos($marker,"native:")===0)$native++;
 elseif(strpos($marker,"watchdog:")===0)$watchdog++;
 else $missing++;
 if($next)$scheduled++;
 echo "ORDER_OBS index=".$total." age_mins=".round((time()-$created)/60)." status=".$o->get_status()." accepted=".($marker?(strpos($marker,"native:")===0?"native":"watchdog"):"no")." retry=".$try." pending_cron=".($next?"yes":"no")."\n";
}
echo "ORDER_OBS_SUMMARY count=$total native=$native watchdog=$watchdog not_marked=$missing pending_cron=$scheduled\n";
$t=$wpdb->prefix."wpmailsmtp_debug_events";
if($wpdb->get_var($wpdb->prepare("SHOW TABLES LIKE %s",$t))===$t){
 $rows=$wpdb->get_results("SELECT * FROM $t WHERE created_at >= UTC_TIMESTAMP()-INTERVAL 3 HOUR ORDER BY id DESC LIMIT 110",ARRAY_A);
 $categories=[];$perHour=[];
 foreach($rows as $r){
  $text=strtolower((string)($r["content"]??$r["message"]??""));
  $cat=preg_match("/authentica|535|invalid credential|login failed/",$text)?"auth":(preg_match("/tls|ssl|certificate/",$text)?"tls":(preg_match("/recipient|rcpt to|address|relay denied/",$text)?"recipient":(preg_match("/connect|timed out|timeout/",$text)?"connection":(preg_match("/sender|send as|not allowed/",$text)?"sender":"other"))));
  $categories[$cat]=($categories[$cat]??0)+1;
  $hour=substr((string)($r["created_at"]??""),0,13);
  $perHour[$hour]=($perHour[$hour]??0)+1;
 }
 foreach($categories as $name=>$n)echo "RECENT_SMTP_ERROR_CATEGORY ".$name." count=".$n."\n";
 foreach($perHour as $hour=>$n)echo "RECENT_SMTP_ERROR_HOUR ".$hour." count=".$n."\n";
}
foreach(["vc_vesta_admin_new_order_watchdog","action_scheduler_run_queue"] as $hook){
 $cron=wp_next_scheduled($hook);
 echo "NEXT_CRON hook=$hook ".($cron?gmdate("c",$cron):"not_global")."\n";
}
'
echo "LATEST_ORDER_MAIL_DIAG_COMPLETE"
