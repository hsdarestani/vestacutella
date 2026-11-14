<?php
// Read-only variant code/name/properties comparison; no customer records or order writes.
error_reporting(E_ERROR|E_PARSE);ini_set('display_errors','0');
$_SERVER['HTTP_HOST']='vesta-cosmetics.ir';$_SERVER['SERVER_NAME']='vesta-cosmetics.ir';$_SERVER['HTTPS']='on';$_SERVER['SERVER_PORT']='443';$_SERVER['REQUEST_URI']='/';
require '/var/www/html/wp-load.php';
global $wpdb;
$ids=[92517,92515,70337,37188,101916,42721,37120,101962];
foreach($ids as $v) {
 $post=get_post($v);$parent=$post?get_post($post->post_parent):null;
 $meta=$wpdb->get_results($wpdb->prepare("SELECT meta_key,meta_value FROM {$wpdb->postmeta} WHERE post_id=%d AND (meta_key LIKE 'attribute%%' OR meta_key IN('_sku','mahak_id','mahak_product_detail_id'))",$v),ARRAY_A);
 echo "===== WOO_VARIATION=$v PARENT=".($post?$post->post_parent:0)." =====\n";
 echo "PARENT_TITLE=".($parent?$parent->post_title:'NO_PARENT')."\n";
 foreach($meta as $m)echo "WOO_META=".$m['meta_key']."=".str_replace(["\n","\r"],' ',(string)$m['meta_value'])."\n";
 $remote=$wpdb->get_results($wpdb->prepare("SELECT ProductId,ProductCode,ProductName,Deleted FROM {$wpdb->prefix}bazara_products WHERE ProductCode=%s OR ProductName=%s LIMIT 6",(string)($post?$post->post_parent:0),(string)($parent?$parent->post_title:'')),ARRAY_A);
 foreach($remote as $r){
  echo "BAZARA_PARENT=".json_encode($r,JSON_UNESCAPED_UNICODE)."\n";
  $details=$wpdb->get_results($wpdb->prepare("SELECT ProductDetailId,Properties,Deleted FROM {$wpdb->prefix}bazara_product_details WHERE ProductId=%d ORDER BY ProductDetailId LIMIT 50",(int)$r['ProductId']),ARRAY_A);
  foreach($details as $d)echo "BAZARA_DETAIL=".json_encode($d,JSON_UNESCAPED_UNICODE)."\n";
 }
}
echo "EIGHT_VARIATION_DISCREPANCY_READONLY_DONE=yes\n";
