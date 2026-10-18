<?php
/**
 * One-time Cutella source catalog Korean food cleanup.
 * User-authorized scope: Korean parent and descendants, plus the five matching products.
 * Products go into Trash, not permanent deletion. Backup required before --apply.
 */
if(PHP_SAPI!=='cli')exit(2);
require '/var/www/html/wp-load.php';
$mode=$argv[1]??'dry-run';
if(!in_array($mode,array('dry-run','apply'),true))exit(2);
$root=get_term(27,'product_cat');
if(!$root || is_wp_error($root) || $root->name!=='خوراکی‌های کره‌ای'){
 echo "SOURCE_KOREAN_ROOT_NOT_FOUND\n";
 exit(0);
}
function vc_children($id){
 $ids=array((int)$id);
 foreach(get_terms(array('taxonomy'=>'product_cat','hide_empty'=>false,'parent'=>$id)) as $t)
  foreach(vc_children((int)$t->term_id) as $tid)$ids[]=$tid;
 return array_values(array_unique($ids));
}
$tree=vc_children(27);
$expected=array(12911,27942,27945,27948,28454);
$items=array();
foreach($tree as $cid){
 $ids=get_objects_in_term($cid,'product_cat');
 if(is_wp_error($ids))exit(3);
 foreach($ids as $pid)if(get_post_type($pid)==='product')$items[(int)$pid]=true;
}
sort($expected);
$actual=array_keys($items);sort($actual);
if($expected!==$actual){echo "REFUSING_UNEXPECTED_KOREAN_SCOPE ".count($actual)." ".count($expected)."\n";exit(4);}
echo 'CUTELLA_KOREAN_PLAN products='.count($actual).' category_terms='.count($tree).PHP_EOL;
if($mode==='dry-run'){echo "CUTELLA_KOREAN_DRY_RUN_OK\n";exit(0);}
foreach($actual as $pid){
 $p=get_post($pid);
 if($p->post_status!=='trash'){
   $done=wp_trash_post($pid);
   if(!$done){echo 'FAILED_TRASH '.$pid.PHP_EOL;exit(5);}
 }
 echo 'KOREAN_SOURCE_TRASHED '.$pid.PHP_EOL;
}
foreach(array_reverse($tree) as $cid){
 $related=get_objects_in_term($cid,'product_cat');
 if(is_wp_error($related))exit(6);
 foreach($related as $pid){
  $r=wp_remove_object_terms((int)$pid,(int)$cid,'product_cat');
  if(is_wp_error($r))exit(7);
 }
 $r=wp_delete_term($cid,'product_cat');
 if(is_wp_error($r) || !$r)exit(8);
 echo 'KOREAN_SOURCE_CATEGORY_DELETED '.$cid.PHP_EOL;
}
wp_cache_flush();
if(function_exists('rocket_clean_domain'))rocket_clean_domain();
echo "CUTELLA_KOREAN_CLEANUP_OK\n";
