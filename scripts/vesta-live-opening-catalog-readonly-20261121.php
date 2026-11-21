<?php
// Read-only, on-demand live WooCommerce catalog and stock-owner export for Mahak import.
// No write actions, no changes to Woo inventory, orders, mappings or sync settings.
error_reporting(E_ERROR | E_PARSE);
ini_set('display_errors','0');
set_time_limit(240);
$_SERVER['HTTP_HOST']='vesta-cosmetics.ir';
$_SERVER['SERVER_NAME']='vesta-cosmetics.ir';
$_SERVER['HTTPS']='on'; $_SERVER['SERVER_PORT']='443';
$_SERVER['REQUEST_URI']='/';
require '/var/www/html/wp-load.php';
global $wpdb;
if (!function_exists('wc_get_product')) throw new RuntimeException('woocommerce_unavailable');
$stampStart=gmdate('c');
$orderStart=(int)$wpdb->get_var("SELECT COALESCE(MAX(ID),0) FROM {$wpdb->posts} WHERE post_type='shop_order'");
$headers=['woo_id','type','parent_id','sku','name','variation_attributes','status',
 'manage_stock','stock_owner_id','stock_quantity','stock_status','price_toman',
 'regular_price_toman','sale_price_toman','backorders','purchasable','categories',
 'mahak_product_id_legacy','mahak_detail_id_legacy'];
$out=fopen('php://output','w');fputcsv($out,$headers);
$ids=$wpdb->get_col("SELECT ID FROM {$wpdb->posts} WHERE post_type IN ('product','product_variation') ORDER BY ID");
$n=0;$statuses=[];$types=[];$nullQuantities=0;$sharedStock=0;
foreach($ids as $id) {
  $p=wc_get_product((int)$id);if(!$p)continue;
  $status=(string)$p->get_status();$type=(string)$p->get_type();
  $statuses[$status]=($statuses[$status]??0)+1;$types[$type]=($types[$type]??0)+1;
  $owner=method_exists($p,'get_stock_managed_by_id')?(int)$p->get_stock_managed_by_id():(int)$p->get_id();
  $qty=$p->get_stock_quantity(); if($qty===null)$nullQuantities++;
  if($owner!==(int)$p->get_id())$sharedStock++;
  $attr=[];
  if($p->is_type('variation'))foreach($p->get_variation_attributes() as $k=>$v) {
    $tax=str_replace('attribute_','',(string)$k);$val=(string)$v;
    if(taxonomy_exists($tax)){$term=get_term_by('slug',$val,$tax);if($term&&!is_wp_error($term))$val=(string)$term->name;}
    $attr[]=$tax.':'.$val;
  }
  $catParent=$p->is_type('variation')? (int)$p->get_parent_id() : (int)$p->get_id();
  $cats=wp_get_post_terms($catParent,'product_cat',['fields'=>'names']);
  if(is_wp_error($cats))$cats=[];
  fputcsv($out,[
    (int)$p->get_id(),$type,(int)$p->get_parent_id(),(string)$p->get_sku(),(string)$p->get_name(),
    implode(' | ',$attr),$status,$p->get_manage_stock()?'yes':'no',
    $owner,$qty===null?'':(string)$qty,(string)$p->get_stock_status(),
    (string)$p->get_price(),(string)$p->get_regular_price(),(string)$p->get_sale_price(),
    (string)$p->get_backorders(),$p->is_purchasable()?'yes':'no',
    implode(' | ',$cats),(string)$p->get_meta('mahak_id',true),
    (string)$p->get_meta('mahak_product_detail_id',true)
  ]);
  $n++;
}
fclose($out);
$orderEnd=(int)$wpdb->get_var("SELECT COALESCE(MAX(ID),0) FROM {$wpdb->posts} WHERE post_type='shop_order'");
fwrite(STDERR,"LIVE_CATALOG_METADATA=".json_encode([
  'timestamp_started_utc'=>$stampStart,'timestamp_finished_utc'=>gmdate('c'),
  'last_order_before'=>$orderStart,'last_order_after'=>$orderEnd,
  'consistent_order_window'=>$orderStart===$orderEnd,'total'=>$n,'statuses'=>$statuses,
  'types'=>$types,'null_quantities'=>$nullQuantities,'shared_stock_owner_rows'=>$sharedStock,
  'read_only'=>true
],JSON_UNESCAPED_UNICODE).PHP_EOL);
