<?php
// Read-only or opt-in exact mapping repair for eligible recent Woo orders that do not have ERP acknowledgments.
error_reporting(E_ERROR|E_PARSE);ini_set('display_errors','0');
$_SERVER['HTTP_HOST']='vesta-cosmetics.ir';$_SERVER['SERVER_NAME']='vesta-cosmetics.ir';
$_SERVER['HTTPS']='on';$_SERVER['SERVER_PORT']='443';$_SERVER['REQUEST_URI']='/';
require '/var/www/html/wp-load.php';
global $wpdb;
$ids=$wpdb->get_col("SELECT p.ID FROM {$wpdb->posts} p LEFT JOIN {$wpdb->postmeta} m
 ON m.post_id=p.ID AND m.meta_key='mahak_id' AND CAST(m.meta_value AS UNSIGNED)>0
 WHERE p.post_type='shop_order' AND p.post_date_gmt>='2026-11-11 00:00:00'
 AND p.post_status IN ('wc-processing','wc-completed','wc-processing5')
 AND m.meta_id IS NULL ORDER BY p.ID ASC LIMIT 50");
function vc_norm($s){
 $s=trim((string)$s);
 $s=strtr($s,[
 '۰'=>'0','۱'=>'1','۲'=>'2','۳'=>'3','۴'=>'4','۵'=>'5','۶'=>'6','۷'=>'7','۸'=>'8','۹'=>'9',
 '٠'=>'0','١'=>'1','٢'=>'2','٣'=>'3','٤'=>'4','٥'=>'5','٦'=>'6','٧'=>'7','٨'=>'8','٩'=>'9']);
 $s=str_replace(['ي','ك','آ','‌','ـ','أ','إ'],['ی','ک','ا',' ','','ا','ا'],$s);
 $s=function_exists('mb_strtolower')?mb_strtolower($s,'UTF-8'):strtolower($s);
 $s=preg_replace('/[\x{064B}-\x{065F}]/u','',$s);
 $s=preg_replace('/[^\p{L}\p{N}\s]/u',' ',$s);
 return trim(preg_replace('/\s+/u',' ',$s));
}
function vc_attr($s){$s=preg_replace('/\s+/u','',vc_norm($s));return preg_replace_callback('/\d+/',function($m){return (string)(int)$m[0];},$s);}
$remoteProducts=$wpdb->get_results("SELECT ProductId,ProductCode,ProductName,Deleted FROM {$wpdb->prefix}bazara_products",ARRAY_A);
$remoteDetails=$wpdb->get_results("SELECT ProductId,ProductDetailId,Properties,Deleted FROM {$wpdb->prefix}bazara_product_details",ARRAY_A);
$productByCode=[];$byTitle=[];$detailByProduct=[];
foreach($remoteProducts as $p){
 if((int)$p['Deleted']!==0)continue;
 $productByCode[(string)$p['ProductCode']][]=$p;
 $byTitle[vc_norm($p['ProductName'])][]=$p;
}
foreach($remoteDetails as $d)if((int)$d['Deleted']===0)$detailByProduct[(int)$d['ProductId']][]=$d;
$seen=[];$exact=[];$unknown=[];$known=[];$orderMissing=[];
foreach($ids as $id){
 $o=wc_get_order($id);if(!$o)continue;
 $missing=0;
 foreach($o->get_items('line_item') as $it){
  $var=(int)$it->get_variation_id();$parent=(int)$it->get_product_id();$key=$var?:$parent;
  $currentP=(string)get_post_meta($key,'mahak_id',true);$currentD=(string)get_post_meta($key,'mahak_product_detail_id',true);
  if($currentP!=='' && $currentD!==''){$known[$key]=1;continue;}
  $missing++;
  if(isset($seen[$key]))continue;
  $seen[$key]=1;
  if($currentP!=='' || $currentD!==''){$unknown[$key]='partial_existing_mapping';continue;}
  $p=get_post($key);$parentPost=get_post($parent);
  if(!$p||!$parentPost||$parentPost->post_type!=='product'||($var && ($p->post_type!=='product_variation'||(int)$p->post_parent!==$parent))){
   $unknown[$key]='invalid_woo_post_parent';continue;
  }
  $matching=$productByCode[(string)$parent]??[];
  if(count($matching)!==1) {
    // Exact normalized title only, if SKU missing entirely.
    $matching=$byTitle[vc_norm($parentPost->post_title)]??[];
    if(count($matching)!==1){$unknown[$key]='ambiguous_parent_matches_'.count($matching);continue;}
  }
  $remote=$matching[0];
  $pid=(int)$remote['ProductId'];
  if(vc_norm($parentPost->post_title)!==vc_norm($remote['ProductName'])) {
    $unknown[$key]='erp_product_code_name_mismatch';continue;
  }
  $details=$detailByProduct[$pid]??[];
  if(!$var){
    $dids=[];
    foreach($details as $d){
      $props=json_decode((string)$d['Properties'],true);
      if(empty($props))$dids[]=(int)$d['ProductDetailId'];
    }
    if(count($dids)!==1){$unknown[$key]='simple_default_detail_matches_'.count($dids);continue;}
    $exact[$key]=[$parent,$pid,$dids[0]];continue;
  }
  $attrs=$wpdb->get_results($wpdb->prepare(
    "SELECT meta_value FROM {$wpdb->postmeta} WHERE post_id=%d AND meta_key LIKE 'attribute%%'",$key),ARRAY_A);
  if(count($attrs)!==1){$unknown[$key]='attribute_count_'.count($attrs);continue;}
  $attr=vc_attr($attrs[0]['meta_value']);$dids=[];
  foreach($details as $d){
    $props=json_decode((string)$d['Properties'],true);
    $values=is_array($props)?array_values(array_filter(array_map(function($v){return is_array($v)?vc_attr($v['V']??''):'';},$props))):[];
    if(count($values)===1 && $values[0]===$attr)$dids[]=(int)$d['ProductDetailId'];
  }
  if(count($dids)!==1){$unknown[$key]='erp_variant_detail_matches_'.count($dids);continue;}
  $exact[$key]=[$parent,$pid,$dids[0]];
 }
 $orderMissing[$id]=$missing;
}
echo 'UNACKED_ORDERS_CHECKED='.count($ids)."\n";
foreach($ids as $id)echo "UNACKED_ORDER=$id UNMAPPED_ITEM_COUNT=".($orderMissing[$id]??0)."\n";
foreach($exact as $k=>$v)echo "EXACT_MATCH_WOO=$k PARENT=$v[0] ERP_PRODUCT=$v[1] ERP_DETAIL=$v[2]\n";
foreach($unknown as $k=>$v)echo "UNRESOLVED_WOO=$k REASON=$v\n";
echo 'ALREADY_MAPPED_UNIQUE_ITEMS='.count($known)."\n";
echo 'EXACT_MATCHES='.count($exact)."\n";
echo 'UNRESOLVED='.count($unknown)."\n";
echo "EXACT_MAPPING_AUDIT_COMPLETE=yes\n";
if(getenv('VC_SAFE_VARIANT_MAP_COMMIT')!=='yes'){echo "DRY_RUN_NO_WRITES=yes\n";exit(0);}
if($unknown){echo "COMMIT_SKIPPED_UNRESOLVED_ITEMS=yes\n";exit(23);}
$created=[];
try{
 foreach($exact as $id=>$v){
  foreach(['mahak_id'=>(string)$v[1],'mahak_product_detail_id'=>(string)$v[2]] as $key=>$val){
   if((string)get_post_meta($id,$key,true)!=='')throw new Exception('concurrent mapping changed');
   if(!add_post_meta($id,$key,$val,true))throw new Exception('meta insert failed');
   $created[]=[$id,$key,$val];
   if((string)get_post_meta($id,$key,true)!==$val)throw new Exception('readback failed');
  }
 }
}catch(Throwable $e){
 foreach(array_reverse($created) as [$id,$key,$val])delete_post_meta($id,$key,$val);
 echo "MAP_REPAIR_ROLLBACK=yes\n";exit(25);
}
echo "EXACT_MAP_SAVED_COUNT=".count($exact)."\n";
echo "META_ROWS_SAVED=".count($created)."\n";
echo "NO_ORDER_OR_PRICE_CHANGE=yes\n";
