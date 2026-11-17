<?php
/**
 * One exact mapped ERP product + detail for Woo variant 101962.
 * ERP stores this variation as a separate good, not a parent+variant.
 * No product, inventory, orders, invoices, pictures, discounts or prices changed.
 */
error_reporting(E_ERROR|E_PARSE);ini_set('display_errors','0');
$_SERVER['HTTP_HOST']='vesta-cosmetics.ir';$_SERVER['SERVER_NAME']='vesta-cosmetics.ir';$_SERVER['HTTPS']='on';$_SERVER['SERVER_PORT']='443';$_SERVER['REQUEST_URI']='/';
require '/var/www/html/wp-load.php';global $wpdb;
$id=101962;$erpPid=10755482;$erpDid=12269296;
$commit=getenv('VC_101962_COMMIT')==='yes';
if($commit&&getenv('VC_101962_BACKUP_VERIFIED')!=='yes')exit(21);
function vesta_101962_norm($s){
 $s=rawurldecode((string)$s);
 $s=strtr($s,['ي'=>'ی','ك'=>'ک','آ'=>'ا','‌'=>' ','٠'=>'0','١'=>'1','٢'=>'2','٣'=>'3','٤'=>'4','٥'=>'5','٦'=>'6','٧'=>'7','٨'=>'8','٩'=>'9','۰'=>'0','۱'=>'1','۲'=>'2','۳'=>'3','۴'=>'4','۵'=>'5','۶'=>'6','۷'=>'7','۸'=>'8','۹'=>'9']);
 $s=mb_strtolower($s,'UTF-8');return preg_replace('/[^\p{L}\p{N}]+/u','',$s);
}
$v=wc_get_product($id);$post=get_post($id);
if(!$v||!$post||$post->post_type!=='product_variation'||$post->post_status!=='publish'||
 !$post->post_parent || get_post_status($post->post_parent)!=='publish')exit(22);
$used=$wpdb->get_var($wpdb->prepare("SELECT COUNT(*) FROM {$wpdb->postmeta} m JOIN {$wpdb->posts} p ON p.ID=m.post_id WHERE m.meta_key='mahak_product_detail_id' AND CAST(m.meta_value AS UNSIGNED)=%d AND p.post_status='publish'",$erpDid));
if((int)$used!==0)exit(23);
if(metadata_exists('post',$id,'mahak_id')||metadata_exists('post',$id,'mahak_product_detail_id'))exit(24);
$rp=$wpdb->get_results($wpdb->prepare("SELECT ProductId,ProductCode,ProductName FROM {$wpdb->prefix}bazara_products WHERE ProductId=%d AND Deleted=0",$erpPid),ARRAY_A);
if(count($rp)!==1)exit(25);
$codes=array_unique(array_filter([(string)$id,(string)$v->get_sku()]));
if(!in_array((string)$rp[0]['ProductCode'],$codes,true)||
 vesta_101962_norm($v->get_name())!==vesta_101962_norm($rp[0]['ProductName'])||
 vesta_101962_norm($v->get_name())===''||
 vesta_101962_norm($v->get_name())===vesta_101962_norm(wc_get_product($post->post_parent)->get_name()))exit(26);
$ds=$wpdb->get_results($wpdb->prepare("SELECT ProductId,ProductDetailId,Properties FROM {$wpdb->prefix}bazara_product_details WHERE ProductId=%d AND Deleted=0",$erpPid),ARRAY_A);
if(count($ds)!==1||(int)$ds[0]['ProductDetailId']!==$erpDid)exit(27);
$props=json_decode((string)($ds[0]['Properties']??''),true);$vals=[];
foreach(is_array($props)?$props:[] as $p)if(is_array($p)&&!empty($p['V']))$vals[]=trim((string)$p['V']);
if($vals)exit(28);
$before=['sku'=>$v->get_sku(),'name'=>$v->get_name(),'price'=>$v->get_price(),
 'stock'=>$v->get_stock_quantity(),'thumbnail'=>get_post_thumbnail_id($id),
 'gallery'=>(string)get_post_meta($id,'_product_image_gallery',true),'parent'=>(int)$post->post_parent];
echo 'ONE_EXACT_STANDALONE_VARIANT_PLAN='.json_encode(['woo_variant_id'=>$id,
 'parent_id'=>$post->post_parent,'erp_product_id'=>$erpPid,'erp_detail_id'=>$erpDid,
 'matched_code'=>(string)$rp[0]['ProductCode'],'zero_duplicate_assignments'=>true,
 'all_existing_price_stock_photo_fields_unchanged'=>true],JSON_UNESCAPED_UNICODE).PHP_EOL;
if(!$commit){echo "VARIANT_101962_DRY_RUN_NO_WRITES=yes\n";exit(0);}
$lockName='vesta_exact_mapping_variation_101962';
if((int)$wpdb->get_var($wpdb->prepare('SELECT GET_LOCK(%s,5)',$lockName))!==1)exit(29);
$added=[];
try{
 if(metadata_exists('post',$id,'mahak_id')||metadata_exists('post',$id,'mahak_product_detail_id'))exit(30);
 foreach(['mahak_id'=>(string)$erpPid,'mahak_product_detail_id'=>(string)$erpDid] as $key=>$val){
   if(!add_post_meta($id,$key,$val,true))throw new RuntimeException('mapping_write_failed');
   $added[]=[$key,$val];
 }
 $read=wc_get_product($id);
 $after=['sku'=>$read->get_sku(),'name'=>$read->get_name(),'price'=>$read->get_price(),
 'stock'=>$read->get_stock_quantity(),'thumbnail'=>get_post_thumbnail_id($id),
 'gallery'=>(string)get_post_meta($id,'_product_image_gallery',true),'parent'=>(int)get_post($id)->post_parent];
 if($before!==$after || (int)get_post_meta($id,'mahak_id',true)!==$erpPid ||
  (int)get_post_meta($id,'mahak_product_detail_id',true)!==$erpDid)throw new RuntimeException('mapping_readback_failed');
 echo "VARIANT_101962_EXACT_MAPPING_CREATED_AND_ALL_FIELDS_PRESERVED=yes\n";
}catch(Throwable $e){
 foreach(array_reverse($added) as $row)delete_post_meta($id,$row[0],$row[1]);
 echo "ONE_VARIANT_MAPPING_ROLLED_BACK_NO_REMOTE_WRITES=yes\n";exit(31);
}finally{$wpdb->get_var($wpdb->prepare('SELECT RELEASE_LOCK(%s)',$lockName));}
