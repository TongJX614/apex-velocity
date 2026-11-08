#!/bin/bash
# APEX VELOCITY — 新车模「运行时探针」：确认 CarVisual 能挂上新层级、无脚本错误、无大量材质 fallback
#
# 三层证据，汇总写入 $OUT_DIR/runtime_errors.log：
#   1) CarVisual 场景探针（真实车库构建路径，autoload 可用）：找 4×Spin_Wheel_* / 2×前轮 Wheel_*、
#      fallback 次数、运行时车漆贴图/clearcoat、spin 纠偏量 → runtime_probe.json/.txt
#   2) 游戏 garage 场景 headless 跑一遍（每台 --quit-after 兜底防挂），采集控制台
#   3) （可选）把截图批次 $OUT_DIR/_logs/*.log 一并扫描
#
# 用法:
#   bash tools/car_audit/runtime_probe.sh [OUT_DIR]
# 环境变量:
#   GODOT / PROJECT       Godot 路径 / 项目根
#   OUT_DIR               输出目录（默认 /tmp/car_after）
#   CARS                  只跑部分车（逗号分隔，默认 manifest 全部）
#   QUIT_AFTER            headless 游戏探针的 --quit-after 帧数（默认 300）
#   TIMEOUT               单台看门狗秒数（默认 90）
#   SKIP_GAME_PROBE=1     跳过第 2 层（只跑 CarVisual 探针）
#   SCAN_SHOT_LOGS=1      追加扫描 $OUT_DIR/_logs/*.log（默认 1）

set -u
GODOT="${GODOT:-/Users/tong/Applications/Godot.app/Contents/MacOS/Godot}"
PROJECT="${PROJECT:-/Users/tong/Desktop/极速巅峰}"
OUT_DIR="${1:-${OUT_DIR:-/tmp/car_after}}"
CARS="${CARS:-}"
QUIT_AFTER="${QUIT_AFTER:-300}"
TIMEOUT="${TIMEOUT:-90}"
SKIP_GAME_PROBE="${SKIP_GAME_PROBE:-0}"
SCAN_SHOT_LOGS="${SCAN_SHOT_LOGS:-1}"

mkdir -p "$OUT_DIR/headless_probe"
cd "$PROJECT" || { echo "无法进入项目: $PROJECT" >&2; exit 1; }

if [ -z "$CARS" ]; then
	CARS=$(python3 - <<'PY'
import json
m = json.load(open('data/car_manifest.json'))
print(','.join(m['cars'].keys()))
PY
)
fi

ERROR_LOG="$OUT_DIR/runtime_errors.log"
: > "$ERROR_LOG"
echo "# APEX VELOCITY 运行时探针  $(date '+%Y-%m-%d %H:%M:%S')" >> "$ERROR_LOG"
echo "# project=$PROJECT godot=$GODOT" >> "$ERROR_LOG"
echo "# cars=$(echo "$CARS" | tr ',' '\n' | wc -l | tr -d ' ') quit_after=$QUIT_AFTER" >> "$ERROR_LOG"
echo "" >> "$ERROR_LOG"

run_with_timeout() {
	# run_with_timeout <logfile> <args...>
	local logfile="$1"; shift
	"$GODOT" "$@" > "$logfile" 2>&1 &
	local pid=$!
	local waited=0
	while kill -0 "$pid" 2>/dev/null; do
		sleep 1
		waited=$((waited + 1))
		if [ "$waited" -ge "$TIMEOUT" ]; then
			kill -9 "$pid" 2>/dev/null
			wait "$pid" 2>/dev/null
			echo "[KILLED by watchdog ${TIMEOUT}s]" >> "$logfile"
			return 124
		fi
	done
	wait "$pid"
}

# ---------------------------------------------------------------------------
# 1) CarVisual 场景探针（一次进程跑完所有车）
# ---------------------------------------------------------------------------
echo "== [1/3] CarVisual 场景探针 =="
PROBE_ARGS=(--headless --path . res://tools/car_audit/runtime_probe.tscn -- \
	"--out=${OUT_DIR}/runtime_probe.json" "--txt=${OUT_DIR}/runtime_probe.txt")
if [ -n "${ONLY_CARS_FOR_PROBE:-}" ]; then
	PROBE_ARGS+=("--cars=${ONLY_CARS_FOR_PROBE}")
fi
run_with_timeout "${OUT_DIR}/runtime_probe_console.log" "${PROBE_ARGS[@]}"
PROBE_RC=$?
echo "CarVisual 探针 exit=$PROBE_RC（0=全部 4×轮节点齐全；1=有缺失/加载失败）"

# ---------------------------------------------------------------------------
# 2) 游戏 garage 场景 headless（真实主流程 + 控制台告警）
# ---------------------------------------------------------------------------
GAME_PROBE_FAIL=0
if [ "$SKIP_GAME_PROBE" != "1" ]; then
	echo "== [2/3] 游戏 garage 场景 headless 探针（每台 --quit-after $QUIT_AFTER）=="
	IFS=',' read -r -a car_arr <<< "$CARS"
	for car in "${car_arr[@]}"; do
		[ -z "$car" ] && continue
		run_with_timeout "$OUT_DIR/headless_probe/${car}.log" \
			--headless --path . --quit-after "$QUIT_AFTER" -- \
			"--shot=$OUT_DIR/headless_probe/_${car}.png" "--shot-scene=garage" "--car=$car"
		rc=$?
		[ "$rc" -ne 0 ] && GAME_PROBE_FAIL=$((GAME_PROBE_FAIL + 1))
	done
	echo "游戏 headless 探针完成，非 0 退出/看门狗: $GAME_PROBE_FAIL 台"
fi

# ---------------------------------------------------------------------------
# 3) 汇总扫描：SCRIPT ERROR / push_error / CarVisual 告警
# ---------------------------------------------------------------------------
echo "== [3/3] 汇总扫描 =="
python3 - "$OUT_DIR" "$ERROR_LOG" "$SCAN_SHOT_LOGS" <<'PY'
import glob, os, re, sys

out_dir, error_log, scan_shots = sys.argv[1], sys.argv[2], sys.argv[3] == '1'
patterns = [
    ('SCRIPT ERROR', re.compile(r'SCRIPT ERROR')),
    ('ERROR', re.compile(r'^ERROR:')),
    ('WARNING', re.compile(r'^WARNING:')),
    ('CarVisual', re.compile(r'CarVisual')),
    ('GarageLook', re.compile(r'GarageLook')),
    ('push_error', re.compile(r'push_error')),
    ('LoadFail', re.compile(r'Failed to load|Cannot open|not found|cannot load', re.IGNORECASE)),
    ('Watchdog', re.compile(r'KILLED by watchdog')),
]
# 已知无害噪音
benign = [
    'RIDs of type "Texture" were leaked',
    'ObjectDB instances were leaked',
    'ObjectDB instances were leaked at exit',
    '运行时探针',   # 我们自己打印的报告标题
    '[RT] ',        # 探针自身输出（含 CarVisual 字样，不算告警）
    # Godot 已知无害告警：car_visual._center_spin_wheels 把轮子子节点包进 WheelRoundFix 时
    # 引擎提示 owner 不一致（游戏里每台车都会打印，不修也不影响渲染）
    "will make owner 'Model' inconsistent",
    'Consider unsetting the owner',
]
benign_hits = []
sources = []  # (label, path)
for p in sorted(glob.glob(os.path.join(out_dir, 'runtime_probe_console.log'))):
    sources.append(('CarVisual探针', p))
for p in sorted(glob.glob(os.path.join(out_dir, 'headless_probe', '*.log'))):
    sources.append(('游戏headless', p))
if scan_shots:
    for p in sorted(glob.glob(os.path.join(out_dir, '_logs', '*.log'))):
        sources.append(('车库截图', p))

hits = []
per_car = {}
for label, p in sources:
    name = os.path.basename(p).replace('.log', '')
    try:
        lines = open(p, 'r', errors='replace').read().splitlines()
    except OSError:
        continue
    for ln in lines:
        if any(b in ln for b in benign):
            benign_hits.append((label, name, ln.strip()[:200]))
            continue
        for tag, rx in patterns:
            if rx.search(ln):
                hits.append((label, name, tag, ln.strip()[:300]))
                per_car.setdefault(name, []).append(tag)
                break

# 探针 JSON 的失败/异常车
probe_fail = []
probe_wheels_bad = []
probe_fallback = []
try:
    import json
    prob = json.load(open(os.path.join(out_dir, 'runtime_probe.json')))
    probe_fail = [c for c, r in prob.get('cars', {}).items() if not r.get('loaded')]
    probe_wheels_bad = prob.get('summary', {}).get('wheels_bad', [])
    probe_fallback = prob.get('summary', {}).get('fallback_cars', [])
except Exception as e:
    print(f'[scan] warn: 无法读取 runtime_probe.json: {e}')

with open(error_log, 'a') as f:
    f.write('## 扫描结果\n\n')
    f.write(f'- 扫描日志文件数: {len(sources)}\n')
    f.write(f'- 匹配告警行数: {len(hits)}\n')
    f.write(f'- CarVisual 探针加载失败车: {probe_fail if probe_fail else "无"}\n')
    f.write(f'- CarVisual 探针轮节点缺失车: {probe_wheels_bad if probe_wheels_bad else "无"}\n')
    f.write(f'- 材质 fallback 触发车: {probe_fallback if probe_fallback else "无"}\n')
    f.write(f'- 已知无害告警行数（如 WheelRoundFix owner 提示）: {len(benign_hits)}\n\n')
    if benign_hits:
        f.write('### 已知无害告警（不计入失败）\n\n')
        uniq = sorted({h[2] for h in benign_hits})
        for u in uniq[:10]:
            f.write(f'- {u}\n')
        f.write('\n')
    if hits:
        f.write('| 来源 | 日志 | 类型 | 内容 |\n|---|---|---|---|\n')
        for label, name, tag, ln in hits:
            f.write(f'| {label} | `{name}` | {tag} | {ln.replace(chr(124), "/")} |\n')
    else:
        f.write('未发现 SCRIPT ERROR / ERROR / CarVisual 告警。\n')

print(f'[scan] 日志 {len(sources)} 个，告警 {len(hits)} 行，已知无害 {len(benign_hits)} 行 -> {error_log}')
print(f'[scan] 探针加载失败={len(probe_fail)} 轮节点缺失={len(probe_wheels_bad)} fallback车辆={len(probe_fallback)}')
sys.exit(1 if (hits or probe_fail or probe_wheels_bad) else 0)
PY
SCAN_RC=$?

echo ""
echo "RUNTIME_PROBE_DONE probe_rc=$PROBE_RC scan_rc=$SCAN_RC game_probe_fail=$GAME_PROBE_FAIL out=$OUT_DIR"
echo "  - runtime_probe.json / runtime_probe.txt / runtime_probe_console.log"
echo "  - wheel_roll_check.txt / wheel_steer_check.txt / parts_check.txt （对应验收项 2/3/4）"
echo "  - runtime_errors.log （汇总告警，给 report.md 引用）"
exit $([ "$PROBE_RC" -eq 0 ] && [ "$SCAN_RC" -eq 0 ] && echo 0 || echo 1)
