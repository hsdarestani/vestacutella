#!/usr/bin/env python3
"""Exact Bazara product sync identity patch. No broad regex, fail closed on drift."""
import argparse, pathlib, sys
MARKER="VESTA_CATALOG_IDENTITY_GUARD_20261118"
OLD="""        $product = bazara_get_product_by_sku($product_code);
        if (!empty($product)) {
            $pp = get_product_by_mahakID($product_id);
            if (!empty($pp)) {
                update_post_meta($pp->get_id(), 'mahak_id', '');
            }
        } else
            $product = get_product_by_mahakID($product_id);"""
NEW="""        // VESTA_CATALOG_IDENTITY_GUARD_20261118:
        // Never let a conflicting variation/draft/duplicate SKU hijack an ERP good.
        // Never erase someone else's Mahak ID to make a matching SKU look valid.
        $vesta_identity = function_exists('vesta_catalog_bazara_policy')
            ? vesta_catalog_bazara_policy($args)
            : array('allow'=>false, 'reason'=>'identity_guard_not_loaded');
        if (empty($vesta_identity['allow'])) {
            error_log('VESTA_CATALOG_BLOCKED good=' . (int)$product_id .
                ' code=' . preg_replace('/[^a-zA-Z0-9_-]/','',(string)$product_code) .
                ' reason=' . preg_replace('/[^a-zA-Z0-9_-]/','',(string)($vesta_identity['reason'] ?? 'unknown')));
            return array('success'=>false,'message'=>'شناسه کالای محک و سایت نیازمند تطبیق است؛ همگام سازی متوقف شد.');
        }
        $product = bazara_get_product_by_sku($product_code);
        if (!empty($product)) {
            $pp = get_product_by_mahakID($product_id);
            if (!empty($pp) && (int)$pp->get_id() !== (int)$product->get_id()) {
                error_log('VESTA_CATALOG_BLOCKED conflicting_erp_owner=' . (int)$product_id);
                return array('success'=>false,'message'=>'شناسه محک به محصول دیگری متصل است؛ تطبیق دستی لازم است.');
            }
        } else {
            $product = get_product_by_mahakID($product_id);
        }"""
def main():
    p=argparse.ArgumentParser()
    p.add_argument("--plugin-root",required=True)
    p.add_argument("--apply",action="store_true")
    a=p.parse_args()
    target=pathlib.Path(a.plugin_root)/"classes/functions.php"
    original=target.read_text(encoding="utf-8")
    normal=original.replace("\r\n","\n")
    if MARKER in normal:
        if OLD in normal or "update_post_meta($pp->get_id(), 'mahak_id', '')" in normal:
            raise ValueError("guard present but destructive old block also present")
        if normal.count(MARKER)!=1:raise ValueError("guard duplicate")
        print("CATALOG_VENDOR_IDENTITY_PATCH_PRESENT=yes")
        return
    if normal.count(OLD)!=1:
        raise ValueError("unexpected vendor product sync source (old block count "+str(normal.count(OLD))+")")
    newer=normal.replace(OLD,NEW)
    if newer.count(MARKER)!=1 or OLD in newer or "update_post_meta($pp->get_id(), 'mahak_id', '')" in newer:
        raise ValueError("unsafe output")
    print("CATALOG_VENDOR_GUARD_PATCH_READY=yes")
    if not a.apply:
        print("DRYRUN_NO_VENDOR_SOURCE_WRITES=yes")
        return
    staging=target.with_name(target.name+".vesta-identity.next")
    staging.write_text(newer,encoding="utf-8")
    staging.chmod(target.stat().st_mode)
    import os
    os.chown(staging,target.stat().st_uid,target.stat().st_gid)
    staging.replace(target)
    print("CATALOG_VENDOR_GUARD_PATCH_APPLIED=yes")
if __name__=="__main__":
    try:main()
    except Exception as e:
        print("CATALOG_VENDOR_GUARD_ABORT="+type(e).__name__+":"+str(e),file=sys.stderr)
        sys.exit(23)
