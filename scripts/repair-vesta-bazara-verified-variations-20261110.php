<?php
// Vesta: repair only 16 exact and independently verified Woo variations against cached Bazara data.
// This is NOT an order submission. No pricing, stock or existing order metadata is changed.
error_reporting(E_ERROR | E_PARSE);
ini_set('display_errors','0');
$_SERVER['HTTP_HOST']='vesta-cosmetics.ir';
$_SERVER['SERVER_NAME']='vesta-cosmetics.ir';
$_SERVER['HTTPS']='on';
$_SERVER['SERVER_PORT']='443';
$_SERVER['REQUEST_SCHEME']='https';
$_SERVER['REQUEST_URI']='/wp-cron.php';
require '/var/www/html/wp-load.php';
global $wpdb;
$rows = [
 // Woo variation => [Woo parent, Bazara ProductId, Bazara ProductDetailId]
 33051=>[33045,10685375,12182450],
 35117=>[35112,10685320,12182427],
 35120=>[35112,10685320,12182428],
 41902=>[41893,10685318,12182734],
 42807=>[42801,10685289,12182803],
 44569=>[44556,10685525,12182622],
 45092=>[45079,10685513,12182643],
 45900=>[45887,10685506,12182603],
 54598=>[54591,10685442,12182671],
 56381=>[56377,10685407,12183720],
 58872=>[58867,10685474,12183717],
 73200=>[73091,10685044,12183811],
 100023=>[37746,10685274,12182710],
 101872=>[101870,10685209,12183393],
 102250=>[102249,10685094,12183612],
 102253=>[102249,10685094,12183609],
];
function norm_text($s) {
 $s=trim((string)$s);
 $s=str_replace(['ي','ك','آ','‌','ـ','أ','إ'],['ی','ک','ا',' ','','ا','ا'],$s);
 $s=function_exists('mb_strtolower')?mb_strtolower($s,'UTF-8'):strtolower($s);
 $s=preg_replace('/[\x{064B}-\x{065F}]/u','',$s);
 $s=preg_replace('/[^\p{L}\p{N}\s]/u',' ',$s);
 return trim(preg_replace('/\s+/u',' ',$s));
}
$toCreate=[];
foreach($rows as $varId=>[$parentId,$productId,$detailId]){
 $post=get_post($varId);$parent=get_post($parentId);
 if(!$post || !$parent || $post->post_type!=='product_variation' || (int)$post->post_parent!==$parentId || $parent->post_type!=='product'){
   echo "MAPPING_PREFLIGHT_INVALID_POST=$varId\n";exit(15);
 }
 $product=$wpdb->get_row($wpdb->prepare(
  "SELECT ProductId, ProductName, Deleted FROM {$wpdb->prefix}bazara_products WHERE ProductId=%d LIMIT 2",$productId
 ));
 if(!$product || (int)$product->Deleted!==0 || norm_text($parent->post_title)!==norm_text($product->ProductName)){
   echo "MAPPING_PREFLIGHT_TITLE_MISMATCH=$varId\n";exit(16);
 }
 // Validate that there is exactly one cached remote ProductId for the parent title.
 $remoteProducts=$wpdb->get_results("SELECT ProductId,ProductName FROM {$wpdb->prefix}bazara_products");
 $same=array_values(array_filter($remoteProducts,function($p)use($parent){return norm_text($p->ProductName)===norm_text($parent->post_title);}));
 if(count($same)!==1 || (int)$same[0]->ProductId!==$productId){
   echo "MAPPING_PREFLIGHT_AMBIGUOUS_PARENT=$varId\n";exit(17);
 }
 $attrs=$wpdb->get_results($wpdb->prepare(
  "SELECT meta_value FROM {$wpdb->postmeta} WHERE post_id=%d AND meta_key LIKE 'attribute%%'",$varId
 ),ARRAY_A);
 if(count($attrs)!==1){
   echo "MAPPING_PREFLIGHT_AMBIGUOUS_ATTRIBUTES=$varId\n";exit(18);
 }
 $expected=norm_text($attrs[0]['meta_value']);
 $allDetails=$wpdb->get_results($wpdb->prepare(
  "SELECT ProductDetailId,Properties,Deleted FROM {$wpdb->prefix}bazara_product_details WHERE ProductId=%d",$productId
 ));
 $candidate=[];
 foreach($allDetails as $d){
   if((int)$d->Deleted!==0)continue;
   $props=json_decode((string)$d->Properties,true);
   $values=is_array($props)?array_values(array_filter(array_map(function($x){return is_array($x)?norm_text($x['V']??''):'';},$props))):[];
   if(count($values)===1 && $values[0]===$expected)$candidate[]=(int)$d->ProductDetailId;
 }
 if(count($candidate)!==1 || $candidate[0]!==$detailId){
   echo "MAPPING_PREFLIGHT_AMBIGUOUS_REMOTE_DETAIL=$varId\n";exit(19);
 }
 $existingProduct=(string)get_post_meta($varId,'mahak_id',true);
 $existingDetail=(string)get_post_meta($varId,'mahak_product_detail_id',true);
 if(($existingProduct!=='' && $existingProduct!==(string)$productId) || ($existingDetail!=='' && $existingDetail!==(string)$detailId)){
   echo "MAPPING_PREFLIGHT_CONFLICT=$varId\n";exit(20);
 }
 $toCreate[$varId]=[
  'mahak_id'=>['old'=>$existingProduct,'new'=>(string)$productId],
  'mahak_product_detail_id'=>['old'=>$existingDetail,'new'=>(string)$detailId]
 ];
}
echo "MAPPING_PREFLIGHT_VALIDATED=".count($toCreate)."\n";
if(getenv('VC_MAP_COMMIT')!=='yes') {
 echo "MAPPING_DRY_RUN_ONLY=yes\n";exit(0);
}
$created=[];
try{
 foreach($toCreate as $varId=>$keys){
  foreach($keys as $name=>$values){
   if($values['old']===$values['new'])continue;
   if($values['old']!=='')throw new Exception("Unexpected existing mapping");
   $res=add_post_meta($varId,$name,$values['new'],true);
   if(!$res)throw new Exception("Add meta failed");
   $created[]=[$varId,$name,$values['new']];
   if((string)get_post_meta($varId,$name,true)!==$values['new'])throw new Exception("Readback mismatch");
  }
 }
}catch(Throwable $e){
 foreach(array_reverse($created) as [$id,$key,$val])delete_post_meta($id,$key,$val);
 echo "MAPPING_ROLLBACK_COMPLETE=yes\n";
 exit(25);
}
echo "MAPPING_META_CREATED=".count($created)."\n";
echo "MAPPING_VERIFIED_COMPLETE=yes\n";
