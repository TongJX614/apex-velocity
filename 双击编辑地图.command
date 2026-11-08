#!/bin/bash
# 场景装饰编辑器 —— 双击启动
cd "$(dirname "$0")" || exit 1

GODOT="$HOME/Applications/Godot.app/Contents/MacOS/Godot"
if [ ! -x "$GODOT" ]; then
  GODOT="/Applications/Godot.app/Contents/MacOS/Godot"
fi
if [ ! -x "$GODOT" ]; then
  echo "找不到 Godot 4，请确认已安装到「应用程序」里。"
  read -r -p "按回车退出…" _
  exit 1
fi

TRACKS=(coast city alpine canyon harbor skyline glacier magma)
NAMES=("翡翠海岸" "霓虹都市" "雪山隘口" "赤岩峡谷" "落日港湾" "天际环城" "冰川湖环道" "熔岩盆地")

echo ""
echo "  APEX / VELOCITY · 场景装饰编辑器"
echo "  ────────────────────────────────"
for i in "${!TRACKS[@]}"; do
  printf "   %d) %-6s %s\n" "$((i+1))" "${TRACKS[$i]}" "${NAMES[$i]}"
done
echo ""
read -r -p "  选择要编辑的赛道 [1-8，默认 1]: " pick
[ -z "$pick" ] && pick=1
IDX=$((pick-1))
if [ "$IDX" -lt 0 ] || [ "$IDX" -ge "${#TRACKS[@]}" ]; then IDX=0; fi

TRACK="${TRACKS[$IDX]}"
# 类缓存缺失时（首次/清过缓存）先静默导入，否则场景里所有 class_name 引用都会失效
if [ ! -f ".godot/global_script_class_cache.cfg" ]; then
  echo "  首次运行：正在建立资源与类缓存（约 3 分钟）……"
  "$GODOT" --headless --path . --import >/dev/null 2>&1
fi
echo ""
echo "  正在载入 ${NAMES[$IDX]} …"
echo ""
"$GODOT" --path . scenes/decor_editor.tscn -- --track="$TRACK"
