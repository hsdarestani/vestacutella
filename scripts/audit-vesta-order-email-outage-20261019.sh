#!/usr/bin/env bash
# Vesta order-email outage diagnostic: no email is sent and no customer data printed.
set -uo pipefail
export LC_ALL=C
echo "AUDIT_UTC=$(date -u +%FT%TZ)"
echo "=== DNS_AND_NETWORK ==="
for d in vesta-cosmetics.ir mail.vesta-cosmetics.ir smtp.vesta-cosmetics.ir; do
  echo "DNS $d"
  for t in A MX; do
    r=$(dig @1.1.1.1 +time=3 +tries=1 +short "$t" "$d" 2>/dev/null | head -3 | tr '\n' ',' || true)
    echo " type=$t record=$r"
  done
done
for host in mail.vesta-cosmetics.ir smtp.vesta-cosmetics.ir server135s.irwebspace.com smtp.gmail.com;do
 for port in 465 587;do
   if timeout 3 bash -c 'echo >/dev/tcp/"$1"/"$2"' _ "$host" "$port" 2>/dev/null;then
     echo "TCP $host:$port open"
   else echo "TCP $host:$port closed_or_unreachable";fi
 done
done
echo "=== WP_WOO_SETTINGS ==="
docker exec vc-vesta php -d display_errors=0 -r '
require "/var/www/html/wp-load.php";
require_once ABSPATH."wp-admin/includes/plugin.php";
global $wpdb;
function safe_domain($e) { $p=explode("@",trim((string)$e));return count($p)===2?preg_replace("/[^a-z0-9.-]/i","",end($p)):"missing"; }
function scalar_yes($v) {return empty($v)?"no":"yes";}
echo "site_utc=".gmdate("c")."\n";
echo "wp_version=".$GLOBALS["wp_version"]." php=".PHP_VERSION."\n";
foreach(["wp-mail-smtp/wp_mail_smtp.php","easy-wp-smtp/easy-wp-smtp.php","fluent-smtp/fluent-smtp.php","post-smtp/postman-smtp.php","woocommerce/woocommerce.php"] as $id) echo "plugin ".preg_replace("/[^a-z0-9\\/-_.]/i","",$id)."=".(is_plugin_active($id)?"active":"inactive")."\n";
$o=get_option("wp_mail_smtp",[]);
$o=is_array($o)?$o:[];
$mail=isset($o["mail"])&&is_array($o["mail"])?$o["mail"]:[];
$smtp=isset($o["smtp"])&&is_array($o["smtp"])?$o["smtp"]:[];
echo "wp_mail_smtp_options=".scalar_yes($o)."\n";
echo "smtp_mailer=".preg_replace("/[^a-z0-9_-]/i","",(string)($mail["mailer"]??"unset"))."\n";
echo "smtp_host=".preg_replace("/[^a-z0-9._-]/i","",(string)($smtp["host"]??"unset"))."\n";
echo "smtp_port=".(int)($smtp["port"]??0)." encryption=".preg_replace("/[^a-z0-9_-]/i","",(string)($smtp["encryption"]??"unset"))." auth=".scalar_yes($smtp["auth"]??false)." username_present=".scalar_yes($smtp["user"]??"")." password_present=".scalar_yes($smtp["pass"]??"")."\n";
echo "configured_mail_from_domain=".safe_domain($mail["from_email"]??"")." woo_from_domain=".safe_domain(get_option("woocommerce_email_from_address",""))." admin_domain=".safe_domain(get_option("admin_email",""))."\n";
echo "mail_errors_table=";
$t=$wpdb->prefix."wpmailsmtp_debug_events";
if($wpdb->get_var($wpdb->prepare("SHOW TABLES LIKE %s",$t))!==$t) echo "missing\n";
else{
 echo "present\n";
 $cols=$wpdb->get_col("SHOW COLUMNS FROM $t",0);
 echo "mail_error_columns=".implode(",",array_filter($cols,function($x){return !preg_match("/message|data|content|email|recipient|address/i",$x);}))."\n";
 if(in_array("created_at",$cols,true)&&in_array("event_type",$cols,true)){
  $rs=$wpdb->get_results("SELECT DATE(created_at) day,event_type,COUNT(*) n FROM $t WHERE created_at>=UTC_TIMESTAMP()-INTERVAL 21 DAY GROUP BY DATE(created_at),event_type ORDER BY day DESC LIMIT 50",ARRAY_A);
  foreach($rs as $r) echo "mail_event day=".$r["day"]." type=".preg_replace("/[^a-z0-9_-]/i","",(string)$r["event_type"])." count=".$r["n"]."\n";
 }
}
echo "wc_new_order_configured_settings=";
$w=get_option("woocommerce_new_order_settings",[]);
echo scalar_yes($w)."\n";
if(function_exists("WC")){
 $mm=WC()->mailer()->get_emails();
 foreach($mm as $e){
  $id=isset($e->id)?$e->id:get_class($e);
  if(preg_match("/new_order|cancelled_order|failed_order|customer_processing_order|customer_completed_order/",(string)$id)){
   $enabled=method_exists($e,"is_enabled")?$e->is_enabled():!empty($e->enabled);
   $rec=method_exists($e,"get_recipient")?$e->get_recipient():"";
   $addrs=array_filter(array_map("trim",explode(",",(string)$rec)));
   echo "WOO_EMAIL ".$id." enabled=".($enabled?"yes":"no")." recipient_count=".count($addrs)." recipient_domains=".implode(",",array_unique(array_map("safe_domain",$addrs)))."\n";
  }
 }
}
echo "WC_ORDER_COUNTS_LAST_21D\n";
$ot=$wpdb->prefix."wc_orders";
if($wpdb->get_var($wpdb->prepare("SHOW TABLES LIKE %s",$ot))===$ot){
 $rows=$wpdb->get_results("SELECT DATE(date_created_gmt) d,status,COUNT(*) n FROM $ot WHERE type=\"shop_order\" AND date_created_gmt>=UTC_TIMESTAMP()-INTERVAL 21 DAY GROUP BY DATE(date_created_gmt),status ORDER BY d DESC LIMIT 60",ARRAY_A);
}else{
 $rows=$wpdb->get_results("SELECT DATE(post_date_gmt) d,post_status status,COUNT(*) n FROM {$wpdb->posts} WHERE post_type=\"shop_order\" AND post_date_gmt>=UTC_TIMESTAMP()-INTERVAL 21 DAY GROUP BY DATE(post_date_gmt),post_status ORDER BY d DESC LIMIT 60",ARRAY_A);
}
foreach($rows as $r)echo "orders date=".$r["d"]." status=".preg_replace("/[^a-z0-9_-]/i","",$r["status"])." count=".$r["n"]."\n";
foreach(["woocommerce_new_order","woocommerce_order_status_pending_to_processing_notification","woocommerce_order_status_pending_to_on-hold_notification","phpmailer_init","wp_mail_failed"] as $h){
 $f=$GLOBALS["wp_filter"][$h]??null;$c=0;if($f)foreach($f->callbacks as $x)$c+=count($x);
 echo "hook_count ".$h."=".$c."\n";
}
echo "DISABLE_WP_CRON=".(defined("DISABLE_WP_CRON")&&DISABLE_WP_CRON?"true":"false")."\n";
'
echo "=== SERVER_MAIL_LOGS_SAFE_AGGREGATES ==="
for file in /var/log/mail.log /var/log/maillog /var/log/exim4/mainlog;do
  [[ ! -r "$file" ]] && continue
  echo "mail_log_present=$(basename "$file")"
  grep -Ei 'deferred|reject|bounce|temporarily|authentication failed|relay access denied' "$file" | tail -150 | sed -En 's/.*(deferred|reject|bounce|temporarily|authentication failed|relay access denied).*/MAIL_LOG_ERROR \1/ip' |sort|uniq -c || true
done
echo "=== SITE_CONNECTIVITY ==="
for p in / /shop/ /wp-login.php /my-account/;do
 code=$(curl --noproxy '*' -kLsS --max-time 20 --resolve vesta-cosmetics.ir:443:127.0.0.1 -o /dev/null -w '%{http_code}' "https://vesta-cosmetics.ir$p"||true)
 echo "site_path=$p status=$code"
done
echo "VESTA_MAIL_ORDER_READONLY_AUDIT_COMPLETE"
