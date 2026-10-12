#!/usr/bin/env bash
set -uo pipefail
echo '=== Current Cloudflare mail DNS check 2026-10-12 ==='
for resolver in 1.1.1.1 8.8.8.8; do
 echo "resolver=$resolver"
 for name in mail.vesta-cosmetics.ir pop.vesta-cosmetics.ir; do
   echo -n "$name A="; dig @"$resolver" +time=4 +tries=1 +short A "$name" | paste -sd',' - || true
 done
 echo "vesta MX:"; dig @"$resolver" +time=4 +tries=1 +short MX vesta-cosmetics.ir | head -n 5
done
echo '=== MX target A and port 25 ==='
MX="$(dig @1.1.1.1 +time=4 +tries=1 +short MX vesta-cosmetics.ir | sort -n | head -n 1 | awk '{print $2}' | sed 's/\.$//')"
echo "mx_target=$MX"
if [[ -n "$MX" ]]; then
 echo -n "mx_target_A="; dig @1.1.1.1 +short A "$MX" | paste -sd',' -
 timeout 6 bash -c 'echo >/dev/tcp/"$1"/25' bash "$MX" >/dev/null 2>&1 && echo 'mx_smtp_port25=reachable' || echo 'mx_smtp_port25=unreachable'
fi
echo '=== Direct mail subdomain service ports ==='
for port in 25 110 143 465 587 993 995; do
 timeout 4 bash -c 'echo >/dev/tcp/"$1"/"$2"' bash mail.vesta-cosmetics.ir "$port" >/dev/null 2>&1 && echo "mail_tcp_$port=reachable" || echo "mail_tcp_$port=unreachable"
done
echo '=== PHP WordPress SMTP state ==='
docker exec vc-vesta php -d display_errors=0 -r '
require "/var/www/html/wp-load.php";
$o=get_option("wp_mail_smtp",array());
echo "wp_mail_smtp_active=".((array)$o?"yes":"no")."\n";
$cfg=(array)($o["smtp"]??array());
echo "configured_smtp_hostname=".preg_replace("/[^a-z0-9._-]/i","",(string)($cfg["host"]??"unset"))."\n";
echo "configured_smtp_port=".(int)($cfg["port"]??0)."\n";
$to=get_option("admin_email");
if(!is_email($to)){echo "admin_email_not_configured\n";exit(2);}
add_action("wp_mail_failed",function($e){
 $m=strtolower($e->get_error_message());
 echo "wp_mail_failed_reason=".(strpos($m,"authenticat")!==false?"auth":(strpos($m,"connect")!==false?"connect":(strpos($m,"ssl")!==false?"ssl":"other")))."\n";
});
$result=wp_mail($to,"Vesta mail DNS post-change verification 2026-10-12","This is one controlled test email after changing mail.vesta-cosmetics.ir to DNS only. No customer data or order is included.");
echo "test_mail_submitted=".($result?"yes":"no")."\n";
if(!$result)exit(3);
'
echo '=== Host cron and Telegram relay state ==='
systemctl is-active cron || true
systemctl is-active vesta-telegram-strato-tunnel || true
echo VESTA_MAIL_DNS_POSTCHANGE_CHECK_END
