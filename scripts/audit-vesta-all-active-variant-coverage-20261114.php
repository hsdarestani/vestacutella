<?php
// Read-only inventory coverage of all active sellable variation metadata; never creates ERP products.
error_reporting(E_ERROR|E_PARSE);ini_set('display_errors','0');
$_SERVER['HTTP_HOST']='vesta-cosmetics.ir';$_SERVER['SERVER_NAME']='vesta-cosmetics.ir';$_SERVER['HTTPS']='on';$_SERVER['SERVER_PORT']='443';$_SERVER['REQUEST_URI']='/';
require '/var/www/html/wp-load.php';
global $wpdb;
$rows=$wpdb->get_results("SELECT v.ID, v.post_parent, v.post_status,
 EXISTS(SELECT 1 FROM {$wpdb->postmeta} m WHERE m.post_id=v.ID AND m.meta_key='mahak_id' AND CAST(m.meta_value AS UNSIGNED)>0) has_product_id,
 EXISTS(SELECT 1 FROM {$wpdb->postmeta} m WHERE m.post_id=v.ID AND m.meta_key='mahak_product_detail_id' AND CAST(m.meta_value AS UNSIGNED)>0) has_detail_id,
 EXISTS(SELECT 1 FROM {$wpdb->postmeta} m WHERE m.post_id=v.ID AND m.meta_key='_price' AND m.meta_value<>'' ) has_price
 FROM {$wpdb->posts} v JOIN {$wpdb->posts} p ON p.ID=v.post_parent
 WHERE v.post_type='product_variation' AND v.post_status='publish' AND p.post_type='product' AND p.post_status='publish'",ARRAY_A);
$counts=array('published_variations'=>count($rows),'fully_mapped'=>0,'missing_product_id'=>0,'missing_detail_id'=>0,'missing_either'=>0,'with_sale_price'=>0,'sellable_missing_either'=>0);
$missing=array();
foreach($rows as $r){
 if($r['has_price'])$counts['with_sale_price']++;
 $a=(bool)$r['has_product_id'];$b=(bool)$r['has_detail_id'];
 if($a&&$b)$counts['fully_mapped']++;
 else {
  $counts['missing_either']++;
  if(!$a)$counts['missing_product_id']++;
  if(!$b)$counts['missing_detail_id']++;
  if($r['has_price'])$counts['sellable_missing_either']++;
  $missing[]=(int)$r['ID'];
 }
}
foreach($counts as $k=>$v)echo strtoupper($k).'='.$v."\n";
echo 'SAMPLE_UNMAPPED_VARIATION_IDS='.implode(',',array_slice($missing,0,40))."\n";
echo "READ_ONLY_ACTIVE_CATALOG_COVERAGE_COMPLETE=yes\n";
