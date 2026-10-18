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
# umask 077 protects backups but image directories must be traversable by Nginx.
find "$BASE/runtime/vesta/wp-content/uploads/cutella-import" -type d -exec chmod 0755 {} +
find "$BASE/runtime/vesta/wp-content/uploads/cutella-import" -type f -exec chmod 0644 {} +
chown -R 33:33 "$BASE/runtime/vesta/wp-content/uploads/cutella-import"
# All imported items stay in draft status until verify completes.
docker exec vc-vesta php -d memory_limit=768M -r 'include "/tmp/vc-cutella-catalog-bridge.php";' -- import /tmp/vc-cutella-catalog.json
docker exec vc-vesta php -d memory_limit=768M -r 'include "/tmp/vc-cutella-catalog-bridge.php";' -- verify /tmp/vc-cutella-catalog.json
for path in / /shop/ /my-account/; do
  code="$(curl -kLsS --noproxy '*' --resolve vesta-cosmetics.ir:443:127.0.0.1 --max-time 40 -o /dev/null -w '%{http_code}' "https://vesta-cosmetics.ir$path")"
  echo "VESTA_STAGED $path $code"
  [[ "$code" == 200 ]]
done
# Only a successful staging + verification can reach public publication.
NEEDS_PUBLIC_ROLLBACK=yes
undo_publication() {
  code=$?
  trap - EXIT
  if [[ "$NEEDS_PUBLIC_ROLLBACK" == yes && "$code" != 0 ]]; then
    echo "ROLLBACK_PUBLICATION begin code=$code"
    docker exec vc-vesta php -d memory_limit=768M -r 'include "/tmp/vc-cutella-catalog-bridge.php";' -- rollback /tmp/vc-cutella-catalog.json || true
  fi
  exit "$code"
}
trap undo_publication EXIT
docker exec vc-vesta php -d memory_limit=768M -r 'include "/tmp/vc-cutella-catalog-bridge.php";' -- finalize /tmp/vc-cutella-catalog.json
docker exec vc-vesta php -d memory_limit=768M -r 'include "/tmp/vc-cutella-catalog-bridge.php";' -- verify /tmp/vc-cutella-catalog.json
for path in / /shop/ /my-account/; do
  code="$(curl -kLsS --noproxy '*' --resolve vesta-cosmetics.ir:443:127.0.0.1 --max-time 40 -o /dev/null -w '%{http_code}' "https://vesta-cosmetics.ir$path")"
  echo "VESTA_AFTER $path $code"
  [[ "$code" == 200 ]]
done
# Verify real category archive and one newly published product (not just homepage).
category_url="$(docker exec vc-vesta php -r 'require "/var/www/html/wp-load.php"; $term=get_term_by("slug","cutella-products","product_cat"); echo ($term && !is_wp_error($term))?get_term_link($term):"";' | tail -1)"
product_url="$(docker exec vc-vesta php -r 'require "/var/www/html/wp-load.php"; global $wpdb; $id=(int)$wpdb->get_var("SELECT post_id FROM {$wpdb->postmeta} WHERE meta_key=\"_vc_cutella_source_product_id\" LIMIT 1"); echo $id?get_permalink($id):"";' | tail -1)"
for url in "$category_url" "$product_url"; do
  [[ "$url" == https://vesta-cosmetics.ir/* || "$url" == http://vesta-cosmetics.ir/* ]] || { echo "Invalid catalog URL: $url";exit 18; }
  code="$(curl -kLsS --max-time 60 -o /dev/null -w '%{http_code}' "$url")"
  echo "VESTA_CATALOG_URL status=$code url=$url"
  [[ "$code" == 200 ]] || exit 19
done
NEEDS_PUBLIC_ROLLBACK=no
trap - EXIT
echo 'CUTELLA_TO_VESTA_IMPORT_SUCCESS'
