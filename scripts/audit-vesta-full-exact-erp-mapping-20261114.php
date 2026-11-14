<?php
// Read-only exact unique mapping classification across ALL published Vesta Woo product variations.
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
$samples=array();$remoteCount=0;
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
 if(count($samples)<25)$samples[]=array($id,$erpId,$erpDetailId);
}
foreach($counts as $k=>$v)echo strtoupper($k)."=".$v."\n";
foreach($samples as $v)echo "SAMPLE_EXACT_WOO=".$v[0]." ERP_PRODUCT=".$v[1]." ERP_DETAIL=".$v[2]."\n";
echo "READ_ONLY_FULL_STORE_EXACT_MATCH_CLASSIFICATION_COMPLETE=yes\n";
