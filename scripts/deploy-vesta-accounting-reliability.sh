#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
stage=${1:?staged source directory required}
base=/srv/vestacutella/runtime/vesta/wp-content
backup=/srv/backups/vesta-accounting-outbox-$(date -u +%Y%m%dT%H%M%SZ)
exec 9>/run/lock/vesta-accounting-reliability-deploy.lock
flock -n 9 || exit 10
mkdir -p -m 0700 "$backup"
test "$(df -Pk /srv | awk 'NR==2{print $4}')" -gt 1500000
for host in vesta-cosmetics.ir cutellashop.ir app.vesta-cosmetics.ir;do
 code=$(curl --noproxy '*' -ksS --connect-timeout 8 --max-time 25 --resolve "$host:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$host/")
 echo "BEFORE=$host HTTP=$code";test "$code" = 200
done
cp -p "$base/plugins/bazara/classes/class.bazara.api.php" "$backup/class.bazara.api.php"
tar -czf "$backup/bazara-and-mu-plugins.tar.gz" -C "$base" plugins/bazara mu-plugins
docker exec vc-db-vesta sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb-dump -uroot --single-transaction --quick "$MARIADB_DATABASE" wp_postmeta wp_options wp_bazara_orders' | gzip > "$backup/accounting-metadata.sql.gz"
gzip -t "$backup/accounting-metadata.sql.gz"
echo "BACKUP_VERIFIED=$backup"
docker cp "$stage" vc-vesta:/tmp/vcar-stage
for f in vesta-accounting-policy.php vesta-accounting-reliability.php;do
 docker exec vc-vesta php -l "/tmp/vcar-stage/$f"
done
docker exec vc-vesta php /tmp/vcar-stage/accounting-policy-test.php /tmp/vcar-stage/vesta-accounting-policy.php
changed=no;verified=no
rollback(){
 rc=$?;trap - EXIT
 if [[ "$changed" = yes && "$verified" != yes ]];then
   cp -p "$backup/class.bazara.api.php" "$base/plugins/bazara/classes/class.bazara.api.php"
   rm -f "$base/mu-plugins/vesta-accounting-reliability.php" "$base/mu-plugins/vesta-accounting-policy.php"
   echo OUTBOX_CODE_ROLLED_BACK=yes
 fi
 exit "$rc"
}
trap rollback EXIT
changed=yes
install -m 0644 "$stage/vesta-accounting-policy.php" "$base/mu-plugins/vesta-accounting-policy.php"
install -m 0644 "$stage/vesta-accounting-reliability.php" "$base/mu-plugins/vesta-accounting-reliability.php"
STAGE="$stage" BASE="$base" python3 - <<'PY'
import pathlib,os,re,fcntl,time,subprocess
p=pathlib.Path(os.environ['BASE'])/'plugins/bazara/classes/class.bazara.api.php'
s=p.read_text()
pid=subprocess.check_output(['docker','inspect','-f','{{.State.Pid}}','vc-vesta'],text=True).strip()
with open('/proc/'+pid+'/root/tmp/vesta-bazara-order-sync.lock','r') as lock:
 for attempt in range(120):
  try: fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB);break
  except BlockingIOError:time.sleep(.25)
 else:raise SystemExit('ACTIVE_SYNC_DID_NOT_RELEASE_LOCK')
 for method,code in [
  ('start_sync_orders',"if (class_exists('Vesta_Accounting_Reliability')) return Vesta_Accounting_Reliability::tick();"),
  ('bazara_save_order',"if (class_exists('Vesta_Accounting_Reliability') && !Vesta_Accounting_Reliability::$dispatching) return Vesta_Accounting_Reliability::request($order_id);")]:
  marker='VCAR_DURABLE_'+method
  if marker in s:continue
  pattern=r'(public function '+method+r'\([^)]*\)\s*\{)'
  s,n=re.subn(pattern,lambda m:m.group(1)+'\n        // '+marker+'\n        '+code,s,count=1)
  if n!=1:raise SystemExit('VENDOR_SIGNATURE_CHANGED_'+method)
 tmp=p.with_suffix('.vcar.tmp');tmp.write_text(s);os.chmod(tmp,p.stat().st_mode);os.chown(tmp,p.stat().st_uid,p.stat().st_gid)
 subprocess.run(['docker','exec','vc-vesta','php','-l','/var/www/html/wp-content/plugins/bazara/classes/class.bazara.api.vcar.tmp'],check=True)
 os.replace(tmp,p)
PY
install -m 0600 "$stage/vesta-accounting-worker.php" /srv/vestacutella/repo/scripts/vesta-accounting-worker.php
install -m 0600 "$stage/vesta-accounting-catalog-audit.php" /srv/vestacutella/repo/scripts/vesta-accounting-catalog-audit.php
docker exec -i -e VCAR_INSTALL=yes vc-vesta php -d memory_limit=768M -d display_errors=0 < "$stage/vesta-accounting-worker.php"
docker exec -i vc-vesta php -d memory_limit=512M -d display_errors=0 < "$stage/vesta-accounting-catalog-audit.php"
for host in vesta-cosmetics.ir cutellashop.ir app.vesta-cosmetics.ir;do
 code=$(curl --noproxy '*' -ksS --connect-timeout 8 --max-time 25 --resolve "$host:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$host/")
 echo "AFTER=$host HTTP=$code";test "$code" = 200
done
cat > /etc/cron.d/vesta-accounting-outbox <<'CRON'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/2 * * * * root flock -n /run/lock/vesta-accounting-worker.lock timeout 180 bash -c 'docker exec -u www-data -i vc-vesta php -d display_errors=0 -d memory_limit=768M < /srv/vestacutella/repo/scripts/vesta-accounting-worker.php' >>/var/log/vesta-accounting-worker.log 2>&1
19 * * * * root flock -n /run/lock/vesta-accounting-catalog-audit.lock timeout 90 bash -c 'docker exec -u www-data -i vc-vesta php -d display_errors=0 -d memory_limit=512M < /srv/vestacutella/repo/scripts/vesta-accounting-catalog-audit.php' >>/var/log/vesta-accounting-catalog.log 2>&1
CRON
chmod 0644 /etc/cron.d/vesta-accounting-outbox
chmod 0644 /srv/vestacutella/repo/scripts/vesta-accounting-worker.php /srv/vestacutella/repo/scripts/vesta-accounting-catalog-audit.php
cat >/etc/logrotate.d/vesta-accounting-outbox <<'ROTATE'
/var/log/vesta-accounting-worker.log /var/log/vesta-accounting-catalog.log {
 daily
 rotate 14
 compress
 missingok
 notifempty
 copytruncate
}
ROTATE
verified=yes
trap - EXIT
echo OUTBOX_DEPLOYED_SENDER_DISABLED_PENDING_CANARY=yes
