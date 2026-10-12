#!/usr/bin/env bash
set -euo pipefail

BASE=/srv/vestacutella
REPO="$BASE/repo"
RUNTIME="$BASE/runtime/vesta"
ENVFILE="$BASE/.env"
BACKUP="/srv/backups/vesta-php74-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$BACKUP"

set -a
source "$ENVFILE"
set +a

cp "$REPO/infra/docker-compose.yml" "$BACKUP/docker-compose.yml.before"

CURRENT_IMAGE="$(docker inspect vc-vesta --format '{{.Config.Image}}')"
echo "current_image=$CURRENT_IMAGE"
docker tag "$(docker inspect vc-vesta --format '{{.Image}}')" "vestacutella-wordpress:vesta-rollback" || true

rollback() {
  echo "=== ROLLBACK VESTA RUNTIME ==="
  [[ -d "$RUNTIME/wp-content/plugins/smsir" && ! -d "$RUNTIME/wp-content/plugins/smsir.disabled-for-migration" ]] && mv "$RUNTIME/wp-content/plugins/smsir" "$RUNTIME/wp-content/plugins/smsir.disabled-for-migration" || true
  [[ -d "$RUNTIME/wp-content/plugins/xcart" && ! -d "$RUNTIME/wp-content/plugins/xcart.disabled-for-migration" ]] && mv "$RUNTIME/wp-content/plugins/xcart" "$RUNTIME/wp-content/plugins/xcart.disabled-for-migration" || true

  cp "$BACKUP/docker-compose.yml.before" "$REPO/infra/docker-compose.yml"
  cd "$REPO/infra"
  docker compose --env-file "$ENVFILE" up -d --no-deps --force-recreate vesta || true
  sleep 6
}
trap 'rc=$?; if [[ $rc -ne 0 ]]; then rollback; fi; exit $rc' EXIT

echo "=== install new compose/Dockerfile files ==="
install -m 644 /tmp/docker-compose.yml "$REPO/infra/docker-compose.yml"
mkdir -p "$REPO/infra/wordpress74"
install -m 644 /tmp/Dockerfile74 "$REPO/infra/wordpress74/Dockerfile"
install -m 644 /tmp/zz-performance74.ini "$REPO/infra/wordpress74/zz-performance.ini"

echo "=== build PHP 7.4 Vesta image ==="
cd "$REPO/infra"
docker compose --env-file "$ENVFILE" build vesta

echo "=== restore old Vesta plugin directories ==="
[[ -d "$RUNTIME/wp-content/plugins/smsir.disabled-for-migration" && ! -e "$RUNTIME/wp-content/plugins/smsir" ]] && mv "$RUNTIME/wp-content/plugins/smsir.disabled-for-migration" "$RUNTIME/wp-content/plugins/smsir"
[[ -d "$RUNTIME/wp-content/plugins/xcart.disabled-for-migration" && ! -e "$RUNTIME/wp-content/plugins/xcart" ]] && mv "$RUNTIME/wp-content/plugins/xcart.disabled-for-migration" "$RUNTIME/wp-content/plugins/xcart"

echo "=== recreate only Vesta on PHP 7.4 ==="
docker compose --env-file "$ENVFILE" up -d --no-deps --force-recreate vesta
sleep 10

echo "=== PHP/runtime verification ==="
docker exec vc-vesta php -v | head -3
docker exec vc-vesta php -m | grep -i ionCube

echo "=== active plugin verification ==="
docker exec vc-vesta php -r '
require "/var/www/html/wp-load.php";
require_once ABSPATH."wp-admin/includes/plugin.php";
foreach (["smsir/index.php","xcart/xcart.php"] as $p) {
 echo $p."=".(is_plugin_active($p)?"active":"inactive").PHP_EOL;
 if (!is_plugin_active($p)) exit(5);
}
'

echo "=== smoke critical pages ==="
for p in / /my-account/ /checkout/ /wp-admin/; do
  code="$(curl -ksS --max-time 40 -o /tmp/vesta-smoke -w '%{http_code}' "https://vesta-cosmetics.ir$p" || true)"
  echo "$p HTTP=$code bytes=$(wc -c </tmp/vesta-smoke 2>/dev/null || echo 0)"
  case "$p:$code" in
    /:200|/my-account/:200|/checkout/:200|/checkout/:302|/wp-admin/:200|/wp-admin/:302) ;;
    *) exit 31 ;;
  esac
done

echo "=== old login behavior verification ==="
curl -ksS --max-time 40 https://vesta-cosmetics.ir/my-account/ -o /tmp/vesta-account.html
grep -q 'smsir-login-app' /tmp/vesta-account.html
grep -q '/wp-content/plugins/smsir/' /tmp/vesta-account.html
grep -q '/wp-content/plugins/xcart/' /tmp/vesta-account.html
echo "smsir_login_ui=present"
echo "xcart_assets=present"

echo "=== recent fatal check ==="
if docker logs --since 3m vc-vesta 2>&1 | grep -Eqi 'PHP Fatal error|Uncaught Error|ionCube.*unauthor'; then
  docker logs --since 3m vc-vesta 2>&1 | grep -Ei 'PHP Fatal error|Uncaught Error|ionCube.*unauthor' | tail -80
  exit 32
fi

echo "=== clear page cache and warm account ==="
docker exec vc-vesta php -r '
require "/var/www/html/wp-load.php";
if (function_exists("rocket_clean_domain")) rocket_clean_domain();
'
curl -ksS --max-time 40 -o /dev/null https://vesta-cosmetics.ir/
curl -ksS --max-time 40 -o /dev/null https://vesta-cosmetics.ir/my-account/

trap - EXIT
echo "VESTA_PHP74_PARITY_OK"
