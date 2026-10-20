#!/usr/bin/env bash
# Vesta mail incident, read-only; never output addresses, credentials or customer fields.
set -euo pipefail
echo "AUDIT_NOW_UTC=$(date -u +%FT%TZ)"
docker exec vc-vesta php -d display_errors=0 -r '
require "/var/www/html/wp-load.php";
global $wpdb;
$cfg=get_option("wp_mail_smtp",[]);
$s=(array)($cfg["smtp"]??[]);
$m=(array)($cfg["mail"]??[]);
echo "SMTP_CONFIG host=".preg_replace("/[^a-zA-Z0-9.-]/","",(string)($s["host"]??"unset"))." port=".(int)($s["port"]??0)." encryption=".preg_replace("/[^a-z]/","",(string)($s["encryption"]??"unset"))." username_present=".(!empty($s["user"])?"yes":"no")."\\n";
echo "SMTP_FROM_DOMAIN=".(strpos((string)($m["from_email"]??""),"@")!==false?substr(strrchr($m["from_email"],"@"),1):"missing")." force_from=".(!empty($m["from_email_force"])?"yes":"no")."\\n";
echo "NATIVE_FROM_DOMAIN=".(strpos((string)get_option("woocommerce_email_from_address",""),"@")!==false?substr(strrchr(get_option("woocommerce_email_from_address"),"@"),1):"missing")."\\n";
$emails=WC()->mailer()->get_emails();
foreach($emails as $e)if(($e->id??"")==="new_order"){
 echo "WOOCOMMERCE_NEW_ORDER_ENABLED=".($e->is_enabled()?"yes":"no")." recipient_count=".count(array_filter(array_map("trim",explode(",",$e->get_recipient()))))."\\n";
}
$table=$wpdb->prefix."wpmailsmtp_debug_events";
if($wpdb->get_var($wpdb->prepare("SHOW TABLES LIKE %s",$table))===$table){
 $rows=$wpdb->get_results("SELECT created_at,event_type,content FROM $table WHERE created_at >= UTC_TIMESTAMP() - INTERVAL 30 HOUR ORDER BY id DESC LIMIT 500",ARRAY_A);
 $classify=function($text){
  $s=strtolower((string)$text);
  if(preg_match("/starttls command used when not advertised|starttls command failed/",$s))return "starttls-not-advertised";
  if(preg_match("/authentication failed|535|could not authenticate/",$s))return "auth";
  if(preg_match("/certificate|verify failed|tls handshake|stream_socket_enable_crypto/",$s))return "tls";
  if(preg_match("/recipient|rcpt|550|553|mailbox|relay denied/",$s))return "recipient-rejection";
  if(preg_match("/could not connect|connection refused|timeout|timed out/",$s))return "connect";
  return "other";
 };
 $summary=[];$latest=[];
 foreach($rows as $row) {
  $when=substr((string)$row["created_at"],0,13);$kind=$classify($row["content"]);
  $key="$when:$kind";$summary[$key]=($summary[$key]??0)+1;
  if(!isset($latest[$kind]))$latest[$kind]=(string)$row["created_at"];
 }
 krsort($summary);foreach(array_slice($summary,0,40,true) as $key=>$n)echo "MAIL_FAILURES hour_and_type=$key count=$n\\n";
 foreach($latest as $kind=>$when)echo "LATEST_MAIL_FAILURE kind=$kind utc=$when\\n";
 echo "MAIL_FAILURES_LAST_30H_ROWS=".count($rows)."\\n";
} else echo "SMTP_DEBUG_LOG_TABLE_MISSING\\n";
$since=strtotime("-30 hours");
$start=(int)get_option("vc_vesta_order_mail_watchdog_start",0);
echo "WATCHDOG_ENABLED_AT=".($start?gmdate("c",$start):"missing")."\\n";
$ids=wc_get_orders(["type"=>"shop_order","limit"=>100,"orderby"=>"date","order"=>"DESC","return"=>"ids"]);
$counts=[];
$recent=[];
foreach($ids as $id){
 $o=wc_get_order($id);if(!$o)continue;
 $created=$o->get_date_created();if(!$created||$created->getTimestamp()<$since)continue;
 $accepted=(string)$o->get_meta("_vc_vesta_admin_new_order_accepted",true);
 $ret=(int)$o->get_meta("_vc_vesta_admin_new_order_retries",true);
 $st=$o->get_status();
 $key=$accepted?(strpos($accepted,"native:")===0?"accepted_native":"accepted_watchdog"):($ret>=4?"retry_exhausted":"not_confirmed");
 $counts[$key]=($counts[$key]??0)+1;
 $counts["status:".$st]=($counts["status:".$st]??0)+1;
 if(count($recent)<15)$recent[]=[
 "created"=>$created->date("Y-m-d H:i:s"),"status"=>$st,"payment"=>$o->get_payment_method(),
 "marker"=>$key,"tries"=>$ret,"pending"=>wp_next_scheduled("vc_vesta_admin_new_order_watchdog",[(int)$id])?"yes":"no"
 ];
}
foreach($counts as $k=>$n)echo "RECENT_ORDERS_SUMMARY kind=".preg_replace("/[^a-z0-9:_-]/i","",$k)." count=$n\\n";
foreach($recent as $i=>$r)echo "RECENT_ORDER n=$i created=".$r["created"]." status=".$r["status"]." payment=".preg_replace("/[^a-zA-Z0-9_-]/","",$r["payment"])." delivery=".$r["marker"]." retries=".$r["tries"]." cron_pending=".$r["pending"]."\\n";
';
echo "=== DNS AUTHENTICATION (do not echo DKIM keys) ==="
for domain in vesta-cosmetics.ir;do
 dig @1.1.1.1 +time=4 +tries=1 +short MX "$domain" |head -3 |sed 's/^/MX /'
 dig @1.1.1.1 +time=4 +tries=1 +short TXT "$domain" |grep -Ei 'spf1'|sed 's/^/SPF /'|head -3 || true
 dmarc="$(dig @1.1.1.1 +time=4 +tries=1 +short TXT "_dmarc.$domain"|head -1)"
 echo "DMARC_PRESENT=$([[ "$dmarc" == *v=DMARC1* ]]&&echo yes||echo no)"
 for s in default mail selector1 selector2 google dkim;do
   txt="$(dig @1.1.1.1 +time=4 +tries=1 +short TXT "$s._domainkey.$domain"|head -1)"
   [[ -z "$txt" ]] || echo "DKIM_POSSIBLE_SELECTOR=$s configured=yes"
 done
done
echo "=== MTA RELAY ==="
for host in server135s.irwebspace.com mail.vesta-cosmetics.ir;do
  echo "SERVER=$host"
  for port in 465 587;do
  if timeout 3 bash -c 'echo >/dev/tcp/"$1"/"$2"' _ "$host" "$port" 2>/dev/null;then echo "PORT=$port reachable=yes";else echo "PORT=$port reachable=no";fi
  done
done
echo "MAIL_INCIDENT_READONLY_COMPLETE"
