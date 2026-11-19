<?php
/**
 * Safe, one-time Woo draft correction for Mahak 102941 / ProductId 10755481.
 * Repair verified ERP title and four variation prices; inventory remains untouched.
 * Dry-run default, CLI --apply only. Never writes to Mahak or orders.
 */
error_reporting(E_ERROR|E_PARSE);ini_set('display_errors','0');set_time_limit(240);
$_SERVER['HTTP_HOST']='vesta-cosmetics.ir';$_SERVER['SERVER_NAME']='vesta-cosmetics.ir';
$_SERVER['HTTPS']='on';$_SERVER['SERVER_PORT']='443';$_SERVER['REQUEST_URI']='/';
require '/var/www/html/wp-load.php';global $wpdb;
$apply=in_array('--apply',$argv??[],true);
$lock='vesta_product_102941_guarded_repair';
if((int)$wpdb->get_var($wpdb->prepare('SELECT GET_LOCK(%s,9)',$lock))!==1)
   throw new RuntimeException('102941 product repair lock unavailable');
$transaction=false;
try{
 $journalKey='vesta_102941_cloud_corrected_20261119_v1';
 $prior=get_option($journalKey,false);
 if(is_array($prior)){
   echo '102941_ALREADY_REPAIRED='.wp_json_encode($prior,JSON_UNESCAPED_UNICODE).PHP_EOL;
   echo '102941_NO_NEW_WRITES=yes'.PHP_EOL;
   exit(0);
 }
 $src=vesta_mhi_catalog();
 $matches=array_values(array_filter((array)($src['Products']??[]),fn($r)=>
     empty($r['Deleted'])&&(string)($r['ProductCode']??'')==='102941'));
 if(count($matches)!==1||(int)$matches[0]['ProductId']!==10755481)
   throw new RuntimeException('Mahak ProductCode/ProductId identity mismatch');
 $desired=trim((string)$matches[0]['Name']);
 if(vesta_catalog_identity_normalize($desired)!==vesta_catalog_identity_normalize('رژ لب جامد شیر اپ GAGK'))
   throw new RuntimeException('Unexpected ERP new title');
 $parent=wc_get_product(105592);
 if(!$parent || !$parent->is_type('variable') || $parent->get_status()!=='draft' ||
    $parent->get_sku()!=='102941' || (int)$parent->get_meta('mahak_id',true)!==10755481)
    throw new RuntimeException('Existing Woo parent is not same verified draft');
 $previous=$parent->get_name();
 if($previous!=='شیر آپ تستر دار اولی بالا' && $previous!==$desired)
    throw new RuntimeException('Parent title has changed since audit');
 $expected=[12269307=>'کد1',12269324=>'کد2',12269323=>'کد3',12269322=>'کد4'];
 $source=[];
 foreach((array)($src['ProductDetails']??[]) as $d) {
   if((int)($d['ProductId']??0)!==10755481||!empty($d['Deleted']))continue;
   $did=(int)($d['ProductDetailId']??0);
   if(!isset($expected[$did])) {
     if(($d['Properties']??null)===null)continue; // Parent/base detail Price1 not saleable variation.
     throw new RuntimeException('Unexpected active ERP variation detail '.$did);
   }
   $props=json_decode((string)($d['Properties']??''),true);
   if(!is_array($props)||count($props)!==1||
      (string)($props[0]['C']??'')!=='3' ||
      (string)($props[0]['V']??'')!==$expected[$did] ||
      (int)($d['Price1']??0)!==550000)
      throw new RuntimeException('Mahak variation code/price changed for '.$did);
   $source[$did]=$d;
 }
 if(count($source)!==4)throw new RuntimeException('Expected 4 verified cloud variations');
 $children=$parent->get_children();
 if(count($children)!==4)throw new RuntimeException('Unexpected Woo variation count');
 $changes=[];
 foreach($children as $childId) {
   $v=wc_get_product($childId);
   if(!$v || !$v->is_type('variation') || $v->get_parent_id()!==105592 ||
      $v->get_status()!=='publish' || $v->get_sale_price()!=='' ||
      !$v->get_manage_stock() || (int)$v->get_stock_quantity()!==7)
      throw new RuntimeException('Variation state changed '.$childId);
   $did=(int)$v->get_meta('mahak_product_detail_id',true);
   if(!isset($source[$did]))throw new RuntimeException('Variation detail identity mismatch '.$childId);
   $attrs=$v->get_attributes();
   $code=$expected[$did];
   if(!array_filter($attrs,fn($a)=>rawurldecode((string)$a)===$code))
      throw new RuntimeException('Variation color attribute mismatch '.$childId);
   if(!in_array((string)$v->get_regular_price(),['0','550000'],true) ||
      !in_array((string)$v->get_price(),['0','550000'],true))
      throw new RuntimeException('Variation price manually changed '.$childId);
   $t=get_post($childId);
   if(!$t||!in_array($t->post_title,[$previous.' - '.$code,$desired.' - '.$code],true))
      throw new RuntimeException('Variation title has unknown change '.$childId);
   $changes[]=['woo_variation'=>$childId,'erp_detail'=>$did,'code'=>$code,
      'old_price'=>$v->get_regular_price(),'new_price'=>550000,'stock'=>7];
 }
 echo '102941_PREFLIGHT='.wp_json_encode([
   'woo_id'=>105592,'erp_id'=>10755481,'previous_name'=>$previous,
   'new_name'=>$desired,'status'=>'draft','variations'=>$changes,
   'no_stock_changes'=>true
 ],JSON_UNESCAPED_UNICODE).PHP_EOL;
 if(!$apply){
   echo '102941_DRY_RUN_PASS=yes'.PHP_EOL;
   echo '102941_NO_WRITES=yes'.PHP_EOL;
   exit(0);
 }
 $wpdb->query('START TRANSACTION');$transaction=true;
 $parent=wc_get_product(105592);
 if(!$parent || $parent->get_name()!==$previous)
   throw new RuntimeException('Parent changed after preflight');
 $parent->set_name($desired);$parent->save();
 foreach($changes as $c) {
   $v=wc_get_product((int)$c['woo_variation']);
   if(!$v || $v->get_regular_price()!==(string)$c['old_price'] ||
      $v->get_stock_quantity()!==7)
      throw new RuntimeException('Variation changed during editing');
   $v->set_regular_price('550000');
   $v->set_price('550000');
   $v->save();
   $newTitle=$desired.' - '.$c['code'];
   $out=wp_update_post(['ID'=>$v->get_id(),'post_title'=>$newTitle],true);
   if(is_wp_error($out))throw new RuntimeException('Variation name save failed');
 }
 WC_Product_Variable::sync(105592);
 $new=wc_get_product(105592);
 if(!$new||$new->get_name()!==$desired||$new->get_status()!=='draft'||
    $new->get_sku()!=='102941'||count($new->get_children())!==4)
    throw new RuntimeException('Parent readback failure');
 foreach($changes as $c) {
   $v=wc_get_product($c['woo_variation']);
   if(!$v || (string)$v->get_regular_price()!=='550000' ||
      (string)$v->get_price()!=='550000' ||
      (int)$v->get_stock_quantity()!==7 ||
      (int)$v->get_meta('mahak_product_detail_id',true)!==$c['erp_detail']||
      get_post_field('post_title',$v->get_id())!==$desired.' - '.$c['code'])
       throw new RuntimeException('Variation readback failure '.$c['woo_variation']);
 }
 $journal=['utc'=>gmdate('c'),'woo_id'=>105592,'erp_id'=>10755481,
    'name'=>$desired,'variation_count'=>4,'price_toman'=>550000,
    'no_stock_changed'=>true,'source'=>'Mahak_Cloud_ProductId_10755481'];
 if(!add_option($journalKey,$journal,'',false))
   throw new RuntimeException('Idempotency journal conflict');
 $wpdb->query('COMMIT');$transaction=false;
 wc_delete_product_transients(105592);
 echo '102941_REPAIR_VERIFIED='.wp_json_encode($journal,JSON_UNESCAPED_UNICODE).PHP_EOL;
 echo '102941_SAFE_NAME_AND_FOUR_VARIATION_PRICES_REPAIRED=yes'.PHP_EOL;
}catch(Throwable $e){
 if($transaction)$wpdb->query('ROLLBACK');
 if(function_exists('wc_delete_product_transients'))wc_delete_product_transients(105592);
 echo '102941_REPAIR_ABORTED='.get_class($e).':'.$e->getMessage().PHP_EOL;
 exit(31);
}finally{$wpdb->get_var($wpdb->prepare('SELECT RELEASE_LOCK(%s)',$lock));}
