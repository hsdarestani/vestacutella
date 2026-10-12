#!/usr/bin/env bash
set -uo pipefail
BASE=/srv/vestacutella/runtime
echo '=== DNS (PUBLIC) ==='
if command -v dig >/dev/null 2>&1; then
 for domain in vesta-cosmetics.ir cutellashop.ir; do
  echo "DOMAIN=$domain"
  for type in MX TXT NS; do
   if [[ "$type" = "TXT" ]]; then
    echo -n 'SPF='
    dig @1.1.1.1 +short TXT "$domain" | grep -i 'v=spf1' | sed -E 's/".*"/present/' | head -n 2 || true
    echo -n 'DMARC='; dig @1.1.1.1 +short TXT "_dmarc.$domain" | grep -q -i 'v=DMARC1' && echo yes || echo no
   else
    echo "$type:"; dig @1.1.1.1 +short "$type" "$domain" | head -n 7
   fi
  done
 done
fi
echo '=== HOST CRON ==='
systemctl is-active cron 2>/dev/null || true
if [[ -f /etc/cron.d/vestacutella-wp-cron ]]; then
 echo 'host_wp_cron_file=yes'
 sed -E 's/^(.*docker exec vc-.*)( >.*)$/\1 [output suppressed]/' /etc/cron.d/vestacutella-wp-cron
else echo 'host_wp_cron_file=no'; fi

for site in vesta cutella; do
 echo "========== SITE=$site =========="
 ROOT="$BASE/$site"
 S="$site"
 docker exec -e VC_SITE="$S" "vc-$site" php -d display_errors=0 -r '
 $site=getenv("VC_SITE");
 require "/var/www/html/wp-load.php";
 require_once ABSPATH."wp-admin/includes/plugin.php";
 global $wpdb;
 echo "site_name=".$site." php=".PHP_VERSION."\n";
 echo "DISABLE_WP_CRON=".(defined("DISABLE_WP_CRON") && DISABLE_WP_CRON?"yes":"no")."\n";
 echo "cron_next_due=".((int)wp_next_scheduled("action_scheduler_run_queue"))."\n";
 echo "wp_cron_due=";
 $c=_get_cron_array();$due=0;$n=0;
 if(is_array($c)) foreach($c as $at=>$events){foreach($events as $hooks){$n+=count($hooks);if($at<=time())$due+=count($hooks);}}
 echo $due." total=".$n."\n";
 $active=(array)get_option("active_plugins",[]);
 echo "ACTIVE_PLUGINS=".count($active)."\n";
 foreach($active as $p){echo "plugin=".$p."\n";}
 echo "NOTIFICATION_OPTION_NAMES:\n";
 $names=$wpdb->get_col("SELECT option_name FROM {$wpdb->options} WHERE option_name REGEXP \"(smtp|mail|telegram|robot|bot_|sms|webhook|notification|wc_settings_email|wp_mail)\" LIMIT 160");
 foreach($names as $k){echo "option=".$k."\n";}
 echo "MAILER_PLUGIN_STATUS:\n";
 foreach(array("wp-mail-smtp/wp_mail_smtp.php","easy-wp-smtp/easy-wp-smtp.php","post-smtp/postman-smtp.php","fluent-smtp/fluent-smtp.php","woocommerce/woocommerce.php") as $p) echo $p."=".(is_plugin_active($p)?"active":"inactive")."\n";
 $from=get_option("admin_email","");
 echo "wp_admin_email_configured=". (is_email($from)?"yes":"no") ."\n";
 if (function_exists("WC")) {
   $wc=WC(); if($wc&&method_exists($wc,"mailer")){
     $mailers=$wc->mailer()->get_emails();
     foreach($mailers as $id=>$email){$name=is_string($id)?$id:get_class($email); echo "wc_email=".$name." enabled=".($email->enabled?"yes":"no")."\n";}
   }
 }
 echo "ACTION_SCHEDULER_STATUS:\n";
 $ast=$wpdb->prefix."actionscheduler_actions";
 if($wpdb->get_var($wpdb->prepare("SHOW TABLES LIKE %s",$ast))===$ast){
  $stats=$wpdb->get_results("SELECT status,COUNT(*) as n FROM {$ast} GROUP BY status",ARRAY_A);
  foreach($stats as $z)echo "as_status=".$z["status"]." count=".$z["n"]."\n";
  $key=$wpdb->esc_like("mail"); $hooks=$wpdb->get_results($wpdb->prepare("SELECT hook,status,count(*) n FROM {$ast} WHERE (hook LIKE %s OR hook LIKE %s OR hook LIKE %s OR hook LIKE %s) GROUP BY hook,status ORDER BY n DESC LIMIT 20","%mail%","%telegram%","%order%","%webhook%"),ARRAY_A);
  foreach($hooks as $z)echo "as_hook=".$z["hook"]." status=".$z["status"]." count=".$z["n"]."\n";
 }
 echo "WC_ORDER_TOTALS_LAST_7D:\n";
 $orderstable=$wpdb->prefix."wc_orders";
 if($wpdb->get_var($wpdb->prepare("SHOW TABLES LIKE %s",$orderstable))===$orderstable){
  $x=$wpdb->get_results("SELECT status,count(*) n FROM {$orderstable} WHERE type=\"shop_order\" AND date_created_gmt > UTC_TIMESTAMP()- INTERVAL 7 DAY GROUP BY status",ARRAY_A);
 } else {
  $x=$wpdb->get_results("SELECT post_status status,count(*) n FROM {$wpdb->posts} WHERE post_type=\"shop_order\" AND post_date_gmt > UTC_TIMESTAMP()- INTERVAL 7 DAY GROUP BY post_status",ARRAY_A);
 }
 foreach($x as $z)echo "order_status=".$z["status"]." n=".$z["n"]."\n";
 '
 echo '== disabled plugin names =='
 find "$ROOT/wp-content/plugins" -mindepth 1 -maxdepth 1 -type d -name '*.disabled-for-migration' -printf '%f\n' 2>/dev/null | sort | head -n 50
 echo '== related plugin paths (names only) =='
 find "$ROOT/wp-content/plugins" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | grep -Ei 'smtp|mail|telegram|bot|robot|notification|sms|order|cart|webhook|wp-crontrol' | head -n 65 || true
 echo '== WooCommerce logger filenames (no contents) =='
 find "$ROOT/wp-content/uploads/wc-logs" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null | grep -Ei 'smtp|mail|telegram|bot|sms|notify|webhook|fatal' | tail -n 20 || true
 echo '== plugin code references to Telegram (files only) =='
 grep -rilE --include='*.php' --max-count=1 'api.telegram.org|sendMessage|telegram_bot|telegram\\b' "$ROOT/wp-content/plugins" 2>/dev/null | sed -E "s#^$ROOT/wp-content/plugins/##" | cut -d/ -f1-2 | sort -u | head -n 45 || true
 echo "== outbound SMTP reachability =="
 timeout 5 bash -c 'echo >/dev/tcp/smtp.gmail.com/587' >/dev/null 2>&1 && echo "gmail_587=reachable" || echo "gmail_587=blocked_or_unreachable"
done
echo 'STORE_MAIL_BOT_DIAGNOSTIC_COMPLETE'
