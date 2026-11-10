<?php
// Controlled historical Bazara order replay; no customer details to stdout.
error_reporting(E_ERROR | E_PARSE);
ini_set('display_errors', '0');
$_SERVER['HTTP_HOST'] = 'vesta-cosmetics.ir';
$_SERVER['SERVER_NAME'] = 'vesta-cosmetics.ir';
$_SERVER['HTTPS'] = 'on';
$_SERVER['SERVER_PORT'] = '443';
$_SERVER['REQUEST_SCHEME'] = 'https';
$_SERVER['REQUEST_URI'] = '/wp-cron.php';
$_SERVER['REQUEST_METHOD'] = 'GET';
$_SERVER['REMOTE_ADDR'] = '127.0.0.1';
define('WP_USE_THEMES', false);
require '/var/www/html/wp-load.php';

function vc_order_log($key, $value) {
    $v = preg_replace('/[^A-Za-z0-9_.:-]/', '_', (string)$value);
    echo $key . '=' . substr($v, 0, 100) . PHP_EOL;
}
$id = (int) getenv('VC_ORDER_ID');
$allowed = array(105052, 105053, 105204, 105205, 105206, 105207);
if (!in_array($id, $allowed, true)) {
    vc_order_log('PRECHECK_ERROR', 'id_not_allowlisted');
    exit(10);
}
if (!function_exists('wc_get_order') || !class_exists('BazaraApi')) {
    vc_order_log('PRECHECK_ERROR', 'runtime_plugin_unavailable');
    exit(11);
}
global $wpdb;
$order = wc_get_order($id);
if (!$order) { vc_order_log('PRECHECK_ERROR', 'order_not_found'); exit(12); }
$status = $order->get_status();
vc_order_log('ORDER_ID', $id);
vc_order_log('WOO_STATUS', $status);
if (!in_array($status, array('completed', 'processing', 'processing5', 'pws-packaged', 'pws-shipping', 'arrival-shipment'), true)) {
    vc_order_log('PRECHECK_ERROR', 'not_eligible_order_status');
    exit(13);
}
$existing = trim((string)$order->get_meta('mahak_id', true));
$remoteReferenceCount = (int)$wpdb->get_var($wpdb->prepare(
    'SELECT COUNT(*) FROM ' . $wpdb->prefix . 'bazara_orders WHERE OrderClientId=%d', $id
));
vc_order_log('HAS_MAHAK_META', $existing !== '' ? 'yes' : 'no');
vc_order_log('LOCAL_ERP_MATCHES', $remoteReferenceCount);
if ($existing !== '' || $remoteReferenceCount > 0) {
    vc_order_log('ACTION', 'skipped_existing_erp_reference');
    exit(0);
}
// Explicit do-not-repeat safety. The script is executed only for one allowlisted order
// and failure stops subsequent orders. No unsupervised retry after an ambiguous API outcome.
if (getenv('VC_SEND_ORDER') !== 'yes') {
    vc_order_log('ACTION', 'check_only');
    exit(0);
}
vc_order_log('ACTION', 'sending_one_order');
$api = new BazaraApi();
try {
    $response = $api->bazara_save_order($id, null);
} catch (Throwable $e) {
    vc_order_log('SEND_RESULT', 'exception_uncertain');
    exit(21);
}
$success = is_array($response) && !empty($response['success']);
$message = is_array($response) && isset($response['message']) ? (string)$response['message'] : '';
$lower = strtolower($message);
$reason = 'unknown';
if (preg_match('/موجودی|stock|inventory/i', $lower)) $reason = 'stock_or_inventory';
elseif (preg_match('/کالا|product|item/i', $lower)) $reason = 'product_or_items';
elseif (preg_match('/timeout|ارتباط|connection|network/i', $lower)) $reason = 'network';
elseif (preg_match('/token|auth|اعتبار/i', $lower)) $reason = 'authorization';
elseif (preg_match('/already|duplicate|تکراری/i', $lower)) $reason = 'possibly_duplicate';
elseif (preg_match('/payment|bank|پرداخت/i', $lower)) $reason = 'payment_or_bank';
vc_order_log('API_RETURN_SUCCESS', $success ? 'yes' : 'no');
vc_order_log('API_RETURN_REASON', $reason);
$order = wc_get_order($id);
$final = $order ? trim((string)$order->get_meta('mahak_id', true)) : '';
$ref = (int)$wpdb->get_var($wpdb->prepare(
    'SELECT COUNT(*) FROM ' . $wpdb->prefix . 'bazara_orders WHERE OrderClientId=%d', $id
));
vc_order_log('AFTER_HAS_MAHAK_META', $final !== '' ? 'yes' : 'no');
vc_order_log('AFTER_LOCAL_ERP_MATCHES', $ref);
if ($success && ($final !== '' || $ref > 0)) {
    vc_order_log('VERDICT', 'verified_local_order_synced');
    exit(0);
}
if ($success) {
    vc_order_log('VERDICT', 'ambiguous_success_no_local_marker_do_not_retry');
    exit(22);
}
vc_order_log('VERDICT', 'failed_do_not_retry_without_investigation');
exit(23);
