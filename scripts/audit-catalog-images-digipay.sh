#!/usr/bin/env bash
# Read-only diagnostic. No customer PII or payment credentials.
set -euo pipefail
BASE=/srv/vestacutella
set -a; source "$BASE/.env"; set +a
echo "=== imported attachment metadata ==="
docker exec vc-vesta php -d memory_limit=512M -r '
require "/var/www/html/wp-load.php";
global $wpdb;
$rows=$wpdb->get_results("SELECT p.ID, pm.meta_value AS source_id
 FROM {$wpdb->posts} p JOIN {$wpdb->postmeta} pm ON pm.post_id=p.ID
 WHERE pm.meta_key=\"_vc_cutella_source_product_id\" AND p.post_type=\"product\" AND p.post_status=\"publish\" ORDER BY p.ID ASC LIMIT 8");
foreach ($rows as $row) {
  $product=wc_get_product($row->ID);
  $aid=$product->get_image_id();
  $path=$aid?get_attached_file($aid):"";
  $url=$aid?wp_get_attachment_url($aid):"";
  $thumb=$aid?wp_get_attachment_image_url($aid,"woocommerce_thumbnail"):"";
  echo "SAMPLE product=".$row->ID." src=".$row->source_id." attachment=".$aid.
    " file_present=".(is_file($path)?"yes":"no").
    " image_url=".$url." thumbnail_url=".$thumb.PHP_EOL;
}
echo "uploads_baseurl=".wp_get_upload_dir()["baseurl"].PHP_EOL;
echo "theme=".get_stylesheet().PHP_EOL;
' 2>&1 | tail -36
echo "=== installed image paths and http, no PII ==="
f="$(find "$BASE/runtime/vesta/wp-content/uploads/cutella-import/" -type f \( -iname '*.jpg' -o -iname '*.png' -o -iname '*.webp' \) -print -quit)"
if [[ -n "$f" ]]; then
  p="${f#"$BASE/runtime/vesta"}"
  echo "IMAGE_SAMPLE_LOCAL bytes=$(stat -c %s "$f")"
  for h in 'https://vesta-cosmetics.ir' 'https://www.vesta-cosmetics.ir'; do
    curl -kLsS --max-time 30 -o /dev/null -w "HTTP %{http_code} %{content_type}\n" "$h$p" || true
  done
fi
echo "=== imported category details (limited) ==="
docker exec vc-vesta php -r '
require "/var/www/html/wp-load.php";
$root=get_term_by("slug","cutella-products","product_cat");
echo "root_term=".(int)($root?$root->term_id:0).PHP_EOL;
if ($root) {
  $cats=get_terms(array("taxonomy"=>"product_cat","hide_empty"=>false,"parent"=>$root->term_id));
  echo "direct_children=".count($cats).PHP_EOL;
  foreach (array_slice($cats,0,35) as $cat) echo "CHILD ".(int)$cat->term_id." ".(int)$cat->count." ".$cat->name.PHP_EOL;
}
$locations=get_nav_menu_locations();
foreach($locations as $slot=>$menuid) {
  $found=0;
  foreach((array)wp_get_nav_menu_items((int)$menuid) as $i)
    if (stripos($i->title,"کیوتلا")!==false || ($i->object==="product_cat" && $root && (int)$i->object_id===(int)$root->term_id)) $found++;
  echo "MENU_LOCATION ".$slot." item_count=".$found.PHP_EOL;
}
' 2>&1 | tail -65
echo "=== DigiPay source references (no customer/order details) ==="
for d in "$BASE/runtime/vesta/wp-content/plugins/"*digipay*; do
  [[ -d "$d" ]] || continue
  echo "DIGIPAY_PLUGIN $(basename "$d")"
  find "$d" -type f -name '*.php' -print | sed "s#$d/##" | head -45
  echo "CODE_REFERENCE_LINES"
  grep -RinE --include='*.php' 'billing_phone|customer.*mobile|mobile.*customer|mobileNumber|mobile_number|cellNumber|buyer.*phone|phone.*buyer|invalid.*mobile|شماره تماس خریدار|شماره تلفن|phoneNumber|buyerPhone' "$d" 2>/dev/null \
    | sed -E "s#^$d/##" | grep -Ev 'config|secret|token|password|merchant|apiKey|apikey' | head -70 || true
done
echo "=== WC checkout billing field requirements (no PII) ==="
docker exec vc-vesta php -r '
require "/var/www/html/wp-load.php";
$f=WC()->checkout()->get_checkout_fields("billing");
foreach(array("billing_phone","billing_country","billing_email") as $key) {
 $field=isset($f[$key])?$f[$key]:array();
 echo $key." type=".($field["type"]??"unset")." required=".(empty($field["required"])?"no":"yes").PHP_EOL;
}
foreach(WC()->payment_gateways()->payment_gateways() as $id=>$g) if(stripos($id,"digipay")!==false) echo "GATEWAY id=".$id." class=".get_class($g)." enabled=".$g->enabled.PHP_EOL;
' 2>&1 | tail -25
echo "CATALOG_CHECKOUT_AUDIT_OK"
