<?php
/**
 * Temporary one-shot HTTP WP-Cron mail diagnostic. Triggered only by a locally
 * scheduled job. Never outputs credentials, email addresses or message content.
 */
if (!defined('ABSPATH')) exit;
add_action('vc_vesta_internal_mail_context_probe_20261020', function () {
    $key = 'vc_vesta_mail_context_result_20261020';
    if (get_option($key, false)) return;
    add_option($key, array('state'=>'running','started'=>gmdate('c')), '', false);
    $r = array('state'=>'started','utc'=>gmdate('c'),'context'=>'http_cron');
    $o=get_option('wp_mail_smtp',array());
    $s=(array)($o['smtp']??array());
    $expected=\WPMailSMTP\Helpers\Crypto::decrypt((string)($s['pass']??''));
    $expU=(string)($s['user']??'');
    $r['option_encryption']=(string)($s['encryption']??'unset');
    $r['option_port']=(int)($s['port']??0);
    $r['option_has_decrypted_password']=is_string($expected)&&$expected!==''?'yes':'no';
    $r['config_is_cached']=wp_cache_get('alloptions','options')!==false?'yes':'no';
    $r['phpmailer_init_seen']='no';
    $r['fail_reason']='none';
    $r['succeeded_hook']='no';
    $r['send_result']='unattempted';
    $capture=function($mail) use (&$r,$expU,$expected) {
        $r['phpmailer_init_seen']='yes';
        $r['mailer_host_is_configured']=$mail->Host==='server135s.irwebspace.com'?'yes':'no';
        $r['mailer_port']=(int)$mail->Port;
        $r['mailer_secure']=(string)$mail->SMTPSecure;
        $r['mailer_auth']=$mail->SMTPAuth?'yes':'no';
        $r['mailer_user_matches_option']=hash_equals($expU,(string)$mail->Username)?'yes':'no';
        $r['mailer_password_matches_decrypted_option']=is_string($expected)&&hash_equals($expected,(string)$mail->Password)?'yes':'no';
        $r['mailer_autotls']=$mail->SMTPAutoTLS?'yes':'no';
        $r['mailer_auth_type']=(string)$mail->AuthType;
        $r['mailer_smtp_options_present']=empty($mail->SMTPOptions)?'no':'yes';
        $r['mailer_php_version']=PHP_VERSION;
    };
    $failed=function($e) use (&$r){
        $m=strtolower($e->get_error_message());
        $r['fail_reason']=preg_match('/authenticat|535|invalid login|login fail/',$m)?'authentication':(preg_match('/starttls|ssl|tls|certificate|crypto/',$m)?'tls':(preg_match('/connect|timeout/',$m)?'connect':'other'));
    };
    $success=function() use (&$r){$r['succeeded_hook']='yes';};
    add_action('phpmailer_init',$capture,PHP_INT_MAX);
    add_action('wp_mail_failed',$failed,10,1);
    add_action('wp_mail_succeeded',$success,10,1);
    try {
        $new=null;
        foreach(WC()->mailer()->get_emails() as $e)if(($e->id??'')==='new_order')$new=$e;
        $to=$new&&$new->is_enabled()?array_values(array_filter(array_map('trim',explode(',',(string)$new->get_recipient())),'is_email')):array();
        if(count($to)!==1)throw new Exception('no_unique_admin');
        if(strtolower(substr(strrchr($to[0],'@'),1))!=='gmail.com')throw new Exception('unexpected_admin_domain');
        $r['send_result']=wp_mail($to,'Vesta: HTTP SMTP delivery diagnostic 2026-10-20','Automated technical verification in the web request context after mailbox incident. No order details or customer information.',array('Content-Type: text/plain; charset=UTF-8'))?'accepted':'failed';
    }catch(Throwable $e){$r['send_result']='exception';$r['exception_class']=get_class($e);}
    finally{
        remove_action('phpmailer_init',$capture,PHP_INT_MAX);
        remove_action('wp_mail_failed',$failed,10);
        remove_action('wp_mail_succeeded',$success,10);
    }
    // One independent login-only handshake from the SAME HTTP/FPM process,
    // using the same decrypted credentials; no second email is sent.
    $direct=new \PHPMailer\PHPMailer\PHPMailer(true);
    $direct->isSMTP();
    $direct->Host=(string)($s['host']??'');
    $direct->Port=(int)($s['port']??0);
    $direct->SMTPSecure=\PHPMailer\PHPMailer\PHPMailer::ENCRYPTION_SMTPS;
    $direct->SMTPAutoTLS=false;
    $direct->SMTPAuth=true;
    $direct->Username=$expU;
    $direct->Password=(string)$expected;
    $direct->Timeout=10;
    $direct->SMTPOptions=array('ssl'=>array('verify_peer'=>true,'verify_peer_name'=>true,'allow_self_signed'=>false));
    try {
        $auth=$direct->smtpConnect();
        $r['direct_auth_from_http']=$auth?'success':'failed';
        if($auth)$direct->smtpClose();
    }catch(Throwable $e){
        $err=strtolower($e->getMessage());
        $r['direct_auth_from_http']=preg_match('/authenticat|535|invalid credential/',$err)?'failed_auth':(preg_match('/starttls|ssl|tls|certificate|crypto/',$err)?'failed_tls':'failed_other');
    }
    $r['state']='finished';
    update_option($key,$r,false);
},10,0);

add_action('init', function () {
    if (($_SERVER['REQUEST_METHOD']??'') !== 'POST' || !isset($_GET['vc_mail_context_probe'])) return;
    $expected=(string)get_option('vc_vesta_mail_probe_token_20261020','');
    $actual=(string)($_SERVER['HTTP_X_VC_MAIL_PROBE_TOKEN']??'');
    if (strlen($expected) !== 48 || !hash_equals($expected,$actual)) {
        status_header(403);exit;
    }
    do_action('vc_vesta_internal_mail_context_probe_20261020');
    nocache_headers();
    echo 'PROBE_EXECUTED';
    exit;
}, 99);
