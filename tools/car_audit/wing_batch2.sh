#!/bin/bash
# 全量特写批渲染：每车 w0 原厂 + w1..w8 供体翼，特写镜头验证翼身连接
GODOT=/Users/tong/Applications/Godot.app/Contents/MacOS/Godot
PROJ=/Users/tong/Desktop/极速巅峰
OUT=/tmp/wing_audit/batch2
mkdir -p "$OUT"
ROTATED="zeekr_7x xiaomi_su7"
cars=$(cat /tmp/wing_audit/car_list.txt)
for car in $cars; do
  plus=""
  for r in $ROTATED; do
    [ "$car" = "$r" ] && plus="--closeupplus"
  done
  for w in 0 1 2 3 4 5 6 7 8; do
    img="$OUT/${car}_w${w}.png"
    [ -s "$img" ] && continue
    "$GODOT" --path "$PROJ" res://tools/car_audit/wing_check.tscn -- \
      "--car=$car" "--wing=$w" --closeup $plus "--out=$img" \
      > /dev/null 2>&1
  done
  echo "done: $car"
done
echo "ALL DONE"
