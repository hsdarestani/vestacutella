#!/usr/bin/env bash
set -uo pipefail
BASE=/srv/vestacutella/runtime
echo '=== MAIL DNS AND ROUTING ==='
for d in vesta-cosmetics.ir cutellashop.ir; do
 echo "domain=$d"
 if command -v dig >/dev/null; then
  mx="$(dig @1.1.1.1 +short MX "$d" | awk 'NR==1{print $2}' | sed 's/\.$//')"
  echo "mx=$mx"
  [[ -z "$mx" ]] || { echo -n 'mx_A='; dig @1.1.1.1 +short A "$mx" | head -n 3; echo -n 'mx_AAAA='; dig @1.1.1.1 +short AAAA "$mx" | head -n 3; }
 fi
done
echo '=== WORDPRESS MAIL AND BOT CONFIG (NO SECRETS) ==='
for site in vesta cutella; do
 echo "-- site=$site --"
 docker exec -e VC_SITE="$site" "vc-$site" php -d display_errors=0 -r '
 require "/var/www/html/wp-load.php";
 global $wpdb;
 $mail=get_option("wp_mail_smtp",array());$mail=is_array($mail)?$mail:array();
 echo "SMTP_option_present=".($mail?"yes":"no")."\n";
 echo "SMTP_mailer_type=".(!empty($mail["mail"]["mailer"])?preg_replace("/[^a-z0-9_-]/i","", $mail["mail"]["mailer"]):"not_set")."\n";
 foreach(array("smtp","mail") as $section){
  $config=isset($mail[$section])&&is_array($mail[$section])?$mail[$section]:array();
  foreach(array("host","port","encryption","autotls","auth") as $key){
   if(!array_key_exists($key,$config))continue;
   $value=(string)$config[$key];
   if($key==="host")$value=preg_replace("/[^a-z0-9._-]/i","",$value);
   elseif($key==="port")$value=(string)(int)$value;
   elseif($key==="encryption")$value=preg_replace("/[^a-z0-9_-]/i","",$value);
   else $value=empty($value)?"no":"yes";
   echo "smtp.".$section.".".$key."=".$value."\n";
  }
  foreach(array("user","pass","password","api_key","mailer","from_email") as $key)if(array_key_exists($key,$config)){
    if($key==="from_email"){$parts=explode("@",(string)$config[$key]);echo "smtp.from_email_domain=".(count($parts)==2?$parts[1]:"not_set")."\n";}
    else echo "smtp.".$section.".".$key."_present=".(empty($config[$key])?"no":"yes")."\n";
  }
 }
 foreach(array("woocommerce_email_from_address","vesta_bot_bridge_token","cutella_bot_bridge_token","telegram_notify_option_name_tab3") as $key) {
  $v=get_option($key,null);
  echo "setting=".$key." present=".(!empty($v)?"yes":"no")." type=".gettype($v)."\n";
  if($key==="telegram_notify_option_name_tab3" && is_array($v)) {
    foreach($v as $a=>$b) echo "telegram_config_key=".preg_replace("/[^a-z0-9_-]/i","",$a)." filled=".(!empty($b)?"yes":"no")."\n";
  }
 }
 echo "REST_BOT_ROUTE_LIST:\n";
 foreach(rest_get_server()->get_routes() as $route=>$handlers)if(preg_match("/bot|telegram|order|vestaland|cutella/i",$route))echo "rest_route=".preg_replace("/[^a-z0-9_\/{}?.,()-]/i","",$route)."\n";
 echo "MAIL_HOOKS:\n";
 foreach(array("phpmailer_init","wp_mail_failed","woocommerce_new_order","woocommerce_order_status_processing","woocommerce_order_status_completed") as $hook){
  global $wp_filter; $h=isset($wp_filter[$hook])?$wp_filter[$hook]:null;
  $n=0;if($h)foreach($h->callbacks as $group)$n+=count($group);
  echo "hook=".$hook." callbacks=".$n."\n";
 }
 '
 echo '-- plugin event hooks and routes --'
 for pl in order-notification-for-telegram-bot vesta-bot-bridge cutella-bot-bridge; do
  d="$BASE/$site/wp-content/plugins/$pl"
  [[ -d "$d" ]] || continue
  echo "plugin=$pl"
  grep -RhoE --include='*.php' "(add_action|add_filter)\(['\"][A-Za-z0-9_]+|register_rest_route\(['\"][A-Za-z0-9_/-]+" "$d" 2>/dev/null | head -n 50 | sort -u | cut -c1-115 || true
 done
 echo '-- recent mail debug event table (no content) --'
 docker exec "vc-$site" php -d display_errors=0 -r '
 require "/var/www/html/wp-load.php";global $wpdb;
 foreach(array($wpdb->prefix."wpmailsmtp_debug_events",$wpdb->prefix."wpmailsmtp_tasks_meta") as $t) {
  if($wpdb->get_var($wpdb->prepare("SHOW TABLES LIKE %s",$t))===$t) {
    echo "mail_debug_table=".$t." rows=".(int)$wpdb->get_var("SELECT COUNT(*) FROM $t")."\n";
    $cols=$wpdb->get_col("SHOW COLUMNS FROM $t",0);
    echo "mail_debug_columns=".implode(",",array_filter($cols,function($v){return !preg_match("/message|content|email|address/i",$v);}))."\n";
   }
 }
 '
done
echo '=== SMTP HOST CONNECTIVITY (NO LOGIN) ==='
for host in mail.vesta-cosmetics.ir mail.cutellashop.ir; do
 echo "host=$host"
 for port in 25 465 587; do
  timeout 3 bash -c 'echo >/dev/tcp/"$1"/"$2"' bash "$host" "$port" >/dev/null 2>&1 && echo "port=$port tcp=yes" || echo "port=$port tcp=no"
 done
done
echo STORE_MAIL_BOT_DEEP_DIAG_DONE
