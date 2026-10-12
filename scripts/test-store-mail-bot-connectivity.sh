#!/usr/bin/env bash
set -uo pipefail
echo '=== PHPMAILER REAL DELIVERY TEST (1 MESSAGE TO STORED SHOP ADMIN, NO ORDERS) ==='
docker exec vc-vesta php -d display_errors=0 -r '
require "/var/www/html/wp-load.php";
add_action("wp_mail_failed",function($e){
  $s=strtolower($e->get_error_message());
  $why="other";
  if(strpos($s,"authenticat")!==false||strpos($s,"535")!==false)$why="authentication";
  elseif(strpos($s,"connect")!==false||strpos($s,"timed out")!==false)$why="connection";
  elseif(strpos($s,"certificate")!==false||strpos($s,"ssl")!==false||strpos($s,"tls")!==false)$why="tls";
  elseif(strpos($s,"recipient")!==false||strpos($s,"sender")!==false)$why="address_policy";
  echo "wp_mail_failed_category=".$why."\n";
});
$to=get_option("admin_email");
if(!is_email($to)){echo "wp_mail_skipped_no_admin_email\n";exit(0);}
$domain=substr(strrchr($to,"@"),1);
echo "test_recipient_domain=".$domain."\n";
$ok=wp_mail($to,"Vesta website mail delivery check","This is a single technical email delivery test after the website migration. No order or customer data is included.");
echo "wp_mail_result=".($ok?"true":"false")."\n";
'
echo '=== WP MAIL SMTP MOST RECENT ERROR EVENT TYPES (NO MESSAGE CONTENT) ==='
docker exec vc-vesta php -d display_errors=0 -r '
require "/var/www/html/wp-load.php";global $wpdb;
$t=$wpdb->prefix."wpmailsmtp_debug_events";
if($wpdb->get_var($wpdb->prepare("SHOW TABLES LIKE %s",$t))!==$t){echo "debug_table_missing\n";exit;}
$r=$wpdb->get_results("SELECT event_type,created_at FROM $t ORDER BY id DESC LIMIT 15",ARRAY_A);
foreach($r as $a)echo "mail_event=".$a["event_type"]." at=".$a["created_at"]."\n";
'
echo '=== SMTP CONNECTION + CERTIFICATE (NO USERNAME OR PASSWORD) ==='
for host in server135s.irwebspace.com mail.cutellashop.ir; do
 echo "smtp_host=$host"
 echo -n 'resolution='
 getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1{print $1}' || true
 for port in 465 587; do
  if timeout 5 bash -c 'echo >/dev/tcp/"$1"/"$2"' bash "$host" "$port" >/dev/null 2>&1; then echo "port_$port=reachable"; else echo "port_$port=unreachable"; fi
 done
done
echo '=== TELEGRAM API GENERAL CONNECTION (NO BOT KEY) ==='
curl --max-time 12 -sS -o /dev/null -w 'telegram_base_http=%{http_code} connect=%{time_connect} ssl=%{time_appconnect}\n' https://api.telegram.org/ || true
echo '=== TELEGRAM SETTINGS SHAPE AND TOKEN PROBE (NO KEYS PRINTED) ==='
docker exec vc-vesta php -d display_errors=0 -r '
require "/var/www/html/wp-load.php";global $wpdb;
$options=$wpdb->get_results("SELECT option_name, option_value FROM {$wpdb->options} WHERE option_name LIKE \"telegram%\" OR option_name LIKE \"%notify%telegram%\" LIMIT 35",ARRAY_A);
$candidates=array();
foreach($options as $op) {
  $name=$op["option_name"];
  if(strlen($name)>120)continue;
  echo "telegram_option=".preg_replace("/[^a-z0-9_-]/i","",$name)."\n";
  $v=maybe_unserialize($op["option_value"]);
  $walk=function($value,$path)use(&$walk,&$candidates){
    if(!is_array($value))return;
    foreach($value as $key=>$vv) {
      $k=strtolower((string)$key);
      if(is_array($vv)){$walk($vv,$path.".".$k);continue;}
      if(preg_match("/token|chat_id|bot_api|bot_key|api_key/", $k))
        echo "telegram_field=".$path.".".preg_replace("/[^a-z0-9_-]/","",$k)." filled=".(!empty($vv)?"yes":"no")."\n";
      if(is_string($vv)&&preg_match("/^\\d{6,}:[A-Za-z0-9_-]{25,}$/D",trim($vv)))$candidates[]=trim($vv);
    }
  };
  if(is_array($v))$walk($v,$name);
}
$candidates=array_unique($candidates);
echo "token_candidate_count=".count($candidates)."\n";
foreach($candidates as $token) {
  $res=wp_remote_get("https://api.telegram.org/bot".$token."/getMe",array("timeout"=>12,"redirection"=>0));
  if(is_wp_error($res))echo "telegram_getme=transport_error\n";
  else {
    $code=wp_remote_retrieve_response_code($res);
    $data=json_decode(wp_remote_retrieve_body($res),true);
    echo "telegram_getme_http=".$code." ok=".(is_array($data)&&!empty($data["ok"])?"yes":"no")."\n";
  }
}
'
echo '=== BRIDGE UNAUTHENTICATED HEALTH (SHOULD DENY WITH 401/403, NEVER 500) ==='
for domain in vesta-cosmetics.ir cutellashop.ir; do
  action=vesta_bot_bridge
  [[ "$domain" == "cutellashop.ir" ]] && action=cutella_bot_bridge
  curl -sk --max-time 20 --resolve "$domain:443:127.0.0.1" -o /dev/null -w "$domain ajax_code=%{http_code} seconds=%{time_total}\n" "https://$domain/wp-admin/admin-ajax.php?action=$action" || true
done
echo STORE_MAIL_BOT_CONNECTION_TEST_DONE
