<?php
/**
 * Plugin Name: Vesta Automatic 40%+ Deals
 * Description: A live, paginated WooCommerce landing page for products discounted by strictly more than 40%.
 * Version: 1.0.0
 * Requires PHP: 7.4
 */
defined('ABSPATH') || exit;

function vc_vesta_offers_discount_pct($regular, $current) {
    $regular = (float) $regular;
    $current = (float) $current;
    if ($regular <= 0 || $current < 0 || $current >= $regular) {
        return 0.0;
    }
    return 100.0 * ($regular - $current) / $regular;
}

function vc_vesta_offers_item_pct($item) {
    if (!($item instanceof WC_Product) || !$item->is_visible() ||
        !$item->is_in_stock() || !$item->is_on_sale()) {
        return 0.0;
    }
    return vc_vesta_offers_discount_pct($item->get_regular_price(), $item->get_price());
}

/**
 * Sale IDs are supplied by WooCommerce, including sale variations. For variable
 * parents evaluate each actual, in-stock variation instead of comparing
 * unrelated min/max variation prices.
 */
function vc_vesta_offers_product_ids() {
    $cached = get_transient('vc_vesta_offers_over40_v1');
    if (is_array($cached)) {
        return $cached;
    }
    if (!function_exists('wc_get_product_ids_on_sale')) {
        return array();
    }

    $results = array();
    $seen_variable = array();
    foreach (array_unique(array_map('absint', wc_get_product_ids_on_sale())) as $id) {
        $item = wc_get_product($id);
        if (!($item instanceof WC_Product)) {
            continue;
        }

        if ($item->is_type('variation')) {
            $parent_id = (int) $item->get_parent_id();
            if (!$parent_id) {
                continue;
            }
            $parent = wc_get_product($parent_id);
            if (!($parent instanceof WC_Product) || !$parent->is_visible() || !$parent->is_in_stock()) {
                continue;
            }
            $pct = vc_vesta_offers_item_pct($item);
            if ($pct > 40.0 && (!isset($results[$parent_id]) || $results[$parent_id] < $pct)) {
                $results[$parent_id] = $pct;
            }
            continue;
        }

        if ($item->is_type('variable')) {
            if (isset($seen_variable[$id])) {
                continue;
            }
            $seen_variable[$id] = true;
            if (!$item->is_visible() || !$item->is_in_stock()) {
                continue;
            }
            foreach ($item->get_children() as $variation_id) {
                $variation = wc_get_product($variation_id);
                $pct = vc_vesta_offers_item_pct($variation);
                if ($pct > 40.0 && (!isset($results[$id]) || $pct > $results[$id])) {
                    $results[$id] = $pct;
                }
            }
            continue;
        }

        $pct = vc_vesta_offers_item_pct($item);
        if ($pct > 40.0) {
            $results[$id] = $pct;
        }
    }

    arsort($results, SORT_NUMERIC);
    $ids = array_map('intval', array_keys($results));
    set_transient('vc_vesta_offers_over40_v1', $ids, 120);
    return $ids;
}

function vc_vesta_offers_invalidate() {
    delete_transient('vc_vesta_offers_over40_v1');
}
add_action('woocommerce_update_product', 'vc_vesta_offers_invalidate');
add_action('woocommerce_new_product', 'vc_vesta_offers_invalidate');
add_action('woocommerce_delete_product_transients', 'vc_vesta_offers_invalidate');
add_action('save_post_product', 'vc_vesta_offers_invalidate');
add_action('save_post_product_variation', 'vc_vesta_offers_invalidate');
add_action('woocommerce_update_product_variation', 'vc_vesta_offers_invalidate');

function vc_vesta_offers_shortcode() {
    if (!function_exists('wc_get_product')) {
        return '<p>فروشگاه در حال به‌روزرسانی است. لطفاً دوباره تلاش کنید.</p>';
    }
    $all = vc_vesta_offers_product_ids();
    $size = 16;
    $page = isset($_GET['offer_page']) ? max(1, min(10000, absint(wp_unslash($_GET['offer_page'])))) : 1;
    $total = count($all);
    $pages = max(1, (int) ceil($total / $size));
    $page = min($page, $pages);
    $ids = array_slice($all, ($page - 1) * $size, $size);

    ob_start();
    echo '<section class="vc-vesta-offer-40" dir="rtl" data-vc-offer="over40">';
    echo '<div class="vc-offer-heading"><h1>تخفیف‌های بالای ۴۰٪</h1>';
    echo '<p>محصولات با بیش از ۴۰ درصد تخفیف واقعی، به‌صورت خودکار از فروشگاه وستا</p></div>';

    if ($ids) {
        // Use native WooCommerce / Woodmart cards with their stock and variation actions.
        $loop = new WP_Query(array(
            'post_type' => 'product',
            'post_status' => 'publish',
            'post__in' => $ids,
            'orderby' => 'post__in',
            'posts_per_page' => $size,
            'no_found_rows' => true,
            'ignore_sticky_posts' => true,
        ));
        if ($loop->have_posts()) {
            wc_setup_loop(array('name' => 'vc_vesta_over40', 'columns' => 4, 'is_shortcode' => true));
            woocommerce_product_loop_start();
            while ($loop->have_posts()) {
                $loop->the_post();
                wc_get_template_part('content', 'product');
            }
            woocommerce_product_loop_end();
            woocommerce_reset_loop();
        }
        wp_reset_postdata();
    } else {
        echo '<p class="vc-offer-empty">در حال حاضر محصول موجود با تخفیف بالای ۴۰٪ نداریم. به‌زودی دوباره سر بزنید.</p>';
    }

    if ($pages > 1) {
        echo '<nav class="vc-offer-pagination" aria-label="صفحات محصولات">';
        $first = max(1, $page - 2);
        $last = min($pages, $page + 2);
        if ($page > 1) {
            echo '<a href="' . esc_url(add_query_arg('offer_page', $page - 1, get_permalink())) . '">قبلی</a>';
        }
        for ($i = $first; $i <= $last; $i++) {
            $link = $i === 1 ? get_permalink() : add_query_arg('offer_page', $i, get_permalink());
            echo '<a ' . ($i === $page ? 'aria-current="page" class="current"' : '') .
                ' href="' . esc_url($link) . '">' . esc_html($i) . '</a>';
        }
        if ($page < $pages) {
            echo '<a href="' . esc_url(add_query_arg('offer_page', $page + 1, get_permalink())) . '">بعدی</a>';
        }
        echo '</nav>';
    }
    echo '</section>';
    return ob_get_clean();
}
add_shortcode('vc_vesta_over_40', 'vc_vesta_offers_shortcode');

add_action('wp_head', function () {
    if (!is_page('off-40')) {
        return;
    }
    echo '<style id="vc-vesta-offer-css">';
    echo '.vc-vesta-offer-40{max-width:1250px;margin:30px auto 60px;padding:0 18px}';
    echo '.vc-offer-heading{text-align:center;margin:22px 0 36px}';
    echo '.vc-offer-heading h1{font-size:clamp(24px,4vw,38px);font-weight:800;margin-bottom:12px}';
    echo '.vc-offer-heading p{color:#666;margin:0}';
    echo '.vc-offer-pagination{display:flex;justify-content:center;gap:10px;flex-wrap:wrap;margin:35px 0}';
    echo '.vc-offer-pagination a{display:inline-flex;min-width:40px;min-height:40px;align-items:center;justify-content:center;border:1px solid #ddd;border-radius:7px;padding:0 12px}';
    echo '.vc-offer-pagination .current{background:#282828;color:#fff;border-color:#282828}';
    echo '.vc-offer-empty{text-align:center;padding:45px 10px}';
    echo '</style>';
}, 20);
