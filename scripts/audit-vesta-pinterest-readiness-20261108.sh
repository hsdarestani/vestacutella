#!/usr/bin/env bash
# Read-only Pinterest readiness checks for WooCommerce. No credentials printed.
set -euo pipefail
SITE=https://vesta-cosmetics.ir
echo "VESTA_PINTEREST_READINESS_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
for p in / /shop/ /robots.txt; do
  printf 'PUBLIC_%s ' "$p"
  curl -LsS --connect-timeout 8 --max-time 25 -o /dev/null -w 'HTTP=%{http_code} URL=%{url_effective}\n' "$SITE$p" || true
done
home=$(curl -LsS --max-time 20 "$SITE/" 2>/dev/null | head -c 40000 || true)
if grep -Eiq 'در حال بروز رسانی|در حال بروزرسانی|maintenance|coming soon' <<<"$home"; then
  echo "PUBLIC_STOREFRONT_MAINTENANCE=true"
else
  echo "PUBLIC_STOREFRONT_MAINTENANCE=false_or_unknown"
fi
if ! docker inspect vc-vesta >/dev/null 2>&1; then echo "WORDPRESS_CONTAINER_UNAVAILABLE"; exit 0; fi
data=$(docker exec -i vc-vesta php -d display_errors=0 -r '
error_reporting(E_ERROR|E_PARSE);
require "/var/www/html/wp-load.php";
if (!function_exists("wc_get_product")) { exit(2); }
$c=wp_count_posts("product");
$ids=get_posts(array("post_type"=>"product","post_status"=>"publish","fields"=>"ids","posts_per_page"=>1,"meta_query"=>array(array("key"=>"_thumbnail_id","compare"=>"EXISTS"))));
$d=array("published_products"=>(int)$c->publish,"currency"=>get_option("woocommerce_currency"),"sample_product_url"=>null,"sample_image_url"=>null);
if ($ids) { $p=wc_get_product($ids[0]); if ($p) { $d["sample_product_url"]=get_permalink($p->get_id()); $d["sample_image_url"]=wp_get_attachment_url($p->get_image_id()); }}
echo json_encode($d,JSON_UNESCAPED_SLASHES|JSON_UNESCAPED_UNICODE);
' 2>/dev/null) || true
if ! printf '%s' "$data" | python3 -m json.tool >/dev/null 2>&1; then echo "WORDPRESS_QUERY_FAILED"; exit 0; fi
echo "PUBLIC_WOOCOMMERCE_DATA=$data"
url=$(printf '%s' "$data" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("sample_product_url") or "")')
case "$url" in
  https://vesta-cosmetics.ir/*) ;;
  *) echo "BLOCKER_NO_VALID_PUBLIC_PRODUCT_SAMPLE"; exit 0;;
esac
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
curl -LsS --connect-timeout 8 --max-time 25 -o "$tmp" -w 'PRODUCT_HTTP=%{http_code} PRODUCT_TYPE=%{content_type}\n' "$url" || true
HTML_FILE="$tmp" python3 - <<'PY'
import os,re
from html.parser import HTMLParser
class P(HTMLParser):
  def __init__(self): super().__init__(); self.m={}
  def handle_starttag(self,t,a):
    if t=='meta':
      d=dict(a); k=d.get('property',d.get('name','')).lower()
      if k in ('og:title','og:image','og:type','product:price:amount','product:price:currency','robots'): self.m.setdefault(k,d.get('content',''))
s=open(os.environ['HTML_FILE'],encoding='utf-8',errors='replace').read()
p=P(); p.feed(s)
for k in ('og:title','og:image','og:type','product:price:amount','product:price:currency','robots'):
  v=p.m.get(k,'MISSING')
  if k in ('og:title','og:image') and v!='MISSING': v='PRESENT'
  print('META_'+k.replace(':','_').upper()+'='+v[:90])
print('SCHEMA_PRODUCT='+str(bool(re.search(r'"@type"\s*:\s*"Product"',s,re.I))).lower())
print('PRODUCT_MAINTENANCE='+str(bool(re.search('در حال بروز رسانی|در حال بروزرسانی|maintenance',s,re.I))).lower())
PY
echo READ_ONLY_AUDIT_COMPLETE

echo '[4] Maintenance origin and SEO plugin identification (read only)'
docker exec -i vc-vesta php -d display_errors=0 -r '
error_reporting(E_ERROR|E_PARSE);
require "/var/www/html/wp-load.php";
echo "WORDPRESS_MAINTENANCE_FILE=".(file_exists(ABSPATH.".maintenance")?"present":"absent")."\n";
echo "WORDPRESS_PUBLIC_SEARCH_ENGINE_OPTION=".(int)get_option("blog_public")."\n";
$plugins=(array)get_option("active_plugins",array());
foreach($plugins as $plugin) {
 if(preg_match("~maintenance|coming-soon|under-construction|seedprod|elementor|seo|rank-math|yoast|all-in-one|woocommerce~i",$plugin))
  echo "ACTIVE_PLUGIN=".preg_replace("~[^a-zA-Z0-9_./-]~","",$plugin)."\n";
}
foreach(array("woodmart_maintenance_mode","maintenance_mode","wp_maintenance_mode","seedprod_coming_soon_mode") as $key) {
  $v=get_option($key,null);
  if(is_scalar($v)) echo "OPTION_".$key."=".substr((string)$v,0,30)."\n";
}
' 2>/dev/null || echo MAINTENANCE_INSPECTION_FAILED
