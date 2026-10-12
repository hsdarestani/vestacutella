#!/usr/bin/env bash
set -euo pipefail
echo '=== Actual configured WooCommerce Telegram bot validation ==='
docker exec vc-vesta php -d display_errors=0 -r '
require "/var/www/html/wp-load.php";
$token=trim((string)get_option("onftb_setting_token",""));
$chat=trim((string)get_option("onftb_setting_chatid",""));
$mode=(string)get_option("onftb_setting_is_use_google_script","");
echo "bot_token_configured=".($token!==""?"yes":"no")."\n";
echo "chat_configured=".($chat!==""?"yes":"no")."\n";
echo "google_script_mode=".preg_replace("/[^a-z0-9_-]/i","",$mode)."\n";
if($token===""||$chat===""){echo "CONFIG_INCOMPLETE\n";exit(20);}
if(!preg_match("/^[0-9]{6,}:[a-zA-Z0-9_-]{25,}$/D",$token)){echo "BOT_TOKEN_FORMAT_UNEXPECTED\n";exit(21);}
$base="https://api.telegram.org/bot".$token."/";
echo "=== Raw PHP cURL with explicit trusted tunnel for configured getMe URL ===";
$h=curl_init($base."getMe");
curl_setopt($h,CURLOPT_CONNECT_TO,array("api.telegram.org:443:172.18.0.1:11443"));
curl_setopt($h,CURLOPT_RETURNTRANSFER,true);curl_setopt($h,CURLOPT_FOLLOWLOCATION,false);
curl_setopt($h,CURLOPT_CONNECTTIMEOUT,7);curl_setopt($h,CURLOPT_TIMEOUT,14);
$raw=curl_exec($h);
$rawCode=(int)curl_getinfo($h,CURLINFO_RESPONSE_CODE);$rawErr=curl_errno($h);
echo "getme_raw_http=$rawCode errno=$rawErr time_total=".curl_getinfo($h,CURLINFO_TOTAL_TIME)."\n";
curl_close($h);
if($rawErr===0&&$rawCode===200){$decoded=json_decode((string)$raw,true);echo "raw_authenticated=".(!empty($decoded["ok"])?"yes":"no")."\n";}
add_action("http_api_curl",function($handle,$args,$url){if(wp_parse_url($url,PHP_URL_HOST)==="api.telegram.org")echo "telegram_http_api_curl_hook=seen\n";},110,3);
$r=wp_remote_get($base."getMe",array("timeout"=>15,"redirection"=>0));
if(is_wp_error($r)){echo "bot_auth_transport_error=".preg_replace("/[^a-z0-9_-]/i","",$r->get_error_code())."\n";exit(22);}
$code=(int)wp_remote_retrieve_response_code($r);
$data=json_decode((string)wp_remote_retrieve_body($r),true);
$ok=($code===200&&is_array($data)&&!empty($data["ok"]));
echo "bot_getme_http=$code authorized=".($ok?"yes":"no")."\n";
if(!$ok)exit(23);
$chats=array_values(array_filter(array_map("trim",explode(",",$chat)),function($c){return $c!=="";}));
echo "configured_chat_count=".count($chats)."\n";
if(count($chats)<1||count($chats)>5){echo "UNEXPECTED_CHAT_COUNT\n";exit(24);}
foreach($chats as $dest){if(!preg_match("/^-?[0-9]{3,20}$/D",$dest)){echo "INVALID_CONFIGURED_CHAT_FORMAT\n";exit(24);}}
$msg="✅ تست اتصال ربات سفارش وستا پس از انتقال سرور (۱۲ اکتبر ۲۰۲۶). این پیام آزمایشی است و مربوط به سفارش واقعی نیست.";
$passed=0;
foreach($chats as $idx=>$dest){
  $result=wp_remote_post($base."sendMessage",array("timeout"=>20,"redirection"=>0,"body"=>array("chat_id"=>$dest,"text"=>$msg,"disable_notification"=>"true")));
  if(is_wp_error($result)){echo "recipient_index=".$idx." transport_error=".preg_replace("/[^a-z0-9_-]/i","",$result->get_error_code())."\n";continue;}
  $scode=(int)wp_remote_retrieve_response_code($result);
  $body=json_decode((string)wp_remote_retrieve_body($result),true);
  $sent=($scode===200&&is_array($body)&&!empty($body["ok"]));
  echo "recipient_index=".$idx." http=".$scode." telegram_accepted=".($sent?"yes":"no")."\n";
  if($sent)$passed++;
}
echo "successfully_tested_chats=".$passed."/".count($chats)."\n";
if($passed!==count($chats))exit(26);
'
echo '=== Store still healthy ==='
for p in / /shop/ /my-account/;do
 curl -ksS --max-time 25 --resolve vesta-cosmetics.ir:443:127.0.0.1 -o /dev/null -w "$p HTTP=%{http_code}\n" "https://vesta-cosmetics.ir$p"
done
echo VESTA_REAL_TELEGRAM_ORDER_ALERT_TEST_OK
