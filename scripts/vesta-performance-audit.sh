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
