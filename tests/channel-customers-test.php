<?php
// Isolated identity/account lifecycle tests; no real users, SMS, mail or orders.
define('ABSPATH','/test/');define('ARRAY_A','ARRAY_A');
class WP_Error {private $code;function __construct($c,$m=''){$this->code=$c;}function get_error_code(){return $this->code;}}
function is_wp_error($x){return $x instanceof WP_Error;}
function add_action(...$a){} function add_filter(...$a){} function add_shortcode(...$a){}
function wp_salt($x){return 'test_'.$x;}
function wp_generate_password(...$a){return 'not-a-real-password';}
function absint($x){return abs((int)$x);}
function sanitize_key($x){return preg_replace('/[^a-z0-9_\-]/','',strtolower($x));}
function is_email($x){return filter_var($x,FILTER_VALIDATE_EMAIL);}
function get_option($k,$d=false){return $GLOBALS['options'][$k]??$d;}
function update_option($k,$v,$a=false){$GLOBALS['options'][$k]=$v;}
function wc_get_is_paid_statuses(){return ['processing','completed'];}
function get_user_meta($id,$key,$single=true){$v=$GLOBALS['meta'][$id][$key]??'';return $single?$v:($v===''?[]:[$v]);}
function update_user_meta($id,$key,$value){$GLOBALS['meta'][$id][$key]=$value;return true;}
function get_user_by($field,$value){foreach($GLOBALS['users'] as $u)if(($field==='id'&&(int)$u->ID===(int)$value)||($field==='email'&&strtolower($u->user_email)===strtolower($value)))return $u;return false;}
function username_exists($name){foreach($GLOBALS['users'] as $u)if($u->user_login===$name)return $u->ID;return false;}
function wp_insert_user($data){
 if($GLOBALS['insert_error']??false)return new WP_Error('insert_failed');
 if(username_exists($data['user_login']))return new WP_Error('existing_user_login');
 $id=count($GLOBALS['users'])+1;$GLOBALS['users'][$id]=(object)['ID'=>$id,'roles'=>[$data['role']],'user_email'=>$data['user_email']??'','user_login'=>$data['user_login']];return $id;
}
function wp_set_auth_cookie(...$a){throw new RuntimeException('automatic_login_forbidden');}
function wp_mail(...$a){throw new RuntimeException('unexpected_outbound_email');}
class FakeDB {
 public $usermeta='wp_usermeta',$last_error='',$locks=[],$deny=false;
 function prepare($sql,...$args){if(isset($args[0])&&is_array($args[0]))$args=$args[0];return [$sql,$args];}
 function get_var($q){list($sql,$args)=$q;if(strpos($sql,'GET_LOCK')!==false){if($this->deny)return 0;$this->locks[$args[0]]=true;return 1;}if(strpos($sql,'RELEASE_LOCK')!==false){unset($this->locks[$args[0]]);return 1;}return 0;}
 function get_results($q,$mode){list($sql,$variants)=$q;$out=[];foreach($GLOBALS['meta'] as $id=>$fields)foreach(['smsir_phone','phone','billing_phone'] as $key)if(isset($fields[$key])&&in_array($fields[$key],$variants,true))$out[]=['user_id'=>$id,'meta_key'=>$key];return $out;}
}
class WC_Order {}
class ChannelOrder extends WC_Order {
 public $id,$customer=0,$status='processing',$phone='09121234567',$email='',$meta=[],$saves=0,$items=[1],$paid=true,$gateway='shopino';
 public $total=123456,$shipping=20000,$stock=5;
 function __construct($id){$this->id=$id;}
 function get_id(){return $this->id;}function get_customer_id(){return $this->customer;}
 function get_type(){return 'shop_order';}function get_date_paid(){return $this->paid?true:null;}
 function get_items($t){return $this->items;}function has_status($s){return in_array($this->status,(array)$s,true);}
 function get_billing_phone(){return $this->phone;}function get_billing_email(){return $this->email;}
 function get_meta($k){return $this->meta[$k]??'';}function update_meta_data($k,$v){$this->meta[$k]=$v;}
 function delete_meta_data($k){unset($this->meta[$k]);}function save_meta_data(){}
 function set_customer_id($id){$this->customer=$id;}function save(){$this->saves++;Vesta_Channel_Customers::saved($this);}
}
function wc_get_order($id){return $GLOBALS['orders'][$id]??false;}
function wc_get_orders($args){return [];}
require $argv[1];require $argv[2];
function reset_case(){
 $GLOBALS['users']=[];$GLOBALS['meta']=[];$GLOBALS['wpdb']=new FakeDB;
 $GLOBALS['options']=['vesta_channel_accounts_enabled'=>true];$GLOBALS['insert_error']=false;
 $GLOBALS['orders']=[10=>new ChannelOrder(10)];return $GLOBALS['orders'][10];
}
function check($v,$name){if(!$v){fwrite(STDERR,'FAIL '.$name."\n");exit(1);}echo 'PASS '.$name."\n";}
$o=reset_case();check(Vesta_Channel_Customers::attach(10)==='linked','shopino_guest_gets_real_customer');
check(count($GLOBALS['users'])===1&&$o->customer===1,'one_real_woo_customer_attached');
check(vesta_otp_existing_user($o->phone)===1,'same_customer_resolves_for_sms_login');
check($GLOBALS['users'][1]->user_email==='','no_fake_email_for_phone_only_customer');
check($o->total===123456&&$o->shipping===20000&&$o->stock===5&&$o->status==='processing','money_status_stock_unchanged');
check(Vesta_Channel_Customers::attach(10)==='already_assigned'&&count($GLOBALS['users'])===1&&$o->saves===1,'repeated_webhooks_and_recursive_save_are_idempotent');
check(vesta_otp_resolve_customer($o->phone)===1&&count($GLOBALS['users'])===1,'otp_login_after_import_reuses_same_customer');
check(count($GLOBALS['wpdb']->locks)===0,'all_identity_and_order_locks_released');
foreach(['WC_Gateway_TorobPay','WC_Gateway_SnappPay','WCDigiPay','wc_zibal','future_external_api'] as $gateway){$id=count($GLOBALS['orders'])+10;$next=new ChannelOrder($id);$next->gateway=$gateway;$GLOBALS['orders'][$id]=$next;check(Vesta_Channel_Customers::attach($id)==='linked'&&$next->customer===1,'shared_customer_for_channel_'.$gateway);}
$o=reset_case();$o->phone='+98 (912) 123-4567';check(Vesta_Channel_Customers::attach(10)==='linked'&&vesta_otp_existing_user('09121234567')===1,'international_mobile_normalized');
check(vesta_otp_phone('۰۹۱۲۱۲۳۴۵۶۷')==='09121234567','persian_mobile_digits_normalized');
$o=reset_case();$o->phone='02112345678';check(Vesta_Channel_Customers::attach(10)==='invalid_mobile'&&count($GLOBALS['users'])===0,'invalid_or_landline_contact_is_flagged');
$o=reset_case();$o->phone='';check(Vesta_Channel_Customers::attach(10)==='missing_customer_identity','no_identity_cannot_create_inaccessible_account');
$o=reset_case();$o->phone='';$o->email='buyer@example.com';check(Vesta_Channel_Customers::attach(10)==='linked'&&$GLOBALS['users'][1]->user_email===$o->email,'real_email_only_customer_can_use_password_recovery');
$o=reset_case();$id=wp_insert_user(['user_login'=>'staff','role'=>'administrator']);update_user_meta($id,'smsir_phone',$o->phone);check(Vesta_Channel_Customers::attach(10)==='non_customer_account'&&$o->customer===0,'privileged_account_never_attached_or_overwritten');
$o=reset_case();foreach(['a','b'] as $name){$id=wp_insert_user(['user_login'=>$name,'role'=>'customer']);update_user_meta($id,'smsir_phone',$o->phone);}check(Vesta_Channel_Customers::attach(10)==='duplicate_mobile'&&count($GLOBALS['users'])===2&&$o->customer===0,'ambiguous_phone_is_flagged_without_merging_accounts');
$o=reset_case();$id=wp_insert_user(['user_login'=>'emailowner','user_email'=>'owner@example.com','role'=>'customer']);$o->email='owner@example.com';check(Vesta_Channel_Customers::attach(10)==='phone_email_identity_conflict'&&count($GLOBALS['users'])===1,'order_email_cannot_bind_unrelated_phone_to_existing_account');
$o=reset_case();$GLOBALS['wpdb']->deny=true;check(Vesta_Channel_Customers::attach(10)==='order_busy'&&count($GLOBALS['users'])===0,'contended_lock_defers_without_duplicate_creation');
$o=reset_case();$GLOBALS['insert_error']=true;check(Vesta_Channel_Customers::attach(10)==='insert_failed'&&$o->customer===0,'user_creation_failure_keeps_order_for_retry');
$o=reset_case();$o->status='pending';$o->paid=false;check(Vesta_Channel_Customers::attach(10)==='not_confirmed'&&count($GLOBALS['users'])===0,'unpaid_pending_checkout_does_not_create_account');
$o->status='processing';check(Vesta_Channel_Customers::attach(10)==='linked','payment_confirmation_creates_customer');
$o=reset_case();$o->items=[];check(Vesta_Channel_Customers::attach(10)==='not_confirmed','partial_rest_order_waits_for_line_items');
$o->items=[1];Vesta_Channel_Customers::saved($o);check($o->customer===1,'final_rest_order_save_links_customer');
$o=reset_case();$o->customer=777;check(Vesta_Channel_Customers::attach(10)==='already_assigned'&&$o->customer===777,'existing_customer_assignment_preserved');

$o=reset_case();$o->phone='0989121234567';check(Vesta_Channel_Customers::attach(10)==='linked'&&vesta_otp_existing_user('09121234567')===1,'observed_channel_country_prefix_normalized_without_guessing_digits');
check(vesta_otp_phone('098912123456')==='', 'short_country_prefix_does_not_guess_missing_digit');
check(vesta_otp_phone('09891212345678')==='', 'long_country_prefix_does_not_drop_subscriber_digits');
$o=reset_case();$id=wp_insert_user(['user_login'=>'legacy098','role'=>'customer']);update_user_meta($id,'smsir_phone','0989121234567');check(vesta_otp_existing_user('09121234567')===$id,'legacy_098_binding_reuses_existing_customer');
