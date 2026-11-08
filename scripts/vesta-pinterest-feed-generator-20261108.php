<?php
/**
 * Vesta -> Pinterest retail catalog CSV generator.
 * CLI ONLY. Read-only WooCommerce. Writes static public CSV atomically.
 * Source currency: IRT (Toman). Catalog currency: IRR (Rial), exact 10x unit
 * conversion; never switch to EUR/USD or change storefront prices.
 */
if (PHP_SAPI !== 'cli') { exit(1); }
error_reporting(E_ERROR | E_PARSE);
set_time_limit(480);
if (!defined('ABSPATH')) { require '/var/www/html/wp-load.php'; }
if (!function_exists('wc_get_product')) { fwrite(STDERR, "FAIL: WooCommerce unavailable\n"); exit(10); }
$currency = get_woocommerce_currency();
if ($currency === 'IRT') { $factor = 10; $export_currency = 'IRR'; }
elseif ($currency === 'IRR') { $factor = 1; $export_currency = 'IRR'; }
else { fwrite(STDERR, "FAIL: unknown currency mapping; cannot assert prices\n"); exit(11); }
$dir = WP_CONTENT_DIR . '/uploads';
if (!is_dir($dir) || !is_writable($dir)) { fwrite(STDERR, "FAIL: uploads not writable\n"); exit(12); }
$final = $dir . '/vesta-pinterest-products.csv';
$tmp = $final . '.tmp-' . getmypid();
$handle = fopen($tmp, 'wb');
if (!$handle) { exit(13); }
$header = array('id','title','description','link','image_link','price','availability','item_group_id','sale_price','product_type','condition');
fputcsv($handle, $header);
$added=0; $skipped=0; $source=0; $variants=0;
function vc_pin_feed_clean($s, $limit=10000) {
    $s = trim(preg_replace('/\s+/u',' ',html_entity_decode(wp_strip_all_tags((string)$s), ENT_QUOTES, 'UTF-8')));
    return function_exists('mb_substr') ? mb_substr($s,0,$limit,'UTF-8') : substr($s,0,$limit);
}
function vc_pin_feed_product($p, $parent_id, $parent, $h, $factor, $export_currency, &$added, &$skipped, &$variants) {
    if (!$p || $p->get_status() !== 'publish' || !$p->is_purchasable()) { $skipped++; return; }
    $current = (float) $p->get_price();
    if ($current <= 0 || !is_finite($current)) { $skipped++; return; }
    $image_id = $p->get_image_id();
    if (!$image_id && $parent) { $image_id = $parent->get_image_id(); }
    $image = $image_id ? wp_get_attachment_url($image_id) : '';
    $link = $p->get_permalink();
    if (!$image || !$link || strpos($image,'https://') !== 0 || strpos($link, 'https://vesta-cosmetics.ir/') !== 0) {
        $skipped++; return;
    }
    $name = vc_pin_feed_clean($p->get_name(),500);
    if ($parent && $p->is_type('variation') && !$name) { $name = vc_pin_feed_clean($parent->get_name(),500); }
    $desc = vc_pin_feed_clean($p->get_short_description() ?: $p->get_description());
    if (!$desc && $parent) { $desc = vc_pin_feed_clean($parent->get_short_description() ?: $parent->get_description()); }
    if (!$desc) { $desc = $name; }
    if (!$name || !$desc) { $skipped++; return; }
    $regular = (float) $p->get_regular_price();
    $sale = '';
    if ($regular > $current && $regular > 0) {
        $price = $regular;
        $sale = number_format($current * $factor, 2, '.', '') . ' ' . $export_currency;
    } else {
        $price = $current;
    }
    if ($p->is_on_backorder(1)) { $availability = 'preorder'; }
    else { $availability = $p->is_in_stock() ? 'in stock' : 'out of stock'; }
    $terms = get_the_terms($parent_id ? $parent_id : $p->get_id(), 'product_cat');
    $cat = ($terms && !is_wp_error($terms)) ? vc_pin_feed_clean($terms[0]->name,1000) : '';
    $row = array(
      'vesta_' . $p->get_id(), $name, $desc, $link, $image,
      number_format($price*$factor, 2,'.','') . ' ' . $export_currency,
      $availability, $parent_id ? 'vesta_' . $parent_id : '',
      $sale, $cat, 'new'
    );
    fputcsv($h, $row);
    $added++;
    if ($parent_id) { $variants++; }
}
for ($page=1;$page<=1000;$page++) {
    $ids=get_posts(array(
       'post_type'=>'product','post_status'=>'publish','fields'=>'ids',
       'posts_per_page'=>100,'paged'=>$page,'orderby'=>'ID','order'=>'ASC',
       'no_found_rows'=>true,'suppress_filters'=>false
    ));
    if (!$ids) { break; }
    foreach($ids as $id) {
        $p=wc_get_product($id);
        if (!$p) { $skipped++; continue; }
        $source++;
        if ($p->is_type('variable')) {
            foreach($p->get_children() as $child_id) {
                $child=wc_get_product($child_id);
                vc_pin_feed_product($child, $id, $p, $handle, $factor,$export_currency,$added,$skipped,$variants);
            }
        } elseif ($p->is_type('simple')) {
            vc_pin_feed_product($p,0,null,$handle,$factor,$export_currency,$added,$skipped,$variants);
        } else { $skipped++; }
    }
}
fflush($handle);
fclose($handle);
if ($added < 1 || filesize($tmp) < 500) {
    @unlink($tmp); fwrite(STDERR,"FAIL: empty or undersized feed\n"); exit(20);
}
@chmod($tmp,0644);
if (!rename($tmp,$final)) { @unlink($tmp); fwrite(STDERR,"FAIL: atomic rename\n"); exit(21); }
echo "PINTEREST_FEED_GENERATED=1\n";
echo "SOURCE_PUBLISHED_PRODUCTS=".$source."\n";
echo "EXPORTED_ROWS=".$added."\n";
echo "EXPORTED_VARIANTS=".$variants."\n";
echo "SKIPPED_PRODUCTS=".$skipped."\n";
echo "STORE_CURRENCY=".$currency."\n";
echo "FEED_CURRENCY=".$export_currency."\n";
echo "FEED_BYTES=".filesize($final)."\n";
echo "FEED_PATH=".$final."\n";
echo "FEED_URL=https://vesta-cosmetics.ir/wp-content/uploads/vesta-pinterest-products.csv\n";
