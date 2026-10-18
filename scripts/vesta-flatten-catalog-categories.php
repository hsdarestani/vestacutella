<?php
/**
 * One-off flatten of imported catalog categories into Vesta's own product taxonomy.
 * Run ONLY with CLI after an independent database backup. Idempotent when root absent.
 */
if (PHP_SAPI!=='cli') exit(2);
set_time_limit(0);
require '/var/www/html/wp-load.php';
if (!function_exists('wp_update_term') || !function_exists('wc_get_products')) { fwrite(STDERR,"WP/Woo missing\n");exit(2); }
function vc_cat_abort($message){fwrite(STDERR,"CATEGORIES_ERROR ".$message."\n");exit(3);}
$root=get_term_by('slug','cutella-products','product_cat');
if (!$root) {
    echo "CATEGORIES_ALREADY_FLATTENED root_missing\n";
    exit(0);
}
$root_id=(int)$root->term_id;
$direct=get_terms(array('taxonomy'=>'product_cat','hide_empty'=>false,'parent'=>$root_id));
if (is_wp_error($direct) || count($direct)<1 || count($direct)>30) vc_cat_abort('Unexpected imported root child categories');
$top=array();
foreach ($direct as $cat) {
    $old=(int)$cat->term_id;
    // Only terms tagged by the one-time importer are eligible for structural edits.
    if (!get_term_meta($old,'_vc_cutella_source_category_id',true)) vc_cat_abort('Unowned child category '.$old);
    $same=get_terms(array('taxonomy'=>'product_cat','hide_empty'=>false,
        'parent'=>0,'name'=>$cat->name));
    if (is_wp_error($same)) vc_cat_abort('term lookup '.$cat->name);
    $matches=array();
    foreach ($same as $term) if ($term->name===$cat->name && (int)$term->term_id!==$old) $matches[]=$term;
    if (count($matches)>1) vc_cat_abort('Ambiguous existing category name '.$cat->name);
    if ($matches) {
        $target=(int)$matches[0]->term_id;
        // Preserve products and existing taxonomies; add membership before removing obsolete term.
        $objects=get_objects_in_term($old,'product_cat');
        if (is_wp_error($objects)) vc_cat_abort('Relation lookup '.$old);
        foreach ($objects as $pid) {
            $added=wp_set_object_terms((int)$pid,$target,'product_cat',true);
            if (is_wp_error($added)) vc_cat_abort('Unable to merge product relation '.$pid);
            $removed=wp_remove_object_terms((int)$pid,$old,'product_cat');
            if (is_wp_error($removed) || !$removed) vc_cat_abort('Unable to remove old category for product '.$pid);
        }
        $grandkids=get_terms(array('taxonomy'=>'product_cat','hide_empty'=>false,'parent'=>$old));
        if (is_wp_error($grandkids)) vc_cat_abort('Grandchild lookup '.$old);
        foreach ($grandkids as $child) {
            $result=wp_update_term((int)$child->term_id,'product_cat',array('parent'=>$target));
            if (is_wp_error($result)) vc_cat_abort('Unable to reparent nested category '.$child->term_id);
        }
        $deleted=wp_delete_term($old,'product_cat');
        if (!$deleted || is_wp_error($deleted)) vc_cat_abort('Unable to remove duplicate category '.$old);
        echo "CATEGORY_MERGED source=$old destination=$target name=".$cat->name."\n";
    } else {
        $target=$old;
        $result=wp_update_term($old,'product_cat',array('parent'=>0));
        if (is_wp_error($result)) vc_cat_abort('Unable to flatten '.$cat->name.' '. $result->get_error_message());
        echo "CATEGORY_PROMOTED id=$old name=".$cat->name."\n";
    }
    $top[]=$target;
}
$top=array_values(array_unique($top));
$remaining=get_terms(array('taxonomy'=>'product_cat','hide_empty'=>false,'parent'=>$root_id));
if (is_wp_error($remaining) || count($remaining)>0) vc_cat_abort('Some source children still use branded category');
$objects=get_objects_in_term($root_id,'product_cat');
if (is_wp_error($objects)) vc_cat_abort('Root relation lookup failed');
foreach($objects as $pid) {
    $removed=wp_remove_object_terms((int)$pid,$root_id,'product_cat');
    if (is_wp_error($removed)) vc_cat_abort('Unable to detach branded category from product '.(int)$pid);
}
echo "ROOT_RELATIONS_REMOVED count=".count($objects)."\n";
$menus=array_values(array_unique(array_filter(array_map('intval',get_nav_menu_locations()))));
foreach ($menus as $menu_id) {
    foreach ((array)wp_get_nav_menu_items($menu_id) as $item) {
        if (($item->object==='product_cat' && (int)$item->object_id===$root_id) ||
            (trim((string)$item->title)==='کیوتلا')) {
            wp_delete_post((int)$item->ID,true);
            echo "OLD_BRAND_MENU_REMOVED item=".$item->ID."\n";
        }
    }
}
$delete=wp_delete_term($root_id,'product_cat');
if (!$delete || is_wp_error($delete)) vc_cat_abort('Could not remove old brand category');
echo "BRANDED_CATEGORY_DELETED\n";
// The same WordPress menu ID serves desktop and mobile; add only one neutral group.
$locations=get_nav_menu_locations();
$menu_id=!empty($locations['main-menu'])?(int)$locations['main-menu']:
    (!empty($locations['mobile-menu'])?(int)$locations['mobile-menu']:0);
if (!$menu_id) vc_cat_abort('No active primary menu');
$items=(array)wp_get_nav_menu_items($menu_id);
$group_id=0;
foreach ($items as $item) {
    if ((string)get_post_meta((int)$item->ID,'_vc_vesta_catalog_group',true)==='1') {
        $group_id=(int)$item->ID; break;
    }
}
if (!$group_id) {
    $group_id=wp_update_nav_menu_item($menu_id,0,array(
        'menu-item-title'=>'دسته‌بندی محصولات',
        'menu-item-url'=>home_url('/shop/'),
        'menu-item-type'=>'custom',
        'menu-item-status'=>'publish'
    ));
    if (is_wp_error($group_id) || !$group_id) vc_cat_abort('Cannot add neutral menu group');
    update_post_meta((int)$group_id,'_vc_vesta_catalog_group','1');
}
foreach ($top as $term_id) {
    $term=get_term($term_id,'product_cat');
    if (!$term || is_wp_error($term)) vc_cat_abort('Missing promoted term '.$term_id);
    $existing_id=0;
    foreach ((array)wp_get_nav_menu_items($menu_id) as $item) {
        if ($item->object==='product_cat' && (int)$item->object_id===$term_id) {$existing_id=(int)$item->ID;break;}
    }
    // Do not move menus created by staff. Link new categories only if not already linked.
    if (!$existing_id) {
        $menu_item=wp_update_nav_menu_item($menu_id,0,array(
            'menu-item-title'=>$term->name,
            'menu-item-type'=>'taxonomy',
            'menu-item-object'=>'product_cat',
            'menu-item-object-id'=>(int)$term_id,
            'menu-item-parent-id'=>(int)$group_id,
            'menu-item-status'=>'publish'
        ));
        if (is_wp_error($menu_item)) vc_cat_abort('Menu item failed '.$term_id);
        echo "CATEGORY_MENU_ADDED name=".$term->name." id=".$menu_item."\n";
    } else echo "CATEGORY_MENU_ALREADY_PRESENT name=".$term->name."\n";
}
wp_cache_flush();
if (function_exists('rocket_clean_domain')) rocket_clean_domain();
echo "VESTA_CATEGORIES_FLATTENED_OK promoted_menu_categories=".count($top)." branded_root_removed=yes\n";
