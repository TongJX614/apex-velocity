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

export_macos() {
	mkdir -p "$PROJ/build/macos"
	echo "[导出] macOS → build/macos/APEX VELOCITY.app"
	"$GODOT" --headless --path "$PROJ" --export-release "macOS" \
		"$PROJ/build/macos/APEX VELOCITY.app"
}

export_windows() {
	mkdir -p "$PROJ/build/windows"
	echo "[导出] Windows → build/windows/APEX_VELOCITY.exe"
	"$GODOT" --headless --path "$PROJ" --export-release "Windows Desktop" \
		"$PROJ/build/windows/APEX_VELOCITY.exe"
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
		export_macos
		;;
	windows)
		ensure_templates
		export_windows
		;;
	android)
		ensure_templates
		export_android
		;;
	all)
		ensure_templates
		export_macos
		export_windows
		;;
	*)
		echo "用法: $0 [all|macos|windows|android]"
		exit 1
		;;
esac

echo "[导出] 完成。产物在 $PROJ/build/"
