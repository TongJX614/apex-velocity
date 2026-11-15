#!/bin/bash
# 把按旧版 assets/ 布局解压的资产迁入 cars/ maps/ 模块目录。
# 可重复执行：目标已存在时跳过并提示。
set -e

PROJ="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJ"

move_dir() {
	local src="$1"
	local dst="$2"
	if [ -d "$src" ] && [ ! -e "$dst" ]; then
		mkdir -p "$(dirname "$dst")"
		mv "$src" "$dst"
		echo "[layout] $src → $dst"
	elif [ -d "$src" ]; then
		echo "[layout] 跳过 $src（目标 $dst 已存在）" >&2
	fi
}

move_dir assets/cars/models        cars/assets/models
move_dir assets/audio/engine       cars/audio/engine
move_dir assets/audio/bgm          maps/audio/bgm
move_dir assets/venues             maps/assets/venues
move_dir assets/buildings          maps/assets/buildings
move_dir assets/backdrops          maps/assets/backdrops
move_dir assets/thirdparty/polyhaven maps/assets/polyhaven
move_dir assets/thirdparty/city_ring maps/assets/city_ring

rmdir assets/cars assets/audio assets/thirdparty 2>/dev/null || true
echo "[layout] 完成：资产已归位到 cars/ 与 maps/"
