#!/usr/bin/env bash
set -euo pipefail
echo "=== SMTP HOST DNS ==="
for host in server135s.irwebspace.com mail.vesta-cosmetics.ir smtp.vesta-cosmetics.ir;do
 echo "HOST $host IPv4=$(getent ahostsv4 "$host" | awk 'NR==1{print $1}' || true)"
done
echo "=== WORDPRESS SMTP AUTH IMPLEMENTATION ==="
docker exec vc-vesta php -d display_errors=0 -r '
require "/var/www/html/wp-load.php";
$conf=get_option("wp_mail_smtp",[]);
$c=isset($conf["smtp"])?(array)$conf["smtp"]:[];
$u=(string)($c["user"]??"");
$p=(string)($c["pass"]??"");
echo "smtp_username_domain=".(strpos($u,"@")!==false?substr(strrchr($u,"@"),1):"not_an_email")."\n";
echo "username_present=".($u!==""?"yes":"no")." stored_password_length=".strlen($p)."\n";
echo "phpmailer_available=".(class_exists("\\PHPMailer\\PHPMailer\\PHPMailer")?"yes":"no")."\n";
foreach(["\\WPMailSMTP\\Helpers\\Crypto","\\WPMailSMTP\\Helpers\\CryptoHelper","\\WPMailSMTP\\Options","\\WPMailSMTP\\MailCatcher"] as $class){
 echo "class ".preg_replace("/[^a-zA-Z0-9\\\\]/","",$class)."=".(class_exists($class)?"yes":"no");
 if(class_exists($class)){
  foreach(["decrypt","get","get_group"] as $meth){
   if(method_exists($class,$meth)){
    $m=new ReflectionMethod($class,$meth);
    echo " method_".$meth."=".($m->isStatic()?"static":"instance");
   }
  }
 }
 echo "\n";
}
echo "phpmailer_init_filters=".(isset($GLOBALS["wp_filter"]["phpmailer_init"])?count($GLOBALS["wp_filter"]["phpmailer_init"]->callbacks):0)."\n";
';
echo SMTP_CONFIG_IMPLEMENTATION_DONE
