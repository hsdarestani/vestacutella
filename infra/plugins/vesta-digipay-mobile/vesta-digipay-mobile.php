<?php
/**
 * Plugin Name: Vesta DigiPay Mobile Number Compatibility
 * Description: Correctly normalizes Iranian mobile numbers before DigiPay's existing validation.
 * Version: 1.0.0
 */
if (!defined('ABSPATH')) exit;

/**
 * Never infer missing digits or replace a customer's number with another account phone.
 * Converts only known equivalent Iranian representations to canonical 09xxxxxxxxx.
 */
function vc_vesta_normalize_iran_mobile($raw) {
    if (!is_scalar($raw)) return '';
    $text = trim((string)$raw);
    if ($text === '') return '';
    $text = strtr($text, array(
        '۰'=>'0','۱'=>'1','۲'=>'2','۳'=>'3','۴'=>'4','۵'=>'5',
        '۶'=>'6','۷'=>'7','۸'=>'8','۹'=>'9',
        '٠'=>'0','١'=>'1','٢'=>'2','٣'=>'3','٤'=>'4','٥'=>'5',
        '٦'=>'6','٧'=>'7','٨'=>'8','٩'=>'9',
    ));
    $num = preg_replace('/[^0-9]/', '', $text);
    if (strpos($num, '0098') === 0) $num = '0' . substr($num, 4);
    elseif (strpos($num, '098') === 0) $num = '0' . substr($num, 3);
    elseif (strpos($num, '98') === 0) $num = '0' . substr($num, 2);
    elseif (preg_match('/^9[0-9]{9}$/D', $num)) $num = '0' . $num;
    return preg_match('/^09[0-9]{9}$/D', $num) ? $num : '';
}
function vc_vesta_is_digipay_method($method) {
    return is_string($method) && strcasecmp($method,'WCDigiPay') === 0;
}
/**
 * Save newly checked-out DigiPay order with a normalized number. Other gateways unchanged.
 */
add_filter('woocommerce_checkout_posted_data', function($data) {
    if (is_array($data) && vc_vesta_is_digipay_method(isset($data['payment_method'])?$data['payment_method']:'')) {
        $valid = vc_vesta_normalize_iran_mobile(isset($data['billing_phone'])?$data['billing_phone']:'');
        if ($valid !== '') $data['billing_phone'] = $valid;
    }
    return $data;
}, 10, 1);
/**
 * Fail early at checkout with actionable feedback instead of redirecting to the
 * DigiPay receipt page, generating a payment attempt, then showing a cryptic error.
 */
add_action('woocommerce_after_checkout_validation', function($data,$errors) {
    if (!is_array($data) || !vc_vesta_is_digipay_method(isset($data['payment_method'])?$data['payment_method']:'') || !is_wp_error($errors)) return;
    if (vc_vesta_normalize_iran_mobile(isset($data['billing_phone'])?$data['billing_phone']:'') === '') {
        $errors->add('vc_vesta_digipay_phone', 'برای پرداخت اقساطی دیجی‌پی، شماره موبایل معتبر وارد کنید (مثال: 09123456789).');
    }
}, 10, 2);
/**
 * Also cover existing pending orders on their order-pay/receipt flow. WooCommerce
 * invokes this filter from WC_Order::get_billing_phone() before the DigiPay plugin
 * reads it. Do not overwrite customer profile/order data or touch other gateways.
 */
add_filter('woocommerce_order_get_billing_phone', function($phone,$order) {
    if (!is_object($order) || !method_exists($order,'get_payment_method')) return $phone;
    if (!vc_vesta_is_digipay_method($order->get_payment_method())) return $phone;
    $valid=vc_vesta_normalize_iran_mobile($phone);
    return $valid !== '' ? $valid : $phone;
}, 10, 2);
