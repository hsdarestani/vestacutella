<?php
// Strict simple-product identity audit and optional existing-ID mapping. Never creates ERP items.
error_reporting(E_ERROR|E_PARSE);ini_set('display_errors','0');
$_SERVER['HTTP_HOST']='vesta-cosmetics.ir';$_SERVER['SERVER_NAME']='vesta-cosmetics.ir';$_SERVER['HTTPS']='on';$_SERVER['SERVER_PORT']='443';$_SERVER['REQUEST_URI']='/';
require '/var/www/html/wp-load.php';global $wpdb;
function vcas_name($s){$s=strtr(trim((string)$s),['ي'=>'ی','ك'=>'ک','‌'=>' ']);return preg_replace('/\s+/u',' ',function_exists('mb_strtolower')?mb_strtolower($s,'UTF-8'):strtolower($s));}
$api=new BazaraApi(true);$r=$api->get_all_data('',array('fromProductVersion'=>0,'fromProductDetailVersion'=>0));
if(!is_array($r)||empty($r['success']))exit(30);
$bycode=[];$products=[];$details=[];
foreach($r['message']['Products']??[] as $p)if(empty($p['Deleted'])){$bycode[(string)$p['ProductCode']][]=$p;$products[(int)$p['ProductId']]=$p;}
foreach($r['message']['ProductDetails']??[] as $d)if(empty($d['Deleted']))$details[(int)$d['ProductId']][]=$d;
$used=[];
foreach($wpdb->get_results("SELECT m.post_id,m.meta_value FROM {$wpdb->postmeta} m JOIN {$wpdb->posts} p ON p.ID=m.post_id WHERE p.post_status='publish' AND m.meta_key='mahak_product_detail_id' AND CAST(m.meta_value AS UNSIGNED)>0",ARRAY_A) as $m)$used[(int)$m['meta_value']][]=(int)$m['post_id'];
$ids=$wpdb->get_col("SELECT p.ID FROM {$wpdb->posts} p WHERE p.post_type='product' AND p.post_status='publish' AND NOT EXISTS(SELECT 1 FROM {$wpdb->posts} v WHERE v.post_parent=p.ID AND v.post_type='product_variation')");
$c=['active_sellable_simple'=>0,'complete_mapping'=>0,'existing_pointer_valid'=>0,'invalid_existing_pointer'=>0,'missing_mapping'=>0,'no_stable_parent_code'=>0,'stable_code_title_conflict'=>0,'no_single_plain_detail'=>0,'detail_collision'=>0,'existing_partial_mapping'=>0,'safe_candidates'=>0,'repaired'=>0];$plan=[];
foreach($ids as $id){
 $id=(int)$id;$o=wc_get_product($id);if(!$o||$o->get_type()!=='simple'||!$o->is_purchasable())continue;
 $c['active_sellable_simple']++;
 $p=(int)get_post_meta($id,'mahak_id',true);$d=(int)get_post_meta($id,'mahak_product_detail_id',true);
 if($p&&$d){$c['complete_mapping']++;$valid=false;foreach($details[$p]??[] as $remote)if((int)$remote['ProductDetailId']===$d)$valid=true;$c[$valid?'existing_pointer_valid':'invalid_existing_pointer']++;continue;}
 $c['missing_mapping']++;
 if(metadata_exists('post',$id,'mahak_id')||metadata_exists('post',$id,'mahak_product_detail_id')){$c['existing_partial_mapping']++;continue;}
 $candidates=[];foreach(array_unique(array_filter([(string)$id,(string)$o->get_sku()])) as $code)foreach($bycode[$code]??[] as $rp)$candidates[(int)$rp['ProductId']]=$rp;
 if(count($candidates)!==1){$c['no_stable_parent_code']++;continue;}
 $rp=reset($candidates);
 if(vcas_name($o->get_name())!==vcas_name($rp['Name']??'')){$c['stable_code_title_conflict']++;continue;}
 $ds=$details[(int)$rp['ProductId']]??[];
 if(count($ds)!==1){$c['no_single_plain_detail']++;continue;}
 $rd=$ds[0];$props=json_decode($rd['Properties']??'',true);$attrs=[];
 foreach(is_array($props)?$props:[] as $prop)if(is_array($prop)&&trim((string)($prop['V']??''))!=='')$attrs[]=$prop;
 if($attrs){$c['no_single_plain_detail']++;continue;}
 $did=(int)$rd['ProductDetailId'];if(!empty($used[$did])){$c['detail_collision']++;continue;}
 $plan[$id]=[(int)$rp['ProductId'],$did];$c['safe_candidates']++;
}
$planned=[];foreach($plan as $id=>$v)$planned[$v[1]][]=$id;
foreach($plan as $id=>$v)if(count($planned[$v[1]])!==1){unset($plan[$id]);$c['safe_candidates']--;$c['detail_collision']++;}
foreach($plan as $id=>$v)echo 'SIMPLE_SAFE_CANDIDATE='.$id.' PRODUCT='.$v[0].' DETAIL='.$v[1]."\n";
if(getenv('VCAR_SIMPLE_COMMIT')==='yes'){
 $made=[];
 try{
  foreach(array_slice($plan,0,100,true) as $id=>$v){
   foreach(['mahak_id'=>(string)$v[0],'mahak_product_detail_id'=>(string)$v[1]] as $k=>$val){
    if(metadata_exists('post',$id,$k)||!add_post_meta($id,$k,$val,true))throw new RuntimeException('concurrent_metadata_conflict');
    $made[]=[$id,$k,$val];
   }
   $c['repaired']++;
  }
 }catch(Throwable $e){foreach(array_reverse($made) as $m)delete_post_meta($m[0],$m[1],$m[2]);echo "SIMPLE_MAPPING_ROLLED_BACK=yes\n";exit(31);}
}
update_option('vcar_simple_catalog_status',$c,false);
echo 'SIMPLE_CATALOG_AUDIT='.json_encode($c)."\n";
echo 'NO_REMOTE_CATALOG_OR_STOCK_OR_PRICE_WRITES=yes'."\n";
