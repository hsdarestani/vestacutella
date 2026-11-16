<?php
/**
 * Plugin Name: Vesta Mahak Image Preservation Gate
 * Description: Prevents enabling destructive Bazara photo synchronization when the reviewed media-preservation patch is absent.
 * Version: 1.0.0
 */
if (!defined('ABSPATH')) exit;

function vesta_bazara_image_patch_verified() {
    static $checked = null;
    if ($checked !== null) return $checked;
    $base = WP_PLUGIN_DIR . '/bazara/classes/';
    $api = @file_get_contents($base.'class.bazara.api.php');
    $table = @file_get_contents($base.'class.products.table.php');
    if (!is_string($api) || !is_string($table)) return $checked=false;
    $marker='VESTA_KEEP_WOO_IMAGES_20261116';
    if (strpos($api,$marker)===false || strpos($table,$marker)===false) return $checked=false;
    $begin=strpos($api,'public function sync_pictures()');
    if ($begin===false) return $checked=false;
    $next=strpos($api,'public function ', $begin+30);
    $body=substr($api,$begin,$next===false?null:$next-$begin);
    if (strpos($body,"set_image_id('')")!==false ||
        strpos($body,'set_gallery_image_ids(array())')!==false ||
        strpos($body,'wp_delete_attachment(')!==false ||
        strpos($body,"if (\$first_image && !\$objProduct->get_image_id()) {")===false) return $checked=false;
    $start=strpos($table,'function delete_product_images_by_sku($sku)');
    $end=$start===false?false:strpos($table,'}', $start);
    $deleteBlock=$start===false||$end===false?'':substr($table,$start,$end-$start+1);
    if(strpos($deleteBlock,'return false;')===false ||
       strpos($deleteBlock,'wp_delete_attachment(')!==false) return $checked=false;
    return $checked=true;
}
function vesta_bazara_disable_unsafe_images() {
    if (vesta_bazara_image_patch_verified()) return false;
    $o = get_option('bazara_visitor_settings', array());
    if (!is_array($o) || empty($o['chkPicture'])) return false;
    $o['chkPicture']='';
    update_option('bazara_visitor_settings',$o,false);
    error_log('VESTA_BAZARA_IMAGE_SYNC_DISABLED_MISSING_SAFE_PATCH');
    return true;
}
add_filter('pre_update_option_bazara_visitor_settings', function($new,$old) {
    if (!is_array($new) || empty($new['chkPicture'])) return $new;
    if (vesta_bazara_image_patch_verified()) return $new;
    $new['chkPicture']='';
    error_log('VESTA_BAZARA_IMAGE_SYNC_ENABLE_BLOCKED_VENDOR_PATCH_MISSING');
    return $new;
}, 10, 2);
add_action('init','vesta_bazara_disable_unsafe_images',1);
add_action('upgrader_process_complete','vesta_bazara_disable_unsafe_images',20,0);
add_action('admin_notices',function(){
    if (!current_user_can('manage_woocommerce') || vesta_bazara_image_patch_verified()) return;
    echo '<div class="notice notice-error"><p>وستا: به‌دلیل حذف محافظ تصاویر در افزونه بازارا، سینک تصاویر محک غیرفعال نگه داشته شده است. قبل از فعال‌کردن، اصلاح محافظ تصاویر را دوباره بررسی کنید.</p></div>';
});
