<?php
// Standalone real-world impersonation regression tests for the ERP identity guard.
require $argv[1];
function is_wp_error($v){return is_object($v)&&($v->error??false);}
function get_user_by($type,$key) {
    if($type==='email') return false;
    if($key===3055) return (object)['ID'=>3055,'roles'=>['subscriber']];
    if($key===6388) return (object)['ID'=>6388,'roles'=>['customer']];
    if($key===7000) return (object)['ID'=>7000,'roles'=>['administrator']];
    return false;
}
function get_user_meta($uid,$key,$single) {
    $ids=[3055=>12761457,6388=>12761501,7000=>12345];
    return $ids[$uid]??0;
}
function vesta_otp_phone($v){return preg_replace('/[^0-9]/','',(string)$v);}
function vesta_otp_existing_user($v){
    $uids=['09000000001'=>6388,'09000000002'=>3055];
    return $uids[$v]??false;
}
class FakeIdentityDB {
    public $prefix='wp_';
    function prepare($sql,...$args){foreach($args as $a)$sql=preg_replace('/%d/',(string)(int)$a,$sql,1);return $sql;}
    function get_row($sql) {
        if(strpos($sql,'12761501')!==false)return (object)['FirstName'=>'درست','LastName'=>'مشتری'];
        if(strpos($sql,'12761457')!==false)return (object)['FirstName'=>'دیگر','LastName'=>'مشتری'];
        return null;
    }
}
$wpdb=new FakeIdentityDB;
class FakeIdentityOrder {
    public $uid,$phone,$first,$last;
    function __construct($u,$p,$first,$last){$this->uid=$u;$this->phone=$p;$this->first=$first;$this->last=$last;}
    function get_customer_id(){return $this->uid;}
    function get_billing_phone(){return $this->phone;}
    function get_billing_first_name(){return $this->first;}
    function get_billing_last_name(){return $this->last;}
    function get_billing_email(){return '';}
}
function ck($ok,$title){if(!$ok){fwrite(STDERR,'FAIL '.$title."\n");exit(1);}echo 'PASS '.$title."\n";}
$correct=new FakeIdentityOrder(6388,'09000000001','درست','مشتری');
ck(vcar_identity_guard($correct)==='','legitimate_customer_before_send');
ck(vcar_identity_guard($correct,12761501)==='','legitimate_person_in_cloud');
ck(vcar_identity_guard($correct,12761457)==='customer_remote_person_mismatch','wrong_cloud_person');
$wrong=new FakeIdentityOrder(3055,'09000000001','درست','مشتری');
ck(vcar_identity_guard($wrong)==='customer_phone_owner_mismatch','seven_card_payments_cannot_reuse_old_customer');
$wrong2=new FakeIdentityOrder(3055,'09000000002','درست','مشتری');
ck(vcar_identity_guard($wrong2)==='customer_erp_name_mismatch','same_contact_but_wrong_erp_person');
$missing=new FakeIdentityOrder(6388,'09009999999','درست','مشتری');
ck(vcar_identity_guard($missing)==='customer_phone_owner_mismatch','unclaimed_phone_does_not_authorize_old_user');
$unmapped=new FakeIdentityOrder(0,'09000000001','درست','مشتری');
ck(vcar_identity_guard($unmapped)==='customer_account_unassigned','guest_fallback_blocked');
$admin=new FakeIdentityOrder(7000,'09000000002','درست','مشتری');
ck(vcar_identity_guard($admin)==='customer_account_privileged','privileged_erp_account_disallowed');
