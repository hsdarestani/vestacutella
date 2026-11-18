<?php
/**
 * One-time narrow repair: two existing Woo variations of Mehrona parent.
 * Fails closed for existing order items, source mismatch, duplicate target or source drift.
 * No invoice, product, photo, stock, price, API or parent title writes.
 */
error_reporting(E_ERROR|E_PARSE);ini_set('display_errors','0');set_time_limit(0);
$_SERVER['HTTP_HOST']='vesta-cosmetics.ir';$_SERVER['SERVER_NAME']='vesta-cosmetics.ir';
$_SERVER['HTTPS']='on';$_SERVER['SERVER_PORT']='443';$_SERVER['REQUEST_URI']='/';
require '/var/www/html/wp-load.php';global $wpdb;
$commit=getenv('VESTA_MEHRONA_COMMIT')==='yes';
if($commit&&getenv('VESTA_MEHRONA_BACKUP_VERIFIED')!=='yes'){echo "REPAIR_BACKUP_NOT_VERIFIED_ABORT=yes\n";exit(11);}
function vmr_norm($s) {
    $s=rawurldecode((string)$s);
    $s=strtr($s,['ي'=>'ی','ك'=>'ک','آ'=>'ا','‌'=>' ','٠'=>'0','١'=>'1','٢'=>'2','٣'=>'3','٤'=>'4','٥'=>'5','٦'=>'6','٧'=>'7','٨'=>'8','٩'=>'9','۰'=>'0','۱'=>'1','۲'=>'2','۳'=>'3','۴'=>'4','۵'=>'5','۶'=>'6','۷'=>'7','۸'=>'8','۹'=>'9']);
    return preg_replace('/[^\p{L}\p{N}]+/u','',mb_strtolower($s,'UTF-8'));
}
$parent=wc_get_product(103200);
if(!$parent||!$parent->is_type('variable')){echo "UNEXPECTED_WOO_PARENT_ABORT=yes\n";exit(12);}
$catalog=vmb_catalog(vmb_api());
$good=null;$allDetails=[];
foreach($catalog['Products']??[] as $g)
    if(empty($g['Deleted'])&&(int)($g['ProductId']??0)===10685134) {
        if($good!==null)exit(13);$good=$g;
    }
if(!$good || (string)($good['ProductCode']??'')!=='103200' ||
    vmr_norm((string)($good['Name']??''))!==vmr_norm($parent->get_name())){echo "ERP_PARENT_IDENTITY_NOT_EXACT_ABORT=yes\n";exit(14);}
foreach($catalog['ProductDetails']??[] as $detail)
    if(empty($detail['Deleted'])&&(int)($detail['ProductId']??0)===10685134)
        $allDetails[(int)($detail['ProductDetailId']??0)]=$detail;
$targets=[
    103201=>['attr'=>'کد سیزده','current_product'=>10755477,'current_detail'=>12269305,'target_detail'=>12183947],
    103203=>['attr'=>'کد شانزده','current_product'=>10755475,'current_detail'=>12269290,'target_detail'=>12183543],
];
$pre=[];$eligible=[];$skip=[];
foreach($targets as $id=>$expect) {
    $v=wc_get_product($id);
    if(!$v || !$v->is_type('variation')||(int)$v->get_parent_id()!==103200)exit(15);
    $val=array_values($v->get_variation_attributes());
    if(count($val)!==1 || vmr_norm($val[0])!==vmr_norm($expect['attr']))exit(16);
    $d=$allDetails[$expect['target_detail']]??null;
    if(!$d)exit(17);
    $props=json_decode((string)($d['Properties']??''),true);$values=[];
    foreach(is_array($props)?$props:[] as $row)if(is_array($row) && isset($row['V']))$values[]=vmr_norm($row['V']);
    if(count($values)!==1||$values[0]!==vmr_norm($expect['attr']))exit(18);
    $currentProduct=(int)get_post_meta($id,'mahak_id',true);
    $currentDetail=(int)get_post_meta($id,'mahak_product_detail_id',true);
    $orderRefs=(int)$wpdb->get_var($wpdb->prepare(
        "SELECT COUNT(DISTINCT order_item_id) FROM {$wpdb->prefix}woocommerce_order_itemmeta
         WHERE meta_key='_variation_id' AND meta_value=%s",(string)$id));
    $uses=$wpdb->get_col($wpdb->prepare("SELECT post_id FROM {$wpdb->postmeta}
         WHERE meta_key='mahak_product_detail_id' AND meta_value=%s AND post_id<>%d",
         (string)$expect['target_detail'],$id));
    $pre[$id]=[
        'woo_id'=>$id,'sku'=>$v->get_sku(),'old_product_id'=>$currentProduct,
        'old_detail_id'=>$currentDetail,'target_product_id'=>10685134,
        'target_detail_id'=>$expect['target_detail'],'order_item_references'=>$orderRefs,
        'target_detail_already_assigned_to_other_woo'=>count($uses),
        'price'=>$v->get_price(),'stock'=>$v->get_stock_quantity(),
        'image_id'=>(int)$v->get_image_id(),'gallery'=>$v->get_gallery_image_ids()
    ];
    if($currentProduct===10685134 && $currentDetail===$expect['target_detail']){
        $skip[$id]='already_correct';continue;
    }
    if($currentProduct!==$expect['current_product']||$currentDetail!==$expect['current_detail']) {
        $skip[$id]='source_changed';continue;
    }
    if($orderRefs>0){$skip[$id]='historical_order_lines_require_review';continue;}
    if(count($uses)>0){$skip[$id]='target_detail_conflicts_with_other_variation';continue;}
    $eligible[$id]=$expect;
}
echo 'MEHRONA_SAFE_REPAIR_PREFLIGHT='.json_encode(['eligible'=>array_keys($eligible),'skipped'=>$skip,'rows'=>array_values($pre)],JSON_UNESCAPED_UNICODE).PHP_EOL;
if(!$commit){echo "MEHRONA_DRY_RUN_NO_MUTATIONS=yes\n";exit(0);}
if(!$eligible){echo "NO_ELIGIBLE_MAPPINGS_NO_WRITES=yes\n";exit(0);}
$lock='vesta_verified_existing_variation_catalog';
if((int)$wpdb->get_var($wpdb->prepare('SELECT GET_LOCK(%s,10)',$lock))!==1)exit(21);
$done=[];
try {
    foreach($eligible as $id=>$expect){
        // All critical assumptions checked once more under exclusive mutex.
        if((int)get_post_meta($id,'mahak_id',true)!==$expect['current_product']||
           (int)get_post_meta($id,'mahak_product_detail_id',true)!==$expect['current_detail'])throw new RuntimeException('concurrent_mapping_change');
        foreach(['mahak_id','mahak_product_detail_id'] as $key){
            if((int)$wpdb->get_var($wpdb->prepare("SELECT COUNT(*) FROM {$wpdb->postmeta} WHERE post_id=%d AND meta_key=%s",$id,$key))!==1)
                throw new RuntimeException('multiple_meta_rows');
        }
        $before=$pre[$id];$done[]=$id;
        if(update_post_meta($id,'mahak_id',(string)10685134)==false)throw new RuntimeException('write_product_id_failed');
        if(update_post_meta($id,'mahak_product_detail_id',(string)$expect['target_detail'])==false)throw new RuntimeException('write_detail_id_failed');
        $v=wc_get_product($id);
        if((int)get_post_meta($id,'mahak_id',true)!==10685134 ||
           (int)get_post_meta($id,'mahak_product_detail_id',true)!==$expect['target_detail'] ||
           $v->get_price()!==$before['price'] ||
           $v->get_stock_quantity()!==$before['stock'] ||
           $v->get_sku()!==$before['sku'] ||
           (int)$v->get_image_id()!==$before['image_id'] ||
           $v->get_gallery_image_ids()!==$before['gallery'])
             throw new RuntimeException('postwrite_parity_failed');
        echo 'MEHRONA_SAFE_MAPPING_FIXED='.$id.' ERP_PRODUCT=10685134 ERP_DETAIL='.$expect['target_detail'].PHP_EOL;
    }
}catch(Throwable $ex){
    foreach(array_reverse($done) as $id) {
        $expected=$targets[$id];
        update_post_meta($id,'mahak_id',(string)$expected['current_product']);
        update_post_meta($id,'mahak_product_detail_id',(string)$expected['current_detail']);
    }
    echo 'MEHRONA_REPAIR_ROLLED_BACK='.get_class($ex).' NO_REPLAY=yes'.PHP_EOL;exit(24);
}finally{$wpdb->get_var($wpdb->prepare('SELECT RELEASE_LOCK(%s)',$lock));}
echo 'MEHRONA_REPAIR_COUNT='.count($done).' NO_PRICE_STOCK_IMAGE_ORDER_ACCOUNTING_CHANGES=yes'.PHP_EOL;
