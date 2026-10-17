<?php
/**
 * Plugin Name: Vesta Reliable Order Print
 * Description: Independent, authenticated WooCommerce address labels and order summaries; no remote licence check.
 * Version: 1.0.0
 * Requires PHP: 7.4
 */
defined('ABSPATH') || exit;

/**
 * Print links use their own authenticated admin-post action and WordPress nonce.
 * The licensed third-party invoice plugin is deliberately not modified or bypassed.
 */
function vc_vesta_print_url($ids, $mode = 'address') {
    $mode = $mode === 'summary' ? 'summary' : 'address';
    $ids = array_slice(array_values(array_unique(array_filter(array_map('absint', (array) $ids)))), 0, 100);
    return add_query_arg(array(
        'action' => 'vc_vesta_print_orders',
        'order_ids' => implode(',', $ids),
        'mode' => $mode,
        '_wpnonce' => wp_create_nonce('vc_vesta_print_' . $mode),
    ), admin_url('admin-post.php'));
}

function vc_vesta_print_bulk_choices($actions) {
    $actions['vc_vesta_print_address'] = 'چاپ آدرس سفارش‌ها (مستقل)';
    $actions['vc_vesta_print_summary'] = 'چاپ خلاصه سفارش‌ها (مستقل)';
    return $actions;
}
add_filter('bulk_actions-edit-shop_order', 'vc_vesta_print_bulk_choices');
add_filter('bulk_actions-woocommerce_page_wc-orders', 'vc_vesta_print_bulk_choices');

function vc_vesta_print_bulk_handler($redirect_url, $action, $order_ids) {
    if ($action !== 'vc_vesta_print_address' && $action !== 'vc_vesta_print_summary') {
        return $redirect_url;
    }
    if (!current_user_can('edit_shop_orders') && !current_user_can('manage_woocommerce')) {
        return $redirect_url;
    }
    $ids = array_slice(array_values(array_unique(array_filter(array_map('absint', (array) $order_ids)))), 0, 100);
    if (!$ids) {
        return $redirect_url;
    }
    return vc_vesta_print_url($ids, $action === 'vc_vesta_print_summary' ? 'summary' : 'address');
}
add_filter('handle_bulk_actions-edit-shop_order', 'vc_vesta_print_bulk_handler', 10, 3);
add_filter('handle_bulk_actions-woocommerce_page_wc-orders', 'vc_vesta_print_bulk_handler', 10, 3);

function vc_vesta_print_order_actions($actions, $order) {
    if ($order instanceof WC_Order &&
        (current_user_can('edit_shop_orders') || current_user_can('manage_woocommerce'))) {
        $actions['vc_vesta_print_address'] = array(
            'url' => vc_vesta_print_url(array($order->get_id())),
            'name' => 'چاپ آدرس (مستقل)',
            'action' => 'vc_vesta_print_address',
        );
    }
    return $actions;
}
add_filter('woocommerce_admin_order_actions', 'vc_vesta_print_order_actions', 20, 2);

function vc_vesta_print_order_detail_links($order) {
    if (!($order instanceof WC_Order) ||
        (!current_user_can('edit_shop_orders') && !current_user_can('manage_woocommerce'))) {
        return;
    }
    echo '<div style="clear:both; margin:14px 0; padding:12px; background:#f5f7fa; border:1px solid #ccd0d4; border-radius:6px" dir="rtl">';
    echo '<strong>چاپ پایدار سفارش:</strong> ';
    echo '<a class="button button-primary" target="_blank" rel="noopener noreferrer" href="' . esc_url(vc_vesta_print_url(array($order->get_id()))) . '">چاپ آدرس</a> ';
    echo '<a class="button" target="_blank" rel="noopener noreferrer" href="' . esc_url(vc_vesta_print_url(array($order->get_id()), 'summary')) . '">چاپ خلاصه سفارش</a>';
    echo '</div>';
}
add_action('woocommerce_admin_order_data_after_order_details', 'vc_vesta_print_order_detail_links', 20);

function vc_vesta_print_legacy_row_actions($actions, $post) {
    if (isset($post->post_type) && $post->post_type === 'shop_order' &&
        (current_user_can('edit_shop_orders') || current_user_can('manage_woocommerce'))) {
        $actions['vc_vesta_print_address'] = '<a target="_blank" rel="noopener noreferrer" href="' .
            esc_url(vc_vesta_print_url(array($post->ID))) . '">چاپ آدرس (مستقل)</a>';
    }
    return $actions;
}
add_filter('post_row_actions', 'vc_vesta_print_legacy_row_actions', 20, 2);

function vc_vesta_print_address_html($order) {
    $formatted = $order->get_formatted_shipping_address();
    if (!trim(wp_strip_all_tags($formatted))) {
        $formatted = $order->get_formatted_billing_address();
    }
    if (!trim(wp_strip_all_tags($formatted))) {
        $formatted = esc_html(trim($order->get_billing_first_name() . ' ' . $order->get_billing_last_name()));
    }
    return wp_kses_post($formatted);
}

function vc_vesta_print_phone($order) {
    $phone = method_exists($order, 'get_shipping_phone') ? $order->get_shipping_phone() : '';
    return $phone ? $phone : $order->get_billing_phone();
}

function vc_vesta_print_orders() {
    if (!current_user_can('edit_shop_orders') && !current_user_can('manage_woocommerce')) {
        wp_die('اجازه چاپ سفارش‌ها را ندارید.', '', array('response' => 403));
    }
    $mode = isset($_GET['mode']) && sanitize_key(wp_unslash($_GET['mode'])) === 'summary'
        ? 'summary' : 'address';
    check_admin_referer('vc_vesta_print_' . $mode);
    if (!function_exists('wc_get_order')) {
        wp_die('ووکامرس در دسترس نیست.', '', array('response' => 503));
    }
    $raw = isset($_GET['order_ids']) && is_string($_GET['order_ids'])
        ? wp_unslash($_GET['order_ids']) : '';
    // The handler never accepts arrays, unbounded ranges, or arbitrary query fragments.
    if (!preg_match('/^\\d+(,\\d+)*$/D', $raw)) {
        wp_die('شناسه سفارش نامعتبر است.', '', array('response' => 400));
    }
    $ids = array_values(array_unique(array_filter(array_map('absint', explode(',', $raw)))));
    if (!$ids || count($ids) > 100) {
        wp_die('بین ۱ تا ۱۰۰ سفارش را انتخاب کنید.', '', array('response' => 400));
    }
    $orders = array();
    foreach ($ids as $id) {
        $order = wc_get_order($id);
        if ($order instanceof WC_Order) {
            $orders[] = $order;
        }
    }
    if (!$orders) {
        wp_die('سفارشی برای چاپ پیدا نشد.', '', array('response' => 404));
    }
    nocache_headers();
    header('X-Robots-Tag: noindex, nofollow, noarchive', true);
    header('Content-Type: text/html; charset=utf-8');
    $site = get_bloginfo('name');
    $shop_address = array_filter(array(
        get_option('woocommerce_store_address', ''),
        get_option('woocommerce_store_address_2', ''),
        get_option('woocommerce_store_city', ''),
        get_option('woocommerce_store_postcode', ''),
    ));
    ?>
<!doctype html>
<html lang="fa" dir="rtl">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title><?php echo esc_html($mode === 'summary' ? 'خلاصه سفارش‌ها' : 'آدرس سفارش‌ها'); ?></title>
<style>
* { box-sizing: border-box; }
body { margin: 0; background: #edf0f3; color: #17212d; font: 14px/1.75 Tahoma, Arial, sans-serif; }
.toolbar { position: sticky; top: 0; z-index: 10; padding: 12px 22px; background: #182536; color: #fff; display: flex; gap: 12px; align-items: center; flex-wrap: wrap; }
.toolbar button, .toolbar a { font: inherit; border: 0; border-radius: 6px; padding: 6px 16px; background: #fff; color: #17212d; text-decoration: none; cursor: pointer; }
.toolbar .count { opacity: .8; }
article { background: white; margin: 18px auto; border: 1px solid #cbd2db; box-shadow: 0 6px 20px rgba(0,0,0,.06); overflow-wrap: anywhere; }
article.address { width: 105mm; min-height: 148mm; padding: 9mm; }
article.summary { width: 210mm; min-height: 260mm; padding: 16mm; }
.brand { font-size: 19px; font-weight: bold; border-bottom: 2px solid #202d3b; padding-bottom: 8px; margin-bottom: 18px; }
.order-number { font-size: 16px; font-weight: bold; }
.heading { font-weight: bold; margin-top: 16px; }
.destination { margin: 12px 0; font-size: 16px; line-height: 2; }
.phone { border-top: 1px solid #ddd; padding-top: 12px; font-size: 15px; }
.muted { color: #606975; font-size: 12px; }
table { border-collapse: collapse; width: 100%; margin: 20px 0; text-align: right; }
th, td { border-bottom: 1px solid #dce1e7; padding: 8px; }
th { background: #f2f4f7; }
.total-row { font-weight: bold; }
@page { size: A6 portrait; margin: 0; }
@media print {
  html, body { background: white; margin: 0; }
  .toolbar { display: none !important; }
  article { border: none; box-shadow: none; margin: 0; break-after: page; page-break-after: always; }
  article:last-of-type { break-after: auto; page-break-after: auto; }
  article.address { width: 105mm; height: 148mm; min-height: 0; padding: 8mm; }
  article.summary { width: 100%; height: auto; min-height: 0; padding: 14mm; }
  body.summary-print { print-color-adjust: exact; }
}
<?php if ($mode === 'summary') : ?>@page { size: A4 portrait; margin: 0; }<?php endif; ?>
</style>
</head>
<body class="<?php echo esc_attr($mode === 'summary' ? 'summary-print' : 'address-print'); ?>">
<nav class="toolbar">
  <button onclick="window.print()">چاپ / ذخیره PDF</button>
  <span class="count"><?php echo esc_html(count($orders)); ?> سفارش آماده چاپ</span>
  <a href="<?php echo esc_url(admin_url('edit.php?post_type=shop_order')); ?>">بازگشت به سفارش‌ها</a>
</nav>
<?php foreach ($orders as $order) : ?>
<article class="<?php echo esc_attr($mode); ?>">
  <div class="brand"><?php echo esc_html($site); ?></div>
  <div class="order-number">شماره سفارش: <?php echo esc_html($order->get_order_number()); ?></div>
  <?php if ($mode === 'address') : ?>
    <div class="heading">گیرنده</div>
    <div class="destination"><?php echo vc_vesta_print_address_html($order); ?></div>
    <div class="phone">شماره تماس: <b><?php echo esc_html(vc_vesta_print_phone($order)); ?></b></div>
    <p class="muted">فرستنده: <?php echo esc_html($site); ?></p>
  <?php else : ?>
    <div class="muted">تاریخ ثبت: <?php echo esc_html($order->get_date_created() ? wc_format_datetime($order->get_date_created(), 'Y/m/d H:i') : '—'); ?></div>
    <div class="heading">آدرس تحویل</div>
    <div><?php echo vc_vesta_print_address_html($order); ?></div>
    <div>شماره تماس: <?php echo esc_html(vc_vesta_print_phone($order)); ?></div>
    <table>
      <thead><tr><th>محصول</th><th>تعداد</th><th>مبلغ</th></tr></thead>
      <tbody>
      <?php foreach ($order->get_items('line_item') as $item) : ?>
      <tr>
        <td><?php echo esc_html($item->get_name()); ?></td>
        <td><?php echo esc_html($item->get_quantity()); ?></td>
        <td><?php echo wp_kses_post(wc_price($item->get_total(), array('currency' => $order->get_currency()))); ?></td>
      </tr>
      <?php endforeach; ?>
      </tbody>
    </table>
    <table><tbody>
    <?php foreach ($order->get_order_item_totals() as $row) : ?>
      <tr><td><?php echo esc_html($row['label']); ?></td><td><?php echo wp_kses_post($row['value']); ?></td></tr>
    <?php endforeach; ?>
    </tbody></table>
    <div class="muted">فرستنده: <?php echo esc_html($site); ?>
      <?php echo esc_html(implode('، ', $shop_address)); ?></div>
  <?php endif; ?>
</article>
<?php endforeach; ?>
<script>
window.addEventListener('load', function () { window.print(); });
</script>
</body>
</html>
    <?php
    exit;
}
add_action('admin_post_vc_vesta_print_orders', 'vc_vesta_print_orders');
