#!/usr/bin/env python3
"""Harden Vesta's existing Mahak-to-Woo import bridge against equal-code wrong goods."""
import argparse
from pathlib import Path
import sys
MARKER="VESTA_SOURCE_IMPORT_MATCH_HARDENED_20261118"
FUNC=r"""function vms_verify_existing_link($woo_id, $code, $erp_product) {
    // VESTA_SOURCE_IMPORT_MATCH_HARDENED_20261118
    $existing=wc_get_product((int)$woo_id);
    if (!$existing || $existing->is_type('variation')) {
        throw new RuntimeException('کد محک روی یک تنوع سایت قرار گرفته است؛ اتصال مستقل مجاز نیست.');
    }
    $name=(string)($erp_product['Name']??'');
    $norm=function($x) {
        $x=vms_normalize((string)$x);
        $x=strtr($x,['آ'=>'ا','َ'=>'','ُ'=>'','ِ'=>'']);
        return preg_replace('/[^\p{L}\p{N}]+/u','',mb_strtolower($x,'UTF-8'));
    };
    if ($norm($existing->get_name())!==$norm($name)) {
        throw new RuntimeException('هویت کالا در محک و ووکامرس متفاوت است؛ کد مشابه کافی نیست.');
    }
    if ((string)$existing->get_sku()!==(string)$code) {
        throw new RuntimeException('SKU محصول سایت با کد محک تطابق ندارد.');
    }
    $id=(int)($erp_product['ProductId']??0);
    $bound=(int)$existing->get_meta('mahak_id',true);
    if ($id<=0 || ($bound>0 && $bound!==$id)) {
        throw new RuntimeException('شناسه داخلی محک برای این کالا متعلق به محصول دیگری است.');
    }
    if (ctype_digit((string)$code)) {
        $original=get_post((int)$code);
        if ($original && $original->post_type==='product' && $original->post_status==='publish'
            && (int)$original->ID!==(int)$woo_id &&
            $norm($original->post_title)===$norm($name)) {
            throw new RuntimeException('کد محک به پیش‌نویس تکراری وصل است؛ ابتدا مالکیت کد اصلاح شود.');
        }
    }
    return true;
}
"""
def main():
    args=argparse.ArgumentParser()
    args.add_argument("--target",required=True)
    args.add_argument("--apply",action="store_true")
    a=args.parse_args()
    p=Path(a.target);original=p.read_text(encoding="utf-8")
    if MARKER in original:
        if original.count(MARKER)!=1 or original.count("vms_verify_existing_link($woo_id, $code, $p);")!=2:
            raise ValueError("hardened source drift")
        print("SOURCE_IMPORT_MATCH_PROTECTION_ALREADY_PRESENT=yes");return
    anchor="function vms_import_existing($payload) {"
    if original.count(anchor)!=1:raise ValueError("import function signature drift")
    updated=original.replace(anchor,FUNC+"\n"+anchor)
    # Call site 1: before successful idempotent return
    before1="""    $woo_id = vms_existing_woo($code, $id);
    if ($woo_id) {
        return vms_public_result(array('status' => 'already_on_site', 'woo_id' => $woo_id));
    }"""
    after1="""    $woo_id = vms_existing_woo($code, $id);
    if ($woo_id) {
        vms_verify_existing_link($woo_id, $code, $p);
        return vms_public_result(array('status' => 'already_on_site', 'woo_id' => $woo_id));
    }"""
    if updated.count(before1)!=1:raise ValueError("initial existing Woo check drift")
    updated=updated.replace(before1,after1)
    before2="""        if ($woo_id) {
            $record['status'] = 'already_on_site';
        } else {"""
    after2="""        if ($woo_id) {
            vms_verify_existing_link($woo_id, $code, $p);
            $record['status'] = 'already_on_site';
        } else {"""
    if updated.count(before2)!=1:raise ValueError("reserved Woo check drift")
    updated=updated.replace(before2,after2)
    if updated.count(MARKER)!=1 or updated.count("vms_verify_existing_link($woo_id, $code, $p);")!=2:
        raise ValueError("invalid guard output")
    print("SOURCE_IMPORT_MATCH_SAFETY_PATCH_READY=yes")
    if not a.apply:
        print("SOURCE_IMPORT_PATCH_DRYRUN_NO_WRITES=yes");return
    temp=p.with_name(p.name+'.vesta-safe.next')
    temp.write_text(updated,encoding='utf-8')
    temp.chmod(p.stat().st_mode)
    import os
    os.chown(temp,p.stat().st_uid,p.stat().st_gid)
    temp.replace(p)
    print("SOURCE_IMPORT_MATCH_SAFETY_PATCH_APPLIED=yes")
if __name__=="__main__":
    try:main()
    except Exception as e:
        print("SOURCE_IMPORT_IDENTITY_GUARD_ABORT="+type(e).__name__+":"+str(e),file=sys.stderr)
        sys.exit(23)
