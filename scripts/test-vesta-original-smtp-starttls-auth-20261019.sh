#!/usr/bin/env bash
# One SMTP AUTH-only attempt against the SAVED host using verified TLS, no message sent.
set -euo pipefail
docker exec vc-vesta php -d display_errors=0 -r '
require "/var/www/html/wp-load.php";
$opt=get_option("wp_mail_smtp",[]);$conf=isset($opt["smtp"])?(array)$opt["smtp"]:[];
$user=(string)($conf["user"]??"");$stored=(string)($conf["pass"]??"");
if(!$user||!$stored||!class_exists("\\WPMailSMTP\\Helpers\\Crypto"))exit(11);
$pw=\WPMailSMTP\Helpers\Crypto::decrypt($stored);
if(!is_string($pw)||$pw==="")exit(12);
$mail=new \PHPMailer\PHPMailer\PHPMailer(true);
$mail->isSMTP();
$mail->Host="server135s.irwebspace.com";
$mail->Port=587;
$mail->SMTPSecure=\PHPMailer\PHPMailer\PHPMailer::ENCRYPTION_STARTTLS;
$mail->SMTPAutoTLS=true;
$mail->SMTPAuth=true;
$mail->Username=$user;
$mail->Password=$pw;
$mail->Timeout=9;
$mail->SMTPDebug=0;
$mail->SMTPOptions=["ssl"=>["verify_peer"=>true,"verify_peer_name"=>true,"allow_self_signed"=>false]];
try {
 $ok=$mail->smtpConnect();
 echo "AUTH_SAVED_HOST_WITH_STARTTLS=".($ok?"success":"failure")."\n";
 $mail->smtpClose();
}catch(\Throwable $e){
 $err=strtolower($e->getMessage());
 $type=(strpos($err,"auth")!==false||strpos($err,"535")!==false)?"authentication":((strpos($err,"tls")!==false||strpos($err,"ssl")!==false||strpos($err,"certificate")!==false)?"tls_certificate":"connection_other");
 echo "AUTH_SAVED_HOST_WITH_STARTTLS=failure category=$type\n";
}
';
echo VESTA_SAVED_SMTP_WITH_TLS_PROBE_COMPLETE
