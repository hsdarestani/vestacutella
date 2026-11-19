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


/**
 * Stage editorial data from the SAME bot product-creation wizard, after a
 * verified one-time Mahak SaveAllData acceptance. Woo publication still waits
 * for native Bazara sync and validated Mahak ID; never create a second product.
 */
function vesta_mcb_stage_key($request_key) {
    if(!is_string($request_key)||!preg_match('/^[a-f0-9]{32}$/D',$request_key))
        throw new InvalidArgumentException('شناسه عملیات محک نامعتبر است.');
    return 'vesta_mcb_stage_'.hash('sha256',$request_key);
}
function vesta_mcb_pending_status($data) {
    $key=(string)($data['request_key']??'');
    $stage=get_option(vesta_mcb_stage_key($key),null);
    if(!is_array($stage))return ['status'=>'not_staged'];
    return [
        'status'=>(string)($stage['status']??'unknown'),
        'code'=>(string)($stage['code']??''),
        'woo_id'=>(int)($stage['woo_id']??0),
        'attempts'=>(int)($stage['attempts']??0),
        'note'=>(string)($stage['note']??''),
    ];
}
function vesta_mcb_schedule_pending($seconds=90) {
    if(!function_exists('as_schedule_single_action'))return false;
    // One pending action at a time, not a repeated Mahak Cloud full fetch.
    if(function_exists('as_next_scheduled_action') &&
       as_next_scheduled_action('vesta_mcb_apply_pending',[],'vesta-mahak-content'))return true;
    return (bool)as_schedule_single_action(time()+max(45,(int)$seconds),
       'vesta_mcb_apply_pending',[],'vesta-mahak-content');
}
function vesta_mcb_stage($data) {
    global $wpdb;
    if(!function_exists('vmb_request_key')||!function_exists('vmb_status'))
        throw new RuntimeException('ثبت محصول محک برای صف تکمیل سایت آماده نیست.');
    $request=(string)($data['request_key']??'');
    $key=vesta_mcb_stage_key($request);
    $record=get_option(vmb_request_key($request),null);
    if(!is_array($record)||!in_array(($record['status']??''),[
      'accepted_pending_sync','visible_in_cloud_export'
    ],true))
        throw new RuntimeException('این محصول هنوز در API محک پذیرفته نشده است.');
    $code=trim((string)($data['code']??''));
    if($code===''||$code!==(string)($record['code']??''))
        throw new RuntimeException('کد کالا با درخواست ثبت در محک مطابقت ندارد.');
    $images=$data['image_ids']??[];
    if(!is_array($images)||count($images)>10)
        throw new InvalidArgumentException('حداکثر ۱۰ عکس قابل ثبت است.');
    $images=array_values(array_unique(array_map('absint',$images)));
    if(in_array(0,$images,true))throw new InvalidArgumentException('شناسه عکس معتبر نیست.');
    $caption=isset($data['caption'])?trim((string)$data['caption']):null;
    if($caption!==null&&($caption===''||mb_strlen($caption)>4000))
        throw new InvalidArgumentException('کپشن نامعتبر است.');
    $weight=isset($data['weight_grams'])?(string)$data['weight_grams']:null;
    if($weight!==null&&(!preg_match('/^\d{1,7}(?:\.\d{1,3})?$/D',$weight)||
       (float)$weight<=0 ||(float)$weight>1000000))
        throw new InvalidArgumentException('وزن باید به گرم و مثبت باشد.');
    foreach($images as $aid) {
        $file=get_attached_file($aid);
        if(get_post_type($aid)!=='attachment'||
           get_post_mime_type($aid)!=='image/jpeg'||
           !is_string($file)||!is_file($file)||
           filesize($file)>12000000)
            throw new RuntimeException('عکس ارسال‌شده در سایت معتبر نیست.');
    }
    $payload=['image_ids'=>$images,'caption'=>$caption,'weight_grams'=>$weight];
    $hash=hash('sha256',wp_json_encode(['code'=>$code,'payload'=>$payload],JSON_UNESCAPED_UNICODE));
    $lock='vesta_mcb_stage_index';
    if((int)$wpdb->get_var($wpdb->prepare('SELECT GET_LOCK(%s,8)',$lock))!==1)
        throw new RuntimeException('صف تکمیل محصولات مشغول است.');
    try{
        $existing=get_option($key,null);
        if(is_array($existing)) {
            if(($existing['hash']??'')!==$hash)
                throw new RuntimeException('مشخصات همان درخواست بعد از ثبت تغییر کرده؛ ایجاد دوباره ممنوع است.');
            vesta_mcb_schedule_pending(90);
            return vesta_mcb_pending_status($data);
        }
        $pending=(array)get_option('vesta_mcb_pending_index',[]);
        if(count($pending)>=100)throw new RuntimeException('صف ثبت محتوا پر است؛ عملیات متوقف شد.');
        $stage=[
            'request_key'=>$request,'code'=>$code,
            'hash'=>$hash,'payload'=>$payload,'status'=>'queued',
            'attempts'=>0,'created_at'=>gmdate('c'),'last_at'=>null,
            'note'=>'در انتظار نمایش محصول با شناسه معتبر محک در سایت'
        ];
        if(!add_option($key,$stage,'',false))
            throw new RuntimeException('ثبت درخواست محتوا در صف ناموفق بود.');
        $pending[]=$request;
        update_option('vesta_mcb_pending_index',array_values(array_unique($pending)),false);
    }finally{$wpdb->get_var($wpdb->prepare('SELECT RELEASE_LOCK(%s)',$lock));}
    vesta_mcb_schedule_pending(75);
    return vesta_mcb_pending_status($data);
}
function vesta_mcb_apply_pending_worker() {
    global $wpdb;
    if(!function_exists('vmb_status')||!function_exists('vesta_mhi_identity_guard') ||
       !function_exists('wc_get_product'))return;
    $lock='vesta_mcb_worker_lock';
    if((int)$wpdb->get_var($wpdb->prepare('SELECT GET_LOCK(%s,1)',$lock))!==1)return;
    try{
        $pending=(array)get_option('vesta_mcb_pending_index',[]);
        if(!$pending)return;
        $next=[];$processed=0;
        foreach($pending as $request){
            if(!is_string($request))continue;
            $stageKey=vesta_mcb_stage_key($request);
            $stage=get_option($stageKey,null);
            if(!is_array($stage)||in_array(($stage['status']??''),['applied','requires_review'],true))continue;
            if($processed>=3){$next[]=$request;continue;}
            $processed++;
            $stage['attempts']=(int)($stage['attempts']??0)+1;
            $stage['last_at']=gmdate('c');
            if(!empty($stage['created_at']) && time()-strtotime($stage['created_at'])>14*DAY_IN_SECONDS){
                $stage['status']='requires_review';
                $stage['note']='پیش‌نویس معتبر سایت بعد از ۱۴ روز پیدا نشد؛ بدون ساخت کالای تکراری متوقف شد.';
                update_option($stageKey,$stage,false);
                continue;
            }
            try{
                // Use the previous verified cloud ID when available.
                // Never fetch the complete ERP catalog again on every 5-minute
                // retry just to check whether Woo/Bazara has created its draft.
                $known=get_option(vmb_request_key($request),null);
                $mahak=(is_array($known) &&
                         ($known['status']??'')==='visible_in_cloud_export' &&
                         (int)($known['mahak_product_id']??0)>0)?
                    ['status'=>'visible_in_cloud_export',
                     'mahak_product_id'=>(int)$known['mahak_product_id'],
                     'name'=>(string)($known['name']??'')]:
                    vmb_status(['request_key'=>$request]);
                if(($mahak['status']??'')!=='visible_in_cloud_export' ||
                   empty($mahak['mahak_product_id'])) {
                    $stage['status']='waiting_mahak';
                    $stage['note']='در انتظار شناسه تأییدشده کالا در خروجی محک';
                    update_option($stageKey,$stage,false);$next[]=$request;continue;
                }
                $erp=(int)$mahak['mahak_product_id'];
                $code=(string)$stage['code'];
                $woo=(int)vms_existing_woo($code,$erp);
                if(!$woo) {
                    $stage['status']='waiting_site';
                    $stage['note']='کالا در محک ابری دیده شد؛ در انتظار همگام‌سازی و ساخت پیش‌نویس سایت';
                    update_option($stageKey,$stage,false);$next[]=$request;continue;
                }
                $p=vesta_mcb_verified_product([
                    'product_id'=>$erp,'code'=>$code,'woo_id'=>$woo
                ]);
                if(!vesta_mhi_name_compatible($p->get_name(),(string)$mahak['name']))
                    throw new RuntimeException('نام محصول سایت با نام درخواست محک تفاوت دارد.');
                $payload=(array)$stage['payload'];
                if(!$payload['image_ids'] && $payload['caption']===null &&
                   $payload['weight_grams']===null){
                    $stage['status']='applied';$stage['woo_id']=$woo;
                    $stage['note']='کالا در سایت ثبت شده؛ محتوای اضافه‌ای برای انتقال نبود.';
                    update_option($stageKey,$stage,false);continue;
                }
                $args=[
                    'request_key'=>$request,'product_id'=>$erp,'code'=>$code,
                    'woo_id'=>$woo,
                    'image_ids'=>$payload['image_ids'],
                    'cover_mode'=>'if_empty'
                ];
                if($payload['caption']!==null)$args['caption']=$payload['caption'];
                if($payload['weight_grams']!==null)$args['weight_grams']=$payload['weight_grams'];
                $saved=vesta_mcb_save($args);
                $stage['status']='applied';$stage['woo_id']=$woo;
                $stage['note']='عکس، کپشن و وزن روی همان محصول سایت ذخیره شد.';
                update_option($stageKey,$stage,false);
            }catch(Throwable $e){
                $stage['status']='waiting_site';
                // Retry transient cloud and on-site synchronization; do not create a new product.
                $stage['note']='نیازمند بررسی دریافت محک/سایت: '.mb_substr($e->getMessage(),0,125);
                update_option($stageKey,$stage,false);$next[]=$request;
            }
        }
        // Merge new submissions that arrived during a slow cloud lookup.
        // Stage writers use this same short index lock; never lose a newly
        // queued product when an old worker finishes.
        $indexLock='vesta_mcb_stage_index';
        if((int)$wpdb->get_var($wpdb->prepare('SELECT GET_LOCK(%s,8)',$indexLock))!==1)
            throw new RuntimeException('صف همگام‌سازی محتوا برای به‌روزرسانی مشغول است.');
        try {
            $current=(array)get_option('vesta_mcb_pending_index',[]);
            $newDuringRun=array_values(array_diff($current,$pending));
            $next=array_values(array_unique(array_merge($newDuringRun,$next)));
            update_option('vesta_mcb_pending_index',$next,false);
        }finally{$wpdb->get_var($wpdb->prepare('SELECT RELEASE_LOCK(%s)',$indexLock));}
        if($next)vesta_mcb_schedule_pending(300);
    }finally{$wpdb->get_var($wpdb->prepare('SELECT RELEASE_LOCK(%s)',$lock));}
}
add_action('vesta_mcb_apply_pending','vesta_mcb_apply_pending_worker');
add_action('bazara_run_product_sync',function(){
    if(!get_option('vesta_mcb_pending_index',[]))return;
    // Native Bazara runs often. Only schedule if no pending worker exists.
    vesta_mcb_schedule_pending(90);
},PHP_INT_MAX-3);

// The stock Bot Bridge dispatches at plugins_loaded, before WooCommerce
// registers the product CPT on init. WC products are NULL at that stage.
// Defer ONLY our three signed editorial operations until after init, and
// retain the core early route for every other operation.
add_action('plugins_loaded',function(){
    if(!isset($_GET['vbb'])||(string)$_GET['vbb']!=='2')return;
    $op=sanitize_key((string)($_GET['o']??''));
    if(!in_array($op,['mahak_content_status','mahak_content_save','mahak_content_stage','mahak_content_pending_status'],true))return;
    remove_action('plugins_loaded','vbb_handle_v2_request',PHP_INT_MAX);
    add_action('init','vesta_mcb_authenticated_dispatch_after_woo_init',PHP_INT_MAX-4);
},PHP_INT_MAX-4);

function vesta_mcb_authenticated_dispatch_after_woo_init() {
    $op=sanitize_key((string)($_GET['o']??''));
    if(!in_array($op,['mahak_content_status','mahak_content_save','mahak_content_stage','mahak_content_pending_status'],true))return;
    if(!function_exists('vbb_v2_authorize') || !did_action('init') ||
       !post_type_exists('product') || !did_action('woocommerce_init'))
       vbb_fail('WooCommerce content editor is not initialized.',503);
    list($verified,$data)=vbb_v2_authorize();
    if($verified!==$op)vbb_fail('Invalid operation.',400);
    try{
        if($op==='mahak_content_status')$result=vesta_mcb_status($data);
        elseif($op==='mahak_content_save')$result=vesta_mcb_save($data);
        elseif($op==='mahak_content_stage')$result=vesta_mcb_stage($data);
        else $result=vesta_mcb_pending_status($data);
        vbb_no_cache();
        wp_send_json_success($result);
    }catch(Throwable $e){vbb_fail($e->getMessage(),400);}
}
