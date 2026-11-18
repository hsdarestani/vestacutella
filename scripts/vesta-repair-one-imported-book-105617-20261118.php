<?php
/**
 * Vesta: repair exact Mahak imported book 105617, its price, zero stock,
 * and misplaced Mahak picture 1887347 currently at Woo 103201.
 * Never touches checkout, ERP, orders, prices/stock of unrelated products or
 * featured media. Strict validation; dry run unless commit+verified backup.
 */
error_reporting(E_ERROR|E_PARSE);ini_set('display_errors','0');set_time_limit(0);
$_SERVER['HTTP_HOST']='vesta-cosmetics.ir';$_SERVER['SERVER_NAME']='vesta-cosmetics.ir';
$_SERVER['HTTPS']='on';$_SERVER['SERVER_PORT']='443';$_SERVER['REQUEST_URI']='/';
require '/var/www/html/wp-load.php';global $wpdb;
$commit=getenv('VESTA_BOOK_105617_COMMIT')==='yes';
if($commit&&getenv('VESTA_BOOK_105617_BACKUP_VERIFIED')!=='yes'){echo "BOOK_BACKUP_REQUIRED_ABORT=yes\n";exit(11);}
$lock='vesta_exact_book_105617_1887347';
if((int)$wpdb->get_var($wpdb->prepare('SELECT GET_LOCK(%s,10)',$lock))!==1)exit(12);
try {
  $good=10755477;$detail=12269305;$code='103201';$pic=1887347;$attachment=105559;
  $p=wc_get_product(105617);$other=wc_get_product(103201);
  $post=get_post(105617);$img=get_post($attachment);
  if(!$p||!$p->is_type('simple')||!$post||$post->post_status!=='draft'||!$other||!$img ||
    $img->post_type!=='attachment'||$img->post_mime_type!=='image/jpeg'||
    (int)$img->post_parent!==103201 ||
    (int)get_post_meta($attachment,'mahak_picture_id',true)!==$pic ||
    (int)$p->get_meta('mahak_id',true)!==$good ||
    (int)$p->get_meta('mahak_product_detail_id',true)!==$detail ||
    (string)$p->get_sku()!==$code ||
    (string)$p->get_name()!=='کتاب آرايشي چهار برگ دخترانه' ||
    (int)$p->get_image_id()!==0 || $p->get_gallery_image_ids()!==[] ||
    (int)$other->get_image_id()!==103196 || $other->get_gallery_image_ids()!==[$attachment] ||
    $p->get_regular_price()!=='' || $p->get_stock_quantity()!==null) {
     echo "BOOK_EXACT_STATE_GUARD_ABORT=yes\n";exit(13);
  }
  $settings=get_bazara_visitor_settings();
  if(($settings['selectCurrencySoftware']??'')!=='toman' ||
     ($settings['selectCurrencyPlugin']??'')!=='toman' ||
     (string)($settings['RegularPrice']??'')!=='1' ||
     empty($settings['chkRegularPrice']) ||
     empty($settings['chkQuantity'])){echo "BOOK_CURRENCY_AND_PRICE_POLICY_ABORT=yes\n";exit(14);}
  $catalog=vmb_catalog(vmb_api());$product=null;$sourceDetail=null;
  foreach(($catalog['Products']??[]) as $r)if(empty($r['Deleted']) &&
     (int)($r['ProductId']??0)===$good && (string)($r['ProductCode']??'')===$code){
      if($product!==null)exit(15);$product=$r;
  }
  foreach(($catalog['ProductDetails']??[]) as $r)if(empty($r['Deleted']) &&
     (int)($r['ProductId']??0)===$good){
      if((int)($r['ProductDetailId']??0)===$detail)$sourceDetail=$r;
      else {echo "BOOK_MULTIPLE_CLOUD_DETAILS_ABORT=yes\n";exit(16);}
  }
  if(!$product||!$sourceDetail||((int)($sourceDetail['DefaultSellPriceLevel']??0))!==1||
     (int)($sourceDetail['Price1']??0)!==2599000 ||
     (int)($sourceDetail['Count1']??-1)!==0 ||
     (int)($sourceDetail['Count2']??-1)!==0 ||
     !function_exists('vesta_mhi_photo_rows')){echo "BOOK_CLOUD_SOURCE_GUARD_ABORT=yes\n";exit(17);}
  $photos=vesta_mhi_photo_rows($good);
  if(count($photos)!==1 || (int)$photos[0]['PictureId']!==$pic)exit(18);
  $relations=$wpdb->get_results($wpdb->prepare(
     "SELECT post_id,meta_key,meta_value FROM {$wpdb->postmeta}
      WHERE (meta_key='_thumbnail_id' AND meta_value=%s)
        OR (meta_key='_product_image_gallery' AND meta_value LIKE %s)",
     (string)$attachment,'%'.$wpdb->esc_like((string)$attachment).'%'),ARRAY_A);
  if(count($relations)!==1 || (int)$relations[0]['post_id']!==103201 ||
     $relations[0]['meta_key']!=='_product_image_gallery' ||
     (string)$relations[0]['meta_value']!==(string)$attachment){
     echo "BOOK_PICTURE_SHARED_UNEXPECTED_ABORT=yes\n";exit(19);
  }
  echo 'BOOK_105617_REPAIR_PLAN='.json_encode([
    'woo_id'=>105617,'mahak_good_id'=>$good,'mahak_detail_id'=>$detail,
    'source_price_toman'=>2599000,'source_stock_count1'=>0,'source_stock_count2'=>0,
    'attachment'=>$attachment,'wrong_gallery_owner'=>103201,
    'preserve_wrong_product_main_photo'=>103196,
    'keep_105617_draft'=>true,'never_delete_existing_media'=>true,
    'no_mahak_write'=>true
  ],JSON_UNESCAPED_UNICODE).PHP_EOL;
  if(!$commit){echo "BOOK_105617_DRY_RUN_NO_WRITES=yes\n";exit(0);}
  $wpdb->query('START TRANSACTION');
  try {
    $p->set_regular_price('2599000');
    $p->set_manage_stock(true);
    $p->set_stock_quantity(0);
    $p->set_stock_status('outofstock');
    $p->set_image_id($attachment);
    $p->save();
    $other->set_gallery_image_ids([]);
    $other->save();
    $u=wp_update_post(['ID'=>$attachment,'post_parent'=>105617],true);
    if(is_wp_error($u)||(int)$u!==$attachment)throw new RuntimeException('picture_parent_update_failed');
    $p=wc_get_product(105617);$other=wc_get_product(103201);
    if(!$p||!$other||(string)$p->get_regular_price()!=='2599000' ||
       (int)$p->get_stock_quantity()!==0||!$p->get_manage_stock()||
       (int)$p->get_image_id()!==$attachment||$p->get_status()!=='draft'||
       (int)$other->get_image_id()!==103196||$other->get_gallery_image_ids()!==[]||
       (int)get_post($attachment)->post_parent!==105617)
       throw new RuntimeException('postwrite_readback_mismatch');
    if($wpdb->query('COMMIT')===false)throw new RuntimeException('transaction_commit_failed');
    echo 'BOOK_105617_PRICE_TOMAN_VERIFIED=2599000'.PHP_EOL;
    echo 'BOOK_105617_STOCK_FROM_CLOUD_VERIFIED=0'.PHP_EOL;
    echo 'BOOK_105617_MAIN_PHOTO_VERIFIED=105559'.PHP_EOL;
    echo 'BOOK_WRONG_GALLERY_103201_CORRECTED_PRESERVING_FEATURED=103196'.PHP_EOL;
    echo 'BOOK_105617_REPAIR_DONE_NO_OTHER_PRODUCT_OR_ORDER_CHANGES=yes'.PHP_EOL;
  }catch(Throwable $e){
    $wpdb->query('ROLLBACK');
    echo 'BOOK_REPAIR_ROLLED_BACK='.get_class($e).':'.$e->getMessage().PHP_EOL;
    exit(29);
  }
}finally{
  $wpdb->get_var($wpdb->prepare('SELECT RELEASE_LOCK(%s)',$lock));
}
