<?php
/**
 * Plugin Name: Vesta October mobile banner WebP
 * Description: Mobile-specific optimized WebP for the two October homepage banners, originals unchanged.
 */
if (!defined('ABSPATH')) exit;

/**
 * Keep a full-resolution PNG <img> fallback for desktop and older browsers.
 * Operates only on WP Rocket homepage HTML, like the existing Vesta hero plugin.
 */
function vc_oct_banner_webp_buffer($html) {
    if (!is_string($html) || strpos($html, 'IMG_9282-1.png') === false) {
        return $html;
    }
    $images = array(
        '/wp-content/uploads/2026/10/IMG_9282-1.png' => '/wp-content/uploads/2026/10/IMG_9282-1.png.vc20261019-mobile.webp',
        '/wp-content/uploads/2026/10/IMG_9279-1.png' => '/wp-content/uploads/2026/10/IMG_9279-1.png.vc20261019-mobile.webp',
    );
    $output = preg_replace_callback('~<img\b[^>]*>~i', static function($match) use($images) {
        $tag = $match[0];
        if (strpos($tag, 'vc20261019-mobile.webp') !== false) return $tag;
        if (!preg_match('~\bsrc\s*=\s*(["\x27])([^"\x27]+)\1~i', $tag, $src)) return $tag;
        $url = html_entity_decode($src[2], ENT_QUOTES, 'UTF-8');
        $path = wp_parse_url($url, PHP_URL_PATH);
        if (!is_string($path) || !isset($images[$path])) return $tag;
        // Existing srcset must remain owned by WordPress, not be rewritten here.
        if (preg_match('~\b(?:data-)?srcset\s*=~i', $tag)) return $tag;
        $optimized = esc_url(home_url($images[$path]));
        return '<picture class="vc-oct-banner-mobile-webp"><source media="(max-width: 767px)" type="image/webp" srcset="'.$optimized.'">'.$tag.'</picture>';
    }, $html, 600);
    return is_string($output) ? $output : $html;
}
add_filter('rocket_buffer', function($html) {
    if (is_admin() || !is_front_page()) return $html;
    return vc_oct_banner_webp_buffer($html);
}, 1005);

add_action('wp_head', function() {
    if (is_admin() || !is_front_page()) return;
    $url = esc_url(home_url('/wp-content/uploads/2026/10/IMG_9282-1.png.vc20261019-mobile.webp'));
    echo '<link id="vc-oct-banner-preload" rel="preload" as="image" type="image/webp" media="(max-width: 767px)" fetchpriority="high" href="'.$url.'">'."\n";
}, 1);
