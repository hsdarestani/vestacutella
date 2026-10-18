#!/usr/bin/env bash
set -euo pipefail
echo "=== order phone format audit, never emit number ==="
docker exec vc-vesta php -r '
require "/var/www/html/wp-load.php";
foreach(array(101583) as $id) {
 $o=wc_get_order($id);
 if(!$o){echo "ORDER ".$id." missing\n";continue;}
 $s=(string)$o->get_billing_phone("edit");
 $ascii=preg_replace("/[^0-9]/","",$s);
 $fa=(bool)preg_match("/[۰-۹]/u",$s);
 $ar=(bool)preg_match("/[٠-٩]/u",$s);
 $p=trim($s);
 $shape=substr($ascii,0,2)==="09"?"09":(substr($ascii,0,2)==="98"?"98":(substr($ascii,0,4)==="0098"?"0098":"other"));
 echo "ORDER ".$id." gateway=".$o->get_payment_method()." raw_bytes=".strlen($s).
 " ascii_digits=".strlen($ascii)." persian_digits=".($fa?"yes":"no").
 " arabic_digits=".($ar?"yes":"no")." prefix_shape=".$shape.PHP_EOL;
}
'
echo "=== top-level category collisions and menu (no customer data) ==="
docker exec vc-vesta php -r '
require "/var/www/html/wp-load.php";
$root=get_term_by("slug","cutella-products","product_cat");
if(!$root)exit;
$kids=get_terms(array("taxonomy"=>"product_cat","hide_empty"=>false,"parent"=>$root->term_id));
foreach($kids as $kid){
 $same=get_terms(array("taxonomy"=>"product_cat","hide_empty"=>false,"parent"=>0,"name"=>$kid->name));
 $match=array();
 foreach((array)$same as $a)if((int)$a->term_id!==(int)$kid->term_id && $a->name===$kid->name)$match[]=(int)$a->term_id;
 echo "CATEGORY ".$kid->term_id." name=".$kid->name." existing_top=".implode(",",$match).PHP_EOL;
}
$loc=get_nav_menu_locations();
foreach($loc as $location=>$id) {
 if($location!=="main-menu" && $location!=="mobile-menu")continue;
 echo "MENU ".$location." id=".$id.PHP_EOL;
 foreach((array)wp_get_nav_menu_items((int)$id) as $item)if((int)$item->menu_item_parent===0) echo "TOP_ITEM ".$item->ID." ".$item->title." type=".$item->type.PHP_EOL;
}
' 2>&1 | tail -90
echo "FORMAT_AND_CATEGORY_OVERLAP_AUDIT_OK"
