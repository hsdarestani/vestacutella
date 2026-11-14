<?php
// No product creation. Assess additional stable SKU/barcode identities and archived records.
error_reporting(E_ERROR|E_PARSE);ini_set('display_errors','0');
$_SERVER['HTTP_HOST']='vesta-cosmetics.ir';$_SERVER['SERVER_NAME']='vesta-cosmetics.ir';$_SERVER['HTTPS']='on';$_SERVER['SERVER_PORT']='443';$_SERVER['REQUEST_URI']='/';
require '/var/www/html/wp-load.php';global $wpdb;
$api=new BazaraApi(true);$r=$api->get_all_data('',array('fromProductVersion'=>0,'fromProductDetailVersion'=>0));
if(!is_array($r)||empty($r['success']))exit(30);
$pcode=[];$pids=[];$barcodes=[];$clientids=[];
foreach($r['message']['Products']??[] as $p)if(empty($p['Deleted'])){$pcode[(string)$p['ProductCode']][]=$p;$pids[(int)$p['ProductId']]=$p;}
foreach($r['message']['ProductDetails']??[] as $d)if(empty($d['Deleted'])){
 if(trim((string)($d['Barcode']??''))!=='')$barcodes[trim((string)$d['Barcode'])][]=$d;
 if((int)($d['ProductDetailClientId']??0)>0)$clientids[(int)$d['ProductDetailClientId']][]=$d;
}
$rows=$wpdb->get_results("SELECT v.ID,v.post_parent FROM {$wpdb->posts} v JOIN {$wpdb->posts} p ON p.ID=v.post_parent WHERE v.post_type='product_variation' AND v.post_status='publish' AND p.post_status='publish'",ARRAY_A);
$stats=['unmapped'=>0,'parent_sku_code_unique'=>0,'variation_sku_barcode_unique'=>0,'stable_parent_and_barcode'=>0,'detail_client_id_match'=>0,'mapped_identity_by_parent_code'=>0,'mapped_identity_requires_review'=>0];
foreach($rows as $v){
 $id=(int)$v['ID'];$parent=(int)$v['post_parent'];$pid=(int)get_post_meta($id,'mahak_id',true);$did=(int)get_post_meta($id,'mahak_product_detail_id',true);
 $psku=(string)get_post_meta($parent,'_sku',true);$sku=(string)get_post_meta($id,'_sku',true);
 if($pid&&$did){
  $remote=$pids[$pid]??[];$code=(string)($remote['ProductCode']??'');
  if($code===(string)$parent||($psku!==''&&$code===$psku))$stats['mapped_identity_by_parent_code']++;
  else $stats['mapped_identity_requires_review']++;
  continue;
 }
 $stats['unmapped']++;
 $parents=$psku!==''?($pcode[$psku]??[]):[];$details=$sku!==''?($barcodes[$sku]??[]):[];
 if(count($parents)===1)$stats['parent_sku_code_unique']++;
 if(count($details)===1)$stats['variation_sku_barcode_unique']++;
 if(count($clientids[$id]??[])===1)$stats['detail_client_id_match']++;
 if(count($parents)===1&&count($details)===1&&(int)$parents[0]['ProductId']===(int)$details[0]['ProductId']){
  $stats['stable_parent_and_barcode']++;echo 'STABLE_SKU_CANDIDATE='.$id.' PRODUCT='.(int)$parents[0]['ProductId'].' DETAIL='.(int)$details[0]['ProductDetailId']."\n";
 }
}
echo 'STABLE_IDENTITY_AUDIT='.json_encode($stats)."\n";
echo 'ARCHIVED_VARIATION_STATUS='.json_encode($wpdb->get_results("SELECT p.post_status parent_status,COUNT(*) n FROM {$wpdb->posts} v JOIN {$wpdb->posts} p ON p.ID=v.post_parent WHERE v.post_type='product_variation' AND v.post_status='publish' AND p.post_status<>'publish' GROUP BY p.post_status",ARRAY_A))."\n";
echo 'ACTIVE_SIMPLE_SELLABLE='.json_encode($wpdb->get_results("SELECT p.ID,EXISTS(SELECT 1 FROM {$wpdb->postmeta} m WHERE m.post_id=p.ID AND m.meta_key='mahak_id' AND CAST(m.meta_value AS UNSIGNED)>0) parent_mapping,EXISTS(SELECT 1 FROM {$wpdb->postmeta} m WHERE m.post_id=p.ID AND m.meta_key='mahak_product_detail_id' AND CAST(m.meta_value AS UNSIGNED)>0) detail_mapping FROM {$wpdb->posts} p WHERE p.post_type='product' AND p.post_status='publish' AND NOT EXISTS(SELECT 1 FROM {$wpdb->posts} v WHERE v.post_parent=p.ID AND v.post_type='product_variation') AND EXISTS(SELECT 1 FROM {$wpdb->postmeta} m WHERE m.post_id=p.ID AND m.meta_key='_price' AND m.meta_value<>'')",ARRAY_A))."\n";
$pending=[];foreach($wpdb->get_col("SELECT option_name FROM {$wpdb->options} WHERE option_name LIKE 'vmb_req_%' LIMIT 1000") as $key){$record=get_option($key);if(is_array($record)){$state=$record['status']??'unknown';$pending[$state]=($pending[$state]??0)+1;}}
echo 'PENDING_PRODUCT_REQUESTS='.json_encode($pending)."\n";
echo "NO_CATALOG_WRITES=yes\n";
