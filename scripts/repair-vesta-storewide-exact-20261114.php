<?php
// Strict idempotent exact Woo-to-existing-ERP metadata mapping; no ERP/catalog/order/stock/price writes.
error_reporting(E_ERROR|E_PARSE); ini_set('display_errors','0'); set_time_limit(0);
$_SERVER['HTTP_HOST']='vesta-cosmetics.ir';$_SERVER['SERVER_NAME']='vesta-cosmetics.ir';$_SERVER['HTTPS']='on';$_SERVER['SERVER_PORT']='443';$_SERVER['REQUEST_URI']='/';
require '/var/www/html/wp-load.php';global $wpdb;
function vc_norm($s){
 $s=trim((string)$s);
 $s=strtr($s,array('۰'=>'0','۱'=>'1','۲'=>'2','۳'=>'3','۴'=>'4','۵'=>'5','۶'=>'6','۷'=>'7','۸'=>'8','۹'=>'9',
 '٠'=>'0','١'=>'1','٢'=>'2','٣'=>'3','٤'=>'4','٥'=>'5','٦'=>'6','٧'=>'7','٨'=>'8','٩'=>'9'));
 $s=str_replace(array('ي','ك','آ','‌','ـ','أ','إ'),array('ی','ک','ا',' ','','ا','ا'),$s);
 $s=function_exists('mb_strtolower')?mb_strtolower($s,'UTF-8'):strtolower($s);
 $s=preg_replace('/[\x{064B}-\x{065F}]/u','',$s);
 $s=preg_replace('/[^\p{L}\p{N}\s]/u',' ',$s);
 return trim(preg_replace('/\s+/u',' ',$s));
}
function vc_attr($s){
 $s=preg_replace('/\s+/u','',vc_norm($s));
 $s=preg_replace('/^(کد|پک)/u','',$s);
 return preg_replace_callback('/\d+/',function($m){return (string)(int)$m[0];},$s);
}
$rows=$wpdb->get_results("SELECT v.ID,v.post_parent,p.post_title FROM {$wpdb->posts} v
 JOIN {$wpdb->posts} p ON p.ID=v.post_parent
 WHERE v.post_type='product_variation' AND v.post_status='publish'
 AND p.post_type='product' AND p.post_status='publish' ORDER BY v.ID",ARRAY_A);
$ids=array_column($rows,'ID');$meta=array();
foreach(array_chunk($ids,300) as $chunk){
 $in=implode(',',array_map('intval',$chunk));
 foreach($wpdb->get_results("SELECT post_id,meta_key,meta_value FROM {$wpdb->postmeta}
 WHERE post_id IN($in) AND (meta_key LIKE 'attribute%' OR meta_key IN('mahak_id','mahak_product_detail_id'))",ARRAY_A) as $m)$meta[(int)$m['post_id']][$m['meta_key']]=$m['meta_value'];
}
$products=$wpdb->get_results("SELECT ProductId,ProductCode,ProductName,Deleted FROM {$wpdb->prefix}bazara_products",ARRAY_A);
$details=$wpdb->get_results("SELECT ProductId,ProductDetailId,Properties,Deleted FROM {$wpdb->prefix}bazara_product_details",ARRAY_A);
$byCode=array();$byName=array();$byDetail=array();
foreach($products as $p) {
 if((int)$p['Deleted']!==0)continue;
 $byCode[(string)$p['ProductCode']][]=$p;
 $byName[vc_norm($p['ProductName'])][]=$p;
}
foreach($details as $d){
 if((int)$d['Deleted']!==0)continue;
 $arr=json_decode((string)$d['Properties'],true);
 $vs=is_array($arr)?array_values(array_filter(array_map(function($a){return is_array($a)?vc_attr($a['V']??''):'';},$arr))):array();
 if(count($vs)===1)$byDetail[(int)$d['ProductId']][$vs[0]][]=(int)$d['ProductDetailId'];
}
$counts=array('total'=>count($rows),'already_fully_mapped'=>0,'safe_new_exact'=>0,'missing_parent'=>0,
 'ambiguous_parent'=>0,'code_title_mismatch'=>0,'attribute_missing_or_multiple'=>0,
 'remote_detail_not_found'=>0,'remote_detail_ambiguous'=>0,'existing_id_conflict'=>0,'existing_partial_empty'=>0);
$samples=array();$plan=array();
foreach($rows as $row){
 $id=(int)$row['ID'];$parent=(int)$row['post_parent'];$m=$meta[$id]??array();
 $mp=(int)($m['mahak_id']??0);$md=(int)($m['mahak_product_detail_id']??0);
 if($mp>0&&$md>0){$counts['already_fully_mapped']++;continue;}
 $p=$byCode[(string)$parent]??array();
 if(count($p)!==1)$p=$byName[vc_norm($row['post_title'])]??array();
 if(count($p)!==1){$counts[count($p)?'ambiguous_parent':'missing_parent']++;continue;}
 if(vc_norm($p[0]['ProductName'])!==vc_norm($row['post_title'])){$counts['code_title_mismatch']++;continue;}
 $erpId=(int)$p[0]['ProductId'];
 $attrs=array();
 foreach($m as $key=>$val)if(strncmp($key,'attribute',9)===0)$attrs[]=$val;
 if(count($attrs)!==1){$counts['attribute_missing_or_multiple']++;continue;}
 $candidate=$byDetail[$erpId][vc_attr($attrs[0])]??array();
 if(count($candidate)!==1){$counts[count($candidate)?'remote_detail_ambiguous':'remote_detail_not_found']++;continue;}
 $erpDetailId=$candidate[0];
 if(($mp>0&&$mp!==$erpId)||($md>0&&$md!==$erpDetailId)){$counts['existing_id_conflict']++;continue;}
 if((array_key_exists('mahak_id',$m)&&!$mp)||(array_key_exists('mahak_product_detail_id',$m)&&!$md)){
  $counts['existing_partial_empty']++;continue;
 }
 $counts['safe_new_exact']++;
 $plan[$id]=array($erpId,$erpDetailId);
 if(count($samples)<25)$samples[]=array($id,$erpId,$erpDetailId);
}
foreach($counts as $k=>$v)echo strtoupper($k)."=".$v."\n";
foreach($samples as $v)echo "SAMPLE_EXACT_WOO=".$v[0]." ERP_PRODUCT=".$v[1]." ERP_DETAIL=".$v[2]."\n";

$existing=array();
$existingRows=$wpdb->get_results("SELECT p.post_id,CAST(p.meta_value AS UNSIGNED) erpDetail,
 v.post_status vstatus,COALESCE(parent.post_status,'none') pstatus
 FROM {$wpdb->postmeta} p JOIN {$wpdb->posts} v ON v.ID=p.post_id
 LEFT JOIN {$wpdb->posts} parent ON parent.ID=v.post_parent
 WHERE v.post_type='product_variation' AND v.post_status='publish' AND parent.post_status='publish' AND p.meta_key='mahak_product_detail_id'
 AND CAST(p.meta_value AS UNSIGNED)>0",ARRAY_A);
$existingStats=array();
foreach($existingRows as $row){
 $existing[(int)$row['erpDetail']][]=array((int)$row['post_id'],$row['vstatus'],$row['pstatus']);
 $kind=$row['vstatus'].'/'.$row['pstatus'];$existingStats[$kind]=($existingStats[$kind]??0)+1;
}
foreach($existingStats as $kind=>$count)echo 'PREVIOUS_DETAIL_MAPPING_STATUS='.$kind.' COUNT='.$count."\n";
$duplicate=array();
foreach($plan as $id=>$v)$duplicate[$v[1]][]=$id;
$strict=array();$collisions=0;$duplicateCollisions=0;$priorCollisions=0;$bothCollisions=0;$examples=array();
foreach($plan as $id=>$v) {
 $multi=(count($duplicate[$v[1]])!==1);$hasOld=!empty($existing[$v[1]]);
 if($multi || $hasOld){
  $collisions++;
  if($multi)$duplicateCollisions++;
  if($hasOld)$priorCollisions++;
  if($multi&&$hasOld)$bothCollisions++;
  if(count($examples)<12)$examples[]=array($id,$v[0],$v[1],count($duplicate[$v[1]]),count($existing[$v[1]]??array()));
  continue;
 }
 $strict[$id]=$v;
}
echo 'UNIQUE_ERP_DETAIL_IDS_IN_CANDIDATES='.count($duplicate)."\n";
echo 'CANDIDATES_WITH_SAME_DETAIL_IN_MULTIPLE_WOO_VARIANTS='.$duplicateCollisions."\n";
echo 'CANDIDATES_USING_ALREADY_MAPPED_DETAIL='.$priorCollisions."\n";
echo 'COLLISIONS_IN_BOTH_CATEGORIES='.$bothCollisions."\n";
foreach($examples as $e){
 echo 'COLLISION_EXAMPLE_WOO='.$e[0].' ERP_PRODUCT='.$e[1].' DETAIL='.$e[2].' NEW_CANDIDATE_COUNT='.$e[3].' EXISTING_WOO_COUNT='.$e[4]."\n";
 foreach(array_slice($existing[$e[2]]??array(),0,3) as $old)echo 'PREVIOUS_MAPPING_WOO='.$old[0].' VAR_STATUS='.$old[1].' PARENT_STATUS='.$old[2]."\n";
}
echo 'STRICT_ONE_TO_ONE_CANDIDATES='.count($strict)."\n";
echo 'ERP_DETAIL_COLLISIONS_SKIPPED='.$collisions."\n";
if(getenv('VC_MAP_COMMIT')!=='yes'){echo "DRY_RUN_NO_WRITES=yes\n";exit(0);}
$batchSize=max(1,min(100,(int)(getenv('VC_MAP_BATCH_SIZE')?:80)));
$selected=array_slice($strict,0,$batchSize,true);
$created=array();
try {
 foreach($selected as $id=>$v){
  foreach(array('mahak_id'=>(string)$v[0], 'mahak_product_detail_id'=>(string)$v[1]) as $key=>$value){
   if(metadata_exists('post',$id,$key))throw new Exception('concurrent_metadata_change');
   if(!add_post_meta($id,$key,$value,true))throw new Exception('metadata_insert_failed');
   $created[]=array($id,$key,$value);
   if((string)get_post_meta($id,$key,true)!==$value)throw new Exception('metadata_readback_failed');
  }
 }
}catch(Throwable $e){
 foreach(array_reverse($created) as $r)delete_post_meta($r[0],$r[1],$r[2]);
 echo "BATCH_ROLLBACK_COMPLETED=yes\n";exit(43);
}
echo 'BATCH_VARIATIONS_MAPPED='.count($selected)."\n";
echo 'BATCH_META_ROWS_CREATED='.count($created)."\n";
echo 'BATCH_EXACT_MAPPING_VERIFIED=yes'."\n";
echo "NO_CLOUD_PRODUCT_OR_ORDER_WRITES=yes\n";
