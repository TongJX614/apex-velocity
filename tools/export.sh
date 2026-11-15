#!/bin/bash
# APEX VELOCITY · 极速巅峰 — 一键导出脚本
#
#   ./tools/export.sh             导出 macOS + Windows（若模板缺失会先下载）
#   ./tools/export.sh macos       只导出 macOS
#   ./tools/export.sh windows     只导出 Windows
#   ./tools/export.sh android     导出 Android（需要先把 JDK + Android SDK 配好）
#
# Godot 版本必须与 export_presets.cfg / 工程一致：4.7.2 stable。
set -e

GODOT="${GODOT:-$HOME/Applications/Godot.app/Contents/MacOS/Godot}"
if [ ! -x "$GODOT" ]; then
	GODOT="/Applications/Godot.app/Contents/MacOS/Godot"
fi
if [ ! -x "$GODOT" ]; then
	echo "找不到 Godot 可执行文件，请设置 GODOT 环境变量指向 Godot 4.7.2"
	exit 1
fi

PROJ="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATE_VERSION="4.7.2.stable"
TPL_DIR="$HOME/Library/Application Support/Godot/export_templates/$TEMPLATE_VERSION"
TARGET="${1:-all}"

COLLISION_BIN="$PROJ/maps/assets/city_ring/city_collision.bin"
COLLISION_RES="$PROJ/maps/assets/city_ring/city_collision.res"
COLLISION_SCRIPT="$PROJ/maps/scripts/openworld/city_collision_data.gd"

ensure_templates() {
	if [ -d "$TPL_DIR" ] && [ -n "$(ls -A "$TPL_DIR" 2>/dev/null)" ]; then
		echo "[导出] 导出模板已存在：$TPL_DIR"
		return
	fi
	echo "[导出] 缺少 Godot $TEMPLATE_VERSION 导出模板，开始下载（约 1.2GB）…"
	mkdir -p "$TPL_DIR"
	TMP_ZIP="/tmp/godot_export_templates_${TEMPLATE_VERSION//./_}.tpz"
	curl -fL -o "$TMP_ZIP" \
		"https://github.com/godotengine/godot/releases/download/4.7.2-stable/Godot_v4.7.2-stable_export_templates.tpz"
	TMP_DIR="$(mktemp -d)"
	unzip -q -o "$TMP_ZIP" -d "$TMP_DIR"
	cp -R "$TMP_DIR/templates/." "$TPL_DIR/"
	rm -rf "$TMP_DIR"
	echo "[导出] 模板安装完成：$TPL_DIR"
}

bake_city_collision() {
	if [ ! -f "$COLLISION_BIN" ]; then
		echo "[导出] 错误：缺少城市碰撞源数据 $COLLISION_BIN" >&2
		exit 1
	fi
	if [ -s "$COLLISION_RES" ] && [ "$COLLISION_RES" -nt "$COLLISION_BIN" ] \
		&& [ "$COLLISION_RES" -nt "$COLLISION_SCRIPT" ]; then
		echo "[导出] 城市碰撞数据已是最新：$(basename "$COLLISION_RES")"
		return
	fi
	echo "[导出] 烘焙城市碰撞数据 → maps/assets/city_ring/city_collision.res"
	"$GODOT" --headless --path "$PROJ" res://tools/bake_city_collision.tscn
	if [ ! -s "$COLLISION_RES" ]; then
		echo "[导出] 错误：碰撞数据烘焙失败（$COLLISION_RES 缺失或为空）" >&2
		exit 1
	fi
}

verify_pck() {
	local label="$1"
	local pck="$2"
	if [ ! -f "$pck" ]; then
		echo "[导出] 错误：$label 未生成 PCK：$pck" >&2
		exit 1
	fi
	local vdir
	vdir="$(mktemp -d /tmp/apex_pck_verify.XXXXXX)"
	printf 'config_version=5\n\n[application]\n\nconfig/name="PCK Verify"\n' > "$vdir/project.godot"
	cp "$PROJ/tools/verify_pck.gd" "$vdir/verify_pck.gd"
	local ok=0
	"$GODOT" --headless --path "$vdir" --script res://verify_pck.gd -- --pck="$pck" || ok=$?
	rm -rf "$vdir"
	if [ "$ok" -ne 0 ]; then
		echo "[导出] 错误：$label 的 PCK 缺少城市碰撞数据 city_collision.res（校验码 $ok）" >&2
		exit 1
	fi
	echo "[导出] PCK 校验通过：$label 含 city_collision.res"
}

export_macos() {
	mkdir -p "$PROJ/build/macos"
	echo "[导出] macOS → build/macos/APEX VELOCITY.app"
	"$GODOT" --headless --path "$PROJ" --export-release "macOS" \
		"$PROJ/build/macos/APEX VELOCITY.app"

	# 磁轴键盘桥是非资源文件，Godot 不会自动放进 .app，必须手动内置
	local app="$PROJ/build/macos/APEX VELOCITY.app"
	local bridge_src="$PROJ/tools/analog_input/ace68/ace68_macos"
	local bridge_dst="$app/Contents/Resources/tools/analog_input/ace68/ace68_macos"
	mkdir -p "$(dirname "$bridge_dst")"
	cp "$bridge_src" "$bridge_dst"
	chmod +x "$bridge_dst"
	echo "[导出] 已内置磁轴键盘桥：tools/analog_input/ace68/ace68_macos"

	local pck
	pck="$(ls "$app"/Contents/Resources/*.pck 2>/dev/null | head -n 1)"
	verify_pck "macOS" "$pck"

	codesign --force --deep --sign - "$app"
	echo "[导出] 已 ad-hoc 签名：$app"
}

export_windows() {
	mkdir -p "$PROJ/build/windows"
	echo "[导出] Windows → build/windows/APEX_VELOCITY.exe"
	"$GODOT" --headless --path "$PROJ" --export-release "Windows Desktop" \
		"$PROJ/build/windows/APEX_VELOCITY.exe"
	verify_pck "Windows" "$PROJ/build/windows/APEX_VELOCITY.pck"
}

export_android() {
	mkdir -p "$PROJ/build/android"
	echo "[导出] Android → build/android/APEX_VELOCITY.apk"
	echo "[导出] 注意：需要已配置 JDK 17+ 与 Android SDK (Godot 编辑器设置 > 导出 > Android)"
	"$GODOT" --headless --path "$PROJ" --export-debug "Android" \
		"$PROJ/build/android/APEX_VELOCITY.apk"
}

case "$TARGET" in
	macos)
		ensure_templates
		bake_city_collision
		export_macos
		;;
	windows)
		ensure_templates
		bake_city_collision
		export_windows
		;;
	android)
		ensure_templates
		bake_city_collision
		export_android
		;;
	all)
		ensure_templates
		bake_city_collision
		export_macos
		export_windows
		;;
	*)
		echo "用法: $0 [all|macos|windows|android]"
		exit 1
		;;
esac

echo "[导出] 完成。产物在 $PROJ/build/"
