#!/usr/bin/env bash
# Independent health verification after guarded rollback. No PHP code execution.
set -euo pipefail
echo "=== POST ROLLBACK SITE HEALTH ==="
for d in vesta-cosmetics.ir cutellashop.ir app.vesta-cosmetics.ir;do
 for route in / /shop/ /wp-login.php;do
  [[ "$d" == app.vesta-cosmetics.ir && "$route" != / ]] && continue
  code="$(curl --noproxy "*" -ksSL --max-time 30 --resolve "$d:443:127.0.0.1" -o /dev/null -w "%{http_code}" "https://$d$route")"
  echo "$d$route http=$code"
  [[ "$code" == 200 ]] || { echo "FAIL origin HTTP";exit 31;}
 done
done
if [[ -e /srv/vestacutella/runtime/cutella/wp-content/mu-plugins/vc-cutella-guest-dashicons.php ]];then
 echo "FAIL: trial dropin still active";exit 32;
else echo "cutella_dashicons_trial=absent (rollback clean)";fi
for name in vc-nginx vc-cutella vc-vesta vc-db-cutella vc-db-vesta vc-redis;do
 docker inspect -f "{{.Name}} running={{.State.Running}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}" "$name"
done
echo "=== CUTELLA ERROR SIGNALS ==="
docker logs --since 15m vc-cutella 2>&1 | grep -Ei "segfault|fatal|php.*error|[[:space:]]500[[:space:]]" | tail -25 | sed -E "s/(password|token|secret|authorization)[^ ]*/[REDACTED]/Ig" || true
echo "=== POST_ROLLBACK_HEALTH_SUCCESS ==="
