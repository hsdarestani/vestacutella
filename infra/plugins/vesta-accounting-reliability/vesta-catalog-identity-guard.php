<?php
/**
 * Plugin Name: Vesta — Mahak/Bazara catalog identity safety guard
 * Description: Refuses unsafe SKU-to-good mappings and protects existing Woo records.
 * Version: 1.0.0
 */
if (!defined('ABSPATH')) exit;

function vesta_catalog_identity_normalize($s) {
    $s=strtr((string)$s,[
      'ي'=>'ی','ك'=>'ک','آ'=>'ا','‌'=>' ',
      '٠'=>'0','١'=>'1','٢'=>'2','٣'=>'3','٤'=>'4','٥'=>'5','٦'=>'6','٧'=>'7','٨'=>'8','٩'=>'9',
      '۰'=>'0','۱'=>'1','۲'=>'2','۳'=>'3','۴'=>'4','۵'=>'5','۶'=>'6','۷'=>'7','۸'=>'8','۹'=>'9'
    ]);
    return preg_replace('/[^\p{L}\p{N}]+/u','',mb_strtolower($s,'UTF-8'));
}
function vesta_catalog_bazara_policy(array $args) {
    global $wpdb;
    $code=trim((string)($args['ProductCode']??''));
    $goodId=(int)($args['ProductId']??0);
    $sourceName=(string)($args['name']??'');
    $norm=vesta_catalog_identity_normalize($sourceName);
    $blocked=function($reason){return ['allow'=>false,'reason'=>$reason];};
    if (!$code||$goodId<=0||mb_strlen($norm)<4) return $blocked('invalid_source_identity');
    if (get_option('vesta_catalog_emergency_off',false)) return $blocked('maintenance_pause');
    if (!function_exists('wc_get_product')) return $blocked('woocommerce_not_ready');
    $holders=$wpdb->get_col($wpdb->prepare(
      "SELECT DISTINCT p.ID FROM {$wpdb->posts} p
       JOIN {$wpdb->postmeta} m ON m.post_id=p.ID
       WHERE p.post_type IN ('product','product_variation')
         AND p.post_status IN ('publish','draft','private')
         AND m.meta_key='_sku' AND m.meta_value=%s ORDER BY p.ID",$code));
    if(count($holders)>1)return $blocked('duplicate_sku_holders');
    if(count($holders)===1){
        $id=(int)$holders[0];$item=wc_get_product($id);
        if(!$item)return $blocked('sku_holder_unavailable');
        if($item->is_type('variation')) {
            // Mahak product with details is a parent-level good, never a nested independent good.
            if(!empty($args['vars'])||($args['type']??'')==='variable')
                return $blocked('nested_variant_product_code');
            $parent=wc_get_product($item->get_parent_id());
            if(!$parent)return $blocked('variation_parent_absent');
            $wooName=$parent->get_name();
        } else $wooName=$item->get_name();
        if(vesta_catalog_identity_normalize($wooName)!==$norm)
            return $blocked('sku_points_to_different_named_good');
        $bound=(int)$item->get_meta('mahak_id',true);
        if($bound>0&&$bound!==$goodId)return $blocked('sku_owned_by_different_erp_product');
        // Do not write to a draft copy while the identical canonical site product is published.
        if(get_post_status($id)==='draft'&&ctype_digit($code)){
            $canonical=get_post((int)$code);
            if($canonical && (int)$canonical->ID!==$id &&
               $canonical->post_type==='product' && $canonical->post_status==='publish' &&
               vesta_catalog_identity_normalize($canonical->post_title)===$norm)
                return $blocked('draft_owns_published_parent_code');
        }
        $attached=get_posts([
          'post_type'=>'product','post_status'=>['publish','private','draft'],
          'meta_key'=>'mahak_id','meta_value'=>(string)$goodId,
          'fields'=>'ids','posts_per_page'=>10,'suppress_filters'=>true
        ]);
        foreach($attached as $otherId)if((int)$otherId!==$id)
            return $blocked('erp_id_bound_to_other_woo_parent');
        return ['allow'=>true,'reason'=>'unique_sku_name_and_erp_id'];
    }
    // No exact raw SKU: never create a second product when the original published
    // WordPress product ID is already the Mahak ProductCode with the correct name.
    if(ctype_digit($code)){
        $canonical=get_post((int)$code);
        if($canonical && $canonical->post_type==='product' &&
           $canonical->post_status==='publish' &&
           vesta_catalog_identity_normalize($canonical->post_title)===$norm)
           return $blocked('published_woo_parent_missing_sku');
    }
    $attached=get_posts([
       'post_type'=>'product','post_status'=>['publish','private','draft'],
       'meta_key'=>'mahak_id','meta_value'=>(string)$goodId,
       'fields'=>'ids','posts_per_page'=>10,'suppress_filters'=>true
    ]);
    if(count($attached)>1)return $blocked('erp_id_has_multiple_woo_parents');
    if(count($attached)===1){
       $old=wc_get_product((int)$attached[0]);
       if(!$old) return $blocked('erp_fallback_missing');
       if(vesta_catalog_identity_normalize($old->get_name())!==$norm)
          return $blocked('erp_fallback_name_mismatch');
       if($old->get_sku()!=='' && $old->get_sku()!==$code)
          return $blocked('erp_fallback_conflicting_sku');
       return ['allow'=>true,'reason'=>'verified_erp_fallback'];
    }
    // Brand-new goods may be created as non-purchasable drafts by the vendor.
    return ['allow'=>true,'reason'=>'new_good_no_existing_woo_identity'];
}
