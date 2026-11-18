<?php
/** Correct only Woo 105617 stock using Bazara ProductDetailStoreAssets (not ProductDetail Count1). */
error_reporting(E_ERROR|E_PARSE);ini_set('display_errors','0');
$_SERVER['HTTP_HOST']='vesta-cosmetics.ir';$_SERVER['SERVER_NAME']='vesta-cosmetics.ir';
$_SERVER['HTTPS']='on';$_SERVER['SERVER_PORT']='443';$_SERVER['REQUEST_URI']='/';
require '/var/www/html/wp-load.php';global $wpdb;
$commit=getenv('VESTA_105617_STOCK_COMMIT')==='yes';
if($commit&&getenv('VESTA_105617_STOCK_BACKUP')!=='yes')exit(11);
$lock='vesta_stock_105617_authoritative';
if((int)$wpdb->get_var($wpdb->prepare('SELECT GET_LOCK(%s,10)',$lock))!==1)exit(12);
try{
  $p=wc_get_product(105617);$cfg=get_bazara_visitor_settings();
  if(!$p||$p->get_status()!=='draft'||!$p->is_type('simple')||
     $p->get_sku()!=='103201'||(int)$p->get_meta('mahak_id',true)!==10755477||
     (int)$p->get_meta('mahak_product_detail_id',true)!==12269305||
     $p->get_regular_price()!=='2599000'||(int)$p->get_image_id()!==105559||
     $p->get_stock_quantity()!==0||!$p->get_manage_stock()||
     empty($cfg['chkQuantity'])){echo "AUTHORITATIVE_STOCK_TARGET_DRIFT_ABORT=yes\n";exit(13);}
  $asset=$wpdb->get_results($wpdb->prepare(
    "SELECT ProductDetailStoreAssetId,ProductDetailId,StoreId,Count1,Count2,Deleted FROM {$wpdb->prefix}bazara_product_assets
       WHERE ProductDetailId=%d AND Deleted=0",12269305),ARRAY_A);
  if(count($asset)!==1||(int)$asset[0]['StoreId']!==40851 ||
     (float)$asset[0]['Count1']!==24.0 ||
     !function_exists('get_product_asset_quantity') ||
     (float)get_product_asset_quantity(12269305,40851)!==24.0){
    echo "AUTHORITATIVE_STOCK_ASSET_UNVERIFIED_ABORT=yes\n";exit(14);
  }
  echo 'AUTHORITATIVE_BOOK_STOCK_SOURCE=BAZARA_STORE_40851_DETAIL_12269305_QUANTITY_24'.PHP_EOL;
  if(!$commit){echo "AUTHORITATIVE_BOOK_STOCK_DRYRUN_NO_WRITES=yes\n";exit(0);}
  $p->set_stock_quantity(24);
  $p->set_stock_status('instock');
  $p->save();
  $after=wc_get_product(105617);
  if(!$after||$after->get_stock_quantity()!==24||
     $after->get_stock_status()!=='instock'||$after->get_status()!=='draft'||
     $after->get_regular_price()!=='2599000'||(int)$after->get_image_id()!==105559){
    echo "AUTHORITATIVE_BOOK_STOCK_READBACK_FAILED=yes\n";exit(22);
  }
  echo 'AUTHORITATIVE_BOOK_STOCK_105617_CORRECTED=24'.PHP_EOL;
  echo 'AUTHORITATIVE_BOOK_STOCK_PRICE_PHOTO_STATUS_PRESERVED=yes'.PHP_EOL;
}finally{$wpdb->get_var($wpdb->prepare('SELECT RELEASE_LOCK(%s)',$lock));}
