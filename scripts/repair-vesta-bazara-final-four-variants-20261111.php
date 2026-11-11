<?php
// Exact mapping of four previously unresolved variants. Never changes prices, stock, orders, or plugin settings.
error_reporting(E_ERROR|E_PARSE);ini_set('display_errors','0');
$_SERVER['HTTP_HOST']='vesta-cosmetics.ir';$_SERVER['SERVER_NAME']='vesta-cosmetics.ir';
$_SERVER['HTTPS']='on';$_SERVER['SERVER_PORT']='443';$_SERVER['REQUEST_URI']='/';
require '/var/www/html/wp-load.php';
global $wpdb;
$expected=[
 94734=>[94733,10684970,12183477],
 37823=>[37821,10685277,12182753],
 37824=>[37821,10685277,12182752],
 42934=>[42928,10685293,12182778],
];
function bazara_norm($s){
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
function norm_detail($s){
 $s=preg_replace('/\s+/u','',bazara_norm($s));
 $s=preg_replace_callback('/\d+/u',function($m){return (string)(int)$m[0];},$s);
 return $s;
}
$allProducts=$wpdb->get_results("SELECT ProductId,ProductCode,ProductName,Deleted FROM {$wpdb->prefix}bazara_products",ARRAY_A);
$byCode=[];
foreach($allProducts as $p)if((int)$p['Deleted']===0)$byCode[(string)$p['ProductCode']][]=$p;
$mapping=[];
foreach($expected as $variantId=>[$parentId,$productId,$detailId]){
 $var=get_post($variantId);$parent=get_post($parentId);
 if(!$var||!$parent||$var->post_type!=='product_variation'||(int)$var->post_parent!==$parentId || $parent->post_type!=='product'){
  echo "ABORT_BAD_WOO_PARENT=$variantId\n";exit(15);
 }
 $matches=$byCode[(string)$parentId]??[];
 if(count($matches)!==1||(int)$matches[0]['ProductId']!==$productId){
  echo "ABORT_ERP_PRODUCT_CODE_NOT_UNIQUE=$variantId\n";exit(16);
 }
 if(bazara_norm($matches[0]['ProductName'])!==bazara_norm($parent->post_title)){
  echo "ABORT_ERP_PARENT_NAME_MISMATCH=$variantId\n";exit(17);
 }
 $attrs=$wpdb->get_results($wpdb->prepare(
  "SELECT meta_value FROM {$wpdb->postmeta} WHERE post_id=%d AND meta_key LIKE 'attribute%%'",$variantId
 ),ARRAY_A);
 if(count($attrs)!==1){
  echo "ABORT_WOO_ATTRIBUTE_COUNT=$variantId\n";exit(18);
 }
 $attr=norm_detail($attrs[0]['meta_value']);
 $remote=$wpdb->get_results($wpdb->prepare(
  "SELECT ProductDetailId,Properties,Deleted FROM {$wpdb->prefix}bazara_product_details WHERE ProductId=%d",
   $productId
 ),ARRAY_A);
 $same=[];
 foreach($remote as $d){
  if((int)$d['Deleted']!==0)continue;
  $props=json_decode((string)$d['Properties'],true);
  $values=is_array($props)?array_values(array_filter(array_map(function($v){return is_array($v)?norm_detail($v['V']??''):'';},$props))):[];
  if(count($values)===1 && $values[0]===$attr)$same[]=(int)$d['ProductDetailId'];
 }
 if(count($same)!==1 || $same[0]!==$detailId){
  echo "ABORT_ERP_DETAIL_NOT_UNIQUE=$variantId MATCHES=".count($same)."\n";exit(19);
 }
 foreach(['mahak_id'=>(string)$productId,'mahak_product_detail_id'=>(string)$detailId] as $k=>$v){
   $current=(string)get_post_meta($variantId,$k,true);
   if($current!=='' && $current!==$v){echo "ABORT_EXISTING_CONFLICT=$variantId\n";exit(20);}
 }
 $mapping[$variantId]=[$parentId,$productId,$detailId];
 echo "EXACT_VERIFIED_MAPPING=$variantId PARENT=$parentId PRODUCT=$productId DETAIL=$detailId\n";
}
if(count($mapping)!==4){echo "ABORT_EXPECTED_FOUR=yes\n";exit(21);}
echo "FINAL_FOUR_MAPPING_DRYRUN_VERIFIED=yes\n";
if(getenv('VC_FINAL_FOUR_MAP_COMMIT')!=='yes'){echo "DRY_RUN_NO_WRITES=yes\n";exit(0);}
$created=[];
try {
 foreach($mapping as $v=>[$parentId,$pid,$did]){
   foreach(['mahak_id'=>(string)$pid,'mahak_product_detail_id'=>(string)$did] as $k=>$val){
    $old=(string)get_post_meta($v,$k,true);
    if($old===$val)continue;
    if($old!=='')throw new Exception('unexpected partial mapping');
    if(!add_post_meta($v,$k,$val,true))throw new Exception('new mapping insert failure');
    $created[]=[$v,$k,$val];
    if((string)get_post_meta($v,$k,true)!==$val)throw new Exception('new mapping readback failure');
   }
 }
}catch(Throwable $e){
 foreach(array_reverse($created) as [$v,$k,$val])delete_post_meta($v,$k,$val);
 echo "ROLLED_BACK_MAPPING_CHANGES=yes\n";exit(25);
}
echo "FINAL_FOUR_MAPPING_COMMIT_SUCCESS=yes NEW_META_ROWS=".count($created)."\n";
