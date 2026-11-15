<?php
/**
 * Plugin Name: Vesta Channel Customer Accounts
 * Description: Attach confirmed WooCommerce orders from every channel to customer panels, without changing money, status or stock.
 * Version: 1.0.0
 * Requires PHP: 7.4
 */
if (!defined('ABSPATH')) exit;
class Vesta_Channel_Customers {
    private static $running = array();
    static function statuses() {
        return array_unique(array_merge(wc_get_is_paid_statuses(),array('on-hold','processing5','pws-packaged','pws-shipping','arrival-shipment','pws-courier','pws-post')));
    }
    static function eligible($o) {
        return $o && $o->get_type()==='shop_order' && !$o->has_status(array('checkout-draft','auto-draft','trash','failed','cancelled','refunded')) &&
            ($o->get_date_paid() || $o->has_status(self::statuses())) && count($o->get_items('line_item'))>0;
    }
    static function issue_label($reason) {
        $labels=array('duplicate_mobile'=>'شماره موبایل به چند حساب متصل است؛ هویت مشتری بررسی شود.',
            'phone_email_identity_conflict'=>'شماره و ایمیل متعلق به یک حساب نیستند؛ هویت مشتری بررسی شود.',
            'invalid_mobile'=>'شماره موبایل معتبر نیست؛ اطلاعات سفارش اصلاح شود.',
            'invalid_email'=>'ایمیل معتبر نیست؛ اطلاعات سفارش اصلاح شود.',
            'missing_customer_identity'=>'شماره موبایل یا ایمیل مشتری در سفارش موجود نیست.',
            'non_customer_account'=>'اطلاعات تماس به حساب کارکنان متصل است؛ پشتیبانی بررسی کند.');
        return $labels[$reason]??'ساخت یا اتصال پنل کامل نشده است؛ در اجرای بعدی دوباره بررسی می‌شود.';
    }
    static function customer($id) {
        $u=get_user_by('id',$id);
        return $u && array_intersect(array('customer','subscriber'),(array)$u->roles) &&
            !array_intersect(array('administrator','editor','author','shop_manager'),(array)$u->roles);
    }
    static function resolve($o) {
        if (!function_exists('vesta_otp_resolve_customer')) return new WP_Error('login_adapter_unavailable');
        $raw=trim((string)$o->get_billing_phone());
        $phone=vesta_otp_phone($raw);
        // Most channel orders have only a mobile. Never invent an email address or bind an order email to mobile login.
        if ($raw !== '' && !$phone) return new WP_Error('invalid_mobile');
        $email=trim((string)$o->get_billing_email());
        if ($email!=='' && !is_email($email)) return new WP_Error('invalid_email');
        $email_user=$email!=='' ? get_user_by('email',$email) : false;
        if ($phone) {
            if ($email_user) {
                $owner=vesta_otp_existing_user($phone);
                if (is_wp_error($owner)) return $owner;
                if (!$owner || (int)$owner!==(int)$email_user->ID) return new WP_Error('phone_email_identity_conflict');
            }
            return vesta_otp_resolve_customer($phone);
        }
        if (!$email) return new WP_Error('missing_customer_identity');
        global $wpdb;
        $lock='vesta_email_'.substr(hash_hmac('sha256',strtolower($email),wp_salt('auth')),0,32);
        if ((int)$wpdb->get_var($wpdb->prepare('SELECT GET_LOCK(%s, 5)',$lock))!==1) return new WP_Error('email_lookup_busy');
        try {
            $u=get_user_by('email',$email);
            if ($u) return self::customer($u->ID) ? (int)$u->ID : new WP_Error('non_customer_account');
            // Real email only; WordPress password recovery grants access to its owner. No auto-login or email is sent here.
            return wp_insert_user(array('user_login'=>'vesta_email_'.substr(hash_hmac('sha256',strtolower($email),wp_salt('secure_auth')),0,24),
                'user_email'=>$email,'user_pass'=>wp_generate_password(40,true,true),'role'=>'customer'));
        } finally { $wpdb->get_var($wpdb->prepare('SELECT RELEASE_LOCK(%s)',$lock)); }
    }
    static function attach($id) {
        $id=absint($id);
        if (!$id || isset(self::$running[$id]) || !get_option('vesta_channel_accounts_enabled',false)) return 'disabled_or_busy';
        self::$running[$id]=true;
        global $wpdb;
        $lock='vesta_channel_order_'.$id;$locked=false;
        try {
            if ((int)$wpdb->get_var($wpdb->prepare('SELECT GET_LOCK(%s, 3)',$lock))!==1) return 'order_busy';
            $locked=true;
            // Read again under the order lock. Always respect an existing customer assignment.
            $o=wc_get_order($id);
            if (!$o || $o->get_customer_id()) return 'already_assigned';
            if (!self::eligible($o)) return 'not_confirmed';
            $user=self::resolve($o);
            if (is_wp_error($user)) {
                $reason=sanitize_key($user->get_error_code());
                if ($o->get_meta('_vesta_account_issue')!==$reason) {
                    $o->update_meta_data('_vesta_account_issue',$reason);$o->save_meta_data();
                }
                return $reason;
            }
            if (!$user || !self::customer($user)) return 'invalid_customer';
            $o->set_customer_id((int)$user);
            $o->update_meta_data('_vesta_account_linked_at',gmdate('c'));
            $o->delete_meta_data('_vesta_account_issue');
            $o->save();
            $saved=wc_get_order($id);
            return $saved && (int)$saved->get_customer_id()===(int)$user ? 'linked' : 'link_not_saved';
        } catch (Throwable $e) {
            // Keep checkout and gateway callbacks working; the bounded worker retries later.
            error_log('VESTA_CHANNEL_ACCOUNT_RETRY_REQUIRED order_id='.$id);
            return 'retry_required';
        } finally {
            if ($locked) $wpdb->get_var($wpdb->prepare('SELECT RELEASE_LOCK(%s)',$lock));
            unset(self::$running[$id]);
        }
    }
    static function saved($o,$store=null) {
        if (is_a($o,'WC_Order') && $o->get_type()==='shop_order') self::attach($o->get_id());
    }
    static function sweep() {
        if (!get_option('vesta_channel_accounts_enabled',false)) return array();
        $page=max(1,(int)get_option('vesta_channel_accounts_page',1));
        $start=(int)get_option('vesta_channel_accounts_since',time());
        $orders=wc_get_orders(array('type'=>'shop_order','customer_id'=>0,'status'=>self::statuses(),
            'date_created'=>'>='.$start,'limit'=>50,'page'=>$page,'orderby'=>'ID','order'=>'ASC','return'=>'ids'));
        $out=array();
        foreach($orders as $id){$reason=self::attach($id);$out[$reason]=($out[$reason]??0)+1;}
        update_option('vesta_channel_accounts_page',count($orders)<50?1:$page+1,false);
        update_option('vesta_channel_accounts_heartbeat',array('at'=>time(),'results'=>$out),false);
        return $out;
    }
}
// Both normal checkout and API/import integrations save through the WooCommerce order data store.
add_action('woocommerce_after_order_object_save',array('Vesta_Channel_Customers','saved'),30,2);
add_action('woocommerce_new_order',array('Vesta_Channel_Customers','attach'),50,1);
add_action('woocommerce_checkout_order_processed',array('Vesta_Channel_Customers','attach'),50,1);
add_action('woocommerce_store_api_checkout_order_processed',array('Vesta_Channel_Customers','saved'),50,1);
add_action('woocommerce_payment_complete',array('Vesta_Channel_Customers','attach'),50,1);
add_action('woocommerce_order_status_changed',array('Vesta_Channel_Customers','attach'),50,1);
add_action('woocommerce_rest_insert_shop_order_object',array('Vesta_Channel_Customers','saved'),50,1);
add_action('admin_notices',function(){
    if (!current_user_can('manage_woocommerce') || !get_option('vesta_channel_accounts_enabled',false)) return;
    $orders=wc_get_orders(array('type'=>'shop_order','customer_id'=>0,'limit'=>1,'return'=>'ids',
        'meta_key'=>'_vesta_account_issue','meta_compare'=>'EXISTS','date_created'=>'>='.(int)get_option('vesta_channel_accounts_since',time())));
    if($orders)echo '<div class="notice notice-warning"><p>ساخت پنل مشتری: یک سفارش به بررسی شماره موبایل یا تداخل حساب نیاز دارد. جزئیات در یادداشت «وضعیت پنل» سفارش نمایش داده می‌شود.</p></div>';
});
add_action('woocommerce_admin_order_data_after_billing_address',function($o){
    $issue=$o->get_meta('_vesta_account_issue');
    if($issue)echo '<p><strong>وضعیت پنل:</strong> '.esc_html(Vesta_Channel_Customers::issue_label($issue)).'</p>';
});
