#!/usr/bin/env bash
# Read-only detailed classification of two WooCommerce taxonomies.
set -euo pipefail
echo "=== VESTA categories with accessory/perfume/cosmetics and imported markers ==="
docker exec vc-vesta php -r '
require "/var/www/html/wp-load.php";
$ts=get_terms(array("taxonomy"=>"product_cat","hide_empty"=>false,"number"=>0));
foreach($ts as $t){
 $flag=get_term_meta($t->term_id,"_vc_cutella_source_category_id",true);
 $anc=get_ancestors($t->term_id,"product_cat");
 $needle=preg_match("/اکسسوری|عطر|خوشبو|لوازم آرایشی|آرایش|خوراکی|کره|فانتزی|دکوری|پوشاک|التحریر|محصولات ویژه/u",$t->name);
 if(!$needle && !$flag)continue;
 echo "VESTA_TERM id=".$t->term_id." parent=".$t->parent." count=".$t->count." src_marker=".$flag." order=".get_term_meta($t->term_id,"order",true)." name=".$t->name." slug=".$t->slug.PHP_EOL;
}
$menus=array_unique(array_filter(array_map("intval",get_nav_menu_locations())));
foreach($menus as $menuid){
 echo "VESTA_MENU id=".$menuid.PHP_EOL;
 foreach((array)wp_get_nav_menu_items($menuid) as $item)
 echo "MENU_ITEM id=".$item->ID." parent=".$item->menu_item_parent." object=".$item->object." object_id=".$item->object_id." title=".$item->title.PHP_EOL;
}
foreach(array("woodmart_header","woodmart_options","woocommerce_default_catalog_orderby") as $k){
 $v=get_option($k,null); echo "OPTION ".$k." type=".gettype($v).(is_array($v)?" count=".count($v):"").PHP_EOL;
}
' 2>&1 | tail -220
echo "=== VESTA current product assignments for requested removals ==="
docker exec vc-vesta php -r '
require "/var/www/html/wp-load.php";
$all=get_terms(array("taxonomy"=>"product_cat","hide_empty"=>false));
foreach($all as $t){
 if(!preg_match("/خوراکی|کره|کیمچی|موچی|چاپستیک|عطر|خوشبو|اکسسوری|لوازم آرایشی|پوشاک/u",$t->name))continue;
 $ids=get_objects_in_term((int)$t->term_id,"product_cat");
 if(is_wp_error($ids))continue;
 $normal=0;$imported=0;$sample=array();
 foreach($ids as $pid){
  if(get_post_type($pid)!=="product")continue;
  if(get_post_status($pid)==="trash")continue;
  $origin=get_post_meta($pid,"_vc_cutella_source_product_id",true);
  if($origin)$imported++;else $normal++;
  if(count($sample)<10)$sample[]=$pid.":".($origin?"imported":"existing").":".get_the_title($pid);
 }
 echo "VESTA_PRODUCTS term=".$t->term_id." name=".$t->name." orig=".$normal." imported=".$imported." sample=".implode(" | ",$sample).PHP_EOL;
}
' 2>&1 | tail -105
echo "=== CUTELLA Korean categories and products ==="
docker exec vc-cutella php -r '
require "/var/www/html/wp-load.php";
$ts=get_terms(array("taxonomy"=>"product_cat","hide_empty"=>false));
foreach($ts as $t){
 if(!preg_match("/خوراکی|کره|موچی|کیمچی|چاپستیک/u",$t->name))continue;
 echo "CUTELLA_TERM id=".$t->term_id." parent=".$t->parent." count=".$t->count." name=".$t->name." slug=".$t->slug.PHP_EOL;
 $ids=get_objects_in_term((int)$t->term_id,"product_cat");
 foreach((array)$ids as $pid){
  if(get_post_type($pid)!=="product")continue;
  $p=wc_get_product($pid);
  echo "CUTELLA_PRODUCT id=".$pid." status=".get_post_status($pid)." stock=".($p?$p->get_stock_status():"n/a")." title=".get_the_title($pid)." categories=".implode(",",wp_get_post_terms($pid,"product_cat",array("fields"=>"ids"))).PHP_EOL;
 }
}
' 2>&1 | tail -95
echo "CATEGORY_REFACTOR_PREFLIGHT_OK"
