#!/bin/bash
# 双击启动：尾翼/车轮人工微调工具（part_tuner）
GODOT="/Users/tong/Applications/Godot.app/Contents/MacOS/Godot"
PROJ="/Users/tong/Desktop/极速巅峰"
# 类缓存缺失时先静默导入，否则调参器里 parts_library 等全局类会找不到
if [ ! -f "$PROJ/.godot/global_script_class_cache.cfg" ]; then
	echo "首次运行：正在建立资源与类缓存（约 3 分钟）……"
	"$GODOT" --headless --path "$PROJ" --import >/dev/null 2>&1
fi
"$GODOT" --path "$PROJ" res://tools/part_tuner/part_tuner.tscn "$@"
