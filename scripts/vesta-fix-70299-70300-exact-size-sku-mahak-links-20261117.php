<?php
/**
 * Exact two-variation Woo SKU / Mahak ProductId+DetailId correction.
 * Site large Woo 70299 -> SKU 70300 -> ERP good 10755489, detail 12269302.
 * Site small Woo 70300 -> SKU 70299 -> ERP good 10755490, detail 12269303.
 * No other products, prices, stock, photos, invoices, customers or orders changed.
 * Dry run unless explicitly backed up in controlled runner.
 */
error_reporting(E_ERROR|E_PARSE);
ini_set('display_errors','0');
$_SERVER['HTTP_HOST']='vesta-cosmetics.ir';
$_SERVER['SERVER_NAME']='vesta-cosmetics.ir';
$_SERVER['HTTPS']='on';
$_SERVER['SERVER_PORT']='443';
$_SERVER['REQUEST_URI']='/';
require '/var/www/html/wp-load.php';
global $wpdb;
$plan=[
 70299=>['sku'=>'70300','product'=>10755489,'detail'=>12269302,'size'=>'سایز بزرگ'],
 70300=>['sku'=>'70299','product'=>10755490,'detail'=>12269303,'size'=>'سایز کوچک'],
];
$commit=getenv('VC_SIZE_SWAP_COMMIT')==='yes';
if($commit && getenv('VC_SIZE_SWAP_BACKUP_VERIFIED')!=='yes'){echo "BACKUP_NOT_VERIFIED_NO_WRITES=yes\n";exit(10);}
$meta=$wpdb->postmeta;$posts=$wpdb->posts;$lookup=$wpdb->prefix.'wc_product_meta_lookup';
function check_swap_preflight($wpdb,$plan,$meta,$posts,$lookup){
  $ids=array_keys($plan);
  $rows=$wpdb->get_results("SELECT p.ID,p.post_type,p.post_status,p.post_parent,m.meta_id,m.meta_value sku
    FROM $posts p JOIN $meta m ON m.post_id=p.ID AND m.meta_key='_sku'
    WHERE p.ID IN (70299,70300)",ARRAY_A);
  if(count($rows)!==2)throw new RuntimeException('sku_postmeta_row_count');
  $byId=[];
  foreach($rows as $r)$byId[(int)$r['ID']]=$r;
  $skuAll=$wpdb->get_results("SELECT post_id,meta_value FROM $meta WHERE meta_key='_sku' AND meta_value IN ('70299','70300')",ARRAY_A);
  if(count($skuAll)!==2)throw new RuntimeException('sku_used_elsewhere');
  $look=$wpdb->get_results("SELECT product_id,sku FROM $lookup WHERE product_id IN (70299,70300)",ARRAY_A);
  if(count($look)!==2)throw new RuntimeException('sku_lookup_missing');
  $lookupBy=[];
  foreach($look as $r)$lookupBy[(int)$r['product_id']]=(string)$r['sku'];
  $goodRows=$wpdb->get_results("SELECT ProductId,ProductCode,ProductName FROM {$wpdb->prefix}bazara_products WHERE ProductId IN (10755489,10755490) AND Deleted=0",ARRAY_A);
  if(count($goodRows)!==2)throw new RuntimeException('erp_goods_missing');
  $goods=[];foreach($goodRows as $good)$goods[(int)$good['ProductId']]=$good;
  $detRows=$wpdb->get_results("SELECT ProductId,ProductDetailId,Properties FROM {$wpdb->prefix}bazara_product_details WHERE ProductId IN (10755489,10755490) AND Deleted=0",ARRAY_A);
  if(count($detRows)!==2)throw new RuntimeException('erp_detail_count_not_unique');
  $details=[];foreach($detRows as $d)$details[(int)$d['ProductId']][]=$d;
  $currentMap=$wpdb->get_results("SELECT post_id,meta_key,meta_value FROM $meta WHERE
    (meta_key='mahak_id' AND meta_value IN ('10755489','10755490')) OR
    (meta_key='mahak_product_detail_id' AND meta_value IN ('12269302','12269303'))",ARRAY_A);
  if($currentMap)throw new RuntimeException('erp_ids_already_assigned');
  $before=[];
  foreach($plan as $id=>$expect){
    $r=$byId[$id]??null;
    if(!$r||$r['post_type']!=='product_variation'||$r['post_status']!=='publish'||
       (int)$r['post_parent']!==70298||$r['sku']!==(string)$id ||
       ($lookupBy[$id]??'')!==(string)$id)throw new RuntimeException('woo_exact_identity_changed');
    if(metadata_exists('post',$id,'mahak_id')||metadata_exists('post',$id,'mahak_product_detail_id'))
      throw new RuntimeException('woo_mapping_already_set');
    $product=wc_get_product($id);
    if(!$product || strpos((string)$product->get_name(),$expect['size'])===false ||
      $product->get_sku()!==(string)$id)throw new RuntimeException('woo_size_identity_changed');
    $good=$goods[$expect['product']]??null;
    $erpName=$good?strtr((string)$good['ProductName'],['ي'=>'ی','ك'=>'ک','‌'=>' ']):'';
    if(!$good || (string)$good['ProductCode']!==$expect['sku'] ||
        strpos($erpName,$expect['size'])===false)
      throw new RuntimeException('erp_good_size_or_code_changed');
    if(count($details[$expect['product']]??[])!==1||
       (int)$details[$expect['product']][0]['ProductDetailId']!==$expect['detail'])
      throw new RuntimeException('erp_detail_unique_identity_changed');
    $prop=(string)($details[$expect['product']][0]['Properties']??'');
    if(!in_array(trim($prop),['','null','[]'],true))
      throw new RuntimeException('erp_unexpected_attributes');
    $before[$id]=[
      'name'=>$product->get_name(),
      'price'=>$product->get_price(),
      'regular_price'=>$product->get_regular_price(),
      'sale_price'=>$product->get_sale_price(),
      'stock_quantity'=>$product->get_stock_quantity(),
      'stock_status'=>$product->get_stock_status(),
      'image_id'=>$product->get_image_id(),
      'gallery'=>$product->get_gallery_image_ids(),
      'attributes'=>$product->get_variation_attributes(),
      'sku'=>$product->get_sku(),
    ];
  }
  return $before;
}
$lockName='vesta_exact_70299_70300_size_code_fix';
$held=false;
try {
  if($commit){
    if((int)$wpdb->get_var($wpdb->prepare('SELECT GET_LOCK(%s,8)',$lockName))!==1)
      throw new RuntimeException('mapping_lock_busy');
    $held=true;
  }
  $before=check_swap_preflight($wpdb,$plan,$meta,$posts,$lookup);
  echo 'EXACT_TWO_SIZES_PREFLIGHT='.json_encode([
    'large_site_variant_70299'=>['new_sku'=>'70300','erp_product'=>10755489,'erp_detail'=>12269302],
    'small_site_variant_70300'=>['new_sku'=>'70299','erp_product'=>10755490,'erp_detail'=>12269303],
    'price_stock_featured_gallery_preserved'=>true
  ],JSON_UNESCAPED_UNICODE).PHP_EOL;
  if(!$commit){echo "EXACT_TWO_SIZES_DRYRUN_NO_WRITES=yes\n";exit(0);}
  $wpdb->query('START TRANSACTION');
  try {
    // Atomic swap avoids intermediate duplicate WooCommerce SKUs and 
    // deliberately bypasses hooks that could launch unintended ERP sync.
    $a=$wpdb->query("UPDATE $meta SET meta_value=CASE post_id
       WHEN 70299 THEN '70300' WHEN 70300 THEN '70299' END
       WHERE meta_key='_sku' AND post_id IN (70299,70300)");
    if($a!==2)throw new RuntimeException('postmeta_sku_swap_failed');
    $b=$wpdb->query("UPDATE $lookup SET sku=CASE product_id
       WHEN 70299 THEN '70300' WHEN 70300 THEN '70299' END
       WHERE product_id IN (70299,70300)");
    if($b!==2)throw new RuntimeException('lookup_sku_swap_failed');
    $insert=$wpdb->query("INSERT INTO $meta(post_id,meta_key,meta_value) VALUES
      (70299,'mahak_id','10755489'),
      (70299,'mahak_product_detail_id','12269302'),
      (70300,'mahak_id','10755490'),
      (70300,'mahak_product_detail_id','12269303')");
    if($insert!==4)throw new RuntimeException('erp_metadata_insert_failed');
    $written=$wpdb->get_results("SELECT post_id,meta_key,meta_value FROM $meta
      WHERE post_id IN (70299,70300) AND meta_key IN ('mahak_id','mahak_product_detail_id','_sku')",ARRAY_A);
    if(count($written)!==6)throw new RuntimeException('transaction_readback_count');
    foreach($plan as $id=>$expect){
      $m=[];foreach($written as $r)if((int)$r['post_id']===$id)$m[$r['meta_key']]=(string)$r['meta_value'];
      if(($m['_sku']??'')!==$expect['sku'] ||
        ($m['mahak_id']??'')!==(string)$expect['product'] ||
        ($m['mahak_product_detail_id']??'')!==(string)$expect['detail'])
        throw new RuntimeException('transaction_id_mismatch');
    }
    $wpdb->query('COMMIT');
  }catch(Throwable $e){$wpdb->query('ROLLBACK');throw $e;}
  // WC product getters use metadata caches; invalidate only these two.
  foreach(array_keys($plan) as $id){
    wp_cache_delete($id,'post_meta');wp_cache_delete($id,'posts');
    clean_post_cache($id);
    wc_delete_product_transients($id);
  }
  $after=[];
  foreach($plan as $id=>$expect){
    $p=wc_get_product($id);
    if(!$p)throw new RuntimeException('product_missing_after_commit');
    $after[$id]=[
      'name'=>$p->get_name(),'price'=>$p->get_price(),
      'regular_price'=>$p->get_regular_price(),'sale_price'=>$p->get_sale_price(),
      'stock_quantity'=>$p->get_stock_quantity(),'stock_status'=>$p->get_stock_status(),
      'image_id'=>$p->get_image_id(),'gallery'=>$p->get_gallery_image_ids(),
      'attributes'=>$p->get_variation_attributes(),'sku'=>$p->get_sku()
    ];
    $saved=$before[$id];$saved['sku']=$expect['sku'];
    if($after[$id]!==$saved ||
      (int)get_post_meta($id,'mahak_id',true)!==$expect['product']||
      (int)get_post_meta($id,'mahak_product_detail_id',true)!==$expect['detail'])
      throw new RuntimeException('wc_readback_does_not_match_preflight');
  }
  echo 'EXACT_SIZE_SKU_AND_MAHAK_MAPPING_READBACK_VERIFIED=yes'.PHP_EOL;
  echo 'ALL_WOO_PRICES_STOCK_NAMES_ATTRIBUTES_AND_IMAGES_UNCHANGED=yes'.PHP_EOL;
  echo 'NO_FINANCIAL_DOCUMENTS_OR_CUSTOMERS_MODIFIED=yes'.PHP_EOL;
}catch(Throwable $e){
  echo 'EXACT_TWO_SIZE_SWAP_FAILED_CLASS='.get_class($e).' CODE='.preg_replace('/[^a-z0-9_]/i','',$e->getMessage()).PHP_EOL;
  exit(30);
}finally{
  if($held)$wpdb->get_var($wpdb->prepare('SELECT RELEASE_LOCK(%s)',$lockName));
}
