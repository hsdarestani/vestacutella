#!/usr/bin/env bash
# Read-only staging feasibility + front-page rendering inventory
set -euo pipefail
echo "=== HOST STAGING CAPACITY ==="
date -u
free -m
df -h / /srv/vestacutella 2>/dev/null || df -h /
uptime
docker stats --no-stream --format 'name={{.Name}} cpu={{.CPUPerc}} memory={{.MemUsage}}' vc-nginx vc-vesta vc-cutella vc-db-vesta vc-db-cutella vc-redis 2>/dev/null
echo "=== SAFE INSTANCE COUNTS AND PORTS ==="
docker ps --format 'name={{.Names}} status={{.Status}} ports={{.Ports}}' | head -30
echo "=== WORDPRESS STOREFRONT META ==="
for site in vesta cutella;do
  echo "site=$site"
  docker exec "vc-$site" php -r '
  require "/var/www/html/wp-load.php";
  echo "front_id=".get_option("page_on_front").PHP_EOL;
  echo "shop_id=".get_option("woocommerce_shop_page_id").PHP_EOL;
  echo "theme=".get_stylesheet().PHP_EOL;
  echo "ext_object_cache=".(wp_using_ext_object_cache()?"yes":"no").PHP_EOL;
  ' 2>&1 | head -20
done
echo "=== VESTA HOME SLIDER AND LAZY IMAGE COUNTS ==="
tmp="$(mktemp)"
curl --noproxy '*' -kLsS --max-time 25 --resolve vesta-cosmetics.ir:443:127.0.0.1 https://vesta-cosmetics.ir/ -o "$tmp"
FILE="$tmp" python3 - <<'PY'
import os,re
from html.parser import HTMLParser
class P(HTMLParser):
 def __init__(self):super().__init__();self.rows=[];self.ims=[];self.sliders=[];self.styles=[]
 def handle_starttag(self,t,attrs):
  a=dict(attrs);cl=a.get('class','')
  if t=='img':self.ims.append(a)
  if 'owl-carousel' in cl:self.sliders.append({'id':a.get('id'),'classes':cl[:90]})
  if ('vc_row' in cl or 'wd-carousel-container' in cl) and t=='div': self.rows.append({'id':a.get('id'),'classes':cl[:145]})
p=P();f=open(os.environ['FILE'],errors='replace').read();p.feed(f)
print('HTML_KB',round(len(f.encode())/1024),'IMG',len(p.ims),'LOADING_LAZY',sum(x.get('loading')=='lazy' for x in p.ims),'LOADING_EAGER',sum(x.get('loading')=='eager' for x in p.ims),'SRCSET',sum(bool(x.get('srcset')) for x in p.ims),'WD_SLIDERS',len(p.sliders),'ROWS',len(p.rows))
for n,x in enumerate(p.rows[:35]):print('ROW',n,x['id'],x['classes'])
print('HAS_AJAX_CONTENT_ENDPOINT',bool(re.search('admin-ajax.php',f)))
PY
rm -f "$tmp"
echo "=== STAGING ASSESSMENT COMPLETE ==="
