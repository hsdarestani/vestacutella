<?php
/**
 * Cutella -> Vesta WooCommerce catalog bridge. PHP 7.4+.
 * Run inside the matching WordPress container. No passwords or HTTP API keys.
 * Export is read-only. Import stages as drafts; finalize publishes after verification.
 */
if (PHP_SAPI !== 'cli') { exit(1); }
set_time_limit(0);
ini_set('memory_limit', '768M');
require '/var/www/html/wp-load.php';
if (!function_exists('wc_get_products')) { fwrite(STDERR, "WooCommerce unavailable\n"); exit(2); }
$mode = isset($argv[1]) ? $argv[1] : '';
$path = isset($argv[2]) ? $argv[2] : '/tmp/vc-cutella-catalog.json';
function vc_fail($message, $code = 3) { fwrite(STDERR, "CATALOG_ERROR ".$message."\n"); exit($code); }
function vc_json($v) { return wp_json_encode($v, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES); }
function vc_img($id) {
    $id = (int)$id; if (!$id) return null;
    $file = get_attached_file($id);
    $uploads = wp_get_upload_dir();
    $base = realpath($uploads['basedir']);
    $real = $file ? realpath($file) : false;
    if (!$base || !$real || strpos($real, $base . DIRECTORY_SEPARATOR) !== 0) return null;
    $rel = substr($real, strlen($base) + 1);
    if (!preg_match('~\.(jpg|jpeg|png|webp|gif|avif)$~i', $rel)) return null;
    return array('id'=>$id,'relative'=>$rel);
}
function vc_export_product($p, $parent_id=0) {
    $image_ids = array();
    if ($p->get_image_id()) $image_ids[]=(int)$p->get_image_id();
    if (method_exists($p,'get_gallery_image_ids')) {
        foreach ($p->get_gallery_image_ids() as $id) $image_ids[]=(int)$id;
    }
    $images = array();
    foreach (array_unique($image_ids) as $id) {
        $image=vc_img($id); if ($image) $images[]=$image;
    }
    $record=array(
        'id'=>$p->get_id(), 'parent_id'=>$parent_id, 'type'=>$p->get_type(),
        'title'=>$p->get_name(), 'slug'=>$p->get_slug(),
        'description'=>$p->get_description(), 'short_description'=>method_exists($p,'get_short_description')?$p->get_short_description():'',
        'sku'=>$p->get_sku(), 'regular_price'=>$p->get_regular_price(), 'sale_price'=>$p->get_sale_price(),
        'sale_from'=>$p->get_date_on_sale_from() ? $p->get_date_on_sale_from()->getTimestamp() : null,
        'sale_to'=>$p->get_date_on_sale_to() ? $p->get_date_on_sale_to()->getTimestamp() : null,
        'stock_status'=>$p->get_stock_status(), 'manage_stock'=>$p->get_manage_stock(),
        'stock_quantity'=>$p->get_stock_quantity(), 'backorders'=>$p->get_backorders(),
        'sold_individually'=>$p->get_sold_individually(), 'virtual'=>$p->get_virtual(),
        'downloadable'=>$p->get_downloadable(), 'weight'=>$p->get_weight(),
        'length'=>$p->get_length(),'width'=>$p->get_width(),'height'=>$p->get_height(),
        'featured'=>$p->get_featured(),'catalog_visibility'=>$p->get_catalog_visibility(),
        'purchase_note'=>$p->get_purchase_note(), 'menu_order'=>$p->get_menu_order(),
        'images'=>$images
    );
    if ($parent_id) {
        $record['variation_attributes']=$p->get_attributes();
    } else {
        $record['categories']=array_map('intval', $p->get_category_ids());
        $record['tags']=array_values(wp_get_post_terms($p->get_id(),'product_tag',array('fields'=>'names')));
        $record['attributes']=array();
        foreach ($p->get_attributes() as $attr) {
            if (!is_object($attr) || !method_exists($attr,'get_name')) continue;
            $a=array('name'=>$attr->get_name(),'taxonomy'=>$attr->is_taxonomy(),
                'visible'=>$attr->get_visible(), 'variation'=>$attr->get_variation(),
                'position'=>$attr->get_position(), 'options'=>array());
            foreach ($attr->get_options() as $val) {
                if ($attr->is_taxonomy()) {
                    $term=is_numeric($val)?get_term((int)$val,$attr->get_name()):get_term_by('slug',(string)$val,$attr->get_name());
                    if ($term && !is_wp_error($term)) $a['options'][]=array('slug'=>$term->slug,'name'=>$term->name);
                } else {
                    $a['options'][]=(string)$val;
                }
            }
            $record['attributes'][]=$a;
        }
        $record['variations']=array();
        if ($p->is_type('variable')) {
            foreach ($p->get_children() as $child_id) {
                $child=wc_get_product($child_id);
                if (!$child || $child->get_status() !== 'publish' || $child->get_stock_status() !== 'instock') continue;
                $record['variations'][]=vc_export_product($child,$p->get_id());
            }
        }
    }
    return $record;
}
if ($mode === 'export') {
    $cats=get_terms(array('taxonomy'=>'product_cat','hide_empty'=>false));
    if (is_wp_error($cats)) vc_fail($cats->get_error_message());
    $categories=array();
    foreach ($cats as $cat) $categories[] = array(
        'id'=>(int)$cat->term_id, 'parent'=>(int)$cat->parent,
        'name'=>$cat->name, 'slug'=>$cat->slug,
        'description'=>$cat->description, 'image'=>vc_img(get_term_meta($cat->term_id,'thumbnail_id',true))
    );
    $attributes=array();
    foreach ((array)wc_get_attribute_taxonomies() as $a) {
        $attributes[]=array('name'=>$a->attribute_name,'label'=>$a->attribute_label,
            'type'=>$a->attribute_type,'order_by'=>$a->attribute_orderby,'public'=>$a->attribute_public);
    }
    $items=array(); $variants=0;
    // Query wp_posts directly: older Cutella has 112 in-stock posts without a
    // product_type taxonomy relationship; wc_get_products silently omits them.
    $source_ids=get_posts(array('post_type'=>'product','post_status'=>'publish',
        'posts_per_page'=>-1,'fields'=>'ids','orderby'=>'ID','order'=>'ASC','suppress_filters'=>true));
    foreach ($source_ids as $source_id) {
        $p=wc_get_product((int)$source_id);
        if (!$p || $p->get_stock_status() !== 'instock') continue;
        if (!in_array($p->get_type(),array('simple','variable'),true)) continue;
        $record=vc_export_product($p);
        $variants += count($record['variations']);
        $items[]=$record;
    }
    $output=array('version'=>1,'source_site'=>home_url(), 'exported_at'=>gmdate('c'),
        'currency'=>get_woocommerce_currency(),'categories'=>$categories,
        'attribute_taxonomies'=>$attributes,'products'=>$items);
    if (!file_put_contents($path,vc_json($output))) vc_fail('Cannot write catalog');
    chmod($path,0600);
    echo "EXPORT_OK products=".count($items)." variations=".$variants." categories=".count($categories)."\n";
    exit(0);
}
if (!in_array($mode,array('preflight','import','verify','finalize','rollback'),true)) vc_fail('Unsupported mode');
$data=json_decode(file_get_contents($path),true);
if (!is_array($data) || ($data['version']??0)!==1 || empty($data['products'])) vc_fail('Invalid/empty catalog JSON');
if (($data['currency']??'')!==get_woocommerce_currency()) vc_fail('Currency mismatch');
if (count($data['products'])>5000) vc_fail('Unreasonable catalog size');
$products=$data['products'];
function vc_origin_id($id,$type='product') {
    global $wpdb;
    $meta_key=$type==='variation'?'_vc_cutella_source_variation_id':'_vc_cutella_source_product_id';
    $sql=$wpdb->prepare("SELECT p.ID FROM {$wpdb->posts} p JOIN {$wpdb->postmeta} pm ON pm.post_id=p.ID AND pm.meta_key=%s AND pm.meta_value=%s WHERE p.post_type=%s AND p.post_status<>'trash' ORDER BY p.ID ASC LIMIT 1",
        $meta_key,(string)$id,$type==='variation'?'product_variation':'product');
    return (int)$wpdb->get_var($sql);
}
if ($mode === 'preflight') {
    $exists=0; $name_matches=0; $existing_names=array();
    global $wpdb;
    foreach ($products as $p) {
        if (vc_origin_id($p['id'])) { $exists++; continue; }
        $nameid=(int)$wpdb->get_var($wpdb->prepare("SELECT ID FROM {$wpdb->posts} WHERE post_type='product' AND post_status<>'trash' AND post_title=%s LIMIT 1",$p['title']));
        if ($nameid) { $name_matches++; $existing_names[]=$p['title']; }
    }
    echo "PREFLIGHT_OK products=".count($products)." already_imported=".$exists." exact_title_overlaps=".$name_matches.
        " variations=".array_sum(array_map(function($p){return count($p['variations']);},$products))."\n";
    foreach (array_slice($existing_names,0,12) as $name) echo "TITLE_OVERLAP ".mb_substr($name,0,100)."\n";
    exit(0);
}
// Keep product grids responsive without generating dozens of unused theme image variants.
function vc_catalog_sizes($sizes) {
    return array_intersect_key($sizes,array_flip(array('thumbnail','medium','woocommerce_thumbnail','woocommerce_single')));
}
add_filter('intermediate_image_sizes_advanced','vc_catalog_sizes',99,1);
function vc_ensure_image($image) {
    if (!$image || empty($image['id']) || empty($image['relative'])) return 0;
    $id=(int)$image['id'];
    global $wpdb;
    $prior=(int)$wpdb->get_var($wpdb->prepare("SELECT post_id FROM {$wpdb->postmeta} WHERE meta_key='_vc_cutella_attachment_id' AND meta_value=%s LIMIT 1",(string)$id));
    if ($prior && get_post_type($prior)==='attachment') return $prior;
    $rel=$image['relative'];
    if (strpos($rel,'..')!==false || strpos($rel,'\\')!==false || substr($rel,0,1)==='/' || !preg_match('~\.(jpg|jpeg|png|webp|gif|avif)$~i',$rel)) return 0;
    $dir=wp_get_upload_dir();
    $file=$dir['basedir'].'/cutella-import/'.$rel;
    if (!is_file($file)) { echo "MISSING_IMAGE id=$id\n"; return 0; }
    $wpfiletype=wp_check_filetype(basename($file),null);
    if (empty($wpfiletype['type'])) { echo "BAD_IMAGE_TYPE id=$id\n"; return 0; }
    $url=$dir['baseurl'].'/cutella-import/'.implode('/',array_map('rawurlencode',explode('/',$rel)));
    $aid=wp_insert_attachment(array('post_mime_type'=>$wpfiletype['type'],'post_title'=>pathinfo($file,PATHINFO_FILENAME),
        'post_status'=>'inherit','guid'=>$url),$file,0,true);
    if (is_wp_error($aid)) vc_fail('Image insert failure: '.$aid->get_error_message());
    update_post_meta($aid,'_vc_cutella_attachment_id',(string)$id);
    require_once ABSPATH.'wp-admin/includes/image.php';
    $meta=wp_generate_attachment_metadata($aid,$file);
    if (is_array($meta)) wp_update_attachment_metadata($aid,$meta);
    return (int)$aid;
}
function vc_ensure_term($catid,&$map,&$source,$root_id,$depth=0) {
    if (!$catid) return $root_id;
    if (isset($map[$catid])) return $map[$catid];
    if ($depth>20 || !isset($source[$catid])) return $root_id;
    $cat=$source[$catid]; $parent=($cat['parent']??0) ? vc_ensure_term((int)$cat['parent'],$map,$source,$root_id,$depth+1):$root_id;
    $found=get_terms(array('taxonomy'=>'product_cat','hide_empty'=>false,'parent'=>$parent,
        'name'=>$cat['name'],'number'=>100));
    $id=0;
    if (!is_wp_error($found)) {
        foreach ($found as $t) if ($t->name===$cat['name']) { $id=(int)$t->term_id; break; }
    }
    if (!$id) {
        $slug=$cat['slug'];
        $existing=get_term_by('slug',$slug,'product_cat');
        if ($existing && (int)$existing->parent!==$parent) $slug='cutella-'.$slug.'-'.$catid;
        $res=wp_insert_term($cat['name'],'product_cat',array('parent'=>$parent,'slug'=>$slug,'description'=>$cat['description']));
        if (is_wp_error($res)) vc_fail('Cannot create category '.$cat['name'].': '.$res->get_error_message());
        $id=(int)$res['term_id'];
    }
    $map[$catid]=$id;
    update_term_meta($id,'_vc_cutella_source_category_id',(string)$catid);
    if (!empty($cat['image'])) {
        $img=vc_ensure_image($cat['image']); if ($img) update_term_meta($id,'thumbnail_id',$img);
    }
    return $id;
}
function vc_ensure_taxonomy($def) {
    $slug=$def['name'];
    if (!preg_match('/^[a-z0-9_-]+$/i',$slug)) vc_fail('Unsupported attribute name '.$slug);
    $tax='pa_'.$slug;
    if (!taxonomy_exists($tax)) {
        $already=wc_attribute_taxonomy_id_by_name($slug);
        if (!$already) {
            $result=wc_create_attribute(array('name'=>$def['label'],'slug'=>$slug,
                'type'=>$def['type']?:'select','order_by'=>$def['order_by']?:'menu_order',
                'has_archives'=>!empty($def['public'])));
            if (is_wp_error($result)) vc_fail('Cannot create attribute '.$tax.': '.$result->get_error_message());
        }
        delete_transient('wc_attribute_taxonomies');
        register_taxonomy($tax,'product',array('hierarchical'=>false,'show_ui'=>true,
            'query_var'=>true,'rewrite'=>false,'labels'=>array('name'=>$def['label'])));
    }
}
function vc_apply_fields($obj,$p) {
    $obj->set_name($p['title']);
    $obj->set_description($p['description']);
    if (!$obj->is_type('variation')) $obj->set_short_description($p['short_description']);
    $obj->set_regular_price($p['regular_price']);
    $obj->set_sale_price($p['sale_price']);
    if ($p['sale_from']) $obj->set_date_on_sale_from(gmdate('Y-m-d H:i:s',(int)$p['sale_from']));
    if ($p['sale_to']) $obj->set_date_on_sale_to(gmdate('Y-m-d H:i:s',(int)$p['sale_to']));
    $obj->set_manage_stock((bool)$p['manage_stock']);
    if ($p['manage_stock'] && $p['stock_quantity']!==null) $obj->set_stock_quantity((int)$p['stock_quantity']);
    $obj->set_stock_status('instock');
    $obj->set_backorders($p['backorders']);
    $obj->set_virtual((bool)$p['virtual']);
    $obj->set_downloadable((bool)$p['downloadable']);
    $obj->set_weight($p['weight']);
    $obj->set_length($p['length']); $obj->set_width($p['width']); $obj->set_height($p['height']);
    $obj->set_menu_order((int)$p['menu_order']);
    if (!$obj->is_type('variation')) {
        $obj->set_sold_individually((bool)$p['sold_individually']);
        $obj->set_featured((bool)$p['featured']);
        $obj->set_catalog_visibility($p['catalog_visibility']);
        $obj->set_purchase_note($p['purchase_note']);
    }
    $imgs=$p['images']; if (!empty($imgs)) {
        $first=vc_ensure_image($imgs[0]); if ($first) $obj->set_image_id($first);
        if (!$obj->is_type('variation') && count($imgs)>1) {
            $gallery=array();
            foreach (array_slice($imgs,1) as $im) { $aid=vc_ensure_image($im); if ($aid) $gallery[]=$aid; }
            $obj->set_gallery_image_ids($gallery);
        }
    }
}
if ($mode === 'import') {
    // All new products remain drafts until a separate verification and finalize phase.
    $root=get_term_by('slug','cutella-products','product_cat');
    if (!$root) {
        $new=wp_insert_term('کیوتلا','product_cat',array('slug'=>'cutella-products','description'=>'محصولات کیوتلا'));
        if (is_wp_error($new)) vc_fail('Cannot create root category '.$new->get_error_message());
        $root=get_term((int)$new['term_id'],'product_cat');
    }
    $sourcecats=array(); foreach ($data['categories'] as $c) $sourcecats[(int)$c['id']]=$c;
    $map=array(); $created=0; $skipped=0; $variations=0;
    foreach ($data['attribute_taxonomies'] as $attr) vc_ensure_taxonomy($attr);
    foreach ($products as $p) {
        $sourceid=(int)$p['id'];
        $prior=vc_origin_id($sourceid);
        if ($prior && get_post_status($prior)==='publish') { $skipped++; continue; }
        if (!$prior) {
            global $wpdb;
            $same=(int)$wpdb->get_var($wpdb->prepare("SELECT ID FROM {$wpdb->posts} WHERE post_type='product' AND post_status<>'trash' AND post_title=%s LIMIT 1",$p['title']));
            if ($same) { echo "EXACT_TITLE_CONFLICT source=$sourceid destination=$same (preserved)\n"; $skipped++; continue; }
        }
        $obj=$prior ? wc_get_product($prior) : ($p['type']==='variable' ? new WC_Product_Variable():new WC_Product_Simple());
        if (!$obj) vc_fail('Unable to load imported product '.$sourceid);
        vc_apply_fields($obj,$p);
        $obj->set_status('draft');
        $categories=array((int)$root->term_id);
        foreach ($p['categories'] as $cid) $categories[]=vc_ensure_term((int)$cid,$map,$sourcecats,(int)$root->term_id);
        $obj->set_category_ids(array_unique($categories));
        if (!empty($p['tags'])) $obj->set_tag_ids(array());
        $attrs=array();
        foreach ($p['attributes'] as $a) {
            $attr=new WC_Product_Attribute();
            $attr->set_name($a['name']);
            $attr->set_position((int)$a['position']); $attr->set_visible((bool)$a['visible']);
            $attr->set_variation((bool)$a['variation']);
            $opts=array();
            if ($a['taxonomy']) {
                if (!taxonomy_exists($a['name'])) vc_fail('Attribute taxonomy missing '.$a['name']);
                foreach ($a['options'] as $option) {
                    $existing=get_term_by('slug',$option['slug'],$a['name']);
                    if (!$existing) {
                        $term=wp_insert_term($option['name'],$a['name'],array('slug'=>$option['slug']));
                        if (is_wp_error($term)) vc_fail('Attribute term '.$a['name'].': '.$term->get_error_message());
                        $opts[]=(int)$term['term_id'];
                    } else $opts[]=(int)$existing->term_id;
                }
                $attr->set_id(wc_attribute_taxonomy_id_by_name($a['name']));
            } else $opts=$a['options'];
            $attr->set_options($opts);
            $attrs[]=$attr;
        }
        $obj->set_attributes($attrs);
        if (!empty($p['sku']) && !wc_get_product_id_by_sku($p['sku'])) $obj->set_sku($p['sku']);
        $id=$obj->save();
        if (!$id) vc_fail('Cannot save source product '.$sourceid);
        update_post_meta($id,'_vc_cutella_source_product_id',(string)$sourceid);
        update_post_meta($id,'_vc_cutella_source_site','cutellashop.ir');
        if (!empty($p['tags'])) wp_set_object_terms($id,$p['tags'],'product_tag',true);
        if (!$prior) $created++;
        foreach ($p['variations'] as $v) {
            $vid=vc_origin_id((int)$v['id'],'variation');
            $var=$vid ? wc_get_product($vid) : new WC_Product_Variation();
            if (!$var) vc_fail('Cannot load variation '.$v['id']);
            $var->set_parent_id($id);
            vc_apply_fields($var,$v);
            $var->set_attributes($v['variation_attributes']);
            $var->set_status('publish');
            if (!empty($v['sku']) && !wc_get_product_id_by_sku($v['sku'])) $var->set_sku($v['sku']);
            $saved=$var->save();
            if (!$saved) vc_fail('Could not save variation '.$v['id']);
            update_post_meta($saved,'_vc_cutella_source_variation_id',(string)$v['id']);
            $variations++;
        }
        if ($p['type']==='variable') WC_Product_Variable::sync($id);
        echo "STAGED source=$sourceid destination=$id type=".$p['type']."\n";
    }
    echo "IMPORT_STAGE_OK created=$created skipped=$skipped variation_rows=$variations\n";
    exit(0);
}
$staged=0; $public=0; $missing=array();
foreach ($products as $p) {
    $id=vc_origin_id((int)$p['id']);
    if (!$id) {
        // Exact title matches are preserved instead of overwritten.
        global $wpdb;
        $same=(int)$wpdb->get_var($wpdb->prepare("SELECT ID FROM {$wpdb->posts} WHERE post_type='product' AND post_status<>'trash' AND post_title=%s LIMIT 1",$p['title']));
        if (!$same) $missing[]=$p['id'];
        continue;
    }
    $obj=wc_get_product($id);
    if (!$obj || !in_array($obj->get_status(),array('draft','publish'),true)) $missing[]=$p['id'];
    elseif ($obj->get_status()==='draft') $staged++;
    else $public++;
    if ($obj && $p['type']==='variable') {
        foreach ($p['variations'] as $v) {
            if (!vc_origin_id((int)$v['id'],'variation')) $missing[]='variation:'.$v['id'];
        }
    }
}
if ($missing) vc_fail('Missing imports: '.implode(',',array_slice($missing,0,30)),7);
if ($mode==='rollback') {
    $reverted=0;
    foreach ($products as $p) {
        $id=vc_origin_id((int)$p['id']);
        if (!$id || get_post_status($id)!=='publish') continue;
        $obj=wc_get_product($id);
        $obj->set_status('draft');
        $obj->save();
        $reverted++;
    }
    echo "ROLLED_BACK_TO_DRAFT count=$reverted\n";
    exit(0);
}
if ($mode==='verify') {
    echo "VERIFY_OK staged=$staged published=$public source_products=".count($products)."\n";
    exit(0);
}
if ($mode==='finalize') {
    $published=0;
    foreach ($products as $p) {
        $id=vc_origin_id((int)$p['id']);
        if (!$id) continue;
        if (get_post_status($id)==='draft') {
            $obj=wc_get_product($id);
            $obj->set_status('publish'); $obj->save(); $published++;
        }
    }
    // Add a single navigable Cutella link only if the active main menu is known.
    $root=get_term_by('slug','cutella-products','product_cat');
    $locations=get_nav_menu_locations(); $menu_id=0;
    foreach (array('main-menu','primary','main_menu','menu-primary','header-menu') as $loc) {
        if (!empty($locations[$loc])) { $menu_id=(int)$locations[$loc]; break; }
    }
    if ($menu_id && $root) {
        $present=false;
        foreach ((array)wp_get_nav_menu_items($menu_id) as $item) {
            if ($item->object==='product_cat' && (int)$item->object_id===(int)$root->term_id) $present=true;
        }
        if (!$present) {
            $menuitem=wp_update_nav_menu_item($menu_id,0,array(
                'menu-item-title'=>'کیوتلا','menu-item-object'=>'product_cat',
                'menu-item-object-id'=>(int)$root->term_id,'menu-item-type'=>'taxonomy',
                'menu-item-status'=>'publish'));
            if (is_wp_error($menuitem)) echo "MENU_INSERT_WARNING ".$menuitem->get_error_message()."\n";
            else echo "MENU_INSERTED id=$menuitem\n";
        }
    } else echo "MENU_NOT_CONFIGURED site categories still browseable\n";
    if (function_exists('wc_delete_product_transients')) wc_delete_product_transients();
    echo "FINALIZE_OK newly_published=$published site_products=".count($products)." category_url=".($root?get_term_link($root):'missing')."\n";
}
