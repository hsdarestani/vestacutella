#!/usr/bin/env python3
"""Deploy under the sender's lock. Never replay or rewrite existing financial documents."""
import pathlib, subprocess, fcntl, time, os, shutil, datetime, hashlib
stage=pathlib.Path(__file__).parent
base=pathlib.Path('/srv/vestacutella/runtime/vesta/wp-content')
vendor=base/'plugins/bazara/classes/class.bazara.api.php'
mu=base/'mu-plugins'
pid=subprocess.check_output(['docker','inspect','-f','{{.State.Pid}}','vc-vesta'],text=True).strip()
lockpath=pathlib.Path('/proc')/pid/'root/tmp/vesta-bazara-order-sync.lock'
def php(code):
    subprocess.run(['docker','exec','-i','vc-vesta','php','-d','display_errors=0','-d','memory_limit=768M'],input=code,text=True,check=True)
boot="""<?php
$_SERVER['HTTP_HOST']='vesta-cosmetics.ir';$_SERVER['SERVER_NAME']='vesta-cosmetics.ir';
$_SERVER['HTTPS']='on';$_SERVER['SERVER_PORT']='443';$_SERVER['REQUEST_URI']='/';
require '/var/www/html/wp-load.php';
"""
with lockpath.open('r') as lock:
    for _ in range(120):
        try:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB);break
        except BlockingIOError:time.sleep(.5)
    else:raise SystemExit('SENDER_BUSY_NO_CHANGES')
    backup=pathlib.Path('/srv/backups')/('vesta-restore-toman-'+datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ'))
    backup.mkdir(mode=0o700)
    targets=[vendor,mu/'vesta-accounting-policy.php',mu/'vesta-accounting-reliability.php']
    for p in targets:shutil.copy2(p,backup/p.name)
    print('BACKUP='+str(backup),flush=True)
    php(boot+"""
$s=get_option('bazara_visitor_settings',[]);
if(get_woocommerce_currency()!=='IRT'||($s['selectCurrencySoftware']??'')!=='toman'||($s['selectCurrencyPlugin']??'')!=='toman')throw new Exception('unexpected_currency_settings');
echo "GLOBAL_CURRENCY=IRT_TOMAN_TOMAN\\n";
""")
    expected={'vesta-accounting-policy.php': 'f2abc69f21beec2dee860000afe26ab9c7da938c4ff52ab07409b5cf68dcfc21', 'vesta-accounting-reliability.php': '93ea8eba859ffd9abb9652ddbe8a19ad9cf20afc494c5b4c29d7cbde3af40f1e'}
    for name,digest in expected.items():
        if hashlib.sha256((mu/name).read_bytes()).hexdigest()!=digest:raise SystemExit('LIVE_SOURCE_DRIFT_NO_CHANGES_'+name)
    src=vendor.read_text()
    inject="""        // VC_BAZARA_OUTBOUND_RIAL_ONLY_20261110
        // ERP ledger is Rial while WooCommerce storefront remains IRT/Toman.
        // Use the plugin's existing conversion branches ONLY for outgoing orders.
        // Never alter global currency settings: the same options also control product imports.
        if ($SoftwareCurrency === 'toman' && $PluginCurrency === 'toman' &&
            function_exists('get_woocommerce_currency') && get_woocommerce_currency() === 'IRT') {
            $SoftwareCurrency = 'rial';
        }
"""
    if src.count(inject)!=1:raise SystemExit('UNEXPECTED_VENDOR_CURRENCY_BLOCK_NO_CHANGES')
    updated=src.replace(inject,'',1)
    assert updated.count('VCAR_DURABLE_bazara_save_order')==1
    assert 'VC_BAZARA_FINANCIAL_PAYLOAD_V1_20261112' in updated
    # Exact byte removal leaves shipping, discount, receipts, mapping and idempotency code intact.
    try:
        for p,content in [(vendor,updated)]+[(mu/n,(stage/n).read_text()) for n in ['vesta-accounting-policy.php','vesta-accounting-reliability.php']]:
            temp=p.with_suffix('.toman.tmp');temp.write_text(content)
            stat=p.stat();os.chown(temp,stat.st_uid,stat.st_gid);os.chmod(temp,stat.st_mode)
            container_path='/var/www/html/wp-content/'+str(temp.relative_to(base))
            subprocess.run(['docker','exec','vc-vesta','php','-l',container_path],check=True)
            os.replace(temp,p)
        php(boot+"""
$s=get_option('bazara_visitor_settings',[]);
if(get_woocommerce_currency()!=='IRT'||$s['selectCurrencySoftware']!=='toman'||$s['selectCurrencyPlugin']!=='toman')throw new Exception('currency_changed');
$code=file_get_contents('/var/www/html/wp-content/plugins/bazara/classes/class.bazara.api.php');
$a=strpos($code,'public function bazara_save_order(');$b=strpos($code,'    private function get_selected_bank_id(',$a);$part=substr($code,$a,$b-$a);
if(strpos($part,'VC_BAZARA_OUTBOUND_RIAL_ONLY_20261110')!==false)throw new Exception('rial_override_remains');
if(preg_match_all('/\\$SoftwareCurrency\\s*=(?!=)/',$part)!==1)throw new Exception('unexpected_currency_override');
if(strpos(file_get_contents('/var/www/html/wp-content/mu-plugins/vesta-accounting-reliability.php'),"update_meta_data('_vcar_money_multiplier',1)")===false)throw new Exception('unit_not_stamped');
echo "OUTBOUND_UNIT=TOMAN; LEGACY_VERIFICATION=RIAL; NO_FINANCIAL_WRITES_IN_DEPLOY=yes\\n";
""")
        for host in ['vesta-cosmetics.ir','cutellashop.ir','app.vesta-cosmetics.ir']:
            code=subprocess.check_output(['curl','--noproxy','*','-ksS','--connect-timeout','8','--max-time','25','--resolve',host+':443:127.0.0.1','-o','/dev/null','-w','%{http_code}','https://'+host+'/'],text=True)
            print('HEALTH='+host+' HTTP='+code,flush=True)
            if code!='200':raise RuntimeError('health_failed')
    except BaseException:
        for p in targets:shutil.copy2(backup/p.name,p)
        print('CODE_ROLLED_BACK=yes',flush=True)
        raise
    print('TOMAN_RESTORED=yes; EXISTING_INVOICES_UNCHANGED=yes',flush=True)
