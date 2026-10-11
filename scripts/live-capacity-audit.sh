#!/usr/bin/env bash
set -euo pipefail

BASE=/srv/vestacutella
ENVFILE=$BASE/.env
set -a
source "$ENVFILE"
set +a

echo "=== SERVER HARDWARE ==="
echo "vcpus=$(nproc)"
lscpu | grep -E '^(Model name|CPU\(s\)|Thread|Core|Socket|CPU max MHz|CPU min MHz):' || true
free -h
df -h /
echo "load:"; uptime

echo "=== STORAGE BREAKDOWN ==="
du -sh /srv/vestacutella/runtime/vesta /srv/vestacutella/runtime/cutella /srv/vestacutella/runtime/db-vesta /srv/vestacutella/runtime/db-cutella /srv/migration 2>/dev/null || true
docker system df || true

echo "=== CONTAINER USAGE IDLE ==="
docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.PIDs}}' vc-vesta vc-cutella vc-db-vesta vc-db-cutella vc-nginx

echo "=== DATABASE SIZES ==="
docker exec vc-db-vesta mariadb -uroot -p"$VESTA_DB_ROOT_PASSWORD" -N -e "
SELECT table_schema,ROUND(SUM(data_length+index_length)/1024/1024,1) AS MB
FROM information_schema.tables WHERE table_schema='vestacos_m' GROUP BY table_schema;
SHOW GLOBAL STATUS WHERE Variable_name IN ('Threads_connected','Threads_running','Max_used_connections','Slow_queries','Created_tmp_disk_tables','Created_tmp_tables');
"
docker exec vc-db-cutella mariadb -uroot -p"$CUTELLA_DB_ROOT_PASSWORD" -N -e "
SELECT table_schema,ROUND(SUM(data_length+index_length)/1024/1024,1) AS MB
FROM information_schema.tables WHERE table_schema='vestacos_cutella' GROUP BY table_schema;
SHOW GLOBAL STATUS WHERE Variable_name IN ('Threads_connected','Threads_running','Max_used_connections','Slow_queries','Created_tmp_disk_tables','Created_tmp_tables');
"

echo "=== ACTIVE CACHE PLUGINS ==="
for site in vesta cutella; do
  echo "--- $site ---"
  docker exec "vc-$site" php -r '
    require "/var/www/html/wp-config.php";
    $db=new mysqli(DB_HOST,DB_USER,DB_PASSWORD,DB_NAME);
    $p=$table_prefix ?? "wp_";
    $q=$db->query("SELECT option_value FROM `".$p."options` WHERE option_name=\"active_plugins\" LIMIT 1");
    if($q && ($r=$q->fetch_assoc())){
      $a=@unserialize($r["option_value"]);
      if(is_array($a)) foreach($a as $x) if(preg_match("/rocket|cache|redis|litespeed|perfmatters|asset|optimi/i",$x)) echo $x.PHP_EOL;
    }
  ' || true
done

echo "=== MX DNS: old host dependency check ==="
for d in cutellashop.ir vesta-cosmetics.ir; do
  echo "--- $d ---"
  DOMAIN="$d" python3 - <<'PY'
import json,os,urllib.request
d=os.environ["DOMAIN"]
try:
    with urllib.request.urlopen("https://dns.google/resolve?name="+d+"&type=MX", timeout=10) as r:
        j=json.load(r)
    for a in j.get("Answer",[]):
        print(a.get("data",""))
    if not j.get("Answer"): print("<no MX answer>")
except Exception as e:
    print("MX_LOOKUP_ERROR",e)
PY
done

bench() {
  local label="$1" domain="$2" path="$3" n="$4" conc="$5"
  local out
  out="$(mktemp)"
  local start end
  start="$(date +%s%N)"
  export BDOMAIN="$domain" BPATH="$path"
  seq 1 "$n" | xargs -P "$conc" -I{} sh -c     'curl --max-time 20 -ksS --resolve "$BDOMAIN:443:127.0.0.1" -o /dev/null -w "%{http_code} %{time_total}\n" "https://$BDOMAIN$BPATH" || echo "000 20"'     > "$out"
  end="$(date +%s%N)"
  LABEL="$label" OUT="$out" START="$start" END="$end" N="$n" CONC="$conc" python3 - <<'PY'
import os,statistics
rows=[]
for line in open(os.environ["OUT"]):
    p=line.split()
    if len(p)>=2:
        try: rows.append((p[0],float(p[1])))
        except: pass
ok=[t for c,t in rows if c.startswith(("2","3"))]
dur=(int(os.environ["END"])-int(os.environ["START"]))/1e9
def pct(a,p):
    if not a:return 0
    b=sorted(a); return b[min(len(b)-1,max(0,int(round((len(b)-1)*p))))]
print(f'{os.environ["LABEL"]}: requests={len(rows)} concurrency={os.environ["CONC"]} wall={dur:.3f}s rps={len(rows)/dur if dur else 0:.1f} success={len(ok)}/{len(rows)} median={statistics.median(ok) if ok else 0:.3f}s p95={pct(ok,.95):.3f}s p99={pct(ok,.99):.3f}s max={max(ok) if ok else 0:.3f}s')
PY
  rm -f "$out"
}

echo "=== CONTROLLED LOCAL LOAD TEST ==="
# Cached/anonymous browsing load.
bench "Vesta home cached" vesta-cosmetics.ir / 160 20
bench "Vesta shop cached" vesta-cosmetics.ir /shop/ 120 15
# Dynamic PHP path; kept deliberately small on live production.
bench "Vesta login dynamic" vesta-cosmetics.ir /wp-login.php 24 4

bench "Cutella home cached" cutellashop.ir / 120 15
bench "Cutella login dynamic" cutellashop.ir /wp-login.php 20 4

echo "=== CONTAINER USAGE AFTER TEST ==="
docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.PIDs}}' vc-vesta vc-cutella vc-db-vesta vc-db-cutella vc-nginx
free -h
uptime

echo "CAPACITY_AUDIT_OK"
