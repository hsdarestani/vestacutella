<?php
/**
 * Plugin Name: Vesta Invoice Licence Diagnostics
 * Description: Temporary passive diagnostics for recurring invoice licence validation.
 * Version: 1.0.0
 *
 * Does not modify licence state, schedules, vendor plugin code, HTTP requests or responses.
 * Logs only timestamps, names of scheduled callbacks, HTTP hostname and status/error category.
 * Expires automatically on 2026-10-31. Remove after root cause is verified.
 */
defined('ABSPATH') || exit;
if (time() > 1793491199) { return; } // 2026-10-31 23:59:59 UTC

function vc_invoice_observer_log($message) {
    // Never include a URL, request body, headers, cookies, customer information or licence key.
    error_log('[vesta-invoice-validation] ' . gmdate('c') . ' ' . $message);
}

add_action('wip-guard-reg_daily_validator', function () {
    vc_invoice_observer_log('scheduled_validation_started');
}, -99999);

add_action('http_api_debug', function ($response, $context, $transport, $args, $url) {
    // We observe only requests *during* the known periodic validator callback.
    if (!doing_action('wip-guard-reg_daily_validator')) { return; }
    if ($context !== 'response') { return; }
    $host = is_string($url) ? wp_parse_url($url, PHP_URL_HOST) : '';
    $host = is_string($host) ? preg_replace('/[^a-z0-9.\-]/i', '', $host) : '';
    if (!$host) { $host = 'unknown'; }
    $result = 'unknown';
    if (is_wp_error($response)) {
        $code = preg_replace('/[^a-z0-9_\-]/i', '', (string) $response->get_error_code());
        $result = 'wp_error:' . substr($code, 0, 55);
    } elseif (is_array($response)) {
        $status = wp_remote_retrieve_response_code($response);
        $result = 'http:' . (int) $status;
    }
    vc_invoice_observer_log('validation_http host=' . substr($host, 0, 100) . ' result=' . $result);
}, 10, 5);

add_action('wip-guard-reg_daily_validator', function () {
    vc_invoice_observer_log('scheduled_validation_finished');
}, 99999);
