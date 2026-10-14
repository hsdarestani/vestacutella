#!/usr/bin/env bash
# Final read-only sanity checks: all home/shop image variants, WebP, cache safety.
set -euo pipefail
echo "=== FINAL STORE MEDIA AND CACHE CHECK ==="
for site in vesta cutella;do
 if [[ "$site" == vesta ]];then d=vesta-cosmetics.ir; else d=cutellashop.ir;fi
 echo "--- $site : $d ---"
 for route in / /shop/ /cart/ /checkout/ /my-account/ /wp-login.php;do
  code="$(curl --noproxy '*' -kLsS --max-time 25 --resolve "$d:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$d$route")"
  echo "route=$route code=$code"
  [[ "$code" == 200 ]] || [[ "$code" == 302 ]] || exit 21
 done
 for route in / /shop/;do
  tmp="$(mktemp)"
  curl --noproxy '*' -kLsS --max-time 25 --resolve "$d:443:127.0.0.1" "https://$d$route" > "$tmp"
  DOMAIN="$d" SITE="$site" PAGE="$route" FILE="$tmp" python3 - <<'PY'
import os,html,urllib.parse,collections
from html.parser import HTMLParser
class P(HTMLParser):
 def __init__(self): super().__init__();self.images=[];self.pictures=0;self.webps=[]
 def handle_starttag(self,t,attrs):
  d=dict(attrs)
  if t=='img':self.images.append(d)
  if t=='picture':self.pictures+=1
  if t=='source' and d.get('type')=='image/webp':self.webps.append(d.get('srcset',''))
p=P();p.feed(open(os.environ['FILE'],errors='replace').read())
d=os.environ['DOMAIN'];site=os.environ['SITE'];base='/srv/vestacutella/runtime/'+site
urls=set();remote=set()
for im in p.images:
 for attr in ['src','data-src','data-lazy-src']:
  if im.get(attr):urls.add(im[attr])
 for attr in ['srcset','data-srcset']:
  if im.get(attr):
   for part in im[attr].split(','):
    u=part.strip().split()
    if u:urls.add(u[0])
for u in p.webps:urls.add(u)
missing=[];matched=0
for val in urls:
 val=html.unescape(val)
 if val.startswith(('data:','blob:','javascript:')):continue
 parsed=urllib.parse.urlsplit(urllib.parse.urljoin('https://'+d+'/',val))
 if parsed.hostname not in (d,'www.'+d):
  remote.add(parsed.hostname or '');continue
 path=urllib.parse.unquote(parsed.path)
 if not path.startswith('/wp-content/'):continue
 loc=base+path
 if os.path.isfile(loc):matched+=1
 else:missing.append(parsed.path)
print('MEDIA_COUNTS',d,os.environ['PAGE'],'img_tags',len(p.images),'picture_tags',p.pictures,'webp_sources',len(p.webps),'local_assets',matched,'missing_on_disk',len(missing),'remote_hosts',','.join(sorted(remote))[:250])
for x in missing[:20]:print('MEDIA_MISSING',x[:250])
if site=='vesta' and os.environ['PAGE']=='/':
 assert len(p.webps)>=4, 'Missing Vesta four WebP sources'
 for src in p.webps:
  assert src.endswith('.vc20261014.webp'), 'Unknown source format'
PY
  rm -f "$tmp"
 done
 echo "=== $d sample public static cache headers ==="
 url="$(find "/srv/vestacutella/runtime/$site/wp-content/uploads/" -type f \( -iname '*.jpg' -o -iname '*.png' -o -iname '*.webp' \) -print -quit)"
 if [[ -n "$url" ]];then
  path="$(printf '%s' "$url" | sed "s#^/srv/vestacutella/runtime/$site##")"
  curl --noproxy '*' -kLsSI --max-time 20 "https://$d$path" | grep -Ei '^(HTTP/|server:|cf-cache-status:|cache-control:|content-type:)' | head -10 || true
 fi
done
echo "=== CUTELLA PUBLIC CACHE COOKIE BYPASS ==="
for cookie in '' 'woocommerce_items_in_cart=1';do
 if [[ -z "$cookie" ]];then
  curl --noproxy '*' -kLsSI --max-time 20 --resolve cutellashop.ir:443:127.0.0.1 https://cutellashop.ir/ | grep -Ei '^(HTTP/|x-vc-guest-cache:)' | head -5
 else
  curl --noproxy '*' -kLsSI --max-time 20 --resolve cutellashop.ir:443:127.0.0.1 -H "Cookie: $cookie" https://cutellashop.ir/ | grep -Ei '^(HTTP/|x-vc-guest-cache:)' | head -5
 fi
done
echo "=== REDIS AND ROUTING ==="
for site in vesta cutella;do
 docker exec "vc-$site" php -r '
 require "/var/www/html/wp-load.php";
 echo "external_cache=".(wp_using_ext_object_cache()?"yes":"no").
 " redis_db=".(defined("WP_REDIS_DATABASE")?WP_REDIS_DATABASE:"none").PHP_EOL;
 ' 2>/dev/null || exit 23
done
grep -q 'server_name app.vesta-cosmetics.ir;' /srv/vestacutella/repo/infra/nginx.conf
docker exec vc-nginx nginx -t
echo "FINAL_STORE_MEDIA_AND_CACHE_OK"
