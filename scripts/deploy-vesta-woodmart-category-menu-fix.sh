#!/usr/bin/env bash
set -euo pipefail
ROOT=/srv/vestacutella
SOURCE=/tmp/fix-vesta-woodmart-categories-menu.php
test -s "$SOURCE"
set -a; source "$ROOT/.env"; set +a
docker cp "$SOURCE" vc-vesta:/tmp/fix-vesta-woodmart-categories-menu.php
docker exec vc-vesta php -d memory_limit=512M -r 'include "/tmp/fix-vesta-woodmart-categories-menu.php";' -- dry-run
for path in / /shop/; do
  status="$(curl -kLsS --max-time 45 --noproxy '*' --resolve vesta-cosmetics.ir:443:127.0.0.1 -o /dev/null -w '%{http_code}' "https://vesta-cosmetics.ir$path")"
  echo "BEFORE_PAGE $path status=$status"
  [[ "$status" == 200 ]]
done
umask 077
backup="/srv/backups/vesta-woodmart-menu-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -m 0700 "$backup"
docker exec vc-db-vesta mariadb-dump -uroot -p"$VESTA_DB_ROOT_PASSWORD" --single-transaction --quick vestacos_m | gzip -1 > "$backup/vesta-before-menu.sql.gz"
test -s "$backup/vesta-before-menu.sql.gz"
echo "CATEGORIES_MENU_BACKUP_SAVED $backup"
docker exec vc-vesta php -d memory_limit=512M -r 'include "/tmp/fix-vesta-woodmart-categories-menu.php";' -- apply
for path in / /shop/ /my-account/; do
  status="$(curl -kLsS --max-time 55 --noproxy '*' --resolve vesta-cosmetics.ir:443:127.0.0.1 -o /dev/null -w '%{http_code}' "https://vesta-cosmetics.ir$path")"
  echo "AFTER_PAGE $path status=$status"
  [[ "$status" == 200 ]]
done
for prefix in "https://vesta-cosmetics.ir" ; do
  filename="$(mktemp)"
  curl -kLsS --max-time 60 --noproxy '*' --resolve vesta-cosmetics.ir:443:127.0.0.1 "$prefix/?woodmart-nav-check=$(date +%s)" -o "$filename"
  python3 - "$filename" <<'PY'
import re,sys,html
from pathlib import Path
data=html.unescape(Path(sys.argv[1]).read_text(errors="replace"))
for t in ("اکسسوری","پوشاک پینترستی","کالاهای فانتزی و دکوری"):
    print("PUBLIC_CATEGORIES_TEXT",t,"count",data.count(t))
    if t not in data:
        raise SystemExit("Missing text from live homepage: "+t)
# Locate the actual category nav, not product names or linked blog content.
m=re.search(r'<ul[^>]*class="[^"]*mobile-categories-menu[^"]*"[^>]*>',data,re.I)
if not m: raise SystemExit("Cannot locate Woodmart mobile category menu")
part=data[m.start():m.start()+280000]
found={}
for termid,name in ((1731,"پوشاک پینترستی"),(1767,"کالاهای فانتزی و دکوری")):
    rx=r'<li[^>]+id="menu-item-(\d+)"[^>]+item-level-0[^>]*>.*?'+re.escape(name)
    match=re.search(rx,part,re.S)
    found[termid]=bool(match)
    print("CATEGORY_IN_MOBILE_NAV",termid,"yes" if match else "no")
if not all(found.values()):raise SystemExit("Category not visible in Woodmart mobile categories navigation")
print("WOODMART_PUBLIC_NAV_VERIFIED_OK")
PY
  rm -f "$filename"
done
echo "WOODMART_MENU_REPAIR_SUCCESS"
