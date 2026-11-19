<?php
/**
 * Narrow, reversible Woo stock correction derived from the user's Nov 2
 * 2026 in-stock snapshot and all live Woo stock-reduced order items since then.
 * Only eligible rows have independent corroboration from the unique live
 * Bazara warehouse asset for the exact Mahak ProductDetailId.
 *
 * Does not change invoices, ERP warehouse data, Woo orders or product mappings.
 * Does not touch out-of-stock products, missing historical SKUs or other goods.
 *
 * Dry-run by default. Explicit CLI --apply required to mutate.
 */
error_reporting(E_ERROR|E_PARSE);
ini_set('display_errors','0');
set_time_limit(250);
$_SERVER['HTTP_HOST']='vesta-cosmetics.ir';
$_SERVER['SERVER_NAME']='vesta-cosmetics.ir';
$_SERVER['HTTPS']='on';$_SERVER['SERVER_PORT']='443';$_SERVER['REQUEST_URI']='/';
require '/var/www/html/wp-load.php';
global $wpdb;
$apply=in_array('--apply',$argv??[],true);
$targets=[
  102492=>['source_baseline'=>5,'expected'=>4,'old'=>3,'mahak'=>10685154,'detail'=>12183557,'parent'=>102488,'type'=>'variation'],
  69849=>['source_baseline'=>23,'expected'=>20,'old'=>19,'mahak'=>10685036,'detail'=>12183925,'parent'=>69843,'type'=>'variation'],
  24102=>['source_baseline'=>50,'expected'=>48,'old'=>46,'mahak'=>10685387,'detail'=>12182963,'parent'=>0,'type'=>'simple'],
];
$origin='2026-11-02 09:06:00';
$lock='vesta_11aban_woocommerce_stock_v1';
$gotLock=(int)$wpdb->get_var($wpdb->prepare("SELECT GET_LOCK(%s,8)",$lock));
if($gotLock!==1)throw new RuntimeException('Another stock correction is running');
$started=false;
try {
  $journalKey='vesta_11aban_stock_safe_repair_20261119_v1';
  $prior=get_option($journalKey,null);
  if(is_array($prior)){
    echo 'NOV02_REPAIR_ALREADY_JOURNALED='.wp_json_encode($prior).PHP_EOL;
    exit(0);
  }
  $sql=$wpdb->prepare("SELECT ID,post_status FROM {$wpdb->posts}
          WHERE post_type='shop_order' AND post_date_gmt>=%s ORDER BY ID",$origin);
  $orders=$wpdb->get_results($sql,ARRAY_A);
  $net=array_fill_keys(array_keys($targets),0.0);
  $failedOrCancelled=array_fill_keys(array_keys($targets),0.0);
  $paidOrders=[];
  $lineCounts=array_fill_keys(array_keys($targets),0);
  foreach($orders as $r) {
    $o=wc_get_order((int)$r['ID']);if(!$o)continue;
    foreach($o->get_items('line_item') as $item){
      $k=(int)($item->get_variation_id()?:$item->get_product_id());
      if(!array_key_exists($k,$targets))continue;
      if(abs((float)$o->get_qty_refunded_for_item($item->get_id()))>0)
        throw new RuntimeException("Refund on item ID ".$item->get_id()."; cannot auto-correct.");
      $lineCounts[$k]++;
      $reduced=$item->get_meta('_reduced_stock',true);
      $net[$k]+=is_numeric($reduced)?(float)$reduced:0.0;
      if(in_array($o->get_status(),['cancelled','failed'],true))
        $failedOrCancelled[$k]+=(float)$item->get_quantity();
      else if(in_array($o->get_status(),['processing','completed'],true)) {
        if((int)$o->get_meta('mahak_id',true)<=0)
          throw new RuntimeException("Paid order #".$o->get_id()." missing ERP ID for candidate ".$k);
        $paidOrders[]=(int)$o->get_id();
      }else throw new RuntimeException("Unexpected Woo order status ".$o->get_status());
    }
  }
  echo 'NOV02_SAFE_REPAIR_ORDER_FACTS='.wp_json_encode([
    'net_reduced'=>$net,'failed_cancelled_quantities'=>$failedOrCancelled,
    'order_item_counts'=>$lineCounts,'paid_erp_order_ids'=>array_values(array_unique($paidOrders))
  ],JSON_UNESCAPED_UNICODE).PHP_EOL;

  // Check exact warehouse StoreId 40851 and Mahak details. Never use
  // ProductDetails.Count1 as inventory.
  $results=[];
  foreach($targets as $id=>$t){
    $p=wc_get_product($id);
    if(!$p||$p->get_type()!==$t['type']||$p->get_status()!=='publish'||
       $p->get_sku()!==(string)$id || $p->get_parent_id()!==$t['parent']||
       !$p->get_manage_stock() ||
       (int)$p->get_meta('mahak_id',true)!==$t['mahak']||
       (int)$p->get_meta('mahak_product_detail_id',true)!==$t['detail']||
       (int)$p->get_stock_quantity()!==$t['old'])
        throw new RuntimeException("Live Woo product precondition mismatch for ".$id);
    $parent=$p->get_parent_id()?wc_get_product($p->get_parent_id()):$p;
    if(!$parent || (int)$parent->get_meta('mahak_id',true)!==$t['mahak'])
        throw new RuntimeException("Parent ERP identity not verified for ".$id);
    $skus=$wpdb->get_col($wpdb->prepare(
      "SELECT post_id FROM {$wpdb->postmeta} WHERE meta_key='_sku' AND meta_value=%s",strval($id)));
    if(count(array_unique($skus))!==1||(int)$skus[0]!==$id)
        throw new RuntimeException("SKU duplicated or remapped for ".$id);
    $linked=$wpdb->get_col($wpdb->prepare(
      "SELECT post_id FROM {$wpdb->postmeta} WHERE meta_key='mahak_product_detail_id'
       AND meta_value=%s",(string)$t['detail']));
    $activeLinked=[];
    foreach(array_unique($linked) as $other){
       $q=wc_get_product((int)$other);
       if($q&&in_array($q->get_status(),['publish','private'],true))$activeLinked[]=(int)$other;
    }
    if($activeLinked!==[$id])
        throw new RuntimeException("ERP detail appears on other active goods: ".$id);
    $rows=$wpdb->get_results($wpdb->prepare(
      "SELECT StoreId,Count1 FROM {$wpdb->prefix}bazara_product_assets
       WHERE ProductDetailId=%d AND Deleted=0",$t['detail']),ARRAY_A);
    if(count($rows)!==1||(int)$rows[0]['StoreId']!==40851 ||
       !is_numeric($rows[0]['Count1']) ||
       abs((float)$rows[0]['Count1']-$t['expected'])>0.00001)
        throw new RuntimeException("Unique Mahak warehouse quantity mismatched for ".$id);
    if(abs($t['source_baseline']-$net[$id]-$t['expected'])>0.00001 ||
       $t['expected']-$t['old']<=0 ||
       $failedOrCancelled[$id]<$t['expected']-$t['old'])
        throw new RuntimeException("Baseline/order/failed-restoration calculation mismatched for ".$id);
    $results[]=[
       'woo_id'=>$id,'sku'=>$p->get_sku(),
       'baseline_20261102'=>$t['source_baseline'],
       'current_stock'=>$t['old'],'verified_expected_stock'=>$t['expected'],
       'erp_actual_warehouse_stock'=>(float)$rows[0]['Count1'],
       'required_restore'=>$t['expected']-$t['old']
    ];
  }
  echo 'NOV02_SAFE_WOO_STOCK_PREFLIGHT='.wp_json_encode($results,JSON_UNESCAPED_UNICODE).PHP_EOL;
  if(!$apply){
    echo 'NOV02_SAFE_WOO_STOCK_DRY_RUN_PASS=yes'.PHP_EOL;
    echo 'NOV02_SAFE_WOO_STOCK_NO_WRITES=yes'.PHP_EOL;
    exit(0);
  }
  // InnoDB row locks also serialize Woo checkout's atomic _stock decrement.
  $wpdb->query('START TRANSACTION');$started=true;
  foreach($targets as $id=>$t){
    $rows=$wpdb->get_results($wpdb->prepare(
      "SELECT meta_id,meta_value FROM {$wpdb->postmeta}
       WHERE post_id=%d AND meta_key='_stock' FOR UPDATE",$id),ARRAY_A);
    if(count($rows)!==1||abs((float)$rows[0]['meta_value']-$t['old'])>0.00001)
      throw new RuntimeException("Stock changed while locking, abort all: ".$id);
    $asset=$wpdb->get_results($wpdb->prepare(
      "SELECT StoreId,Count1 FROM {$wpdb->prefix}bazara_product_assets
       WHERE ProductDetailId=%d AND Deleted=0 FOR UPDATE",$t['detail']),ARRAY_A);
    if(count($asset)!==1||(int)$asset[0]['StoreId']!==40851 ||
       abs((float)$asset[0]['Count1']-$t['expected'])>0.00001)
      throw new RuntimeException("Warehouse stock changed while locking, abort all: ".$id);
  }
  foreach($targets as $id=>$t){
    $r=wc_update_product_stock($id,$t['expected'],'set');
    if(is_wp_error($r)||!is_numeric($r)||abs((float)$r-$t['expected'])>0.00001)
      throw new RuntimeException("Woo stock set returned unexpected result: ".$id);
    $read=$wpdb->get_var($wpdb->prepare(
      "SELECT meta_value FROM {$wpdb->postmeta}
       WHERE post_id=%d AND meta_key='_stock' LIMIT 1",$id));
    if(!is_numeric($read)||abs((float)$read-$t['expected'])>0.00001)
      throw new RuntimeException("Post-write SQL stock readback failed: ".$id);
  }
  $journal=[
    'date_utc'=>gmdate('c'),'baseline_source'=>'Vesta_Products_In_Stock_SKU_Updated_2026-11-02.xlsx',
    'corrected'=>$results,'mode'=>'exact_ERP_baseline_and_Woo_stock_reduction_matched',
    'changed_in_erp'=>false,'changed_in_woo'=>true,'changed_orders'=>false
  ];
  if(!add_option($journalKey,$journal,'',false))
    throw new RuntimeException('Idempotency journal did not save; rolling back.');
  $wpdb->query('COMMIT');$started=false;
  foreach(array_keys($targets) as $id) {
    wc_delete_product_transients($id);
    $p=wc_get_product($id);
    if($p)$p->read_meta_data(true);
  }
  echo 'NOV02_BULK_SAFE_STOCK_REPAIRED='.wp_json_encode($journal,JSON_UNESCAPED_UNICODE).PHP_EOL;
  echo 'NOV02_SAFE_WOO_STOCK_APPLIED_AND_VERIFIED=yes'.PHP_EOL;
} catch(Throwable $e){
  if($started){$wpdb->query('ROLLBACK');foreach(array_keys($targets) as $id)wc_delete_product_transients($id);}
  echo 'NOV02_SAFE_STOCK_REPAIR_ABORTED='.get_class($e).':'.$e->getMessage().PHP_EOL;
  exit(31);
} finally {
  $wpdb->get_var($wpdb->prepare("SELECT RELEASE_LOCK(%s)",$lock));
}
