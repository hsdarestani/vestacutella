#!/usr/bin/env bash
set -euo pipefail
echo "=== top-level product category ordering ==="
docker exec vc-vesta php -r '
require "/var/www/html/wp-load.php";
$t=get_terms(array("taxonomy"=>"product_cat","hide_empty"=>false,"parent"=>0,"number"=>0));
foreach($t as $x){if($x->count>=1 || get_term_meta($x->term_id,"_vc_cutella_source_category_id",true))echo "ROOT id=".$x->term_id." count=".$x->count." order=".get_term_meta($x->term_id,"order",true)." name=".$x->name.PHP_EOL;}
echo "registered_menu_locations:".PHP_EOL;
foreach(get_registered_nav_menus() as $k=>$v)echo "REGISTERED ".$k." ".$v.PHP_EOL;
echo "assigned_menus:".PHP_EOL;
foreach(get_nav_menu_locations() as $k=>$v)echo "ASSIGNED ".$k." ".$v.PHP_EOL;
foreach(get_terms(array("taxonomy"=>"product_cat","hide_empty"=>false)) as $x){
 if(get_term_meta($x->term_id,"_vc_cutella_source_category_id",true))
 echo "IMPORTED_TERM id=".$x->term_id." parent=".$x->parent." count=".$x->count." name=".$x->name.PHP_EOL;
}
' 2>&1 | tail -210
echo "=== source store entertainment categories and destination linkage ==="
docker exec vc-cutella php -r '
require "/var/www/html/wp-load.php";
foreach(get_terms(array("taxonomy"=>"product_cat","hide_empty"=>false)) as $x){
 if(preg_match("/سرگرمی|لوازم.التحریر|کالاهای فانتزی|لوازم آرایشی/u",$x->name))
 echo "SOURCE_TERM ".$x->term_id." parent=".$x->parent." count=".$x->count." name=".$x->name.PHP_EOL;
}
' 2>&1 | tail -30
echo "=== destination imported product/category samples incl cosmetic target ==="
docker exec vc-vesta php -r '
require "/var/www/html/wp-load.php";
global $wpdb;
foreach(array(1769,1774,1767,1772,1777,1783,1784,1731,1053,946,950) as $cid){
 $term=get_term($cid,"product_cat");if(!$term||is_wp_error($term))continue;
 $ids=get_objects_in_term($cid,"product_cat");if(is_wp_error($ids))continue;
 $found=0;
 echo "GROUP ".$cid." ".$term->name." children=".count(get_terms(array("taxonomy"=>"product_cat","hide_empty"=>false,"parent"=>$cid))).PHP_EOL;
 foreach($ids as $pid){
  if(get_post_type($pid)!=="product" || !get_post_meta($pid,"_vc_cutella_source_product_id",true))continue;
  echo "PRODUCT ".$pid." from=".get_post_meta($pid,"_vc_cutella_source_product_id",true)." ".$cid." name=".get_the_title($pid).PHP_EOL;
  if(++$found>=35)break;
 }
}
' 2>&1 | tail -200
echo "DETAILED_CATEGORY_PREFLIGHT_OK"
