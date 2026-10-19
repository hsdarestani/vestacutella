#!/usr/bin/env bash
# Fix verified STARTTLS-not-advertised error using secure implicit TLS on port 465.
set -euo pipefail
umask 077
BACKUP="/srv/backups/vesta-smtp-implicit-ssl-$(date -u +%Y%m%dT%H%M%SZ)"
status(){ curl --noproxy '*' -kLsS --max-time 30 --resolve "$1:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$1$2"; }
for site in vesta-cosmetics.ir cutellashop.ir app.vesta-cosmetics.ir;do
 code="$(status "$site" /)";echo "PRECHECK $site $code";[[ "$code" == 200 ]] || exit 11
done
cert="$(timeout 12 openssl s_client -connect server135s.irwebspace.com:465 -servername server135s.irwebspace.com -verify_return_error -brief </dev/null 2>&1 || true)"
grep -q 'Verification: OK' <<< "$cert" || { echo "SMTP_IMPLICIT_TLS_CERT_NOT_VERIFIED";exit 12; }
echo "SMTP_IMPLICIT_TLS_CERT_VERIFIED"
docker exec vc-vesta php -d display_errors=0 -r '
require "/var/www/html/wp-load.php";
$o=get_option("wp_mail_smtp",[]);
$m=(array)($o["mail"]??[]);
$s=(array)($o["smtp"]??[]);
if(($m["mailer"]??"")!=="smtp"||($s["host"]??"")!=="server135s.irwebspace.com"||
   (int)($s["port"]??0)!==587||($s["encryption"]??"")!=="tls"||
   empty($s["auth"])||empty($s["user"])||empty($s["pass"])) {
  echo "SMTP_ORIGINAL_CONFIG_DRIFT_ABORT\n";exit(21);
}
$new=null;foreach(WC()->mailer()->get_emails() as $e)if(($e->id??"")==="new_order")$new=$e;
if(!$new||!$new->is_enabled())exit(22);
$rec=array_values(array_filter(array_map("trim",explode(",",$new->get_recipient())),"is_email"));
if(count($rec)!==1)exit(23);
echo "SMTP_PREFLIGHT_DONE recipient_count=1 recipient_domain=".substr(strrchr($rec[0],"@"),1)."\n";
'
mkdir -p "$BACKUP"; chmod 700 "$BACKUP"
docker exec vc-vesta php -d display_errors=0 -r 'require "/var/www/html/wp-load.php";echo serialize(get_option("wp_mail_smtp",[]));' > "$BACKUP/old-wp-mail-smtp.ser"
chmod 600 "$BACKUP/old-wp-mail-smtp.ser"
test -s "$BACKUP/old-wp-mail-smtp.ser"
changed=0
complete=0
rollback(){
 rc=$?
 trap - EXIT
 if [[ "$changed" == 1 && "$complete" != 1 ]];then
  echo "SMTP_SSL_465_ROLLBACK rc=$rc"
  docker cp "$BACKUP/old-wp-mail-smtp.ser" vc-vesta:/tmp/vc-mail-old-465.ser || true
  docker exec vc-vesta php -d display_errors=0 -r '
   require "/var/www/html/wp-load.php";
   $x=@unserialize(file_get_contents("/tmp/vc-mail-old-465.ser"),["allowed_classes"=>false]);
   if(is_array($x)&&isset($x["smtp"]))update_option("wp_mail_smtp",$x);
   echo "SMTP_SETTINGS_RESTORED\n";
  ' || true
  docker exec vc-vesta rm -f /tmp/vc-mail-old-465.ser || true
 fi
 exit "$rc"
}
trap rollback EXIT
docker exec vc-vesta php -d display_errors=0 -r '
 require "/var/www/html/wp-load.php";
 $opt=get_option("wp_mail_smtp",[]);
 if(($opt["smtp"]["encryption"]??"")!=="tls"||(int)($opt["smtp"]["port"]??0)!==587)exit(31);
 $opt["smtp"]["encryption"]="ssl";$opt["smtp"]["port"]=465;
 if(!update_option("wp_mail_smtp",$opt))exit(32);
 echo "SMTP_SSL_PORT_465_ENABLED\n";
'
changed=1
docker exec vc-vesta php -d display_errors=0 -r '
 require "/var/www/html/wp-load.php";
 $o=get_option("wp_mail_smtp",[]);$s=(array)($o["smtp"]??[]);
 if(($s["host"]??"")!=="server135s.irwebspace.com"||($s["encryption"]??"")!=="ssl"||(int)($s["port"]??0)!==465)exit(41);
 $new=null;foreach(WC()->mailer()->get_emails() as $e)if(($e->id??"")==="new_order")$new=$e;
 $rec=array_values(array_filter(array_map("trim",explode(",",$new->get_recipient())),"is_email"));
 if(count($rec)!==1)exit(42);
 add_action("wp_mail_failed",function($err){
 $m=strtolower((string)$err->get_error_message());
 $cat=strpos($m,"starttls")!==false?"starttls":(strpos($m,"auth")!==false?"authentication":(strpos($m,"ssl")!==false||strpos($m,"tls")!==false?"tls_other":"other"));
 echo "SMTP_SSL_TEST_FAILED category=$cat\n";
 },10,1);
 $sent=wp_mail($rec, "Vesta order email delivery check SSL 465 2026-10-19", "One technical delivery check from the WooCommerce shop after fixing the STARTTLS protocol mismatch. No customer or order data.","Content-Type: text/plain; charset=UTF-8");
 echo "SMTP_SSL_TEST_SMTP_ACCEPTED=".($sent?"yes":"no")."\n";
 if(!$sent)exit(43);
'
for site in vesta-cosmetics.ir cutellashop.ir app.vesta-cosmetics.ir;do
 code="$(status "$site" /)";echo "POSTCHECK $site $code";[[ "$code" == 200 ]] || exit 51
done
for page in /shop/ /cart/ /checkout/ /my-account/ /wp-login.php;do
 code="$(status vesta-cosmetics.ir "$page")";echo "CHECK $page $code";[[ "$code" == 200 || "$code" == 301 || "$code" == 302 ]] || exit 52
done
complete=1;trap - EXIT
echo "VESTA_SMTP_SSL465_DEPLOYED secure=yes no_customer_mail=yes backup=$BACKUP"
