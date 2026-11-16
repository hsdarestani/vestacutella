#!/usr/bin/env python3
"""Conservative, idempotent, fail-closed Bazara vendor image patch.

Turns destructive full-gallery replacement into non-destructive addition:
- Never permanently deletes a Woo attachment during manual photo refresh.
- Never clears featured/gallery before processing Mahak pictures.
- Never deletes local pictures when absent/deleted in Mahak.
- Never replaces an existing Woo featured image. Adds new Mahak pictures to gallery.

Patch exactly the known reviewed Bazara methods; abort on vendor source drift.
No picture synchronization is enabled by this script.
"""
import argparse
import pathlib
import re
import sys

MARKER = "VESTA_KEEP_WOO_IMAGES_20261116"


def exactly_once(source, before, after, label):
    count = source.count(before)
    if count != 1:
        raise RuntimeError(f"{label}_EXPECTED_ONE_MATCH_FOUND_{count}")
    return source.replace(before, after)


def patch_product_table(source):
    if MARKER in source:
        verify_product_table(source)
        return source
    # Permanently disabling this class-local destructive helper also covers any
    # administrative caller other than process_bulk_action().
    pattern = r"(?ms)^function delete_product_images_by_sku\(\$sku\) \{.*?^\}"
    replacement = (
        "function delete_product_images_by_sku($sku) {\n"
        f"    // {MARKER}: no attachment deletion even for manual picture refresh.\n"
        "    return false;\n"
        "}"
    )
    source, n = re.subn(pattern, replacement, source, count=1)
    if n != 1:
        raise RuntimeError(f"DELETE_HELPER_MATCHES_{n}")
    verify_product_table(source)
    return source


def verify_product_table(source):
    m = re.search(r"(?ms)^function delete_product_images_by_sku\(\$sku\) \{.*?^\}", source)
    if not m or MARKER not in m.group(0):
        raise RuntimeError("PRODUCT_TABLE_PATCH_NOT_PRESENT")
    if "wp_delete_attachment" in m.group(0) or "delete_post_thumbnail" in m.group(0):
        raise RuntimeError("DESTRUCTIVE_PRODUCT_TABLE_HELPER_STILL_PRESENT")


def patch_api(source):
    if MARKER in source:
        verify_api(source)
        return source
    # A deleted remote picture must never remove a locally uploaded picture.
    old_deletion = re.compile(
        r"(?s)    // حذف تصاویر حذف شده از محصولات\n"
        r"    foreach \(\$deleted_pictures as \$deleted_pic\) \{.*?"
        r"\n    \}\n\n    // دریافت و پردازش تصاویر جدید"
    )
    replacement = (
        f"    // {MARKER}: ignored deletions from remote Mahak. Local Woo pictures are owner-managed.\n"
        "    // دریافت و پردازش تصاویر جدید"
    )
    source, n = old_deletion.subn(replacement, source, count=1)
    if n != 1:
        raise RuntimeError(f"REMOTE_DELETE_BLOCK_MATCHES_{n}")
    old_clear = (
        "            $objProduct->set_image_id(''); // حذف تصویر شاخص\n"
        "            $objProduct->set_gallery_image_ids(array()); // حذف گالری تصاویر\n"
        "            $objProduct->save(); // ذخیره تغییرات\n"
    )
    source = exactly_once(source, old_clear, "            // Existing Woo featured image/gallery remain unchanged.\n",
                          "GALLERY_CLEAR_BLOCK")
    source = exactly_once(source, "if ($first_image) {",
                          "if ($first_image && !$objProduct->get_image_id()) {",
                          "FEATURED_IMAGE_ASSIGNMENT")
    verify_api(source)
    return source


def verify_api(source):
    if MARKER not in source:
        raise RuntimeError("API_PATCH_NOT_PRESENT")
    m = re.search(r"(?s)public function sync_pictures\(\).*?(?=\n    public function |\n    private function |\n    protected function |\Z)", source)
    if not m:
        raise RuntimeError("SYNC_PICTURES_METHOD_NOT_FOUND")
    method = m.group(0)
    for forbidden in ("set_image_id('')", "set_gallery_image_ids(array())",
                      "delete_post_thumbnail(", "wp_delete_attachment("):
        if forbidden in method:
            raise RuntimeError("DESTRUCTIVE_IMAGE_SYNC_STILL_PRESENT_"+forbidden)
    if "if ($first_image && !$objProduct->get_image_id()) {" not in method:
        raise RuntimeError("FEATURED_IMAGE_PROTECTION_MISSING")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--plugin-root", required=True)
    parser.add_argument("--apply", action="store_true")
    options = parser.parse_args()
    root = pathlib.Path(options.plugin_root)
    targets = {
        "classes/class.products.table.php": patch_product_table,
        "classes/class.bazara.api.php": patch_api,
    }
    plans = []
    for rel, patch in targets.items():
        path = root / rel
        old = path.read_text(encoding="utf-8")
        new = patch(old)
        plans.append((path, old, new))
        print(f"IMAGE_SAFE_PATCH_CHECK={rel} READY=yes WILL_CHANGE={int(old != new)}")
    if not options.apply:
        print("DRY_RUN_ONLY_NO_SOURCE_WRITES=yes")
        return 0
    for path, old, new in plans:
        if old == new:
            continue
        staging = path.with_name(path.name+".vesta-safe.next")
        staging.write_text(new, encoding="utf-8")
        staging.chmod(path.stat().st_mode)
        staging.chown(path.stat().st_uid, path.stat().st_gid)
        staging.replace(path)
        print(f"IMAGE_SAFE_PATCH_INSTALLED={path.name}")
    print("IMAGE_SAFE_PATCH_INSTALLED_KEEPS_SYNC_SETTING_UNCHANGED=yes")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        print("IMAGE_SAFE_PATCH_ABORT="+type(exc).__name__+":"+str(exc), file=sys.stderr)
        sys.exit(23)
