<?php
// Fail-closed exact ERP matching, supplementary 18 Woo variations, no order or stock writes.
error_reporting(E_ERROR|E_PARSE);ini_set('display_errors','0');
$_SERVER['HTTP_HOST']='vesta-cosmetics.ir';$_SERVER['SERVER_NAME']='vesta-cosmetics.ir';
$_SERVER['HTTPS']='on';$_SERVER['SERVER_PORT']='443';$_SERVER['REQUEST_URI']='/';
require '/var/www/html/wp-load.php';
global $wpdb;
$rows=array(
 76565=>array(76561,10685051,12183862),
 85731=>array(85720,10684923,12183846),
 36675=>array(36666,10685266,12182405),
 36673=>array(36666,10685266,12182407),
 54111=>array(54109,10685564,12182650),
 36669=>array(36666,10685266,12182410),
 42932=>array(42928,10685293,12182780),
 37112=>array(37102,10685268,12182412),
 87719=>array(62775,10685241,12183701),
 87720=>array(62775,10685241,12183681),
 37737=>array(37724,10685273,12182426),
 42933=>array(42928,10685293,12182779),
 102363=>array(102359,10685143,12183522),
 94710=>array(94708,10684966,12183471),
 54139=>array(54125,10685547,12182651),
 39916=>array(39910,10685244,12182758),
 35812=>array(33108,10685377,12182430),
 46843=>array(46834,10685491,12182683),
 37188=>array(37185,10685271,12182415),
);
function vc_norm($s){
 $s=trim((string)$s);
 $s=strtr($s,array('۰'=>'0','۱'=>'1','۲'=>'2','۳'=>'3','۴'=>'4','۵'=>'5','۶'=>'6','۷'=>'7','۸'=>'8','۹'=>'9',
 '٠'=>'0','١'=>'1','٢'=>'2','٣'=>'3','٤'=>'4','٥'=>'5','٦'=>'6','٧'=>'7','٨'=>'8','٩'=>'9'));
 $s=str_replace(array('ي','ك','آ','‌','ـ','أ','إ'),array('ی','ک','ا',' ','','ا','ا'),$s);
 $s=function_exists('mb_strtolower')?mb_strtolower($s,'UTF-8'):strtolower($s);
 $s=preg_replace('/[\x{064B}-\x{065F}]/u','',$s);
 $s=preg_replace('/[^\p{L}\p{N}\s]/u',' ',$s);
 return trim(preg_replace('/\s+/u',' ',$s));
}
function vc_attr($s){
 $s=preg_replace('/\s+/u','',vc_norm($s));
 $s=preg_replace('/^(کد|پک)/u','',$s);
 return preg_replace_callback('/\d+/',function($m){return (string)(int)$m[0];},$s);
}
$ps=$wpdb->get_results("SELECT ProductId,ProductCode,ProductName,Deleted FROM {$wpdb->prefix}bazara_products",ARRAY_A);
$ds=$wpdb->get_results("SELECT ProductId,ProductDetailId,Properties,Deleted FROM {$wpdb->prefix}bazara_product_details",ARRAY_A);
$byTitle=array();$byCode=array();$byDetail=array();
foreach($ps as $p)if((int)$p['Deleted']===0){
 $byTitle[vc_norm($p['ProductName'])][]=$p;
 $byCode[(string)$p['ProductCode']][]=$p;
}
foreach($ds as $d)if((int)$d['Deleted']===0)$byDetail[(int)$d['ProductId']][]=$d;
$plan=array();
foreach($rows as $id=>$expected){
 list($parentId,$productId,$detailId)=$expected;
 $post=get_post($id);$parent=get_post($parentId);
 if(!$post||$post->post_type!=='product_variation'||(int)$post->post_parent!==$parentId||!$parent||$parent->post_type!=='product'){
  echo "FAIL_WOO_ID=$id\n";exit(10);
 }
 $match=$byCode[(string)$parentId]??array();
 if(count($match)!==1)$match=$byTitle[vc_norm($parent->post_title)]??array();
 if(count($match)!==1||(int)$match[0]['ProductId']!==$productId||vc_norm($match[0]['ProductName'])!==vc_norm($parent->post_title)){
  echo "FAIL_PARENT_ID=$id\n";exit(11);
 }
 $attrs=$wpdb->get_col($wpdb->prepare("SELECT meta_value FROM {$wpdb->postmeta} WHERE post_id=%d AND meta_key LIKE 'attribute%%'",$id));
 if(count($attrs)!==1){echo "FAIL_ATTR=$id\n";exit(12);}
 $candidate=array();$wanted=vc_attr($attrs[0]);
 foreach($byDetail[$productId]??array() as $detail){
  $props=json_decode((string)$detail['Properties'],true);
  $vals=is_array($props)?array_values(array_filter(array_map(function($p){return is_array($p)?vc_attr($p['V']??''):'';},$props))):array();
  if(count($vals)===1&&$vals[0]===$wanted)$candidate[]=(int)$detail['ProductDetailId'];
 }
 if(count($candidate)!==1||$candidate[0]!==$detailId){echo "FAIL_DETAIL=$id\n";exit(13);}
 foreach(array('mahak_id'=>(string)$productId,'mahak_product_detail_id'=>(string)$detailId) as $key=>$val) {
  $old=(string)get_post_meta($id,$key,true);
  if($old!==''&&$old!==$val){echo "FAIL_CONFLICT=$id\n";exit(14);}
  if($old===''&&metadata_exists('post',$id,$key)){echo "FAIL_EMPTY_EXISTING=$id\n";exit(15);}
  if($old==='')$plan[]=array($id,$key,$val);
 }
}
echo 'EXACT_VARIATIONS_VALIDATED='.count($rows)."\n";
echo 'SAFE_NEW_METADATA_ROWS='.count($plan)."\n";
if(getenv('VC_MAP_COMMIT')!=='yes'){echo "DRY_RUN_ONLY=yes\n";exit(0);}
$created=array();
try{
 foreach($plan as $p){
  list($id,$key,$val)=$p;
  if(!add_post_meta($id,$key,$val,true))throw new Exception('meta_insert_failed');
  $created[]=$p;
  if((string)get_post_meta($id,$key,true)!==$val)throw new Exception('readback_failed');
 }
}catch(Throwable $e){
 foreach(array_reverse($created) as $p)delete_post_meta($p[0],$p[1],$p[2]);
 echo "MAPPING_ROLLBACK_COMPLETE=yes\n";exit(25);
}
echo 'CREATED_META_ROWS='.count($created)."\n";
echo "MAPPING_REPAIR_VERIFIED=yes\n";
