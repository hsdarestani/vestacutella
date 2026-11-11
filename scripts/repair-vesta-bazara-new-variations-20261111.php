<?php
// Vesta: repair only 28 exact and independently verified Woo variations against cached Bazara data.
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
 // Woo variation => [Woo parent, Bazaar product ID, Bazaar exact variant detail ID]
 94902=>[94901,10684973,12183468],
 69956=>[69947,10685068,12183822],
 65195=>[65186,10684999,12183892],
 58820=>[58809,10685472,12183768],
 46097=>[46087,10685494,12182611],
 41708=>[41693,10685314,12182725],
 76573=>[76570,10685052,12183864],
 88950=>[88949,10684955,12183415],
 101233=>[101227,10685161,12183365],
 100025=>[37746,10685274,12182586],
 42648=>[42645,10685284,12182817],
 54597=>[54591,10685442,12182672],
 42649=>[42645,10685284,12182816],
 100022=>[37746,10685274,12182587],
 41904=>[41893,10685318,12182732],
 42947=>[42943,10685294,12182786],
 29632=>[29608,10685397,12182398],
 60159=>[60154,10685453,12183644],
 102847=>[102845,10685124,12183544],
 51810=>[51806,10685526,12182700],
 41555=>[41553,10685311,12182713],
 33048=>[33045,10685375,12182453],
 26957=>[26954,10685392,12182360],
 42675=>[42672,10685286,12182824],
 42724=>[42714,10685288,12182833],
 102165=>[102164,10685081,12183640],
 102364=>[102359,10685143,12183521],
 101686=>[101684,10685225,12183345],
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
