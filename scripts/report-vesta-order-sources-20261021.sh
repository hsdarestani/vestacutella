#!/usr/bin/env bash
# Aggregated, read-only Vesta WooCommerce order-source report. Never outputs customer or order details.
set -euo pipefail
docker exec -i vc-vesta php -d display_errors=0 -d memory_limit=512M -d max_execution_time=0 <<'PHP'
<?php
error_reporting(E_ERROR | E_PARSE);
$_SERVER['HTTP_HOST'] = 'vesta-cosmetics.ir';
require '/var/www/html/wp-load.php';
if (!function_exists('wc_get_orders')) { fwrite(STDERR, "WC_UNAVAILABLE\n"); exit(2); }
$start='2026-04-21'; $end='2026-10-21';
$metaKeys=array('_wc_order_attribution_source_type','_wc_order_attribution_utm_source','_wc_order_attribution_utm_medium','_wc_order_attribution_referrer','_wc_order_attribution_session_entry','_wc_order_attribution_utm_campaign');
$presence=array_fill_keys($metaKeys,0);
$statuses=array(); $channels=array(); $monthly=array(); $methods=array(); $originTypes=array();
$matched=0; $qualified=0; $other=0; $unknown=0; $qualifiedRevenue=0.0;
$max=50000; $perPage=150; $page=1;
function bucket_source($sourceType,$utm,$medium,$referrer,$entry,$via) {
  $signals=strtolower(trim($utm.' '.$referrer.' '.$entry));
  if (preg_match('~instagram\\.com|instagr\\.am|(^|[^a-z])instagram([^a-z]|$)|l\\.instagram\\.com|ig\\.me~i',$signals)) return 'Instagram';
  if (preg_match('~(^|[^a-z])snapp([^a-z]|$)|snappmarket|snappfood|snappshop~i',$signals)) return 'Snapp';
  if (preg_match('~(^|[^a-z])google([^a-z]|$)|google\\.|gclid|googleads~i',$signals)) return 'Google';
  if (preg_match('~(^|[^a-z])facebook([^a-z]|$)|facebook\\.com|fb\\.com|l\\.facebook~i',$signals)) return 'Facebook';
  if (preg_match('~(^|[^a-z])torob([^a-z]|$)|torob\\.com|torob\\.ir~i',$signals)) return 'Torob';
  if (preg_match('~emalls|e-malls~i',$signals)) return 'Emalls';
  if (preg_match('~t\\.me/|telegram|telegram\\.me~i',$signals)) return 'Telegram';
  if (preg_match('~digikala|digistyle~i',$signals)) return 'Digikala';
  if (preg_match('~bing\\.|yahoo\\.|duckduckgo\\.|yandex\\.~i',$signals)) return 'Other search';
  if (preg_match('~(^|[^a-z])email([^a-z]|$)|newsletter~i',strtolower($utm.' '.$medium))) return 'Email';
  if (preg_match('~(^|[^a-z])direct([^a-z]|$)~i',trim($utm)) || in_array(strtolower($sourceType),array('typein','direct'),true)) return 'Direct / typed';
  if ($via === 'admin') return 'Admin created / unknown';
  if ($via === 'rest-api') return 'API created / unknown';
  if (in_array(strtolower($sourceType),array('social','search','referral','utm','organic'),true) || trim($utm.$referrer.$entry) !== '') return 'Other attributed';
  return 'Unknown / untracked';
}
function add_metric(&$target,$key,$total) {
  if (!isset($target[$key])) $target[$key]=array('orders'=>0,'amount'=>0.0);
  $target[$key]['orders']++; $target[$key]['amount']+=$total;
}
do {
  $res=wc_get_orders(array('type'=>'shop_order','status'=>array_keys(wc_get_order_statuses()),'limit'=>$perPage,'page'=>$page,'orderby'=>'date','order'=>'ASC','date_created'=>$start.'...'.$end,'paginate'=>true));
  if (!is_object($res) || !isset($res->orders)) { fwrite(STDERR,"UNEXPECTED_QUERY_RESPONSE\n"); exit(3); }
  foreach ($res->orders as $order) {
    if (!$order) continue;
    $created=$order->get_date_created(); if (!$created) continue;
    $d=$created->date('Y-m-d'); if ($d<$start || $d>$end) continue;
    $matched++;
    $status=$order->get_status(); $statuses[$status]=($statuses[$status]??0)+1;
    if (!in_array($status,array('processing','completed'),true)) { $other++; continue; }
    $qualified++;
    $net=max(0,(float)$order->get_total()-(float)$order->get_total_refunded());
    $qualifiedRevenue+=$net;
    $values=array();
    foreach ($metaKeys as $key) {
      $v=$order->get_meta($key,true);
      $values[$key]=is_scalar($v)?trim((string)$v):'';
      if ($values[$key]!=='') $presence[$key]++;
    }
    $sourceType=$values['_wc_order_attribution_source_type'];
    $utm=$values['_wc_order_attribution_utm_source'];
    $medium=$values['_wc_order_attribution_utm_medium'];
    $referrer=$values['_wc_order_attribution_referrer'];
    $entry=$values['_wc_order_attribution_session_entry'];
    $via=(string)$order->get_created_via();
    $bucket=bucket_source($sourceType,$utm,$medium,$referrer,$entry,$via);
    if ($bucket==='Unknown / untracked') $unknown++;
    add_metric($channels,$bucket,$net);
    add_metric($monthly[$created->date('Y-m')],$bucket,$net);
    $pay=(string)$order->get_payment_method();
    $pay=preg_replace('/[^a-z0-9_-]/i','',strtolower($pay));
    add_metric($methods,$pay!==''?$pay:'unknown',$net);
    $type=preg_replace('/[^a-z0-9_-]/i','',strtolower($sourceType));
    add_metric($originTypes,$type!==''?$type:'missing',$net);
  }
  if ($matched >= $max) break;
  $pages=(int)$res->max_num_pages;
  $page++;
} while ($page <= $pages);
echo "REPORT_RANGE|$start|$end\n";
echo "SUMMARY|scanned=$matched|processing_completed=$qualified|other_status=$other|processing_completed_net_total=".round($qualifiedRevenue,2)."|untracked=$unknown|truncated=".($matched>=$max?'yes':'no')."\n";
ksort($statuses); foreach ($statuses as $key=>$n) echo "STATUS|$key|$n\n";
foreach($presence as $key=>$n) echo "ATTR_META|$key|$n\n";
uasort($channels,function($a,$b){return $b['orders']<=>$a['orders'];});
foreach($channels as $key=>$v) echo "CHANNEL|$key|".$v['orders']."|".round($v['amount'],2)."\n";
ksort($monthly); foreach($monthly as $month=>$items) { ksort($items); foreach($items as $key=>$v) echo "MONTH_CHANNEL|$month|$key|".$v['orders']."|".round($v['amount'],2)."\n"; }
uasort($methods,function($a,$b){return $b['orders']<=>$a['orders'];});
foreach($methods as $key=>$v) echo "PAYMENT_GATEWAY|$key|".$v['orders']."|".round($v['amount'],2)."\n";
uasort($originTypes,function($a,$b){return $b['orders']<=>$a['orders'];});
foreach($originTypes as $key=>$v) echo "SOURCE_TYPE|$key|".$v['orders']."|".round($v['amount'],2)."\n";
echo "REPORT_DONE\n";
PHP
