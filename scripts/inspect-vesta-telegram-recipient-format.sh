#!/usr/bin/env bash
set -euo pipefail
F=/srv/vestacutella/runtime/vesta/wp-content/plugins/order-notification-for-telegram-bot/includes/common/helper/TelegramBot.php
echo '=== Plugin TelegramBot request and multiple-recipient logic ==='
sed -n '12,140p' "$F" | grep -vE '(^\s*//|var_dump|print_r)' | cut -c1-165 || true
echo '=== Configured chat identifier syntax (redacted) ==='
docker exec vc-vesta php -d display_errors=0 -r '
require "/var/www/html/wp-load.php";
$v=trim((string)get_option("onftb_setting_chatid",""));
echo "chat_value_length=".strlen($v)."\n";
echo "has_comma=".(strpos($v,",")!==false?"yes":"no")." has_semicolon=".(strpos($v,";")!==false?"yes":"no")." has_pipe=".(strpos($v,"|")!==false?"yes":"no")." has_at=".(strpos($v,"@")!==false?"yes":"no")."\n";
$parts=preg_split("/[;,|[:space:]]+/", $v,-1,PREG_SPLIT_NO_EMPTY);
echo "chat_candidate_parts=".count($parts)."\n";
foreach($parts as $i=>$p){
  echo "part_".$i."_type=".(preg_match("/^-?[0-9]{3,20}$/",$p)?"numeric":(preg_match("/^@[a-zA-Z0-9_]{4,32}$/",$p)?"public_channel":"unknown"))." length=".strlen($p)."\n";
}
'
echo VESTA_CHAT_FORMAT_DIAGNOSTIC_OK
