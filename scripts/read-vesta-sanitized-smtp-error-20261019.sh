#!/usr/bin/env bash
set -euo pipefail
docker exec vc-vesta php -d display_errors=0 -r '
require "/var/www/html/wp-load.php";global $wpdb;
$t=$wpdb->prefix."wpmailsmtp_debug_events";
$row=$wpdb->get_row("SELECT content FROM $t WHERE created_at>=UTC_TIMESTAMP()-INTERVAL 3 HOUR ORDER BY id DESC LIMIT 1",ARRAY_A);
$m=(string)($row["content"]??"");
if(!$m){echo "NO_RECENT_ERROR_TEXT\n";exit;}
$m=preg_replace("/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}/","[redacted-email]",$m);
$m=preg_replace("/\\b(?:[0-9]{1,3}\\.){3}[0-9]{1,3}\\b/","[redacted-ip]",$m);
$m=preg_replace("/(password|token|secret|user(name)?)\\s*[:=]\\s*\\S+/i","$1=[redacted]",$m);
$m=preg_replace("/[A-Za-z0-9_-]{28,}/","[redacted]",$m);
$m=substr(preg_replace("/[\\r\\n\\t]+/"," ",$m),0,210);
echo "LATEST_WP_MAIL_SMTP_ERROR_REDACTED=".$m."\n";
'
echo "=== SMTP_PUBLIC_TLS_PEER ==="
timeout 12 openssl s_client -starttls smtp -connect server135s.irwebspace.com:587 -servername server135s.irwebspace.com -verify_return_error -brief </dev/null 2>&1 |grep -E "Protocol version:|Verification:" |head -4 || true
echo SAFE_SMTP_ERROR_DETAIL_DONE
