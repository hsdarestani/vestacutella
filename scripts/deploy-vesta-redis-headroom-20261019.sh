#!/usr/bin/env bash
# Rollbackable no-restart Redis expansion for Vesta and Cutella.
set -euo pipefail
export LC_ALL=C
COMPOSE=/srv/vestacutella/repo/infra/docker-compose.yml
BACKUP="/srv/backups/vesta-redis-headroom-$(date -u +%Y%m%dT%H%M%SZ)"
get_max(){ docker exec vc-redis redis-cli --raw CONFIG GET maxmemory | tail -1 | tr -d '\r'; }
status(){ curl --noproxy '*' -kLsS --max-time 25 --resolve "$1:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$1$2"; }
test -s "$COMPOSE"
test "$(docker inspect -f '{{.State.Running}}' vc-redis)" = true
test "$(docker exec vc-redis redis-cli ping | tr -d '\r')" = PONG
old_max="$(get_max)"
new_max=268435456
if [[ "$old_max" == "$new_max" ]]; then
 grep -q -- '--maxmemory", "256mb"' "$COMPOSE" || { echo "ABORT: runtime is tuned but Compose is not";exit 20; }
 echo REDIS_HEADROOM_ALREADY_APPLIED;exit 0
fi
[[ "$old_max" == 134217728 ]] || { echo "ABORT unexpected maxmemory $old_max";exit 21; }
old_limit="$(docker inspect -f '{{.HostConfig.Memory}}' vc-redis)"
[[ "$old_limit" == 201326592 ]] || { echo "ABORT Docker limit drifted $old_limit";exit 22; }
available="$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)"
(( available > 786432 )) || { echo "ABORT insufficient available RAM";exit 23; }
python3 - "$COMPOSE" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
old='''    command: ["redis-server", "--save", "", "--appendonly", "no", "--maxmemory", "128mb", "--maxmemory-policy", "allkeys-lru"]
    mem_limit: 192m'''
assert s.count(old)==1, "Unexpected live redis config"
assert s.count("container_name: vc-redis")==1
print("REDIS_CONFIG_PREFLIGHT_OK")
PY
for host in vesta-cosmetics.ir cutellashop.ir app.vesta-cosmetics.ir; do
 code="$(status "$host" /)"
 echo "PRECHECK $host code=$code"
 [[ "$code" == 200 ]] || exit 24
done
mkdir -p "$BACKUP";chmod 700 "$BACKUP";cp -p "$COMPOSE" "$BACKUP/docker-compose.yml"
docker exec vc-redis redis-cli INFO memory | grep -E '^(used_memory_human|maxmemory_human):' || true
docker exec vc-redis redis-cli INFO stats | grep -E '^(evicted_keys|keyspace_hits|keyspace_misses):' || true
changed=0;complete=0
rollback(){
 rc=$?
 trap - EXIT
 if [[ "$changed" == 1 && "$complete" != 1 ]];then
  echo "REDIS_HEADROOM_ROLLBACK rc=$rc"
  docker exec vc-redis redis-cli CONFIG SET maxmemory "$old_max" || true
  docker update --memory "$old_limit" vc-redis || true
  cp -p "$BACKUP/docker-compose.yml" "$COMPOSE" || true
 fi
 exit "$rc"
}
trap rollback EXIT
python3 - "$COMPOSE" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]);s=p.read_text()
old='''    command: ["redis-server", "--save", "", "--appendonly", "no", "--maxmemory", "128mb", "--maxmemory-policy", "allkeys-lru"]
    mem_limit: 192m'''
new='''    command: ["redis-server", "--save", "", "--appendonly", "no", "--maxmemory", "256mb", "--maxmemory-policy", "allkeys-lru"]
    mem_limit: 384m'''
if s.count(old)!=1:raise SystemExit("Redis config preflight drift")
p.write_text(s.replace(old,new,1))
PY
changed=1
# Avoid restarting the Redis container. Keep existing object cache entries intact.
docker update --memory 384m vc-redis >/dev/null
docker exec vc-redis redis-cli CONFIG SET maxmemory "$new_max"
[[ "$(get_max)" == "$new_max" ]] || exit 30
[[ "$(docker inspect -f '{{.HostConfig.Memory}}' vc-redis)" == 402653184 ]] || exit 31
[[ "$(docker exec vc-redis redis-cli ping | tr -d '\r')" == PONG ]] || exit 32
[[ "$(docker exec vc-redis redis-cli --raw CONFIG GET maxmemory-policy | tail -1 | tr -d '\r')" == allkeys-lru ]] || exit 33
docker exec vc-redis redis-cli INFO memory | grep -E '^(used_memory_human|maxmemory_human):' || true
docker exec vc-redis redis-cli INFO keyspace | grep '^db[01]:' || true
for host in vesta-cosmetics.ir cutellashop.ir app.vesta-cosmetics.ir; do
 code="$(status "$host" /)"
 echo "POSTCHECK $host code=$code"
 [[ "$code" == 200 ]] || exit 34
done
for route in /shop/ /cart/ /checkout/ /my-account/ /wp-login.php; do
 code="$(status vesta-cosmetics.ir "$route")"
 echo "CHECK $route code=$code"
 [[ "$code" == 200 || "$code" == 301 || "$code" == 302 ]] || exit 35
done
headers="$(mktemp)"
curl --noproxy '*' -kLsS --max-time 25 --resolve vesta-cosmetics.ir:443:127.0.0.1 -H "Cookie: vc_customer_safety=1" -D "$headers" -o /dev/null https://vesta-cosmetics.ir/
grep -qi 'x-vc-guest-cache: .*skip=1' "$headers" || { rm -f "$headers";exit 36; }
rm -f "$headers"
docker exec vc-nginx nginx -t >/dev/null
complete=1;trap - EXIT
echo "VESTA_REDIS_HEADROOM_DEPLOYED maxmemory=256MiB container_limit=384MiB backup=$BACKUP"
