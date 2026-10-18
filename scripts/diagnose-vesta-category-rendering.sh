#!/usr/bin/env bash
set -euo pipefail
echo "=== all WP menus and relevant item counts ==="
docker exec vc-vesta php -d memory_limit=512M -r '
require "/var/www/html/wp-load.php";
$menus=wp_get_nav_menus();
foreach($menus as $menu){
 $items=wp_get_nav_menu_items($menu->term_id);
 echo "MENU id=".$menu->term_id." slug=".$menu->slug." name=".$menu->name." items=".count((array)$items).PHP_EOL;
 foreach((array)$items as $item){
  if($item->object==="product_cat" && in_array((int)$item->object_id,array(946,1731,1767,1053,950),true))
   echo "  CATEGORY_ITEM id=".$item->ID." title=".$item->title." category_id=".$item->object_id." parent=".$item->menu_item_parent.PHP_EOL;
 }
}
echo "TERM_DETAILS\n";
foreach(array(946,1731,1767,1053,950) as $id){
 $t=get_term($id,"product_cat");
 if(!is_wp_error($t)&&$t)echo "CATEGORY ".$id." parent=".$t->parent." count=".$t->count." name=".$t->name." url=".get_term_link($t).PHP_EOL;
}
echo "THEME_HEADER_OPTIONS\n";
foreach(array("xts-woodmart-options","woodmart_options","xts_theme_settings","woodmart-header-builder","header_builder","woodmart_header","header_woodmart") as $name){
 $v=get_option($name,null);
 echo "OPTION ".$name." type=".gettype($v);
 if(is_array($v)){echo " count=".count($v);foreach($v as $key=>$value){if(preg_match("/menu|categor|header|mobile/i",(string)$key))echo " ".$key."=".(is_scalar($value)?substr((string)$value,0,100):gettype($value));}}
 echo PHP_EOL;
}
' 2>&1 | tail -120
echo "=== server-side cached front-end markup around accessory nav link ==="
tmp="$(mktemp)"
curl -kLsS --max-time 40 --noproxy '*' --resolve vesta-cosmetics.ir:443:127.0.0.1 "https://vesta-cosmetics.ir/" -o "$tmp"
python3 - "$tmp" <<'PY'
from pathlib import Path
import sys,re,html
body=Path(sys.argv[1]).read_text(errors='replace')
print("HTML_BYTES",len(body))
for word in ["اکسسوری","پوشاک پینترستی","کالاهای فانتزی و دکوری","کالا و دکوری فانتزی","دسته بندی ها"]:
    idxs=[m.start() for m in re.finditer(re.escape(word),body)]
    print("WORD",word,"hits",len(idxs))
    for i in idxs[:3]:
        x=body[max(0,i-850):i+400]
        print("CONTEXT",re.sub(r'\s+',' ',html.unescape(x))[:1250])
PY
rm -f "$tmp"
echo "CATEGORY_RENDER_DIAG_COMPLETE"
