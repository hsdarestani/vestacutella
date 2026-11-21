<?php
// Fast read-only catalog snapshot based on the previously verified export loop.
// Never updates options, WooCommerce products/stock, invoices, orders or the Mahak database.
error_reporting(E_ALL);
ini_set('display_errors','stderr');
set_time_limit(240);
$_SERVER['HTTP_HOST']='vesta-cosmetics.ir';
$_SERVER['SERVER_NAME']='vesta-cosmetics.ir';
$_SERVER['HTTPS']='on';$_SERVER['SERVER_PORT']='443';$_SERVER['REQUEST_URI']='/';
require '/var/www/html/wp-load.php';
global $wpdb;
$start=gmdate('c');
$maxBefore=(int)$wpdb->get_var("SELECT COALESCE(MAX(ID),0) FROM {$wpdb->posts} WHERE post_type='shop_order'");
$f=fopen('php://output','w');
fputcsv($f,['woo_id','type','parent_id','sku','name','variation_attributes','status',
  'manage_stock','stock_owner_id','stock_quantity','stock_status','price_toman',
  'regular_price_toman','mahak_product_id_legacy','mahak_detail_id_legacy']);
$ids=$wpdb->get_col("SELECT ID FROM {$wpdb->posts} WHERE post_type IN ('product','product_variation') ORDER BY ID");
$count=0;$null=0;
foreach($ids as $id){
  $p=wc_get_product((int)$id);if(!$p)continue;
  $owner=method_exists($p,'get_stock_managed_by_id')?(int)$p->get_stock_managed_by_id():$p->get_id();
  $qty=$p->get_stock_quantity();if($qty===null)$null++;
  $attrs=[];
  if($p->is_type('variation'))foreach($p->get_variation_attributes() as $k=>$v){
    $tax=substr($k,10);$value=(string)$v;
    if(taxonomy_exists($tax)){$term=get_term_by('slug',$value,$tax);
      if($term&&!is_wp_error($term))$value=$term->name;}
    $attrs[]=$tax.':'.$value;
  }
  fputcsv($f,[$p->get_id(),$p->get_type(),$p->get_parent_id(),$p->get_sku(),
    $p->get_name(),implode(' | ',$attrs),$p->get_status(),
    $p->get_manage_stock()?'yes':'no',$owner,
    $qty===null?'':$qty,$p->get_stock_status(),
    $p->get_price(),$p->get_regular_price(),
    $p->get_meta('mahak_id',true),$p->get_meta('mahak_product_detail_id',true)]);
  $count++;
}
fclose($f);
$maxAfter=(int)$wpdb->get_var("SELECT COALESCE(MAX(ID),0) FROM {$wpdb->posts} WHERE post_type='shop_order'");
fwrite(STDERR,'LIVE_CATALOG_METADATA='.json_encode([
  'timestamp_started_utc'=>$start,'timestamp_finished_utc'=>gmdate('c'),
  'last_order_before'=>$maxBefore,'last_order_after'=>$maxAfter,
  'order_window_unchanged'=>$maxBefore===$maxAfter,'count'=>$count,
  'null_quantity_rows'=>$null,'store_currency'=>get_option('woocommerce_currency'),
  'read_only'=>true],JSON_UNESCAPED_UNICODE).PHP_EOL);
