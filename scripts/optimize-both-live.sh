#!/usr/bin/env bash
# Stage one of Redis introduction: start an isolated and memory-limited cache
# service only. Do not alter WordPress, PHP, database, Nginx or live sessions.
set -euo pipefail
BASE=/srv/vestacutella
TARGET="$BASE/repo/infra/docker-compose.yml"
ENVFILE="$BASE/.env"
BACKUP="/srv/backups/redis-bootstrap-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$BACKUP"
test -s "$ENVFILE"
test -s /tmp/docker-compose.yml

code() {
  local domain="$1"
  curl -kLsS --max-time 22 --resolve "$domain:443:127.0.0.1" \
    -o /dev/null -w '%{http_code}' "https://$domain/"
}
for domain in cutellashop.ir vesta-cosmetics.ir app.vesta-cosmetics.ir; do
  status="$(code "$domain")"
  echo "before: $domain status=$status"
  [[ "$status" == 200 ]] || { echo "ABORT: unhealthy baseline"; exit 31; }
done
# Strict validation: existing services must be preserved unchanged.
for c in db-cutella db-vesta vesta cutella nginx; do
  grep -Eq "^  $c:" /tmp/docker-compose.yml || { echo "ABORT: missing existing service $c"; exit 32; }
done
grep -Eq '^  redis:' /tmp/docker-compose.yml
grep -q 'image: redis:7.4-alpine' /tmp/docker-compose.yml
grep -q 'mem_limit: 192m' /tmp/docker-compose.yml
cp -a "$TARGET" "$BACKUP/compose.before.yml"
echo "Backup: $BACKUP"
changed=0
rollback() {
  local ec=$?
  trap - EXIT
  if [[ "$changed" == 1 ]]; then
    echo "ROLLBACK: redis bootstrap failed rc=$ec"
    (cd "$BASE/repo/infra" && docker compose --env-file "$ENVFILE" stop redis) || true
    cat "$BACKUP/compose.before.yml" > "$TARGET"
  fi
  exit "$ec"
}
trap rollback EXIT
# Parse with Docker Compose before installing the desired new definition.
(cd "$BASE/repo/infra" && docker compose -f /tmp/docker-compose.yml --env-file "$ENVFILE" config -q)
cat /tmp/docker-compose.yml > "$TARGET"
changed=1
(cd "$BASE/repo/infra" && docker compose --env-file "$ENVFILE" up -d --no-deps redis)
healthy=""
for i in $(seq 1 20); do
  healthy="$(docker inspect --format '{{.State.Health.Status}}' vc-redis 2>/dev/null || true)"
  [[ "$healthy" == healthy ]] && break
  sleep 2
done
[[ "$healthy" == healthy ]] || { echo "Redis not healthy: $healthy"; exit 33; }
docker exec vc-redis redis-cli ping | grep -qx PONG
maxmemory="$(docker exec vc-redis redis-cli CONFIG GET maxmemory | tail -1)"
[[ "$maxmemory" == 134217728 ]] || { echo "Wrong maxmemory: $maxmemory"; exit 34; }
[[ "$(docker port vc-redis | wc -l)" == 0 ]] || { echo "Unexpected Redis public port"; exit 35; }
for domain in cutellashop.ir vesta-cosmetics.ir app.vesta-cosmetics.ir; do
  status="$(code "$domain")"
  echo "after: $domain status=$status"
  [[ "$status" == 200 ]] || { echo "Rollback: site failure"; exit 36; }
done
# No object-cache.php drop-ins are installed in this stage.
for site in vesta cutella; do
  [[ ! -f "$BASE/runtime/$site/wp-content/object-cache.php" ]] || {
    echo "Warning: existing cache drop-in now present for $site; inspect before enabling Redis"
  }
done
changed=0
trap - EXIT
echo "REDIS_SERVER_BOOTSTRAP_SUCCESS"
