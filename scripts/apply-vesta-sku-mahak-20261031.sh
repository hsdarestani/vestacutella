#!/usr/bin/env bash
set -euo pipefail
umask 077
TARGETS=/tmp/vesta-mahak-targets-20261031.txt
[[ -s "$TARGETS" ]]
grep -Eq '^[0-9]+$' "$TARGETS"
! grep -Evq '^[0-9]+$' "$TARGETS"
[[ "$(wc -l < "$TARGETS")" -eq 1292 ]]
[[ "$(sort -n "$TARGETS" | uniq | wc -l)" -eq 1292 ]]
IDS="$(paste -sd, "$TARGETS")"
VALUES="$(awk '{printf("(%d),",$1)}' "$TARGETS")"
VALUES="$(printf '%s' "$VALUES" | sed 's/,$//')"
BACKUP="/srv/backups/vesta-mahak-sku-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p -m 0700 "$BACKUP"
cp "$TARGETS" "$BACKUP/target-ids.txt"
db() { docker exec -i vc-db-vesta sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb -uroot -D "$MARIADB_DATABASE" --batch --raw --default-character-set=utf8mb4'; }
# Back up the affected SKU metadata and WooCommerce SKU lookup, not orders or other product metadata.
cat <<SQL | db > "$BACKUP/meta-before.tsv"
SELECT pm.meta_id,pm.post_id,pm.meta_value FROM wp_postmeta pm
WHERE pm.meta_key='_sku' AND pm.post_id IN ($IDS) ORDER BY pm.post_id,pm.meta_id;
SQL
cat <<SQL | db > "$BACKUP/lookup-before.tsv"
SELECT product_id,COALESCE(sku,'') AS sku FROM wp_wc_product_meta_lookup
WHERE product_id IN ($IDS) ORDER BY product_id;
SQL
[[ -s "$BACKUP/meta-before.tsv" && -s "$BACKUP/lookup-before.tsv" ]]
echo "BACKUP_CREATED=$BACKUP"
cat > "$BACKUP/apply.sql" <<SQL
DELIMITER //
DROP PROCEDURE IF EXISTS vc_assign_maha_sku_20261031//
CREATE PROCEDURE vc_assign_maha_sku_20261031()
BEGIN
  DECLARE v_count INT DEFAULT 0;
  DECLARE v_bad INT DEFAULT 0;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;
  CREATE TEMPORARY TABLE vc_sku_targets (id BIGINT UNSIGNED PRIMARY KEY) ENGINE=MEMORY;
  INSERT INTO vc_sku_targets(id) VALUES $VALUES;
  SELECT COUNT(*) INTO v_count FROM vc_sku_targets;
  IF v_count <> 1292 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Target count mismatch';
  END IF;
  SELECT COUNT(*) INTO v_count FROM vc_sku_targets t
    JOIN wp_posts p ON p.ID=t.id AND p.post_type IN ('product','product_variation') AND p.post_status='publish';
  IF v_count <> 1292 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='A target product no longer exists or is unpublished';
  END IF;
  SELECT COUNT(*) INTO v_bad FROM wp_postmeta pm JOIN vc_sku_targets t ON pm.post_id=t.id
    WHERE pm.meta_key='_sku' AND TRIM(pm.meta_value)<>'';
  IF v_bad <> 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='An SKU was assigned since the audit';
  END IF;
  SELECT COUNT(*) INTO v_bad FROM wp_postmeta pm JOIN vc_sku_targets t
    ON pm.meta_value=CAST(t.id AS CHAR) AND pm.post_id<>t.id
    WHERE pm.meta_key='_sku' AND pm.meta_value<>'';
  IF v_bad <> 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='An SKU conflicts with an existing product';
  END IF;
  SELECT COUNT(*) INTO v_bad FROM
    (SELECT pm.post_id FROM wp_postmeta pm JOIN vc_sku_targets t ON t.id=pm.post_id
     WHERE pm.meta_key='_sku' GROUP BY pm.post_id HAVING COUNT(*)>1) mult;
  IF v_bad <> 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Duplicate SKU meta rows on targets';
  END IF;
  SELECT COUNT(*) INTO v_count FROM vc_sku_targets t
    JOIN wp_wc_product_meta_lookup l ON l.product_id=t.id;
  IF v_count <> 1292 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='WooCommerce lookup row missing';
  END IF;
  START TRANSACTION;
  UPDATE wp_postmeta pm JOIN vc_sku_targets t ON pm.post_id=t.id
    SET pm.meta_value=CAST(t.id AS CHAR)
    WHERE pm.meta_key='_sku' AND (pm.meta_value='' OR pm.meta_value IS NULL);
  INSERT INTO wp_postmeta(post_id,meta_key,meta_value)
    SELECT t.id,'_sku',CAST(t.id AS CHAR)
    FROM vc_sku_targets t
    WHERE NOT EXISTS (SELECT 1 FROM wp_postmeta pm WHERE pm.post_id=t.id AND pm.meta_key='_sku');
  UPDATE wp_wc_product_meta_lookup l JOIN vc_sku_targets t ON t.id=l.product_id
    SET l.sku=CAST(t.id AS CHAR);
  SELECT COUNT(DISTINCT t.id) INTO v_count FROM vc_sku_targets t
    JOIN wp_postmeta pm ON pm.post_id=t.id AND pm.meta_key='_sku' AND pm.meta_value=CAST(t.id AS CHAR)
    JOIN wp_wc_product_meta_lookup l ON l.product_id=t.id AND l.sku=CAST(t.id AS CHAR);
  IF v_count <> 1292 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Verification failed; transaction rolled back';
  END IF;
  COMMIT;
  SELECT 'UPDATED_SKUS' AS metric, 1292 AS quantity;
END//
DELIMITER ;
CALL vc_assign_maha_sku_20261031();
DROP PROCEDURE IF EXISTS vc_assign_maha_sku_20261031;
SQL
trap 'printf "DROP PROCEDURE IF EXISTS vc_assign_maha_sku_20261031;\n" | db >/dev/null 2>&1 || true' EXIT
db < "$BACKUP/apply.sql" | tee "$BACKUP/apply.log"
cat <<SQL | db > /tmp/vesta-mahak-sku-result-20261031.tsv
SELECT p.ID AS product_id,
       COALESCE(MAX(CASE WHEN pm.meta_key='_sku' THEN pm.meta_value END),'') AS sku,
       COALESCE(MAX(l.sku),'') AS lookup_sku,
       p.post_type,p.post_status
FROM wp_posts p
LEFT JOIN wp_postmeta pm ON pm.post_id=p.ID AND pm.meta_key='_sku'
LEFT JOIN wp_wc_product_meta_lookup l ON l.product_id=p.ID
WHERE p.ID IN ($IDS)
GROUP BY p.ID,p.post_type,p.post_status ORDER BY p.ID;
SQL
[[ "$(($(wc -l < /tmp/vesta-mahak-sku-result-20261031.tsv)-1))" -eq 1292 ]]
awk -F '\t' 'NR>1 && ($1!=$2 || $1!=$3) { bad++ } END{ if(bad>0) exit 1; print "POST_WRITE_VALIDATED=1292" }' /tmp/vesta-mahak-sku-result-20261031.tsv
echo "SKU_WRITE_SUCCESS"
