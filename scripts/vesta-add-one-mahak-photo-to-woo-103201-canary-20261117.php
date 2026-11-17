<?php
/**
 * Single-photo canary. Image 1887347 belongs to ERP good 10755477 which
 * uniquely maps to Woo 103201. Only append a downloaded JPEG to its gallery.
 * The existing featured photo, all existing gallery items, prices, stock,
 * customers, orders, vendor picture-status and global picture-sync option
 * are left unchanged. No bulk import. Dry-run unless backed up opt-in.
 */
error_reporting(E_ERROR|E_PARSE);ini_set('display_errors','0');
$_SERVER['HTTP_HOST']='vesta-cosmetics.ir';$_SERVER['SERVER_NAME']='vesta-cosmetics.ir';$_SERVER['HTTPS']='on';$_SERVER['SERVER_PORT']='443';$_SERVER['REQUEST_URI']='/';
require '/var/www/html/wp-load.php';
global $wpdb;
$woo=103201;$erp=10755477;$pictureId=1887347;
$commit=getenv('VC_IMAGE_ONE_COMMIT')==='yes';
if($commit&&getenv('VC_IMAGE_ONE_BACKUP_VERIFIED')!=='yes')exit(11);
if(!function_exists('vesta_bazara_image_patch_verified')||!vesta_bazara_image_patch_verified())exit(12);
$settings=get_option('bazara_visitor_settings',[]);
if(!is_array($settings)||!empty($settings['chkPicture']))exit(13);
$p=wc_get_product($woo);if(!$p||!$p->get_image_id()||
 (int)get_post_meta($woo,'mahak_id',true)!==$erp||
 (int)get_post_meta($woo,'mahak_product_detail_id',true)<=0)exit(14);
$picture=$wpdb->get_row($wpdb->prepare(
 "SELECT * FROM {$wpdb->prefix}bazara_pictures WHERE PictureId=%d AND Deleted=0",$pictureId),ARRAY_A);
$relation=$wpdb->get_results($wpdb->prepare(
 "SELECT ItemCode FROM {$wpdb->prefix}bazara_photo_gallery WHERE PictureId=%d AND Deleted=0",$pictureId),ARRAY_A);
if(!$picture||count($relation)!==1||(int)$relation[0]['ItemCode']!==$erp)exit(15);
$existing=$wpdb->get_col($wpdb->prepare(
 "SELECT post_id FROM {$wpdb->postmeta} WHERE meta_key='mahak_picture_id' AND meta_value=%s",(string)$pictureId));
if($existing){echo 'MAHAK_CANARY_PICTURE_ALREADY_IN_WOO_NO_NEW_IMPORT=yes'.PHP_EOL;exit(0);}
$code=@file_get_contents(WP_PLUGIN_DIR.'/bazara/classes/class.bazara.api.php');
if(!is_string($code)||
 !preg_match('/\$img_url\s*=\s*[\x27\x22]([^\x27\x22]+)[\x27\x22]\s*;/',$code,$matched))exit(16);
$base=$matched[1];$filename=basename((string)$picture['Url']);
if(!$filename||!preg_match('/\.(jpe?g)$/i',$filename))exit(17);
$url=rtrim($base,'/').'/'.$filename;
$parts=wp_parse_url($url);
if(!$parts || strtolower((string)($parts['scheme']??''))!=='https' || empty($parts['host'])||
 !filter_var((string)$parts['host'],FILTER_VALIDATE_DOMAIN,FILTER_FLAG_HOSTNAME))exit(18);
$head=wp_safe_remote_head($url,['timeout'=>20,'redirection'=>2,'sslverify'=>true]);
if(is_wp_error($head)||(int)wp_remote_retrieve_response_code($head)!==200||
 stripos((string)wp_remote_retrieve_header($head,'content-type'),'image/jpeg')!==0)exit(19);
$len=(int)wp_remote_retrieve_header($head,'content-length');
if($len>12000000)exit(20);
$priorGallery=$p->get_gallery_image_ids();$priorFeatured=(int)$p->get_image_id();
$prior=['price'=>$p->get_price(),'stock'=>$p->get_stock_quantity(),
        'sku'=>$p->get_sku(),'name'=>$p->get_name(),
        'featured'=>$priorFeatured,'gallery'=>$priorGallery];
echo 'MAHAK_ONE_PHOTO_CANARY_PLAN='.json_encode([
 'woo_product'=>$woo,'erp_product'=>$erp,'erp_picture_id'=>$pictureId,
 'existing_featured_unchanged'=>$priorFeatured,'existing_gallery_count'=>count($priorGallery),
 'source_http_200'=>true,'source_type'=>'image/jpeg','remote_bytes'=>$len,
 'append_to_gallery_only'=>true],JSON_UNESCAPED_UNICODE).PHP_EOL;
if(!$commit){echo "ONE_MAHAK_PHOTO_CANARY_DRYRUN_NO_WRITES=yes".PHP_EOL;exit(0);}
$lock='vesta_exact_image_1887347_woo_103201';
if((int)$wpdb->get_var($wpdb->prepare('SELECT GET_LOCK(%s,10)',$lock))!==1)exit(22);
$newId=0;$tmp='';$canaryError='';
try{
 $current=wc_get_product($woo);
 if(!$current ||(int)$current->get_image_id()!==$priorFeatured||
   $current->get_gallery_image_ids()!==$priorGallery||
   (int)$wpdb->get_var($wpdb->prepare("SELECT COUNT(*) FROM {$wpdb->postmeta} WHERE meta_key='mahak_picture_id' AND meta_value=%s",(string)$pictureId))!==0)throw new RuntimeException('canary_guard_23');
 require_once ABSPATH.'wp-admin/includes/file.php';
 require_once ABSPATH.'wp-admin/includes/media.php';
 require_once ABSPATH.'wp-admin/includes/image.php';
 $tmp=download_url($url,25);
 if(is_wp_error($tmp))throw new RuntimeException('canary_guard_24');
 $size=@filesize($tmp);$meta=@getimagesize($tmp);
 if(!$size || $size>12000000 || !is_array($meta) ||
    (int)($meta[2]??0)!==IMAGETYPE_JPEG)throw new RuntimeException('canary_guard_25');
 // Core image sideload adds an attachment. It never touches old media.
 $newId=media_handle_sideload(['name'=>$filename,'tmp_name'=>$tmp],$woo,
    'Single safely linked Mahak picture '.$pictureId);
 if(is_wp_error($newId)){$newId=0;throw new RuntimeException('canary_guard_26');}
 $tmp='';
 if(get_post_mime_type($newId)!=='image/jpeg')throw new RuntimeException('canary_guard_27');
 add_post_meta($newId,'mahak_picture_id',(string)$pictureId,true);
 add_post_meta($newId,'_vesta_canary_image_imported_at',gmdate('c'),true);
 $current=wc_get_product($woo);
 if((int)$current->get_image_id()!==$priorFeatured||
    $current->get_gallery_image_ids()!==$priorGallery)throw new RuntimeException('canary_guard_28');
 $current->set_gallery_image_ids(array_values(array_unique(array_merge($priorGallery,[(int)$newId]))));
 $current->save();
 $after=wc_get_product($woo);
 if(!$after || (int)$after->get_image_id()!==$priorFeatured||
   $after->get_gallery_image_ids()!==array_values(array_unique(array_merge($priorGallery,[(int)$newId])))||
   [$after->get_price(),$after->get_stock_quantity(),$after->get_sku(),$after->get_name()]!==
   [$prior['price'],$prior['stock'],$prior['sku'],$prior['name']])throw new RuntimeException('canary_guard_29');
 echo 'MAHAK_ONE_PICTURE_1887347_IMPORTED_TO_WOO_103201_GALLERY_ATTACHMENT='.(int)$newId.PHP_EOL;
 echo 'FEATURED_AND_ALL_EXISTING_GALLERY_PRICE_STOCK_FIELDS_UNCHANGED=yes'.PHP_EOL;
 $newId=0; // Ownership transferred to safely verified Woo gallery
}catch(Throwable $e){$canaryError=get_class($e);}
finally{
 if($tmp&&is_string($tmp)&&file_exists($tmp))@unlink($tmp);
 if($newId){
   $current=wc_get_product($woo);
   if($current){
     $current->set_gallery_image_ids($priorGallery);
     $current->save();
   }
   wp_delete_attachment($newId,true); // only the new canary attachment
   echo 'FAILED_CANARY_NEW_ATTACHMENT_ROLLED_BACK_EXISTING_PHOTOS_PRESERVED=yes'.PHP_EOL;
 }
 $wpdb->get_var($wpdb->prepare('SELECT RELEASE_LOCK(%s)',$lock));
}
if($canaryError!==''){echo 'MAHAK_IMAGE_CANARY_GUARD_ABORT_ERROR_CLASS='.$canaryError.PHP_EOL;exit(31);}
