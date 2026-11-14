<?php
error_reporting(E_ERROR|E_PARSE);ini_set('display_errors','0');
$_SERVER['HTTP_HOST']='vesta-cosmetics.ir';$_SERVER['SERVER_NAME']='vesta-cosmetics.ir';$_SERVER['HTTPS']='on';$_SERVER['SERVER_PORT']='443';$_SERVER['REQUEST_URI']='/';
require '/var/www/html/wp-load.php';global $wpdb;
$rows=$wpdb->get_results("SELECT v.ID,v.post_parent FROM {$wpdb->posts} v JOIN {$wpdb->posts} p ON p.ID=v.post_parent WHERE v.post_type='product_variation' AND v.post_status='publish' AND p.post_status='publish'",ARRAY_A);
$details=array();foreach($wpdb->get_results("SELECT ProductDetailId,ProductId,Deleted FROM {$wpdb->prefix}bazara_product_details",ARRAY_A) as $d)$details[(int)$d['ProductDetailId']]=$d;
$c=array('active_variations'=>count($rows),'complete_mapping'=>0,'valid_existing_detail_pointer'=>0,'invalid_detail_pointer'=>0,'missing_mapping'=>0,'duplicate_active_detail_assignments'=>0,'sellable'=>0,'sellable_missing'=>0);
$assigned=array();
foreach($rows as $r){
 $id=(int)$r['ID'];$p=(int)get_post_meta($id,'mahak_id',true);$d=(int)get_post_meta($id,'mahak_product_detail_id',true);
 $price=get_post_meta($id,'_price',true);if($price!=='')$c['sellable']++;
 if(!$p||!$d){$c['missing_mapping']++;if($price!=='')$c['sellable_missing']++;continue;}
 $c['complete_mapping']++;$assigned[$d][]=$id;
 if(isset($details[$d])&&empty($details[$d]['Deleted'])&&(int)$details[$d]['ProductId']===$p)$c['valid_existing_detail_pointer']++;
 else $c['invalid_detail_pointer']++;
}
foreach($assigned as $ids)if(count($ids)>1)$c['duplicate_active_detail_assignments']+=count($ids);
$c['checked_at']=time();update_option('vcar_catalog_status',$c,false);
echo 'CATALOG_VALIDATION='.json_encode($c)."\n";
echo 'SIMPLE_PRODUCT_COUNTS='.json_encode($wpdb->get_results("SELECT COUNT(*) total,SUM(EXISTS(SELECT 1 FROM {$wpdb->postmeta} m WHERE m.post_id=p.ID AND m.meta_key='mahak_id' AND CAST(m.meta_value AS UNSIGNED)>0)) mapped_parent FROM {$wpdb->posts} p WHERE post_type='product' AND post_status='publish' AND NOT EXISTS(SELECT 1 FROM {$wpdb->posts} v WHERE v.post_parent=p.ID AND v.post_type='product_variation')",ARRAY_A))."\n";
