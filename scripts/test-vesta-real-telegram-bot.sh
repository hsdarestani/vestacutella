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
$r=wp_remote_get($base."getMe",array("timeout"=>15,"redirection"=>0));
if(is_wp_error($r)){echo "bot_auth_transport_error=".preg_replace("/[^a-z0-9_-]/i","",$r->get_error_code())."\n";exit(22);}
$code=(int)wp_remote_retrieve_response_code($r);
$data=json_decode((string)wp_remote_retrieve_body($r),true);
$ok=($code===200&&is_array($data)&&!empty($data["ok"]));
echo "bot_getme_http=$code authorized=".($ok?"yes":"no")."\n";
if(!$ok)exit(23);
if(!preg_match("/^-?[0-9]{3,20}$/D",$chat)){echo "CHAT_ID_FORMAT_UNKNOWN_SKIP_TEST\n";exit(24);}
$msg="✅ تست اتصال ربات سفارش وستا پس از انتقال سرور (۱۲ اکتبر ۲۰۲۶). این پیام آزمایشی است و مربوط به سفارش واقعی نیست.";
$result=wp_remote_post($base."sendMessage",array("timeout"=>15,"redirection"=>0,"body"=>array("chat_id"=>$chat,"text"=>$msg,"disable_notification"=>"true")));
if(is_wp_error($result)){echo "bot_send_transport_error=".preg_replace("/[^a-z0-9_-]/i","",$result->get_error_code())."\n";exit(25);}
$scode=(int)wp_remote_retrieve_response_code($result);
$body=json_decode((string)wp_remote_retrieve_body($result),true);
$sent=($scode===200&&is_array($body)&&!empty($body["ok"]));
echo "bot_send_http=$scode delivered_to_configured_chat=".($sent?"yes":"no")."\n";
if(!$sent)exit(26);
'
echo '=== Store still healthy ==='
for p in / /shop/ /my-account/;do
 curl -ksS --max-time 25 --resolve vesta-cosmetics.ir:443:127.0.0.1 -o /dev/null -w "$p HTTP=%{http_code}\n" "https://vesta-cosmetics.ir$p"
done
echo VESTA_REAL_TELEGRAM_ORDER_ALERT_TEST_OK
