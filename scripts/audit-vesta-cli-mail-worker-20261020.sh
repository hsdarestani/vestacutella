#!/usr/bin/env bash
set -euo pipefail
echo "AUDIT_UTC=$(date -u +%FT%TZ)"
test -s /etc/cron.d/vesta-admin-order-mail-cli
systemctl is-active --quiet cron
echo "CLI_CRON_SCHEDULE_PRESENT=yes"
test -s /srv/vestacutella/repo/scripts/vesta-admin-order-mail-cli-worker-20261020.php
echo "CLI_WORKER_SOURCE_PRESENT=yes"
if test -e /var/log/vesta-admin-order-mail-cli.log;then
  echo "=== MAIL CLI CRON RECENT CYCLES ==="
  tail -20 /var/log/vesta-admin-order-mail-cli.log | grep -E 'MAIL_CLI|ERROR|Error|Fatal' || true
  echo "CLI_CRON_LOG_SIZE=$(stat -c %s /var/log/vesta-admin-order-mail-cli.log)"
else echo "CLI_CRON_LOG_NOT_YET_CREATED";fi
docker exec -u www-data vc-vesta php -d display_errors=0 -r '
require "/var/www/html/wp-load.php";
$start=(int)get_option("vc_vesta_cli_admin_mail_start_20261020",0);
echo "CLI_WORKER_START_UTC=".($start?gmdate("c",$start):"none")."\n";
$orders=wc_get_orders(["type"=>"shop_order","limit"=>30,"orderby"=>"date","order"=>"DESC","status"=>["processing","completed","on-hold"]]);
$c=["created_after_start"=>0,"accepted_cli"=>0,"accepted_other"=>0,"unconfirmed"=>0];
foreach($orders as $o){
 $date=$o->get_date_created();if(!$date||$date->getTimestamp()<$start)continue;
 $c["created_after_start"]++;
 $mark=(string)$o->get_meta("_vc_vesta_admin_new_order_accepted",true);
 if(strpos($mark,"cli-worker:")===0)$c["accepted_cli"]++;
 elseif($mark)$c["accepted_other"]++;
 else $c["unconfirmed"]++;
}
foreach($c as $key=>$n)echo "CLI_DELIVERY_STATUS ".$key."=".$n."\n";
'
echo "CLI_MAIL_TRANSPORT_AUDIT_COMPLETE"
