#!/usr/bin/env bash
set -uo pipefail
export LC_ALL=C
echo "DIAG_UTC=$(date -u +%FT%TZ)"
echo "=== WORDPRESS_CACHE_UI ==="
docker exec vc-vesta php -d display_errors=0 -r '
require "/var/www/html/wp-load.php";require_once ABSPATH."wp-admin/includes/plugin.php";
global $wpdb;
echo "SITE=" . home_url("/") . "\n";
foreach (["wp-rocket/wp-rocket.php","wp-rocket-minify/wp-rocket.php","redis-cache/redis-cache.php","wp-super-cache/wp-cache.php"] as $p)
 echo "PLUGIN ". $p . "=".(is_plugin_active($p)?"active":"inactive")."\n";
foreach(["rocket_clean_domain","rocket_clean_home","rocket_clean_post","rocket_is_cache_active"] as $f)
 echo "FUNCTION ".$f."=".(function_exists($f)?"yes":"no")."\n";
foreach(["show_admin_bar","admin_bar_menu","wp_before_admin_bar_render","wp_footer","admin_init"] as $h) {
 $f=$GLOBALS["wp_filter"][$h]??null;$n=0;
 if ($f) foreach($f->callbacks as $group) $n+=count($group);
 echo "HOOK ".$h."=". $n."\n";
}
foreach(["wp_rocket_settings","wp_rocket_settings_woocommerce","rocket_cache_reject_uri","wp_rocket_settings","woocommerce_notify_low_stock_amount"] as $k) {
 $v=get_option($k,null);
 echo "OPTION ".$k." present=".($v===null?"no":"yes")." type=".gettype($v)."\n";
}
$users=get_users(["role__in"=>["administrator","shop_manager"],"fields"=>["ID","roles"],"number"=>15]);
foreach($users as $u) {
 $data=get_user_meta($u->ID,"show_admin_bar_front",true);
 echo "DASHBOARD_ROLE=".implode("+",$u->roles)." admin_bar_front=".($data==="false"?"disabled":($data==="true"?"enabled":"default"))."\n";
}
$mu=glob(WPMU_PLUGIN_DIR."/*.php");
echo "MU_PLUGINS=".count((array)$mu)."\n";
foreach($mu as $f) {
 $src=file_get_contents($f, false, null, 0, 8000);
 if (preg_match("/show_admin_bar|admin_bar_menu|remove_menu|wp_rocket|rocket_clean_domain/", $src))
 echo "MU_CACHE_TOOLBAR_REF=".basename($f)."\n";
}
echo "EMAIL_NEW_ORDER_SETTINGS";
$w=WC()->mailer()->get_emails();
foreach($w as $email)if(($email->id??"")==="new_order")echo " enabled=".($email->is_enabled()?"yes":"no")." recipient_count=".count(array_filter(array_map("trim",explode(",",$email->get_recipient()))))."\n";
$s=get_option("wp_mail_smtp",[]);
$m=(array)($s["mail"]??[]);
$smtp=(array)($s["smtp"]??[]);
foreach(["from_email","mailer"] as $k) echo "MAIL_SETTING_".$k."=".($k==="from_email"?(strpos((string)($m[$k]??""),"@")!==false?substr(strrchr($m[$k],"@"),1):"unset"):preg_replace("/[^a-z_-]/i","",(string)($m[$k]??"unset")))."\n";
echo "MAIL_HOST=".preg_replace("/[^a-z0-9.-]/i","",(string)($smtp["host"]??"unset"))." port=".(int)($smtp["port"]??0)." encryption=".preg_replace("/[^a-z0-9_-]/i","",(string)($smtp["encryption"]??"unset"))."\n";
foreach(["woocommerce_email_from_address","admin_email"] as $key){
 $email=(string)get_option($key,"");
 echo "MAIL_FROM_DOMAIN_".$key."=".(strpos($email,"@")!==false?substr(strrchr($email,"@"),1):"unset")."\n";
}
$t=$wpdb->prefix."wpmailsmtp_debug_events";
if($wpdb->get_var($wpdb->prepare("SHOW TABLES LIKE %s",$t))===$t) {
 $r=$wpdb->get_results("SELECT DATE_FORMAT(created_at, \"%Y-%m-%d %H:00\") hour, COUNT(*) qty FROM $t WHERE created_at>=UTC_TIMESTAMP()-INTERVAL 8 HOUR GROUP BY hour ORDER BY hour DESC LIMIT 10",ARRAY_A);
 foreach($r as $a)echo "MAIL_ERROR_BUCKET ".$a["hour"]." count=".$a["qty"]."\n";
}
'
echo "=== CACHE_HTTP ==="
for path in / /shop/; do
 for run in 1 2; do
 echo "path=$path run=$run"
 curl --noproxy '*' -ksS --max-time 20 --resolve vesta-cosmetics.ir:443:127.0.0.1 -D - -o /dev/null "https://vesta-cosmetics.ir$path" | grep -Ei '^(HTTP/|cache-control:|x-cache:|x-rocket:|x-vc-|cf-cache-status:|age:|server:)' | head -10
 done
done
echo "=== EMAIL_AUTH_DNS ==="
for name in vesta-cosmetics.ir _dmarc.vesta-cosmetics.ir;do
 echo "DNS_NAME=$name"
 dig @1.1.1.1 +time=3 +tries=1 +short TXT "$name" 2>/dev/null | grep -Ei 'v=spf1|v=DMARC1' | head -3 || true
done
for sel in default mail selector1 selector2 google dkim;do
 rec="$(dig @1.1.1.1 +short TXT "$sel._domainkey.vesta-cosmetics.ir" 2>/dev/null |tr -d '\n')"
 if echo "$rec" | grep -qi 'v=DKIM1\|p='; then echo "DKIM_SELECTOR=$sel present=yes";fi
done
echo "AUDIT_COMPLETE"
