<?php
/**
 * Fix the ACTUAL Woodmart mobile category menu, id 45, not site pages menu 1757.
 * Insert existing Vesta categories immediately below Accessories (946).
 * CLI modes: dry-run, apply, verify. Does not change products or taxonomy.
 */
if (PHP_SAPI!=='cli') exit(2);
set_time_limit(0);
require '/var/www/html/wp-load.php';
$mode=$argv[1]??'dry-run';
if(!in_array($mode,array('dry-run','apply','verify'),true))exit(2);
function vmfail($message){fwrite(STDERR,"MENU_REPAIR_ERROR ".$message.PHP_EOL);exit(3);}
$menu=wp_get_nav_menu_object(45);
if (!$menu || is_wp_error($menu) || strpos($menu->name,'دسته بندی محصولات')===false) vmfail('Unexpected Woodmart category menu');
$wanted=array(1731=>'پوشاک پینترستی',1767=>'کالاهای فانتزی و دکوری');
foreach($wanted as $id=>$name){
    $term=get_term((int)$id,'product_cat');
    if(!$term || is_wp_error($term) || $term->name!==$name || (int)$term->parent!==0)vmfail('Missing/renamed category '.$id);
    if((int)$term->count<1)vmfail('Target category has no WooCommerce products '.$id);
}
$items=wp_get_nav_menu_items(45,array('post_status'=>'publish','orderby'=>'menu_order','order'=>'ASC'));
if(!is_array($items) || count($items)<90)vmfail('Unexpected category menu size');
$acc=null;$existing=array();
foreach($items as $i){
    if($i->object==='product_cat' && (int)$i->object_id===946 && (int)$i->menu_item_parent===0){
        if($acc)vmfail('Duplicate top-level Accessories menu item');
        $acc=$i;
    }
    foreach($wanted as $tid=>$name)if($i->object==='product_cat' && (int)$i->object_id===(int)$tid){
        if(isset($existing[$tid]))vmfail('Duplicate new category menu item '.$tid);
        $existing[$tid]=$i;
    }
}
if(!$acc)vmfail('Accessories menu entry not found');
$root_names=array();
$acc_idx=-1;
foreach($items as $j=>$i){
  if((int)$i->menu_item_parent===0)$root_names[]=$i->title;
  if((int)$i->ID===(int)$acc->ID)$acc_idx=$j;
}
if($acc_idx<0)vmfail('Accessories index missing');
echo "CATEGORY_MENU_PLAN id=45 name=".$menu->name." current_items=".count($items)." accessories_item=".$acc->ID.
   " targets_present=".count($existing)." root_order=".implode(' | ',$root_names).PHP_EOL;
if($mode==='dry-run') { echo "CATEGORY_MENU_DRY_RUN_OK\n";exit(0); }
if($mode==='apply'){
    foreach($wanted as $term_id=>$title){
        if(isset($existing[$term_id]))continue;
        $id=wp_update_nav_menu_item(45,0,array(
            'menu-item-title'=>$title,
            'menu-item-type'=>'taxonomy',
            'menu-item-object'=>'product_cat',
            'menu-item-object-id'=>(int)$term_id,
            'menu-item-parent-id'=>0,
            'menu-item-status'=>'publish'
        ));
        if(is_wp_error($id)||!$id)vmfail('Unable to insert category '.$term_id);
        echo "CATEGORY_MENU_ITEM_CREATED term=$term_id item=$id\n";
    }
    // Preserve every existing category and subcategory order, inserting two
    // top-level items after the Accessories subtree, ahead of next top-level item.
    $items=wp_get_nav_menu_items(45,array('post_status'=>'publish','orderby'=>'menu_order','order'=>'ASC'));
    $target_ids=array(); $others=array();
    foreach($items as $i){
        if($i->object==='product_cat' && (int)$i->menu_item_parent===0 &&
             array_key_exists((int)$i->object_id,$wanted)){
           $target_ids[(int)$i->object_id]=(int)$i->ID;
        }else $others[]=$i;
    }
    if(count($target_ids)!==2)vmfail('Cannot resolve both category menu entries');
    $output=array();$sawAcc=false;$inserted=false;
    foreach($others as $i){
       if($sawAcc && !$inserted && (int)$i->menu_item_parent===0){
          foreach(array_keys($wanted) as $term_id)$output[]=$target_ids[$term_id];
          $inserted=true;
       }
       $output[]=(int)$i->ID;
       if((int)$i->ID===(int)$acc->ID)$sawAcc=true;
    }
    if(!$sawAcc)vmfail('Accessories lost while updating');
    if(!$inserted)foreach(array_keys($wanted) as $term_id)$output[]=$target_ids[$term_id];
    if(count($output)!==count($items)||count(array_unique($output))!==count($items))vmfail('Invalid reordered menu');
    $position=1;
    foreach($output as $id){
       $post=get_post((int)$id);
       if(!$post || $post->post_type!=='nav_menu_item')vmfail('Missing nav item '.$id);
       if((int)$post->menu_order!==$position) {
           $updated=wp_update_post(array('ID'=>$id,'menu_order'=>$position),true);
           if(is_wp_error($updated)||!$updated)vmfail('Failed menu position for '.$id);
       }
       $position++;
    }
    wp_cache_flush();
    if(function_exists('rocket_clean_domain'))rocket_clean_domain();
    if(function_exists('woodmart_clear_cache'))woodmart_clear_cache();
    echo "CATEGORY_MENU_ORDER_APPLIED items=".count($output)."\n";
}
$after=wp_get_nav_menu_items(45,array('post_status'=>'publish','orderby'=>'menu_order','order'=>'ASC'));
if(!is_array($after))vmfail('Cannot reload menu');
$roots=array();
foreach($after as $i)if((int)$i->menu_item_parent===0)$roots[]=$i;
$sequence=array();
foreach($roots as $r)$sequence[]=(int)$r->object_id;
$accPos=array_search(946,$sequence,true);
if($accPos===false||array_slice($sequence,$accPos+1,2)!==array(1731,1767))
  vmfail('Both categories are not immediately after Accessories');
$seen=array();
foreach($roots as $i)foreach($wanted as $term_id=>$title)
 if($i->object==='product_cat' && (int)$i->object_id===(int)$term_id)$seen[$term_id]=get_term_link((int)$term_id,'product_cat');
if(count($seen)!==2)vmfail('Missing published top-level category menu links');
echo "CATEGORY_MENU_VERIFIED accessories_then_pinterest_then_decor=yes order=".implode(' | ',array_map(function($r){return $r->title;},$roots)).PHP_EOL;
foreach($seen as $tid=>$url)echo "CATEGORY_MENU_LIVE_LINK term=$tid url=$url\n";
echo "WOODMART_CATEGORIES_MENU_FIXED_OK\n";
