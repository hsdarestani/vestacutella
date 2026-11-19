<?php
// Vesta new accounting epoch: pause legacy finance and ERP-to-Woo product imports.
// Writes ONLY synchronization options and a durable epoch marker; never changes
// Woo products, inventory, Woo orders, payment records or Mahak invoices.
error_reporting(E_ERROR | E_PARSE);
ini_set('display_errors','0');
set_time_limit(180);
$_SERVER['HTTP_HOST']='vesta-cosmetics.ir';
$_SERVER['SERVER_NAME']='vesta-cosmetics.ir';
$_SERVER['HTTPS']='on'; $_SERVER['SERVER_PORT']='443';
$_SERVER['REQUEST_URI']='/';
require '/var/www/html/wp-load.php';
global $wpdb;
if (!class_exists('Vesta_Accounting_Reliability') || !class_exists('BazaraApi')) {
    throw new RuntimeException('accounting_bridge_not_loaded');
}
if (get_option('woocommerce_custom_orders_table_enabled')==='yes') {
    throw new RuntimeException('HPOS_cutover_not_implemented');
}
$lockPath='/tmp/vesta-bazara-order-sync.lock';
$lock=is_file($lockPath)?fopen($lockPath,'r'):fopen($lockPath,'c+');
if (!$lock) throw new RuntimeException('sender_lock_unavailable');
$got=false;
for ($i=0;$i<120;$i++) {
    if (flock($lock,LOCK_EX|LOCK_NB)) {$got=true;break;}
    usleep(150000);
}
if (!$got) throw new RuntimeException('sender_lock_busy');
try {
    $old=get_option('vcar_new_accounting_epoch',[]);
    if (!empty($old['epoch_utc'])) {
        fwrite(STDERR, "EPOCH_ALREADY_REGISTERED=".wp_json_encode($old).PHP_EOL);
        throw new RuntimeException('new_epoch_already_exists_no_duplicate_reset');
    }
    $max=(int)$wpdb->get_var("SELECT COALESCE(MAX(ID),0) FROM {$wpdb->posts} WHERE post_type='shop_order'");
    $utc=(string)$wpdb->get_var('SELECT UTC_TIMESTAMP()');
    if (!$utc || !$max) throw new RuntimeException('unable_to_mark_epoch');
    $settings=get_option('bazara_visitor_settings',[]);
    if (!is_array($settings)) throw new RuntimeException('bazara_settings_not_array');
    // Preserve configuration for later reconnection; never log credentials.
    $prior=[
      'vcar_sender_enabled'=>get_option('vcar_sender_enabled',false),
      'vesta_mhi_auto_disabled'=>get_option('vesta_mhi_auto_disabled',false),
      'bazara_visitor_settings'=>$settings
    ];
    // Persist the previous settings privately in WP option, not in a public artifact.
    if (!add_option('vcar_new_accounting_previous_settings',$prior,'','no')) {
        throw new RuntimeException('previous_settings_slot_already_exists');
    }
    // Cut finance before recording the epoch: no in-flight outbox sender can pass this lock.
    update_option('vcar_sender_enabled',false,false);
    update_option('vesta_mhi_auto_disabled',true,false);
    foreach (['chkProduct','chkQuantity','chkRegularPrice','chkPrice','chkSalePrice','chkPicture'] as $key) {
        if (array_key_exists($key,$settings)) $settings[$key]=0;
    }
    update_option('bazara_visitor_settings',$settings,false);
    $epoch=[
      'epoch_utc'=>gmdate('Y-m-d\TH:i:s\Z',strtotime($utc.' UTC')),
      'last_legacy_order_id'=>$max,
      'state'=>'waiting_for_new_mahak_company_and_opening_stock',
      'site_stock_is_source_of_truth'=>true,
      'old_orders_must_never_replay'=>true,
      'snapshot_status'=>'in_progress'
    ];
    if (!add_option('vcar_new_accounting_epoch',$epoch,'','no')) {
        throw new RuntimeException('new_epoch_option_not_created');
    }
    if (function_exists('as_unschedule_all_actions')) {
        as_unschedule_all_actions('bazara_run_product_sync');
    }
    fwrite(STDERR,'NEW_ACCOUNTING_EPOCH='.wp_json_encode($epoch,JSON_UNESCAPED_UNICODE).PHP_EOL);
    fwrite(STDERR,'LEGACY_ACCOUNTING_SENDER_PAUSED=yes'.PHP_EOL);
    fwrite(STDERR,'LEGACY_ERP_PRODUCT_IMPORT_PAUSED=yes'.PHP_EOL);
} finally {
    flock($lock,LOCK_UN);fclose($lock);
}
// No customer / order details are exported, only Woo catalog IDs and inventory data.
$fp=fopen('php://output','w');
fputcsv($fp,['woo_id','type','parent_id','sku','name','variation_attributes','status',
 'manage_stock','stock_owner_id','stock_quantity','stock_status','price_toman',
 'regular_price_toman','mahak_product_id_legacy','mahak_detail_id_legacy']);
$count=0;$unquantified=0;$owners=[];
$ids=$wpdb->get_col("SELECT ID FROM {$wpdb->posts} WHERE post_type IN ('product','product_variation') ORDER BY ID");
foreach ($ids as $id) {
    $p=wc_get_product((int)$id);
    if (!$p) continue;
    $owner=method_exists($p,'get_stock_managed_by_id')?(int)$p->get_stock_managed_by_id():$p->get_id();
    if ($p->get_manage_stock()) $owners[$owner]=true;
    if ($p->get_stock_quantity()===null) $unquantified++;
    $attributes=[];
    if ($p->is_type('variation')) foreach ($p->get_variation_attributes() as $k=>$v) {
        $attrs=substr($k,10);$value=(string)$v;
        if (taxonomy_exists($attrs)) {
            $term=get_term_by('slug',$value,$attrs);
            if ($term&&!is_wp_error($term)) $value=$term->name;
        }
        $attributes[]=$attrs.':'.$value;
    }
    fputcsv($fp,[$p->get_id(),$p->get_type(),$p->get_parent_id(),$p->get_sku(),
      $p->get_name(),implode(' | ',$attributes),$p->get_status(),
      $p->get_manage_stock()?'yes':'no',$owner,
      $p->get_stock_quantity()===null?'':$p->get_stock_quantity(),$p->get_stock_status(),
      $p->get_price(),$p->get_regular_price(),
      $p->get_meta('mahak_id',true),$p->get_meta('mahak_product_detail_id',true)]);
    $count++;
}
fclose($fp);
$endMax=(int)$wpdb->get_var("SELECT COALESCE(MAX(ID),0) FROM {$wpdb->posts} WHERE post_type='shop_order'");
$epoch=get_option('vcar_new_accounting_epoch',[]);
$epoch['snapshot_status']=$endMax===(int)$epoch['last_legacy_order_id']?'captured_no_new_orders_during_export':'review_orders_created_during_export';
$epoch['products_exported']=$count;
$epoch['stock_owners_managed']=count($owners);
$epoch['rows_with_null_quantity']=$unquantified;
$epoch['last_order_after_export']=$endMax;
$epoch['snapshot_finished_utc']=gmdate('c');
update_option('vcar_new_accounting_epoch',$epoch,false);
fwrite(STDERR,'OPENING_STOCK_EXPORT='.wp_json_encode([
  'products'=>$count,'managed_stock_owners'=>count($owners),
  'null_qty_rows'=>$unquantified,'snapshot_status'=>$epoch['snapshot_status'],
  'cutoff_order_id'=>$epoch['last_legacy_order_id'],'latest_order_id'=>$endMax
],JSON_UNESCAPED_UNICODE).PHP_EOL);
