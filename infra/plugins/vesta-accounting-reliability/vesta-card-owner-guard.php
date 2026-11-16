<?php
/**
 * Plugin Name: Vesta Card Payment Customer Ownership Guard
 * Description: Correct confirmed card-transfer orders accidentally assigned to the identified legacy Woo customer, without touching the original payment or remote invoice.
 * Version: 1.0.0
 */
if (!defined('ABSPATH')) exit;
class Vesta_Card_Owner_Guard {
    private static $busy=array();
    const LEGACY_WOO_UID=3055;
    static function assign($order_id) {
        $id=absint($order_id);
        if(!$id || isset(self::$busy[$id]))return;
        self::$busy[$id]=true;
        global $wpdb;
        $lock='vesta_channel_order_'.$id;$locked=false;
        try {
            if((int)$wpdb->get_var($wpdb->prepare('SELECT GET_LOCK(%s,3)',$lock))!==1)return;
            $locked=true;
            if(!class_exists('Vesta_Channel_Customers') || !function_exists('vesta_otp_phone') ||
               !function_exists('vesta_otp_existing_user'))return;
            $o=wc_get_order($id);
            if(!$o || $o->get_payment_method()!=='pcs_smart_cardpay' ||
               (int)$o->get_customer_id()!==self::LEGACY_WOO_UID ||
               !$o->get_date_paid() ||
               !$o->has_status(array('processing','completed','processing5','pws-packaged','pws-shipping','arrival-shipment','pws-courier','pws-post')))return;
            $ph=vesta_otp_phone((string)$o->get_billing_phone());
            if(!$ph){self::flag($o,'cardpay_billing_phone_unverified');return;}
            $owner=vesta_otp_existing_user($ph);
            if(is_wp_error($owner)){self::flag($o,'cardpay_phone_ambiguous');return;}
            if((int)$owner===self::LEGACY_WOO_UID)return;
            $fname=trim((string)$o->get_billing_first_name());$lname=trim((string)$o->get_billing_last_name());
            $billName=vcar_identity_normalize_name($fname.' '.$lname);
            if($billName===''){self::flag($o,'cardpay_billing_name_missing');return;}
            $target=Vesta_Channel_Customers::resolve($o);
            if(is_wp_error($target)){self::flag($o,'cardpay_'.sanitize_key($target->get_error_code()));return;}
            $uid=(int)$target;
            if(!$uid || $uid===self::LEGACY_WOO_UID || !Vesta_Channel_Customers::customer($uid)){
                self::flag($o,'cardpay_identity_not_unique');return;
            }
            $u=get_user_by('id',$uid);
            $existingName=vcar_identity_normalize_name(($u->first_name??'').' '.($u->last_name??''));
            if($existingName!=='' && $existingName!==$billName){self::flag($o,'cardpay_phone_name_conflict');return;}
            if(!trim((string)get_user_meta($uid,'first_name',true)))update_user_meta($uid,'first_name',$fname);
            if(!trim((string)get_user_meta($uid,'last_name',true)))update_user_meta($uid,'last_name',$lname);
            if(!get_user_meta($uid,'billing_first_name',true))update_user_meta($uid,'billing_first_name',$fname);
            if(!get_user_meta($uid,'billing_last_name',true))update_user_meta($uid,'billing_last_name',$lname);
            $financial=array($o->get_total(),$o->get_shipping_total(),$o->get_discount_total(),$o->get_payment_method(),$o->get_currency(),$o->get_status());
            $o->set_customer_id($uid);
            $o->update_meta_data('_vesta_identity_previous_customer_id',self::LEGACY_WOO_UID);
            $o->update_meta_data('_vesta_identity_repaired_at',gmdate('c'));
            $o->update_meta_data('_vesta_identity_repair_reason','automatic_verified_cardpay_legacy_account');
            $o->update_meta_data('_vesta_accounting_erp_customer_reconciliation','required');
            $o->delete_meta_data('_vesta_account_issue');
            $o->save();
            $after=wc_get_order($id);
            $final=array($after->get_total(),$after->get_shipping_total(),$after->get_discount_total(),$after->get_payment_method(),$after->get_currency(),$after->get_status());
            if((int)$after->get_customer_id()!==$uid || $financial!=$final){
                error_log('VC_CARDPAY_OWNERSHIP_FINANCIAL_INVARIANT_FAILED order_id='.$id);
            } else {
                error_log('VC_CARDPAY_OWNERSHIP_RECONCILED order_id='.$id);
            }
        } catch(Throwable $e) {
            error_log('VC_CARDPAY_OWNERSHIP_REVIEW_REQUIRED order_id='.$id);
        } finally {
            if($locked)$wpdb->get_var($wpdb->prepare('SELECT RELEASE_LOCK(%s)',$lock));
            unset(self::$busy[$id]);
        }
    }
    static function flag($o,$reason){
        if($o->get_meta('_vesta_account_issue')!==$reason){
            $o->update_meta_data('_vesta_account_issue',$reason);
            $o->save_meta_data();
        }
    }
    static function after_save($order,$store=null){
        if($order instanceof WC_Order)self::assign($order->get_id());
    }
}
add_action('woocommerce_payment_complete',array('Vesta_Card_Owner_Guard','assign'),40,1);
add_action('woocommerce_order_status_changed',array('Vesta_Card_Owner_Guard','assign'),40,1);
add_action('woocommerce_after_order_object_save',array('Vesta_Card_Owner_Guard','after_save'),40,2);
