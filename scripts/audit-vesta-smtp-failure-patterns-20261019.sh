#!/usr/bin/env bash
set -uo pipefail
echo "SMTP_FOLLOWUP_AT=$(date -u +%FT%TZ)"
docker exec vc-vesta php -d display_errors=0 -r '
require "/var/www/html/wp-load.php";
global $wpdb;
$t=$wpdb->prefix."wpmailsmtp_debug_events";
$rows=$wpdb->get_results("SELECT event_type,created_at,content FROM $t WHERE created_at>=UTC_TIMESTAMP()-INTERVAL 5 HOUR ORDER BY id DESC LIMIT 130",ARRAY_A);
$counts=[];
foreach($rows as $r){
 $m=strtolower((string)($r["content"]??""));
 $k=preg_match("/authentication failed|could not authenticate|535|invalid credentials/",$m)?"auth":(preg_match("/certificate|peer verify|verification failed|expired/",$m)?"certificate":(preg_match("/starttls|stream_socket_enable_crypto|enable crypto|tls handshake/",$m)?"crypto":(preg_match("/could not connect|connection refused|timed out|timeout/",$m)?"connect":(preg_match("/recipient|rcpt|relay denied/",$m)?"recipient":"other"))));
 $key=substr(hash("sha256",$m),0,9).":".$k;
 if(!isset($counts[$key]))$counts[$key]=["total"=>0,"first"=>(string)$r["created_at"],"last"=>(string)$r["created_at"],"bytes"=>strlen($m)];
 $counts[$key]["total"]++;
 $counts[$key]["first"]=(string)$r["created_at"];
}
foreach($counts as $k=>$x)echo "FAILURE_PATTERN sig=".$k." n=".$x["total"]." bytes=".$x["bytes"]." first=".$x["first"]." last=".$x["last"]."\n";
'
echo "=== SERVER_CERTIFICATE_FROM_PHP_CONTAINER ==="
docker exec vc-vesta php -d display_errors=0 -r '
$host="server135s.irwebspace.com";
$ctx=stream_context_create(["ssl"=>["verify_peer"=>true,"verify_peer_name"=>true,"peer_name"=>$host,"SNI_enabled"=>true]]);
$err=0;$msg="";
$socket=@stream_socket_client("ssl://".$host.":465",$err,$msg,8,STREAM_CLIENT_CONNECT,$ctx);
echo "PHP_TLS_VERIFICATION=".($socket?"pass":"fail")."\n";
if($socket)fclose($socket);
'
echo "MAIL_DIAG_NO_MAIL_SENT"
