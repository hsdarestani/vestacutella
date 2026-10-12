<?php
/**
 * Plugin Name: Vesta SMS.ir OTP Login
 * Description: Unencoded, isolated replacement for the broken legacy SMS.ir customer OTP login.
 * Version: 1.1.0
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
/**
 * Resolve a verified phone without confusing a WooCommerce billing contact
 * with the identity used for OTP login.
 *
 * smsir_phone and phone are login/profile bindings. billing_phone is often a
 * recipient's contact number and may legitimately appear on several accounts.
 * Only auto-select an account when all explicit login/profile bindings agree.
 * Never auto-merge users, delete meta, or choose by ID/order history.
 */
function vesta_otp_existing_user($phone) {
    global $wpdb;
    $alternates = array_values(array_unique(array(
        $phone, '+98'.substr($phone,1), '98'.substr($phone,1),
        substr($phone,1), '0098'.substr($phone,1)
    )));
    $holders = implode(',', array_fill(0, count($alternates), '%s'));
    // Cap unexpectedly large matches rather than making an unsafe decision on
    // an incomplete result set. Include meta_key to distinguish login bindings.
    $sql = "SELECT DISTINCT user_id, meta_key FROM {$wpdb->usermeta} WHERE meta_key IN ('smsir_phone','phone','billing_phone') AND meta_value IN ($holders) LIMIT 101";
    $rows = $wpdb->get_results($wpdb->prepare($sql, $alternates), ARRAY_A);
    if ($wpdb->last_error || !is_array($rows)) {
        return new WP_Error('mobile_lookup_failed', 'بررسی حساب کاربری ممکن نیست. لطفاً دوباره تلاش کنید.');
    }
    $all = array();
    $login = array();
    foreach ($rows as $row) {
        $id = (int) $row['user_id'];
        if ($id <= 0) { continue; }
        $all[$id] = true;
        if ($row['meta_key'] === 'smsir_phone' || $row['meta_key'] === 'phone') {
            $login[$id] = true;
        }
    }
    $conflict = new WP_Error('duplicate_mobile', 'این شماره برای ورود به بیش از یک حساب ثبت شده است. لطفاً با پشتیبانی تماس بگیرید.');
    if (count($rows) > 100) { return $conflict; }
    // An explicit login binding wins over somebody else's billing-only contact.
    if (count($login) === 1) { return (int) key($login); }
    // Two different login bindings are a genuine account ownership conflict.
    if (count($login) > 1 || count($all) > 1) { return $conflict; }
    return count($all) === 1 ? (int) key($all) : 0;
}
/**
 * A shared billing contact is not proof of ownership of any particular
 * WooCommerce account. For legacy contacts, require both the SMS challenge
 * and a code delivered to the account's already-registered email.
 */
function vesta_otp_recovery_key($token) {
    return 'vesta_otp_recovery_' . hash('sha256', $token);
}
function vesta_otp_recovery_state() {
    $token = isset($_POST['recovery_token']) ? trim((string) wp_unslash($_POST['recovery_token'])) : '';
    if (!preg_match('/^[a-f0-9]{64}$/D', $token)) {
        return new WP_Error('invalid_recovery', 'درخواست ورود منقضی شده است. دوباره تلاش کنید.');
    }
    $state = get_transient(vesta_otp_recovery_key($token));
    if (!is_array($state) || empty($state['phone']) || !vesta_otp_phone($state['phone'])) {
        return new WP_Error('invalid_recovery', 'درخواست ورود منقضی شده است. دوباره تلاش کنید.');
    }
    return array($token, $state);
}
function vesta_otp_recovery_contact_matches($user_id, $phone) {
    foreach (array('billing_phone', 'phone', 'smsir_phone') as $key) {
        foreach ((array) get_user_meta($user_id, $key, false) as $stored) {
            if (vesta_otp_phone($stored) === $phone) { return true; }
        }
    }
    return false;
}
function vesta_otp_recovery_has_login_owner($phone) {
    global $wpdb;
    $variants = array_values(array_unique(array(
        $phone, '+98'.substr($phone, 1), '98'.substr($phone, 1),
        substr($phone, 1), '0098'.substr($phone, 1)
    )));
    $holders = implode(',', array_fill(0, count($variants), '%s'));
    $query = "SELECT COUNT(DISTINCT user_id) FROM {$wpdb->usermeta} WHERE meta_key IN ('smsir_phone','phone') AND meta_value IN ($holders)";
    return (int) $wpdb->get_var($wpdb->prepare($query, $variants)) > 0;
}
function vesta_otp_recovery_send() {
    vesta_otp_ajax_check();
    $resolved = vesta_otp_recovery_state();
    if (is_wp_error($resolved)) {
        wp_send_json_error(array('message'=>$resolved->get_error_message()), 403);
    }
    list($token, $state) = $resolved;
    if (!empty($state['sent_at']) && (time() - (int) $state['sent_at']) < 60) {
        wp_send_json_error(array('message'=>'لطفاً یک دقیقه بعد دوباره تلاش کنید.'), 429);
    }
    if (!empty($state['requests']) && (int) $state['requests'] >= 3) {
        wp_send_json_error(array('message'=>'تعداد درخواست‌ها بیش از حد مجاز است. دوباره از ابتدا وارد شوید.'), 429);
    }
    $email = isset($_POST['email']) ? sanitize_email(wp_unslash($_POST['email'])) : '';
    if (!$email || !is_email($email)) {
        wp_send_json_error(array('message'=>'ایمیل حساب کاربری را درست وارد کنید.'), 400);
    }
    $state['requests'] = isset($state['requests']) ? (int) $state['requests'] + 1 : 1;
    $state['sent_at'] = time();
    unset($state['email_user'], $state['email_hash']);
    $phone = $state['phone'];
    $existing = vesta_otp_existing_user($phone);
    // Never continue recovery when an explicit mobile login has been bound.
    if (is_wp_error($existing) && $existing->get_error_code() === 'duplicate_mobile' &&
        !vesta_otp_recovery_has_login_owner($phone)) {
        $user = get_user_by('email', $email);
        if ($user && vesta_otp_recovery_contact_matches($user->ID, $phone) &&
            array_intersect(array('customer','subscriber'), (array) $user->roles) &&
            !array_intersect(array('administrator','editor','author','shop_manager'), (array) $user->roles)) {
            $code = (string) random_int(100000, 999999);
            $message = "کد تأیید ورود به وستا: " . $code . "\nاعتبار: ۵ دقیقه. این کد را در اختیار دیگران قرار ندهید.";
            if (wp_mail($user->user_email, 'کد تأیید ورود به وستا', $message)) {
                $state['email_user'] = (int) $user->ID;
                $state['email_hash'] = wp_hash_password($code);
                $state['email_attempts'] = 0;
                $state['email_expires'] = time() + 300;
            }
        }
    }
    set_transient(vesta_otp_recovery_key($token), $state, 600);
    // Avoid revealing which email addresses belong to store customers.
    wp_send_json_success(array('message'=>'اگر این ایمیل به یکی از حساب‌ها مرتبط باشد، کد تأیید ارسال می‌شود.'));
}
function vesta_otp_recovery_verify() {
    vesta_otp_ajax_check();
    $resolved = vesta_otp_recovery_state();
    if (is_wp_error($resolved)) {
        wp_send_json_error(array('message'=>$resolved->get_error_message()), 403);
    }
    list($token, $state) = $resolved;
    $code = isset($_POST['email_code']) ? trim((string) wp_unslash($_POST['email_code'])) : '';
    if (!preg_match('/^[0-9]{6}$/D', $code) ||
        empty($state['email_hash']) || empty($state['email_user']) ||
        empty($state['email_expires']) || time() > (int) $state['email_expires']) {
        wp_send_json_error(array('message'=>'کد ایمیل معتبر نیست یا منقضی شده است.'), 400);
    }
    $attempts = isset($state['email_attempts']) ? (int) $state['email_attempts'] : 0;
    if ($attempts >= 5) {
        delete_transient(vesta_otp_recovery_key($token));
        wp_send_json_error(array('message'=>'تعداد تلاش‌ها بیش از حد مجاز است.'), 429);
    }
    if (!wp_check_password($code, $state['email_hash'])) {
        $state['email_attempts'] = $attempts + 1;
        if ($state['email_attempts'] >= 5) delete_transient(vesta_otp_recovery_key($token));
        else set_transient(vesta_otp_recovery_key($token), $state, 600);
        wp_send_json_error(array('message'=>'کد ایمیل اشتباه است.'), 400);
    }
    $phone = $state['phone'];
    $user_id = (int) $state['email_user'];
    $user = get_user_by('id', $user_id);
    if (!$user || !array_intersect(array('customer','subscriber'), (array) $user->roles) ||
        array_intersect(array('administrator','editor','author','shop_manager'), (array) $user->roles) ||
        !vesta_otp_recovery_contact_matches($user_id, $phone)) {
        wp_send_json_error(array('message'=>'امکان تأیید این حساب وجود ندارد.'), 403);
    }
    // Serialize phone ownership changes to avoid two competing recoveries.
    global $wpdb;
    $lock = 'vesta_otp_' . substr(vesta_otp_phone_key($phone), 0, 32);
    if ((int) $wpdb->get_var($wpdb->prepare('SELECT GET_LOCK(%s, 5)', $lock)) !== 1) {
        wp_send_json_error(array('message'=>'درخواست در حال بررسی است. دوباره تلاش کنید.'), 503);
    }
    $safe = false;
    $existing = vesta_otp_existing_user($phone);
    if (is_wp_error($existing) && $existing->get_error_code() === 'duplicate_mobile' &&
        !vesta_otp_recovery_has_login_owner($phone) &&
        vesta_otp_recovery_contact_matches($user_id, $phone)) {
        // This is a new identity binding only; no other user or order is changed.
        $safe = (bool) update_user_meta($user_id, 'smsir_phone', $phone);
    }
    $wpdb->get_var($wpdb->prepare('SELECT RELEASE_LOCK(%s)', $lock));
    if (!$safe) {
        wp_send_json_error(array('message'=>'تأیید حساب ممکن نشد. لطفاً با پشتیبانی تماس بگیرید.'), 409);
    }
    delete_transient(vesta_otp_recovery_key($token));
    wp_set_current_user($user_id);
    wp_set_auth_cookie($user_id, true, is_ssl());
    do_action('wp_login', $user->user_login, $user);
    $redirect = function_exists('wc_get_page_permalink') ? wc_get_page_permalink('myaccount') : home_url('/my-account/');
    wp_send_json_success(array('redirect'=>esc_url_raw($redirect)));
}
add_action('wp_ajax_nopriv_vesta_otp_recovery_send', 'vesta_otp_recovery_send');
add_action('wp_ajax_vesta_otp_recovery_send', 'vesta_otp_recovery_send');
add_action('wp_ajax_nopriv_vesta_otp_recovery_verify', 'vesta_otp_recovery_verify');
add_action('wp_ajax_vesta_otp_recovery_verify', 'vesta_otp_recovery_verify');

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
    if (is_wp_error($user_id)) {
        if ($user_id->get_error_code() === 'duplicate_mobile') {
            $recovery_token = bin2hex(random_bytes(32));
            set_transient(vesta_otp_recovery_key($recovery_token), array('phone'=>$phone, 'requests'=>0), 600);
            wp_send_json_error(array(
                'code'=>'account_selection_required',
                'recovery_token'=>$recovery_token,
                'message'=>'این شماره در اطلاعات تماس چند حساب وجود دارد. برای ورود امن، ایمیل حساب خود را هم تأیید کنید.'
            ), 409);
        }
        wp_send_json_error(array('message'=>$user_id->get_error_message()), 409);
    }
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
        <div id="vesta-otp-email-recovery" hidden>
          <p>برای انتخاب حساب، ایمیل ثبت‌شده در همان حساب را وارد کنید. کد جداگانه‌ای به آن ایمیل ارسال می‌شود.</p>
          <label for="vesta-otp-email">ایمیل حساب</label>
          <input id="vesta-otp-email" type="email" inputmode="email" autocomplete="email" placeholder="email@example.com" />
          <div id="vesta-otp-email-code-row" hidden>
            <label for="vesta-otp-email-code">کد ایمیل</label>
            <input id="vesta-otp-email-code" type="text" inputmode="numeric" autocomplete="one-time-code" maxlength="6" placeholder="کد ۶ رقمی ایمیل" />
          </div>
          <p>اگر ایمیل حساب را ندارید، از ورود با رمز عبور یا پشتیبانی کمک بگیرید.</p>
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
      var token='', recoveryToken='', stage='send', ajax=<?php echo wp_json_encode($ajax); ?>, nonce=<?php echo wp_json_encode($nonce); ?>;
      var recovery=document.getElementById('vesta-otp-email-recovery'),
          email=document.getElementById('vesta-otp-email'),
          emailCode=document.getElementById('vesta-otp-email-code'),
          emailCodeRow=document.getElementById('vesta-otp-email-code-row');
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
          if(stage==='send'){
            var a=await call('vesta_otp_send',{phone:phone.value});
            if(!a.success) throw Error(a.data&&a.data.message||'خطا در ارسال کد');
            token=a.data.token; stage='sms'; row.hidden=false; phone.readOnly=true;
            button.textContent='ورود با کد تأیید';feedback.textContent=a.data.message;code.focus();
          }else if(stage==='sms'){
            var b=await call('vesta_otp_verify',{phone:phone.value,code:code.value,token:token});
            if(!b.success) {
              if(b.data && b.data.code==='account_selection_required' && b.data.recovery_token){
                recoveryToken=b.data.recovery_token; stage='recovery-email';
                row.hidden=true; recovery.hidden=false; button.textContent='ارسال کد به ایمیل';
                feedback.textContent=b.data.message;email.focus();
              }else throw Error(b.data&&b.data.message||'کد تأیید نامعتبر است');
            }else window.location.assign(b.data.redirect||'/my-account/');
          }else if(stage==='recovery-email'){
            var c=await call('vesta_otp_recovery_send',{recovery_token:recoveryToken,email:email.value});
            if(!c.success) throw Error(c.data&&c.data.message||'ارسال کد ایمیل ناموفق بود');
            stage='recovery-verify';email.readOnly=true;emailCodeRow.hidden=false;
            button.textContent='تأیید ایمیل و ورود';feedback.textContent=c.data.message;emailCode.focus();
          }else if(stage==='recovery-verify'){
            var d=await call('vesta_otp_recovery_verify',{recovery_token:recoveryToken,email_code:emailCode.value});
            if(!d.success) throw Error(d.data&&d.data.message||'کد ایمیل نامعتبر است');
            window.location.assign(d.data.redirect||'/my-account/');
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
