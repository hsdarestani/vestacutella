<?php
require $argv[1];
function wc_get_is_paid_statuses(){return array('processing','completed');}
function get_post_meta($id,$key,$single){return $key==='mahak_id'?7:9;}
class TestItem {
 function get_variation_id(){return 1;} function get_product_id(){return 2;}
 function get_total(){return 180;} function get_quantity(){return 2;}
}
class TestOrder {
 function get_id(){return 33;} function get_date_paid(){return true;}
 function has_status($s){return in_array('pws-courier',$s,true);}
 function get_currency(){return 'IRT';} function get_total_tax(){return 0;}
 function get_items($type){return $type==='fee'?array():array(new TestItem);}
 function get_shipping_total(){return 20;} function get_total(){return 200;}
}
function check($condition,$name){if(!$condition){fwrite(STDERR,'FAIL '.$name."\n");exit(1);}echo 'PASS '.$name."\n";}
$o=new TestOrder;
$row=array('OrderClientId'=>33,'SendCost'=>200,'ReceiptId'=>44);
$lines=array(array('ProductDetailId'=>9,'Count1'=>2,'Price'=>1000,'Discount'=>200));
$receipts=array(array('ReceiptId'=>44,'CashAmount'=>0));
$transfers=array(array('ReceiptId'=>44,'BankId'=>55,'Amount'=>2000));
check(vcar_eligible($o),'paid_custom_shipping_status');
check(vcar_bank(array('banksMethods'=>'[{"method":"x","name":"55"}]'),'x')===55,'exact_bank');
check(vcar_bank(array('banksMethods'=>'[{"method":"x","name":"55"},{"method":"x","name":"55"}]'),'x')===0,'duplicate_bank_setting_rejected');
check(vcar_verify($o,$row,$lines,$receipts,55,$transfers)==='','correct_invoice_discount_shipping_receipt_bank');
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
