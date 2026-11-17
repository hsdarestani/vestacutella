<?php
require $argv[1];
function wc_get_is_paid_statuses(){return array('processing','completed');}
function get_post_meta($id,$key,$single){return $key==='mahak_id'?7:9;}
class TestItem {
 function get_variation_id(){return 1;} function get_product_id(){return 2;}
 function get_total(){return 180;} function get_subtotal(){return 200;} function get_quantity(){return 2;}
}
class TestOrder {
 function get_id(){return 33;} function get_date_paid(){return true;}
 function has_status($s){return in_array('pws-courier',$s,true);}
 function get_currency(){return 'IRT';} function get_total_tax(){return 0;}
 function get_items($type){return $type==='fee'?array():array(new TestItem);}
 function get_shipping_total(){return 20;} function get_total(){return 200;}
}
function check($condition,$name){if(!$condition){fwrite(STDERR,'FAIL '.$name."\n");exit(1);}echo 'PASS '.$name."\n";}
$deadlock=['Result'=>false,'Code'=>1,'Message'=>'Transaction (Process ID 123) was deadlocked on lock resources with another process and has been chosen as the deadlock victim. Rerun the transaction.'];
check(vcar_definite_rollback(json_encode($deadlock)),'explicit_sql_1205_rollback_recognized');
check(vcar_definite_rollback('{"success":false,"message":"'.json_encode($deadlock).'"}'),'vendor_nested_json_slash_loss_recovered');
check(!vcar_definite_rollback('{"Result":false,"Message":"Timeout while saving transaction"}'),'generic_timeout_is_never_proof_of_rollback');
check(!vcar_definite_rollback('{"Result":false,"Message":"deadlock"}'),'generic_deadlock_word_is_not_sufficient');
$o=new TestOrder;
$row=array('OrderId'=>88,'OrderClientId'=>33,'SendCost'=>200,'ReceiptId'=>44);
$lines=array(array('ProductDetailId'=>9,'Count1'=>2,'Price'=>1000,'Discount'=>200));
$receipts=array(array('OrderId'=>88,'ReceiptId'=>44,'CashAmount'=>0));
$transfers=array(array('ReceiptId'=>44,'BankId'=>55,'Amount'=>2000,'Type'=>2));
check(vcar_eligible($o),'paid_custom_shipping_status');
check(vcar_bank(array('banksMethods'=>'[{"method":"x","name":"55"}]'),'x')===55,'exact_bank');
check(vcar_bank(array('banksMethods'=>'[{"method":"x","name":"55"},{"method":"x","name":"55"}]'),'x')===0,'duplicate_bank_setting_rejected');
check(vcar_verify($o,$row,$lines,$receipts,55,$transfers)==='','correct_invoice_discount_shipping_receipt_bank');
$nullable=$row;$nullable['ReceiptId']=null;
check(vcar_verify($o,$nullable,$lines,$receipts,55,$transfers)==='','receipt_order_link_with_nullable_header');
$wrong=$receipts;$wrong[0]['OrderId']=777;
check(vcar_verify($o,$row,$lines,$wrong,55,$transfers)==='receipt_link','receipt_for_wrong_invoice_rejected');
$bad=$lines;$bad[0]['ProductDetailId']=99;
check(vcar_verify($o,$row,$bad,$receipts,55,$transfers)==='line_quantity_or_amount','equal_total_wrong_product_rejected');
$bad=$lines;$bad[0]['Count1']=1;
check(vcar_verify($o,$row,$bad,$receipts,55,$transfers)==='line_quantity_or_amount','wrong_quantity_rejected');
$bad=$row;$bad['SendCost']=0;
check(vcar_verify($o,$bad,$lines,$receipts,55,$transfers)==='invoice_total_or_shipping','shipping_missing_rejected');
check(vcar_verify($o,$row,$lines,array(),55,$transfers)==='missing_receipt','missing_receipt_rejected');
check(vcar_verify($o,$row,$lines,array_merge($receipts,$receipts),55,$transfers)==='multiple_receipts','duplicate_receipts_rejected');
check(vcar_verify($o,$row,$lines,$receipts,99,$transfers)==='receipt_bank','wrong_bank_rejected');
$bad=$transfers;$bad[0]['Amount']=200;
check(vcar_verify($o,$row,$lines,$receipts,55,$bad)==='receipt_amount','rial_toman_error_rejected');
check(vcar_verify($o,$row,$lines,$receipts,55,array())==='bank_transfer_unverified','receipt_presence_alone_not_success');

$tomanRow=$row;$tomanRow['SendCost']=20;
$tomanLines=$lines;$tomanLines[0]['Price']=100;$tomanLines[0]['Discount']=20;
$tomanTransfers=$transfers;$tomanTransfers[0]['Amount']=200;
check(vcar_verify($o,$tomanRow,$tomanLines,$receipts,55,$tomanTransfers,1)==='', 'toman_invoice_discount_shipping_and_receipt_match');
check(vcar_verify($o,$row,$lines,$receipts,55,$transfers,1)==='line_quantity_or_amount','new_toman_invoice_cannot_accept_rial_amounts');
check(vcar_verify($o,$tomanRow,$tomanLines,$receipts,55,$tomanTransfers)==='line_quantity_or_amount','legacy_rial_invoice_cannot_accept_toman_amounts');
$wrongUnitReceipt=$tomanTransfers;$wrongUnitReceipt[0]['Amount']=2000;
check(vcar_verify($o,$tomanRow,$tomanLines,$receipts,55,$wrongUnitReceipt,1)==='receipt_amount','mixed_toman_invoice_rial_receipt_rejected');

class TestTomanOrder extends TestOrder { function get_meta($key){return $key==='_vcar_money_multiplier'?1:0;} }
check(vcar_verify(new TestTomanOrder,$tomanRow,$tomanLines,$receipts,55,$tomanTransfers)==='','standalone_monitor_uses_persisted_toman_unit');

class HeaderCouponItem {
 function get_variation_id(){return 100;} function get_product_id(){return 0;}
 function get_quantity(){return 6;} function get_subtotal(){return 450000;} function get_total(){return 2250;}
}
class HeaderCouponOrder extends TestOrder {
 function get_id(){return 105203;} function get_items($type){return $type==='fee'?[]:[new HeaderCouponItem];}
 function get_shipping_total(){return 0;} function get_total(){return 2250;}
 function get_discount_total(){return 447750;}
}
$couponOrder=new HeaderCouponOrder();
$couponRow=['OrderId'=>308569697,'OrderClientId'=>105203,'SendCost'=>0,'Discount'=>447750,'ReceiptId'=>null];
$couponLines=[['ProductDetailId'=>9,'Count1'=>6,'Price'=>75000,'Discount'=>0]];
$couponReceipts=[['OrderId'=>308569697,'ReceiptId'=>65124614,'CashAmount'=>0]];
$couponTransfers=[['ReceiptId'=>65124614,'BankId'=>55,'Amount'=>2250,'Type'=>2]];
check(vcar_verify($couponOrder,$couponRow,$couponLines,$couponReceipts,55,$couponTransfers,1)==='','legitimate_coupon_booked_on_header_not_again_on_lines');
$couponBad=$couponRow;$couponBad['Discount']=0;
check(vcar_verify($couponOrder,$couponBad,$couponLines,$couponReceipts,55,$couponTransfers,1)==='line_quantity_or_amount','missing_coupon_header_does_not_bypass_line_check');
$couponBad=$couponLines;$couponBad[0]['Price']=76000;
check(vcar_verify($couponOrder,$couponRow,$couponBad,$couponReceipts,55,$couponTransfers,1)==='line_quantity_or_amount','wrong_gross_line_cannot_hide_behind_header_discount');
$couponBad=$couponRow;$couponBad['SendCost']=150000;
check(vcar_verify($couponOrder,$couponBad,$couponLines,$couponReceipts,55,$couponTransfers,1)==='invoice_total_or_shipping','fake_shipping_not_accepted_with_coupon');
$couponBad=$couponTransfers;$couponBad[0]['Amount']=450000;
check(vcar_verify($couponOrder,$couponRow,$couponLines,$couponReceipts,55,$couponBad,1)==='receipt_amount','wrong_coupon_payment_still_rejected');
echo 'STRICT_HEADER_COUPON_REGRESSION_COMPLETE=yes'.PHP_EOL;
