<?php
// Add verified existing Shopino bank mapping without modifying any other gateway or order.
error_reporting(E_ERROR|E_PARSE);ini_set('display_errors','0');
$_SERVER['HTTP_HOST']='vesta-cosmetics.ir';$_SERVER['SERVER_NAME']='vesta-cosmetics.ir';
$_SERVER['HTTPS']='on';$_SERVER['SERVER_PORT']='443';$_SERVER['REQUEST_URI']='/';
require '/var/www/html/wp-load.php';
global $wpdb;
$bankId=471168;
$found=$wpdb->get_results($wpdb->prepare("SELECT * FROM {$wpdb->prefix}bazara_banks WHERE BankId=%d LIMIT 2",$bankId),ARRAY_A);
if(count($found)!==1 || (int)($found[0]['Deleted']??1)!==0){
 echo "SHOPINO_ERP_BANK_NOT_UNIQUELY_ACTIVE_ABORT=yes\n";exit(21);
}
$label=(string)($found[0]['BankName']??$found[0]['Name']??'');
$norm=trim(preg_replace('/\s+/u',' ',str_replace(['ي','ك'],['ی','ک'],$label)));
if(!str_contains($norm,'شاپینو')){
 echo "SHOPINO_ERP_BANK_NAME_NOT_MATCHED_ABORT=yes\n";exit(22);
}
$opts=get_option('bazara_visitor_settings',[]);
$methods=json_decode(stripslashes($opts['banksMethods']??''),true);
if(!is_array($opts)||!is_array($methods)){echo "BANK_MAPPING_INVALID_ABORT=yes\n";exit(23);}
$existing=[];
foreach($methods as $x)if(($x['method']??'')==='shopino')$existing[]=$x;
if(count($existing)>1 || (count($existing)===1 && (string)($existing[0]['name']??'')!==(string)$bankId)){
 echo "SHOPINO_BANK_MAPPING_CONFLICT_ABORT=yes\n";exit(24);
}
if(count($existing)===0)$methods[]=['method'=>'shopino','name'=>(string)$bankId];
echo "SHOPINO_PAYMENT_MAPPING_VERIFIED_BANK_ID=".$bankId."\n";
echo "PREVIOUS_BANK_METHOD_MAPPING_COUNT=".(count($methods)-(count($existing)===0?1:0))."\n";
if(getenv('VC_SHOPINO_BANK_COMMIT')!=='yes'){echo "SHOPINO_BANK_DRYRUN_NO_WRITES=yes\n";exit(0);}
$opts['banksMethods']=wp_json_encode($methods,JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES);
update_option('bazara_visitor_settings',$opts,false);
$actual=get_option('bazara_visitor_settings',[]);
$arr=json_decode(stripslashes($actual['banksMethods']??''),true);
$matched=0;
foreach(is_array($arr)?$arr:[] as $x)if(($x['method']??'')==='shopino' && (string)($x['name']??'')===(string)$bankId)$matched++;
if($matched!==1){echo "SHOPINO_PAYMENT_READBACK_FAILED=yes\n";exit(25);}
echo "SHOPINO_BANK_MAPPING_SAVED_AND_VERIFIED=yes\n";
echo "NO_WOO_ORDERS_OR_PRICES_CHANGED=yes\n";
