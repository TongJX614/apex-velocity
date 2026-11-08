#!/bin/bash
# APEX VELOCITY · 极速巅峰 — Godot 重制版启动器
# 双击即可运行；如果 Godot 不在默认位置，会提示安装路径。
cd "$(dirname "$0")" || exit 1

GODOT="$HOME/Applications/Godot.app/Contents/MacOS/Godot"
if [ ! -x "$GODOT" ]; then
	GODOT="/Applications/Godot.app/Contents/MacOS/Godot"
fi
if [ ! -x "$GODOT" ]; then
	echo "=============================================="
	echo " 找不到 Godot 4.7.2"
	echo " 请把 Godot.app 放到 ~/Applications/ 或 /Applications/"
	echo " 下载: https://godotengine.org/download/macos/"
	echo "=============================================="
	read -n 1 -s -r -p "按任意键退出..."
	exit 1
fi

# 项目里 51 个脚本用 class_name 互相引用，注册表存在 .godot/global_script_class_cache.cfg。
# 删缓存或首次拉取项目时该文件不存在，而直接 run 不会重建它，会表现为
# 一堆 "Could not find type ..." 并停在一片空白窗口。所以缺缓存时先静默导入一次。
if [ ! -f ".godot/global_script_class_cache.cfg" ]; then
	echo "首次运行：正在建立资源与类缓存（约 3 分钟，仅此一次）……"
	"$GODOT" --headless --path "$(pwd)" --import >/dev/null 2>&1
	echo "缓存建立完成，正在启动。"
fi

# 渲染驱动按系统在项目设置里锁定：macOS = Metal（Apple GPU 原生显存管线），
# Windows / Linux = Vulkan。需要对比或排错时可用 APEX_DRIVER=vulkan 覆盖。
ARGS=(--path "$(pwd)")
if [ -n "$APEX_DRIVER" ]; then
	ARGS+=(--rendering-driver "$APEX_DRIVER")
fi
echo "APEX VELOCITY  |  $(uname -s)  |  渲染驱动：${APEX_DRIVER:-按系统自动（macOS Metal / 桌面 Vulkan）}"
exec "$GODOT" "${ARGS[@]}"
