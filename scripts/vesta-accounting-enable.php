<?php
error_reporting(E_ERROR|E_PARSE);ini_set('display_errors','0');
$_SERVER['HTTP_HOST']='vesta-cosmetics.ir';$_SERVER['SERVER_NAME']='vesta-cosmetics.ir';$_SERVER['HTTPS']='on';$_SERVER['SERVER_PORT']='443';$_SERVER['REQUEST_URI']='/';
require '/var/www/html/wp-load.php';global $wpdb;
$api=new BazaraApi(true);$cloud=Vesta_Accounting_Reliability::cloud($api);
$s=get_option('bazara_visitor_settings',array());$verified=0;$bad=0;
if(empty($s['chkBankOrder'])){echo "MAPPED_BANK_SELECTION_DISABLED=yes\n";exit(31);}
$ids=$wpdb->get_col("SELECT ID FROM {$wpdb->posts} WHERE post_type='shop_order' AND post_date_gmt>='2026-11-12 00:00:00'");
foreach($ids as $id){
 $id=(int)$id;$o=wc_get_order($id);if(!vcar_eligible($o))continue;
 $rows=$cloud['orders'][$id]??array();if(!$rows)continue;
 if(count($rows)!==1){$bad++;continue;}
 $r=$rows[0];$erp=(int)$r['OrderId'];
 $error=vcar_verify($o,$r,$cloud['details'][$erp]??array(),$cloud['receipts'][$erp]??array(),vcar_bank($s,$o->get_payment_method()),$cloud['transfers']);
 Vesta_Accounting_Reliability::verify($id,$o,$cloud,vcar_bank($s,$o->get_payment_method()));
 if($error){$bad++;echo 'CANARY_REJECTED_ORDER='.$id.' REASON='.$error."\n";}
 else{$verified++;echo 'VERIFIED_REAL_ORDER='.$id.' REMOTE_INVOICE='.$erp."\n";}
}
echo 'CANARY_VERIFIED='.$verified.' CANARY_FAILED='.$bad."\n";
if($verified<5||$bad){echo "SENDER_ENABLE_BLOCKED=yes\n";exit(32);}
update_option('vcar_sender_enabled',true,false);
echo "DURABLE_SENDER_ENABLED=yes\n";
