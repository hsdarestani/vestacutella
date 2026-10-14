#!/usr/bin/env bash
# Production read-only resource/CDN inventory for Vesta + Cutella.
set -euo pipefail
echo "=== PROXY ==="
for d in vesta-cosmetics.ir cutellashop.ir app.vesta-cosmetics.ir; do
 echo "domain=$d"
 curl --noproxy "*" -ksSI --max-time 18 "https://$d/" | grep -iE "^(HTTP/|server:|cf-ray:|cf-cache-status:|cache-control:)" | head -10 || true
 curl --noproxy "*" -ksSI --max-time 18 --resolve "$d:443:127.0.0.1" "https://$d/" | grep -iE "^(HTTP/|server:|cf-ray:|cf-cache-status:|cache-control:)" | head -10 || true
done
echo "=== CUTELLA HTML RESOURCES ==="
f="$(mktemp)"
curl --noproxy "*" -ksSL --max-time 25 --resolve cutellashop.ir:443:127.0.0.1 https://cutellashop.ir/ > "$f"
F="$f" python3 - <<'PY'
import os
from html.parser import HTMLParser
class P(HTMLParser):
 def __init__(self):super().__init__();self.scripts=[];self.styles=[];self.classes=[]
 def handle_starttag(self,t,a):
  d=dict(a)
  if t=="script" and d.get("src"):self.scripts.append(d["src"])
  if t=="link" and d.get("rel")=="stylesheet":self.styles.append(d.get("href",""))
  if d.get("class"):self.classes.extend(d["class"].split())
p=P();s=open(os.environ["F"],errors="replace").read();p.feed(s)
print("css_count",len(p.styles),"js_count",len(p.scripts))
print("revslider_markup",any(w in s for w in ("rs-module","rev_slider","rev-slide")))
print("dashicons_markers",sum("dashicons" in c for c in p.classes))
print("cutella_banners",sum("cutella-banner" in c for c in p.classes))
for kind,items in (("css",p.styles),("js",p.scripts)):
 for u in items:
  if any(x in u.lower() for x in ("revslider","dashicons","jquery","elementor","cutella-")):print(kind,u[:210])
PY
rm -f "$f"
echo "=== WORDPRESS FRONTEND SETTINGS ==="
for site in cutella vesta;do
 echo "$site"
 docker exec "vc-$site" php -r 'require "/var/www/html/wp-load.php"; echo "theme=".get_stylesheet().PHP_EOL;foreach((array)get_option("active_plugins",[]) as $p)if(preg_match("/rocket|revslider|cutella|redis/i",$p))echo "active=".$p.PHP_EOL; $o=get_option("wp_rocket_settings",[]);foreach(["remove_unused_css","minify_css","delay_js","defer_all_js"] as $k)echo "rocket_".$k."=".json_encode($o[$k]??null).PHP_EOL;' 2>&1 | head -25
done
echo "=== CDN_DEPENDENCIES_AUDIT_OK ==="
