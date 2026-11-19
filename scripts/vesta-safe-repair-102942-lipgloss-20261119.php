<?php
/**
 * Verified 102942 GAGK lip gloss import with a stale legacy SKU cleanup.
 * Existing LUCKGO variation #102942 and order #105545 retain their Woo ID,
 * ERP parent/detail mappings, price/stock, and item identity; ONLY its
 * duplicate SKU is released. New Mahak product 10755480 gets SKU 102942.
 * Dry-run default; --apply requires complete verified real-cloud preflight.
 */
error_reporting(E_ERROR|E_PARSE);ini_set('display_errors','0');set_time_limit(240);
$_SERVER['HTTP_HOST']='vesta-cosmetics.ir';$_SERVER['SERVER_NAME']='vesta-cosmetics.ir';
$_SERVER['HTTPS']='on';$_SERVER['SERVER_PORT']='443';$_SERVER['REQUEST_URI']='/';
require '/var/www/html/wp-load.php'; global $wpdb;
$apply=in_array('--apply',$argv??[],true);
$lock='vesta_102942_gagk_verified_creation';
if((int)$wpdb->get_var($wpdb->prepare('SELECT GET_LOCK(%s,8)',$lock))!==1)
  throw new RuntimeException('102942 SKU reassignment lock busy');
$tx=false;$newId=0;$legacyId=102942;
try {
 $journalKey='vesta_102942_verified_gagk_creation_20261119_v1';
 $already=get_option($journalKey,false);
 if(is_array($already)){
   echo '102942_ALREADY_CREATED='.wp_json_encode($already,JSON_UNESCAPED_UNICODE).PHP_EOL;
   echo '102942_NO_DUPLICATE_WRITES=yes'.PHP_EOL;exit(0);
 }
 $catalog=vesta_mhi_catalog();
 $cloud=array_values(array_filter((array)($catalog['Products']??[]),fn($p)=>
     empty($p['Deleted'])&&(string)($p['ProductCode']??'')==='102942'));
 if(count($cloud)!==1 || (int)($cloud[0]['ProductId']??0)!==10755480)
   throw new RuntimeException('Mahak parent identity not unique');
 $name=trim((string)$cloud[0]['Name']);
 if(vesta_catalog_identity_normalize($name)!==
    vesta_catalog_identity_normalize('ليپ گيلاس پاپيوني gagk'))
   throw new RuntimeException('New Mahak name differs from reviewed identity');
 $oldCloud=array_values(array_filter((array)($catalog['Products']??[]),fn($p)=>
     empty($p['Deleted'])&&(int)($p['ProductId']??0)===10685130));
 if(count($oldCloud)!==1 || (string)$oldCloud[0]['ProductCode']!=='102940')
   throw new RuntimeException('Old LUCKGO ERP parent mapping changed');
 $cloudDetails=[];$oldDetailGood=false;$baseDetail=false;
 foreach((array)($catalog['ProductDetails']??[]) as $d) {
   if(!empty($d['Deleted']))continue;
   $pid=(int)($d['ProductId']??0);$id=(int)($d['ProductDetailId']??0);
   if($pid===10685130 && $id===12183539)$oldDetailGood=true;
   if($pid!==10755480)continue;
   $p=$d['Properties']??null;
   if(!$p) {
     if($id!==12269293 || (int)($d['Price1']??0)!==648000 || $baseDetail)
       throw new RuntimeException('Mahak base detail unexpected');
     $baseDetail=true;continue;
   }
   $attrs=json_decode((string)$p,true);
   if(!is_array($attrs)||count($attrs)!==1 ||
      (string)($attrs[0]['C']??'')!=='3' ||
      !in_array((string)($attrs[0]['V']??''),['کد1','کد2','کد3','کد4'],true) ||
      (int)($d['Price1']??0)!==648000)
      throw new RuntimeException('Unknown ERP option or price');
   $label=(string)$attrs[0]['V'];
   if(isset($cloudDetails[$label]))throw new RuntimeException('Duplicate ERP color');
   $cloudDetails[$label]=$id;
 }
 $expected=['کد1'=>12269321,'کد2'=>12269320,'کد3'=>12269319,'کد4'=>12269318];
 if(!$baseDetail || !$oldDetailGood || $cloudDetails!==array_intersect_key($expected,$cloudDetails) ||
    count($cloudDetails)!==4) {
    // Array order in cloud is arbitrary; compare each individually too.
    if(!$baseDetail||!$oldDetailGood||count($cloudDetails)!==4)
       throw new RuntimeException('ERP detail count insufficient');
    foreach($expected as $key=>$did)
       if(($cloudDetails[$key]??0)!==$did)
         throw new RuntimeException('ERP detail identity mismatch '.$key);
 }
 $store=40851;
 foreach($expected as $key=>$did) {
   $rows=$wpdb->get_results($wpdb->prepare(
     "SELECT StoreId,Count1 FROM {$wpdb->prefix}bazara_product_assets
      WHERE ProductDetailId=%d AND Deleted=0",$did),ARRAY_A);
   if(count($rows)!==1 || (int)$rows[0]['StoreId']!==$store ||
      !is_numeric($rows[0]['Count1']) ||
      abs((float)$rows[0]['Count1']-7)>0.000001)
      throw new RuntimeException('Real warehouse quantity no longer 7 for '.$key);
 }
 $legacy=wc_get_product($legacyId);$oldParent=wc_get_product(102940);
 if(!$legacy||!$oldParent||!$legacy->is_type('variation') ||
    $legacy->get_parent_id()!==102940 || $legacy->get_sku()!=='102942' ||
    $legacy->get_status()!=='publish' ||
    (int)$legacy->get_meta('mahak_id',true)!==10685130 ||
    (int)$legacy->get_meta('mahak_product_detail_id',true)!==12183539 ||
    $legacy->get_stock_quantity()!==0 || $legacy->get_regular_price()!=='760000' ||
    $oldParent->get_status()!=='publish' ||
    vesta_catalog_identity_normalize($oldParent->get_name())!==
       vesta_catalog_identity_normalize('لیپ گلاس تینتی LUCKGO'))
    throw new RuntimeException('Legacy LUCKGO variation identity is different');
 if((int)wc_get_product_id_by_sku('102942')!==$legacyId)
   throw new RuntimeException('SKU ownership changed');
 $wooHolderRows=$wpdb->get_col($wpdb->prepare(
    "SELECT post_id FROM {$wpdb->postmeta} WHERE meta_key='_sku' AND meta_value=%s",'102942'));
 if(count(array_unique($wooHolderRows))!==1 || (int)$wooHolderRows[0]!==$legacyId)
    throw new RuntimeException('SKU held elsewhere');
 $wp= get_posts(['post_type'=>'product','post_status'=>['publish','draft','private','pending'],
   'meta_key'=>'mahak_id','meta_value'=>'10755480','fields'=>'ids',
   'posts_per_page'=>10,'suppress_filters'=>true]);
 if($wp)throw new RuntimeException('Target Mahak ERP already has Woo product');
 $nameMatches=$wpdb->get_results($wpdb->prepare(
   "SELECT ID,post_title FROM {$wpdb->posts} WHERE post_type='product'
    AND post_status IN ('publish','draft','private','pending')
    AND post_title LIKE %s",'%پاپيوني%'),ARRAY_A);
 foreach($nameMatches as $row)
   if(vesta_catalog_identity_normalize($row['post_title'])===
      vesta_catalog_identity_normalize($name))
     throw new RuntimeException('Same-named Woo parent already exists');
 $order=wc_get_order(105545);
 if(!$order||$order->get_status()!=='processing'||$order->get_meta('mahak_id',true))
    throw new RuntimeException('Old order status/ERP mapping changed');
 $oldLine=0;foreach($order->get_items('line_item') as $it)
   if((int)$it->get_variation_id()===102942 &&
      (int)$it->get_product_id()===102940 && (int)$it->get_quantity()===1)
      $oldLine++;
 if($oldLine!==1)throw new RuntimeException('Legacy order line not unique');
 $outbox=$wpdb->get_row("SELECT state,reason,remote_id FROM {$wpdb->prefix}vesta_accounting_outbox WHERE order_id=105545",ARRAY_A);
 if(!$outbox||$outbox['state']!=='blocked'||$outbox['reason']!=='missing_product_mapping')
   throw new RuntimeException('Historical accounting outbox state changed');
 $template=wc_get_product(105592);
 if(!$template||!$template->is_type('variable') ||$template->get_status()!=='draft')
   throw new RuntimeException('Verified Woo color taxonomy template missing');
 $attribute=null;$tax='';
 foreach($template->get_attributes() as $a) {
   if($a instanceof WC_Product_Attribute && $a->is_taxonomy()&&$a->get_variation() &&
      $a->get_name()==='pa_رنگ'){$attribute=clone $a;$tax=$a->get_name();break;}
 }
 if(!$attribute||count($attribute->get_options())!==4 ||
    (int)$attribute->get_id()!==4||!taxonomy_exists($tax))
   throw new RuntimeException('Expected color taxonomy unavailable');
 $terms=[];foreach($attribute->get_options() as $tid) {
    $t=get_term((int)$tid,$tax);
    if(!$t||is_wp_error($t)||!isset($expected[$t->name]) || isset($terms[$t->name]))
       throw new RuntimeException('Woo color term mismatch');
    $terms[$t->name]=$t;
 }
 if(count($terms)!==4)throw new RuntimeException('Expected Woo terms missing');
 $cfg=get_bazara_visitor_settings();
 if(($cfg['selectCurrencySoftware']??'')!=='toman' ||
    ($cfg['selectCurrencyPlugin']??'')!=='toman' ||
    ($cfg['publishStatus']??'')!=='draft')
    throw new RuntimeException('Toman/draft policy mismatch');
 echo 'LIPGLOSS_102942_PREFLIGHT='.wp_json_encode([
    'mahak_product_id'=>10755480,'erp_code'=>'102942','erp_name'=>$name,
    'old_woo_variation_id'=>102942,'old_erp_id'=>10685130,
    'order_105545'=>'kept_by_woo_id','variation_count'=>4,
    'unit_price_toman'=>648000,'warehouse_per_variant'=>7,
    'proposed_new_status'=>'draft','category'=>948,
    'color_taxonomy'=>$tax,'photo_import_in_separate_transaction'=>true
 ],JSON_UNESCAPED_UNICODE).PHP_EOL;
 if(!$apply){echo 'LIPGLOSS_102942_DRY_RUN_PASS=yes'.PHP_EOL;
   echo 'LIPGLOSS_102942_NO_WRITES=yes'.PHP_EOL;exit(0);}
 $wpdb->query('START TRANSACTION');$tx=true;
 // Do not alter legacy name, post IDs, ERP source/detail, stock, price or orders.
 $parent=new WC_Product_Variable();
 $parent->set_name($name);$parent->set_status('draft');
 $parent->set_catalog_visibility('hidden');$parent->set_manage_stock(false);
 $parent->set_attributes([$tax=>$attribute]);
 $parent->set_category_ids([948]);
 $parent->update_meta_data('mahak_id','10755480');
 $parent->update_meta_data('mahak_product_detail_id','12269293');
 $parent->update_meta_data('_vesta_mahak_product_id','10755480');
 $parent->update_meta_data('_vesta_mahak_product_code','102942');
 $parent->update_meta_data('_vesta_mahak_import_source','conflict_repair_verified_cloud_20261119');
 $newId=(int)$parent->save();
 if($newId<=0 || $newId===102942)
   throw new RuntimeException('New Woo parent could not be created');
 $termOut=wp_set_object_terms($newId,array_map('intval',$attribute->get_options()),$tax,false);
 if(is_wp_error($termOut)||count($termOut)!==4)
   throw new RuntimeException('Could not attach 4 verified color terms');
 $created=[];
 foreach($expected as $label=>$did) {
    $v=new WC_Product_Variation();
    $v->set_parent_id($newId);$v->set_status('publish');
    $v->set_attributes([$tax=>$terms[$label]->slug]);
    $v->set_regular_price('648000');$v->set_price('648000');
    $v->set_manage_stock(true);$v->set_stock_quantity(7);
    $v->set_stock_status('instock');
    $v->update_meta_data('mahak_id','10755480');
    $v->update_meta_data('mahak_product_detail_id',(string)$did);
    $v->update_meta_data('mahak_product_store_id',(string)$store);
    $v->update_meta_data('_vesta_mahak_option_label',$label);
    $cid=(int)$v->save();
    if(!$cid||$cid===$legacyId)
       throw new RuntimeException('Failed creating verified option');
    $edit=wp_update_post(['ID'=>$cid,'post_title'=>$name.' - '.$label],true);
    if(is_wp_error($edit))throw new RuntimeException('Variation title write failed');
    $created[$label]=$cid;
 }
 // The legacy variation is 0 stock but needed for unresolved order #105545.
 // Preserve its Woo ID and Mahak ProductDetailId; only free wrongly reused SKU.
 $legacy=wc_get_product($legacyId);
 if(!$legacy||$legacy->get_sku()!=='102942')throw new RuntimeException('Legacy SKU changed');
 $legacy->update_meta_data('_vesta_legacy_sku_102942_reassigned_at',gmdate('c'));
 $legacy->update_meta_data('_vesta_legacy_sku_102942_origin_code','102940');
 $legacy->set_sku('');$legacy->save();
 if((int)wc_get_product_id_by_sku('102942')!==0)
    throw new RuntimeException('Legacy SKU not released in Woo lookup');
 $parent=wc_get_product($newId);
 if(!$parent)throw new RuntimeException('New Woo product missing');
 $parent->set_sku('102942');$parent->save();
 WC_Product_Variable::sync($newId);
 $read=wc_get_product($newId);
 if(!$read || !$read->is_type('variable') || $read->get_status()!=='draft' ||
    $read->get_sku()!=='102942'||(int)$read->get_meta('mahak_id',true)!==10755480 ||
    count($read->get_children())!==4 ||
    (int)wc_get_product_id_by_sku('102942')!==$newId)
    throw new RuntimeException('New SKU and parent readback failed');
 foreach($created as $label=>$cid) {
    $v=wc_get_product($cid);
    if(!$v||$v->get_parent_id()!==$newId||
       $v->get_regular_price()!=='648000'||$v->get_price()!=='648000' ||
       $v->get_stock_quantity()!==7||
       (int)$v->get_meta('mahak_product_detail_id',true)!==$expected[$label]||
       (int)$v->get_meta('mahak_id',true)!==10755480)
       throw new RuntimeException('Child variation source not verified '.$cid);
 }
 $old=wc_get_product($legacyId);
 $order=wc_get_order(105545);
 $sameLine=false;foreach($order->get_items('line_item') as $it)
    if((int)$it->get_variation_id()===$legacyId &&
       (int)$it->get_product_id()===102940 && (int)$it->get_quantity()===1)
       $sameLine=true;
 if(!$old || $old->get_sku()!==''||$old->get_parent_id()!==102940||
    (int)$old->get_meta('mahak_id',true)!==10685130 ||
    (int)$old->get_meta('mahak_product_detail_id',true)!==12183539 ||
    $old->get_stock_quantity()!==0 ||
    !$sameLine||$order->get_status()!=='processing')
    throw new RuntimeException('Legacy variation or order identity changed');
 $afterOutbox=$wpdb->get_row("SELECT state,reason,remote_id FROM {$wpdb->prefix}vesta_accounting_outbox WHERE order_id=105545",ARRAY_A);
 if($afterOutbox!==$outbox)throw new RuntimeException('Historical accounting state changed');
 $journal=['utc'=>gmdate('c'),'new_woo_id'=>$newId,'code'=>'102942',
    'mahak_id'=>10755480,'name'=>$name,'variation_ids'=>$created,
    'price_toman'=>648000,'stock_per_variant'=>7,
    'legacy_variation_102942_preserved'=>true,'old_order_105545_unchanged'=>true,
    'parent_status'=>'draft','photos_pending_import'=>true];
 if(!add_option($journalKey,$journal,'',false))
    throw new RuntimeException('Idempotency journal collision');
 $wpdb->query('COMMIT');$tx=false;
 wc_delete_product_transients($newId);wc_delete_product_transients(102940);
 echo 'LIPGLOSS_102942_CREATED='.wp_json_encode($journal,JSON_UNESCAPED_UNICODE).PHP_EOL;
 echo 'LIPGLOSS_102942_VERIFIED_DRAFT_WITH_FOUR_VARIANTS=yes'.PHP_EOL;
 echo 'LIPGLOSS_OLD_ORDER_AND_VARIATION_PRESERVED=yes'.PHP_EOL;
}catch(Throwable $e){
 if($tx)$wpdb->query('ROLLBACK');
 if(function_exists('wc_delete_product_transients')) {
    if($newId)wc_delete_product_transients($newId);
    wc_delete_product_transients(102940);
 }
 echo 'LIPGLOSS_102942_ABORTED='.get_class($e).':'.$e->getMessage().PHP_EOL;
 exit(32);
}finally{
 $wpdb->get_var($wpdb->prepare('SELECT RELEASE_LOCK(%s)',$lock));
}
