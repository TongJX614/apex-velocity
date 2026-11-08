#!/bin/bash
# 启动 ACE68 磁轴桥接 + 游戏（macOS 双击本文件即可）
# 桥接会临时打开键盘的「模拟量上报」开关，游戏退出后自动还原。
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
PROJ="$(cd "$DIR/../../.." && pwd)"
GODOT="/Users/tong/Applications/Godot.app/Contents/MacOS/Godot"
BRIDGE_PID=""

cleanup() {
    if [ -n "$BRIDGE_PID" ] && kill -0 "$BRIDGE_PID" 2>/dev/null; then
        kill "$BRIDGE_PID" 2>/dev/null
        wait "$BRIDGE_PID" 2>/dev/null
    fi
}
trap cleanup EXIT INT TERM

if [ ! -x "$DIR/ace68_macos" ]; then
    echo "找不到 $DIR/ace68_macos，先编译："
    echo "  clang -O2 -framework IOKit -framework CoreFoundation \"$DIR/ace68_macos.c\" -o \"$DIR/ace68_macos\""
    read -r -p "按回车退出..."
    exit 1
fi

echo "== 启动 ACE68 磁轴桥接（W=线性油门 S=刹车 A/D=线性转向）=="
"$DIR/ace68_macos" --stream &
BRIDGE_PID=$!
sleep 0.8
if ! kill -0 "$BRIDGE_PID" 2>/dev/null; then
    echo "桥接启动失败（可能键盘未连接/被 M HUB 占用）。游戏仍可用普通键盘游玩。"
    read -r -p "按回车退出..."
    exit 1
fi

echo "== 启动游戏 =="
"$GODOT" --path "$PROJ" --rendering-driver metal
cleanup
echo "== 已退出，键盘模拟量开关已还原 =="
