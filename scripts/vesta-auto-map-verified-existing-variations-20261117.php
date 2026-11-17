<?php
/**
 * Map existing Mahak catalog IDs onto sellable Woo variations only when
 * the stable ProductCode, product name, exact variation attributes (or full
 * standalone variation name) and unique ProductDetail all match.
 *
 * Dry-run default; no ERP product creation, invoice, stock, price, photos or
 * remote API writes; commit requires verified local backup and is max 10/run.
 */
error_reporting(E_ERROR|E_PARSE);ini_set('display_errors','0');
$_SERVER['HTTP_HOST']='vesta-cosmetics.ir';$_SERVER['SERVER_NAME']='vesta-cosmetics.ir';$_SERVER['HTTPS']='on';$_SERVER['SERVER_PORT']='443';$_SERVER['REQUEST_URI']='/';
require '/var/www/html/wp-load.php';global $wpdb;
$commit=getenv('VCAR_VARIANT_COMMIT')==='yes';
if($commit&&getenv('VCAR_VARIANT_BACKUP_VERIFIED')!=='yes'){echo "VARIANT_BACKUP_REQUIRED_NO_WRITES=yes\n";exit(20);}
function vav_norm($s){
 $s=rawurldecode((string)$s);
 $s=strtr($s,['ي'=>'ی','ك'=>'ک','آ'=>'ا','‌'=>' ','٠'=>'0','١'=>'1','٢'=>'2','٣'=>'3','٤'=>'4','٥'=>'5','٦'=>'6','٧'=>'7','٨'=>'8','٩'=>'9','۰'=>'0','۱'=>'1','۲'=>'2','۳'=>'3','۴'=>'4','۵'=>'5','۶'=>'6','۷'=>'7','۸'=>'8','۹'=>'9']);
 $s=mb_strtolower($s,'UTF-8');$s=preg_replace('/[^\p{L}\p{N}]+/u','',$s);
 return preg_replace_callback('/\d+/',function($m){return (string)(int)$m[0];},$s);
}
function vav_attr($s){return preg_replace('/^(کد|پک)/u','',vav_norm($s));}
$byCode=[];$detailByProduct=[];$used=[];
foreach($wpdb->get_results("SELECT ProductId,ProductCode,ProductName,Deleted FROM {$wpdb->prefix}bazara_products",ARRAY_A) as $p)
 if((int)$p['Deleted']===0)$byCode[(string)$p['ProductCode']][]=$p;
foreach($wpdb->get_results("SELECT ProductId,ProductDetailId,Properties,Deleted FROM {$wpdb->prefix}bazara_product_details",ARRAY_A) as $d)
 if((int)$d['Deleted']===0)$detailByProduct[(int)$d['ProductId']][]=$d;
foreach($wpdb->get_results("SELECT m.meta_value,m.post_id FROM {$wpdb->postmeta} m JOIN {$wpdb->posts} p ON p.ID=m.post_id WHERE m.meta_key='mahak_product_detail_id' AND CAST(m.meta_value AS UNSIGNED)>0 AND p.post_status NOT IN ('trash','auto-draft')",ARRAY_A) as $r)
 $used[(int)$r['meta_value']][]=(int)$r['post_id'];
$plan=[];$observed=['unmapped_variations'=>0,'parent_code_candidates'=>0,'independent_good_candidates'=>0,
 'unresolved_or_ambiguous'=>0,'duplicate_detail_conflicts'=>0,'safe_candidates'=>0,'candidate_ids'=>[]];
$rows=$wpdb->get_results("SELECT v.ID,v.post_parent FROM {$wpdb->posts} v JOIN {$wpdb->posts} p ON p.ID=v.post_parent WHERE v.post_type='product_variation' AND v.post_status='publish' AND p.post_status='publish'",ARRAY_A);
foreach($rows as $row){
 $id=(int)$row['ID'];$parentID=(int)$row['post_parent'];
 if(metadata_exists('post',$id,'mahak_id')||metadata_exists('post',$id,'mahak_product_detail_id'))continue;
 $observed['unmapped_variations']++;
 $variation=wc_get_product($id);$parent=wc_get_product($parentID);
 if(!$variation||!$parent || $variation->get_price()===''){$observed['unresolved_or_ambiguous']++;continue;}
 $found=[];
 // Mode A: ERP parent good has parent Woo ID/SKU, and ERP detail has
 // precisely all variation attribute values.
 $parentCodes=array_unique(array_filter([(string)$parentID,(string)$parent->get_sku()]));
 $parentMatches=[];
 foreach($parentCodes as $code)foreach($byCode[$code]??[] as $p)$parentMatches[(int)$p['ProductId']]=$p;
 if(count($parentMatches)===1){
  $p=reset($parentMatches);
  if(vav_norm($p['ProductName'])===vav_norm($parent->get_name())){
   $attrs=[];$valid=true;
   foreach($wpdb->get_results($wpdb->prepare("SELECT meta_key,meta_value FROM {$wpdb->postmeta} WHERE post_id=%d AND meta_key LIKE 'attribute%%'",$id),ARRAY_A) as $a){
    $val=(string)$a['meta_value'];$tax=substr($a['meta_key'],10);
    if(taxonomy_exists($tax)){
      $term=get_term_by('slug',$val,$tax);
      if(!$term||is_wp_error($term)){$valid=false;break;}
      $val=$term->name;
    }
    $norm=vav_attr($val);
    if($norm===''){$valid=false;break;}
    $attrs[]=$norm;
   }
   if($valid&&$attrs){
    sort($attrs);$matched=[];
    foreach($detailByProduct[(int)$p['ProductId']]??[] as $d){
      $props=json_decode((string)$d['Properties'],true);$values=[];
      foreach(is_array($props)?$props:[] as $prop)
        if(is_array($prop) && isset($prop['V']) && trim((string)$prop['V'])!=='')$values[]=vav_attr($prop['V']);
      sort($values);
      if($values===$attrs)$matched[]=(int)$d['ProductDetailId'];
    }
    if(count($matched)===1)$found[]=[(int)$p['ProductId'],$matched[0],'parent'];
   }
  }
 }
 // Mode B: variation itself is a standalone ERP good with the exact
 // full variation name and one plain detail. Parent-only name is not proof.
 $varCodes=array_unique(array_filter([(string)$id,(string)$variation->get_sku()]));
 $varMatches=[];
 foreach($varCodes as $code)foreach($byCode[$code]??[] as $p)$varMatches[(int)$p['ProductId']]=$p;
 if(count($varMatches)===1){
  $p=reset($varMatches);
  if(vav_norm($p['ProductName'])===vav_norm($variation->get_name()) &&
   vav_norm($variation->get_name())!==vav_norm($parent->get_name())){
   $ds=$detailByProduct[(int)$p['ProductId']]??[];
   if(count($ds)===1){
    $raw=trim((string)$ds[0]['Properties']);$props=json_decode($raw,true);$vals=[];
    if($raw!==''&&$raw!=='null'&&!is_array($props))continue;
    foreach(is_array($props)?$props:[] as $a)
      if(is_array($a)&&isset($a['V'])&&trim((string)$a['V'])!=='')$vals[]=vav_attr($a['V']);
    if(!$vals)$found[]=[(int)$p['ProductId'],(int)$ds[0]['ProductDetailId'],'independent'];
   }
  }
 }
 // No match by name-only; no overriding partial/existing metadata.
 if(count($found)!==1 || $found[0][1]<=0 || isset($used[$found[0][1]])){
   $observed['unresolved_or_ambiguous']++;continue;
 }
 $plan[$id]=$found[0];
 $observed[$found[0][2]==='parent'?'parent_code_candidates':'independent_good_candidates']++;
}
$detailsInPlan=[];
foreach($plan as $id=>$match)$detailsInPlan[$match[1]][]=$id;
foreach($plan as $id=>$match)if(count($detailsInPlan[$match[1]])!==1){
 unset($plan[$id]);$observed['duplicate_detail_conflicts']++;
}
ksort($plan);
$observed['safe_candidates']=count($plan);
$observed['candidate_ids']=array_slice(array_keys($plan),0,30);
echo 'VERIFIED_EXISTING_VARIATION_PLAN='.json_encode($observed,JSON_UNESCAPED_UNICODE).PHP_EOL;
if(!$commit){echo "VERIFIED_VARIATION_DRY_RUN_ONLY_NO_WRITES=yes\n";exit(0);}
$lock='vesta_verified_existing_variation_catalog';
if((int)$wpdb->get_var($wpdb->prepare('SELECT GET_LOCK(%s,5)',$lock))!==1){echo "VARIANT_MAPPER_BUSY_NO_WRITES=yes\n";exit(24);}
$created=[];$completed=0;
try{
 foreach(array_slice($plan,0,10,true) as $id=>$entry){
   [$productID,$detailID,$mode]=$entry;
   if(metadata_exists('post',$id,'mahak_id')||metadata_exists('post',$id,'mahak_product_detail_id'))continue;
   $remote=$wpdb->get_var($wpdb->prepare("SELECT ProductDetailId FROM {$wpdb->prefix}bazara_product_details WHERE ProductId=%d AND ProductDetailId=%d AND Deleted=0 LIMIT 1",$productID,$detailID));
   if((int)$remote!==$detailID || isset($used[$detailID]))throw new RuntimeException('detail_changed');
   // Keep financial and media metadata completely untouched.
   $woo=wc_get_product($id);
   $before=[$woo->get_price(),$woo->get_stock_quantity(),$woo->get_sku(),$woo->get_name(),(int)get_post_thumbnail_id($id),get_post_meta($id,'_product_image_gallery',true)];
   foreach(['mahak_id'=>(string)$productID,'mahak_product_detail_id'=>(string)$detailID] as $key=>$val){
     if(!add_post_meta($id,$key,$val,true))throw new RuntimeException('concurrent_or_duplicate_mapping');
     $created[]=[$id,$key,$val];
   }
   $new=wc_get_product($id);
   $after=[$new->get_price(),$new->get_stock_quantity(),$new->get_sku(),$new->get_name(),(int)get_post_thumbnail_id($id),get_post_meta($id,'_product_image_gallery',true)];
   if($before!==$after || (int)get_post_meta($id,'mahak_id',true)!==$productID ||
      (int)get_post_meta($id,'mahak_product_detail_id',true)!==$detailID)throw new RuntimeException('readback_failed');
   $used[$detailID]=[$id];$completed++;
   echo 'VERIFIED_VARIATION_MAPPING_APPLIED='.$id.' ERP_PRODUCT='.$productID.' ERP_DETAIL='.$detailID.' MODE='.$mode.PHP_EOL;
 }
}catch(Throwable $e){
 foreach(array_reverse($created) as $a)delete_post_meta($a[0],$a[1],$a[2]);
 echo "VARIANT_MAPPING_BATCH_ROLLBACK_COMPLETE_NO_ERP_WRITES=yes\n";exit(25);
}finally{$wpdb->get_var($wpdb->prepare('SELECT RELEASE_LOCK(%s)',$lock));}
echo 'VERIFIED_EXISTING_VARIATION_MAPPINGS_CREATED='.$completed.' ALL_WOO_PRICES_STOCK_AND_IMAGES_UNCHANGED=yes'.PHP_EOL;
echo "NO_REMOTE_PRODUCT_PERSON_INVOICE_OR_PAYMENT_WRITES=yes\n";
