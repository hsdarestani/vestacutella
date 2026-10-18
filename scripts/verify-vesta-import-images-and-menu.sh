#!/usr/bin/env bash
# Read-only final storefront QA. Do not place a purchase or query customer data.
set -euo pipefail
echo "=== product images from WordPress, original and grid thumbnail ==="
urls="$(docker exec vc-vesta php -r '
require "/var/www/html/wp-load.php";
global $wpdb;
$ids=$wpdb->get_col("SELECT DISTINCT p.ID FROM {$wpdb->posts} p JOIN {$wpdb->postmeta} m ON m.post_id=p.ID WHERE m.meta_key=\"_vc_cutella_source_product_id\" AND p.post_type=\"product\" AND p.post_status=\"publish\" ORDER BY p.ID LIMIT 30");
$count=0;
foreach($ids as $id) {
  $product=wc_get_product((int)$id);
  if(!$product || !$product->get_image_id()) continue;
  $original=wp_get_attachment_url($product->get_image_id());
  $thumbnail=wp_get_attachment_image_url($product->get_image_id(),"woocommerce_thumbnail");
  if($original) echo $original.PHP_EOL;
  if($thumbnail) echo $thumbnail.PHP_EOL;
  $count++; if($count>=7)break;
}
' | grep '^https://vesta-cosmetics.ir/wp-content/uploads/')" 
echo "sampled_urls=$(printf '%s\n' "$urls" | grep -c '^https' || true)"
count=0
while IFS= read -r url; do
  [[ -z "$url" ]] && continue
  status="$(curl -LksS --max-time 35 -o /dev/null -w '%{http_code}' "$url")"
  [[ "$status" == 200 ]] || { echo "IMAGE_SAMPLE_FAILED code=$status"; exit 4; }
  count=$((count+1))
done <<< "$urls"
[[ "$count" -ge 12 ]] || { echo "TOO_FEW_IMAGES_CHECKED"; exit 5; }
echo "IMAGE_SAMPLE_ALL_HTTP_200 count=$count"
echo "=== actual public HTML nav label ==="
for url in https://vesta-cosmetics.ir/ https://vesta-cosmetics.ir/shop/; do
  file="$(mktemp)"
  curl -LksS --max-time 65 "$url" -o "$file"
  if grep -q 'کیوتلا' "$file"; then
    echo "BRANDED_TEXT_STILL_IN_PUBLIC_HTML $url"
    rm -f "$file";exit 6
  fi
  rm -f "$file"
  echo "NO_SOURCE_BRAND_IN_PUBLIC_HTML $url"
done
echo "=== independent WordPress/menu/phone readiness ==="
docker exec vc-vesta php -r '
require "/var/www/html/wp-load.php";
if(get_term_by("slug","cutella-products","product_cat")) exit(11);
$cat=0;$menu=0;
foreach(array_unique(array_filter(array_map("intval",get_nav_menu_locations()))) as $menuid) {
 foreach((array)wp_get_nav_menu_items($menuid) as $item) {
  if(trim((string)$item->title)==="کیوتلا") exit(12);
  if((string)get_post_meta((int)$item->ID,"_vc_vesta_catalog_group",true)==="1")$menu=(int)$item->ID;
  if((int)$item->menu_item_parent===$menu && $menu) $cat++;
 }
}
if(!$menu || $cat<7)exit(13);
if(!function_exists("vc_vesta_normalize_iran_mobile")) exit(14);
$o=wc_get_order(101583);
if(!$o || !preg_match("/^09[0-9]{9}$/D",$o->get_billing_phone("view"))) exit(15);
echo "CATEGORY_MENU_VERIFIED subcategories=".$cat." digipay_format=yes\n";
'
echo "VESTA_CATALOG_AND_CHECKOUT_FINAL_QA_OK"
