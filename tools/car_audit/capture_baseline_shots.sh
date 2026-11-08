#!/bin/bash
# APEX VELOCITY · 极速巅峰 — 车模升级前基线截图采集
#
# 用游戏自带 --shot 模式（main.gd _parse_args）逐台车抓 garage 基线图，
# 再补 menu / race 各 2 张。顺序执行（单窗口，避免多 Godot 实例抢窗口）。
#
# 用法:
#   tools/car_audit/capture_baseline_shots.sh [输出目录]
#   默认输出 /tmp/car_baseline
#
# 可选环境变量:
#   GODOT    Godot 可执行文件路径
#   PROJECT  项目根目录
#   OUT_DIR  截图输出目录
#   TIMEOUT  单张截图看门狗秒数（默认 120）
#   EXTRAS   额外场景截图，格式 "scene:car,scene:car"（默认 menu:bmw_m3_e46_gtr,...）

set -u
GODOT="${GODOT:-/Users/tong/Applications/Godot.app/Contents/MacOS/Godot}"
PROJECT="${PROJECT:-/Users/tong/Desktop/极速巅峰}"
OUT_DIR="${1:-${OUT_DIR:-/tmp/car_baseline}}"
TIMEOUT="${TIMEOUT:-120}"
GARAGE="${GARAGE:-1}"      # 0 = 跳过硬车库截图（只补 menu/race）
TRACK="${TRACK:-}"         # race 场景追加 --track=<id>（如 coast）
EXTRAS="${EXTRAS-menu:bmw_m3_e46_gtr,menu:xiaomi_su7,race:bmw_m3_e46_gtr,race:xiaomi_su7}"

LOG_DIR="${OUT_DIR}/_logs"
SHOT_LOG="${OUT_DIR}/screenshots.log"
mkdir -p "$OUT_DIR" "$LOG_DIR"
: > "$SHOT_LOG"

cd "$PROJECT" || { echo "无法进入项目目录: $PROJECT" >&2; exit 1; }

# 从 manifest 读取车辆 id（保持名册顺序）
CARS=$(python3 - <<'PY'
import json
m = json.load(open('data/car_manifest.json'))
print(' '.join(m['cars'].keys()))
PY
)

run_godot() {
	# run_godot <logfile> <godot args...>
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
			return 124
		fi
	done
	wait "$pid"
}

shoot() {
	# shoot <scene> <car> <outfile>
	local scene="$1" car="$2" out="$3"
	local log="$LOG_DIR/${scene}_${car}.log"
	rm -f "$out"
	# 注意：macOS bash 3.2 + set -u 下空数组展开会报 unbound variable，这里用分支而非数组
	if [ "$scene" = "race" ] && [ -n "$TRACK" ]; then
		run_godot "$log" --path . --rendering-driver metal -- \
			"--shot=${out}" "--shot-scene=${scene}" "--car=${car}" "--track=${TRACK}"
	else
		run_godot "$log" --path . --rendering-driver metal -- \
			"--shot=${out}" "--shot-scene=${scene}" "--car=${car}"
	fi
	local rc=$?
	local size=0
	[ -f "$out" ] && size=$(stat -f%z "$out" 2>/dev/null || echo 0)
	local status="OK"
	[ "$rc" -ne 0 ] && status="FAIL(rc=$rc)"
	[ "$size" -eq 0 ] && status="FAIL(no-png)"
	printf '%s  %-5s %-22s %-8s %8s bytes  log=%s\n' \
		"$(date +%H:%M:%S)" "$scene" "$car" "$status" "$size" "$log" | tee -a "$SHOT_LOG"
	[ "$status" = "OK" ] && return 0 || return 1
}

fail=0
total=0
if [ "$GARAGE" = "1" ]; then
	echo "== garage 基线截图 (每台一张) ==" | tee -a "$SHOT_LOG"
	for car in $CARS; do
		total=$((total + 1))
		shoot garage "$car" "${OUT_DIR}/garage_${car}.png" || fail=$((fail + 1))
	done
else
	echo "== 跳过 garage 批次（GARAGE=0）==" | tee -a "$SHOT_LOG"
fi

echo "== 补充 menu / race 场景 ==" | tee -a "$SHOT_LOG"
IFS=',' read -r -a extra_arr <<< "$EXTRAS"
for extra in "${extra_arr[@]}"; do
	[ -z "$extra" ] && continue
	scene="${extra%%:*}"
	car="${extra##*:}"
	total=$((total + 1))
	shoot "$scene" "$car" "${OUT_DIR}/${scene}_${car}.png" || fail=$((fail + 1))
done

echo "SCREENSHOT_DONE total=${total} fail=${fail} out=${OUT_DIR}" | tee -a "$SHOT_LOG"
exit $([ "$fail" -eq 0 ] && echo 0 || echo 1)
