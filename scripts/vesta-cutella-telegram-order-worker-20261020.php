<?php
/**
 * Reliable admin Telegram notifications for Vesta orders containing imported Cutella items.
 * CLI worker only: sends to the existing Telegram chats, never customers.
 * No order/payment/stock status mutation. Handles mixed carts and variations.
 */
if (PHP_SAPI !== 'cli') exit(90);
require '/var/www/html/wp-load.php';
if (!function_exists('wc_get_orders') || !function_exists('wp_remote_post')) exit(11);
$mode = $argv[1] ?? '--dry-run';
if (!in_array($mode, array('--dry-run','--canary','--send'),true)) exit(12);
$since = strtotime('2026-10-18 00:00:00 UTC');
$start = (int)get_option('vc_vesta_cutella_order_telegram_active_since_20261020',0);
if ($mode === '--send' && !$start) {echo "CUTELLA_TG_WORKER_NOT_ACTIVATED\n";exit(13);}
$token = trim((string)get_option('onftb_setting_token',''));
$raw = (string)get_option('onftb_setting_chatid','');
$chats=array_values(array_unique(array_filter(array_map('trim',explode(',',$raw)))));
if (!preg_match('/^[0-9]{6,}:[a-zA-Z0-9_-]{25,}$/D',$token) || count($chats)<1 || count($chats)>5) {
 echo "CUTELLA_TG_BOT_CONFIG_INVALID\n";exit(14);
}
foreach ($chats as $chat) if (!preg_match('/^-?[0-9]{3,20}$/D',$chat)) exit(15);
function vc_cutella_tg_item_imported($item) {
 if (!$item || !is_a($item,'WC_Order_Item_Product')) return false;
 $parent=(int)$item->get_product_id();$variation=(int)$item->get_variation_id();
 if ($parent && get_post_meta($parent,'_vc_cutella_source_product_id',true)!=='') return true;
 if ($variation && get_post_meta($variation,'_vc_cutella_source_variation_id',true)!=='') return true;
 return false;
}
function vc_cutella_tg_order_type($order) {
 if (!$order || !is_a($order,'WC_Order')) return '';
 $hasImported=false;$hasOther=false;
 foreach($order->get_items('line_item') as $item) {
  if(vc_cutella_tg_item_imported($item))$hasImported=true;
  else $hasOther=true;
 }
 return $hasImported ? ($hasOther?'mixed':'cutella-only') : '';
}
function vc_cutella_tg_clean($s,$length=115) {
 $s=html_entity_decode(wp_strip_all_tags((string)$s),ENT_QUOTES|ENT_HTML5,'UTF-8');
 $s=preg_replace('/[\x00-\x1F\x7F]+/u',' ',$s);
 $s=trim(preg_replace('/\s+/u',' ',$s));
 return function_exists('mb_substr')?mb_substr($s,0,$length,'UTF-8'):substr($s,0,$length);
}
function vc_cutella_tg_message($order,$kind,$recovery) {
 $intro=$recovery?'🔁 بازیابی اعلان سفارش کیوتلا':'📦 سفارش جدید شامل محصولات کیوتلا';
 $txt=$intro."\n";
 $txt.='شماره سفارش: #'.vc_cutella_tg_clean($order->get_order_number(),35)."\n";
 $txt.='وضعیت: '.vc_cutella_tg_clean(wc_get_order_status_name('wc-'.$order->get_status()),60)."\n";
 $txt.='نوع سبد: '.($kind==='mixed'?'ترکیبی وستا و کیوتلا':'کیوتلا')."\n\n";
 $n=0;
 foreach($order->get_items('line_item') as $item) {
  $n++;
  if($n>40){$txt.="و سایر اقلام...\n";break;}
  $src=vc_cutella_tg_item_imported($item)?'کیوتلا':'وستا';
  $txt.='• ['.$src.'] '.vc_cutella_tg_clean($item->get_name(),125).' × '.(float)$item->get_quantity()."\n";
 }
 $total=html_entity_decode(wp_strip_all_tags(wc_price($order->get_total(),array('currency'=>$order->get_currency()))),ENT_QUOTES|ENT_HTML5,'UTF-8');
 $txt.="\nمبلغ: ".vc_cutella_tg_clean($total,55)."\n";
 $link=$order->get_edit_order_url();
 if(!$link)$link=admin_url('post.php?post='.$order->get_id().'&action=edit');
 $txt.='مشاهده سفارش: '.$link;
 return function_exists('mb_substr')?mb_substr($txt,0,3800,'UTF-8'):substr($txt,0,3800);
}
$orders=wc_get_orders(array('type'=>'shop_order','limit'=>200,'orderby'=>'date','order'=>'DESC',
 'status'=>array('processing','completed','on-hold')));
$eligible=array();
foreach($orders as $o){
 $dt=$o->get_date_created();
 if(!$dt || $dt->getTimestamp()<$since)continue;
 $kind=vc_cutella_tg_order_type($o);
 if($kind==='')continue;
 $delivered=$o->get_meta('_vc_cutella_telegram_order_accepted_chats_v1',true);
 if(!is_array($delivered))$delivered=array();
 $remaining=0;
 foreach($chats as $chat)if(empty($delivered[hash('sha256',$chat)]))$remaining++;
 if($remaining)$eligible[]=array('order'=>$o,'kind'=>$kind,'remaining'=>$remaining);
}
echo "CUTELLA_TG_SCAN mode=$mode chats=".count($chats)." imported_eligible=".count($eligible)."\n";
$countKinds=array('mixed'=>0,'cutella-only'=>0);
foreach($eligible as $x)$countKinds[$x['kind']]++;
echo "CUTELLA_TG_SCAN_COUNTS mixed=".$countKinds['mixed']." cutella_only=".$countKinds['cutella-only']."\n";
if($mode==='--dry-run'){echo "CUTELLA_TG_DRY_RUN_DONE\n";exit(0);}
if($mode==='--canary'){
 // Use the most recent unnotified imported order. Sends no more than one order.
 $eligible=array_slice($eligible,0,1);
} else {
 // Backfill earliest missing imports first, two orders per run to avoid rate limits.
 $eligible=array_slice(array_reverse($eligible),0,2);
}
$successfulOrders=0;$failedChats=0;$attemptedOrders=0;
foreach($eligible as $selection){
 $o=$selection['order'];
 $id=(int)$o->get_id();
 $meta='_vc_cutella_telegram_order_accepted_chats_v1';
 $sent=$o->get_meta($meta,true);
 if(!is_array($sent))$sent=array();
 $kind=$selection['kind'];
 $isRecovery=$o->get_date_created()->getTimestamp()<time()-600;
 $msg=vc_cutella_tg_message($o,$kind,$isRecovery);
 $all=true;
 foreach($chats as $chat){
  $hash=hash('sha256',$chat);
  if(!empty($sent[$hash]))continue;
  $o->update_meta_data('_vc_cutella_telegram_last_attempt_v1',time());
  $o->save_meta_data();
  $result=wp_remote_post('https://api.telegram.org/bot'.$token.'/sendMessage',array(
    'timeout'=>17,'redirection'=>0,
    'body'=>array('chat_id'=>$chat,'text'=>$msg,'disable_web_page_preview'=>'true'),
  ));
  $http=is_wp_error($result)?0:(int)wp_remote_retrieve_response_code($result);
  $body=!is_wp_error($result)?json_decode((string)wp_remote_retrieve_body($result),true):null;
  if($http===200 && is_array($body) && !empty($body['ok'])){
    $sent[$hash]=gmdate('c');
    $o->update_meta_data($meta,$sent);
    $o->save_meta_data();
  }else{
    $all=false;$failedChats++;
    $errorCode=is_wp_error($result)?preg_replace('/[^a-z0-9_-]/i','',$result->get_error_code()):'none';
    echo "CUTELLA_TG_SEND chat=failed http=$http transport=$errorCode\n";
  }
 }
 $attemptedOrders++;
 if($all){$successfulOrders++;echo "CUTELLA_TG_SEND order=accepted type=$kind\n";}
 else echo "CUTELLA_TG_SEND order=partial type=$kind\n";
}
echo "CUTELLA_TG_RESULT attempts=$attemptedOrders full_accepted=$successfulOrders failed_chats=$failedChats\n";
if($failedChats)exit(21);
echo "CUTELLA_TG_WORKER_COMPLETED\n";
