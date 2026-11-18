<?php
/**
 * Plugin Name: Vesta — Import existing Mahak products and photos
 * Description: Admin-only, on-demand Mahak to Woo draft import and append-only image import.
 * Version: 0.2.0
 */
if (!defined('ABSPATH')) exit;

function vesta_mhi_ready() {
    return class_exists('WC_Product') && function_exists('vms_search') &&
        function_exists('vms_import_existing') && function_exists('vms_identify') &&
        function_exists('vesta_bazara_image_patch_verified') && vesta_bazara_image_patch_verified();
}
function vesta_mhi_code($value) {
    $code = trim((string)$value);
    if ($code === '' || strlen($code)>80 || !preg_match('/^[\p{L}\p{N}_.-]+$/uD',$code))
        throw new InvalidArgumentException('کد محصول محک نامعتبر است.');
    return $code;
}
function vesta_mhi_name_compatible($woo_name,$erp_name) {
    // Fail closed on conflicting identities. Translation and variant naming can legitimately differ:
    // such cases require a reviewed explicit link, never automatic photo attachment.
    if (!function_exists('vms_normalize')) return false;
    $a=mb_strtolower(vms_normalize((string)$woo_name),'UTF-8');
    $b=mb_strtolower(vms_normalize((string)$erp_name),'UTF-8');
    if (mb_strlen($a)<5 || mb_strlen($b)<5) return false;
    return $a===$b || (mb_strlen($b)>=8 && mb_stripos($a,$b,0,'UTF-8')!==false) ||
        (mb_strlen($a)>=8 && mb_stripos($b,$a,0,'UTF-8')!==false);
}
function vesta_mhi_identity_guard($woo_id,$erp_id,$expected_code='') {
    $p=wc_get_product($woo_id);
    if (!$p || (int)$p->get_meta('mahak_id',true)!==$erp_id)
        throw new RuntimeException('شناسه داخلی محصول سایت با شناسه محک تطابق ندارد.');
    if (!function_exists('vmb_catalog')||!function_exists('vmb_api'))
        throw new RuntimeException('بررسی هویت کالا در محک در دسترس نیست.');
    $source=null;
    foreach (vmb_catalog(vmb_api())['Products']??[] as $row) {
        if (empty($row['Deleted']) && (int)($row['ProductId']??0)===$erp_id) {
            if ($source!==null) throw new RuntimeException('شناسه محصول محک تکراری است.');
            $source=$row;
        }
    }
    if (!$source) throw new RuntimeException('کالای متناظر در خروجی فعلی محک وجود ندارد.');
    // A Mahak good with variants must be represented by its main Woo product.
    // A variation-level SKU is NOT a stable Mahak parent ProductCode.
    if ($p->is_type('variation'))
        throw new RuntimeException('عکس‌های کالای دارای تنوع باید به محصول مادر وارد شوند؛ تنوع با شناسه محصول مستقل محک همگام نمی‌شود.');
    if ($expected_code!=='' && (string)($source['ProductCode']??'')!==$expected_code)
        throw new RuntimeException('کد کالای محک با نتیجه جست‌وجو متفاوت است.');
    if (!vesta_mhi_name_compatible($p->get_name(),$source['Name']??'')) {
        throw new RuntimeException('تعارض هویت محصول: نام کالای محک با نام محصول سایت متفاوت است. انتقال عکس متوقف شد؛ اتصال شناسه‌ها باید بررسی شود.');
    }
    $catalog=vmb_catalog(vmb_api());
    $detailIds=[];
    foreach ((array)($catalog['ProductDetails']??[]) as $d)
        if (empty($d['Deleted'])&&(int)($d['ProductId']??0)===$erp_id)
            $detailIds[]=(int)($d['ProductDetailId']??0);
    if (!$detailIds) throw new RuntimeException('محک برای این کالا هیچ ردیف جزئیات فعال ندارد.');
    if ($p->is_type('simple')) {
        if (count($detailIds)!==1 ||
            (int)$p->get_meta('mahak_product_detail_id',true)!==$detailIds[0])
            throw new RuntimeException('شناسه جزئیات محصول ساده با محک تطابق ندارد.');
    } elseif (!$p->is_type('variable')) {
        throw new RuntimeException('نوع این محصول برای انتقال خودکار عکس پشتیبانی نشده است.');
    }
    return $source;
}
function vesta_mhi_photo_rows($erp_id) {
    if ($erp_id<=0) throw new InvalidArgumentException('شناسه محک نامعتبر است.');
    // Always request the live Mahak Cloud picture ledger when the merchant clicks.
    // Local Bazara cache may lag after a new upload in Mahak Windows.
    if (!function_exists('vmb_api')) throw new RuntimeException('اتصال محک ابری فعال نیست.');
    $response=vmb_api()->get_all_data('',[
      'fromPictureVersion'=>0,'fromPhotoGalleryVersion'=>0
    ]);
    if (!is_array($response)||empty($response['success'])||
        !is_array($response['message']??null)||
        !is_array($response['message']['Pictures']??null)||
        !is_array($response['message']['PhotoGalleries']??null))
        throw new RuntimeException('فهرست جدید عکس‌های محک دریافت نشد؛ بدون تغییر در تصاویر سایت متوقف شد.');
    $ledger=$response['message'];
    $pictures=[];
    foreach ($ledger['Pictures'] as $row) {
        if (!is_array($row)||!empty($row['Deleted'])) continue;
        $id=(int)($row['PictureId']??0);
        if ($id>0) $pictures[$id]=['PictureId'=>$id,'Url'=>(string)($row['Url']??'')];
    }
    $found=[];
    foreach ($ledger['PhotoGalleries'] as $rel) {
        if (!is_array($rel)||!empty($rel['Deleted'])||
            (int)($rel['ItemCode']??0)!==$erp_id)continue;
        $pictureId=(int)($rel['PictureId']??0);
        if ($pictureId>0 && isset($pictures[$pictureId]))
            $found[$pictureId]=$pictures[$pictureId];
    }
    ksort($found,SORT_NUMERIC);
    if (count($found)>20)
        throw new RuntimeException('این محصول بیش از ۲۰ عکس دارد؛ انتقال خودکار تا بررسی تعداد عکس‌ها متوقف شد.');
    return array_values($found);
}
function vesta_mhi_plan($woo_id,$erp_id) {
    if (!vesta_mhi_ready()) throw new RuntimeException('اتصال امن محک یا محافظ تصاویر فعال نیست.');
    $p=wc_get_product($woo_id);
    if (!$p) throw new RuntimeException('محصول در سایت وجود ندارد.');
    vesta_mhi_identity_guard($woo_id,$erp_id);
    global $wpdb;
    $photos=vesta_mhi_photo_rows($erp_id);
    $missing=[];$present=0;$elsewhere=0;
    foreach ($photos as $photo) {
        $pic=(int)$photo['PictureId'];
        if ($pic<=0) continue;
        $attached=$wpdb->get_col($wpdb->prepare(
            "SELECT post_id FROM {$wpdb->postmeta} WHERE meta_key='mahak_picture_id' AND meta_value=%s",(string)$pic));
        if ($attached) {
            $owned=false;
            foreach ($attached as $aid) {
                $post=get_post((int)$aid);
                if ($post && (int)$post->post_parent===$woo_id) $owned=true;
            }
            if ($owned) $present++; else $elsewhere++;
            continue;
        }
        $missing[]=$photo;
    }
    return ['product'=>$p,'total'=>count($photos),'present'=>$present,'elsewhere'=>$elsewhere,
            'missing'=>$missing,'truncated'=>count($photos)>=20];
}
function vesta_mhi_photo_base_url() {
    $source=@file_get_contents(WP_PLUGIN_DIR.'/bazara/classes/class.bazara.api.php');
    if (!is_string($source) ||
        !preg_match('/\$img_url\s*=\s*[\x27\x22]([^\x27\x22]+)[\x27\x22]\s*;/',$source,$matches))
        throw new RuntimeException('آدرس تصاویر بازارا در نسخه فعلی قابل تأیید نیست.');
    $base=rtrim($matches[1],'/');
    $parts=wp_parse_url($base);
    if (!is_array($parts) || strtolower((string)($parts['scheme']??''))!=='https' ||
        empty($parts['host']) || !filter_var($parts['host'],FILTER_VALIDATE_DOMAIN,FILTER_FLAG_HOSTNAME) ||
        !empty($parts['user']) || !empty($parts['pass']))
        throw new RuntimeException('آدرس منبع عکس معتبر نیست.');
    return $base;
}
function vesta_mhi_import_pictures($woo_id,$erp_id,$max=5) {
    global $wpdb;
    $max=max(1,min(5,(int)$max));
    $lock='vesta_mhi_photo_'.(int)$erp_id;
    if ((int)$wpdb->get_var($wpdb->prepare('SELECT GET_LOCK(%s,8)',$lock))!==1)
        throw new RuntimeException('انتقال عکس همین محصول در حال اجراست.');
    try {
        $plan=vesta_mhi_plan($woo_id,$erp_id);
        if (!$plan['missing']) return ['added'=>0,'total'=>$plan['total'],'pending'=>0,'note'=>'تمام عکس‌های شناسایی‌شده قبلاً منتقل شده‌اند یا نیازمند بررسی هستند.'];
        $base=vesta_mhi_photo_base_url();
        require_once ABSPATH.'wp-admin/includes/file.php';
        require_once ABSPATH.'wp-admin/includes/media.php';
        require_once ABSPATH.'wp-admin/includes/image.php';
        $added=0;$errors=0;
        foreach (array_slice($plan['missing'],0,$max) as $photo) {
            $pic=(int)$photo['PictureId'];
            $filename=basename((string)$photo['Url']);
            if (!$pic || !preg_match('/^[a-zA-Z0-9_.-]{1,180}\.jpe?g$/iD',$filename)) {$errors++;continue;}
            $url=$base.'/'.$filename;
            $head=wp_safe_remote_head($url,['timeout'=>15,'redirection'=>2,'sslverify'=>true]);
            if (is_wp_error($head) || (int)wp_remote_retrieve_response_code($head)!==200 ||
                stripos((string)wp_remote_retrieve_header($head,'content-type'),'image/jpeg')!==0 ||
                (int)wp_remote_retrieve_header($head,'content-length')>12000000) {$errors++;continue;}
            $current=wc_get_product($woo_id);
            if (!$current || (int)$current->get_meta('mahak_id',true)!==$erp_id) throw new RuntimeException('اتصال محصول در حین انتقال تغییر کرد.');
            $oldMain=(int)$current->get_image_id();$oldGallery=$current->get_gallery_image_ids();
            $tmp='';$newId=0;
            try {
                $tmp=download_url($url,25);
                if (is_wp_error($tmp)) { $tmp='';throw new RuntimeException('download_failed'); }
                $size=@filesize($tmp);$info=@getimagesize($tmp);
                if (!$size||$size>12000000||!is_array($info)||(int)$info[2]!==IMAGETYPE_JPEG)
                    throw new RuntimeException('image_invalid');
                $again=$wpdb->get_var($wpdb->prepare(
                  "SELECT post_id FROM {$wpdb->postmeta} WHERE meta_key='mahak_picture_id' AND meta_value=%s LIMIT 1",(string)$pic));
                if ($again) continue; // Never duplicate the same remote photo.
                $newId=media_handle_sideload(['name'=>$filename,'tmp_name'=>$tmp],$woo_id,'عکس تأییدشده محک '.$pic);
                if (is_wp_error($newId)) {$newId=0;throw new RuntimeException('attachment_failed');}
                $tmp='';
                if (get_post_mime_type($newId)!=='image/jpeg') throw new RuntimeException('attachment_type');
                add_post_meta($newId,'mahak_picture_id',(string)$pic,true);
                add_post_meta($newId,'_vesta_mhi_imported_at',gmdate('c'),true);
                $check=wc_get_product($woo_id);
                if (!$check || (int)$check->get_image_id()!==$oldMain ||
                    $check->get_gallery_image_ids()!==$oldGallery)
                    throw new RuntimeException('concurrent_media_change');
                if (!$oldMain) $check->set_image_id((int)$newId);
                else $check->set_gallery_image_ids(array_values(array_unique(array_merge($oldGallery,[(int)$newId]))));
                $check->save();
                $result=wc_get_product($woo_id);
                if (!$result || (int)$result->get_image_id()!==($oldMain ?: (int)$newId) ||
                    ($oldMain && !in_array((int)$newId,$result->get_gallery_image_ids(),true)))
                    throw new RuntimeException('media_readback');
                $added++;$newId=0;
            } catch (Throwable $e) {
                $errors++;
                if ($newId) {
                    $restore=wc_get_product($woo_id);
                    if ($restore) {
                        if ((int)$restore->get_image_id()===(int)$newId) $restore->set_image_id($oldMain);
                        $restore->set_gallery_image_ids($oldGallery);
                        $restore->save();
                    }
                    wp_delete_attachment($newId,true); // Delete only this newly created attachment on rollback.
                }
            } finally { if (is_string($tmp) && $tmp!=='' && file_exists($tmp)) @unlink($tmp); }
        }
        $after=vesta_mhi_plan($woo_id,$erp_id);
        return ['added'=>$added,'errors'=>$errors,'total'=>$after['total'],
          'pending'=>count($after['missing']),
          'note'=>$errors?'بعضی عکس‌ها به دلیل خطای دریافت یا اعتبارسنجی منتقل نشدند.':'عکس‌های قبلی محصول حفظ شدند.'];
    } finally {
        $wpdb->get_var($wpdb->prepare('SELECT RELEASE_LOCK(%s)',$lock));
    }
}
function vesta_mhi_admin_notice($message,$bad=false) {
    set_transient('vesta_mhi_notice_'.get_current_user_id(),
        ['text'=>mb_substr((string)$message,0,600),'bad'=>(bool)$bad],120);
}
add_action('admin_menu',function(){
    add_submenu_page('woocommerce','دریافت محصول از محک','دریافت محصول از محک',
        'manage_woocommerce','vesta-mahak-import','vesta_mhi_admin_page');
},40);
function vesta_mhi_admin_page() {
    if (!current_user_can('manage_woocommerce')) wp_die('Access denied');
    echo '<div class="wrap"><h1>دریافت محصول از محک</h1>';
    echo '<p>کالای موجود در محک را با نام یا کد جست‌وجو کن. محصولات جدید به‌صورت <strong>پیش‌نویس غیرفعال</strong> ایجاد می‌شوند؛ قیمت و موجودی قبل از انتشار باید بررسی شوند. هیچ کالایی در محک ساخته یا تغییر داده نمی‌شود.</p>';
    $notice=get_transient('vesta_mhi_notice_'.get_current_user_id());
    if (is_array($notice)) {
        delete_transient('vesta_mhi_notice_'.get_current_user_id());
        echo '<div class="notice notice-'.(!empty($notice['bad'])?'error':'success').'"><p>'.esc_html($notice['text']).'</p></div>';
    }
    if (!vesta_mhi_ready()) {
        echo '<div class="notice notice-error"><p>واردکردن امن محصول آماده نیست. افزونه اتصال محک و محافظ تصاویر را بررسی کنید.</p></div></div>';
        return;
    }
    echo '<form method="get"><input type="hidden" name="page" value="vesta-mahak-import">';
    echo '<input name="q" style="width:360px;max-width:95%" required minlength="2" maxlength="100" placeholder="کد محصول یا بخشی از نام" value="'.
        esc_attr(sanitize_text_field(wp_unslash($_GET['q']??''))).'"> ';
    submit_button('جست‌وجو در محک','primary','submit',false);echo '</form>';
    $q=sanitize_text_field(wp_unslash($_GET['q']??''));
    if (mb_strlen(trim($q))<2) {echo '</div>';return;}
    try {$found=vms_search(['query'=>$q]);}
    catch(Throwable $e) {echo '<div class="notice notice-error"><p>'.esc_html($e->getMessage()).'</p></div></div>';return;}
    echo '<p>نتایج: '.(int)($found['total']??0).' — حداکثر ۸ مورد نمایش داده می‌شود.</p>';
    echo '<table class="widefat striped"><thead><tr><th>نام کالا</th><th>کد محک</th><th>جزئیات/تنوع</th><th>وضعیت سایت</th><th>عملیات</th></tr></thead><tbody>';
    foreach ((array)($found['items']??[]) as $item) {
        $id=(int)$item['product_id'];$woo=(int)$item['woo_id'];
        $code=(string)$item['code'];$count=(int)$item['detail_count'];
        echo '<tr><td>'.esc_html($item['name']).'</td><td>'.esc_html($code).'</td><td>'.(int)$count.'</td><td>';
        if ($woo) echo 'موجود در سایت ('.(int)$woo.')';
        else echo $count===1?'قابل ایجاد به‌صورت پیش‌نویس':'نیازمند بررسی تنوع‌ها';
        echo '</td><td>';
        $identityConflict=false;
        if ($woo) {
            $wp=wc_get_product($woo);
            $identityConflict=(!$wp || !vesta_mhi_name_compatible($wp->get_name(),$item['name']));
        }
        if ($identityConflict) {echo '<strong style="color:#b91c1c">تعارض شناسه: نام سایت و محک متفاوت است؛ انتقال ممنوع</strong>';}
        elseif (!$woo && $count!==1) {echo 'انتقال خودکار متوقف: جزئیات کالا یکتا نیست';}
        else {
            echo '<form method="post" action="'.esc_url(admin_url('admin-post.php')).'">';
            echo '<input type="hidden" name="action" value="vesta_mhi_import">';
            echo '<input type="hidden" name="product_id" value="'.(int)$id.'">';
            echo '<input type="hidden" name="code" value="'.esc_attr($code).'">';
            wp_nonce_field('vesta_mhi_import_'.$id);
            submit_button($woo?'افزودن عکس‌های محک':'ایجاد پیش‌نویس + عکس‌ها','secondary','submit',false);
            echo '</form>';
            if ($woo) echo ' <a href="'.esc_url(admin_url('post.php?post='.$woo.'&action=edit')).'">ویرایش در سایت</a>';
        }
        echo '</td></tr>';
    }
    echo '</tbody></table><p>فهرست عکس‌ها هنگام درخواست مستقیماً از محک ابری خوانده می‌شود. عکس فقط به محصول اصلی با کد و نام و شناسه حسابداری منطبق اضافه خواهد شد؛ تصاویر و موجودی قبلی حذف یا جایگزین نمی‌شوند. بعد از ثبت عکس در محک ویندوزی، ابتدا ارسال و دریافت بازارا را انجام بده.</p></div>';
}
add_action('admin_post_vesta_mhi_import',function() {
    if (!current_user_can('manage_woocommerce')) wp_die('Access denied');
    $id=(int)($_POST['product_id']??0);
    check_admin_referer('vesta_mhi_import_'.$id);
    $url=admin_url('admin.php?page=vesta-mahak-import');
    try {
        if (!vesta_mhi_ready() || $id<=0) throw new RuntimeException('اتصال امن فعال نیست.');
        $code=vesta_mhi_code(wp_unslash($_POST['code']??''));
        list($ident,$exact,$product)=vms_identify(['product_id'=>$id,'code'=>$code]);
        if ($ident!==$id || $exact!==$code || !$product) throw new RuntimeException('تطبیق کد و شناسه محک ناموفق بود.');
        $preexisting=vms_existing_woo($code,$id);
        if ($preexisting) {
            $old=wc_get_product($preexisting);
            if (!$old || !vesta_mhi_name_compatible($old->get_name(),$product['Name']??''))
                throw new RuntimeException('تعارض کد محصول بین محک و ووکامرس: نام کالاها متفاوت است. از ساخت یا اتصال خودکار جلوگیری شد.');
        }
        $result=vms_import_existing(['product_id'=>$id,'code'=>$code]);
        $woo=(int)($result['woo_id']??0);
        if (!$woo) throw new RuntimeException('نتیجه ایجاد محصول قطعی نیست؛ پیش از درخواست مجدد، محصول را بررسی کن.');
        $product=wc_get_product($woo);
        if (!$product) throw new RuntimeException('محصول سایت پس از عملیات پیدا نشد.');
        if ((int)$product->get_meta('mahak_id',true)!==$id)
            throw new RuntimeException('محصول موجود است، اما اتصال یکتای آن به محک تأیید نشده؛ عکس وارد نشد.');
        $images=vesta_mhi_import_pictures($woo,$id,5);
        vesta_mhi_admin_notice('محصول سایت '.$woo.'؛ عکس جدید: '.$images['added'].'؛ باقی‌مانده: '.$images['pending'].'؛ '.($images['note']??''));
        $url=add_query_arg('q',rawurlencode($code),$url);
    } catch(Throwable $e) {vesta_mhi_admin_notice($e->getMessage(),true);}
    wp_safe_redirect($url);exit;
});
