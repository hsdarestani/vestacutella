<?php
// Read-only financial invariants: no customer identity, no order modifications.
error_reporting(E_ERROR|E_PARSE);ini_set('display_errors','0');
$_SERVER['HTTP_HOST']='vesta-cosmetics.ir';$_SERVER['SERVER_NAME']='vesta-cosmetics.ir';
$_SERVER['HTTPS']='on';$_SERVER['SERVER_PORT']='443';$_SERVER['REQUEST_URI']='/';
require '/var/www/html/wp-load.php';
global $wpdb;
$ids=$wpdb->get_col("SELECT ID FROM {$wpdb->posts} WHERE post_type='shop_order' AND ID>100000 ORDER BY ID DESC LIMIT 600");
$tested=0;$mismatches=0;$badTax=0;$badFee=0;$shipping=0;$discount=0;$buckets=[];
foreach($ids as $id){
 $o=wc_get_order($id);
 if(!$o||!$o->has_status(['completed','processing']))continue;
 $items=$o->get_items('line_item');
 if(!$items)continue;
 $sub=0;$lineDiscount=0;$lines=0;$itemTotal=0;
 foreach($items as $item){
  $qty=(float)$item->get_quantity();
  if($qty<=0){echo "BAD_ITEM_QTY=".$id."\n";$mismatches++;continue 2;}
  $sub+=(float)$item->get_subtotal();
  $lineDiscount+=max(0,(float)$item->get_subtotal()-(float)$item->get_total());
  $itemTotal+=(float)$item->get_total();
  $lines++;
 }
 $ship=(float)$o->get_shipping_total();
 $shipTax=(float)$o->get_shipping_tax();
 $tax=(float)$o->get_total_tax();
 $fees=0;
 foreach($o->get_items('fee') as $f)$fees+=(float)$f->get_total();
 $total=(float)$o->get_total();
 $expected=$sub-$lineDiscount+$ship+$tax+$fees;
 $calc=$itemTotal+$ship+$tax+$fees;
 $diff=abs($expected-$total);
 if($diff>0.51 || abs($calc-$total)>0.51){
   echo "ORDER_PARITY_MISMATCH=".$id." TOTAL=".$total." COMPUTED=".$expected." DIRECT=".$calc." DIFF=".$diff."\n";
   $mismatches++;
 }
 if(abs($tax)>0.001)$badTax++;
 if(abs($fees)>0.001)$badFee++;
 if($ship>0)$shipping++;
 if($lineDiscount>0)$discount++;
 $gateway=$o->get_payment_method();
 $buckets[$gateway]=($buckets[$gateway]??0)+1;
 $tested++;
}
echo "ORDERS_PARITY_CHECKED=".$tested."\n";
echo "PARITY_MISMATCH_COUNT=".$mismatches."\n";
echo "ORDERS_WITH_SHIPPING=".$shipping."\n";
echo "ORDERS_WITH_DISCOUNT=".$discount."\n";
echo "ORDERS_WITH_NONZERO_TAX=".$badTax."\n";
echo "ORDERS_WITH_NONZERO_FEES=".$badFee."\n";
foreach($buckets as $gateway=>$n)echo "GATEWAY=".$gateway." COUNT=".$n."\n";
echo "FINANCE_DRYRUN_ONLY_NO_DB_WRITES=yes\n";
if($tested<10 || $mismatches>0)exit(21);
