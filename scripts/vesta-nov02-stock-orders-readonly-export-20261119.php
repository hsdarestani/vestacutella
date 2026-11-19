<?php
// Read-only export for reconciling the confirmed 11 Aban Woo inventory snapshot.
// NEVER changes orders, products, invoices, stock or mappings.
error_reporting(E_ERROR|E_PARSE);
ini_set('display_errors','0');
set_time_limit(0);
$_SERVER['HTTP_HOST']='vesta-cosmetics.ir';$_SERVER['SERVER_NAME']='vesta-cosmetics.ir';
$_SERVER['HTTPS']='on';$_SERVER['SERVER_PORT']='443';$_SERVER['REQUEST_URI']='/';
require '/var/www/html/wp-load.php';
global $wpdb;
$dir='/tmp/vesta-reconcile-nov02';
if(!is_dir($dir))mkdir($dir,0700,true);
$base='2026-11-02 09:06:00';
$pm=$wpdb->prefix;
function fcsv($fp,$row){fputcsv($fp,$row,',','"', '\\');}
function ent($v){return $v===null?'':strval($v);}
function outf($name,$columns){global $dir;$f=fopen("$dir/$name",'wb');fcsv($f,$columns);return $f;}
// Load all local warehouse asset rows in one query. Count1 on ProductDetails is NOT stock.
$assetMap=[];
$assetData=$wpdb->get_results("SELECT ProductDetailId,StoreId,Count1 FROM {$pm}bazara_product_assets WHERE Deleted=0",ARRAY_A);
foreach($assetData as $row){$detail=(int)$row['ProductDetailId'];$assetMap[$detail][]=$row;}
$productFile=outf('products.csv',[
  'woo_id','sku','name','type','status','parent_id','manage_stock',
  'stock_qty','stock_status','mahak_product_id','mahak_detail_id',
  'asset_rows','store_id','mahak_warehouse_qty','woo_last_modified_utc',
  'woo_price','woo_regular_price'
]);
$products=0;$assetUnique=0;$assetAmbiguous=0;
$posts=$wpdb->get_col("SELECT ID FROM {$wpdb->posts} WHERE post_type IN ('product','product_variation') ORDER BY ID");
foreach($posts as $id) {
 $p=wc_get_product((int)$id);if(!$p)continue;
 $did=(int)$p->get_meta('mahak_product_detail_id',true);
 $assets=$assetMap[$did]??[];
 $assetCount=count($assets);
 $warehouseQty=$assetCount===1?(string)$assets[0]['Count1']:'';
 $store=$assetCount===1?(string)$assets[0]['StoreId']:'';
 if($assetCount===1)$assetUnique++;
 if($assetCount>1)$assetAmbiguous++;
 $updated=$p->get_date_modified();
 fcsv($productFile,[
  $p->get_id(),$p->get_sku(),$p->get_name(),$p->get_type(),$p->get_status(),$p->get_parent_id(),
  $p->get_manage_stock()?'yes':'no',ent($p->get_stock_quantity()),$p->get_stock_status(),
  $p->get_meta('mahak_id',true),$did,$assetCount,$store,$warehouseQty,
  $updated?$updated->date('Y-m-d H:i:s'):'',
  $p->get_price(),$p->get_regular_price()
 ]);
 $products++;
}
fclose($productFile);
$orderFile=outf('orders.csv',[
 'woo_order_id','created_gmt','paid_gmt','status','currency','total',
 'order_stock_reduced','mahak_id','local_bazara_order_count','local_mahak_order_id',
 'item_id','woo_product_id','woo_variation_id','item_stock_target_id',
 'item_qty','item_refunded_qty','item_reduced_stock','item_total'
]);
$sql=$wpdb->prepare("SELECT ID,post_date_gmt FROM {$wpdb->posts}
 WHERE post_type='shop_order' AND post_date_gmt>=%s ORDER BY post_date_gmt,ID",$base);
$orderRows=$wpdb->get_results($sql,ARRAY_A);
$remoteIds=[];
foreach($wpdb->get_results("SELECT OrderClientId,OrderId FROM {$pm}bazara_orders WHERE Deleted=0",ARRAY_A) as $remote) {
  $id=(int)$remote['OrderClientId'];if($id<=0)continue;
  $remoteIds[$id][]=(int)$remote['OrderId'];
}
$orders=0;$paid=0;$items=0;$itemsStockReduced=0;
foreach($orderRows as $row){
  $id=(int)$row['ID'];$o=wc_get_order($id);if(!$o)continue;
  $orders++;
  $paidDate=$o->get_date_paid();
  if($paidDate)$paid++;
  $sr=$o->get_meta('_order_stock_reduced',true);
  $sr=($sr===false||$sr===null)?'':strval($sr);
  $erp=$o->get_meta('mahak_id',true);
  foreach($o->get_items('line_item') as $item) {
    $items++;
    $red=$item->get_meta('_reduced_stock',true);
    if($red!==null&&$red!==''&&$red!==false)$itemsStockReduced++;
    $var=(int)$item->get_variation_id();$woo=(int)$item->get_product_id();
    fcsv($orderFile,[
     $id,$row['post_date_gmt'],$paidDate?$paidDate->date('Y-m-d H:i:s'):'',
     $o->get_status(),$o->get_currency(),$o->get_total(),$sr,$erp,
     count($remoteIds[$id]??[]),
     count($remoteIds[$id]??[])===1?$remoteIds[$id][0]:'',
     $item->get_id(),$woo,$var,$var?:$woo,
     $item->get_quantity(),$o->get_qty_refunded_for_item($item->get_id()),ent($red),$item->get_total()
    ]);
  }
}
fclose($orderFile);
// Summary outbox state counts only. Never write or resend disputed orders.
$outbox=$wpdb->prefix.'vesta_accounting_outbox';
$found=$wpdb->get_var($wpdb->prepare('SHOW TABLES LIKE %s',$outbox));
$outboxSchema=$found?$wpdb->get_col("SHOW COLUMNS FROM $outbox",0):[];
$summary=[
 'created_utc'=>gmdate('c'),'cutoff_utc'=>$base,
 'all_woo_products'=>$products,
 'warehouse_unique_details'=>$assetUnique,'warehouse_ambiguous_details'=>$assetAmbiguous,
 'orders'=>$orders,'paid_orders'=>$paid,
 'order_line_items'=>$items,'line_items_with_woo_stock_reduced_flag'=>$itemsStockReduced,
 'order_statuses'=>array_count_values(array_map(fn($x)=>(string)$x['post_date_gmt']?$x['post_date_gmt']:'',array_filter($orderRows,fn($x)=>false))),
 'outbox_exists'=>(bool)$found,'outbox_columns'=>$outboxSchema,
 'accounting_storage'=>'posts',
 'stock_source'=>'wp_bazara_product_assets.Count1 per ProductDetailId+StoreId, never ProductDetails.Count1'
];
file_put_contents("$dir/summary.json",json_encode($summary,JSON_UNESCAPED_UNICODE|JSON_PRETTY_PRINT));
echo 'VESTA_NOV02_READONLY_EXPORT_SUMMARY='.json_encode($summary,JSON_UNESCAPED_UNICODE).PHP_EOL;
echo 'VESTA_NOV02_READONLY_EXPORT_SUCCESS=yes'.PHP_EOL;
