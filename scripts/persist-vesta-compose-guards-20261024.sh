#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
file=/srv/vestacutella/repo/infra/docker-compose.yml
envfile=/srv/vestacutella/.env
test -s "$file"
test -s "$envfile"
save=/srv/backups/vesta-compose-logcaps-$(date -u +%Y%m%dT%H%M%SZ)
mkdir -m 700 -p "$save"
cp -p "$file" "$save/docker-compose.yml"
echo "COMPOSE_BACKUP=$save"
python3 - "$file" <<'PY'
from pathlib import Path
import sys,re
p=Path(sys.argv[1]);s=p.read_text()
names=['redis','db-cutella','db-vesta','cutella','vesta','nginx']
for name in names:
    x='    container_name: vc-'+name
    if s.count(x)!=1:raise SystemExit("ABORT compose drift "+name)
    start=s.index(x)
    next_service=re.search(r"(?m)^  [A-Za-z0-9_-]+:\s*$",s[start+len(x):])
    ending=start+len(x)+next_service.start() if next_service else len(s)
    chunk=s[start:ending]
    if '    logging:' not in chunk:
        anchor='    restart: unless-stopped'
        if chunk.count(anchor)!=1:raise SystemExit("restart anchor missing "+name)
        opts='''    logging:
      driver: "json-file"
      options:
        max-size: "20m"
        max-file: "4"'''
        chunk=chunk.replace(anchor,anchor+'\n'+opts,1)
    if name in ('vesta','cutella') and '    mem_limit:' not in chunk:
        anchor='    restart: unless-stopped'
        chunk=chunk.replace(anchor,anchor+'\n    mem_limit: '+('2900m' if name=='vesta' else '1500m'),1)
    s=s[:start]+chunk+s[ending:]
p.write_text(s)
PY
if ! docker compose -f "$file" --env-file "$envfile" config -q >/dev/null 2>&1; then
 cp -p "$save/docker-compose.yml" "$file"
 echo "COMPOSE_VALIDATION_FAILED_ROLLED_BACK"
 exit 22
fi
echo "COMPOSE_STATIC_VALIDATION_OK"
echo "Future container recreations inherit memory caps and rotating Docker logs; no container restarted."
for d in vesta-cosmetics.ir cutellashop.ir app.vesta-cosmetics.ir; do
 code=$(curl -ksS --connect-timeout 5 --max-time 15 --resolve "$d:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$d/" || true)
 echo "SITE $d HTTP=$code"
 if [ "$code" != 200 ];then exit 23;fi
done
echo "PERSISTENCE_DEPLOY_OK"
