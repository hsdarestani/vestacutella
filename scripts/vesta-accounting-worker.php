<?php
error_reporting(E_ERROR|E_PARSE);ini_set('display_errors','0');set_time_limit(0);
$_SERVER['HTTP_HOST']='vesta-cosmetics.ir';$_SERVER['SERVER_NAME']='vesta-cosmetics.ir';
$_SERVER['HTTPS']='on';$_SERVER['SERVER_PORT']='443';$_SERVER['REQUEST_URI']='/wp-cron.php';
require '/var/www/html/wp-load.php';
if(!class_exists('Vesta_Accounting_Reliability'))exit(20);
if(getenv('VCAR_INSTALL')==='yes'){
 Vesta_Accounting_Reliability::install();
 echo 'OUTBOX_SEEDED='.Vesta_Accounting_Reliability::seed_all()."\n";
}
if(getenv('VCAR_RECONCILE_ONLY')==='yes') {
 global $wpdb;$t=Vesta_Accounting_Reliability::table();$api=new BazaraApi(true);
 $cloud=Vesta_Accounting_Reliability::cloud($api);
 $cursor=(int)get_option('vcar_reconcile_cursor',0);
 $settings=get_option('bazara_visitor_settings',array());$n=0;
 $ids=array_keys($cloud['orders']);sort($ids,SORT_NUMERIC);
 foreach($ids as $id){
  if($id<=$cursor)continue;
  $o=wc_get_order($id);
  if(vcar_eligible($o)){
   Vesta_Accounting_Reliability::enqueue($id);
   Vesta_Accounting_Reliability::verify($id,$o,$cloud,vcar_bank($settings,$o->get_payment_method()));
  }
  $cursor=$id;$n++;if($n>=120)break;
 }
 update_option('vcar_reconcile_cursor',$cursor,false);
 echo 'READ_ONLY_REMOTE_RECONCILED='.$n.' CURSOR='.$cursor."\n";
 // Explicitly retain all historical candidates; absence in this export is not desktop absence.
 $wpdb->query("UPDATE $t q JOIN {$wpdb->posts} p ON p.ID=q.order_id SET q.state='blocked',q.reason='historical_ledger_export_required',q.next_attempt=UNIX_TIMESTAMP()+86400 WHERE q.state='pending' AND q.remote_id=0 AND p.post_date_gmt<'2026-11-08 00:00:00'");
}else{
 $r=Vesta_Accounting_Reliability::tick(getenv('VCAR_FORCE')==='yes',(int)(getenv('VCAR_MAX_SEND')?:1));
 echo 'WORKER_PASS='.json_encode($r)."\n";
}
global $wpdb;$t=Vesta_Accounting_Reliability::table();
echo 'OUTBOX_COUNTS='.json_encode($wpdb->get_results("SELECT state,reason,COUNT(*) n FROM $t GROUP BY state,reason",ARRAY_A))."\n";
echo 'HEARTBEAT='.json_encode(get_option('vcar_heartbeat',array()))."\n";
echo "DESKTOP_VERIFIED=no\n";
