<?php
/**
 * Plugin Name: Vesta Telegram Low/Out Stock Alerts
 * Description: Notify the existing configured Telegram order-notification chats when inventory reaches 2 or 0.
 * Version: 1.0.0
 */
if (!defined('ABSPATH')) exit;
if (!function_exists('vc_vesta_stock_bot_state')) {
    function vc_vesta_stock_bot_state($product) {
        if (!$product || !is_a($product, 'WC_Product')) return 'ignore';
        if (in_array($product->get_status(), array('trash', 'draft', 'auto-draft'), true)) return 'ignore';
        $stockStatus = $product->get_stock_status();
        $manage = $product->managing_stock();
        $qty = $product->get_stock_quantity();
        if ($stockStatus === 'outofstock' || ($manage && is_numeric($qty) && (float)$qty <= 0)) return 'out';
        if ($manage && is_numeric($qty) && (float)$qty <= 2) return 'low';
        return 'ok';
    }
    function vc_vesta_stock_bot_product_id($p) {
        if (is_numeric($p)) $p = wc_get_product((int)$p);
        if (!$p || !is_a($p, 'WC_Product')) return 0;
        // Inherited variation stock belongs to the parent (not each child).
        if (method_exists($p, 'get_stock_managed_by_id')) {
            $managed = (int)$p->get_stock_managed_by_id();
            if ($managed > 0 && $managed !== (int)$p->get_id()) return $managed;
        }
        return (int)$p->get_id();
    }
    function vc_vesta_stock_bot_queue($p) {
        if (!function_exists('wc_get_product')) return;
        $id = vc_vesta_stock_bot_product_id($p);
        if ($id < 1) return;
        $product = wc_get_product($id);
        if (!$product) return;
        $state = vc_vesta_stock_bot_state($product);
        if ($state === 'ignore') return;
        $previous = get_post_meta($id, '_vc_vesta_stock_bot_notified_state', true);
        if ($state === 'ok') {
            if ($previous !== 'ok') update_post_meta($id, '_vc_vesta_stock_bot_notified_state', 'ok');
            delete_post_meta($id, '_vc_vesta_stock_bot_partial');
            return;
        }
        if ($previous === $state) return;
        // Scheduled work leaves checkout and admin stock updates responsive.
        if (!wp_next_scheduled('vc_vesta_stock_bot_dispatch', array($id))) {
            wp_schedule_single_event(time()+15, 'vc_vesta_stock_bot_dispatch', array($id));
        }
    }
    function vc_vesta_stock_bot_recipients() {
        $token = trim((string)get_option('onftb_setting_token', ''));
        $chatStr = (string)get_option('onftb_setting_chatid', '');
        if (!preg_match('/^[0-9]{6,}:[A-Za-z0-9_-]{25,}$/D', $token)) return array();
        $chats = array_unique(array_filter(array_map('trim', explode(',', $chatStr))));
        if (count($chats) < 1 || count($chats) > 5) return array();
        foreach ($chats as $chat) if (!preg_match('/^-?[0-9]{3,20}$/D', $chat)) return array();
        return array('token' => $token, 'chats' => array_values($chats));
    }
    function vc_vesta_stock_bot_send($text, $productId = 0, $state = 'test') {
        $c = vc_vesta_stock_bot_recipients();
        if (!$c) { error_log('Vesta stock bot: existing bot token or chat configuration missing'); return false; }
        $base = 'https://api.telegram.org/bot' . $c['token'] . '/sendMessage';
        $partialKey = '_vc_vesta_stock_bot_partial';
        $partial = $productId ? get_post_meta($productId, $partialKey, true) : array();
        if (!is_array($partial) || ($partial['state'] ?? '') !== $state) {
            $partial = array('state'=>$state, 'accepted'=>array());
        }
        foreach ($c['chats'] as $chat) {
            $idHash = hash('sha256', (string)$chat);
            if (!empty($partial['accepted'][$idHash])) continue;
            $r = wp_remote_post($base, array(
                'timeout' => 14, 'redirection' => 0,
                'body' => array(
                    'chat_id' => $chat,
                    'text' => $text,
                    'disable_web_page_preview' => 'true',
                ),
            ));
            if (is_wp_error($r)) {
                error_log('Vesta stock bot: Telegram transport unavailable');
                continue;
            }
            $code = (int)wp_remote_retrieve_response_code($r);
            $payload = json_decode((string)wp_remote_retrieve_body($r), true);
            if ($code === 200 && is_array($payload) && !empty($payload['ok'])) {
                $partial['accepted'][$idHash] = true;
                if ($productId) update_post_meta($productId, $partialKey, $partial);
            } else {
                error_log('Vesta stock bot: Telegram did not accept stock alert, HTTP ' . $code);
            }
        }
        foreach ($c['chats'] as $chat) {
            if (empty($partial['accepted'][hash('sha256', (string)$chat)])) return false;
        }
        if ($productId) delete_post_meta($productId, $partialKey);
        return true;
    }
    function vc_vesta_stock_bot_dispatch($id) {
        $id = absint($id);
        if ($id < 1) return;
        $product = wc_get_product($id);
        if (!$product) return;
        $state = vc_vesta_stock_bot_state($product);
        if ($state === 'ignore') return;
        $previous = (string)get_post_meta($id, '_vc_vesta_stock_bot_notified_state', true);
        if ($state === 'ok') {
            update_post_meta($id, '_vc_vesta_stock_bot_notified_state', 'ok');
            delete_post_meta($id, '_vc_vesta_stock_bot_partial');
            return;
        }
        if ($previous === $state) return;
        $name = trim(wp_strip_all_tags($product->get_name()));
        if (function_exists('mb_substr')) $name = mb_substr($name, 0, 160);
        else $name = substr($name, 0, 160);
        $sku = trim((string)$product->get_sku());
        $sku = $sku !== '' ? "\nکد محصول: " . $sku : '';
        $qty = $product->get_stock_quantity();
        if ($state === 'out') $head = "🔴 محصول ناموجود شد\nموجودی: ۰";
        else {
            $q = is_numeric($qty) ? max(0, (int)$qty) : 2;
            $head = "⚠️ موجودی رو به اتمام\nفقط " . $q . " عدد باقی مانده";
        }
        $url = get_edit_post_link($id, 'raw');
        if (!$url) $url = admin_url('post.php?post='.$id.'&action=edit');
        $text = $head."\nمحصول: ".$name.$sku."\nویرایش موجودی: ".$url;
        if (vc_vesta_stock_bot_send($text, $id, $state)) {
            update_post_meta($id, '_vc_vesta_stock_bot_notified_state', $state);
            delete_post_meta($id, '_vc_vesta_stock_bot_retries');
        } else {
            $attempts = (int)get_post_meta($id, '_vc_vesta_stock_bot_retries', true) + 1;
            update_post_meta($id, '_vc_vesta_stock_bot_retries', $attempts);
            if ($attempts < 5 && !wp_next_scheduled('vc_vesta_stock_bot_dispatch', array($id))) {
                wp_schedule_single_event(time() + (300 * $attempts), 'vc_vesta_stock_bot_dispatch', array($id));
            }
        }
    }
}
add_action('woocommerce_product_set_stock', 'vc_vesta_stock_bot_queue', 20, 1);
add_action('woocommerce_variation_set_stock', 'vc_vesta_stock_bot_queue', 20, 1);
add_action('woocommerce_low_stock', 'vc_vesta_stock_bot_queue', 20, 1);
add_action('woocommerce_no_stock', 'vc_vesta_stock_bot_queue', 20, 1);
add_action('woocommerce_product_set_stock_status', function($id) { vc_vesta_stock_bot_queue($id); }, 20, 1);
add_action('woocommerce_variation_set_stock_status', function($id) { vc_vesta_stock_bot_queue($id); }, 20, 1);
add_action('woocommerce_product_object_updated_props', function($product, $updated) {
    if (is_array($updated) && (in_array('stock_quantity',$updated,true) || in_array('stock_status',$updated,true))) {
        vc_vesta_stock_bot_queue($product);
    }
}, 20, 2);
add_action('vc_vesta_stock_bot_dispatch', 'vc_vesta_stock_bot_dispatch', 10, 1);
