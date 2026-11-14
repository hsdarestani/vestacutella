<?php
/**
 * Plugin Name: Vesta Accounting Reliability
 * Version: 1.0.0
 * Description: Durable accounting outbox with independent remote verification.
 */
if (!defined('ABSPATH')) exit;
require_once __DIR__.'/vesta-accounting-policy.php';
class Vesta_Accounting_Reliability {
    public static $dispatching = false;
    static function table() { global $wpdb; return $wpdb->prefix.'vesta_accounting_outbox'; }
    static function install() {
        global $wpdb;
        require_once ABSPATH.'wp-admin/includes/upgrade.php';
        $t=self::table();
        dbDelta("CREATE TABLE $t (
          order_id bigint(20) unsigned NOT NULL,
          request_key varchar(64) NOT NULL,
          state varchar(32) NOT NULL DEFAULT 'pending',
          reason varchar(80) NOT NULL DEFAULT '',
          remote_id bigint(20) unsigned NOT NULL DEFAULT 0,
          attempts int unsigned NOT NULL DEFAULT 0,
          failures int unsigned NOT NULL DEFAULT 0,
          next_attempt bigint(20) unsigned NOT NULL DEFAULT 0,
          submitted_at bigint(20) unsigned NOT NULL DEFAULT 0,
          created_at bigint(20) unsigned NOT NULL,
          updated_at bigint(20) unsigned NOT NULL,
          PRIMARY KEY  (order_id),
          KEY state_due (state,next_attempt),
          UNIQUE KEY request_key (request_key)
        ) ENGINE=InnoDB {$wpdb->get_charset_collate()};");
        if ($wpdb->get_var($wpdb->prepare('SHOW TABLES LIKE %s',$t)) !== $t) throw new RuntimeException('outbox_schema_failed');
        update_option('vcar_schema','1',false);
    }
    static function enqueue($id) {
        global $wpdb;
        if (get_option('vcar_schema')!=='1') return;
        $o=wc_get_order($id); if(!vcar_eligible($o)) return;
        $t=self::table(); $now=time();
        $wpdb->query($wpdb->prepare("INSERT IGNORE INTO $t (order_id,request_key,created_at,updated_at) VALUES (%d,%s,%d,%d)",
            $id,hash('sha256','vesta-cosmetics.ir:woo:'.$id),$now,$now));
    }
    static function request($id) {
        global $wpdb;self::enqueue($id);
        $r=$wpdb->get_row($wpdb->prepare('SELECT state,remote_id FROM '.self::table().' WHERE order_id=%d',$id),ARRAY_A);
        return array('success'=>($r['state']??'')==='verified','message'=>($r['state']??'')==='verified'
            ? 'Cloud invoice verified: '.(int)$r['remote_id'].'; desktop not verified'
            : 'Queued for independent cloud verification; not yet synchronized');
    }
    static function set($id,$state,$reason='',$extra=array()) {
        global $wpdb;
        $data=array_merge(array('state'=>$state,'reason'=>$reason,'updated_at'=>time()),$extra);
        if ($wpdb->update(self::table(),$data,array('order_id'=>$id))===false) throw new RuntimeException('outbox_write_failed');
    }
    static function seed($limit=200) {
        global $wpdb;
        $cursor=(int)get_option('vcar_scan_cursor',0);
        // HPOS is disabled on the verified production install. Fail closed on a future switch.
        if(get_option('woocommerce_custom_orders_table_enabled')==='yes') throw new RuntimeException('hpos_requires_adapter');
        $ids=$wpdb->get_col($wpdb->prepare("SELECT ID FROM {$wpdb->posts} WHERE post_type='shop_order' AND ID>%d ORDER BY ID LIMIT %d",$cursor,$limit));
        foreach($ids as $id){self::enqueue((int)$id);$cursor=(int)$id;}
        update_option('vcar_scan_cursor',$cursor,false);
        if(count($ids)<$limit) update_option('vcar_history_scan_complete',time(),false);
        return count($ids);
    }
    static function seed_all() {
        global $wpdb;$t=self::table();$now=time();
        $statuses=array('wc-processing','wc-completed','wc-processing5','wc-pws-packaged','wc-pws-shipping','wc-arrival-shipment','wc-pws-courier','wc-pws-post');
        $st="'".implode("','",$statuses)."'";
        $n=$wpdb->query("INSERT IGNORE INTO $t (order_id,request_key,created_at,updated_at)
          SELECT ID,SHA2(CONCAT('vesta-cosmetics.ir:woo:',ID),256),$now,$now FROM {$wpdb->posts} p
          WHERE post_type='shop_order' AND post_status IN ($st) AND EXISTS(
            SELECT 1 FROM {$wpdb->postmeta} m WHERE m.post_id=p.ID AND
            ((m.meta_key='_date_paid' AND CAST(m.meta_value AS UNSIGNED)>0) OR (m.meta_key='_paid_date' AND m.meta_value<>'')))");
        if($n===false)throw new RuntimeException('full_history_seed_failed');
        update_option('vcar_scan_cursor',(int)$wpdb->get_var("SELECT MAX(ID) FROM {$wpdb->posts} WHERE post_type='shop_order'"),false);
        update_option('vcar_history_scan_complete',time(),false);
        return $n;
    }
    static function cloud($api) {
        $r=$api->get_all_data('',array('fromOrderVersion'=>0,'fromOrderDetailVersion'=>0,'fromReceiptVersion'=>0,'fromChequeVersion'=>0));
        if(!is_array($r)||empty($r['success'])) throw new RuntimeException('cloud_read_unavailable');
        $m=$r['message']??array();
        foreach(array('Orders','OrderDetails','Receipts') as $k) if(!isset($m[$k])||!is_array($m[$k])) throw new RuntimeException('cloud_contract_missing');
        $out=array('orders'=>array(),'details'=>array(),'receipts'=>array(),'transfers'=>$m['Cheques']??array());
        foreach($m['Orders'] as $r) if(empty($r['Deleted'])) $out['orders'][(int)$r['OrderClientId']][]=$r;
        foreach($m['OrderDetails'] as $r) if(empty($r['Deleted'])) $out['details'][(int)$r['OrderId']][]=$r;
        foreach($m['Receipts'] as $r) if(empty($r['Deleted'])) $out['receipts'][(int)$r['OrderId']][]=$r;
        return $out;
    }
    static function verify($id,$o,$cloud,$bank) {
        $rows=$cloud['orders'][$id]??array();
        if(!$rows) return false;
        if(count($rows)!==1){self::set($id,'conflict','multiple_remote_invoices');return true;}
        $r=$rows[0];$erp=(int)$r['OrderId'];
        $error=vcar_verify($o,$r,$cloud['details'][$erp]??array(),$cloud['receipts'][$erp]??array(),$bank,$cloud['transfers']);
        self::set($id,$error?'cloud_mismatch':'verified',$error,array('remote_id'=>$erp,'next_attempt'=>time()+3600));
        if(!$error) {
            $o->update_meta_data('_vcar_cloud_verified_at',gmdate('c'));
            $o->update_meta_data('_vcar_cloud_invoice_id',$erp);$o->save_meta_data();
        }
        return true;
    }
    static function tick($force=false,$maxSend=1) {
        global $wpdb;
        if(get_option('vcar_schema')!=='1'||!class_exists('BazaraApi')) return array('success'=>false,'message'=>'Outbox not initialized');
        // Linux protected_regular can reject O_CREAT on a www-data-owned /tmp lock for root CLI.
        // Opening an existing inode read-only still supports flock(LOCK_EX), without changing ownership.
        $path='/tmp/vesta-bazara-order-sync.lock';
        $lock=is_file($path)?fopen($path,'r'):fopen($path,'x+');
        if(!$lock)return array('success'=>false,'message'=>'Accounting lock inaccessible');
        if(!flock($lock,LOCK_EX|LOCK_NB)){fclose($lock);return array('success'=>false,'message'=>'Accounting worker busy');}
        try {
            if(!$force && time()-(int)get_option('vcar_last_start',0)<100)return array('success'=>false,'message'=>'Accounting worker throttled');
            update_option('vcar_last_start',time(),false);
            if(time()-(int)get_option('vcar_history_scan_complete',0)>3600)self::seed_all();
            else self::seed(150);
            $api=new BazaraApi(true);$cloud=self::cloud($api);
            $settings=get_option('bazara_visitor_settings',array());
            $t=self::table();$now=time();$sent=0;
            $rows=$wpdb->get_results($wpdb->prepare("SELECT * FROM $t WHERE state<>'verified' AND next_attempt<=%d ORDER BY submitted_at DESC,order_id DESC LIMIT 60",$now),ARRAY_A);
            foreach($rows as $q) {
                $id=(int)$q['order_id'];$o=wc_get_order($id);
                if(!vcar_eligible($o)){self::set($id,'ineligible','payment_or_status_changed',array('next_attempt'=>$now+3600));continue;}
                $bank=vcar_bank($settings,$o->get_payment_method());
                if(self::verify($id,$o,$cloud,$bank))continue;
                if((int)$q['submitted_at']>0){self::set($id,'uncertain','submitted_without_remote_ack',array('next_attempt'=>$now+600));continue;}
                $local=(int)$o->get_meta('mahak_id');
                $cached=(int)$wpdb->get_var($wpdb->prepare("SELECT COUNT(*) FROM {$wpdb->prefix}bazara_orders WHERE OrderClientId=%d",$id));
                if($local||$cached){self::set($id,'conflict','local_ack_without_remote_invoice',array('next_attempt'=>$now+3600));continue;}
                $reason=self::preflight($o,$bank);
                if($reason){self::set($id,'blocked',$reason,array('next_attempt'=>$now+600));continue;}
                // Archived fiscal years cannot be proven absent from today's cloud export.
                // Historical records stay in the durable queue pending a complete Mahak ledger comparison.
                $created=$o->get_date_created();
                if($created && $created->getTimestamp()<strtotime('2026-11-08T00:00:00Z')) {
                    self::set($id,'blocked','historical_ledger_export_required',array('next_attempt'=>$now+3600));continue;
                }
                if($sent >= $maxSend || !get_option('vcar_sender_enabled',false))continue;
                // Persist BEFORE making a potentially ambiguous external mutation.
                self::set($id,'sending','',array('attempts'=>(int)$q['attempts']+1,'submitted_at'=>time()));
                self::$dispatching=true;
                try {$api->bazara_save_order($id,'');}finally{self::$dispatching=false;}
                $sent++;
                $cloud=self::cloud($api);
                if(!self::verify($id,$o,$cloud,$bank))self::set($id,'uncertain','submitted_without_remote_ack',array('next_attempt'=>time()+600));
            }
            update_option('vcar_read_failures',0,false);
            update_option('vcar_heartbeat',array('at'=>time(),'sent'=>$sent,'error'=>''),false);
            $pending=(int)$wpdb->get_var("SELECT COUNT(*) FROM $t WHERE state<>'verified' AND state<>'ineligible'");
            return array('success'=>$pending===0,'message'=>'Accounting outbox: '.$pending.' orders still require cloud verification. Desktop receipt is not verified.','sent'=>$sent);
        } catch(Throwable $e) {
            $n=(int)get_option('vcar_read_failures',0)+1;update_option('vcar_read_failures',$n,false);
            $code=in_array($e->getMessage(),array('cloud_read_unavailable','cloud_contract_missing','hpos_requires_adapter','outbox_write_failed'),true)?$e->getMessage():'worker_exception';
            update_option('vcar_heartbeat',array('at'=>time(),'sent'=>0,'error'=>$code),false);
            update_option('vcar_last_start',time()+min(3600,60*pow(2,min($n,6))),false);
            error_log('VCAR_WORKER_FAILED_NO_AUTOMATIC_RESUBMISSION');
            return array('success'=>false,'message'=>'Accounting worker requires retry or inspection');
        } finally {flock($lock,LOCK_UN);fclose($lock);}
    }
    static function preflight($o,$bank) {
        global $wpdb;
        if($o->get_currency()!=='IRT')return 'unsupported_currency';
        if(!$bank || !$wpdb->get_var($wpdb->prepare("SELECT BankId FROM {$wpdb->prefix}bazara_banks WHERE BankId=%d AND Deleted=0",$bank)))return 'payment_bank_unmapped';
        if((float)$o->get_total_tax()!=0||count($o->get_items('fee')))return 'unsupported_tax_or_fee';
        $sum=0;$items=$o->get_items('line_item');if(!$items)return 'no_line_items';
        foreach($items as $it){
            $pid=$it->get_variation_id()?:$it->get_product_id();
            $p=(int)get_post_meta($pid,'mahak_id',true);$d=(int)get_post_meta($pid,'mahak_product_detail_id',true);
            if(!$p||!$d)return 'missing_product_mapping';
            if(!$wpdb->get_var($wpdb->prepare("SELECT ProductDetailId FROM {$wpdb->prefix}bazara_product_details WHERE ProductDetailId=%d AND ProductId=%d AND Deleted=0",$d,$p)))return 'invalid_product_mapping';
            if((float)$it->get_quantity()<=0)return 'invalid_quantity';
            $sum+=(float)$it->get_total();
        }
        return abs($sum+(float)$o->get_shipping_total()-(float)$o->get_total())>0.51?'order_total_mismatch':'';
    }
    static function dashboard() {
        if(!current_user_can('manage_woocommerce'))return;
        global $wpdb;$t=self::table();
        $rows=$wpdb->get_results("SELECT state,reason,COUNT(*) n FROM $t GROUP BY state,reason",ARRAY_A);
        $hb=get_option('vcar_heartbeat',array());
        echo '<div class="wrap"><h1>وضعیت واقعی اتصال حسابداری</h1><p>تأیید ابر و تأیید محک ویندوزی مستقل‌اند. وضعیت نسخه ویندوز: تأیید نشده.</p>';
        echo '<p>آخرین اجرای کارگر: '.esc_html(!empty($hb['at'])?gmdate('c',$hb['at']):'هنوز اجرا نشده').'</p>';
        $catalog=get_option('vcar_catalog_status',array());
        if($catalog)echo '<p>کاتالوگ: '.(int)($catalog['complete_mapping']??0).' نگاشت از '.(int)($catalog['active_variations']??0).' تنوع فعال. موارد بدون نگاشت: '.(int)($catalog['missing_mapping']??0).'. خطای آخرین اجرا: '.esc_html($hb['error']??'').'</p>';
        echo '<table class="widefat"><tr><th>وضعیت</th><th>علت</th><th>تعداد</th></tr>';
        foreach($rows as $r)echo '<tr><td>'.esc_html($r['state']).'</td><td>'.esc_html($r['reason']).'</td><td>'.(int)$r['n'].'</td></tr>';
        echo '</table><h2>سفارش‌های نیازمند بررسی</h2><table class="widefat"><tr><th>سفارش</th><th>وضعیت</th><th>علت</th><th>فاکتور ابر</th></tr>';
        foreach($wpdb->get_results("SELECT order_id,state,reason,remote_id FROM $t WHERE state<>'verified' ORDER BY order_id DESC LIMIT 100",ARRAY_A) as $r)
            echo '<tr><td>'.(int)$r['order_id'].'</td><td>'.esc_html($r['state']).'</td><td>'.esc_html($r['reason']).'</td><td>'.(int)$r['remote_id'].'</td></tr>';
        echo '</table></div>';
    }
}
add_action('woocommerce_payment_complete',array('Vesta_Accounting_Reliability','enqueue'),20);
add_action('woocommerce_order_status_changed',array('Vesta_Accounting_Reliability','enqueue'),20);
add_action('admin_menu',function(){add_submenu_page('woocommerce','اتصال واقعی محک','اتصال واقعی محک','manage_woocommerce','vesta-accounting',array('Vesta_Accounting_Reliability','dashboard'));});
add_action('admin_notices',function(){
    if(!current_user_can('manage_woocommerce')||get_option('vcar_schema')!=='1')return;
    global $wpdb;$t=Vesta_Accounting_Reliability::table();$n=(int)$wpdb->get_var("SELECT COUNT(*) FROM $t WHERE state<>'verified'");
    $hb=get_option('vcar_heartbeat',array());$stale=time()-(int)($hb['at']??0)>600;
    if($n||$stale)echo '<div class="notice notice-warning"><p>اتصال محک: '.(int)$n.' سفارش بدون تأیید کامل ابر. '.($stale?'اجرای خودکار نیازمند بررسی است. ':'').'<a href="'.esc_url(admin_url('admin.php?page=vesta-accounting')).'">جزئیات اتصال</a></p></div>';
});
