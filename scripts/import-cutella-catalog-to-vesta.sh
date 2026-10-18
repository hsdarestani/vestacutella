#!/usr/bin/env bash
# One-way WooCommerce transfer: Cutella unchanged; Vesta drafts -> verified -> publish.
set -euo pipefail
MODE="${1:---dry-run}"
case "$MODE" in --dry-run|--apply) ;; *) echo "Invalid mode" >&2;exit 2;; esac
BASE=/srv/vestacutella
BRIDGE=/tmp/cutella-vesta-catalog-bridge.php
test -s "$BRIDGE"
set -a
source "$BASE/.env"
set +a
umask 077
mkdir -p /srv/backups
RUN_DIR="$(mktemp -d /srv/backups/cutella-vesta-XXXXXXXX)"
echo "CATALOG_RUN_DIR=$RUN_DIR MODE=$MODE"
for name in vc-cutella vc-vesta vc-db-cutella vc-db-vesta; do
  docker ps --filter name="^/$name$" --format '{{.Names}}' | grep -qx "$name"
done
echo "STEP_COPY_SOURCE"; docker cp "$BRIDGE" vc-cutella:/tmp/vc-cutella-catalog-bridge.php
echo "STEP_COPY_DEST"; docker cp "$BRIDGE" vc-vesta:/tmp/vc-cutella-catalog-bridge.php
echo "STEP_PHP_SOURCE_READY"
echo "STEP_PHP_DEST_READY"
echo "STEP_EXPORT_SOURCE"; docker exec vc-cutella php -d memory_limit=768M -r 'include "/tmp/vc-cutella-catalog-bridge.php";' -- export /tmp/vc-cutella-catalog.json
docker cp vc-cutella:/tmp/vc-cutella-catalog.json "$RUN_DIR/catalog.json"
docker cp "$RUN_DIR/catalog.json" vc-vesta:/tmp/vc-cutella-catalog.json
docker exec vc-vesta php -d memory_limit=768M -r 'include "/tmp/vc-cutella-catalog-bridge.php";' -- preflight /tmp/vc-cutella-catalog.json
python3 - "$RUN_DIR/catalog.json" <<'PY'
import json,sys,os
data=json.load(open(sys.argv[1]))
n=len(data['products'])
v=sum(len(p.get('variations',[])) for p in data['products'])
if n<1 or n>5000: raise SystemExit('Unreasonable count')
print(f"CATALOG_VALIDATED products={n} variations={v} categories={len(data['categories'])}")
for a in data['attribute_taxonomies']:
    print("ATTRIBUTE_DEFINITION name="+a['name']+" label="+a['label'])
src=os.path.realpath('/srv/vestacutella/runtime/cutella/wp-content/uploads')
photos={}
for cat in data['categories']:
    if cat.get('image'): photos[cat['image']['id']]=cat['image']['relative']
for p in data['products']:
    for rec in [p]+p.get('variations',[]):
        for im in rec.get('images',[]): photos[im['id']]=im['relative']
missing=[]
for ident,rel in photos.items():
    file=os.path.realpath(os.path.join(src,rel))
    if not file.startswith(src+os.sep) or not os.path.isfile(file):
        missing.append(ident)
print(f"MEDIA_PREFLIGHT referenced={len(photos)} missing={len(missing)}")
if missing: raise SystemExit('Missing source image originals, examples: '+str(missing[:10]))
PY
if [[ "$MODE" == "--dry-run" ]]; then
  echo "CATALOG_DRY_RUN_OK no production changes"
  exit 0
fi
for path in / /shop/ /my-account/; do
  code="$(curl -kLsS --noproxy '*' --resolve vesta-cosmetics.ir:443:127.0.0.1 --max-time 40 -o /dev/null -w '%{http_code}' "https://vesta-cosmetics.ir$path")"
  echo "VESTA_BEFORE $path $code"
  [[ "$code" == 200 ]]
done
docker exec vc-db-vesta mariadb-dump -uroot -p"$VESTA_DB_ROOT_PASSWORD" --single-transaction --quick vestacos_m | gzip -1 > "$RUN_DIR/vesta-before.sql.gz"
test -s "$RUN_DIR/vesta-before.sql.gz"
echo "VESTA_DB_BACKUP_OK"
# Only copy referenced originals, no old Cutella or Vesta image is replaced.
python3 - "$RUN_DIR/catalog.json" <<'PY'
import json,os,sys,shutil
data=json.load(open(sys.argv[1]))
src=os.path.realpath('/srv/vestacutella/runtime/cutella/wp-content/uploads')
dst=os.path.realpath('/srv/vestacutella/runtime/vesta/wp-content/uploads/cutella-import')
allowed={'.jpg','.jpeg','.png','.webp','.gif','.avif'}
images={}
for cat in data['categories']:
    if cat.get('image'): images[cat['image']['id']]=cat['image']['relative']
for p in data['products']:
    for item in [p]+p.get('variations',[]):
        for im in item.get('images',[]): images[im['id']]=im['relative']
count=missing=0
for ident,rel in images.items():
    if not isinstance(rel,str) or rel.startswith('/') or '\\' in rel or '..' in rel.split('/'): raise SystemExit('Unsafe image path')
    if os.path.splitext(rel.lower())[1] not in allowed: raise SystemExit('Unsafe extension')
    origin=os.path.realpath(os.path.join(src,rel))
    target=os.path.realpath(os.path.join(dst,rel))
    if not origin.startswith(src+os.sep) or not target.startswith(dst+os.sep): raise SystemExit('Media path escapes root')
    if not os.path.isfile(origin):
        missing+=1
        print(f"MISSING_IMAGE id={ident}")
        continue
    os.makedirs(os.path.dirname(target),exist_ok=True)
    if not os.path.isfile(target):
        shutil.copy2(origin,target)
        os.chmod(target,0o644)
        count+=1
print(f"MEDIA_COPY_OK copied={count} missing={missing} referenced={len(images)}")
if missing: raise SystemExit('Source image missing; import refused')
PY
chown -R 33:33 "$BASE/runtime/vesta/wp-content/uploads/cutella-import"
# All imported items stay in draft status until verify completes.
docker exec vc-vesta php -d memory_limit=768M -r 'include "/tmp/vc-cutella-catalog-bridge.php";' -- import /tmp/vc-cutella-catalog.json
docker exec vc-vesta php -d memory_limit=768M -r 'include "/tmp/vc-cutella-catalog-bridge.php";' -- verify /tmp/vc-cutella-catalog.json
for path in / /shop/ /my-account/; do
  code="$(curl -kLsS --noproxy '*' --resolve vesta-cosmetics.ir:443:127.0.0.1 --max-time 40 -o /dev/null -w '%{http_code}' "https://vesta-cosmetics.ir$path")"
  echo "VESTA_STAGED $path $code"
  [[ "$code" == 200 ]]
done
docker exec vc-vesta php -d memory_limit=768M -r 'include "/tmp/vc-cutella-catalog-bridge.php";' -- finalize /tmp/vc-cutella-catalog.json
docker exec vc-vesta php -d memory_limit=768M -r 'include "/tmp/vc-cutella-catalog-bridge.php";' -- verify /tmp/vc-cutella-catalog.json
for path in / /shop/ /my-account/; do
  code="$(curl -kLsS --noproxy '*' --resolve vesta-cosmetics.ir:443:127.0.0.1 --max-time 40 -o /dev/null -w '%{http_code}' "https://vesta-cosmetics.ir$path")"
  echo "VESTA_AFTER $path $code"
  [[ "$code" == 200 ]]
done
echo 'CUTELLA_TO_VESTA_IMPORT_SUCCESS'
