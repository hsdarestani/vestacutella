<?php
// Read-only: resolve variation mappings via exact unique ERP product title AND exact unique variant-property value.
error_reporting(E_ERROR|E_PARSE);ini_set('display_errors','0');
$_SERVER['HTTP_HOST']='vesta-cosmetics.ir';$_SERVER['SERVER_NAME']='vesta-cosmetics.ir';
$_SERVER['HTTPS']='on';$_SERVER['SERVER_PORT']='443';$_SERVER['REQUEST_URI']='/';
require '/var/www/html/wp-load.php';
global $wpdb;
$orders=[105219,105220,105221,105223,105225,105226,105227,105228,105230];
function normaliz($s){
 $s=trim((string)$s);
 $s=str_replace(['ي','ك','آ','‌','ـ','أ','إ'],['ی','ک','ا',' ','','ا','ا'],$s);
 $s=function_exists('mb_strtolower')?mb_strtolower($s,'UTF-8'):strtolower($s);
 $s=preg_replace('/[\x{064B}-\x{065F}]/u','',$s);
 $s=preg_replace('/[^\p{L}\p{N}\s]/u',' ',$s);
 return trim(preg_replace('/\s+/u',' ',$s));
}
$remoteProducts=$wpdb->get_results("SELECT ProductId,ProductName,Deleted FROM {$wpdb->prefix}bazara_products",ARRAY_A);
$remoteDetails=$wpdb->get_results("SELECT ProductId,ProductDetailId,Properties,Deleted FROM {$wpdb->prefix}bazara_product_details",ARRAY_A);
$titleByNorm=[];$detailByProduct=[];
foreach($remoteProducts as $pr){if((int)$pr['Deleted']!==0)continue;$titleByNorm[normaliz($pr['ProductName'])][]=(int)$pr['ProductId'];}
foreach($remoteDetails as $rd){if((int)$rd['Deleted']!==0)continue;$detailByProduct[(int)$rd['ProductId']][]=$rd;}
$seen=[];$candidates=[];$problems=[];$already=[];
foreach($orders as $oId){
 $order=wc_get_order($oId);if(!$order || !$order->has_status(['processing','completed']))continue;
 foreach($order->get_items('line_item') as $it){
  $vid=(int)$it->get_variation_id();if(!$vid)continue;
  if(isset($seen[$vid]))continue;$seen[$vid]=1;
  $post=get_post($vid);$parent=$post?get_post($post->post_parent):null;
  if(!$post || !$parent || $post->post_type!=='product_variation' || $parent->post_type!=='product'){
   $problems[$vid]='bad_woo_parent';continue;
  }
  $old=(string)get_post_meta($vid,'mahak_id',true);
  $oldDetail=(string)get_post_meta($vid,'mahak_product_detail_id',true);
  if($old!=='' && $oldDetail!==''){$already[$vid]=1;continue;}
  if($old!=='' || $oldDetail!==''){$problems[$vid]='partially_mapped';continue;}
  $pids=$titleByNorm[normaliz($parent->post_title)]??[];
  if(count($pids)!==1){$problems[$vid]='remote_parent_matches_'.count($pids);continue;}
  $pid=$pids[0];
  $attrs=$wpdb->get_results($wpdb->prepare(
   "SELECT meta_key,meta_value FROM {$wpdb->postmeta} WHERE post_id=%d AND meta_key LIKE 'attribute%%'",$vid
  ),ARRAY_A);
  if(count($attrs)!==1){$problems[$vid]='attribute_count_'.count($attrs);continue;}
  $want=normaliz($attrs[0]['meta_value']);
  $matching=[];
  foreach(($detailByProduct[$pid]??[]) as $detail){
   $props=json_decode((string)$detail['Properties'],true);
   $values=is_array($props)?array_values(array_filter(array_map(function($v){return is_array($v)?normaliz($v['V']??''):'';},$props))):[];
   if(count($values)===1 && $values[0]===$want)$matching[]=(int)$detail['ProductDetailId'];
  }
  if(count($matching)!==1){$problems[$vid]='remote_detail_matches_'.count($matching);continue;}
  $candidates[$vid]=[(int)$post->post_parent,$pid,$matching[0]];
 }
}
echo "AUDIT_ORDER_COUNT=".count($orders)." UNIQUE_VARIABLE_VARIANTS=".count($seen)."\n";
foreach($candidates as $v=>[$parent,$pid,$did])echo "EXACT_MAPPING_CANDIDATE=".$v." PARENT=".$parent." ERP_PRODUCT=".$pid." ERP_DETAIL=".$did."\n";
foreach($problems as $v=>$why)echo "MAPPING_UNRESOLVED=".$v." REASON=".$why."\n";
echo "ALREADY_MAPPED_COUNT=".count($already)."\n";
echo "EXACT_MAPPING_CANDIDATE_COUNT=".count($candidates)."\n";
echo "MAPPING_UNRESOLVED_COUNT=".count($problems)."\n";
echo "READ_ONLY_MAPPING_AUDIT_DONE=yes\n";
