#!/usr/bin/env bash
set -euo pipefail
echo "AUDIT_UTC=$(date -u +%FT%TZ)"
echo "=== TELEGRAM PLUGIN HOOK IMPLEMENTATION ==="
P=/srv/vestacutella/runtime/vesta/wp-content/plugins/order-notification-for-telegram-bot
test -d "$P"
find "$P" -maxdepth 3 -type f -name '*.php' | head -30 | sed "s#$P##"
grep -RnE --include='*.php' 'woocommerce_(new_order|order_status_|checkout_order_processed|store_api_checkout|payment_complete|order_object_updated_props)|get_items|get_product|order_status' "$P" 2>/dev/null | head -95 | cut -c1-215 || true
echo "=== LIVE WP CONFIG AND ORDER CLASSIFICATION ==="
docker exec vc-vesta php -d display_errors=0 -r '
require "/var/www/html/wp-load.php";
global $wpdb;
echo "PLUGIN_ACTIVATION=".(is_plugin_active("order-notification-for-telegram-bot/order-notification-for-telegram-bot.php")?"active":"inspect_path")."\n";
foreach(["onftb_setting_token","onftb_setting_chatid","onftb_setting_is_use_google_script"] as $k){
 $v=get_option($k,"");
 echo "SETTING ".$k." defined=".($v!==""?"yes":"no").($k==="onftb_setting_chatid"?" count=".count(array_filter(explode(",",(string)$v))):"")."\n";
}
$opts=$wpdb->get_col("SELECT option_name FROM {$wpdb->options} WHERE option_name LIKE \047onftb_%\047 ORDER BY option_name LIMIT 150");
foreach($opts as $k){
 $v=get_option($k);
 echo "OTHER_OPTION=".preg_replace("/[^a-zA-Z0-9_-]/","",$k)." value_type=".gettype($v)." is_truthy=".(!empty($v)?"yes":"no")."\n";
}
foreach(["woocommerce_new_order","woocommerce_order_status_changed","woocommerce_order_status_processing","woocommerce_order_status_pending_to_processing","woocommerce_checkout_order_processed","woocommerce_store_api_checkout_order_processed","woocommerce_payment_complete"] as $name){
 $h=$GLOBALS["wp_filter"][$name]??null;
 echo "LIVE_HOOK ".$name." callbacks=";
 $found=[];
 if($h){foreach($h->callbacks as $prio=>$group){
  foreach($group as $callback){
   $fn=$callback["function"]??null;
   $n=is_string($fn)?$fn:(is_array($fn)?(is_object($fn[0])?get_class($fn[0]):(string)$fn[0])."::".($fn[1]??""):"closure");
   $found[]=$prio.":".preg_replace("/[^a-zA-Z0-9_:]/","",$n);
  }
 }}
 echo implode(",",array_slice($found,0,18))."\n";
}
$ids=wc_get_orders(["type"=>"shop_order","limit"=>65,"orderby"=>"date","order"=>"DESC","return"=>"ids"]);
$stats=[];
$examples=[];
foreach($ids as $id){
 $o=wc_get_order($id);if(!$o)continue;
 $hasCutella=false;$hasOther=false;$variationCount=0;$items=0;
 foreach($o->get_items("line_item") as $item){
  $items++;$pid=$item->get_product_id();$vid=$item->get_variation_id();
  $v=$vid?wc_get_product($vid):null;
  if($v)$variationCount++;
  $imported=($pid && get_post_meta($pid,"_vc_cutella_source_product_id",true)!=="") || ($vid && get_post_meta($vid,"_vc_cutella_source_variation_id",true)!=="");
  if($imported)$hasCutella=true;else $hasOther=true;
 }
 $type=$hasCutella?($hasOther?"mixed":"cutella"):"other";
 $st=$o->get_status();$created=$o->get_date_created();
 $key=$type.":".$st;
 $stats[$key]=($stats[$key]??0)+1;
 if(count($examples)<20)$examples[]=["age_min"=>$created?round((time()-$created->getTimestamp())/60):null,"type"=>$type,"status"=>$st,"payment"=>$o->get_payment_method(),"via"=>$o->get_created_via(),"item_count"=>$items,"variations"=>$variationCount];
}
foreach($stats as $k=>$n)echo "ORDER_TYPE_STATS type_status=$k count=$n\n";
foreach($examples as $i=>$e)echo "ORDER_SAMPLE index=$i age_min=".$e["age_min"]." type=".$e["type"]." status=".$e["status"]." payment=".preg_replace("/[^a-zA-Z0-9_-]/","",$e["payment"])." created_via=".preg_replace("/[^a-zA-Z0-9_-]/","",$e["via"])." line_count=".$e["item_count"]." var_count=".$e["variations"]."\n";
';
echo "TELEGRAM_ORDER_CUTELLA_AUDIT_READONLY_DONE"
