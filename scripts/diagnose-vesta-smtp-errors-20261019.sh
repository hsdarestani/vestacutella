#!/usr/bin/env bash
# Classify recent SMTP debug failures without exposing mail content or addresses.
set -euo pipefail
docker exec vc-vesta php -d display_errors=0 -r '
require "/var/www/html/wp-load.php";
global $wpdb;
$settings=get_option("wp_mail_smtp",[]);
$m=is_array($settings)&&isset($settings["mail"])?(array)$settings["mail"]:[];
$s=is_array($settings)&&isset($settings["smtp"])?(array)$settings["smtp"]:[];
foreach(["from_email_force","from_name_force","return_path","from_email","mailer"] as $k){
 if($k==="from_email"){echo "MAIL_FORCE_FROM_domain=". (strpos((string)($m[$k]??""),"@")!==false?substr(strrchr($m[$k],"@"),1):"unset")."\n";continue;}
 if($k==="mailer"){echo "MAIL_MAILER=".preg_replace("/[^a-zA-Z0-9_-]/","",(string)($m[$k]??"unset"))."\n";continue;}
 echo "MAIL_OPTION_".$k."=".(!empty($m[$k])?"yes":"no")."\n";
}
echo "SMTP_AUTOTLS=".(!empty($s["autotls"])?"yes":"no")." SMTP_SECURE=".preg_replace("/[^a-z0-9_-]/i","",(string)($s["encryption"]??"unset"))."\n";
$t=$wpdb->prefix."wpmailsmtp_debug_events";
if($wpdb->get_var($wpdb->prepare("SHOW TABLES LIKE %s",$t))!==$t){echo "DEBUG_EVENTS_MISSING\n";exit;}
$rs=$wpdb->get_results("SELECT * FROM $t ORDER BY id DESC LIMIT 100",ARRAY_A);
function kind($s){
 $s=strtolower((string)$s);
 $patterns=[
 "authentication"=>"/authenticat|535[ -]|username and password|invalid credential|wrong password|login failed|invalid login/",
 "tls_certificate"=>"/certificate|tls|ssl|handshake|starttls|encryption|crypto/",
 "smtp_connection"=>"/could not connect|connect\\(\\) failed|connection refused|timeout|timed out|network unreachable|failed to connect|host not found|name resolution/",
 "recipient_rejected"=>"/recipient|relay access denied|mailbox unavailable|rcpt to|address rejected|unknown user/",
 "sender_rejected"=>"/sender|send as|from address|mail from|not allowed to send|unauthorized sender|not permitted to send|spoof/",
 "mail_rate_limit"=>"/rate limit|too many|quota|daily limit|sending limit|limit exceeded|429/",
 "message_rejected"=>"/data not accepted|message rejected|550|554|552|blocked|spam|policy/",
 "php_error"=>"/fatal|exception|error in wp_mail|undefined function|uncaught/",
 ];
 foreach($patterns as $name=>$pattern)if(preg_match($pattern,$s))return $name;
 return "unknown";
}
$totals=[];
foreach($rs as $row){
 $text=(string)($row["content"]??$row["message"]??$row["description"]??"");
 if($text==="")foreach($row as $k=>$v)if(preg_match("/content|message|details|error/i",$k) && is_scalar($v))$text.=" ".(string)$v;
 $cat=kind($text);
 $totals[$cat]=($totals[$cat]??0)+1;
 $codes=[];
 if(preg_match_all("/(?<!\\d)(4[0-9]{2}|5[0-9]{2})(?!\\d)/",$text,$matches))$codes=array_values(array_unique($matches[1]));
 if(count($totals)>100)break;
 echo "SMTP_EVENT date=".substr((string)($row["created_at"]??""),0,10)." kind=$cat codes=".implode(",",$codes)." bytes=".strlen($text)."\n";
}
foreach($totals as $k=>$n) echo "SMTP_FAILURE_CATEGORY $k $n\n";
';
echo "=== CHECK SMTP CERTIFICATE AND STARTTLS CAPABILITY ==="
for h in server135s.irwebspace.com mail.vesta-cosmetics.ir; do
 output="$(timeout 10 openssl s_client -connect "$h:587" -starttls smtp -servername "$h" -brief </dev/null 2>&1 || true)"
 echo "TLS_HOST=$h"
 if grep -Eq 'Protocol version: TLSv1\.[23]|Protocol *: TLSv1\.[23]' <<< "$output";then echo "TLS_HANDSHAKE=yes";else echo "TLS_HANDSHAKE=unconfirmed";fi
 if grep -qi 'Verification: OK' <<< "$output";then echo "TLS_CERT_VERIFIED=yes";else echo "TLS_CERT_VERIFIED=unconfirmed";fi
done
echo "SMTP_ERROR_FORENSIC_COMPLETE"
