<?php
/**
 * Reconcile Mahak product codes to the existing published Woo parent.
 * Only exact-name, exact-attribute, unique-detail, zero-history-conflict groups.
 * Dry-run by default. Commit requires a verified external database backup.
 * Never alters orders, Mahak Cloud, product prices, stock, thumbnails, galleries or publication status.
 */
error_reporting(E_ERROR|E_PARSE); ini_set('display_errors','0'); set_time_limit(0);
$_SERVER['HTTP_HOST']='vesta-cosmetics.ir';$_SERVER['SERVER_NAME']='vesta-cosmetics.ir';
$_SERVER['HTTPS']='on';$_SERVER['SERVER_PORT']='443';$_SERVER['REQUEST_URI']='/';
require '/var/www/html/wp-load.php'; global $wpdb;
$commit=getenv('VESTA_CATALOG_COMMIT')==='yes';
$verified=getenv('VESTA_CATALOG_BACKUP_VERIFIED')==='yes';
$target=trim((string)(getenv('VESTA_CATALOG_TARGET')?:''));
$batch=min(30,max(1,(int)(getenv('VESTA_CATALOG_BATCH')?:5)));
if($commit&&!$verified){echo "CATALOG_MIGRATION_BACKUP_REQUIRED=yes\n";exit(22);}
function vci_norm($s){
 $s=rawurldecode((string)$s);
 $s=strtr($s,['ي'=>'ی','ك'=>'ک','آ'=>'ا','‌'=>' ','٠'=>'0','١'=>'1','٢'=>'2','٣'=>'3','٤'=>'4','٥'=>'5','٦'=>'6','٧'=>'7','٨'=>'8','٩'=>'9','۰'=>'0','۱'=>'1','۲'=>'2','۳'=>'3','۴'=>'4','۵'=>'5','۶'=>'6','۷'=>'7','۸'=>'8','۹'=>'9']);
 return preg_replace('/[^\p{L}\p{N}]+/u','',mb_strtolower($s,'UTF-8'));
}
function vci_value($row,$key){return (int)get_post_meta((int)$row,$key,true);}
function vci_order_ids(){
 global $wpdb;
 $values=$wpdb->get_col("SELECT DISTINCT meta_value FROM {$wpdb->prefix}woocommerce_order_itemmeta
   WHERE meta_key IN ('_product_id','_variation_id') AND meta_value REGEXP '^[0-9]+$'");
 $lookup=[];
 foreach((array)$values as $v)$lookup[(int)$v]=true;
 return $lookup;
}
$cloud=vmb_catalog(vmb_api());$goods=[];$details=[];$codeIndex=[];
foreach($cloud['Products']??[] as $g){
 if(!empty($g['Deleted']))continue;
 $code=(string)($g['ProductCode']??'');$id=(int)($g['ProductId']??0);
 if(!$id||$code==='')continue;
 $goods[$code]=$g;$codeIndex[$code]=$id;
}
foreach($cloud['ProductDetails']??[] as $d){
 if(!empty($d['Deleted']))continue;
 $pid=(int)($d['ProductId']??0);$did=(int)($d['ProductDetailId']??0);
 if($pid&&$did)$details[$pid][$did]=$d;
}
$raw=$wpdb->get_results("SELECT p.ID,p.post_type,p.post_status,m.meta_value AS sku
 FROM {$wpdb->posts} p JOIN {$wpdb->postmeta} m ON m.post_id=p.ID AND m.meta_key='_sku'
 WHERE p.post_type IN ('product','product_variation') AND p.post_status IN ('publish','private','draft')
 AND m.meta_value<>''",ARRAY_A);
$owners=[];foreach($raw as $r)$owners[(string)$r['sku']][]=$r;
$used=vci_order_ids();
$detailUses=[];$meta=$wpdb->get_results("SELECT p.ID,p.post_parent,p.post_status,m.meta_value AS did
 FROM {$wpdb->posts} p JOIN {$wpdb->postmeta} m ON m.post_id=p.ID AND m.meta_key='mahak_product_detail_id'
 WHERE p.post_type IN ('product','product_variation') AND p.post_status NOT IN ('trash','auto-draft')
 AND m.meta_value<>''",ARRAY_A);
foreach($meta as $m)$detailUses[(int)$m['did']][]=$m;
function vci_snapshot($p){
 return ['price'=>$p->get_price(),'stock'=>$p->get_stock_quantity(),'image'=>(int)$p->get_image_id(),
  'gallery'=>$p->get_gallery_image_ids(),'status'=>$p->get_status(),'sku'=>$p->get_sku()];
}
function vci_immutable($before,$after){
 foreach(['price','stock','image','gallery','status'] as $k)if($before[$k]!==$after[$k])return false;
 return true;
}
function vci_candidate($code,$good,$owners,$details,$used,$detailUses,$codeIndex){
 if(!ctype_digit((string)$code)||count($owners[$code]??[])!==1)return [null,'not_unique_raw_sku_owner'];
 $holder=$owners[$code][0];$liveId=(int)$code;$draftId=(int)$holder['ID'];
 if($holder['post_type']!=='product'||$holder['post_status']!=='draft'||$draftId===$liveId)
    return [null,'not_duplicate_draft_owner'];
 $lp=get_post($liveId);$dp=get_post($draftId);
 if(!$lp||!$dp||$lp->post_type!=='product'||$lp->post_status!=='publish'||$dp->post_status!=='draft')
    return [null,'no_published_canonical_product'];
 if(vci_norm($lp->post_title)!==vci_norm($good['Name']??'') ||
    vci_norm($dp->post_title)!==vci_norm($good['Name']??''))
    return [null,'name_identity_conflict'];
 $parent=wc_get_product($liveId);$draft=wc_get_product($draftId);
 if(!$parent||!$draft||!$parent->is_type('variable')||!$draft->is_type('variable'))
    return [null,'nonvariable_parent_draft'];
 if((string)get_post_meta($liveId,'_sku',true)!=='')
    return [null,'published_parent_sku_not_empty'];
 $erp=(int)$good['ProductId'];
 $pmeta=vci_value($liveId,'mahak_id');$dmeta=vci_value($draftId,'mahak_id');
 if(($pmeta!==0&&$pmeta!==$erp)||$dmeta!==$erp)
    return [null,'parent_erp_id_conflict'];
 $source=$details[$erp]??[];if(count($source)<2)return [null,'not_multidetail_erp_good'];
 $byValues=[];
 foreach($source as $d){
   $values=[];$arr=json_decode((string)($d['Properties']??''),true);
   foreach(is_array($arr)?$arr:[] as $entry)
     if(is_array($entry)&&isset($entry['V'])&&trim((string)$entry['V'])!=='')$values[]=vci_norm($entry['V']);
   if(count($values)!==1||$values[0]==='')continue;
   $byValues[$values[0]][]=(int)$d['ProductDetailId'];
 }
 $activeIds=$parent->get_children();$draftIds=$draft->get_children();
 if(count($activeIds)<1||count($draftIds)<1)return [null,'missing_variations'];
 foreach(array_merge([$draftId],$draftIds) as $id)
   if(!empty($used[(int)$id]))return [null,'draft_order_history'];
 $draftByDetail=[];
 foreach($draftIds as $id){
   $v=wc_get_product((int)$id);
   if(!$v)return [null,'draft_child_missing'];
   $did=vci_value($id,'mahak_product_detail_id');
   if($did && !isset($source[$did]))return [null,'draft_detail_from_other_erp_good'];
   if($did){
     $draftByDetail[$did][]=['id'=>(int)$id,'prop'=>vci_value($id,'prop_id')];
   }
 }
 $vmap=[];$usedDetail=[];
 foreach($activeIds as $id){
    $v=wc_get_product((int)$id);
    if(!$v||!$v->is_type('variation'))return [null,'live_variation_missing'];
    $attrs=$v->get_variation_attributes();
    if(count($attrs)!==1)return [null,'live_variation_attribute_count'];
    $value=vci_norm(reset($attrs));
    if($value===''||count($byValues[$value]??[])!==1)return [null,'nonunique_detail_attribute'];
    $detail=(int)$byValues[$value][0];
    if(isset($usedDetail[$detail]))return [null,'two_variations_same_detail'];
    $usedDetail[$detail]=true;
    if(count($draftByDetail[$detail]??[])!==1||
       (int)$draftByDetail[$detail][0]['prop']<=0)return [null,'draft_prop_id_missing_or_duplicate'];
    foreach($detailUses[$detail]??[] as $usage){
       $uid=(int)$usage['ID'];
       if($uid===$draftId||in_array($uid,$draftIds,true)||in_array($uid,$activeIds,true))continue;
       return [null,'detail_used_by_other_woo'];
    }
    $oldProduct=vci_value($id,'mahak_id');$oldDetail=vci_value($id,'mahak_product_detail_id');
    $oldProp=vci_value($id,'prop_id');$rawSku=(string)get_post_meta($id,'_sku',true);
    $conflictingSku=$rawSku!=='' && isset($codeIndex[$rawSku]) && (int)$codeIndex[$rawSku]!==$erp;
    if(($oldProduct>0&&$oldProduct!==$erp ||
        $oldDetail>0&&$oldDetail!==$detail ||
        $conflictingSku) && !empty($used[(int)$id]))
         return [null,'live_variation_historical_order_requires_review'];
    $alias=$conflictingSku?'V-'.$code.'-'.(int)$id:'';
    if($alias!=='' && wc_get_product_id_by_sku($alias))return [null,'variant_alias_already_exists'];
    $vmap[(int)$id]=['detail'=>$detail,'prop'=>(int)$draftByDetail[$detail][0]['prop'],
       'old_product'=>$oldProduct,'old_detail'=>$oldDetail,'old_prop'=>$oldProp,
       'old_raw_sku'=>$rawSku,'new_sku'=>$alias];
 }
 $plan=['code'=>$code,'good_id'=>$erp,'parent_id'=>$liveId,'draft_id'=>$draftId,
        'active_variants'=>$vmap,'draft_children'=>array_map('intval',$draftIds),
        'old_parent'=>vci_snapshot($parent),'old_draft'=>vci_snapshot($draft),
        'old_erp_parent'=>$pmeta,'old_draft_erp'=>$dmeta,
        'old_draft_detail'=>vci_value($draftId,'mahak_product_detail_id')];
 return [$plan,'ready'];
}
function vci_write($plan){
 global $wpdb;
 $code=(string)$plan['code'];$live=(int)$plan['parent_id'];$draft=(int)$plan['draft_id'];
 $erp=(int)$plan['good_id'];
 // Refuse unexpected double execution; the backup option is also a permanent audit journal.
 $journal='vesta_catalog_reconciled_'.hash('sha256',$code.':'.$erp);
 if(get_option($journal,false)!==false)throw new RuntimeException('already_migrated_journal');
 $wpdb->query('START TRANSACTION');
 try {
   $legacy=['code'=>$code,'erp_id'=>$erp,'draft_parent'=>$draft,'draft_meta'=>
     ['mahak_id'=>$plan['old_draft_erp'],'mahak_product_detail_id'=>$plan['old_draft_detail']],
     'live_parent_erp'=>$plan['old_erp_parent'],'variants'=>$plan['active_variants']];
   if(!add_option($journal,$legacy,'',false))throw new RuntimeException('journal_create_failed');
   update_post_meta($live,'_vesta_catalog_sync_hold','1');
   foreach(array_merge([$draft],$plan['draft_children']) as $id){
     $old=['mahak_id'=>get_post_meta($id,'mahak_id',true),
       'mahak_product_detail_id'=>get_post_meta($id,'mahak_product_detail_id',true),
       'prop_id'=>get_post_meta($id,'prop_id',true)];
     update_post_meta($id,'_vesta_legacy_catalog_ids_20261118',wp_json_encode($old));
     delete_post_meta($id,'mahak_id');delete_post_meta($id,'mahak_product_detail_id');
     delete_post_meta($id,'prop_id');
   }
   $draftObj=wc_get_product($draft);$draftObj->set_sku('');$draftObj->save();
   $liveObj=wc_get_product($live);$liveObj->set_sku($code);$liveObj->save();
   update_post_meta($live,'mahak_id',(string)$erp);
   // Change no existing price/stock/image/category and no old orders.
   foreach($plan['active_variants'] as $id=>$info){
     $v=wc_get_product($id);if(!$v)throw new RuntimeException('variation_disappeared');
     if($info['new_sku']!==''){
        update_post_meta($id,'_vesta_legacy_sku_20261118',$info['old_raw_sku']);
        $v->set_sku($info['new_sku']);$v->save();
     }
     update_post_meta($id,'mahak_id',(string)$erp);
     update_post_meta($id,'mahak_product_detail_id',(string)$info['detail']);
     update_post_meta($id,'prop_id',(string)$info['prop']);
   }
   $afterDraft=wc_get_product($draft);$afterLive=wc_get_product($live);
   if(!vci_immutable($plan['old_draft'],vci_snapshot($afterDraft))||
      !vci_immutable($plan['old_parent'],vci_snapshot($afterLive)))
     throw new RuntimeException('immutable_parent_or_draft_fields_changed');
   if((string)get_post_meta($draft,'_sku',true)!=='' ||
      (string)get_post_meta($live,'_sku',true)!==$code ||
      (int)get_post_meta($live,'mahak_id',true)!==$erp ||
      (int)get_post_meta($draft,'mahak_id',true)!==0)
     throw new RuntimeException('canonical_sku_or_erp_readback_failed');
   foreach($plan['active_variants'] as $id=>$info){
     if((int)get_post_meta($id,'mahak_id',true)!==$erp ||
        (int)get_post_meta($id,'mahak_product_detail_id',true)!==(int)$info['detail'] ||
        (int)get_post_meta($id,'prop_id',true)!==(int)$info['prop'])
       throw new RuntimeException('variation_link_readback_failed');
   }
   delete_post_meta($live,'_vesta_catalog_sync_hold');
   $wpdb->query('COMMIT');
   echo 'CATALOG_CANONICAL_PARENT_FIXED='.$live.' ERP='.$erp.' DRAFT_ARCHIVED='.$draft.
     ' VARIATIONS='.count($plan['active_variants']).PHP_EOL;
 }catch(Throwable $e){
   $wpdb->query('ROLLBACK');
   echo 'CATALOG_RECONCILIATION_ABORTED_TRANSACTION_ROLLBACK='.$e->getMessage().PHP_EOL;
   throw $e;
 }
}
$plans=[];$reasons=[];$examples=[];
foreach($goods as $code=>$g){
 if($target!=='' && (string)$code!==$target)continue;
 if(!ctype_digit((string)$code)||count($owners[$code]??[])!==1)continue;
 $owner=$owners[$code][0];
 if($owner['post_type']!=='product'||$owner['post_status']!=='draft')continue;
 [$p,$reason]=vci_candidate($code,$g,$owners,$details,$used,$detailUses,$codeIndex);
 $reasons[$reason]=($reasons[$reason]??0)+1;
 if($p){
   $plans[$code]=$p;
   if(count($examples)<10)$examples[]=['code'=>$code,'live'=>$p['parent_id'],
     'draft'=>$p['draft_id'],'n_variations'=>count($p['active_variants']),
     'aliases'=>count(array_filter($p['active_variants'],fn($x)=>$x['new_sku']!==''))];
 }
}
echo 'VESTA_CANONICAL_CATALOG_PLAN='.json_encode([
 'eligible'=>count($plans),'reasons'=>$reasons,'examples'=>$examples,
 'target'=>$target,'limit'=>$batch],JSON_UNESCAPED_UNICODE).PHP_EOL;
if(!$commit){echo "CATALOG_CANONICAL_DRY_RUN_NO_CHANGES=yes\n";exit(0);}
$lock='vesta_verified_existing_variation_catalog';
if((int)$wpdb->get_var($wpdb->prepare('SELECT GET_LOCK(%s,10)',$lock))!==1){
 echo 'CATALOG_RECONCILIATION_LOCK_BUSY=yes'.PHP_EOL;exit(24);
}
$done=0;
try{
 foreach(array_slice($plans,0,$batch,true) as $code=>$oldPlan){
   // Re-read the entire relevant Woo + Mahak state under mutex, skip if any change.
   $fresh=wc_get_product((int)$oldPlan['parent_id']);
   $draft=wc_get_product((int)$oldPlan['draft_id']);
   if(!$fresh||!$draft||
     (string)get_post_meta($oldPlan['parent_id'],'_sku',true)!=='' ||
     (string)get_post_meta($oldPlan['draft_id'],'_sku',true)!==(string)$code)
       throw new RuntimeException('concurrent_sku_owner_change');
   vci_write($oldPlan);$done++;
 }
}finally{$wpdb->get_var($wpdb->prepare('SELECT RELEASE_LOCK(%s)',$lock));}
echo 'CATALOG_CANONICAL_BATCH_DONE='.$done.' NO_ORDER_PRICE_STOCK_IMAGE_REMOTE_WRITES=yes'.PHP_EOL;
