<?php
/**
 * Plugin Name: Vesta SMS.ir OTP Login
 * Description: Unencoded, isolated replacement for the broken legacy SMS.ir customer OTP login.
 * Version: 1.0.0
 * Requires PHP: 7.4
 */
if (!defined('ABSPATH')) { exit; }

function vesta_otp_settings() {
    $opt = get_option('smsir_settings', array());
    $cfg = (is_array($opt) && isset($opt['settings']) && is_array($opt['settings'])) ? $opt['settings'] : array();
    return array(
        'key' => isset($cfg['api_key']) ? trim((string) $cfg['api_key']) : '',
        'template' => isset($cfg['template_id']) ? absint($cfg['template_id']) : 0,
    );
}
function vesta_otp_ready() {
    $cfg = vesta_otp_settings();
    return $cfg['key'] !== '' && $cfg['template'] > 0;
}
function vesta_otp_phone($raw) {
    $p = (string) $raw;
    $p = strtr($p, array(
        '۰'=>'0','۱'=>'1','۲'=>'2','۳'=>'3','۴'=>'4','۵'=>'5','۶'=>'6','۷'=>'7','۸'=>'8','۹'=>'9',
        '٠'=>'0','١'=>'1','٢'=>'2','٣'=>'3','٤'=>'4','٥'=>'5','٦'=>'6','٧'=>'7','٨'=>'8','٩'=>'9'
    ));
    $p = preg_replace('/[\s\-\(\)]/u', '', $p);
    if (strpos($p, '+98') === 0) { $p = '0' . substr($p, 3); }
    elseif (strpos($p, '0098') === 0) { $p = '0' . substr($p, 4); }
    elseif (strpos($p, '98') === 0 && strlen($p) === 12) { $p = '0' . substr($p, 2); }
    elseif (strpos($p, '9') === 0 && strlen($p) === 10) { $p = '0' . $p; }
    return preg_match('/^09\d{9}$/D', $p) ? $p : '';
}
function vesta_otp_phone_key($phone) {
    return hash_hmac('sha256', $phone, wp_salt('auth'));
}
function vesta_otp_ajax_check() {
    if (!check_ajax_referer('vesta_otp_login', 'nonce', false)) {
        wp_send_json_error(array('message'=>'درخواست نامعتبر است. صفحه را تازه کنید.'), 403);
    }
    if (!vesta_otp_ready()) {
        wp_send_json_error(array('message'=>'ورود پیامکی موقتاً در دسترس نیست.'), 503);
    }
}
function vesta_otp_ip_key() {
    // Only used for coarse throttling; verification remains bound to one phone and opaque token.
    $ip = isset($_SERVER['REMOTE_ADDR']) ? (string) $_SERVER['REMOTE_ADDR'] : 'unknown';
    return 'vesta_otp_ip_' . substr(hash_hmac('sha256', $ip, wp_salt('nonce')), 0, 32);
}
function vesta_otp_send() {
    vesta_otp_ajax_check();
    $phone = vesta_otp_phone(isset($_POST['phone']) ? wp_unslash($_POST['phone']) : '');
    if (!$phone) { wp_send_json_error(array('message'=>'شماره موبایل معتبر وارد کنید.'), 400); }
    $key = substr(vesta_otp_phone_key($phone), 0, 36);
    $rate = 'vesta_otp_rate_' . $key;
    $ipk = vesta_otp_ip_key();
    if (get_transient($rate) || (int) get_transient($ipk) >= 30) {
        wp_send_json_error(array('message'=>'لطفاً کمی بعد دوباره تلاش کنید.'), 429);
    }
    set_transient($rate, 1, 60);
    set_transient($ipk, (int) get_transient($ipk) + 1, 1800);
    $otp = (string) random_int(100000, 999999);
    $token = bin2hex(random_bytes(24));
    $cfg = vesta_otp_settings();
    $body = array(
        'mobile' => $phone,
        'templateId' => $cfg['template'],
        'parameters' => array(array('name'=>'Code', 'value'=>$otp)),
    );
    $resp = wp_remote_post('https://api.sms.ir/v1/send/verify', array(
        'timeout'=>20,
        'redirection'=>0,
        'headers'=>array('Content-Type'=>'application/json', 'Accept'=>'application/json', 'X-API-KEY'=>$cfg['key']),
        'body'=>wp_json_encode($body),
    ));
    $success = false;
    if (!is_wp_error($resp) && (int) wp_remote_retrieve_response_code($resp) >= 200 && (int) wp_remote_retrieve_response_code($resp) < 300) {
        $json = json_decode((string) wp_remote_retrieve_body($resp), true);
        $success = is_array($json) && isset($json['status']) && (int) $json['status'] === 1;
    }
    if (!$success) {
        wp_send_json_error(array('message'=>'ارسال کد موفق نبود. لطفاً دوباره تلاش کنید.'), 502);
    }
    set_transient('vesta_otp_challenge_' . $key, array(
        'hash'=>wp_hash_password($otp),
        'token'=>hash('sha256', $token),
        'attempts'=>0,
    ), 300);
    wp_send_json_success(array('token'=>$token, 'message'=>'کد تأیید ارسال شد.'));
}
function vesta_otp_existing_user($phone) {
    global $wpdb;
    $alternates = array_unique(array(
        $phone, '+98'.substr($phone,1), '98'.substr($phone,1), substr($phone,1), '0098'.substr($phone,1)
    ));
    $alternates = array_values($alternates);
    $holders = implode(',', array_fill(0, count($alternates), '%s'));
    $sql = "SELECT DISTINCT user_id FROM {$wpdb->usermeta} WHERE meta_key IN ('smsir_phone','phone','billing_phone') AND meta_value IN ($holders) LIMIT 3";
    $user_ids = $wpdb->get_col($wpdb->prepare($sql, $alternates));
    if (count($user_ids) > 1) { return new WP_Error('duplicate_mobile', 'این شماره در چند حساب ثبت شده است. لطفاً با پشتیبانی تماس بگیرید.'); }
    return count($user_ids) === 1 ? (int) $user_ids[0] : 0;
}
function vesta_otp_verify() {
    vesta_otp_ajax_check();
    $phone = vesta_otp_phone(isset($_POST['phone']) ? wp_unslash($_POST['phone']) : '');
    $code = isset($_POST['code']) ? trim((string) wp_unslash($_POST['code'])) : '';
    $token = isset($_POST['token']) ? trim((string) wp_unslash($_POST['token'])) : '';
    if (!$phone || !preg_match('/^\d{6}$/D', $code) || !preg_match('/^[a-f0-9]{48}$/D', $token)) {
        wp_send_json_error(array('message'=>'اطلاعات کد تأیید نامعتبر است.'), 400);
    }
    $key = substr(vesta_otp_phone_key($phone), 0, 36);
    $challenge_key = 'vesta_otp_challenge_' . $key;
    $challenge = get_transient($challenge_key);
    if (!is_array($challenge) || (int) $challenge['attempts'] >= 5) {
        wp_send_json_error(array('message'=>'کد منقضی شده است. دوباره درخواست دهید.'), 400);
    }
    if (!hash_equals((string) $challenge['token'], hash('sha256', $token))) {
        wp_send_json_error(array('message'=>'درخواست تأیید نامعتبر است.'), 403);
    }
    if (!wp_check_password($code, $challenge['hash'])) {
        $challenge['attempts'] = (int) $challenge['attempts'] + 1;
        if ($challenge['attempts'] >= 5) { delete_transient($challenge_key); }
        else { set_transient($challenge_key, $challenge, 300); }
        wp_send_json_error(array('message'=>'کد واردشده درست نیست.'), 400);
    }
    // A verified code is single-use, even when account lookup or creation fails.
    delete_transient($challenge_key);
    $user_id = vesta_otp_existing_user($phone);
    if (is_wp_error($user_id)) { wp_send_json_error(array('message'=>$user_id->get_error_message()), 409); }
    if (!$user_id) {
        $username = 'vesta_mobile_' . substr(hash_hmac('sha256', $phone, wp_salt('secure_auth')), 0, 24);
        if (username_exists($username)) {
            wp_send_json_error(array('message'=>'امکان ثبت‌نام وجود ندارد. با پشتیبانی تماس بگیرید.'), 409);
        }
        $user_id = wp_insert_user(array(
            'user_login'=>$username,
            'user_pass'=>wp_generate_password(40, true, true),
            'role'=>'customer',
        ));
        if (is_wp_error($user_id)) {
            wp_send_json_error(array('message'=>'ساخت حساب کاربری ناموفق بود.'), 500);
        }
        update_user_meta($user_id, 'smsir_phone', $phone);
        update_user_meta($user_id, 'phone', $phone);
        update_user_meta($user_id, 'billing_phone', $phone);
    }
    $user = get_user_by('id', $user_id);
    if (!$user || !array_intersect(array('customer','subscriber'), (array) $user->roles) || array_intersect(array('administrator','editor','author','shop_manager'), (array) $user->roles)) {
        // Do not give passwordless access to privileged or non-customer WordPress accounts.
        wp_send_json_error(array('message'=>'این حساب نیاز به ورود با رمز عبور دارد.'), 403);
    }
    wp_set_current_user($user_id);
    wp_set_auth_cookie($user_id, true, is_ssl());
    do_action('wp_login', $user->user_login, $user);
    $redirect = function_exists('wc_get_page_permalink') ? wc_get_page_permalink('myaccount') : home_url('/my-account/');
    wp_send_json_success(array('redirect'=>esc_url_raw($redirect)));
}
add_action('wp_ajax_nopriv_vesta_otp_send', 'vesta_otp_send');
add_action('wp_ajax_vesta_otp_send', 'vesta_otp_send');
add_action('wp_ajax_nopriv_vesta_otp_verify', 'vesta_otp_verify');
add_action('wp_ajax_vesta_otp_verify', 'vesta_otp_verify');

function vesta_otp_render() {
    if (is_user_logged_in() || !vesta_otp_ready()) { return ''; }
    $nonce = wp_create_nonce('vesta_otp_login');
    $ajax = admin_url('admin-ajax.php');
    ob_start();
    ?>
    <div id="vesta-otp-login" class="vesta-otp-login" dir="rtl">
      <h3>ورود یا ثبت‌نام با شماره موبایل</h3>
      <p>شماره موبایل خود را وارد کنید تا کد ورود برایتان ارسال شود.</p>
      <form id="vesta-otp-form" autocomplete="on">
        <label for="vesta-otp-phone">شماره موبایل</label>
        <input id="vesta-otp-phone" name="tel" type="tel" inputmode="tel" autocomplete="tel" placeholder="۰۹۱۲۱۲۳۴۵۶۷" required />
        <div id="vesta-otp-code-row" hidden>
          <label for="vesta-otp-code">کد تأیید</label>
          <input id="vesta-otp-code" type="text" inputmode="numeric" autocomplete="one-time-code" maxlength="6" placeholder="کد ۶ رقمی" />
        </div>
        <button id="vesta-otp-submit" type="submit">دریافت کد ورود</button>
        <p id="vesta-otp-feedback" role="status" aria-live="polite"></p>
      </form>
      <button type="button" id="vesta-otp-legacy" class="vesta-otp-legacy">ورود با رمز عبور</button>
    </div>
    <style>
    .vesta-otp-login{box-sizing:border-box;max-width:540px;margin:30px auto;padding:25px;border:1px solid #e7e7e7;border-radius:14px;background:#fff;text-align:right;direction:rtl}
    .vesta-otp-login *{box-sizing:border-box}.vesta-otp-login h3{margin:0 0 10px}.vesta-otp-login p{margin:0 0 16px}
    .vesta-otp-login label{display:block;margin:12px 0 6px}
    .vesta-otp-login input{display:block;width:100%;padding:13px;border:1px solid #ccc;border-radius:8px;font-size:16px}
    .vesta-otp-login button[type=submit]{display:block;width:100%;padding:14px;margin-top:18px;border:0;border-radius:8px;cursor:pointer;background:#222;color:#fff}
    .vesta-otp-legacy{display:block;margin:15px auto 0;border:0;background:transparent;text-decoration:underline;cursor:pointer}
    #vesta-otp-feedback{margin:10px 0 0;min-height:24px}
    body:not(.vesta-show-password-login) .woocommerce #customer_login,
    body:not(.vesta-show-password-login) .woocommerce .woocommerce-form-login.login{display:none}
    </style>
    <script>
    (function(){
      var root=document.getElementById('vesta-otp-login'); if(!root||root.dataset.bound) return; root.dataset.bound='1';
      var form=document.getElementById('vesta-otp-form'),phone=document.getElementById('vesta-otp-phone'),
      code=document.getElementById('vesta-otp-code'), row=document.getElementById('vesta-otp-code-row'),
      button=document.getElementById('vesta-otp-submit'),feedback=document.getElementById('vesta-otp-feedback');
      var token='', ajax=<?php echo wp_json_encode($ajax); ?>, nonce=<?php echo wp_json_encode($nonce); ?>;
      document.getElementById('vesta-otp-legacy').addEventListener('click',function(){ document.body.classList.toggle('vesta-show-password-login'); });
      async function call(action,details) {
        var d=new FormData();d.append('action',action);d.append('nonce',nonce);
        Object.keys(details).forEach(function(k){d.append(k,details[k]);});
        var r=await fetch(ajax,{method:'POST',body:d,credentials:'same-origin'});
        return await r.json();
      }
      form.addEventListener('submit',async function(e){
        e.preventDefault();button.disabled=true;feedback.textContent='لطفاً صبر کنید…';
        try{
          if(!token){
            var a=await call('vesta_otp_send',{phone:phone.value});
            if(!a.success) throw Error(a.data&&a.data.message||'خطا در ارسال کد');
            token=a.data.token; row.hidden=false; phone.readOnly=true;
            button.textContent='ورود با کد تأیید';feedback.textContent=a.data.message;code.focus();
          }else{
            var b=await call('vesta_otp_verify',{phone:phone.value,code:code.value,token:token});
            if(!b.success) throw Error(b.data&&b.data.message||'کد تأیید نامعتبر است');
            window.location.assign(b.data.redirect||'/my-account/');
          }
        }catch(err){feedback.textContent=err.message||'ارتباط برقرار نشد. دوباره تلاش کنید.';}
        button.disabled=false;
      });
    })();
    </script>
    <?php
    return ob_get_clean();
}
add_shortcode('vesta_sms_login', 'vesta_otp_render');
add_action('woocommerce_before_customer_login_form', function() {
    if (is_account_page() && !is_user_logged_in()) {
        echo vesta_otp_render(); // phpcs:ignore WordPress.Security.EscapeOutput.OutputNotEscaped
    }
}, 1);

add_action('woocommerce_before_checkout_form', function() {
    if (!is_user_logged_in()) {
        echo vesta_otp_render(); // phpcs:ignore WordPress.Security.EscapeOutput.OutputNotEscaped
    }
}, 1);
add_filter('woocommerce_checkout_fields', function($fields) {
    if (isset($fields['billing']['billing_email'])) {
        $fields['billing']['billing_email']['required'] = false;
    }
    return $fields;
}, 20);
