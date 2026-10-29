<?php
/**
 * Plugin Name: Vesta DigiPay Refunds
 * Description: Admin-only tracked, manual refunds for Vesta DigiPay WooCommerce orders. Never initiates an automatic transfer.
 * Version: 1.0.0
 * Requires PHP: 7.4
 */
defined('ABSPATH') || exit;

function vc_dp_is_gateway_order($order) {
    if (!($order instanceof WC_Order)) { return false; }
    $name = strtolower((string) $order->get_payment_method());
    $label = (string) $order->get_payment_method_title();
    return strpos($name, 'digipay') !== false || strpos($name, 'digi_pay') !== false ||
        strpos($label, 'دیجی') !== false && strpos($label, 'پی') !== false;
}
function vc_dp_credentials($order) {
    $map = array('username'=>'VC_DIGIPAY_USERNAME','password'=>'VC_DIGIPAY_PASSWORD',
        'client_id'=>'VC_DIGIPAY_CLIENT_ID','client_secret'=>'VC_DIGIPAY_CLIENT_SECRET');
    $values = array();
    foreach ($map as $field => $constant) {
        if (defined($constant) && is_scalar(constant($constant))) {
            $values[$field] = trim((string) constant($constant));
        }
    }
    // Read only the already-configured payment gateway's settings; never print or log secrets.
    $settings = get_option('woocommerce_' . $order->get_payment_method() . '_settings', array());
    if (is_array($settings)) {
        $normalized = array();
        foreach ($settings as $key => $value) {
            if (is_scalar($value)) { $normalized[strtolower(preg_replace('/[^a-z0-9]/i', '', (string)$key))] = (string)$value; }
        }
        foreach (array('username'=>'username','password'=>'password','client_id'=>'clientid','client_secret'=>'clientsecret') as $target => $key) {
            if (empty($values[$target]) && !empty($normalized[$key])) { $values[$target] = trim($normalized[$key]); }
        }
    }
    foreach ($map as $key => $unused) { if (empty($values[$key])) { return array(); } }
    return $values;
}
function vc_dp_api($order, $path, $payload = null) {
    $creds = vc_dp_credentials($order);
    if (!$creds) { return new WP_Error('no_credentials', 'اطلاعات ورود API دیجی‌پی در تنظیمات درگاه پیدا نشد.'); }
    $auth = wp_remote_post('https://api.mydigipay.com/digipay/api/oauth/token', array(
        'timeout'=>20, 'redirection'=>0, 'headers'=>array('Authorization'=>'Basic '.base64_encode($creds['client_id'].':'.$creds['client_secret'])),
        'body'=>array('username'=>$creds['username'],'password'=>$creds['password'],'grant_type'=>'password'),
    ));
    if (is_wp_error($auth)) { return new WP_Error('auth_network', 'ارتباط با احراز هویت دیجی‌پی برقرار نشد.'); }
    $a = json_decode(wp_remote_retrieve_body($auth), true);
    if ((int)wp_remote_retrieve_response_code($auth)!==200 || empty($a['access_token'])) {
        return new WP_Error('auth_failed', 'احراز هویت API دیجی‌پی موفق نبود (HTTP '.(int)wp_remote_retrieve_response_code($auth).').');
    }
    $args = array('timeout'=>30,'redirection'=>0,'headers'=>array(
        'Authorization'=>'Bearer '.$a['access_token'], 'Content-Type'=>'application/json; charset=UTF-8'));
    if ($payload !== null) { $args['body'] = wp_json_encode($payload); }
    else { $args['body'] = '{}'; }
    $response = wp_remote_post('https://api.mydigipay.com/digipay/api/'.ltrim($path,'/'), $args);
    if (is_wp_error($response)) { return new WP_Error('refund_network', 'ارتباط با دیجی‌پی قطع شد؛ وضعیت نامشخص است و نباید دوباره درخواست بازپرداخت ارسال شود.'); }
    $data = json_decode(wp_remote_retrieve_body($response), true);
    if (!is_array($data)) { return new WP_Error('unexpected_response', 'پاسخ API قابل تفسیر نبود؛ برای جلوگیری از بازپرداخت تکراری، ابتدا استعلام بگیرید.'); }
    $data['_http'] = (int)wp_remote_retrieve_response_code($response);
    return $data;
}
function vc_dp_attempts($order) {
    $items = $order->get_meta('_vc_dp_refund_attempts', true);
    return is_array($items) ? $items : array();
}
function vc_dp_store($order, $items) {
    $order->update_meta_data('_vc_dp_refund_attempts', $items);
    $order->save();
}
function vc_dp_lock($id) {
    $key = 'vc_dp_refund_lock_' . (int)$id;
    $old = (int)get_option($key,0);
    if ($old && $old < time()-180) { delete_option($key); }
    return add_option($key, (string)time(), '', 'no');
}
function vc_dp_error_redirect($order_id, $message, $level = 'error') {
    set_transient('vc_dp_notice_'.get_current_user_id(), array($level, $message), 45);
    delete_option('vc_dp_refund_lock_' . absint($order_id));
    $target = function_exists('wc_get_order') ? wc_get_order(absint($order_id)) : null;
    wp_safe_redirect($target && method_exists($target, 'get_edit_order_url') ? $target->get_edit_order_url() : admin_url('post.php?post='.absint($order_id).'&action=edit'));
    exit;
}
add_action('admin_notices', function() {
    if (!current_user_can('manage_woocommerce')) { return; }
    $key = 'vc_dp_notice_'.get_current_user_id();
    $notice = get_transient($key);
    if (!$notice || !is_array($notice)) { return; }
    delete_transient($key);
    echo '<div class="notice notice-'.esc_attr($notice[0]).' is-dismissible"><p>'.esc_html($notice[1]).'</p></div>';
});
function vc_dp_box($order) {
    if (!($order instanceof WC_Order) || !vc_dp_is_gateway_order($order) || !current_user_can('manage_woocommerce')) { return; }
    $attempts = vc_dp_attempts($order);
    $currency = strtoupper($order->get_currency());
    $available = max(0, (float)$order->get_total()-(float)$order->get_total_refunded());
    $pending = false;
    foreach ($attempts as $attempt) {
        if (in_array($attempt['state'], array('submitted','uncertain','processing','confirmed_unrecorded'), true)) { $pending = true; }
    }
    $credentials = (bool)vc_dp_credentials($order);
    echo '<div dir="rtl" style="margin:16px 0;padding:14px;border:1px solid #c3c4c7;background:#f8f9fb;border-radius:8px">';
    echo '<h3>بازگشت وجه دیجی‌پی</h3>';
    echo '<p>بازپرداخت فقط پس از ثبت دستی درخواست مدیر انجام می‌شود. تأیید نهایی با استعلام دیجی‌پی بررسی می‌شود.</p>';
    if (!$credentials) { echo '<p style="color:#a00">دسترسی فنی API این درگاه پیدا نشد؛ مقادیر Client ID / Client Secret / Username / Password باید در تنظیمات درگاه یا ثابت‌های امن سرور قرار بگیرند.</p>'; }
    if (!in_array($currency, array('IRR','IRT','TOMAN'), true)) { echo '<p style="color:#a00">واحد پول سفارش پشتیبانی نشده؛ مبلغ ریالی باید پیش از فعال‌سازی مشخص شود.</p>'; }
    if ($attempts) {
        echo '<table class="widefat striped"><thead><tr><th>شناسه درخواست</th><th>مبلغ</th><th>نوع</th><th>وضعیت</th><th>پیگیری</th></tr></thead><tbody>';
        foreach (array_reverse($attempts, true) as $index=>$item) {
            echo '<tr><td>'.esc_html($item['provider']).'</td><td>'.esc_html($item['store_amount'].' '.$currency).'</td><td>'.esc_html($item['type']).'</td><td>'.esc_html($item['state']).'</td><td>';
            if (in_array($item['state'], array('submitted','uncertain','processing','confirmed_unrecorded'), true)) {
                echo '<form method="post" action="'.esc_url(admin_url('admin-post.php')).'">';
                wp_nonce_field('vc_dp_manage_'.$order->get_id());
                echo '<input type="hidden" name="action" value="vc_dp_manage"><input type="hidden" name="mode" value="inquiry"><input type="hidden" name="order_id" value="'.esc_attr($order->get_id()).'"><input type="hidden" name="attempt" value="'.esc_attr($index).'">';
                echo '<button class="button" type="submit">استعلام وضعیت</button></form>';
            } else { echo '—'; }
            echo '</td></tr>';
        }
        echo '</tbody></table>';
    }
    if ($available>0 && !$pending && $credentials && in_array($currency,array('IRR','IRT','TOMAN'),true) && $order->is_paid()) {
        echo '<form method="post" action="'.esc_url(admin_url('admin-post.php')).'" onsubmit="return confirm(\'آیا درخواست واقعی بازگشت وجه به دیجی‌پی ارسال شود؟\')">';
        wp_nonce_field('vc_dp_manage_'.$order->get_id());
        echo '<input type="hidden" name="action" value="vc_dp_manage"><input type="hidden" name="mode" value="refund"><input type="hidden" name="order_id" value="'.esc_attr($order->get_id()).'">';
        echo '<p><label>مبلغ ('.esc_html($currency).') <input type="number" name="amount" step="1" min="1" max="'.esc_attr((int)floor($available)).'" value="'.esc_attr((int)floor($available)).'" required></label></p>';
        echo '<p><label>کد پیگیری پرداخت (trackingCode) <input type="text" name="tracking" value="'.esc_attr($order->get_transaction_id()).'" required maxlength="80" autocomplete="off"></label></p>';
        echo '<p><label>نوع پرداخت <select name="type"><option value="">انتخاب کنید</option><option value="0">IPG (0)</option><option value="11">کیف پول (11)</option><option value="5">اعتباری (5)</option><option value="13">BNPL (13)</option><option value="24">کارت اعتباری (24)</option></select></label></p>';
        echo '<p><strong>قبل از ارسال، trackingCode و نوع تراکنش را با گزارش دیجی‌پی تطبیق دهید.</strong></p>';
        echo '<button class="button button-primary" type="submit">ارسال درخواست واقعی بازگشت وجه</button></form>';
    }
    echo '</div>';
}
add_action('woocommerce_admin_order_data_after_order_details', 'vc_dp_box', 30);
add_action('admin_post_vc_dp_manage', function() {
    if (!current_user_can('manage_woocommerce')) { wp_die('دسترسی مجاز نیست.', '',array('response'=>403)); }
    $id = isset($_POST['order_id']) ? absint($_POST['order_id']) : 0;
    check_admin_referer('vc_dp_manage_'.$id);
    $order = function_exists('wc_get_order') ? wc_get_order($id) : false;
    if (!($order instanceof WC_Order) || !vc_dp_is_gateway_order($order)) { wp_die('سفارش دیجی‌پی معتبر نیست.', '',array('response'=>400)); }
    if (!vc_dp_lock($id)) { vc_dp_error_redirect($id,'عملیات دیگری روی این سفارش در حال انجام است.'); }
    try {
        $mode = isset($_POST['mode']) ? sanitize_key(wp_unslash($_POST['mode'])) : '';
        $items = vc_dp_attempts($order);
        $pending = false;
        foreach ($items as $i) { if (in_array($i['state'],array('submitted','uncertain','processing','confirmed_unrecorded'),true)) { $pending=true; } }
        if ($mode==='refund') {
            if ($pending) { vc_dp_error_redirect($id,'ابتدا وضعیت درخواست قبلی را استعلام کنید.'); }
            if (!vc_dp_credentials($order) || !$order->is_paid()) { vc_dp_error_redirect($id,'سفارش پرداخت‌شده یا اطلاعات API معتبر نیست.'); }
            $currency = strtoupper($order->get_currency());
            if (!in_array($currency,array('IRR','IRT','TOMAN'),true)) { vc_dp_error_redirect($id,'واحد پول پشتیبانی نشده است.'); }
            $amount = isset($_POST['amount']) ? (string)wp_unslash($_POST['amount']) : '';
            if (!preg_match('/^[1-9][0-9]*$/D',$amount)) { vc_dp_error_redirect($id,'مبلغ معتبر نیست.'); }
            $amount = (int)$amount;
            $remaining = (int)floor(max(0,(float)$order->get_total()-(float)$order->get_total_refunded()));
            if ($amount<1 || $amount>$remaining) { vc_dp_error_redirect($id,'مبلغ بیش از مانده سفارش است.'); }
            $type = isset($_POST['type']) ? (string)wp_unslash($_POST['type']) : '';
            if (!in_array($type,array('0','5','11','13','24'),true)) { vc_dp_error_redirect($id,'نوع تراکنش را انتخاب کنید.'); }
            $tracking = isset($_POST['tracking']) ? trim((string)wp_unslash($_POST['tracking'])) : '';
            if (!preg_match('/^[a-zA-Z0-9-]{6,80}$/D',$tracking)) { vc_dp_error_redirect($id,'کد پیگیری خرید معتبر نیست.'); }
            $rials = $currency==='IRR' ? $amount : $amount*10;
            if ($rials<=0 || $rials>PHP_INT_MAX) { vc_dp_error_redirect($id,'مبلغ ریالی معتبر نیست.'); }
            $provider = 'vesta-rf-'.$id.'-'.wp_generate_password(14,false,false);
            $items[] = array('provider'=>$provider,'store_amount'=>$amount,'rial_amount'=>$rials,'tracking'=>$tracking,
                'type'=>$type,'state'=>'uncertain','created'=>current_time('mysql',true),'remote_tracking'=>'','wc_refund_id'=>0);
            $n = count($items)-1;
            vc_dp_store($order,$items); // Persist idempotency BEFORE any external POST.
            $result = vc_dp_api($order,'refunds?type='.$type,array('providerId'=>$provider,'amount'=>$rials,'saleTrackingCode'=>$tracking));
            if (!is_wp_error($result) && $result['_http']===200 && isset($result['result']['status']) && (int)$result['result']['status']===0) {
                $items[$n]['state']='submitted';
                $items[$n]['remote_tracking']=isset($result['trackingCode']) ? sanitize_text_field((string)$result['trackingCode']) : '';
            }
            vc_dp_store($order,$items);
            $order->add_order_note('درخواست ریفاند دیجی‌پی با شناسه '.$provider.' ثبت شد؛ وضعیت: '.$items[$n]['state'].'. برای نتیجه نهایی استعلام کنید.');
            vc_dp_error_redirect($id,'درخواست ثبت شد؛ برای تأیید و ثبت نتیجه در ووکامرس از «استعلام وضعیت» استفاده کنید.','success');
        }
        if ($mode==='inquiry') {
            $n = isset($_POST['attempt']) ? absint($_POST['attempt']) : -1;
            if (!isset($items[$n]) || !in_array($items[$n]['state'],array('submitted','uncertain','processing','confirmed_unrecorded'),true)) {
                vc_dp_error_redirect($id,'درخواست قابل استعلام نیست.');
            }
            $item = $items[$n];
            $inquiry = $item['remote_tracking'] ? $item['remote_tracking'] : $item['provider'];
            $result = vc_dp_api($order,'refunds/'.rawurlencode($inquiry).'?type='.$item['type']);
            if (is_wp_error($result) || !isset($result['status']) || !isset($result['result']['status']) || (int)$result['result']['status']!==0) {
                vc_dp_error_redirect($id,'نتیجه استعلام مشخص نیست. درخواست دیگری نفرستید.');
            }
            $status = (int)$result['status'];
            if ($status===0) {
                $items[$n]['state']='confirmed_unrecorded';
                vc_dp_store($order,$items); // Never retry real transfers if Woo local record fails.
                if (empty($item['wc_refund_id'])) {
                    $refund = wc_create_refund(array('order_id'=>$id,'amount'=>$item['store_amount'],
                        'reason'=>'بازگشت وجه تأییدشده دیجی‌پی: '.$item['provider'],'refund_payment'=>false,'restock_items'=>false));
                    if (is_wp_error($refund)) { vc_dp_error_redirect($id,'دیجی‌پی موفقیت را تأیید کرد اما ثبت حسابداری ووکامرس ناموفق بود؛ بررسی دستی لازم است.'); }
                    $items[$n]['wc_refund_id'] = $refund->get_id();
                }
                $items[$n]['state']='completed';
                vc_dp_store($order,$items);
                $order->add_order_note('بازپرداخت دیجی‌پی تأیید و با شناسه '.$items[$n]['wc_refund_id'].' در ووکامرس ثبت شد.');
                vc_dp_error_redirect($id,'بازپرداخت توسط دیجی‌پی تأیید و در ووکامرس ثبت شد.','success');
            }
            if ($status===1) { $items[$n]['state']='failed'; vc_dp_store($order,$items); vc_dp_error_redirect($id,'دیجی‌پی اعلام کرد بازپرداخت ناموفق است.'); }
            $items[$n]['state']='processing'; vc_dp_store($order,$items);
            vc_dp_error_redirect($id,'بازپرداخت هنوز نهایی نشده است. بعداً دوباره استعلام کنید.','warning');
        }
        vc_dp_error_redirect($id,'درخواست نامعتبر است.');
    } finally { delete_option('vc_dp_refund_lock_'.$id); }
});