<?php
// Strictly map current site customer-paid shipping methods to the existing ERP person "کرایه حمل سایت".
error_reporting(E_ERROR|E_PARSE);ini_set('display_errors','0');
$_SERVER['HTTP_HOST']='vesta-cosmetics.ir';$_SERVER['SERVER_NAME']='vesta-cosmetics.ir';
$_SERVER['HTTPS']='on';$_SERVER['SERVER_PORT']='443';$_SERVER['REQUEST_URI']='/';
require '/var/www/html/wp-load.php';
global $wpdb;
$erpPerson=12677843;
$rows=$wpdb->get_results($wpdb->prepare(
 "SELECT PersonId,FirstName,LastName,Deleted FROM {$wpdb->prefix}bazara_persons WHERE PersonId=%d LIMIT 2",$erpPerson
));
if(count($rows)!==1||(int)$rows[0]->Deleted!==0){
 echo "VALIDATED_CARRIER_PERSON_NOT_FOUND_ABORT=yes\n";exit(20);
}
$full=trim((string)$rows[0]->FirstName.' '.(string)$rows[0]->LastName);
$norm=trim(preg_replace('/\s+/u',' ',str_replace(['ي','ك'],['ی','ک'],$full)));
if($norm!=='کرایه حمل سایت' && $norm!=='کرایه حمل  سایت'){
 echo "EXPECTED_CARRIER_PERSON_NAME_MISMATCH_ABORT=yes\n";exit(21);
}
$options=get_option('bazara_visitor_settings',[]);
if(!is_array($options)||empty($options['chkShippingOrder'])){
 echo "SHIPPING_OPTION_DISABLED_ABORT=yes\n";exit(22);
}
$maps=json_decode(stripslashes($options['carrierMethods']??''),true);
if(!is_array($maps)) {echo "INVALID_CARRIER_METHODS_JSON_ABORT=yes\n";exit(23);}
$target=['flat_rate','shopino_shipping'];
$counts=[];$present=[];
foreach($maps as $i=>$row){
 if(!is_array($row) || !isset($row['method']))continue;
 $method=(string)$row['method'];
 if(!in_array($method,$target,true))continue;
 $counts[$method]=($counts[$method]??0)+1;
 $old=$row['name']??null;
 if($old!==null && $old!=='' && (string)$old!==(string)$erpPerson){
  echo "CARRIER_METHOD_CONFLICT_ABORT=".$method."\n";exit(24);
 }
 $maps[$i]['name']=(string)$erpPerson;
 $present[$method]=1;
}
if(($counts['flat_rate']??0)!==1||($counts['shopino_shipping']??0)>1){
 echo "CARRIER_METHOD_DUPLICATE_OR_MISSING_ABORT=yes\n";exit(25);
}
if(!isset($present['shopino_shipping']))$maps[]=['method'=>'shopino_shipping','name'=>(string)$erpPerson];
foreach($target as $method)echo "VERIFIED_CARRIER_MAPPING_METHOD=".$method." PERSON_ID=".$erpPerson."\n";
echo "EXISTING_CARRIER_ACCOUNT_PRECHECK=pass\n";
if(getenv('VC_CARRIER_MAP_COMMIT')!=='yes'){
 echo "NO_WRITES_DRYRUN=yes\n";exit(0);
}
$next=$options;
$next['carrierMethods']=wp_json_encode($maps,JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES);
$before=$options['carrierMethods']??'';
if(!update_option('bazara_visitor_settings',$next,false) && $before!==$next['carrierMethods']){
 echo "OPTION_UPDATE_FAILED_ABORT=yes\n";exit(26);
}
$stored=get_option('bazara_visitor_settings',[]);
$actual=json_decode(stripslashes($stored['carrierMethods']??''),true);
if(!is_array($actual)){echo "STORED_OPTION_JSON_BAD=yes\n";exit(27);}
foreach($target as $method){
 $values=[];
 foreach($actual as $a)if(($a['method']??'')===$method)$values[]=(string)($a['name']??'');
 if(count($values)!==1||$values[0]!==(string)$erpPerson){
  echo "CARRIER_MAPPING_READBACK_MISMATCH=".$method."\n";exit(28);
 }
}
echo "SAFE_SHIPPING_CARRIER_MAPPING_SAVED=yes\n";
echo "OTHER_OPTIONS_AND_WOO_PRICES_NOT_INTENTIONALLY_CHANGED=yes\n";
