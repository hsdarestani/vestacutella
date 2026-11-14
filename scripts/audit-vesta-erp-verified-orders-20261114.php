<?php
// Read-only reconciliation of eligible Woo payments to cloud Bazaar invoices, amounts and receipts.
error_reporting(E_ERROR|E_PARSE);ini_set('display_errors','0');
$_SERVER['HTTP_HOST']='vesta-cosmetics.ir';$_SERVER['SERVER_NAME']='vesta-cosmetics.ir';$_SERVER['HTTPS']='on';$_SERVER['SERVER_PORT']='443';$_SERVER['REQUEST_URI']='/';
require '/var/www/html/wp-load.php';global $wpdb;
$api=new BazaraApi(true);
$r=$api->get_all_data('',array('fromOrderVersion'=>5144000000,'fromOrderDetailVersion'=>5144000000,'fromReceiptVersion'=>5144000000));
if(!is_array($r)||empty($r['success'])||!is_array($r['message']['Orders']??null)){
 echo "CLOUD_READ_FAILED_NO_RECONCILIATION=yes\n";exit(30);
}
$msg=$r['message'];$cloud=array();$details=array();$receipts=array();
foreach($msg['Orders'] as $x) {
 $id=(int)($x['OrderClientId']??0);
 if($id>0)$cloud[$id][]=$x;
}
foreach($msg['OrderDetails']??array() as $d)$details[(int)($d['OrderId']??0)][]=$d;
foreach($msg['Receipts']??array() as $v)$receipts[(int)($v['OrderId']??0)][]=1;
$ids=$wpdb->get_col("SELECT ID FROM {$wpdb->posts} WHERE post_type='shop_order' AND post_date_gmt>='2026-11-12 00:00:00' ORDER BY ID ASC");
$count=array('eligible'=>0,'cloud_confirmed'=>0,'financial_and_receipt_verified'=>0,'ready_without_cloud'=>0,'blocked_missing_mapping'=>0,'unpaid_or_uneligible'=>0,'cloud_multiple'=>0,'cloud_local_ack_disagree'=>0,'amount_or_receipt_mismatch'=>0,'cloud_missing_local_ack'=>0,'cloud_missing_details'=>0);
foreach($ids as $id) {
 $id=(int)$id;$o=wc_get_order($id);if(!$o)continue;
 if(!$o->has_status(array('processing','completed','processing5','pws-packaged','pws-shipping','arrival-shipment'))||!$o->get_date_paid()){$count['unpaid_or_uneligible']++;continue;}
 $count['eligible']++;
 $ack=(int)$o->get_meta('mahak_id');$rows=$cloud[$id]??array();$n=count($rows);
 if($n>1){$count['cloud_multiple']++;echo "ISSUE=$id CODE=multiple_cloud_orders N=$n\n";continue;}
 if($n===0){
  if($ack>0){$count['cloud_local_ack_disagree']++;echo "ISSUE=$id CODE=local_ack_no_cloud ID=$ack\n";continue;}
  $bad=array();foreach($o->get_items('line_item') as $item){
   $pid=(int)($item->get_variation_id()?:$item->get_product_id());
   if((int)get_post_meta($pid,'mahak_id',true)<=0||(int)get_post_meta($pid,'mahak_product_detail_id',true)<=0)$bad[]=$pid;
  }
  if($bad){$count['blocked_missing_mapping']++;echo "ISSUE=$id CODE=needs_erp_variant MISSING=".implode(',',$bad)."\n";}
  else {$count['ready_without_cloud']++;echo "ISSUE=$id CODE=ready_waiting_in_queue\n";}
  continue;
 }
 $count['cloud_confirmed']++;
 $row=$rows[0];$erp=(int)($row['OrderId']??0);
 if($ack!==$erp){$count['cloud_local_ack_disagree']++;echo "ISSUE=$id CODE=cloud_ack_mismatch ACK=$ack ERP=$erp\n";}
 $lines=$details[$erp]??array();
 if(!$lines){$count['cloud_missing_details']++;echo "ISSUE=$id CODE=cloud_order_no_details\n";continue;}
 $gross=0;$discount=0;
 foreach($lines as $d){$gross+=(float)($d['Price']??0)*(float)($d['Count1']??0);$discount+=(float)($d['Discount']??0);}
 $ship=(float)($row['SendCost']??0);
 $calc=$gross-$discount-(float)($row['Discount']??0)+$ship;
 $expected=(float)$o->get_total()*10;
 $receiptCount=count($receipts[$erp]??array());
 if(abs($expected-$calc)>0.51||abs($ship-(float)$o->get_shipping_total()*10)>0.51||$receiptCount===0){
  $count['amount_or_receipt_mismatch']++;
  echo "ISSUE=$id CODE=accounting_parity_mismatch EXPECTED_RIAL=$expected CLOUD_RIAL=$calc SHIP_RIAL=$ship RECEIPTS=$receiptCount\n";
 }else $count['financial_and_receipt_verified']++;
}
foreach($count as $k=>$v)echo strtoupper($k)."=".$v."\n";
echo "CLOUD_ORDER_FIELDS=".implode(',',array_keys($msg['Orders'][0]??array()))."\n";
echo "READ_ONLY_CLOUD_AND_WOO_RECONCILIATION_FINISHED=yes\n";
