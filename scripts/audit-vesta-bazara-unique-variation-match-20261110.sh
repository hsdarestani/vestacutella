#!/usr/bin/env bash
set -Eeuo pipefail
db() { docker exec -i vc-db-vesta sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb -uroot -D "$MARIADB_DATABASE" --batch --raw --default-character-set=utf8mb4'; }
{
  echo '@@PARENTS'
  cat <<'SQL' | db
SELECT ID,REPLACE(REPLACE(post_title,CHAR(10),' '),CHAR(9),' ') FROM wp_posts
WHERE ID IN(42801,45079,33045,102249,37746,45887,58867,56377,54591,101870,44556,41893,35112,73091);
SQL
  echo '@@CATALOG'
  cat <<'SQL' | db
SELECT ProductId,REPLACE(REPLACE(ProductName,CHAR(10),' '),CHAR(9),' ') FROM wp_bazara_products;
SQL
  echo '@@ATTRIBUTES'
  cat <<'SQL' | db
SELECT p.ID,p.post_parent,m.meta_value FROM wp_posts p JOIN wp_postmeta m ON m.post_id=p.ID
WHERE p.ID IN(42807,45092,33051,102250,102253,100023,45900,58872,56381,54598,101872,44569,41902,35120,35117,73200)
AND m.meta_key LIKE 'attribute%';
SQL
  echo '@@DETAILS'
  cat <<'SQL' | db
SELECT ProductId,ProductDetailId,COALESCE(Properties,'null'),COALESCE(Deleted,0) FROM wp_bazara_product_details;
SQL
  echo '@@STOCK'
  cat <<'SQL' | db
SELECT ProductDetailId,StoreId,Count1 FROM wp_bazara_product_assets WHERE Deleted=0 OR Deleted IS NULL;
SQL
} | python3 -c '
import sys,json,re,unicodedata,collections
def n(x):
 x=unicodedata.normalize("NFKC",x.strip().casefold())
 x=x.replace("ي","ی").replace("ك","ک").replace("آ","ا").replace("‌"," ").replace("ـ","")
 x=re.sub(r"[\u064b-\u065f]","",x)
 return re.sub(r"\s+"," ",re.sub(r"[^\w\s]"," ",x)).strip()
section=""; parents={}; catalog=collections.defaultdict(list); attrs=collections.defaultdict(list); details=collections.defaultdict(list);stock=collections.defaultdict(list)
for line in sys.stdin:
 line=line.rstrip("\n")
 if line.startswith("@@"):section=line;continue
 v=line.split("\t")
 if not v or v[0] in ("ID","ProductId","ProductDetailId"):continue
 try:
  if section=="@@PARENTS" and len(v)>=2:parents[int(v[0])]=n(v[1])
  elif section=="@@CATALOG" and len(v)>=2:catalog[n(v[1])].append(int(v[0]))
  elif section=="@@ATTRIBUTES" and len(v)>=3:attrs[int(v[0])].append((int(v[1]),n(v[2])))
  elif section=="@@DETAILS" and len(v)>=4:
   raw=json.loads(v[2]) if v[2]!="null" else []
   vals=sorted(n(item.get("V","")) for item in raw if isinstance(item,dict) and item.get("V")) if isinstance(raw,list) else []
   details[int(v[0])].append((str(v[1]),vals,int(v[3])))
  elif section=="@@STOCK" and len(v)>=3:stock[str(v[0])].append((v[1],float(v[2])))
 except Exception as e:print("DATA_PARSE_SKIP",section,type(e).__name__)
success=0;fails=0
for vid, av in sorted(attrs.items()):
 pid=av[0][0]
 want=sorted(v for _,v in av if v)
 name=parents.get(pid,"")
 bids=catalog.get(name,[])
 if len(bids)!=1 or not want:
  print("VARIATION",vid,"UNMATCHED_PARENT_OR_ATTRIBUTE","MATCHING_CATALOG",len(bids));fails+=1;continue
 bids=bids[0]
 candidates=[did for did,props,deleted in details[bids] if props==want and deleted==0]
 if len(candidates)!=1:
  print("VARIATION",vid,"AMBIGUOUS_DETAILS","PRODUCT_ID",bids,"EXPECTED_ATTRS",want,"DETAIL_MATCHES",len(candidates));fails+=1;continue
 did=candidates[0]; s=stock.get(did,[])
 print("VALID_UNIQUE_MAP",vid,"PARENT",pid,"ERP_PRODUCT",bids,"ERP_DETAIL",did,"WOO_ATTRS",",".join(want),"ASSET_STORES",len(s),"STOCK",",".join(str(sid)+":"+str(qty) for sid,qty in s[:5]))
 success+=1
print("UNIQUE_MAPPINGS",success,"UNMATCHED_OR_AMBIGUOUS",fails)
';
