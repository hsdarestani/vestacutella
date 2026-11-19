<?php
/**
 * Plugin Name: Vesta — automatic Mahak to WooCommerce draft completion
 * Description: After native Bazara product sync, safely creates verified simple drafts and completes missing price, real warehouse stock and pictures.
 * Version: 1.0.0
 *
 * Never publishes, overwrites manually edited prices/media, or writes to Mahak.
 * Variable products with nonunique detail mappings remain with the native vendor sync.
 */
if (!defined('ABSPATH')) exit;

function vesta_mhi_auto_fingerprint() {
    global $wpdb;
    $data=[];
    foreach(['bazara_products','bazara_product_details','bazara_product_assets'] as $name) {
        $table=$wpdb->prefix.$name;
        $value=$wpdb->get_row("SELECT COUNT(*) AS n, COALESCE(MAX(RowVersion),0) AS v
            FROM {$table}",ARRAY_A);
        if(!is_array($value))throw new RuntimeException('Bazara local catalog fingerprint unavailable: '.$name);
        $data[$name]=[(int)$value['n'],(string)$value['v']];
    }
    return hash('sha256',wp_json_encode($data));
}

function vesta_mhi_auto_schedule($force=false,$delay=100) {
    if (get_option('vesta_mhi_auto_disabled',false)) return false;
    $now=time();
    if(!$force) {
        // Local DB-only change detection. The native job runs extremely often;
        // never turn every native invocation into a costly Mahak Cloud API fetch.
        try {$fingerprint=vesta_mhi_auto_fingerprint();}
        catch(Throwable $e) {error_log('VESTA_MHI_AUTO_FINGERPRINT_ERROR '.get_class($e));return false;}
        $last=(string)get_option('vesta_mhi_auto_completed_fingerprint','');
        $lastPhoto=(int)get_option('vesta_mhi_auto_last_photo_scan_at',0);
        $backlog=(bool)get_option('vesta_mhi_auto_pending_backlog',false);
        if(!$backlog && $last===$fingerprint && $lastPhoto>0 && $now-$lastPhoto<7200)
            return false;
        if($now-(int)get_option('vesta_mhi_auto_last_schedule_at',0)<900)
            return false;
    }
    if(function_exists('as_has_scheduled_action') &&
       as_has_scheduled_action('vesta_mhi_auto_tick',[],'vesta'))return false;
    if(wp_next_scheduled('vesta_mhi_auto_tick'))return false;
    if(function_exists('as_schedule_single_action')) {
        $id=as_schedule_single_action($now+max(30,(int)$delay),
            'vesta_mhi_auto_tick',[],'vesta');
        if(!$id)return false;
    }else{
        if(!wp_schedule_single_event($now+max(30,(int)$delay),'vesta_mhi_auto_tick'))return false;
    }
    update_option('vesta_mhi_auto_last_schedule_at',$now,false);
    return true;
}
// This fires only *after* the native product-sync callback has run. It schedules
// a separate bounded worker, never expensive Cloud calls in the native job.
add_action('bazara_run_product_sync',function(){vesta_mhi_auto_schedule(false,100);},PHP_INT_MAX);

function vesta_mhi_auto_run($dryRun=false,$limit=6) {
    global $wpdb;
    $limit=max(1,min(10,(int)$limit));
    if(!function_exists('vesta_mhi_ready') || !vesta_mhi_ready() ||
       !function_exists('vesta_mhi_catalog') ||
       !function_exists('vesta_mhi_cloud_photo_ledger') ||
       !function_exists('vesta_catalog_bazara_policy'))
        throw new RuntimeException('Safe Mahak importer prerequisites not available');
    if(get_option('vesta_mhi_auto_disabled',false))throw new RuntimeException('Automatic Mahak import paused');
    $lock='vesta_mhi_auto_v1';
    if((int)$wpdb->get_var($wpdb->prepare('SELECT GET_LOCK(%s,1)',$lock))!==1)
        throw new RuntimeException('Automatic Mahak worker already running');
    try {
        $catalog=vesta_mhi_catalog();
        $ledger=vesta_mhi_cloud_photo_ledger();
        $details=[];
        foreach((array)($catalog['ProductDetails']??[]) as $d)
            if(is_array($d)&&empty($d['Deleted'])&&(int)($d['ProductId']??0)>0)
                $details[(int)$d['ProductId']][]=$d;
        $photos=[];
        $pictures=[];
        foreach((array)($ledger['Pictures']??[]) as $r)
            if(is_array($r)&&empty($r['Deleted']))$pictures[(int)($r['PictureId']??0)]=true;
        foreach((array)($ledger['PhotoGalleries']??[]) as $r)
            if(is_array($r)&&empty($r['Deleted'])&&
               isset($pictures[(int)($r['PictureId']??0)]))
                $photos[(int)($r['ItemCode']??0)]=true;
        $source=[];
        $codeCounts=[];
        foreach((array)($catalog['Products']??[]) as $p) {
            if(!is_array($p)||!empty($p['Deleted']))continue;
            $gid=(int)($p['ProductId']??0);
            $code=trim((string)($p['ProductCode']??''));
            if(!$gid||$code==='')continue;
            $source[]=$p;
            $codeCounts[$code]=($codeCounts[$code]??0)+1;
        }
        $cfg=get_bazara_visitor_settings();
        $currencyOk=($cfg['selectCurrencySoftware']??'')==='toman' &&
           ($cfg['selectCurrencyPlugin']??'')==='toman' &&
           ($cfg['publishStatus']??'')==='draft' &&
           !empty($cfg['chkRegularPrice']) &&
           (string)($cfg['RegularPrice']??'')==='1' &&
           !empty($cfg['chkQuantity']);
        // Exact normalized title duplicate guard: a matching name on an existing
        // product without the source SKU requires reconciliation, not a second draft.
        $names=[];
        $titles=$wpdb->get_results("SELECT ID,post_title FROM {$wpdb->posts}
            WHERE post_type='product' AND post_status IN ('publish','draft','private','pending','future')",ARRAY_A);
        foreach((array)$titles as $r){
            $norm=vesta_catalog_identity_normalize($r['post_title']);
            if($norm!=='')$names[$norm]=true;
        }
        $candidates=[];$blocked=[];$stats=[
            'source_goods'=>count($source),'verified_simple_existing'=>0,
            'eligible_new_drafts'=>0,'eligible_enrich_existing'=>0,
            'variable_or_no_detail'=>0,'skipped_unchanged'=>0,
            'blocked'=>[],'new_drafts'=>0,'completed_existing'=>0,
            'completed_new'=>0,'images_added'=>0,'errors'=>[],
        ];
        $assetTable=$wpdb->prefix.'bazara_product_assets';
        foreach($source as $p){
            $code=trim((string)$p['ProductCode']);$gid=(int)$p['ProductId'];
            if(($codeCounts[$code]??0)!==1) { $blocked['duplicate_cloud_code']=($blocked['duplicate_cloud_code']??0)+1;continue;}
            $ds=$details[$gid]??[];
            if(count($ds)!==1) {
                // Multi-detail Mahak goods correspond to variable Woo parents.
                // Never create or remap variations here; only transfer photos to
                // an existing parent whose code, name and Mahak ID are verified.
                $stats['variable_or_no_detail']++;
                if(empty($photos[$gid]))continue;
                $parentId=(int)vms_existing_woo($code,$gid);
                if(!$parentId)continue;
                $parent=wc_get_product($parentId);
                if(!$parent || !$parent->is_type('variable') ||
                   $parent->get_sku()!==$code ||
                   (int)$parent->get_meta('mahak_id',true)!==$gid) {
                    $blocked['variable_parent_identifier_mismatch']=($blocked['variable_parent_identifier_mismatch']??0)+1;
                    continue;
                }
                try {
                    $plan=vesta_mhi_plan($parentId,$gid);
                    if(count($plan['missing'])+count($plan['reuse'])>0) {
                        $candidates[]=['kind'=>'variable-photo','woo_id'=>$parentId,
                            'code'=>$code,'erp_id'=>$gid,'needs_fields'=>false,
                            'needs_photos'=>true];
                        $stats['eligible_enrich_existing']++;
                    }else $stats['skipped_unchanged']++;
                }catch(Throwable $e) {
                    $blocked['variable_photo_identity_guard']=($blocked['variable_photo_identity_guard']??0)+1;
                }
                continue;
            }
            $d=$ds[0];$did=(int)($d['ProductDetailId']??0);
            if(!$did)continue;
            $wooId=(int)vms_existing_woo($code,$gid);
            if($wooId){
                $woo=wc_get_product($wooId);
                if(!$woo || !$woo->is_type('simple') ||
                   (int)$woo->get_meta('mahak_id',true)!==$gid ||
                   (int)$woo->get_meta('mahak_product_detail_id',true)!==$did ||
                   (string)$woo->get_sku()!==$code){
                    $blocked['existing_sku_or_detail_conflict']=($blocked['existing_sku_or_detail_conflict']??0)+1;
                    continue;
                }
                try{vesta_mhi_identity_guard($wooId,$gid,$code);}
                catch(Throwable $e){
                    $blocked['existing_erp_identity_guard']=($blocked['existing_erp_identity_guard']??0)+1;
                    continue;
                }
                $stats['verified_simple_existing']++;
                $needsFields=$woo->get_status()==='draft' &&
                    ($woo->get_regular_price()==='' || !$woo->get_manage_stock() ||
                     $woo->get_stock_quantity()===null);
                $needsPhotos=false;
                if(!empty($photos[$gid])) {
                    try{
                        $plan=vesta_mhi_plan($wooId,$gid);
                        $needsPhotos=count($plan['missing'])+count($plan['reuse'])>0;
                    }catch(Throwable $e){
                        $blocked['picture_plan_unavailable']=($blocked['picture_plan_unavailable']??0)+1;
                    }
                }
                if(!$needsFields && !$needsPhotos){$stats['skipped_unchanged']++;continue;}
                $candidates[]=['kind'=>'existing','woo_id'=>$wooId,'code'=>$code,
                    'erp_id'=>$gid,'needs_fields'=>$needsFields,'needs_photos'=>$needsPhotos];
                $stats['eligible_enrich_existing']++;
                continue;
            }
            if(!$currencyOk || $did<=0 || !isset($d['Price1']) ||
               !is_numeric($d['Price1']) || (float)$d['Price1']<=0 ||
               (float)$d['Price1']>10000000000) {
                $blocked['new_price_or_currency_unverified']=($blocked['new_price_or_currency_unverified']??0)+1;
                continue;
            }
            $title=vesta_catalog_identity_normalize((string)($p['Name']??''));
            if(mb_strlen($title)<5 || isset($names[$title])) {
                $blocked['new_existing_title_collision']=($blocked['new_existing_title_collision']??0)+1;
                continue;
            }
            if(ctype_digit($code)) {
                $sameId=get_post((int)$code);
                if($sameId && in_array($sameId->post_type,['product','product_variation'],true)) {
                    $blocked['new_wp_id_collision']=($blocked['new_wp_id_collision']??0)+1;
                    continue;
                }
            }
            $assets=$wpdb->get_results($wpdb->prepare(
                "SELECT StoreId,Count1 FROM {$assetTable}
                 WHERE ProductDetailId=%d AND Deleted=0 LIMIT 3",$did),ARRAY_A);
            if(count($assets)!==1 || (int)$assets[0]['StoreId']<=0 ||
               !is_numeric($assets[0]['Count1']) ||
               (float)$assets[0]['Count1']<0) {
                $blocked['new_warehouse_asset_unverified']=($blocked['new_warehouse_asset_unverified']??0)+1;
                continue;
            }
            $policy=vesta_catalog_bazara_policy([
                'ProductId'=>$gid,'ProductCode'=>$code,'name'=>(string)$p['Name'],
                'type'=>'simple','vars'=>[]
            ]);
            if(empty($policy['allow'])){
                $blocked[(string)($policy['reason']??'new_identity_blocked')]=
                    ($blocked[(string)($policy['reason']??'new_identity_blocked')]??0)+1;
                continue;
            }
            $candidates[]=['kind'=>'new','code'=>$code,'erp_id'=>$gid];
            $stats['eligible_new_drafts']++;
        }
        // Give newly registered products precedence over filling old drafts.
        usort($candidates,function($a,$b){return ($a['kind']==='new'?0:1)<=>($b['kind']==='new'?0:1);});
        $stats['blocked']=$blocked;
        $stats['candidate_count']=count($candidates);
        $stats['processed_codes']=[];
        if($dryRun) {
            $stats['dry_run']=true;
            $stats['sample_candidates']=array_slice($candidates,0,12);
            return $stats;
        }
        $processed=0;
        foreach($candidates as $c){
            if($processed>=$limit)break;
            $processed++;
            $id=(int)$c['erp_id'];$code=(string)$c['code'];
            try {
                if($c['kind']==='new'){
                    $out=vms_import_existing(['product_id'=>$id,'code'=>$code]);
                    $wooId=(int)($out['woo_id']??0);
                    if(!$wooId || !in_array(($out['status']??''),['draft_created','already_on_site'],true))
                        throw new RuntimeException('new_draft_creation_not_confirmed');
                    $now=wc_get_product($wooId);
                    if(!$now||$now->get_status()!=='draft' ||
                       $now->get_sku()!==$code ||
                       (int)$now->get_meta('mahak_id',true)!==$id)
                        throw new RuntimeException('new_draft_ERP_identity_failed');
                    $stats['new_drafts']++;
                }else{
                    $wooId=(int)$c['woo_id'];
                }
                $result=vesta_mhi_complete_draft($wooId,$id);
                $photoResult=['added'=>0,'pending'=>0,'errors'=>0];
                if(!empty($photos[$id]))
                    $photoResult=vesta_mhi_import_pictures($wooId,$id,5);
                $stats[$c['kind']==='new'?'completed_new':'completed_existing']++;
                $stats['images_added']+=(int)($photoResult['added']??0);
                $stats['processed_codes'][]=$code;
                if(!empty($photoResult['errors']))
                    $stats['errors'][]=['code'=>$code,'reason'=>'photo_partial'];
            }catch(Throwable $e){
                if(count($stats['errors'])<15)
                    $stats['errors'][]=['code'=>$code,'reason'=>substr(get_class($e),0,40).':'.mb_substr($e->getMessage(),0,115)];
            }
        }
        $stats['remaining_candidates']=max(0,count($candidates)-$processed);
        $stats['completed_at']=gmdate('c');
        update_option('vesta_mhi_auto_last_report',$stats,false);
        update_option('vesta_mhi_auto_completed_fingerprint',vesta_mhi_auto_fingerprint(),false);
        update_option('vesta_mhi_auto_last_photo_scan_at',time(),false);
        update_option('vesta_mhi_auto_pending_backlog',$stats['remaining_candidates']>0,false);
        // The next native product-sync event continues any bounded backlog
        // without launching a nested action while the current one is running.
        return $stats;
    } finally {
        $wpdb->get_var($wpdb->prepare('SELECT RELEASE_LOCK(%s)',$lock));
    }
}
function vesta_mhi_auto_run_action(){
    try{
        $r=vesta_mhi_auto_run(false,6);
        error_log('VESTA_MHI_AUTO_COMPLETED '.wp_json_encode([
            'new_drafts'=>$r['new_drafts']??0,
            'completed_existing'=>$r['completed_existing']??0,
            'images_added'=>$r['images_added']??0,
            'remaining'=>$r['remaining_candidates']??0
        ]));
    }catch(Throwable $e){
        update_option('vesta_mhi_auto_last_report',[
           'completed_at'=>gmdate('c'),'error'=>mb_substr($e->getMessage(),0,180)
        ],false);
        error_log('VESTA_MHI_AUTO_FAILED '.get_class($e));
    }
}
add_action('vesta_mhi_auto_tick','vesta_mhi_auto_run_action');
