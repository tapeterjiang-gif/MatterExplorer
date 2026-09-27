#!/bin/bash
# 从 CSA DCL（分布式合规账本）拉取「厂商表」「产品表」「认证表」，生成随 App 打包的 JSON 资源。
#
# 用法：bash Tools/fetch_matter_catalogs.sh
# 依赖：curl、python3
#   （本机 Python 直连 TLS 会握手失败，因此网络请求一律交给 curl，Python 只做本地文件解析）
#
# 产物：
#   Sources/Resources/matter-vendors.json            {"<vendorID>": "<厂商名>"}
#   Sources/Resources/matter-products.json           [[vendorID, productID, 产品名, 设备类型ID], ...]
#   Sources/Resources/matter-certified-models.json   [[vendorID, productID, 软件版本, 认证类型, 认证值], ...]
#
# 这三个文件是随包「初始快照」；App 运行时可从设置页手动更新，把新数据缓存在 Library/DCLData/。
#
# 两个必须注意的点：
#   1. DCL 单页数据过大会被截断（约 190 KB 处断开），故分页固定 limit=100，
#      并对每页做 JSON 完整性校验与重试。
#   2. 产品表以 (VID, PID) 组合为键 —— PID 只在厂商内部唯一，
#      实测有 721 个 PID 值同时属于多个厂商（PID=1 被 121 家使用）。
#
# 拉完后需要执行 `xcodegen generate`，让新增的资源文件进入工程。

set -uo pipefail

BASE="https://on.dcl.csa-iot.org/dcl"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT/Sources/Resources"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$OUT_DIR"

# 抓取一个分页接口的全部分页，逐页落盘到 $TMP/<name><N>.json，返回页数。
# 参数：$1=DCL 路径  $2=文件名前缀
fetch_pages() {
  local path="$1" name="$2" key="" page=0
  while [ "$page" -lt 500 ]; do
    page=$((page + 1))
    local file="$TMP/$name$page.json" ok=""
    for _ in 1 2 3 4 5; do
      curl -s -G -m 60 "$BASE/$path" \
        --data-urlencode "pagination.limit=100" \
        --data-urlencode "pagination.key=$key" -o "$file"
      if python3 -c "import json,sys;json.load(open(sys.argv[1]))" "$file" 2>/dev/null; then
        ok=1
        break
      fi
      sleep 1
    done
    if [ -z "$ok" ]; then
      echo "  ! 第 $page 页连续 5 次校验失败，中止" >&2
      break
    fi
    key=$(python3 -c "import json,sys;print((json.load(open(sys.argv[1])).get('pagination') or {}).get('next_key') or '')" "$file")
    if [ -z "$key" ]; then
      break
    fi
    if [ $((page % 20)) -eq 0 ]; then
      echo "  已拉取 $page 页…" >&2
    fi
  done
  echo "$page"
}

echo "拉取厂商表（vendorinfo/vendors）…"
vendor_pages=$(fetch_pages "vendorinfo/vendors" vendor)
python3 - "$TMP" "$vendor_pages" "$OUT_DIR/matter-vendors.json" <<'PY'
import json, sys

tmp, pages, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
table = {}
for i in range(1, pages + 1):
    with open(f"{tmp}/vendor{i}.json") as fp:
        for vendor in (json.load(fp).get("vendorInfo") or []):
            vid = vendor.get("vendorID")
            name = (vendor.get("vendorName") or "").strip()
            if isinstance(vid, int) and name:
                table[str(vid)] = name
with open(out, "w") as fp:
    json.dump(table, fp, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
print(f"厂商表 {len(table)} 条 -> {out}（{len(open(out, 'rb').read())} 字节）")
PY

echo "拉取产品表（model/models）…"
model_pages=$(fetch_pages "model/models" model)
python3 - "$TMP" "$model_pages" "$OUT_DIR/matter-products.json" <<'PY'
import json, sys

tmp, pages, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
rows = {}
for i in range(1, pages + 1):
    with open(f"{tmp}/model{i}.json") as fp:
        for model in (json.load(fp).get("model") or []):
            vid, pid = model.get("vid"), model.get("pid")
            if not isinstance(vid, int) or not isinstance(pid, int):
                continue
            name = (model.get("productName") or "").strip() or (model.get("productLabel") or "").strip()
            if not name:
                continue
            device_type = model.get("deviceTypeId")
            rows[(vid, pid)] = [vid, pid, name, device_type if isinstance(device_type, int) else 0]
data = [rows[key] for key in sorted(rows)]
with open(out, "w") as fp:
    json.dump(data, fp, ensure_ascii=False, separators=(",", ":"))
print(f"产品表 {len(data)} 条 -> {out}（{len(open(out, 'rb').read())} 字节）")
PY

echo "拉取认证表（compliance/certified-models）…"
certified_pages=$(fetch_pages "compliance/certified-models" certified)
python3 - "$TMP" "$certified_pages" "$OUT_DIR/matter-certified-models.json" <<'PY'
import json, sys

tmp, pages, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
rows = {}
for i in range(1, pages + 1):
    with open(f"{tmp}/certified{i}.json") as fp:
        for model in (json.load(fp).get("certifiedModel") or []):
            vid, pid, sv = model.get("vid"), model.get("pid"), model.get("softwareVersion")
            if not isinstance(vid, int) or not isinstance(pid, int) or not isinstance(sv, int):
                continue
            rows[(vid, pid, sv)] = [
                vid, pid, sv,
                str(model.get("certificationType") or ""),
                model.get("value") if isinstance(model.get("value"), int) else 0,
            ]
data = [rows[key] for key in sorted(rows)]
with open(out, "w") as fp:
    json.dump(data, fp, ensure_ascii=False, separators=(",", ":"))
print(f"认证表 {len(data)} 条 -> {out}（{len(open(out, 'rb').read())} 字节）")
PY

echo "完成。记得执行：xcodegen generate"