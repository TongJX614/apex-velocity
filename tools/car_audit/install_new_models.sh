#!/bin/bash
# APEX VELOCITY — 安装 staging 新 GLB 到游戏 assets/cars/models/
#
# 依据 /tmp/car_export_out/batch_report.json：
#   - status=ok 且无 measured_r 偏差>5% / 结构异常告警 → 安装
#   - status=ok_special / skip / fail / measured_r 偏差>5% → 保留旧模型，列入待修
#   - hyundai_elantra、bmw_m4_adro_kit 等 Lead 决定保留旧版的：自动跳过
# 安装前把「当前项目里的文件」备份到 /tmp/car_after/pre_install/（旧模型备份在项目外大备份里已有，
# 但 bmw_m3_e46_gtr 当前是 Lead 的新原型，覆盖前单独留存），并做 sha256 校验。
#
# 用法:
#   bash tools/car_audit/install_new_models.sh [--dry-run]
# 输出:
#   /tmp/car_after/install_plan.txt     每台的决策（install/skip/keep-old + 原因 + 大小 + sha256）
#   /tmp/car_after/pre_install/         被覆盖前的项目文件备份
#
# 说明: 只写 assets/cars/models/ 与 /tmp；不改 data/、scripts/。

set -u
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

PROJECT="${PROJECT:-/Users/tong/Desktop/极速巅峰}"
STAGING="${STAGING:-/tmp/car_export_out}"
OUT_DIR="${OUT_DIR:-/tmp/car_after}"
MANIFEST="$PROJECT/data/car_manifest.json"
BATCH="$STAGING/batch_report.json"

[ -f "$BATCH" ] || { echo "缺少 batch_report: $BATCH" >&2; exit 1; }
mkdir -p "$OUT_DIR/pre_install"
PLAN="$OUT_DIR/install_plan.txt"
: > "$PLAN"
echo "# 安装计划 $(date '+%Y-%m-%d %H:%M:%S')  staging=$STAGING  dry_run=$DRY" | tee -a "$PLAN"

# 解析 batch_report + manifest，输出安装/保留决策表；shell 按行读取执行
DECISIONS=$(python3 - "$BATCH" "$MANIFEST" "$PLAN" <<'PY'
import json, os, sys

batch_path, manifest_path, plan_path = sys.argv[1], sys.argv[2], sys.argv[3]
batch = json.load(open(batch_path, encoding='utf-8'))
manifest = json.load(open(manifest_path, encoding='utf-8'))
cars_doc = manifest.get('cars', {})

entries = batch.get('cars', {})
if isinstance(entries, list):
    entries = {c.get('slug'): c for c in entries}

# Lead/导出侧决定保留旧版的车（batch skip）
keep_old = {'hyundai_elantra', 'bmw_m4_adro_kit'}
for s in batch.get('skip', []):
    slug = s.get('slug')
    if slug:
        keep_old.add(slug)
# measured_r 偏差 >5% 的榜单（再兜一层）
dev_gt5 = {x.get('slug') for x in (batch.get('measured_r_dev_gt5pct') or []) if x.get('slug')}
keep_old |= dev_gt5

def find_car_id_by_slug(slug):
    # 优先：manifest model 文件名 == slug.glb
    if slug in cars_doc:
        return slug
    for cid, e in cars_doc.items():
        if str(e.get('model', '')) == f'{slug}.glb':
            return cid
    return None

decisions = []
for slug, info in sorted(entries.items()):
    car_id = find_car_id_by_slug(slug)
    entry = cars_doc.get(car_id, {}) if car_id else {}
    model = str(entry.get('model', '')) or f'{slug}.glb'
    status = str(info.get('status', ''))
    reasons = []
    action = 'install'
    if car_id is None:
        action = 'skip'
        reasons.append('manifest 无对应车 id')
    if slug in keep_old:
        action = 'skip'
        reasons.append('导出侧/Lead 决定保留旧版')
    if status not in ('ok',):
        action = 'skip'
        reasons.append(f'batch status={status}（Lead 规则：仅 ok 才装）')
    # 三角面与原件偏差
    tris_dev = info.get('tris_dev_pct')
    if tris_dev is not None and abs(float(tris_dev)) > 0.5:
        action = 'skip'
        reasons.append(f'tris_dev={float(tris_dev):+.2f}% (>0.5%)')
    # measured_r（轮半径）与旧模型包络偏差 >5%
    max_r_dev = info.get('max_dev_old_r_pct')
    if max_r_dev is not None and abs(float(max_r_dev)) > 5.0:
        action = 'skip'
        reasons.append(f'max_dev_old_r_pct={float(max_r_dev):+.1f}% (>5%)')
    # 轮宽偏差仅记录（Lead 规则只卡 measured_r；宽度差异写入计划供参考）
    max_w_dev = info.get('max_dev_old_w_pct')
    if max_w_dev is not None and abs(float(max_w_dev)) > 5.0:
        reasons.append(f'[记] max_dev_old_w_pct={float(max_w_dev):+.1f}%')
    # 结构/节点异常
    missing = info.get('missing_nodes') or []
    unexpected = info.get('unexpected_blend') or []
    if missing:
        action = 'skip'
        reasons.append('missing_nodes: ' + ','.join(map(str, missing)))
    if unexpected:
        action = 'skip'
        reasons.append('unexpected blend: ' + ','.join(map(str, unexpected)))
    if info.get('wheel_hierarchy_ok') is False:
        action = 'skip'
        reasons.append('wheel_hierarchy_ok=false')
    sym = info.get('wheel_symmetry_m')
    sym_max = None
    if isinstance(sym, dict):
        vals = [abs(float(x)) for x in sym.values() if isinstance(x, (int, float))]
        sym_max = max(vals) if vals else None
    elif isinstance(sym, (int, float)):
        sym_max = abs(float(sym))
    if sym_max is not None and sym_max > 0.01:
        action = 'skip'
        reasons.append(f'轮心/轮位左右不对称 {sym_max:.4f} m (>0.01)')
    ztm = info.get('zero_tri_meshes') or []
    if ztm:
        action = 'skip'
        reasons.append(f'zero_tri_meshes: {len(ztm)} 个')
    rp = os.path.join(os.path.dirname(batch_path), slug + '.glb')
    rpj = os.path.join(os.path.dirname(batch_path), slug + '.report.json')
    exists = os.path.exists(rp)
    if not exists:
        action = 'skip'
        reasons.append('staging GLB 不存在')
    size = os.path.getsize(rp) if exists else 0
    decisions.append({
        'action': action, 'car_id': car_id or slug, 'slug': slug, 'model': model,
        'target': os.path.join('assets/cars/models', model),
        'source': rp, 'report_json': rpj,
        'size': size, 'status': status, 'reasons': reasons,
        'tris': info.get('tris'), 'nodes': info.get('nodes'), 'meshes': info.get('meshes'),
        'materials': info.get('materials'),
    })

lines = []
for d in decisions:
    lines.append('\t'.join([
        d['action'], d['car_id'], d['slug'], d['model'], d['source'], str(d['size']),
        str(d['tris']), str(d['nodes']), d['status'], '; '.join(d['reasons']) if d['reasons'] else '-',
    ]))

with open(plan_path, 'a', encoding='utf-8') as f:
    f.write(f'# 共 {len(decisions)} 条：install={sum(1 for d in decisions if d["action"]=="install")} '
            f'skip={sum(1 for d in decisions if d["action"]=="skip")}\n')
    f.write('# action\tcar_id\tslug\tmodel\tsource\tsize\ttris\tnodes\tstatus\treasons\n')
    skips = batch.get('skip', [])
    if skips:
        f.write('# 导出侧保留旧版（不安装）:\n')
        for s in skips:
            f.write(f'#   - {s.get("slug")}: {s.get("status")} / {s.get("reason","")}\n')
    for d in decisions:
        f.write('\t'.join([
            d['action'], d['car_id'], d['slug'], d['model'], d['source'], str(d['size']),
            str(d['tris']), str(d['nodes']), d['status'], '; '.join(d['reasons']) if d['reasons'] else '-',
        ]) + '\n')
print('\n'.join(lines))
PY
)

INSTALLED=0
SKIPPED=0
FAILED=0
while IFS=$'\t' read -r action car_id slug model source size tris nodes status reasons; do
	[ -z "${action:-}" ] && continue
	if [ "$action" != "install" ]; then
		SKIPPED=$((SKIPPED + 1))
		echo "SKIP   $car_id ($slug): $reasons" | tee -a "$PLAN"
		continue
	fi
	target="$PROJECT/assets/cars/models/$model"
	[ -f "$source" ] || { echo "FAIL   $car_id: staging 文件消失 $source" | tee -a "$PLAN"; FAILED=$((FAILED + 1)); continue; }
	# 覆盖前备份当前项目文件（仅一次）
	if [ -f "$target" ] && [ ! -f "$OUT_DIR/pre_install/$model" ]; then
		cp "$target" "$OUT_DIR/pre_install/$model"
	fi
	if [ "$DRY" = "1" ]; then
		echo "DRY    $car_id: $source -> $target ($size bytes)" | tee -a "$PLAN"
		INSTALLED=$((INSTALLED + 1))
		continue
	fi
	if cp "$source" "$target"; then
		src_sha=$(shasum -a 256 "$source" | awk '{print $1}')
		dst_sha=$(shasum -a 256 "$target" | awk '{print $1}')
		if [ "$src_sha" = "$dst_sha" ]; then
			INSTALLED=$((INSTALLED + 1))
			echo "OK     $car_id: -> $model ($size bytes, sha256 ${src_sha:0:12}…)" | tee -a "$PLAN"
		else
			FAILED=$((FAILED + 1))
			echo "FAIL   $car_id: sha256 不一致 src=$src_sha dst=$dst_sha" | tee -a "$PLAN"
		fi
	else
		FAILED=$((FAILED + 1))
		echo "FAIL   $car_id: cp 失败" | tee -a "$PLAN"
	fi
done <<< "$DECISIONS"

echo "" | tee -a "$PLAN"
echo "INSTALL_DONE installed=$INSTALLED skipped=$SKIPPED failed=$FAILED dry_run=$DRY" | tee -a "$PLAN"
echo "计划/决策: $PLAN；被覆盖文件备份: $OUT_DIR/pre_install/"
[ "$FAILED" -eq 0 ] && exit 0 || exit 1
