<?php
/**
 * Plugin Name: Vesta Pinterest product sharing
 * Description: Clean share-to-Pinterest links and product image OG metadata; no API, tracking, or automatic posting.
 * Version: 1.0.0
 */
if (!defined('ABSPATH')) { exit; }

if (!function_exists('vc_pin_product_context')) {
    function vc_pin_product_context() {
        if (is_admin() || !function_exists('is_product') || !is_product() || !function_exists('wc_get_product')) {
            return false;
        }
        $id = get_queried_object_id();
        if (!$id) { return false; }
        $product = wc_get_product($id);
        if (!$product || $product->get_status() !== 'publish' || !$product->is_visible()) {
            return false;
        }
        $image_id = $product->get_image_id();
        $image = $image_id ? wp_get_attachment_image_url($image_id, 'full') : '';
        if (!$image || !wp_http_validate_url($image)) { return false; }
        $url = get_permalink($id);
        if (!$url || !wp_http_validate_url($url)) { return false; }
        return array('product' => $product, 'image_id' => $image_id, 'image' => $image, 'url' => $url);
    }
}

if (!function_exists('vc_pin_product_meta')) {
    function vc_pin_product_meta() {
        $ctx = vc_pin_product_context();
        if (!$ctx) { return; }
        $p = $ctx['product'];
        $title = wp_strip_all_tags($p->get_name());
        $text = trim(preg_replace('/\s+/u', ' ', wp_strip_all_tags($p->get_short_description() ?: $p->get_description())));
        if (!$text) { $text = $title; }
        $text = function_exists('mb_substr') ? mb_substr($text, 0, 300) : substr($text, 0, 300);
        $pairs = array(
            'og:type' => 'product',
            'og:title' => $title,
            'og:description' => $text,
            'og:url' => $ctx['url'],
            'og:image' => $ctx['image'],
        );
        // Do not duplicate metadata owned by a dedicated SEO plugin.
        if (defined('WPSEO_VERSION') || defined('RANK_MATH_VERSION') || defined('AIOSEO_VERSION') || defined('SEOPRESS_VERSION')) {
            return;
        }
        $metadata = wp_get_attachment_metadata($ctx['image_id']);
        if (is_array($metadata) && !empty($metadata['width']) && !empty($metadata['height'])) {
            $pairs['og:image:width'] = (string)intval($metadata['width']);
            $pairs['og:image:height'] = (string)intval($metadata['height']);
        }
        foreach ($pairs as $k => $v) {
            echo '<meta property="' . esc_attr($k) . '" content="' . esc_attr($v) . '">' . "\n";
        }
        echo '<meta name="twitter:card" content="summary_large_image">' . "\n";
        // Prices are intentionally omitted: WooCommerce uses IRT, not a Pinterest retail-catalog currency.
    }
    add_action('wp_head', 'vc_pin_product_meta', 10);
}

if (!function_exists('vc_pin_product_share_button')) {
    function vc_pin_product_share_button() {
        $ctx = vc_pin_product_context();
        if (!$ctx) { return; }
        $title = trim(wp_strip_all_tags($ctx['product']->get_name()));
        $description = $title . ' | فروشگاه وستا';
        $url = add_query_arg(array(
            'url' => $ctx['url'],
            'media' => $ctx['image'],
            'description' => $description
        ), 'https://www.pinterest.com/pin/create/button/');
        echo '<div class="vc-pin-share"><a class="vc-pin-share-link" href="' . esc_url($url) . '" target="_blank" rel="noopener noreferrer nofollow" aria-label="' . esc_attr('ذخیره تصویر محصول در پینترست: ' . $title) . '">';
        echo '<span aria-hidden="true" class="vc-pin-mark">P</span> ذخیره در پینترست</a></div>';
    }
    add_action('woocommerce_single_product_summary', 'vc_pin_product_share_button', 51);
}

if (!function_exists('vc_pin_product_share_css')) {
    function vc_pin_product_share_css() {
        if (!function_exists('is_product') || !is_product()) { return; }
        echo '<style id="vc-pin-share-style">.vc-pin-share{margin:12px 0 15px;clear:both}.vc-pin-share-link{display:inline-flex;align-items:center;gap:8px;padding:10px 16px;border:1px solid #d6d6d6;border-radius:8px;background:#fff;color:#2b2b2b!important;text-decoration:none!important;font:inherit;font-size:14px;line-height:1.6}.vc-pin-share-link:hover,.vc-pin-share-link:focus{border-color:#bd081c;color:#bd081c!important}.vc-pin-mark{color:#bd081c;font-size:17px;font-weight:800;font-family:Arial,sans-serif;line-height:1}</style>' . "\n";
    }
    add_action('wp_head', 'vc_pin_product_share_css', 30);
}
