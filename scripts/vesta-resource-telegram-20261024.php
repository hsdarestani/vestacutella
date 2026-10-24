<?php
// This CLI-only admin alert reuses existing WordPress Telegram bot options.
if (PHP_SAPI !== 'cli') exit(20);
$root = '/var/www/html/wp-load.php';
if (!is_file($root)) exit(21);
require $root;
$message = trim((string)getenv('VESTA_RESOURCE_ALERT_TEXT'));
if ($message === '' || strlen($message) > 700) exit(22);
$token = trim((string)get_option('onftb_setting_token', ''));
$raw = (string)get_option('onftb_setting_chatid', '');
$chats = array_values(array_unique(array_filter(array_map('trim', explode(',', $raw)))));
if (!preg_match('/^[0-9]{6,}:[a-zA-Z0-9_-]{25,}$/D', $token) || count($chats) < 1 || count($chats) > 5) {
  echo "ALERT_TELEGRAM_NOT_CONFIGURED\n";
  exit(23);
}
$sent=0;
foreach($chats as $chat) {
 if (!preg_match('/^-?[0-9]{3,20}$/D',$chat)) continue;
 $r=wp_remote_post('https://api.telegram.org/bot'.$token.'/sendMessage', array(
  'timeout'=>9,
  'body'=>array('chat_id'=>$chat,'text'=>$message,'disable_web_page_preview'=>'true')
 ));
 if(!is_wp_error($r) && wp_remote_retrieve_response_code($r)===200) $sent++;
}
echo "ALERT_TELEGRAM_SENT=$sent TARGETS=".count($chats)."\n";
if ($sent!==count($chats)) exit(24);
