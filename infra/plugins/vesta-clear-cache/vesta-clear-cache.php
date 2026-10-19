<?php
/**
 * Plugin Name: Vesta Clear Cache Control
 * Description: Restores a protected top toolbar and Tools menu action for clearing Vesta WP Rocket page cache.
 * Version: 1.0.0
 */
if (!defined('ABSPATH')) exit;
if (!function_exists('vc_vesta_cache_user_allowed')) {
    function vc_vesta_cache_user_allowed() {
        return current_user_can('manage_options') || current_user_can('manage_woocommerce');
    }
    function vc_vesta_cache_admin_url() {
        return wp_nonce_url(admin_url('admin-post.php?action=vc_vesta_purge_page_cache'), 'vc_vesta_purge_page_cache');
    }
    function vc_vesta_cache_purge_action() {
        if (!vc_vesta_cache_user_allowed()) wp_die('Access denied', '', array('response'=>403));
        check_admin_referer('vc_vesta_purge_page_cache');
        $ok = false;
        if (function_exists('rocket_clean_domain')) {
            rocket_clean_domain();
            $ok = true;
        }
        // No Redis flush, no sessions, no WooCommerce orders, no global shared Nginx cache purge.
        // Nginx anonymous homepage cache naturally expires within 12 seconds.
        $target = wp_get_referer();
        if (!$target || strpos($target, 'admin-post.php') !== false) {
            $target = admin_url('tools.php?page=vc-vesta-clear-cache');
        }
        $target = remove_query_arg(array('vc_cache_purged', 'vc_cache_error'), $target);
        wp_safe_redirect(add_query_arg($ok ? 'vc_cache_purged' : 'vc_cache_error', '1', $target));
        exit;
    }
    function vc_vesta_cache_toolbar($bar) {
        if (!vc_vesta_cache_user_allowed()) return;
        $bar->add_node(array(
            'id' => 'vc-vesta-clear-cache',
            'title' => 'حذف کش وستا',
            'href' => vc_vesta_cache_admin_url(),
            'meta' => array('title'=>'پاک کردن کش صفحات وستا'),
        ));
    }
    function vc_vesta_cache_tools_menu() {
        if (!vc_vesta_cache_user_allowed()) return;
        $cap = current_user_can('manage_options') ? 'manage_options' : 'manage_woocommerce';
        add_management_page('حذف کش وستا', 'حذف کش وستا', $cap, 'vc-vesta-clear-cache', 'vc_vesta_cache_tools_page');
    }
    function vc_vesta_cache_tools_page() {
        if (!vc_vesta_cache_user_allowed()) wp_die('Access denied', '', array('response'=>403));
        echo '<div class="wrap"><h1>حذف کش وستا</h1>';
        if (isset($_GET['vc_cache_purged'])) echo '<div class="notice notice-success"><p>کش صفحات وستا پاک شد. کش کوتاه‌مدت Nginx هم ظرف حدود ۱۲ ثانیه تازه می‌شود.</p></div>';
        if (isset($_GET['vc_cache_error'])) echo '<div class="notice notice-error"><p>WP Rocket در دسترس نیست. کش پاک نشد.</p></div>';
        echo '<p>فقط کش صفحات WP Rocket پاک می‌شود؛ سفارش‌ها، سبد خرید و موجودی تغییر نمی‌کنند.</p>';
        echo '<form action="' . esc_url(admin_url('admin-post.php')) . '" method="post">';
        echo '<input type="hidden" name="action" value="vc_vesta_purge_page_cache">';
        wp_nonce_field('vc_vesta_purge_page_cache');
        submit_button('حذف کش سایت');
        echo '</form></div>';
    }
}
add_action('admin_bar_menu', 'vc_vesta_cache_toolbar', 9999);
add_action('admin_menu', 'vc_vesta_cache_tools_menu', 50);
add_action('admin_post_vc_vesta_purge_page_cache', 'vc_vesta_cache_purge_action');
