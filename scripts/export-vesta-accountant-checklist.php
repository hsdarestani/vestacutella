<?php
// Read-only accountant checklist export: public catalog identity only; no customers or financial payloads.
error_reporting(E_ERROR|E_PARSE);ini_set('display_errors','0');set_time_limit(0);
$_SERVER['HTTP_HOST']='vesta-cosmetics.ir';$_SERVER['SERVER_NAME']='vesta-cosmetics.ir';$_SERVER['HTTPS']='on';$_SERVER['SERVER_PORT']='443';$_SERVER['REQUEST_URI']='/';
require '/var/www/html/wp-load.php';global $wpdb;
function va_norm($s){$s=trim((string)$s);$s=strtr($s,['۰'=>'0','۱'=>'1','۲'=>'2','۳'=>'3','۴'=>'4','۵'=>'5','۶'=>'6','۷'=>'7','۸'=>'8','۹'=>'9','٠'=>'0','١'=>'1','٢'=>'2','٣'=>'3','٤'=>'4','٥'=>'5','٦'=>'6','٧'=>'7','٨'=>'8','٩'=>'9']);$s=str_replace(['ي','ك','آ','‌','ـ','أ','إ'],['ی','ک','ا',' ','','ا','ا'],$s);$s=function_exists('mb_strtolower')?mb_strtolower($s,'UTF-8'):strtolower($s);$s=preg_replace('/[\\x{064B}-\\x{065F}]/u','',$s);return trim(preg_replace('/\\s+/u',' ',preg_replace('/[^\\p{L}\\p{N}\\s]/u',' ',$s)));}
function va_attr($s){$s=preg_replace('/\\s+/u','',va_norm($s));$s=preg_replace('/^(کد|پک)/u','',$s);return preg_replace_callback('/\\d+/',function($m){return (string)(int)$m[0];},$s);}
$api=new BazaraApi(true);$r=$api->get_all_data('',array('fromProductVersion'=>0,'fromProductDetailVersion'=>0));
if(!is_array($r)||empty($r['success'])||!isset($r['message']['Products'],$r['message']['ProductDetails']))exit(30);
$bycode=[];$details=[];$detailsAttr=[];
foreach($r['message']['Products'] as $p)if(empty($p['Deleted']))$bycode[(string)$p['ProductCode']][]=$p;
foreach($r['message']['ProductDetails'] as $d)if(empty($d['Deleted'])){
 $pid=(int)$d['ProductId'];$details[$pid][]=$d;$v=[];
 foreach(json_decode((string)$d['Properties'],true)??[] as $a)if(is_array($a)&&va_attr($a['V']??'')!=='')$v[]=va_attr($a['V']??'');
 if(count($v)===1)$detailsAttr[$pid][$v[0]][]=$d;
}
$priority=[];$blocked=$wpdb->get_col("SELECT order_id FROM {$wpdb->prefix}vesta_accounting_outbox WHERE state='blocked' AND reason='missing_product_mapping'");
foreach($blocked as $id){$o=wc_get_order($id);if(!$o)continue;foreach($o->get_items('line_item') as $i){$p=$i->get_variation_id()?:$i->get_product_id();if(!(int)get_post_meta($p,'mahak_id',true)||!(int)get_post_meta($p,'mahak_product_detail_id',true))$priority[$p][]=(string)$id;}}
$rows=[];$counts=['variation_active'=>0,'variation_mapped'=>0,'simple_sellable'=>0,'simple_mapped'=>0];$reason=[];
$vars=$wpdb->get_results("SELECT v.ID,v.post_parent,p.post_title FROM {$wpdb->posts} v JOIN {$wpdb->posts} p ON p.ID=v.post_parent WHERE v.post_type='product_variation' AND v.post_status='publish' AND p.post_status='publish' ORDER BY v.ID",ARRAY_A);
foreach($vars as $v){
 $id=(int)$v['ID'];$parent=(int)$v['post_parent'];$counts['variation_active']++;
 $mp=(int)get_post_meta($id,'mahak_id',true);$md=(int)get_post_meta($id,'mahak_product_detail_id',true);if($mp&&$md){$counts['variation_mapped']++;continue;}
 $sku=(string)get_post_meta($id,'_sku',true);$psku=(string)get_post_meta($parent,'_sku',true);
 $stable=[];foreach(array_unique(array_filter([(string)$parent,$psku])) as $code)foreach($bycode[$code]??[] as $p)$stable[(int)$p['ProductId']]=$p;
 $stable=array_values($stable);$rp=count($stable)===1?$stable[0]:null;
 $attrsRaw=[];$attrsDisplay=[];foreach(get_post_meta($id) as $k=>$vs)if(strncmp($k,'attribute',9)===0){
  $raw=(string)($vs[0]??'');$attrsRaw[]=$raw;$tax=substr($k,10);$label=wc_attribute_label($tax);$display=rawurldecode($raw);
  if(taxonomy_exists($tax)){$t=get_term_by('slug',$raw,$tax);if($t&&!is_wp_error($t))$display=$t->name;}
  $attrsDisplay[]=$label.': '.$display;
 }
 if(!$stable)$why='missing_stable_parent';
 elseif(count($stable)!==1)$why='ambiguous_parent';
 elseif(va_norm($rp['Name']??'')!==va_norm($v['post_title']))$why='code_name_conflict';
 elseif(count($attrsRaw)!==1)$why='attribute_definition_review';
 elseif(count($detailsAttr[(int)$rp['ProductId']][va_attr($attrsRaw[0])]??[])===0)$why='missing_exact_detail';
 elseif(count($detailsAttr[(int)$rp['ProductId']][va_attr($attrsRaw[0])]??[])!==1)$why='ambiguous_detail';
 else $why='mapping_review';
 $reason[$why]=($reason[$why]??0)+1;
 $rows[]=['type'=>'variation','id'=>(string)$id,'parent_id'=>(string)$parent,'name'=>html_entity_decode($v['post_title'],ENT_QUOTES,'UTF-8'),'attributes'=>implode(' | ',$attrsDisplay),'sku'=>$sku,'parent_sku'=>$psku,'reason'=>$why,'cloud_code'=>(string)($rp['ProductCode']??''),'cloud_name'=>html_entity_decode((string)($rp['Name']??''),ENT_QUOTES,'UTF-8'),'cloud_product_id'=>(string)($rp['ProductId']??''),'url'=>get_permalink($parent),'waiting_orders'=>implode(', ',array_unique($priority[$id]??[])),'has_price'=>get_post_meta($id,'_price',true)!=='','stock_status'=>(string)get_post_meta($id,'_stock_status',true)];
}
$ids=$wpdb->get_col("SELECT p.ID FROM {$wpdb->posts} p WHERE p.post_type='product' AND p.post_status='publish' AND NOT EXISTS(SELECT 1 FROM {$wpdb->posts} v WHERE v.post_parent=p.ID AND v.post_type='product_variation') ORDER BY p.ID");
foreach($ids as $id){
 $id=(int)$id;$o=wc_get_product($id);if(!$o||$o->get_type()!=='simple'||!$o->is_purchasable())continue;$counts['simple_sellable']++;
 if((int)get_post_meta($id,'mahak_id',true)&&(int)get_post_meta($id,'mahak_product_detail_id',true)){$counts['simple_mapped']++;continue;}
 $sku=(string)$o->get_sku();$stable=[];foreach(array_unique(array_filter([(string)$id,$sku])) as $code)foreach($bycode[$code]??[] as $p)$stable[(int)$p['ProductId']]=$p;
 $stable=array_values($stable);$rp=count($stable)===1?$stable[0]:null;
 if(!$stable)$why='missing_stable_parent';elseif(count($stable)!==1)$why='ambiguous_parent';elseif(va_norm($o->get_name())!==va_norm($rp['Name']??''))$why='code_name_conflict';else $why='mapping_review';
 $reason[$why]=($reason[$why]??0)+1;
 $rows[]=['type'=>'simple','id'=>(string)$id,'parent_id'=>'','name'=>html_entity_decode($o->get_name(),ENT_QUOTES,'UTF-8'),'attributes'=>'','sku'=>$sku,'parent_sku'=>'','reason'=>$why,'cloud_code'=>(string)($rp['ProductCode']??''),'cloud_name'=>html_entity_decode((string)($rp['Name']??''),ENT_QUOTES,'UTF-8'),'cloud_product_id'=>(string)($rp['ProductId']??''),'url'=>get_permalink($id),'waiting_orders'=>implode(', ',array_unique($priority[$id]??[])),'has_price'=>true,'stock_status'=>$o->get_stock_status()];
}
$out=['exported_utc'=>gmdate('c'),'store'=>'https://vesta-cosmetics.ir','basis'=>'WooCommerce published active catalog and freshly read Mahak Cloud catalog; Mahak Windows not inspected','counts'=>$counts,'reason_counts'=>$reason,'blocked_order_count'=>count($blocked),'rows'=>$rows];
$json=json_encode($out,JSON_UNESCAPED_UNICODE|JSON_INVALID_UTF8_SUBSTITUTE|JSON_UNESCAPED_SLASHES);if(!$json)exit(31);
$b64=base64_encode(gzencode($json,9));foreach(str_split($b64,12000) as $i=>$chunk)echo 'ACCOUNTANT_EXPORT_CHUNK_'.sprintf('%04d',$i).'='.$chunk."\n";
echo 'ACCOUNTANT_EXPORT_SHA256='.hash('sha256',$json)."\n";echo 'ACCOUNTANT_EXPORT_ROWS='.count($rows)."\n";echo "READ_ONLY_EXPORT_COMPLETE=yes\n";
