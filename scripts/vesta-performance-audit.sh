#!/usr/bin/env bash
# Read-only production baseline for both WooCommerce stores.
set -uo pipefail
BASE=/srv/vestacutella
echo "=== AUDIT $(date -u +%FT%TZ) ==="
echo "=== SERVER ==="
hostname
uptime
free -h
df -h /
echo "=== RECENT BACKUPS (metadata only) ==="
for p in /srv/backups /srv/vestacutella/runtime/db-vesta /srv/vestacutella/runtime/db-cutella; do
  if [[ -e "$p" ]]; then du -sh "$p" 2>/dev/null || true; else echo "MISSING $p"; fi
done
find /srv/backups -maxdepth 2 -type f -printf '%TY-%Tm-%Td %s %p\n' 2>/dev/null | sort -r | head -15 || true
echo "=== DOCKER ==="
docker ps --format 'table {{.Names}}\t{{.Status}}'
docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.PIDs}}' vc-nginx vc-vesta vc-cutella vc-db-vesta vc-db-cutella 2>/dev/null || true
echo "=== PHP/EXTENSIONS ==="
for site in vesta cutella; do
  echo "--- $site ---"
  docker exec "vc-$site" php -r 'echo "version=".PHP_VERSION." opcache=".(extension_loaded("Zend OPcache")?"yes":"no")." redis_extension=".(extension_loaded("redis")?"yes":"no")." memory=".ini_get("memory_limit").PHP_EOL;' 2>/dev/null || true
done
echo "=== DATABASE METRICS ==="
for db in vesta cutella; do
  echo "--- $db ---"
  docker exec "vc-$db" php -r '
  require "/var/www/html/wp-load.php";
  global $wpdb;
  echo "dbname=".DB_NAME." tables_prefix=".$wpdb->prefix.PHP_EOL;
  $r=$wpdb->get_row("SELECT COUNT(*) n, COALESCE(SUM(LENGTH(option_value)),0) b FROM {$wpdb->options} WHERE autoload IN (\"yes\",\"on\",\"auto\",\"auto-on\")",ARRAY_A);
  echo "autoload_rows=".($r["n"]??"unknown")." bytes=".($r["b"]??"unknown").PHP_EOL;
  echo "wp_cache_ext=".(function_exists("wp_using_ext_object_cache") && wp_using_ext_object_cache()?"yes":"no").PHP_EOL;
  $plugins=(array)get_option("active_plugins",[]);
  foreach($plugins as $p) if(preg_match("/rocket|redis|cache|asset|optimi|performance|woocommerce/i",$p)) echo "active_plugin=".$p.PHP_EOL;
  ' 2>&1 | grep -Ev 'DB_PASSWORD|SECRET|TOKEN|password=|Authorization:|Bearer ' | head -35 || true
done
echo "=== ORIGIN RESPONSE TIME (3x per page) ==="
for domain in vesta-cosmetics.ir cutellashop.ir; do
  for path in / /shop/ /wp-login.php; do
    for i in 1 2 3; do
      curl -kLsS --max-time 18 --resolve "$domain:443:127.0.0.1" -o /dev/null \
        -w "$domain $path run=$i status=%{http_code} ttfb=%{time_starttransfer}s total=%{time_total}s size=%{size_download}\n" "https://$domain$path" || true
    done
  done
done
echo "=== STATIC FILES AND IMAGE AUDIT ==="
for domain in vesta-cosmetics.ir cutellashop.ir; do
  echo "--- $domain ---"
  f="$(mktemp)"
  curl -kLsS --max-time 25 --resolve "$domain:443:127.0.0.1" "https://$domain/" > "$f" || true
  DOMAIN="$domain" HTML_FILE="$f" python3 - <<'PY'
import os,re,subprocess,urllib.parse,html
from html.parser import HTMLParser
d=os.environ["DOMAIN"]; content=open(os.environ["HTML_FILE"],errors="replace").read()
class Assets(HTMLParser):
 def __init__(self):
  super().__init__(); self.urls=[]; self.images=0
 def handle_starttag(self,tag,attrs):
  a=dict(attrs)
  if tag=="img":
   self.images+=1
   for k in ("src","data-src","data-lazy-src"):
    if a.get(k): self.urls.append(a[k]); break
  elif tag=="link" and a.get("rel","").find("stylesheet")>=0 and a.get("href"):
   self.urls.append(a["href"])
  elif tag=="script" and a.get("src"):
   self.urls.append(a["src"])
p=Assets();p.feed(content)
urls=[]; seen=set()
for v in p.urls:
 v=html.unescape(v)
 if not v or v.startswith(("data:","blob:")):continue
 v=urllib.parse.urljoin("https://"+d+"/",v)
 if v not in seen:urls.append(v);seen.add(v)
print("html_bytes=%d img_elements=%d distinct_asset_urls=%d"%(len(content.encode()),p.images,len(urls)))
print("legacy_asset_hosts="+",".join(sorted(set(urllib.parse.urlsplit(x).hostname or "" for x in urls if urllib.parse.urlsplit(x).hostname not in (d,"www."+d))))[:500])
fails=[]
for u in urls[:35]:
 cmd=["curl","-kLsS","--max-time","8","--range","0-0","-o","/dev/null","-w","%{http_code} %{time_total} %{size_download}"]
 if urllib.parse.urlsplit(u).hostname in (d,"www."+d):
  cmd+=["--resolve",urllib.parse.urlsplit(u).hostname+":443:127.0.0.1"]
 try:
  a=subprocess.run(cmd+[u],capture_output=True,text=True,timeout=10)
  t=a.stdout.strip().split()
  code=int(t[0]) if t and t[0].isdigit() else 0
  if code not in (200,206,301,302): fails.append((code,u))
 except Exception: fails.append((0,u))
print("assets_tested=%d failing=%d"%(min(35,len(urls)),len(fails)))
for code,u in fails[:20]:print("BROKEN_ASSET",code,u[:250])
PY
  rm -f "$f"
  echo "Cache headers:"
  curl -kLsSI --max-time 12 --resolve "$domain:443:127.0.0.1" "https://$domain/" | grep -Ei '^(HTTP/|cache-control:|expires:|content-encoding:|vary:|server:)' | head -12 || true
done
echo "=== PRODUCTION_BASELINE_DONE ==="


echo "=== DEEP DIVE CACHE ==="
for site in cutella vesta; do
  echo "--- $site WordPress caching ---"
  docker exec "vc-$site" php -r '
    require "/var/www/html/wp-load.php";
    echo "WP_CACHE=".(defined("WP_CACHE")?(WP_CACHE?"true":"false"):"not-defined").PHP_EOL;
    echo "advanced_cache=".(is_file(WP_CONTENT_DIR."/advanced-cache.php")?"present":"missing").PHP_EOL;
    echo "object_cache_dropin=".(is_file(WP_CONTENT_DIR."/object-cache.php")?"present":"missing").PHP_EOL;
    echo "wp_rocket_plugin=".(is_dir(WP_PLUGIN_DIR."/wp-rocket")?"present":"missing").PHP_EOL;
    $r=get_option("wp_rocket_settings",[]);
    foreach(["cache_mobile","do_caching_mobile_files","lazyload","lazyload_iframes","minify_css","minify_js","defer_all_js","remove_unused_css","delay_js"] as $key) {
      echo "rocket_".$key."=".(isset($r[$key])?json_encode($r[$key]):"unset").PHP_EOL;
    }
    global $wpdb;
    if ($wpdb instanceof wpdb) {
      foreach (["actionscheduler_actions","woocommerce_sessions"] as $t) {
        $n=$wpdb->get_var($wpdb->prepare("SHOW TABLES LIKE %s",$wpdb->prefix.$t));
        if ($n) {
          $cnt=$wpdb->get_var("SELECT COUNT(*) FROM ".$wpdb->prefix.$t);
          echo $t."_rows=".$cnt.PHP_EOL;
        }
      }
    }
  ' 2>&1 | grep -Ev 'DB_PASSWORD|SECRET|TOKEN|password=|Authorization:|Bearer ' | head -35 || true
  c="/srv/vestacutella/runtime/$site/wp-content/cache/wp-rocket"
  if [[ -d "$c" ]]; then
    echo "wp_rocket_files=$(find "$c" -type f 2>/dev/null | wc -l)"
    du -sh "$c" 2>/dev/null || true
    find "$c" -maxdepth 3 -type f -printf '%p %s bytes\n' 2>/dev/null | head -8 || true
  else
    echo "wp_rocket_disk_cache=missing"
  fi
done
echo "=== CHECK ALL HOME PAGE IMAGE FILES ==="
for site in vesta cutella; do
  [[ "$site" == vesta ]] && domain=vesta-cosmetics.ir || domain=cutellashop.ir
  file="$(mktemp)"
  curl -kLsS --max-time 20 --resolve "$domain:443:127.0.0.1" "https://$domain/" > "$file" || true
  DOMAIN="$domain" SITE="$site" HTML_FILE="$file" python3 - <<'PY'
import os,urllib.parse,html
from html.parser import HTMLParser
domain=os.environ["DOMAIN"];site=os.environ["SITE"]
class Reader(HTMLParser):
 def __init__(self):super().__init__();self.images=[]
 def handle_starttag(self,tag,attrs):
  if tag=="img":
   d=dict(attrs)
   for k in ("src","data-src","data-lazy-src"):
    if d.get(k):
     self.images.append(d[k]);break
p=Reader();p.feed(open(os.environ["HTML_FILE"],errors="replace").read())
missing=[];present=0;remote=0;seen=set()
for u in p.images:
 u=html.unescape(u);u=urllib.parse.urljoin("https://"+domain+"/",u)
 parsed=urllib.parse.urlsplit(u)
 if parsed.hostname not in (domain,"www."+domain):remote+=1;continue
 path=urllib.parse.unquote(parsed.path)
 if not path.startswith("/wp-content/uploads/"):continue
 local="/srv/vestacutella/runtime/"+site+path
 if local in seen:continue
 seen.add(local)
 if os.path.isfile(local):present+=1
 else:missing.append(u)
print("front_page_images=%s unique_uploads=%s disk_present=%s disk_missing=%s remote_images=%s"%(len(p.images),len(seen),present,len(missing),remote))
for x in missing[:30]:print("MISSING_IMAGE",x[:250])
PY
  rm -f "$file"
done
echo "=== CACHE_DEEP_DIVE_DONE ==="


echo "=== LIVE NGINX INVENTORY BEFORE ANY DEPLOY ==="
for file in /srv/vestacutella/repo/infra/nginx.conf /srv/vestacutella/repo/infra/docker-compose.yml; do
 if [[ -r "$file" ]]; then sha256sum "$file"; wc -l "$file"; else echo "MISSING $file"; fi
done
docker exec vc-nginx sha256sum /etc/nginx/nginx.conf || true
grep -En '^[[:space:]]*(upstream|server_name|location|proxy_pass|include|listen)' /srv/vestacutella/repo/infra/nginx.conf | head -120 || true
echo "=== APACHE WORKERS ==="
docker exec vc-cutella sh -c 'ps aux 2>/dev/null | grep -E "apache2|httpd" | grep -v grep | wc -l' || true
docker exec vc-vesta sh -c 'ps aux 2>/dev/null | grep -E "apache2|httpd" | grep -v grep | wc -l' || true
echo "=== LIVE_NGINX_INVENTORY_DONE ==="


echo "=== GIT / LIVE NGINX DIFFERENCE ==="
tmpconfig="$(mktemp)"
if curl -fsSL --max-time 12 https://raw.githubusercontent.com/hsdarestani/vestacutella/main/infra/nginx.conf -o "$tmpconfig"; then
  diff -u "$tmpconfig" /srv/vestacutella/repo/infra/nginx.conf | head -140 || true
else
  echo "Cannot read upstream nginx config"
fi
rm -f "$tmpconfig"
echo "=== CUTELLA HOME DISK CACHE ==="
for site in cutella vesta; do
 [[ "$site" == cutella ]] && d=cutellashop.ir || d=vesta-cosmetics.ir
 p="/srv/vestacutella/runtime/$site/wp-content/cache/wp-rocket/$d"
 echo "-- $site disk cache at $p"
 if [[ -d "$p" ]]; then
  find "$p" -maxdepth 1 -type f -printf "%f %s bytes %TY-%Tm-%Td %TH:%TM\n" | head -10
  find "$p" -maxdepth 1 -type d -printf 'dir %f\n' | head -15
 else echo "cache-host-directory missing";fi
done
echo "=== IMAGE LOAD ATTRIBUTES ==="
for d in vesta-cosmetics.ir cutellashop.ir;do
 f="$(mktemp)"
 curl -kLsS --max-time 20 --resolve "$d:443:127.0.0.1" "https://$d/" > "$f" || true
 F="$f" D="$d" python3 - <<'PY'
import os
from html.parser import HTMLParser
class P(HTMLParser):
 def __init__(self):super().__init__();self.total=0;self.lazy=0;self.eager=0;self.width=0;self.empty=0
 def handle_starttag(self,tag,attrs):
  if tag!="img":return
  x=dict(attrs);self.total+=1
  if x.get("loading")=="lazy":self.lazy+=1
  if x.get("loading")=="eager":self.eager+=1
  if x.get("width") and x.get("height"):self.width+=1
  if not x.get("src") and not x.get("data-src"):self.empty+=1
p=P();p.feed(open(os.environ["F"],errors="replace").read())
print(os.environ["D"],"total",p.total,"lazy",p.lazy,"eager",p.eager,"dimensioned",p.width,"without-src",p.empty)
PY
 rm -f "$f"
done
echo "=== CACHE_AND_ASSETS_DEEP_DONE ==="


echo "=== CACHE BYPASS DIAGNOSTICS ==="
for site in cutella vesta; do
 [[ "$site" == cutella ]] && d=cutellashop.ir || d=vesta-cosmetics.ir
 echo "--- $site ---"
 for path in / /shop/; do
   header="$(mktemp)"
   curl -ksSL --max-time 25 --resolve "$d:443:127.0.0.1" -D "$header" -o /dev/null "https://$d$path" || true
   echo "path=$path"
   grep -Ei '^(HTTP/|Cache-Control:|Age:|x-rocket:|x-cache:|vary:|expires:)' "$header" | head -12 || true
   echo "cookie_names=$(grep -i '^set-cookie:' "$header" | sed -E 's/^[^:]+:[[:space:]]*([^=;]+)=.*/\1/i' | tr '\n' ',' | cut -c1-300)"
   rm -f "$header"
 done
 echo "Cached shop files:"
 find "/srv/vestacutella/runtime/$site/wp-content/cache/wp-rocket/$d/shop" -maxdepth 1 -type f -printf '%f %s bytes\n' 2>/dev/null | head -5 || true
 docker exec "vc-$site" php -r '
   require "/var/www/html/wp-load.php";
   global $wpdb;
   $t=$wpdb->prefix."actionscheduler_actions";
   $found=$wpdb->get_var($wpdb->prepare("SHOW TABLES LIKE %s",$t));
   if($found){
     $rows=$wpdb->get_results("SELECT status,COUNT(*) n FROM ".$t." GROUP BY status",ARRAY_A);
     foreach($rows as $r)echo "scheduler_".$r["status"]."=".$r["n"].PHP_EOL;
     $old=$wpdb->get_var("SELECT COUNT(*) FROM ".$t." WHERE status IN (\"complete\",\"failed\",\"canceled\") AND scheduled_date_gmt < DATE_SUB(UTC_TIMESTAMP(), INTERVAL 60 DAY)");
     echo "old_terminal_jobs_60d=".$old.PHP_EOL;
   }
 ' 2>&1 | head -20 || true
done
echo "=== CACHE_BYPASS_DIAGNOSTICS_DONE ==="


echo "=== WHY CUTELLA IS NOT PAGE-CACHED ==="
docker exec vc-cutella php -r '
 require "/var/www/html/wp-load.php";
 echo "show_on_front=".get_option("show_on_front")." page_on_front=".get_option("page_on_front")." woocommerce_shop_page_id=".get_option("woocommerce_shop_page_id").PHP_EOL;
 $r=get_option("wp_rocket_settings",[]);
 foreach ($r as $k=>$v) {
  if(preg_match("/cache_reject|cache.*query|cache.*cookie|cache_ssl|cache_mobile|cache_logged|cache_purge|never_cache|preload/i",$k)){
   echo $k."=".substr(is_scalar($v)?strval($v):json_encode($v),0,1000).PHP_EOL;
  }
 }
 if(function_exists("get_rocket_option")){
  foreach(["cache_reject_uri","cache_reject_cookies","cache_reject_ua"] as $k){
   echo "get_rocket_option_".$k."=".substr(json_encode(get_rocket_option($k)),0,1000).PHP_EOL;
  }
 }
' 2>&1 | head -65 || true
echo "=== DONT_CACHE_FLAGS_IN_ACTIVE_PLUGINS ==="
for site in cutella vesta; do
 f="/srv/vestacutella/runtime/$site/wp-content"
 echo "--- $site ---"
 grep -RslE 'DONOTCACHEPAGE|rocket_cache_reject_uri|rocket_override_donotcachepage' "$f/mu-plugins" 2>/dev/null | head -15 || true
done
echo "=== CACHE_EXCLUSIONS_DONE ==="


echo "=== STAGED NGINX SAFE-PREFLIGHT (NO RELOAD) ==="
test_nginx="$(mktemp)"
if curl -fsSL --max-time 15 "https://raw.githubusercontent.com/hsdarestani/vestacutella/perf-cache-cutella-safe-20261014/infra/nginx.conf" -o "$test_nginx"; then
  docker cp "$test_nginx" vc-nginx:/tmp/vc-staged-nginx.conf
  if docker exec vc-nginx nginx -t -c /tmp/vc-staged-nginx.conf; then
    echo "STAGED_NGINX_TEST_OK"
  else
    echo "STAGED_NGINX_TEST_FAILED"
  fi
else
  echo "STAGED_NGINX_DOWNLOAD_FAILED"
fi
rm -f "$test_nginx"


echo "=== NGINX CACHE RELOAD FAILURE ROOT CAUSE ==="
docker exec vc-nginx sh -c 'ls -ld /var/cache /var/cache/nginx /var/cache/nginx/vc-guest-pages 2>&1 || true'
docker logs --since 35m vc-nginx 2>&1 | grep -Ei 'emerg|error|cache|mkdir|permission|signal|reload' | tail -65 || true
echo "live_conf_sha=$(sha256sum /srv/vestacutella/repo/infra/nginx.conf | cut -d' ' -f1)"
docker exec vc-nginx nginx -t || true
echo "=== ROOT_CAUSE_DIAGNOSTIC_END ==="


echo "=== REAL NETWORK PATH DIAG ==="
for d in cutellashop.ir vesta-cosmetics.ir app.vesta-cosmetics.ir; do
 echo "--- $d default ---"
 curl -kLsS --max-time 20 --resolve "$d:443:127.0.0.1" -o /dev/null -w 'remote=%{remote_ip} code=%{http_code} ttfb=%{time_starttransfer}\n' "https://$d/" || true
 echo "--- $d direct no-proxy ---"
 curl -kLsS --max-time 20 --noproxy '*' --resolve "$d:443:127.0.0.1" -o /dev/null -w 'remote=%{remote_ip} code=%{http_code} ttfb=%{time_starttransfer}\n' "https://$d/" || true
done
echo "proxy_env_set=$(env | grep -Eic '^(https?|all)_proxy=' || true)"
echo "=== PORT AND NGINX PROCESS ==="
ss -lntp 2>/dev/null | grep -E '(:80 |:443 )' | head -15 || true
docker exec vc-nginx ps -ef 2>/dev/null | grep nginx | head -20 || true
docker ps --format 'table {{.Names}}\t{{.Ports}}' | grep -E '^NAMES|^vc-nginx' || true
echo "=== PATH_DIAG_DONE ==="


echo "=== BIND MOUNT INODE CHECK ==="
stat -c 'host-file inode=%i size=%s device=%d' /srv/vestacutella/repo/infra/nginx.conf || true
docker exec vc-nginx stat -c 'container-file inode=%i size=%s device=%d' /etc/nginx/nginx.conf || true
sha256sum /srv/vestacutella/repo/infra/nginx.conf || true
docker exec vc-nginx sha256sum /etc/nginx/nginx.conf || true
echo "=== MOUNT CHECK END ==="


echo "=== POST DEPLOY TTFB AND MEDIA SIZES ==="
for site in cutella vesta; do
 [[ "$site" == cutella ]] && d=cutellashop.ir || d=vesta-cosmetics.ir
 echo "--- $site post deploy ---"
 for i in 1 2 3;do
   curl --noproxy '*' -kLsS --max-time 20 --resolve "$d:443:127.0.0.1" -o /dev/null \
     -w "run=$i ttfb=%{time_starttransfer} total=%{time_total} code=%{http_code}\n" "https://$d/" || true
 done
 f="$(mktemp)"
 curl --noproxy '*' -kLsS --max-time 20 --resolve "$d:443:127.0.0.1" "https://$d/" > "$f"
 D="$d" SITE="$site" F="$f" python3 - <<'PY'
import os,html,collections,statistics,urllib.parse
from html.parser import HTMLParser
d=os.environ["D"];site=os.environ["SITE"]
class P(HTMLParser):
 def __init__(self):super().__init__();self.urls=[]
 def handle_starttag(self,tag,attrs):
  if tag!="img":return
  x=dict(attrs)
  for k in ("src","data-src","data-lazy-src"):
   if x.get(k):self.urls.append(x[k]);break
p=P();p.feed(open(os.environ["F"],errors="replace").read())
files={};ext=collections.Counter();total=0
for u in p.urls:
 z=urllib.parse.urlsplit(urllib.parse.urljoin("https://"+d+"/",html.unescape(u)))
 if z.hostname not in (d,"www."+d) or not z.path.startswith("/wp-content/uploads/"):continue
 loc="/srv/vestacutella/runtime/"+site+urllib.parse.unquote(z.path)
 if os.path.isfile(loc):files[loc]=os.path.getsize(loc)
for loc,sz in files.items():
 ext[os.path.splitext(loc)[-1].lower()]+=1;total+=sz
size=sorted(files.values())
p95=size[int(len(size)*.95)] if size else 0
print("unique_images=%d total_bytes=%d p95_kb=%d over_300KB=%d over_1MB=%d"%(len(files),total,p95//1024,sum(x>300*1024 for x in size),sum(x>1024*1024 for x in size)))
print("image_formats="+str(dict(ext)))
for loc,sz in sorted(files.items(),key=lambda x:-x[1])[:10]:
 print("large_image_kb=%d file=%s"%(sz//1024,os.path.basename(loc)[:150]))
PY
 rm -f "$f"
done
echo "=== POST_DEPLOY_MEDIA_AND_TTFB_DONE ==="


echo "=== VESTA HEAVY IMAGE ATTRIBUTES AND TOOLS ==="
command -v jpegoptim || true
command -v optipng || true
command -v cwebp || true
command -v convert || true
python3 -c 'import PIL;print("pillow_available=yes")' 2>/dev/null || echo "pillow_available=no"
docker exec vc-vesta php -r 'if(extension_loaded("gd")) {echo "php_gd_webp=".(function_exists("imagewebp")?"yes":"no").PHP_EOL;}else{echo "php_gd=no".PHP_EOL;}' || true
f="$(mktemp)"
curl --noproxy '*' -kLsS --max-time 20 --resolve vesta-cosmetics.ir:443:127.0.0.1 https://vesta-cosmetics.ir/ > "$f"
F="$f" python3 - <<'PY'
import os,urllib.parse,html
from html.parser import HTMLParser
class P(HTMLParser):
 def __init__(self):super().__init__();self.ims=[]
 def handle_starttag(self,tag,attrs):
  if tag=="img":self.ims.append(dict(attrs))
p=P();p.feed(open(os.environ["F"],errors="replace").read())
print("image_count",len(p.ims),"srcset_count",sum(bool(z.get("srcset") or z.get("data-srcset")) for z in p.ims))
items=[]
for z in p.ims:
 v=z.get("src") or z.get("data-src") or ""
 u=urllib.parse.urlsplit(urllib.parse.urljoin("https://vesta-cosmetics.ir/",html.unescape(v)))
 if u.hostname not in ("vesta-cosmetics.ir","www.vesta-cosmetics.ir") or not u.path.startswith("/wp-content/uploads/"):continue
 path="/srv/vestacutella/runtime/vesta"+urllib.parse.unquote(u.path)
 if os.path.isfile(path):
  items.append((os.path.getsize(path),os.path.basename(path),z))
for size,name,z in sorted(items,key=lambda x:-x[0])[:18]:
 print("KB",size//1024,"file",name[:100],"display",z.get("width"),"x",z.get("height"),"loading",z.get("loading"),"srcset",bool(z.get("srcset") or z.get("data-srcset")),"priority",z.get("fetchpriority"))
PY
rm -f "$f"
echo "=== HEAVY_IMAGE_DIAG_DONE ==="
