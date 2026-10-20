#!/usr/bin/env bash
set -euo pipefail
docker exec vc-vesta php -d display_errors=0 -r '
require "/var/www/html/wp-load.php";
$o=get_option("wp_mail_smtp",[]);$s=(array)($o["smtp"]??[]);
if(($s["host"]??"")!=="server135s.irwebspace.com"){echo "ABORT_UNEXPECTED_HOST\n";exit(11);}
if(!class_exists("\\WPMailSMTP\\Helpers\\Crypto")){echo "NO_DECRYPT_HELPER\n";exit(12);}
$stored=(string)($s["pass"]??"");$u=(string)($s["user"]??"");
$p=\WPMailSMTP\Helpers\Crypto::decrypt($stored);
if(!$u||!is_string($p)||$p===""){echo "NO_VALID_SAVED_CREDENTIAL\n";exit(13);}
echo "SAVED_CREDENTIAL_FORMAT user_is_email=".(strpos($u,"@")!==false?"yes":"no")." pass_nonempty=yes\n";
foreach([[465,\PHPMailer\PHPMailer\PHPMailer::ENCRYPTION_SMTPS],[587,\PHPMailer\PHPMailer\PHPMailer::ENCRYPTION_STARTTLS]] as $c){
 [$port,$secure]=$c;
 $m=new \PHPMailer\PHPMailer\PHPMailer(true);
 $m->isSMTP();$m->Host="server135s.irwebspace.com";$m->Port=$port;$m->SMTPSecure=$secure;$m->SMTPAutoTLS=($port==587);
 $m->SMTPAuth=true;$m->Username=$u;$m->Password=$p;$m->Timeout=10;$m->SMTPDebug=0;
 $m->SMTPOptions=["ssl"=>["verify_peer"=>true,"verify_peer_name"=>true,"allow_self_signed"=>false]];
 try{
  $result=$m->smtpConnect();
  echo "LOGIN_ONLY port=$port result=".($result?"authenticated":"failed")."\n";
  if($result)$m->smtpClose();
 }catch(\Throwable $e){
  $msg=strtolower($e->getMessage());
  $category=preg_match("/authenticat|535|login failed|invalid credential/",$msg)?"authentication":(preg_match("/starttls|tls|ssl|certificate|crypto/",$msg)?"tls":(preg_match("/connect|timeout|connection/",$msg)?"network":"other"));
  echo "LOGIN_ONLY port=$port result=failed category=$category\n";
 }
}
';
echo "SAVED_CREDENTIAL_LOGIN_ONLY_CHECK_COMPLETE"
