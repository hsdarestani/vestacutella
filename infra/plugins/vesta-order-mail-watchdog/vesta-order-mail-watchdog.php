<?php
/**
 * Plugin Name: Vesta Reliable Admin New Order Email
 * Description: Watch actual WooCommerce new-order deliveries; retry only missing admin notifications after checkout/API order creation.
 * Version: 1.0.0
 */
if (!defined('ABSPATH')) exit;
if (!function_exists('vc_vesta_order_mail_schedule')) {
    function vc_vesta_order_mail_enabled_since() {
        return (int)get_option('vc_vesta_order_mail_watchdog_start', 0);
    }
    function vc_vesta_order_mail_valid($order) {
        if (!$order || !is_a($order, 'WC_Order')) return false;
        $start = vc_vesta_order_mail_enabled_since();
        $created = $order->get_date_created();
        return $start > 0 && $created && $created->getTimestamp() >= $start &&
               in_array($order->get_status(), array('processing','completed','on-hold'), true);
    }
    function vc_vesta_order_mail_schedule($id) {
        if (!function_exists('wc_get_order')) return;
        $order = wc_get_order((int)$id);
        if (!vc_vesta_order_mail_valid($order)) return;
        if ($order->get_meta('_vc_vesta_admin_new_order_accepted', true)) return;
        if (!wp_next_scheduled('vc_vesta_admin_new_order_watchdog', array((int)$id))) {
            // Give native WooCommerce and payment gateway triggers time to run.
            wp_schedule_single_event(time() + 240, 'vc_vesta_admin_new_order_watchdog', array((int)$id));
        }
    }
    function vc_vesta_order_mail_record($sent, $id, $email) {
        if (!$sent || $id !== 'new_order' || !is_object($email)) return;
        $order = isset($email->object) ? $email->object : null;
        if (!vc_vesta_order_mail_valid($order)) return;
        $order->update_meta_data('_vc_vesta_admin_new_order_accepted', 'native:' . gmdate('c'));
        $order->save_meta_data();
    }
    function vc_vesta_order_mail_retry($id) {
        $id = absint($id);
        $order = wc_get_order($id);
        if (!vc_vesta_order_mail_valid($order)) return;
        if ($order->get_meta('_vc_vesta_admin_new_order_accepted', true)) return;
        $attempts = (int)$order->get_meta('_vc_vesta_admin_new_order_retries', true);
        if ($attempts >= 4) return;
        // Use an atomically inserted temporary lock to prevent two workers mailing at once.
        $lock = 'vc_vesta_order_mail_lock_' . $id;
        $ts = (int)get_option($lock, 0);
        if ($ts && time() - $ts > 300) delete_option($lock);
        if (!add_option($lock, time(), '', 'no')) return;
        try {
            $emails = WC()->mailer()->get_emails();
            $new = null;
            foreach ($emails as $email) if (isset($email->id) && $email->id === 'new_order') $new = $email;
            if (!$new || !$new->is_enabled()) return;
            $to = array_values(array_filter(array_map('trim', explode(',',(string)$new->get_recipient())), 'is_email'));
            if (count($to) !== 1) return;
            $ok = false;
            $successListener = function($args) use (&$ok) {
                // Scoped to this single synchronous trigger invocation.
                $ok = true;
            };
            add_action('wp_mail_succeeded', $successListener, 10, 1);
            try { $new->trigger($id, $order); }
            finally { remove_action('wp_mail_succeeded', $successListener, 10); }
            $order = wc_get_order($id);
            if ($ok) {
                $order->update_meta_data('_vc_vesta_admin_new_order_accepted', 'watchdog:' . gmdate('c'));
                $order->save_meta_data();
            } else {
                $attempts++;
                $order->update_meta_data('_vc_vesta_admin_new_order_retries', $attempts);
                $order->save_meta_data();
                error_log('Vesta admin order email watchdog: mail not accepted (id suppressed)');
                if ($attempts < 4 && !wp_next_scheduled('vc_vesta_admin_new_order_watchdog', array($id))) {
                    wp_schedule_single_event(time()+300*$attempts, 'vc_vesta_admin_new_order_watchdog', array($id));
                }
            }
        } catch (Throwable $e) {
            error_log('Vesta admin order email watchdog: trigger exception, order suppressed');
        } finally {
            delete_option($lock);
        }
    }
}
add_action('woocommerce_email_sent', 'vc_vesta_order_mail_record', 10, 3);
add_action('woocommerce_new_order', 'vc_vesta_order_mail_schedule', 70, 1);
add_action('woocommerce_order_status_changed', function($id) { vc_vesta_order_mail_schedule($id); }, 70, 1);
add_action('woocommerce_checkout_order_processed', 'vc_vesta_order_mail_schedule', 70, 1);
add_action('woocommerce_store_api_checkout_order_processed', function($order) {
    if (is_object($order) && method_exists($order,'get_id')) vc_vesta_order_mail_schedule($order->get_id());
}, 70, 1);
add_action('vc_vesta_admin_new_order_watchdog', 'vc_vesta_order_mail_retry', 10, 1);
