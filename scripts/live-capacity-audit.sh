#!/usr/bin/env bash
set -euo pipefail
echo "=== CDN AND SERVER ==="
free -h
df -h /
for d in vesta-cosmetics.ir cutellashop.ir app.vesta-cosmetics.ir; do
  echo "--- $d ORIGIN ---"
  curl -kLsS --noproxy '*' --resolve "$d:443:127.0.0.1" --max-time 25 -o /dev/null -w 'origin http=%{http_code} ttfb=%{time_starttransfer}\n' "https://$d/"
  echo "--- $d PUBLIC ---"
  curl -kLsS --noproxy '*' --max-time 25 -o /dev/null -w 'public http=%{http_code} remote=%{remote_ip} ttfb=%{time_starttransfer}\n' "https://$d/" || true
  curl -kLsSI --noproxy '*' --max-time 18 "https://$d/" | grep -Ei '^(HTTP/|server:|cf-cache-status:|cache-control:)' | head -10 || true
done
echo "=== IMAGE ELEMENT REFERENCES ==="
f="$(mktemp)"
curl -kLsS --noproxy '*' --resolve vesta-cosmetics.ir:443:127.0.0.1 --max-time 25 "https://vesta-cosmetics.ir/" > "$f"
F="$f" python3 - <<'PY'
from html.parser import HTMLParser
import html,os
class P(HTMLParser):
 def __init__(self): super().__init__();self.items=[]
 def handle_starttag(self,tag,attrs):
  if tag=='img':self.items.append(dict(attrs))
p=P();p.feed(open(os.environ['F'],errors='replace').read())
selected=['ED83410A-44E6-40D9-98B3-9E3EFC5A9026.png','IMG_2078.png','3497C2E4-9664-4275-BFDE-91A6EB754951.png','A41F349F-B523-4FEA-8943-A1EAB187E4C5.png']
for a in p.items:
 for k in ['src','data-src','data-lazy-src']:
  value=html.unescape(a.get(k,''))
  if any(n in value for n in selected):
   print('TARGET_TAG',k,repr(value[:240]),'loading',a.get('loading'),'priority',a.get('fetchpriority'),'size',a.get('width'),a.get('height'));break
for root,dirs,files in os.walk('/srv/vestacutella/runtime/vesta/wp-content/uploads'):
 for n in files:
  if n in selected:
   path=os.path.join(root,n)
   print('TARGET_FILE',path,os.path.getsize(path))
PY
rm -f "$f"
echo "=== SAFE WEBP ENCODING TRIAL (TEMP ONLY) ==="
docker exec -i vc-vesta php <<'PHP'
<?php
$want=['ED83410A-44E6-40D9-98B3-9E3EFC5A9026.png','IMG_2078.png','3497C2E4-9664-4275-BFDE-91A6EB754951.png','A41F349F-B523-4FEA-8943-A1EAB187E4C5.png'];
$iter=new RecursiveIteratorIterator(new RecursiveDirectoryIterator('/var/www/html/wp-content/uploads',FilesystemIterator::SKIP_DOTS));
foreach($iter as $file){
 if(!in_array($file->getBasename(),$want,true))continue;
 $path=$file->getPathname();$im=@imagecreatefrompng($path);if(!$im)continue;
 $tmp=tempnam(sys_get_temp_dir(),'vcw');
 if(imagewebp($im,$tmp,86)){
  $test=@imagecreatefromwebp($tmp);
  echo "WEBP_TEST ".$file->getBasename()." original_kb=".round(filesize($path)/1024).
       " webp_kb=".round(filesize($tmp)/1024).
       " dimensions_same=".($test && imagesx($test)==imagesx($im)&&imagesy($test)==imagesy($im)?'yes':'no')."\n";
  if($test)imagedestroy($test);
 }
 @unlink($tmp);imagedestroy($im);
}
PHP
echo "=== AUDIT_COMPLETE ==="
