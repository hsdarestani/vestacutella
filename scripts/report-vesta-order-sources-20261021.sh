#!/usr/bin/env bash
# Aggregates only, read-only SQL against Vesta's MariaDB. No personal/order rows logged.
set -euo pipefail
q() { printf '%s\n' "$1" | docker exec -i vc-db-vesta sh -c 'exec mariadb -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE" --batch --raw --skip-column-names'; }
prefix=$(q "SELECT LEFT(p.table_name,CHAR_LENGTH(p.table_name)-5) FROM information_schema.tables p WHERE p.table_schema=DATABASE() AND p.table_name LIKE '%posts' AND EXISTS(SELECT 1 FROM information_schema.tables x WHERE x.table_schema=DATABASE() AND x.table_name=CONCAT(LEFT(p.table_name,CHAR_LENGTH(p.table_name)-5),'postmeta')) ORDER BY p.table_name LIMIT 1;")
[[ "$prefix" =~ ^[a-zA-Z0-9_]+$ ]] || { echo SCHEMA_UNAVAILABLE; exit 2; }
currency=$(q "SELECT option_value FROM ${prefix}options WHERE option_name='woocommerce_currency' LIMIT 1;")
hpos_exists=$(q "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=DATABASE() AND table_name='${prefix}wc_orders';")
hpos_count=0
if [[ "$hpos_exists" == 1 ]]; then
  hpos_count=$(q "SELECT COUNT(*) FROM ${prefix}wc_orders WHERE type='shop_order' AND date_created_gmt>='2026-04-20 20:30:00' AND date_created_gmt<'2026-10-21 20:30:00';")
fi
if (( hpos_count > 0 )); then
 mode=HPOS
 raw="SELECT o.id oid, MAX(DATE_FORMAT(DATE_ADD(o.date_created_gmt,INTERVAL 210 MINUTE),'%Y-%m')) mon,
 MAX(o.status) st, MAX(o.total_amount) amount, MAX(o.payment_method) gateway,
 MAX(CASE WHEN m.meta_key='_wc_order_attribution_source_type' THEN LEFT(m.meta_value,255) ELSE '' END) source_type,
 MAX(CASE WHEN m.meta_key='_wc_order_attribution_utm_source' THEN LEFT(m.meta_value,255) ELSE '' END) utm,
 MAX(CASE WHEN m.meta_key='_wc_order_attribution_utm_medium' THEN LEFT(m.meta_value,255) ELSE '' END) medium,
 MAX(CASE WHEN m.meta_key='_wc_order_attribution_referrer' THEN LEFT(m.meta_value,1024) ELSE '' END) referrer,
 MAX(CASE WHEN m.meta_key='_wc_order_attribution_session_entry' THEN LEFT(m.meta_value,1024) ELSE '' END) entry
 FROM ${prefix}wc_orders o LEFT JOIN ${prefix}wc_orders_meta m ON m.order_id=o.id AND m.meta_key IN ('_wc_order_attribution_source_type','_wc_order_attribution_utm_source','_wc_order_attribution_utm_medium','_wc_order_attribution_referrer','_wc_order_attribution_session_entry')
 WHERE o.type='shop_order' AND o.date_created_gmt>='2026-04-20 20:30:00' AND o.date_created_gmt<'2026-10-21 20:30:00' GROUP BY o.id"
else
 mode=LEGACY
 raw="SELECT o.ID oid, MAX(DATE_FORMAT(o.post_date,'%Y-%m')) mon,MAX(o.post_status) st,
 MAX(CASE WHEN m.meta_key='_order_total' THEN CAST(m.meta_value AS DECIMAL(20,2)) ELSE 0 END) amount,
 MAX(CASE WHEN m.meta_key='_payment_method' THEN LEFT(m.meta_value,100) ELSE '' END) gateway,
 MAX(CASE WHEN m.meta_key='_wc_order_attribution_source_type' THEN LEFT(m.meta_value,255) ELSE '' END) source_type,
 MAX(CASE WHEN m.meta_key='_wc_order_attribution_utm_source' THEN LEFT(m.meta_value,255) ELSE '' END) utm,
 MAX(CASE WHEN m.meta_key='_wc_order_attribution_utm_medium' THEN LEFT(m.meta_value,255) ELSE '' END) medium,
 MAX(CASE WHEN m.meta_key='_wc_order_attribution_referrer' THEN LEFT(m.meta_value,1024) ELSE '' END) referrer,
 MAX(CASE WHEN m.meta_key='_wc_order_attribution_session_entry' THEN LEFT(m.meta_value,1024) ELSE '' END) entry
 FROM ${prefix}posts o LEFT JOIN ${prefix}postmeta m ON m.post_id=o.ID AND m.meta_key IN ('_order_total','_payment_method','_wc_order_attribution_source_type','_wc_order_attribution_utm_source','_wc_order_attribution_utm_medium','_wc_order_attribution_referrer','_wc_order_attribution_session_entry')
 WHERE o.post_type='shop_order' AND o.post_date>='2026-04-21 00:00:00' AND o.post_date<'2026-10-22 00:00:00' GROUP BY o.ID"
fi
echo "RANGE|2026-04-21|2026-10-21"
echo "CONFIG|$mode|$currency"
sql="WITH raw_orders AS ($raw),
c AS (SELECT mon,st,COALESCE(amount,0) amount,
CASE
WHEN LOWER(CONCAT_WS(' ',utm,referrer,entry)) REGEXP 'instagram|instagr.am|ig.me' THEN 'Instagram'
WHEN LOWER(CONCAT_WS(' ',utm,referrer,entry)) REGEXP 'snapp' THEN 'Snapp'
WHEN LOWER(CONCAT_WS(' ',utm,referrer,entry)) REGEXP 'google|gclid' THEN 'Google'
WHEN LOWER(CONCAT_WS(' ',utm,referrer,entry)) REGEXP 'facebook|fb.com' THEN 'Facebook'
WHEN LOWER(CONCAT_WS(' ',utm,referrer,entry)) REGEXP 'torob' THEN 'Torob'
WHEN LOWER(CONCAT_WS(' ',utm,referrer,entry)) REGEXP 'emalls' THEN 'Emalls'
WHEN LOWER(CONCAT_WS(' ',utm,referrer,entry)) REGEXP 'telegram|t.me/' THEN 'Telegram'
WHEN LOWER(CONCAT_WS(' ',utm,referrer,entry)) REGEXP 'digikala' THEN 'Digikala'
WHEN LOWER(CONCAT_WS(' ',utm,referrer,entry)) REGEXP 'bing.|yahoo.|duckduckgo.|yandex.' THEN 'Other search'
WHEN LOWER(CONCAT_WS(' ',utm,medium)) REGEXP 'email|newsletter' THEN 'Email'
WHEN LOWER(source_type) IN ('direct','typein') OR LOWER(utm)='direct' THEN 'Direct'
WHEN source_type<>'' OR CONCAT(utm,referrer,entry)<>'' THEN 'Other attributed'
ELSE 'Unknown / untracked' END channel,
CASE WHEN LOWER(source_type) REGEXP '^[a-z0-9_-]{1,30}$' THEN LOWER(source_type) ELSE 'missing' END stype,
CASE WHEN LOWER(gateway) REGEXP '^[a-z0-9_-]{1,40}$' THEN LOWER(gateway) ELSE 'missing' END gateway,
(source_type<>'') has_type,(utm<>'') has_utm,(referrer<>'') has_ref,(entry<>'') has_entry
FROM raw_orders)
SELECT tag,category,n,total FROM (
SELECT 'SUMMARY' tag,'all' category,COUNT(*) n,ROUND(COALESCE(SUM(amount),0),2) total FROM c
UNION ALL SELECT 'SUMMARY','active_orders',COUNT(*),ROUND(COALESCE(SUM(amount),0),2) FROM c WHERE st IN ('wc-processing','wc-completed')
UNION ALL SELECT 'STATUS',st,COUNT(*),ROUND(COALESCE(SUM(amount),0),2) FROM c GROUP BY st
UNION ALL SELECT 'CHANNEL',channel,COUNT(*),ROUND(COALESCE(SUM(amount),0),2) FROM c WHERE st IN ('wc-processing','wc-completed') GROUP BY channel
UNION ALL SELECT 'MONTH_CHANNEL',CONCAT(mon,'|',channel),COUNT(*),ROUND(COALESCE(SUM(amount),0),2) FROM c WHERE st IN ('wc-processing','wc-completed') GROUP BY mon,channel
UNION ALL SELECT 'SOURCE_TYPE',stype,COUNT(*),ROUND(COALESCE(SUM(amount),0),2) FROM c WHERE st IN ('wc-processing','wc-completed') GROUP BY stype
UNION ALL SELECT 'PAYMENT',gateway,COUNT(*),ROUND(COALESCE(SUM(amount),0),2) FROM c WHERE st IN ('wc-processing','wc-completed') GROUP BY gateway
UNION ALL SELECT 'CAPTURED','source_type',COALESCE(SUM(has_type),0),0 FROM c WHERE st IN ('wc-processing','wc-completed')
UNION ALL SELECT 'CAPTURED','utm_source',COALESCE(SUM(has_utm),0),0 FROM c WHERE st IN ('wc-processing','wc-completed')
UNION ALL SELECT 'CAPTURED','referrer',COALESCE(SUM(has_ref),0),0 FROM c WHERE st IN ('wc-processing','wc-completed')
UNION ALL SELECT 'CAPTURED','session_entry',COALESCE(SUM(has_entry),0),0 FROM c WHERE st IN ('wc-processing','wc-completed')
) report ORDER BY tag,category;"
q "$sql" | sed $'s/\t/|/g'
echo REPORT_DONE
