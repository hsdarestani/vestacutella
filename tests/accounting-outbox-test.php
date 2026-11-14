<?php
// Isolated fault scenarios. No WordPress installation, network, or accounting writes.
define('ABSPATH','/nonexistent/');
function add_action(...$args){}
function wc_get_is_paid_statuses(){return ['processing','completed'];}
function get_option($k,$d=false){return $GLOBALS['options'][$k]??$d;}
function update_option($k,$v,$autoload=false){$GLOBALS['options'][$k]=$v;return true;}
function get_post_meta($id,$key,$single){return $id===101?0:($key==='mahak_id'?7:9);}
function wc_get_order($id){return new FakeOrder($id);}
class FakeItem {
 public $id;function __construct($id){$this->id=$id;}
 function get_variation_id(){return $this->id===1?101:102;}
 function get_product_id(){return 0;}function get_quantity(){return 2;}
 function get_total(){return 180;}
}
class FakeOrder {
 public $id;function __construct($id){$this->id=$id;}
 function get_id(){return $this->id;}function get_date_paid(){return true;}
 function has_status($s){return in_array('processing',$s,true);}
 function get_currency(){return 'IRT';}function get_total_tax(){return 0;}
 function get_payment_method(){return 'wc_zibal';}function get_meta($key){return $this->id===2?($GLOBALS['local_ack']??0):0;}
 function get_date_created(){return new DateTime('2026-11-13T00:00:00Z');}
 function get_items($type){return $type==='fee'?[]:[new FakeItem($this->id)];}
 function get_shipping_total(){return 20;}function get_total(){return 200;}
 function update_meta_data($k,$v){if($k==='mahak_id')$GLOBALS['ack_written']=$v;}function save_meta_data(){}
}
class FakeDB {
 public $prefix='wp_',$posts='wp_posts',$rows=[];
 function prepare($sql,...$args){foreach($args as $a)$sql=preg_replace('/%[ds]/',is_numeric($a)?(string)$a:"'".$a."'",$sql,1);return $sql;}
 function get_col($sql){return [];}
 function get_var($sql){
  if(strpos($sql,'bazara_banks')!==false)return 55;
  if(strpos($sql,'bazara_product_details')!==false)return 9;
  if(strpos($sql,'bazara_orders')!==false)return 0;
  if(strpos($sql,'COUNT(*)')!==false)return count(array_filter($this->rows,fn($r)=>$r['state']!=='verified'));
  return 0;
 }
 function get_results($sql,$mode){
  if(strpos($sql,"state IN ('sending','uncertain')")!==false)return array_values(array_filter($this->rows,fn($r)=>in_array($r['state'],['sending','uncertain'],true)));
  return array_values(array_filter($this->rows,fn($r)=>$r['state']!=='verified'&&$r['next_attempt']<=time()));
 }
 function update($table,$data,$where){$id=$where['order_id'];$this->rows[$id]=array_merge($this->rows[$id],$data);return 1;}
}
define('ARRAY_A','ARRAY_A');
class BazaraApi {
 function __construct($arg){}
 function get_all_data($token,$params){
  $exists=$GLOBALS['remote_exists'];
  return ['success'=>true,'message'=>[
   'Orders'=>$exists?[['OrderId'=>88,'OrderClientId'=>2,'ReceiptId'=>null,'SendCost'=>200]]:[],
   'OrderDetails'=>$exists?[['OrderId'=>88,'ProductDetailId'=>9,'Count1'=>2,'Price'=>1000,'Discount'=>200]]:[],
   'Receipts'=>$exists?[['OrderId'=>88,'ReceiptId'=>44,'CashAmount'=>0]]:[],
   'Cheques'=>$exists?[['ReceiptId'=>44,'BankId'=>55,'Amount'=>2000,'Type'=>2]]:[]
  ]];
 }
 function bazara_save_order($id,$token){
  if($GLOBALS['wpdb']->rows[$id]['state']!=='sending'||!$GLOBALS['wpdb']->rows[$id]['submitted_at'])throw new RuntimeException('mutation_before_durable_reservation');
  $GLOBALS['sends']++;
  if(!$GLOBALS['ambiguous'])$GLOBALS['remote_exists']=true;
  return ['success'=>!$GLOBALS['ambiguous']];
 }
}
require $argv[1];
function reset_case($remote,$ambiguous){
 $GLOBALS['wpdb']=new FakeDB;
 foreach([1,2] as $id)$GLOBALS['wpdb']->rows[$id]=['order_id'=>$id,'state'=>'pending','submitted_at'=>0,'attempts'=>0,'next_attempt'=>0];
 $GLOBALS['options']=['vcar_schema'=>'1','vcar_history_scan_complete'=>time(),'vcar_sender_enabled'=>true,
 'bazara_visitor_settings'=>['banksMethods'=>'[{"method":"wc_zibal","name":"55"}]']];
 $GLOBALS['remote_exists']=$remote;$GLOBALS['ambiguous']=$ambiguous;$GLOBALS['sends']=0;$GLOBALS['local_ack']=0;$GLOBALS['ack_written']=0;
}
function ensure($ok,$name){if(!$ok){fwrite(STDERR,'FAIL '.$name."\n");exit(1);}echo 'PASS '.$name."\n";}
reset_case(false,false);Vesta_Accounting_Reliability::tick(true,2);
ensure($GLOBALS['sends']===1&&$GLOBALS['wpdb']->rows[1]['state']==='blocked'&&$GLOBALS['wpdb']->rows[2]['state']==='verified','blocked_product_does_not_block_unrelated_order_and_actual_remote_ack_required');
reset_case(true,false);Vesta_Accounting_Reliability::tick(true,2);
ensure($GLOBALS['sends']===0&&$GLOBALS['wpdb']->rows[2]['state']==='verified','existing_remote_invoice_without_local_ack_never_resent');
reset_case(false,true);Vesta_Accounting_Reliability::tick(true,2);
ensure($GLOBALS['sends']===1&&$GLOBALS['wpdb']->rows[2]['state']==='uncertain','ambiguous_write_persists_uncertain_state');
$GLOBALS['wpdb']->rows[2]['next_attempt']=0;Vesta_Accounting_Reliability::tick(true,2);
ensure($GLOBALS['sends']===1,'ambiguous_write_never_automatically_resent');
$GLOBALS['remote_exists']=true;$GLOBALS['wpdb']->rows[2]['next_attempt']=time()+3600;
Vesta_Accounting_Reliability::tick(true,2);
ensure($GLOBALS['sends']===1&&$GLOBALS['wpdb']->rows[2]['state']==='verified','delayed_remote_ack_recovers_without_waiting_for_retry_or_resubmitting');
ensure($GLOBALS['ack_written']===88,'verified_delayed_ack_repairs_canonical_local_reference');
reset_case(true,false);$GLOBALS['local_ack']=99;Vesta_Accounting_Reliability::tick(true,2);
ensure($GLOBALS['sends']===0&&$GLOBALS['wpdb']->rows[2]['state']==='conflict','conflicting_existing_financial_reference_is_not_overwritten');
