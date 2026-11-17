<?php
/**
 * Plugin Name: Vesta Verified Admin Order Ownership Guard
 * Description: Only attach new paid admin-associated Woo orders to a unique, already-existing OTP-verified buyer. Never touch ERP, invoices or amounts.
 * Version: 1.0.0
 */
if (!defined('ABSPATH')) exit;
class Vesta_Verified_Admin_Owner_Guard {
    private static $busy = array();
    const START_AT = '2026-11-17T00:00:00Z';
    const LEGACY_ADMIN_ID = 1;

    public static function plan($o) {
        if (!$o || !method_exists($o, 'get_type') || $o->get_type() !== 'shop_order') return array('reason'=>'invalid_order');
        $date = $o->get_date_created();
        if (!$date || $date->getTimestamp() < strtotime(self::START_AT)) return array('reason'=>'preexisting_order_out_of_scope');
        $old = (int)$o->get_customer_id();
        if ($old !== self::LEGACY_ADMIN_ID) return array('reason'=>'not_legacy_admin_owner');
        if (!class_exists('Vesta_Channel_Customers') || !function_exists('vesta_otp_phone') ||
            !function_exists('vesta_otp_existing_user') || !function_exists('vcar_identity_normalize_name') ||
            !function_exists('vcar_eligible')) return array('reason'=>'guard_dependency_unavailable');
        if (!vcar_eligible($o)) return array('reason'=>'not_paid');
        $admin=get_user_by('id', self::LEGACY_ADMIN_ID);
        if (!$admin || !array_intersect((array)$admin->roles,array('administrator','shop_manager'))) return array('reason'=>'old_user_not_admin');
        if ((int)$o->get_meta('mahak_id') > 0 || (int)$o->get_meta('_vcar_cloud_invoice_id') > 0)
            return array('reason'=>'remote_invoice_already_acknowledged');
        global $wpdb;
        if (!isset($wpdb) || !method_exists($wpdb,'get_row')) return array('reason'=>'database_not_available');
        if (class_exists('Vesta_Accounting_Reliability')) {
            $outbox=$wpdb->get_row($wpdb->prepare('SELECT state,attempts,submitted_at,remote_id FROM '.Vesta_Accounting_Reliability::table().' WHERE order_id=%d',(int)$o->get_id()),ARRAY_A);
            if (is_array($outbox) && ((int)$outbox['attempts']>0 || (int)$outbox['submitted_at']>0 ||
                (int)$outbox['remote_id']>0 || in_array((string)$outbox['state'],array('verified','sending','uncertain','cloud_mismatch','conflict'),true)))
                return array('reason'=>'erp_sender_already_attempted');
        }
        $phone=vesta_otp_phone((string)$o->get_billing_phone());
        if (!$phone) return array('reason'=>'missing_verified_mobile');
        $owner=vesta_otp_existing_user($phone);
        if (is_wp_error($owner) || !is_numeric($owner) || (int)$owner<=0)
            return array('reason'=>'mobile_owner_not_unique');
        $uid=(int)$owner;
        if ($uid===self::LEGACY_ADMIN_ID || !Vesta_Channel_Customers::customer($uid))
            return array('reason'=>'mobile_owner_not_customer');
        $user=get_user_by('id',$uid);
        if (!$user) return array('reason'=>'buyer_account_not_found');
        $billing=vcar_identity_normalize_name($o->get_billing_first_name().' '.$o->get_billing_last_name());
        $profile=vcar_identity_normalize_name($user->first_name.' '.$user->last_name);
        if (!$billing || $profile!==$billing) return array('reason'=>'buyer_name_not_verified');
        $profilePhone=vesta_otp_phone((string)get_user_meta($uid,'billing_phone',true));
        if (!$profilePhone || $profilePhone!==$phone) return array('reason'=>'buyer_profile_phone_mismatch');
        $email=trim((string)$o->get_billing_email());
        if ($email!=='' && !is_email($email)) return array('reason'=>'billing_email_invalid');
        $emailOwner=$email?get_user_by('email',$email):false;
        if ($emailOwner && !in_array((int)$emailOwner->ID,array(self::LEGACY_ADMIN_ID,$uid),true))
            return array('reason'=>'third_party_email_owner');
        return array('reason'=>'verified','buyer_uid'=>$uid,'legacy_admin_email'=>($emailOwner&&(int)$emailOwner->ID===self::LEGACY_ADMIN_ID));
    }

    public static function apply($order_id) {
        $id=absint($order_id);
        if (!$id || isset(self::$busy[$id])) return;
        self::$busy[$id]=true;
        $wpdb=$GLOBALS['wpdb']??null;$locked=false;$lock='vesta_channel_order_'.$id;
        try {
            if (!$wpdb || (int)$wpdb->get_var($wpdb->prepare('SELECT GET_LOCK(%s, 3)',$lock))!==1) return;
            $locked=true;
            $o=wc_get_order($id);$plan=self::plan($o);
            if (($plan['reason']??'')!=='verified') return;
            $before=array((float)$o->get_total(),(float)$o->get_shipping_total(),(float)$o->get_discount_total(),
                (float)$o->get_total_tax(),$o->get_payment_method(),$o->get_currency(),$o->get_status(),
                count($o->get_items('line_item')),(int)$o->get_meta('mahak_id'));
            $o->set_customer_id((int)$plan['buyer_uid']);
            $o->update_meta_data('_vesta_identity_previous_customer_id',self::LEGACY_ADMIN_ID);
            $o->update_meta_data('_vesta_identity_repaired_at',gmdate('c'));
            $o->update_meta_data('_vesta_identity_repair_reason','automatic_verified_admin_owner_protection');
            if (!empty($plan['legacy_admin_email']))
                $o->update_meta_data('_vesta_customer_billing_email_review','legacy_admin_email_in_order');
            $o->delete_meta_data('_vesta_account_issue');
            $o->save();
            $r=wc_get_order($id);
            $after=array((float)$r->get_total(),(float)$r->get_shipping_total(),(float)$r->get_discount_total(),
                (float)$r->get_total_tax(),$r->get_payment_method(),$r->get_currency(),$r->get_status(),
                count($r->get_items('line_item')),(int)$r->get_meta('mahak_id'));
            if ((int)$r->get_customer_id()!==(int)$plan['buyer_uid'] || $after!==$before)
                error_log('VESTA_ADMIN_GUARD_READBACK_FAILED ORDER_ID='.$id);
            else error_log('VESTA_ADMIN_GUARD_VERIFIED_OWNER_RELINKED ORDER_ID='.$id);
        }catch(Throwable $e){error_log('VESTA_ADMIN_GUARD_REVIEW_REQUIRED ORDER_ID='.$id);}
        finally{
            if($locked)$wpdb->get_var($wpdb->prepare('SELECT RELEASE_LOCK(%s)',$lock));
            unset(self::$busy[$id]);
        }
    }
    public static function after_save($order,$store=null) {
        if ($order instanceof WC_Order) self::apply($order->get_id());
    }
}
add_action('woocommerce_payment_complete',array('Vesta_Verified_Admin_Owner_Guard','apply'),8,1);
add_action('woocommerce_order_status_changed',array('Vesta_Verified_Admin_Owner_Guard','apply'),8,1);
add_action('woocommerce_after_order_object_save',array('Vesta_Verified_Admin_Owner_Guard','after_save'),8,2);
