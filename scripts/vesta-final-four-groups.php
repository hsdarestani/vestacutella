<?php
/**
 * One-time cleanup of Vesta categories added by the Cutella transfer.
 * Usage: php -r 'include "/tmp/vesta-categories-final.php";' -- dry-run|apply
 * PHP >= 7.4. No destructive changes to existing non-imported products.
 */
if (PHP_SAPI !== 'cli') exit(2);
set_time_limit(0);
require '/var/www/html/wp-load.php';
$mode = $argv[1] ?? 'dry-run';
if (!in_array($mode,array('dry-run','apply'),true)) exit(2);
$apply=$mode==='apply';
function vcfail($msg,$code=3){fwrite(STDERR,'CATEGORY_FIX_FAILED '.$msg.PHP_EOL);exit($code);}
function vcterm($id,$name=null){
 $t=get_term((int)$id,'product_cat');
 if(!$t || is_wp_error($t))vcfail('Missing term '.$id);
 if($name!==null && $t->name!==$name)vcfail('Unexpected term name id='.$id.' name='.$t->name);
 return $t;
}
function vcdesc($id){
 $out=array((int)$id);
 foreach(get_terms(array('taxonomy'=>'product_cat','hide_empty'=>false,'parent'=>(int)$id)) as $child){
  foreach(vcdesc((int)$child->term_id) as $desc) $out[]=$desc;
 }
 return array_values(array_unique($out));
}
function vcassign($pid,$to,$remove){
 if(!get_post($pid))vcfail('Missing product '.(int)$pid);
 $added=wp_set_object_terms((int)$pid,(int)$to,'product_cat',true);
 if(is_wp_error($added))vcfail('Assign error product '.(int)$pid);
 $all=array_map('intval',wp_get_post_terms((int)$pid,'product_cat',array('fields'=>'ids')));
 if(!in_array((int)$to,$all,true))vcfail('Term not saved for '.(int)$pid);
 if($remove){
  $result=wp_remove_object_terms((int)$pid,array_values(array_unique(array_map('intval',$remove))),'product_cat');
  if(is_wp_error($result))vcfail('Detach error product '.(int)$pid);
 }
}
function vcmove($from,$to){
 if((int)$from===(int)$to)return 0;
 $objects=get_objects_in_term((int)$from,'product_cat');
 if(is_wp_error($objects))vcfail('Term objects unavailable '.(int)$from);
 $n=0;
 foreach(array_unique(array_map('intval',$objects)) as $pid){
  if(get_post_type($pid)!=='product')continue;
  vcassign($pid,$to,array((int)$from));
  $n++;
 }
 return $n;
}
function vcdel($id){
 $t=get_term((int)$id,'product_cat');
 if(!$t || is_wp_error($t))return;
 $children=get_terms(array('taxonomy'=>'product_cat','hide_empty'=>false,'parent'=>(int)$id));
 if($children)vcfail('Cannot delete populated category tree '.(int)$id);
 $ob=get_objects_in_term((int)$id,'product_cat');
 if(is_wp_error($ob)||count($ob))vcfail('Cannot delete assigned term '.(int)$id);
 $r=wp_delete_term((int)$id,'product_cat');
 if(!$r || is_wp_error($r))vcfail('Delete failed for '.(int)$id);
}
$must=array(
 946=>'اکسسوری', 1053=>'عطر و خوشبو کننده',
 1731=>'پوشاک پینترستی', 1767=>'کالاهای فانتزی و دکوری',
 1772=>'اکسسوری‌های فانتزی',1777=>'عطر و خوشبوکننده',
 1774=>'لوازم‌التحریر فانتزی',1769=>'لوازم آرایشی',
 1719=>'سرگرمی', 1783=>'خوراکی‌های کره‌ای'
);
foreach($must as $id=>$name)vcterm($id,$name);
foreach(array(1772,1777,1774,1769,1767,1783) as $id){
 if(!get_term_meta($id,'_vc_cutella_source_category_id',true))vcfail('Category not owned by import '.$id);
}
$cosmetics=array(
 101725=>946,101915=>946,102027=>946,102038=>946,
 102061=>950,102068=>950,102070=>950,
 102074=>1767,102089=>946,102109=>1767,102122=>1767,
 102139=>906,102193=>946,102206=>946,102404=>896
);
foreach($cosmetics as $pid=>$to){
 $product=get_post($pid);
 if(!$product || $product->post_type!=='product'||!get_post_meta($pid,'_vc_cutella_source_product_id',true))
  vcfail('Unrecognized imported cosmetic product '.$pid);
 vcterm($to);
}
$cosObjects=get_objects_in_term(1769,'product_cat');
foreach($cosObjects as $id)if(get_post_type($id)==='product'&&!array_key_exists((int)$id,$cosmetics))
 vcfail('Unclassified imported cosmetics product '.(int)$id);
$koreanNew=array();
foreach(vcdesc(1783) as $termid){
 $ids=get_objects_in_term($termid,'product_cat');
 if(is_wp_error($ids))vcfail('Korean term inaccessible');
 foreach($ids as $pid){
  if(get_post_type($pid)==='product' && get_post_meta($pid,'_vc_cutella_source_product_id',true))
   $koreanNew[(int)$pid]=true;
 }
}
if(count($koreanNew)>10)vcfail('Unexpected large imported Korean subset');
$menuids=array_unique(array_filter(array_map('intval',get_nav_menu_locations())));
$menuDelete=array();
foreach($menuids as $mid){
 foreach((array)wp_get_nav_menu_items($mid) as $item){
  if((string)get_post_meta((int)$item->ID,'_vc_vesta_catalog_group',true)==='1')$menuDelete[(int)$item->ID]=true;
 }
}
foreach($menuids as $mid){
 foreach((array)wp_get_nav_menu_items($mid) as $item)
  if(isset($menuDelete[(int)$item->menu_item_parent]))$menuDelete[(int)$item->ID]=true;
}
echo 'PLAN imported_cosmetics='.count($cosmetics).' cosmetics_to_existing_food_category=3'.
 ' newly_imported_korean='.count($koreanNew).
 ' stationery_tree='.count(vcdesc(1774)).' entertainment_tree='.count(vcdesc(1719)).
 ' accessory_tree='.count(vcdesc(1772)).' custom_menu_items='.count($menuDelete).PHP_EOL;
if(!$apply){echo "VESTA_CATEGORY_FINAL_DRY_RUN_OK\n";exit(0);}
foreach($cosmetics as $pid=>$termid){
 vcassign($pid,$termid,array(1769));
}
vcdel(1769);
echo "COSMETIC_IMPORT_CATEGORY_REMOVED product_count=".count($cosmetics).PHP_EOL;

// Keep the 55+ pre-existing Vesta Korean items untouched pending explicit scope confirmation.
// Remove the newly imported Korean item(s) from public sale using reversible Trash.
foreach(array_keys($koreanNew) as $pid){
 $r=wp_trash_post($pid);
 if(!$r)vcfail('Could not trash imported Korean product '.$pid);
 echo 'IMPORTED_KOREAN_PRODUCT_TRASHED id='.$pid.PHP_EOL;
}
foreach(array_reverse(vcdesc(1783)) as $termid){
 $obj=get_objects_in_term($termid,'product_cat');
 if(is_wp_error($obj))vcfail('Cannot list Korean category '.$termid);
 foreach($obj as $pid){
  // Trashed product may still retain taxonomy membership.
  $remove=wp_remove_object_terms((int)$pid,(int)$termid,'product_cat');
  if(is_wp_error($remove))vcfail('Unable to detach Korean term '.$termid.' product '.$pid);
 }
 vcdel($termid);
}
echo "IMPORTED_KOREAN_CATEGORY_REMOVED old_vesta_korean_category_preserved=yes\n";
// Merge perfume under Vesta's established "عطر و خوشبو کننده".
vcmove(1777,1053);
vcdel(1777);
echo "PERFUME_MERGED target=1053\n";
// Reparent imported accessory subcategories to existing Vesta accessory structure.
// If matching children already exist, merge them instead of making duplicates.
$accKids=get_terms(array('taxonomy'=>'product_cat','hide_empty'=>false,'parent'=>1772));
foreach($accKids as $kid){
 $existing=get_terms(array('taxonomy'=>'product_cat','hide_empty'=>false,'parent'=>946,'name'=>$kid->name));
 $target=0;
 foreach($existing as $e)if($e->name===$kid->name)$target=(int)$e->term_id;
 if($target){
  vcmove($kid->term_id,$target);
  $sub=get_terms(array('taxonomy'=>'product_cat','hide_empty'=>false,'parent'=>$kid->term_id));
  foreach($sub as $child){
   $u=wp_update_term($child->term_id,'product_cat',array('parent'=>$target));
   if(is_wp_error($u))vcfail('Nested accessory reparent failed');
  }
  vcdel($kid->term_id);
 } else {
  $u=wp_update_term($kid->term_id,'product_cat',array('parent'=>946));
  if(is_wp_error($u))vcfail('Accessory reparent failed '.$kid->term_id);
 }
}
vcmove(1772,946);
vcdel(1772);
echo "ACCESSORIES_MERGED target=946\n";
// Flat combined category: existing entertainment items and imported stationery belong
// directly to "کالاهای فانتزی و دکوری"; remove redundant category branches.
foreach(array(1774,1719) as $root){
 $desc=vcdesc($root);
 foreach($desc as $termid)vcmove($termid,1767);
 foreach(array_reverse($desc) as $termid)vcdel($termid);
 echo "DECOR_SOURCE_MERGED term=".$root." combined_target=1767\n";
}
// Remove only the navigation we created; leave original WordPress main menu intact.
foreach(array_keys($menuDelete) as $mid){
 if(get_post($mid))wp_delete_post($mid,true);
}
echo "REDUNDANT_MAIN_MENU_REMOVED count=".count($menuDelete).PHP_EOL;
// Place two new main categories directly below current Accessories (term 946 order=1).
$top=get_terms(array('taxonomy'=>'product_cat','hide_empty'=>false,'parent'=>0,'number'=>0));
foreach($top as $cat){
 $cid=(int)$cat->term_id;
 if(in_array($cid,array(1731,1767,946),true))continue;
 $order=get_term_meta($cid,'order',true);
 if($order!=='' && (int)$order>=2)update_term_meta($cid,'order',(int)$order+2);
}
update_term_meta(1731,'order',2);
update_term_meta(1767,'order',3);
echo "CATEGORY_ORDER_AFTER_ACCESSORIES pinterest=2 decor=3\n";
if(function_exists('wc_delete_product_transients'))wc_delete_product_transients();
wp_cache_flush();
if(function_exists('rocket_clean_domain'))rocket_clean_domain();
echo "VESTA_FOUR_GROUP_CATEGORY_CLEANUP_OK\n";
