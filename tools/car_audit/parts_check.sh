#!/bin/bash
# APEX VELOCITY — 配件库（车漆/轮毂/轮胎/尾翼/卡钳）实拍验证
#
# 做法：备份用户存档 user://garage.json → 按组合改该车配置 → 跑 garage 截图 → 全部跑完还原存档。
# 任何一个组合都不会写回配置（游戏 --shot 模式只读配置，不触发 save）。
#
# 用法:
#   bash tools/car_audit/parts_check.sh [OUT_DIR]
# 默认输出 /tmp/car_after/parts
# 环境变量:
#   GODOT / PROJECT     Godot 路径 / 项目根
#   OUT_DIR             输出目录（默认 /tmp/car_after/parts）
#   SAVE_FILE           用户存档路径（默认自动按 project.godot 的 config/name 定位）
#   CARS                车型（逗号分隔，默认 bmw_m3_e46_gtr,lambo_urus,buick_gl8,xiaomi_su7）
#   CFGS                组合（逗号分隔，默认 factory,paint1,paint2,wheels,tire,wing,caliper）
#   TIMEOUT             单张看门狗秒数（默认 120）
#
# 组合含义:
#   factory  = 全原厂（对照）
#   paint1   = 只改车漆 曜石黑     paint2 = 只改车漆 珍珠白
#   wheels   = wheel=2 (DISH 6)   tire   = wheel=2 + tire=2 (RACE SLICK)
#   wing     = wing=1 (GT WING)   caliper= caliper=1 (竞速黄)
#
# 重要：脚本用 trap 保证退出/中断时还原用户存档，并做 sha256 校验。

set -u
GODOT="${GODOT:-/Users/tong/Applications/Godot.app/Contents/MacOS/Godot}"
PROJECT="${PROJECT:-/Users/tong/Desktop/极速巅峰}"
OUT_DIR="${1:-${OUT_DIR:-/tmp/car_after/parts}}"
CARS="${CARS:-bmw_m3_e46_gtr,lambo_urus,buick_gl8,xiaomi_su7}"
CFGS="${CFGS:-factory,paint1,paint2,wheels,tire,wing,caliper}"
TIMEOUT="${TIMEOUT:-120}"
mkdir -p "$OUT_DIR/logs"
cd "$PROJECT" || { echo "无法进入项目: $PROJECT" >&2; exit 1; }

# ---- 定位用户存档 ----
if [ -z "${SAVE_FILE:-}" ]; then
	SAVE_FILE=$(python3 - <<'PY'
import os, re, glob
name = None
for line in open('project.godot', encoding='utf-8', errors='replace'):
    m = re.match(r'config/name="(.*)"', line.strip())
    if m:
        name = m.group(1)
        break
base = os.path.expanduser('~/Library/Application Support/Godot/app_userdata')
if name:
    p = os.path.join(base, name, 'garage.json')
    if os.path.exists(p):
        print(p); raise SystemExit
hits = glob.glob(os.path.join(base, '*', 'garage.json'))
print(hits[0] if hits else '')
PY
)
fi
if [ -z "$SAVE_FILE" ] || [ ! -f "$SAVE_FILE" ]; then
	echo "找不到用户存档 garage.json（可用 SAVE_FILE=... 指定）: $SAVE_FILE" >&2
	exit 1
fi

BACKUP="$OUT_DIR/garage.json.bak"
cp "$SAVE_FILE" "$BACKUP"
ORIG_SHA=$(shasum -a 256 "$SAVE_FILE" | awk '{print $1}')
echo "用户存档: $SAVE_FILE"
echo "备份 -> $BACKUP (sha256 ${ORIG_SHA:0:16}…)"

restore_save() {
	if [ -f "$BACKUP" ]; then
		cp "$BACKUP" "$SAVE_FILE"
		local now_sha
		now_sha=$(shasum -a 256 "$SAVE_FILE" | awk '{print $1}')
		if [ "$now_sha" = "$ORIG_SHA" ]; then
			echo "用户存档已还原并校验通过 (sha256 ${now_sha:0:16}…)"
		else
			echo "!! 用户存档还原校验不一致: $now_sha" >&2
		fi
	fi
}
trap restore_save EXIT INT TERM

# 组合 → 配置键值（python 片段用）
cfg_apply() {
	# cfg_apply <car> <cfg-name>
	python3 - "$SAVE_FILE" "$1" "$2" <<'PY'
import json, sys
save_path, car, cfgname = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(save_path, encoding='utf-8'))
cars = d.setdefault('cars', {})
c = cars.setdefault(car, {})
for k in ['paint','rim','caliper','wheel','tire','wing','livery']:
    c[k] = 0
if cfgname == 'paint1':
    c['paint'] = 1
elif cfgname == 'paint2':
    c['paint'] = 2
elif cfgname == 'wheels':
    c['wheel'] = 2
elif cfgname == 'tire':
    c['wheel'] = 2
    c['tire'] = 2
elif cfgname == 'wing':
    c['wing'] = 1
elif cfgname == 'caliper':
    c['caliper'] = 1
elif cfgname != 'factory':
    raise SystemExit('未知组合: ' + cfgname)
for k, v in [('engine', c.get('engine', 0)), ('tires', c.get('tires', 0)),
             ('aero', c.get('aero', 0)), ('nitro', c.get('nitro', 0))]:
    c[k] = v
json.dump(d, open(save_path, 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
PY
}

run_with_timeout() {
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

FAIL=0
TOTAL=0
LOG="$OUT_DIR/parts_shots.log"
: > "$LOG"
IFS=',' read -r -a car_arr <<< "$CARS"
IFS=',' read -r -a cfg_arr <<< "$CFGS"
for car in "${car_arr[@]}"; do
	[ -z "$car" ] && continue
	for cfg in "${cfg_arr[@]}"; do
		[ -z "$cfg" ] && continue
		cfg_apply "$car" "$cfg"
		out="$OUT_DIR/${car}_${cfg}.png"
		rm -f "$out"
		TOTAL=$((TOTAL + 1))
		run_with_timeout "$OUT_DIR/logs/${car}_${cfg}.log" --path . --rendering-driver metal -- \
			"--shot=$out" "--shot-scene=garage" "--car=$car"
		rc=$?
		size=0
		[ -f "$out" ] && size=$(stat -f%z "$out" 2>/dev/null || echo 0)
		status="OK"
		[ "$rc" -ne 0 ] && status="FAIL(rc=$rc)"
		[ "$size" -eq 0 ] && status="FAIL(no-png)"
		[ "$status" != "OK" ] && FAIL=$((FAIL + 1))
		printf '%s  %-18s %-9s %-8s %8s bytes\n' "$(date +%H:%M:%S)" "$car" "$cfg" "$status" "$size" | tee -a "$LOG"
	done
done

restore_save
trap - EXIT INT TERM
echo "PARTS_CHECK_DONE total=$TOTAL fail=$FAIL out=$OUT_DIR"
exit $([ "$FAIL" -eq 0 ] && echo 0 || echo 1)
