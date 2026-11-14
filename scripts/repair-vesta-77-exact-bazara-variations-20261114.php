<?php
// One-time fail-closed exact Woo variation mapping repair. No orders, prices, inventory or remote API writes.
error_reporting(E_ERROR|E_PARSE);ini_set('display_errors','0');
$_SERVER['HTTP_HOST']='vesta-cosmetics.ir';$_SERVER['SERVER_NAME']='vesta-cosmetics.ir';
$_SERVER['HTTPS']='on';$_SERVER['SERVER_PORT']='443';$_SERVER['REQUEST_URI']='/';
require '/var/www/html/wp-load.php';
global $wpdb;
$ids=array(51589,69741,69800,62484,60140,54381,31690,88526,42946,41557,37330,66388,102212,102446,41556,71047,69849,46126,44661,47741,66391,95129,51808,31691,46175,33069,33049,102029,33067,102222,102219,102221,66321,102898,102866,102868,101231,101232,101228,66322,69783,37327,37786,66390,65094,46083,63740,54589,71017,67615,101792,37329,41690,95110,58738,92365,59688,101774,37788,45585,69847,71000,60137,42726,41688,41921,45899,44570,42677,42678,94907,69944,101205,41903,102899,44787,56415);
function vc_norm_14($s) {
 $s=str_replace(array('ي','ك','آ','‌','ـ','أ','إ'),array('ی','ک','ا',' ','','ا','ا'),trim((string)$s));
 $s=function_exists('mb_strtolower')?mb_strtolower($s,'UTF-8'):strtolower($s);
 $s=preg_replace('/[\x{064B}-\x{065F}]/u','',$s);
 $s=preg_replace('/[^\p{L}\p{N}\s]/u',' ',$s);
 return trim(preg_replace('/\s+/u',' ',$s));
}
$ps=$wpdb->get_results("SELECT ProductId,ProductName,Deleted FROM {$wpdb->prefix}bazara_products",ARRAY_A);
$ds=$wpdb->get_results("SELECT ProductId,ProductDetailId,Properties,Deleted FROM {$wpdb->prefix}bazara_product_details",ARRAY_A);
$products=array();$details=array();
foreach($ps as $p)if((int)$p['Deleted']===0)$products[vc_norm_14($p['ProductName'])][]=$p;
foreach($ds as $d)if((int)$d['Deleted']===0)$details[(int)$d['ProductId']][]=$d;
$plan=array();
foreach($ids as $id){
 $post=get_post($id);$parent=$post?get_post($post->post_parent):null;
 if(!$post||$post->post_type!=='product_variation'||!$parent||$parent->post_type!=='product'){echo "FAIL_INVALID_WOO_POST=$id\n";exit(10);}
 $matches=$products[vc_norm_14($parent->post_title)]??array();
 if(count($matches)!==1){echo "FAIL_PARENT_NOT_UNIQUE=$id\n";exit(11);}
 $productId=(int)$matches[0]['ProductId'];
 $attrs=$wpdb->get_col($wpdb->prepare("SELECT meta_value FROM {$wpdb->postmeta} WHERE post_id=%d AND meta_key LIKE 'attribute%%'",$id));
 if(count($attrs)!==1){echo "FAIL_ATTR_COUNT=$id\n";exit(12);}
 $expected=vc_norm_14($attrs[0]);$candidate=array();
 foreach($details[$productId]??array() as $d){
  $props=json_decode((string)$d['Properties'],true);
  $vals=is_array($props)?array_values(array_filter(array_map(function($p){return is_array($p)?vc_norm_14($p['V']??''):'';},$props))):array();
  if(count($vals)===1&&$vals[0]===$expected)$candidate[]=(int)$d['ProductDetailId'];
 }
 if(count($candidate)!==1){echo "FAIL_DETAIL_NOT_UNIQUE=$id\n";exit(13);}
 $keys=array('mahak_id'=>(string)$productId,'mahak_product_detail_id'=>(string)$candidate[0]);
 foreach($keys as $name=>$value){
  $old=(string)get_post_meta($id,$name,true);
  if($old!==''&&$old!==$value){echo "FAIL_EXISTING_CONFLICT=$id:$name\n";exit(14);}
  if($old===''&&metadata_exists('post',$id,$name)){echo "FAIL_EXISTING_EMPTY_META=$id:$name\n";exit(15);}
  if($old==='')$plan[]=array($id,$name,$value);
 }
}
echo 'EXACT_VARIATIONS_VALIDATED='.count($ids)."\n";
echo 'SAFE_NEW_METADATA_ROWS='.count($plan)."\n";
if(getenv('VC_MAP_COMMIT')!=='yes'){echo "DRY_RUN_ONLY=yes\n";exit(0);}
$created=array();
try {
 foreach($plan as $p){
  list($id,$key,$value)=$p;
  if(!add_post_meta($id,$key,$value,true))throw new Exception('write_failed');
  $created[]=$p;
  if((string)get_post_meta($id,$key,true)!==$value)throw new Exception('readback_failed');
 }
}catch(Throwable $e){
 foreach(array_reverse($created) as $p)delete_post_meta($p[0],$p[1],$p[2]);
 echo "ROLLBACK_CREATED_META_COMPLETE=yes\n";exit(25);
}
echo 'CREATED_META_ROWS='.count($created)."\n";
echo "MAPPING_REPAIR_VERIFIED=yes\n";
