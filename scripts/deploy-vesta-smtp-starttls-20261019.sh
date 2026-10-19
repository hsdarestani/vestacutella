#!/usr/bin/env bash
# Correct WooCommerce SMTP transport to verified STARTTLS on port 587.
# Makes a one-key settings change with root-only backup, rollback, and one admin mail.
set -euo pipefail
umask 077
BACKUP="/srv/backups/vesta-smtp-starttls-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$BACKUP"
chmod 700 "$BACKUP"
status() { curl -kLsS --noproxy '*' --max-time 22 --resolve "$1:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$1$2"; }
echo "SMTP_DEPLOY_PREFLIGHT_UTC=$(date -u +%FT%TZ)"
for domain in vesta-cosmetics.ir cutellashop.ir app.vesta-cosmetics.ir;do
  code="$(status "$domain" /)"
  echo "PRECHECK $domain status=$code"
  [[ "$code" == 200 ]] || exit 10
done
# Require a currently valid server identity before enabling authenticated SMTP.
tls="$(timeout 12 openssl s_client -starttls smtp -connect server135s.irwebspace.com:587 -servername server135s.irwebspace.com -verify_return_error -brief </dev/null 2>&1 || true)"
grep -q 'Verification: OK' <<< "$tls" || { echo "ERROR SMTP_SERVER_TLS_CERTIFICATE_NOT_VERIFIED";exit 11; }
echo "SMTP_TLS_CERTIFICATE_VERIFIED"

# Never echo or log the saved SMTP credentials.
docker exec vc-vesta php -d display_errors=0 -r '
  require "/var/www/html/wp-load.php";
  $x=get_option("wp_mail_smtp",[]);
  if(!is_array($x)||!isset($x["smtp"])||!is_array($x["smtp"])){echo "SMTP_OPTION_MISSING\n";exit(21);}
  $s=$x["smtp"];
  $m=isset($x["mail"])&&is_array($x["mail"])?$x["mail"]:[];
  if(($s["host"]??"")!=="server135s.irwebspace.com"||(int)($s["port"]??0)!==587||
     empty($s["auth"])||empty($s["user"])||empty($s["pass"])||($m["mailer"]??"")!=="smtp"){
      echo "SMTP_CONFIG_DRIFT_ABORT\n";exit(22);
  }
  if(($s["encryption"]??"")!=="none"){echo "SMTP_ENCRYPTION_NOT_EXPECTED\n";exit(23);}
  if(!function_exists("WC")){echo "WC_NOT_AVAILABLE\n";exit(24);}
  $emails=WC()->mailer()->get_emails();
  $new=null;
  foreach($emails as $e)if(($e->id??"")==="new_order")$new=$e;
  if(!$new||!$new->is_enabled()||!is_email(trim(explode(",",$new->get_recipient())[0]))){
     echo "WC_NEW_ORDER_EMAIL_NOT_READY\n";exit(25);
  }
  echo "SMTP_CONFIG_PREFLIGHT_OK notification_recipient_domain=".substr(strrchr(trim(explode(",",$new->get_recipient())[0]),"@"),1)."\n";
'
docker exec vc-vesta php -d display_errors=0 -r 'require "/var/www/html/wp-load.php";echo serialize(get_option("wp_mail_smtp",[]));' > "$BACKUP/wp_mail_smtp-before.ser"
test -s "$BACKUP/wp_mail_smtp-before.ser"
chmod 600 "$BACKUP/wp_mail_smtp-before.ser"
echo "SMTP_BACKUP_SAVED root_private=yes"

changed=0
complete=0
rollback() {
 local rc=$?
 trap - EXIT
 if [[ "$changed" == 1 && "$complete" != 1 ]]; then
   echo "SMTP_STARTTLS_ROLLBACK reason_code=$rc"
   docker cp "$BACKUP/wp_mail_smtp-before.ser" vc-vesta:/tmp/vc-vesta-mail-rollback.ser || true
   docker exec vc-vesta php -d display_errors=0 -r '
     require "/var/www/html/wp-load.php";
     $original=@unserialize(file_get_contents("/tmp/vc-vesta-mail-rollback.ser"),["allowed_classes"=>false]);
     if(!is_array($original)||!isset($original["smtp"]))exit(2);
     update_option("wp_mail_smtp",$original);
     echo "SMTP_ORIGINAL_SETTINGS_RESTORED\n";
   ' || true
   docker exec vc-vesta rm -f /tmp/vc-vesta-mail-rollback.ser || true
 fi
 exit "$rc"
}
trap rollback EXIT

docker exec vc-vesta php -d display_errors=0 -r '
 require "/var/www/html/wp-load.php";
 $o=get_option("wp_mail_smtp",[]);
 if(($o["smtp"]["host"]??"")!=="server135s.irwebspace.com"||
     ($o["smtp"]["encryption"]??"")!=="none")exit(31);
 $o["smtp"]["encryption"]="tls";
 if(!update_option("wp_mail_smtp",$o))exit(32);
 echo "STARTTLS_SETTING_APPLIED port_587=yes\n";
'
changed=1
docker exec vc-vesta php -d display_errors=0 -r '
 require "/var/www/html/wp-load.php";
 $o=get_option("wp_mail_smtp",[]);
 if(($o["smtp"]["encryption"]??"")!=="tls"||($o["smtp"]["host"]??"")!=="server135s.irwebspace.com"||(int)($o["smtp"]["port"]??0)!==587)exit(40);
 $emails=WC()->mailer()->get_emails();$new=null;
 foreach($emails as $email)if(($email->id??"")==="new_order")$new=$email;
 if(!$new||!$new->is_enabled())exit(41);
 $recipients=array_map("trim",explode(",",$new->get_recipient()));
 $to=$recipients[0]??"";
 if(!is_email($to))exit(42);
 $domain=substr(strrchr($to,"@"),1);
 echo "ORDER_NOTIFICATION_TEST recipient_domain=".$domain."\n";
 add_action("wp_mail_failed",function($err){
   $s=strtolower($err->get_error_message());
   $cat=(strpos($s,"auth")!==false||strpos($s,"535")!==false)?"authentication":
      ((strpos($s,"ssl")!==false||strpos($s,"tls")!==false||strpos($s,"certificate")!==false)?"tls_certificate":
      ((strpos($s,"connect")!==false||strpos($s,"timeout")!==false)?"connection":"other"));
   echo "CONTROLLED_EMAIL_FAILED category=".$cat."\n";
 });
 $ok=wp_mail($to,"Vesta: order email SMTP check 2026-10-19",
  "Technical test: new-order WooCommerce notification delivery using authenticated STARTTLS. No order or customer data.");
 echo "CONTROLLED_EMAIL_SMTP_ACCEPTED=".($ok?"yes":"no")."\n";
 if(!$ok)exit(43);
'
for domain in vesta-cosmetics.ir cutellashop.ir app.vesta-cosmetics.ir;do
 code="$(status "$domain" /)"
 echo "POSTCHECK $domain status=$code"
 [[ "$code" == 200 ]] || exit 50
done
for path in /shop/ /cart/ /checkout/ /my-account/ /wp-login.php;do
 code="$(status vesta-cosmetics.ir "$path")"
 echo "VESTA_ROUTE $path status=$code"
 [[ "$code" == 200 || "$code" == 301 || "$code" == 302 ]] || exit 51
done
complete=1
trap - EXIT
echo "VESTA_ORDER_SMTP_STARTTLS_REPAIRED test_message_submitted=yes backup=$BACKUP"
