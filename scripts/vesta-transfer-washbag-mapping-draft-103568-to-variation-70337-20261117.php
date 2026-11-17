<?php
/**
 * Exact ERP good/detail mapping transfer:
 * - source: imported unpublished, non-purchasable simple product 103568;
 * - target: purchasable published Wash Bag "ست دو عددی کوچک+بزرگ" variation 70337.
 * No ERP invoice / stock / image / price / customer mutation.
 * Only moves exactly two Woo metadata records; protected order outbox handles sends.
 */
error_reporting(E_ERROR|E_PARSE);ini_set('display_errors','0');
$_SERVER['HTTP_HOST']='vesta-cosmetics.ir';$_SERVER['SERVER_NAME']='vesta-cosmetics.ir';$_SERVER['HTTPS']='on';$_SERVER['SERVER_PORT']='443';$_SERVER['REQUEST_URI']='/';
require '/var/www/html/wp-load.php';global $wpdb;
$from=103568;$to=70337;$erp=10685058;$detail=12183120;
$commit=getenv('VC_WASHBAG_REMAP_COMMIT')==='yes';
if($commit && getenv('VC_WASHBAG_REMAP_BACKUP_VERIFIED')!=='yes')exit(11);
function wbr_norm($s){
  $s=rawurldecode((string)$s);
  $s=strtr($s,['ي'=>'ی','ك'=>'ک','آ'=>'ا','‌'=>' ','٠'=>'0','١'=>'1','٢'=>'2','٣'=>'3','٤'=>'4','٥'=>'5','٦'=>'6','٧'=>'7','٨'=>'8','٩'=>'9','۰'=>'0','۱'=>'1','۲'=>'2','۳'=>'3','۴'=>'4','۵'=>'5','۶'=>'6','۷'=>'7','۸'=>'8','۹'=>'9']);
  $s=mb_strtolower($s,'UTF-8');return preg_replace('/[^\p{L}\p{N}]+/u','',$s);
}
$lockName='vesta_exact_70337_draft_import_mapping_transfer';
$held=false;$began=false;
try {
  if($commit){
    if((int)$wpdb->get_var($wpdb->prepare('SELECT GET_LOCK(%s,10)',$lockName))!==1)
      throw new RuntimeException('lock_busy');
    $held=true;
  }
  $draft=wc_get_product($from);$var=wc_get_product($to);
  if(!$draft||!$var||$draft->get_type()!=='simple' ||$var->get_type()!=='variation' ||
     get_post_status($from)!=='draft' ||get_post_status($to)!=='publish' ||
     (int)$var->get_parent_id()!==70328 ||$draft->is_purchasable()||!$var->is_purchasable())
      throw new RuntimeException('draft_or_variant_identity_invalid');
  if(strpos(wbr_norm($var->get_name()),wbr_norm('ست دو عددی کوچک+بزرگ'))===false ||
     strpos(wbr_norm($var->get_name()),wbr_norm('واش بگ مدل قلب نسکافه ای وستا'))===false)
      throw new RuntimeException('variation_name_mismatch');
  $erpRow=$wpdb->get_row($wpdb->prepare(
      "SELECT ProductId,ProductCode,ProductName FROM {$wpdb->prefix}bazara_products WHERE ProductId=%d AND Deleted=0",$erp),ARRAY_A);
  if(!$erpRow || $erpRow['ProductCode']!=='70328' ||
      wbr_norm($erpRow['ProductName'])!==wbr_norm($var->get_name()))
      throw new RuntimeException('erp_product_code_or_name_changed');
  $detailRows=$wpdb->get_results($wpdb->prepare(
      "SELECT ProductDetailId,Properties FROM {$wpdb->prefix}bazara_product_details WHERE ProductId=%d AND Deleted=0",$erp),ARRAY_A);
  if(count($detailRows)!==1 || (int)$detailRows[0]['ProductDetailId']!==$detail ||
     !in_array(trim((string)($detailRows[0]['Properties']??'')),['','null','[]'],true))
      throw new RuntimeException('erp_detail_not_unique');
  $refs=$wpdb->get_col($wpdb->prepare("SELECT post_id FROM {$wpdb->postmeta}
      WHERE meta_key='mahak_product_detail_id' AND meta_value=%s",(string)$detail));
  if(count($refs)!==1 || (int)$refs[0]!==$from)
      throw new RuntimeException('detail_mapping_not_exclusively_on_draft');
  if((int)get_post_meta($from,'mahak_id',true)!==$erp ||
      (int)get_post_meta($from,'mahak_product_detail_id',true)!==$detail ||
      metadata_exists('post',$to,'mahak_id') || metadata_exists('post',$to,'mahak_product_detail_id'))
      throw new RuntimeException('existing_mapping_identity_mismatch');
  $oldOrders=(int)$wpdb->get_var($wpdb->prepare(
      "SELECT COUNT(*) FROM {$wpdb->prefix}woocommerce_order_items oi
        JOIN {$wpdb->prefix}woocommerce_order_itemmeta m ON m.order_item_id=oi.order_item_id
        WHERE m.meta_key IN ('_product_id','_variation_id') AND m.meta_value=%s",(string)$from));
  if($oldOrders!==0)throw new RuntimeException('draft_product_has_order_references');
  $before=[];
  foreach([$from,$to] as $id){
    $p=wc_get_product($id);
    $before[$id]=['name'=>$p->get_name(),'sku'=>$p->get_sku(),
       'price'=>$p->get_price(),'stock'=>$p->get_stock_quantity(),
       'image'=>$p->get_image_id(),'gallery'=>$p->get_gallery_image_ids(),
       'status'=>get_post_status($id)];
  }
  echo 'WASHBAG_STANDALONE_EXACT_REMAP_PLAN='.json_encode([
     'draft_woo_id'=>$from,'published_woo_variation'=>$to,
     'erp_good'=>$erp,'erp_detail'=>$detail,
     'draft_has_no_orders'=>true,'no_duplicate_erp_detail'=>true,
     'prices_stock_images_are_preserved'=>true
   ],JSON_UNESCAPED_UNICODE).PHP_EOL;
  if(!$commit){echo "WASHBAG_REMAP_DRYRUN_NO_WRITES=yes\n";exit(0);}
  $wpdb->query('START TRANSACTION');$began=true;
  $removed=$wpdb->query($wpdb->prepare(
     "DELETE FROM {$wpdb->postmeta} WHERE post_id=%d AND
       ((meta_key='mahak_id' AND meta_value=%s) OR (meta_key='mahak_product_detail_id' AND meta_value=%s))",
      $from,(string)$erp,(string)$detail));
  if($removed!==2)throw new RuntimeException('expected_two_draft_meta_records');
  $written=$wpdb->query($wpdb->prepare(
     "INSERT INTO {$wpdb->postmeta} (post_id,meta_key,meta_value) VALUES (%d,'mahak_id',%s),(%d,'mahak_product_detail_id',%s)",
     $to,(string)$erp,$to,(string)$detail));
  if($written!==2)throw new RuntimeException('expected_two_new_meta_records');
  if((int)$wpdb->get_var($wpdb->prepare("SELECT COUNT(*) FROM {$wpdb->postmeta} WHERE meta_key='mahak_product_detail_id' AND meta_value=%s",(string)$detail))!==1)
    throw new RuntimeException('erp_detail_reuse');
  $wpdb->query('COMMIT');$began=false;
  foreach([$from,$to] as $id){wp_cache_delete($id,'post_meta');clean_post_cache($id);wc_delete_product_transients($id);}
  foreach([$from,$to] as $id){
    $p=wc_get_product($id);
    $after=['name'=>$p->get_name(),'sku'=>$p->get_sku(),'price'=>$p->get_price(),
      'stock'=>$p->get_stock_quantity(),'image'=>$p->get_image_id(),
      'gallery'=>$p->get_gallery_image_ids(),'status'=>get_post_status($id)];
    if($after!==$before[$id])throw new RuntimeException('non_mapping_field_changed');
  }
  if(metadata_exists('post',$from,'mahak_id')||metadata_exists('post',$from,'mahak_product_detail_id')||
    (int)get_post_meta($to,'mahak_id',true)!==$erp ||
    (int)get_post_meta($to,'mahak_product_detail_id',true)!==$detail)
    throw new RuntimeException('mapping_post_commit_readback_failed');
  echo "WASHBAG_70337_EXACT_GOOD_AND_DETAIL_MOVED_FROM_UNUSED_DRAFT_READBACK_VERIFIED=yes\n";
  echo "WASHBAG_PRICE_STOCK_IMAGES_AND_ERP_INVOICES_UNCHANGED=yes\n";
}catch(Throwable $e){
  if($began)$wpdb->query('ROLLBACK');
  echo 'WASHBAG_EXACT_REMAP_ABORT_REASON='.preg_replace('/[^a-z_]/','',$e->getMessage()).PHP_EOL;
  exit(30);
}finally{if($held)$wpdb->get_var($wpdb->prepare('SELECT RELEASE_LOCK(%s)',$lockName));}
