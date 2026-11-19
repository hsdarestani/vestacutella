<?php
/**
 * Plugin Name: Vesta — Telegram Mahak product content editor
 * Description: Add photos, short description and package weight to the already verified Woo product; never modify ERP, variants, price, stock or publication.
 * Version: 1.0.0
 */
if (!defined('ABSPATH')) exit;

function vesta_mcb_verified_product($data) {
    if (!function_exists('wc_get_product') || !function_exists('vms_existing_woo') ||
        !function_exists('vesta_mhi_identity_guard')) {
        throw new RuntimeException('اتصال امن محصول محک به سایت آماده نیست.');
    }
    $code=trim((string)($data['code']??''));
    $erp=(int)($data['product_id']??0);
    $woo=(int)($data['woo_id']??0);
    if($erp<=0||$code===''||mb_strlen($code)>80||
       !preg_match('/^[\p{L}\p{N}_.-]+$/uD',$code))
        throw new InvalidArgumentException('کد یا شناسه محک معتبر نیست.');
    $real=(int)vms_existing_woo($code,$erp);
    if(!$real||($woo&&$real!==$woo))
        throw new RuntimeException('محصول متناظر در ووکامرس پیدا نشد یا شناسه تغییر کرده است.');
    $p=wc_get_product($real);
    if(!$p||$p->is_type('variation')||!in_array($p->get_type(),['simple','variable'],true)||
       !in_array($p->get_status(),['draft','publish','private','pending'],true)||
       $p->get_sku()!==$code||(int)$p->get_meta('mahak_id',true)!==$erp)
       throw new RuntimeException('محصول به کالای صحیح محک متصل نیست؛ تغییری انجام نشد.');
    vesta_mhi_identity_guard($real,$erp,$code);
    return $p;
}
function vesta_mcb_state($p) {
    $unit=get_option('woocommerce_weight_unit','kg');
    $grams=$p->get_weight()!=='' && function_exists('wc_get_weight')
        ? wc_get_weight((float)$p->get_weight(),'g',$unit) : '';
    return [
        'woo_id'=>$p->get_id(),'name'=>$p->get_name(),'status'=>$p->get_status(),
        'type'=>$p->get_type(),'code'=>$p->get_sku(),
        'short_description'=>wp_strip_all_tags($p->get_short_description()),
        'weight_grams'=>$grams===''?'':(string)wc_format_decimal($grams,3),
        'image_id'=>(int)$p->get_image_id(),
        'gallery_image_ids'=>array_map('intval',$p->get_gallery_image_ids()),
        'edit_url'=>admin_url('post.php?post='.$p->get_id().'&action=edit'),
        'price_and_stock_are_accounting_controlled'=>true,
    ];
}
function vesta_mcb_status($data) {
    return vesta_mcb_state(vesta_mcb_verified_product($data));
}
function vesta_mcb_save($data) {
    global $wpdb;
    $key=(string)($data['request_key']??'');
    if(!preg_match('/^[a-f0-9]{32}$/D',$key))throw new InvalidArgumentException('شناسه درخواست نامعتبر است.');
    $code=trim((string)($data['code']??''));
    $erp=(int)($data['product_id']??0);
    $media=$data['image_ids']??[];
    if(!is_array($media)||count($media)>10)throw new InvalidArgumentException('حداکثر ۱۰ تصویر در هر عملیات مجاز است.');
    $media=array_values(array_unique(array_map('absint',$media)));
    if(in_array(0,$media,true))throw new InvalidArgumentException('شناسه یکی از عکس‌ها نامعتبر است.');
    $caption=array_key_exists('caption',$data)?(string)$data['caption']:null;
    if($caption!==null && (mb_strlen($caption)>4000||mb_strlen($caption)<1))
        throw new InvalidArgumentException('توضیح کوتاه باید بین ۱ تا ۴۰۰۰ حرف باشد.');
    $grams=array_key_exists('weight_grams',$data)?(string)$data['weight_grams']:null;
    if($grams!==null && (!preg_match('/^\d{1,7}(?:\.\d{1,3})?$/D',$grams) ||
        (float)$grams<=0 || (float)$grams>1000000))
        throw new InvalidArgumentException('وزن باید عدد مثبت به گرم باشد.');
    $coverMode=(string)($data['cover_mode']??'if_empty');
    if(!in_array($coverMode,['if_empty','keep','replace'],true))throw new InvalidArgumentException('نوع انتقال تصویر نامعتبر است.');
    if(!$media && $caption===null && $grams===null)
        throw new InvalidArgumentException('عکس، کپشن یا وزن جدیدی برای ذخیره انتخاب نشده است.');
    $hash=hash('sha256',wp_json_encode([
        'code'=>$code,'erp'=>$erp,'woo'=>(int)($data['woo_id']??0),
        'media'=>$media,'caption'=>$caption,'grams'=>$grams,'cover_mode'=>$coverMode
    ],JSON_UNESCAPED_UNICODE));
    $lock='vesta_telegram_content_'.$erp;
    if((int)$wpdb->get_var($wpdb->prepare('SELECT GET_LOCK(%s,8)',$lock))!==1)
        throw new RuntimeException('ویرایش همین کالا در حال اجراست؛ دوباره ارسال نکنید.');
    try{
        $auditKey='vesta_mcb_'.hash('sha256',$key);
        $previous=get_option($auditKey,false);
        if(is_array($previous)) {
            if(($previous['hash']??'')!==$hash)throw new RuntimeException('شناسه درخواست برای اطلاعات متفاوت استفاده شده است.');
            $same=vesta_mcb_verified_product($data);
            return ['already_applied'=>true,'product'=>vesta_mcb_state($same)];
        }
        $p=vesta_mcb_verified_product($data);
        if(isset($data['expected_image_id']) && (int)$data['expected_image_id']!==(int)$p->get_image_id())
            throw new RuntimeException('عکس اصلی در سایت تغییر کرده؛ پیش‌نمایش محصول را دوباره باز کنید.');
        if($caption!==null && isset($data['expected_caption_hash']) &&
            (string)$data['expected_caption_hash']!==hash('sha256',wp_strip_all_tags($p->get_short_description())))
            throw new RuntimeException('کپشن محصول در سایت تغییر کرده؛ قبل از جایگزینی دوباره بررسی کنید.');
        foreach($media as $aid){
            $att=get_post($aid);
            if(!$att||$att->post_type!=='attachment'||get_post_mime_type($aid)!=='image/jpeg' ||
               ($att->post_parent && (int)$att->post_parent!==(int)$p->get_id()))
                throw new RuntimeException('یکی از تصاویر به محصول دیگری تعلق دارد یا فایل JPEG معتبر نیست.');
            $local=get_attached_file($aid);
            if(!is_string($local)||!is_file($local)||filesize($local)>12000000)
                throw new RuntimeException('فایل یکی از تصاویر روی سرور معتبر نیست.');
        }
        $before=[
            'status'=>$p->get_status(),'name'=>$p->get_name(),
            'sku'=>$p->get_sku(),'erp'=>(int)$p->get_meta('mahak_id',true),
            'price'=>$p->get_regular_price(),'sale_price'=>$p->get_sale_price(),
            'stock'=>$p->get_stock_quantity(),'manage_stock'=>$p->get_manage_stock(),
            'stock_status'=>$p->get_stock_status(),'children'=>$p->is_type('variable')?$p->get_children():[]
        ];
        $oldMain=(int)$p->get_image_id();$gallery=array_map('intval',$p->get_gallery_image_ids());
        $rest=$media;
        if($media && ($coverMode==='replace'||($coverMode==='if_empty'&&!$oldMain))) {
            $p->set_image_id($media[0]);
            $rest=array_slice($media,1);
        }
        // Keep previous main/gallery attachment IDs available. No existing file deleted.
        $gallery=array_values(array_unique(array_merge($gallery,$rest)));
        $gallery=array_values(array_diff($gallery,[(int)$p->get_image_id()]));
        if($gallery!==$p->get_gallery_image_ids())$p->set_gallery_image_ids($gallery);
        if($caption!==null)$p->set_short_description(wp_kses_post($caption));
        if($grams!==null) {
            $unit=get_option('woocommerce_weight_unit','kg');
            if(!in_array($unit,['g','kg','lbs','oz'],true)||!function_exists('wc_get_weight'))
                throw new RuntimeException('واحد وزن ووکامرس قابل تأیید نیست.');
            $p->set_weight(wc_format_decimal(wc_get_weight((float)$grams,$unit,'g'),6));
        }
        $p->save();
        $after=wc_get_product($p->get_id());
        if(!$after)throw new RuntimeException('بازخوانی محصول ناموفق بود.');
        $afterImmutable=[
            'status'=>$after->get_status(),'name'=>$after->get_name(),
            'sku'=>$after->get_sku(),'erp'=>(int)$after->get_meta('mahak_id',true),
            'price'=>$after->get_regular_price(),'sale_price'=>$after->get_sale_price(),
            'stock'=>$after->get_stock_quantity(),'manage_stock'=>$after->get_manage_stock(),
            'stock_status'=>$after->get_stock_status(),'children'=>$after->is_type('variable')?$after->get_children():[]
        ];
        if($before!==$afterImmutable)throw new RuntimeException('اطلاعات حسابداری محصول پس از ذخیره تغییر کرد.');
        foreach($media as $aid)if((int)$after->get_image_id()!==$aid &&
            !in_array($aid,$after->get_gallery_image_ids(),true))
            throw new RuntimeException('یکی از تصاویر به محصول متصل نشد.');
        if($caption!==null && wp_strip_all_tags($after->get_short_description())!==wp_strip_all_tags(wp_kses_post($caption)))
            throw new RuntimeException('کپشن ثبت‌شده با درخواست یکسان نیست.');
        if($grams!==null && abs((float)wc_get_weight($after->get_weight(),'g',get_option('woocommerce_weight_unit','kg'))-(float)$grams)>0.02)
            throw new RuntimeException('وزن ثبت‌شده با درخواست یکسان نیست.');
        add_option($auditKey,['hash'=>$hash,'woo_id'=>$after->get_id(),'completed_at'=>gmdate('c')],'',false);
        return ['already_applied'=>false,'product'=>vesta_mcb_state($after)];
    }finally{$wpdb->get_var($wpdb->prepare('SELECT RELEASE_LOCK(%s)',$lock));}
}

// The stock Bot Bridge dispatches at plugins_loaded, before WooCommerce
// registers the product CPT on init. WC products are NULL at that stage.
// Defer ONLY our three signed editorial operations until after init, and
// retain the core early route for every other operation.
add_action('plugins_loaded',function(){
    if(!isset($_GET['vbb'])||(string)$_GET['vbb']!=='2')return;
    $op=sanitize_key((string)($_GET['o']??''));
    if(!in_array($op,['mahak_content_status','mahak_content_save'],true))return;
    remove_action('plugins_loaded','vbb_handle_v2_request',PHP_INT_MAX);
    add_action('init','vesta_mcb_authenticated_dispatch_after_woo_init',PHP_INT_MAX-4);
},PHP_INT_MAX-4);

function vesta_mcb_authenticated_dispatch_after_woo_init() {
    $op=sanitize_key((string)($_GET['o']??''));
    if(!in_array($op,['mahak_content_status','mahak_content_save'],true))return;
    if(!function_exists('vbb_v2_authorize') || !did_action('init') ||
       !post_type_exists('product') || !did_action('woocommerce_init'))
       vbb_fail('WooCommerce content editor is not initialized.',503);
    list($verified,$data)=vbb_v2_authorize();
    if($verified!==$op)vbb_fail('Invalid operation.',400);
    try{
        $result=$op==='mahak_content_status'?vesta_mcb_status($data):vesta_mcb_save($data);
        vbb_no_cache();
        wp_send_json_success($result);
    }catch(Throwable $e){vbb_fail($e->getMessage(),400);}
}
