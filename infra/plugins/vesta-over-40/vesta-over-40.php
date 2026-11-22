<?php
/**
 * Plugin Name: Vesta Automatic Black Friday Deals
 * Description: Live, paginated all-sale listing and dynamic Woodmart Black Friday product badges.
 * Version: 1.1.0
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
    $cached = get_transient('vc_vesta_offers_anysale_v2');
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
            if ($pct > 0.0 && (!isset($results[$parent_id]) || $results[$parent_id] < $pct)) {
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
                if ($pct > 0.0 && (!isset($results[$id]) || $pct > $results[$id])) {
                    $results[$id] = $pct;
                }
            }
            continue;
        }

        $pct = vc_vesta_offers_item_pct($item);
        if ($pct > 0.0) {
            $results[$id] = $pct;
        }
    }

    arsort($results, SORT_NUMERIC);
    $ids = array_map('intval', array_keys($results));
    set_transient('vc_vesta_offers_anysale_v2', $ids, 120);
    return $ids;
}

function vc_vesta_offers_invalidate() {
    delete_transient('vc_vesta_offers_anysale_v2');
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
    echo '<section class="vc-vesta-offer-40" dir="rtl" data-vc-offer="all-sale">';
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
        echo '<p class="vc-offer-empty">در حال حاضر محصول موجود با تخفیف فعال نداریم. به‌زودی دوباره سر بزنید.</p>';
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
    echo '.vc-offer-pagination{display:flex;justify-content:center;gap:10px;flex-wrap:wrap;margin:35px 0}';
    echo '.vc-offer-pagination a{display:inline-flex;min-width:40px;min-height:40px;align-items:center;justify-content:center;border:1px solid #ddd;border-radius:7px;padding:0 12px}';
    echo '.vc-offer-pagination .current{background:#282828;color:#fff;border-color:#282828}';
    echo '.vc-offer-empty{text-align:center;padding:45px 10px}';
    echo '</style>';
}, 20);


/**
 * Preserve Woodmart's live sale percentage as the source of truth. The original
 * label stays intact when JavaScript is disabled; on the frontend, only its
 * visual representation becomes the requested Black Friday PNG plus the number.
 * No prices, Woo product metadata or category assignments are modified.
 */
add_action('wp_head', function () {
    if (is_admin()) {
        return;
    }
    ?>
    <style id="vesta-bf-badge-css">
    .product-labels .onsale.product-label.vc-vesta-bf-badge {
        width: 96px !important;
        height: 88px !important;
        min-width: 96px !important;
        min-height: 88px !important;
        max-width: none !important;
        border: 0 !important;
        border-radius: 0 !important;
        box-shadow: none !important;
        background-color: transparent !important;
        background-image: url("https://vesta-cosmetics.ir/wp-content/uploads/2026/11/IMG_3921-1.png") !important;
        background-repeat: no-repeat !important;
        background-position: center center !important;
        background-size: 100% 100% !important;
        display: flex !important;
        flex-direction: row !important;
        align-items: flex-end !important;
        justify-content: flex-start !important;
        box-sizing: border-box !important;
        padding: 0 0 15px 17px !important;
        margin: 0 !important;
        color: #fff !important;
        font-size: 26px !important;
        font-weight: 900 !important;
        line-height: 1 !important;
        white-space: nowrap !important;
        text-align: left !important;
        direction: ltr !important;
        text-shadow: 0 1px 2px rgba(0,0,0,.35) !important;
        letter-spacing: -1px !important;
        position: relative;
        z-index: 2;
    }
    @media (max-width: 767px) {
        .product-labels .onsale.product-label.vc-vesta-bf-badge {
            width: 76px !important;
            height: 70px !important;
            min-width: 76px !important;
            min-height: 70px !important;
            padding: 0 0 12px 14px !important;
            font-size: 21px !important;
        }
    }
    </style>
    <?php
}, 20);

add_action('wp_footer', function () {
    if (is_admin()) {
        return;
    }
    ?>
    <script id="vesta-bf-badge-js">
    (function () {
        "use strict";
        var selector = ".product-labels .onsale.product-label";
        function decorate(label) {
            if (!label || !label.textContent) return;
            var raw = label.textContent.replace(/[\s\u200e\u200f\u061c]/g, "");
            var match = raw.match(/^[\u002d\u2212\u2013]?([0-9\u06f0-\u06f9\u0660-\u0669]{1,3})[%\u066a]$/);
            if (!match) return;
            var digits = match[1];
            label.textContent = digits;
            label.classList.add("vc-vesta-bf-badge");
            label.setAttribute("aria-label", "تخفیف " + digits + " درصد");
        }
        function scan(root) {
            if (!root || (root.nodeType !== 1 && root.nodeType !== 9)) return;
            if (root.matches && root.matches(selector)) decorate(root);
            if (root.querySelectorAll) {
                var labels = root.querySelectorAll(selector);
                for (var i = 0; i < labels.length; i++) decorate(labels[i]);
            }
        }
        scan(document);
        if (typeof MutationObserver !== "function" || !document.body) return;
        new MutationObserver(function (changes) {
            for (var i = 0; i < changes.length; i++) {
                var mutation = changes[i];
                if (mutation.target && mutation.target.nodeType === 1 &&
                    mutation.target.matches && mutation.target.matches(selector)) {
                    decorate(mutation.target);
                }
                for (var j = 0; j < mutation.addedNodes.length; j++) {
                    scan(mutation.addedNodes[j]);
                }
            }
        }).observe(document.body, {subtree: true, childList: true});
    })();
    </script>
    <?php
}, 30);
