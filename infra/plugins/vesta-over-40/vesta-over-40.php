<?php
/**
 * Plugin Name: Vesta Automatic Black Friday Deals
 * Description: Live, paginated all-sale listing and dynamic Woodmart Black Friday product badges.
 * Version: 1.2.0
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

    // The catalog is already sorted by its highest real, in-stock sale discount.
    $highest = 0;
    if ($total) {
        $featured = wc_get_product($all[0]);
        if ($featured instanceof WC_Product) {
            if ($featured->is_type('variable')) {
                foreach ($featured->get_children() as $variation_id) {
                    $highest = max($highest, vc_vesta_offers_item_pct(wc_get_product($variation_id)));
                }
            } else {
                $highest = vc_vesta_offers_item_pct($featured);
            }
        }
    }
    $highest = (int) floor($highest);
    $sale_count = number_format_i18n($total);
    $highest_text = number_format_i18n($highest);

    ob_start();
    echo '<section class="vc-vesta-offer-40" dir="rtl" data-vc-offer="all-sale">';
    echo '<div class="vc-offer-hero">';
    echo '<div class="vc-offer-hero-copy">';
    echo '<div class="vc-offer-eyebrow"><span class="vc-offer-live-dot" aria-hidden="true"></span>پیشنهادهای ویژه وستا</div>';
    echo '<p class="vc-offer-english" lang="en" dir="ltr">VESTA BLACK FRIDAY</p>';
    echo '<h1>جمعه سیاه وستا<span class="vc-offer-hero-spark" aria-hidden="true">✦</span></h1>';
    echo '<p class="vc-offer-hero-description">هر محصولی که تخفیف فعال داشته باشه، اینجا منتظرته! از تخفیف‌های کوچیک تا پیشنهادهای حسابی جذاب.</p>';
    echo '<div class="vc-offer-hero-actions"><a class="vc-offer-primary-link" href="#vc-vesta-deals">دیدن محصولات تخفیف‌دار <span aria-hidden="true">←</span></a><span class="vc-offer-hero-footnote">تخفیف‌ها خودکار به‌روز می‌شن</span></div>';
    echo '</div>';
    echo '<div class="vc-offer-hero-visual" aria-hidden="true"><span class="vc-offer-hero-orbit"></span><img src="' . esc_url(home_url('/wp-content/uploads/2026/11/IMG_3921-1.png')) . '" alt="" width="250" height="250" loading="lazy" decoding="async">';
    if ($highest > 0) {
        echo '<strong class="vc-offer-art-number">' . esc_html($highest_text) . '</strong>';
    }
    echo '</div>';
    echo '</div>';
    echo '<div class="vc-offer-benefits">';
    echo '<div class="vc-offer-benefit"><span class="vc-offer-benefit-icon" aria-hidden="true">✦</span><div><strong>' . esc_html($sale_count) . ' محصول تخفیف‌دار</strong><small>تمام تخفیف‌های فعال فروشگاه</small></div></div>';
    echo '<div class="vc-offer-benefit"><span class="vc-offer-benefit-icon" aria-hidden="true">٪</span><div><strong>تخفیف‌های واقعی</strong><small>بر اساس قیمت فعلی محصولات</small></div></div>';
    echo '<div class="vc-offer-benefit"><span class="vc-offer-benefit-icon" aria-hidden="true">↻</span><div><strong>همیشه به‌روز</strong><small>بدون نیاز به ثبت دستی محصولات</small></div></div>';
    echo '</div>';
    echo '<div class="vc-offer-list-title" id="vc-vesta-deals"><div><span class="vc-offer-list-kicker">SPECIAL OFFERS / VESTA</span><h2>همه تخفیف‌های جمعه سیاه</h2><p>پیشنهادها رو از بیشترین درصد تخفیف ببین.</p></div><span class="vc-offer-count-chip">' . esc_html($sale_count) . ' محصول</span></div>';
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
    ?>
    body.page-id-101531 .main-page-wrapper {background:#faf9f8;}
    body.page-id-101531 .main-page-wrapper > .page-title {display:none !important;}
    body.page-id-101531 .main-page-wrapper > .container {max-width:1360px;}
    body.page-id-101531 .main-page-wrapper .entry-content {padding-bottom:35px;}
    .vc-vesta-offer-40{max-width:1290px;margin:20px auto 65px;padding:0 18px;font-family:inherit;}
    .vc-offer-hero{isolation:isolate;position:relative;overflow:hidden;display:grid;grid-template-columns:minmax(0,1.4fr) minmax(235px,.75fr);align-items:center;gap:24px;min-height:350px;border-radius:29px;padding:42px 58px;color:#fff;background:radial-gradient(ellipse at 84% 5%,rgba(241,45,69,.36),transparent 38%),radial-gradient(ellipse at 10% 110%,rgba(149,16,38,.34),transparent 43%),linear-gradient(115deg,#190f16,#2b101a 57%,#100e12);box-shadow:0 20px 56px rgba(37,12,23,.17);}
    .vc-offer-hero:before{content:"";pointer-events:none;position:absolute;inset:15px;border:1px solid rgba(255,220,205,.1);border-radius:22px;z-index:-1;}
    .vc-offer-hero:after{content:"";pointer-events:none;position:absolute;width:380px;height:380px;border:1px solid rgba(255,255,255,.07);border-radius:50%;left:-110px;top:-180px;z-index:-1;}
    .vc-offer-hero-copy{position:relative;z-index:1;text-align:right;max-width:660px;}
    .vc-offer-eyebrow{display:inline-flex;gap:9px;align-items:center;padding:8px 12px;border:1px solid rgba(255,255,255,.18);border-radius:50px;color:#ffe8e5;font-size:13px;font-weight:600;background:rgba(255,255,255,.07);}
    .vc-offer-live-dot{width:8px;height:8px;display:inline-block;border-radius:50%;background:#fb5268;box-shadow:0 0 0 4px rgba(246,72,94,.15);}
    .vc-offer-english{font-family:Arial,sans-serif;letter-spacing:3px;color:#f5979f;font-size:12px;font-weight:800;margin:18px 0 8px;text-align:right;}
    .vc-offer-hero h1{font-size:clamp(32px,4.2vw,58px);color:#fff;line-height:1.3;margin:0 0 10px;font-weight:900;letter-spacing:-.6px;}
    .vc-offer-hero-spark{display:inline-block;font-family:Arial,sans-serif;font-size:23px;color:#ff7084;vertical-align:top;padding-right:10px;}
    .vc-offer-hero-description{max-width:520px;color:#f3dfe5;font-size:15px;line-height:2;margin:0 0 24px;}
    .vc-offer-hero-actions{display:flex;gap:17px;align-items:center;flex-wrap:wrap;}
    .vc-offer-primary-link,.vc-offer-primary-link:hover{display:inline-flex;align-items:center;justify-content:center;gap:11px;min-height:47px;border-radius:12px;padding:0 22px;background:#f33755;color:white;box-shadow:0 8px 25px rgba(238,44,73,.3);font-size:14px;font-weight:800;text-decoration:none;transition:transform .18s ease,background .18s ease;}
    .vc-offer-primary-link:hover{background:#d92244;transform:translateY(-2px);}
    .vc-offer-hero-footnote{font-size:12px;color:#e8bfc9;}
    .vc-offer-hero-visual{position:relative;display:flex;align-items:center;justify-content:center;min-height:245px;align-self:center;}
    .vc-offer-hero-orbit{position:absolute;width:85%;aspect-ratio:1;border-radius:50%;background:radial-gradient(circle,rgba(253,71,91,.27),transparent 65%);filter:blur(9px);}
    .vc-offer-hero-visual img{position:relative;display:block;max-width:min(250px,100%);width:100%;height:auto;filter:drop-shadow(0 12px 22px rgba(0,0,0,.28));transform:rotate(-7deg);}
    .vc-offer-art-number{position:absolute;bottom:17%;left:19%;color:#fff;text-shadow:0 2px 5px rgba(0,0,0,.45);font-family:Arial,sans-serif;font-size:clamp(28px,4.2vw,53px);line-height:1;font-weight:900;transform:rotate(-7deg);}
    .vc-offer-benefits{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:12px;margin:19px 0 49px;}
    .vc-offer-benefit{display:flex;gap:12px;align-items:center;border-radius:16px;border:1px solid #f0e4e7;padding:17px 21px;background:#fff;box-shadow:0 5px 17px rgba(31,17,23,.03);}
    .vc-offer-benefit-icon{display:flex;align-items:center;justify-content:center;width:41px;height:41px;flex:0 0 41px;border-radius:13px;background:#fff0f1;color:#dc2545;font-size:21px;font-weight:900;}
    .vc-offer-benefit strong{display:block;font-weight:800;font-size:14px;color:#2e2025;line-height:1.65;}
    .vc-offer-benefit small{display:block;font-size:11px;color:#8f7a81;line-height:1.8;}
    .vc-offer-list-title{scroll-margin-top:90px;display:flex;align-items:end;justify-content:space-between;gap:20px;margin:0 0 23px;padding:0 2px 16px;border-bottom:1px solid #f0e8ea;}
    .vc-offer-list-kicker{display:block;color:#d64058;font-family:Arial,sans-serif;letter-spacing:2px;font-size:10px;font-weight:900;margin-bottom:5px;}
    .vc-offer-list-title h2{font-size:clamp(22px,2.7vw,29px);color:#2d2024;font-weight:850;margin:0 0 6px;line-height:1.5;}
    .vc-offer-list-title p{color:#8b797e;font-size:12px;margin:0;}
    .vc-offer-count-chip{white-space:nowrap;border-radius:30px;padding:9px 15px;background:#fff1f3;color:#c52641;font-size:12px;font-weight:800;}
    .vc-vesta-offer-40 .products{display:grid !important;grid-template-columns:repeat(4,minmax(0,1fr)) !important;gap:19px !important;margin:0 !important;padding:0 !important;}
    .vc-vesta-offer-40 .products>.product-grid-item{position:relative !important;display:block !important;width:auto !important;max-width:100% !important;flex:initial !important;float:none !important;margin:0 !important;padding:0 !important;border:1px solid #f0e8ea;border-radius:17px;background:#fff;box-shadow:0 4px 12px rgba(30,15,24,.035);min-width:0;transition:box-shadow .2s ease,transform .2s ease;overflow:hidden;}
    .vc-vesta-offer-40 .products>.product-grid-item:hover{box-shadow:0 11px 30px rgba(45,20,31,.11);transform:translateY(-3px);}
    .vc-vesta-offer-40 .product-wrapper{padding:11px 11px 18px !important;}
    .vc-vesta-offer-40 .product-element-top{overflow:hidden;border-radius:12px;background:#f8f5f6;}
    .vc-vesta-offer-40 .product-image-link img{border-radius:12px;}
    .vc-vesta-offer-40 .wd-entities-title{min-height:43px;line-height:1.8 !important;margin-top:13px !important;font-weight:700 !important;font-size:13px !important;}
    .vc-vesta-offer-40 .wd-entities-title a{color:#35272d !important;}
    .vc-vesta-offer-40 .wrap-price{margin-top:9px;}
    .vc-vesta-offer-40 .price{font-size:14px !important;font-weight:800 !important;color:#c52946 !important;}
    .vc-vesta-offer-40 .price del{font-size:11px !important;font-weight:500 !important;color:#a79da0 !important;}
    .vc-vesta-offer-40 .wd-add-btn .button{border-radius:9px !important;}
    .vc-offer-pagination{display:flex;justify-content:center;gap:9px;flex-wrap:wrap;margin:41px auto 0;}
    .vc-offer-pagination a{display:inline-flex;min-width:42px;min-height:42px;align-items:center;justify-content:center;border:1px solid #eddee2;background:#fff;color:#37272d;border-radius:11px;padding:0 13px;text-decoration:none;font-size:14px;font-weight:700;}
    .vc-offer-pagination a:hover,.vc-offer-pagination .current{background:#d52e4c;color:#fff;border-color:#d52e4c;}
    .vc-offer-empty{border-radius:15px;background:#fff;text-align:center;padding:48px 15px;color:#74666c;}
    @media(max-width:1024px){.vc-vesta-offer-40 .products{grid-template-columns:repeat(3,minmax(0,1fr)) !important;}.vc-offer-hero{padding:39px;}}
    @media(max-width:767px){
      .vc-vesta-offer-40{margin:12px auto 48px;padding:0 10px;}
      .vc-offer-hero{grid-template-columns:minmax(0,1fr);gap:4px;min-height:0;padding:31px 23px 16px;border-radius:23px;}
      .vc-offer-hero:before{inset:10px;border-radius:16px;}
      .vc-offer-hero h1{font-size:34px;}
      .vc-offer-english{font-size:10px;letter-spacing:2px;}
      .vc-offer-hero-description{font-size:13px;line-height:1.95;}
      .vc-offer-hero-actions{gap:13px;}
      .vc-offer-primary-link{min-height:43px;padding:0 16px;}
      .vc-offer-hero-visual{min-height:125px;max-height:155px;margin:0 auto;max-width:170px;overflow:visible;}
      .vc-offer-hero-visual img{max-width:165px;}
      .vc-offer-art-number{font-size:32px;}
      .vc-offer-benefits{grid-template-columns:repeat(2,minmax(0,1fr));gap:9px;margin:12px 0 33px;}
      .vc-offer-benefit{padding:11px 9px;gap:8px;border-radius:12px;}
      .vc-offer-benefit:last-child{grid-column:1/-1;}
      .vc-offer-benefit-icon{width:31px;height:31px;flex-basis:31px;font-size:17px;border-radius:9px;}
      .vc-offer-benefit strong{font-size:11px;}
      .vc-offer-benefit small{font-size:10px;}
      .vc-offer-list-title{align-items:center;margin-bottom:15px;}
      .vc-offer-list-title h2{font-size:21px;}
      .vc-offer-list-title p{font-size:10px;}
      .vc-offer-count-chip{font-size:10px;padding:8px 10px;}
      .vc-vesta-offer-40 .products{grid-template-columns:repeat(2,minmax(0,1fr)) !important;gap:10px !important;}
      .vc-vesta-offer-40 .product-wrapper{padding:6px 6px 13px !important;}
      .vc-vesta-offer-40 .products>.product-grid-item{border-radius:12px;}
      .vc-vesta-offer-40 .wd-entities-title{font-size:11px !important;margin-top:9px !important;min-height:44px;}
      .vc-vesta-offer-40 .price{font-size:12px !important;}
      .vc-vesta-offer-40 .price del{font-size:10px !important;}
      .vc-offer-pagination{margin-top:26px;}
    }
    @media(prefers-reduced-motion:reduce){.vc-vesta-offer-40 .products>.product-grid-item,.vc-offer-primary-link{transition:none;}}
    <?php
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


/**
 * Homepage's five image banners (not product carousels) rotate less frequently.
 * Woodmart reads data-speed as the autoplay interval in milliseconds. Keep a
 * tiny DOM-ready fallback for uncached pages where rocket_buffer is skipped.
 */
add_filter('rocket_buffer', function ($html) {
    if (!is_front_page() || !is_string($html) || strpos($html, 'banners-carousel-wrapper') === false) {
        return $html;
    }
    return preg_replace_callback('~<div\b[^>]*\bbanners-carousel-wrapper\b[^>]*>~i', function ($match) {
        $tag = $match[0];
        if (strpos($tag, 'data-autoplay="yes"') === false) {
            return $tag;
        }
        if (preg_match('~\bdata-speed="[^"]*"~', $tag)) {
            return preg_replace('~\bdata-speed="[^"]*"~', 'data-speed="7000"', $tag, 1);
        }
        return substr($tag, 0, -1) . ' data-speed="7000">';
    }, $html, 1);
}, 1010);

add_action('wp_head', function () {
    if (!is_front_page() || is_admin()) {
        return;
    }
    ?>
    <script id="vc-vesta-banner-timing">
    document.addEventListener('DOMContentLoaded', function () {
      var banner = document.querySelector('.banners-carousel-wrapper[data-autoplay="yes"]');
      if (!banner) return;
      banner.setAttribute('data-speed', '7000');
      if (!window.jQuery) return;
      var $carousel = window.jQuery(banner).find('.owl-carousel').first();
      var owl = $carousel.data('owl.carousel');
      if (owl) {
        owl.options.autoplayTimeout = 7000;
        owl.settings.autoplayTimeout = 7000;
        $carousel.trigger('stop.owl.autoplay');
        $carousel.trigger('play.owl.autoplay', [7000]);
      }
    });
    </script>
    <?php
}, 2);
