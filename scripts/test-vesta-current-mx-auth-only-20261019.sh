#!/usr/bin/env bash
# One login-only SMTP AUTH attempt with saved credentials to the CURRENT MX server.
# Never sends messages, prints credentials, or changes settings.
set -euo pipefail
echo "=== MX_CERTIFICATE ==="
dig @1.1.1.1 +time=3 +tries=1 +short -x 93.95.27.75 | head -4 || true
timeout 12 openssl s_client -starttls smtp -connect mail.vesta-cosmetics.ir:587 -servername mail.vesta-cosmetics.ir -showcerts </dev/null 2>/dev/null | openssl x509 -noout -subject -ext subjectAltName 2>/dev/null | head -15 || true
echo "=== TEST AUTH AGAINST CURRENT MAIL HOST (NO SEND) ==="
docker exec vc-vesta php -d display_errors=0 -r '
require "/var/www/html/wp-load.php";
$opts=get_option("wp_mail_smtp",[]);
$c=isset($opts["smtp"])?(array)$opts["smtp"]:[];
$user=(string)($c["user"]??"");$stored=(string)($c["pass"]??"");
if($user===""||$stored===""){echo "SMTP_AUTH_SKIPPED missing saved credentials\n";exit(2);}
if(!class_exists("\\WPMailSMTP\\Helpers\\Crypto")){echo "SMTP_AUTH_SKIPPED no crypto helper\n";exit(3);}
$pass=\WPMailSMTP\Helpers\Crypto::decrypt($stored);
if(!is_string($pass)||$pass===""){echo "SMTP_AUTH_SKIPPED could not decrypt\n";exit(4);}
$mail=new \PHPMailer\PHPMailer\PHPMailer(true);
$mail->isSMTP();
$mail->Host="mail.vesta-cosmetics.ir";
$mail->Port=587;
$mail->SMTPSecure=\PHPMailer\PHPMailer\PHPMailer::ENCRYPTION_STARTTLS;
$mail->SMTPAutoTLS=true;
$mail->SMTPAuth=true;
$mail->Username=$user;
$mail->Password=$pass;
$mail->Timeout=9;
$mail->SMTPDebug=0;
$mail->SMTPOptions=["ssl"=>["verify_peer"=>true,"verify_peer_name"=>true,"allow_self_signed"=>false]];
try{
 $ok=$mail->smtpConnect();
 echo "AUTH_CURRENT_MAIL_587=".($ok?"success":"failure")."\n";
 if($ok)$mail->smtpClose();
}catch(\Throwable $e){
 $a=strtolower($e->getMessage());
 $reason=(strpos($a,"auth")!==false||strpos($a,"535")!==false)?"authentication":((strpos($a,"certificate")!==false||strpos($a,"ssl")!==false||strpos($a,"tls")!==false||strpos($a,"crypto")!==false)?"tls_certificate":"network_or_other");
 echo "AUTH_CURRENT_MAIL_587=failure reason=$reason\n";
}
';
echo SMTP_LOGIN_ONLY_PROBE_COMPLETE
