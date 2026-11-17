class_name ConeStore
extends RefCounted
## 漂移练习场的锥桶布局存档：user://cone_layout_drift.json。
## 布局为 xz 平面坐标数组 [[x, z], ...]，场地中心为原点。

const PATH := "user://cone_layout_drift.json"
const MAX_CONES := 240


static func load_layout() -> Array:
	var data: Variant = SafeJson.read_dict(PATH)
	if data is not Dictionary:
		return []
	var raw: Array = data.get("cones", [])
	var out: Array = []
	for item in raw:
		if item is Array and item.size() >= 2:
			out.append(Vector2(float(item[0]), float(item[1])))
		if out.size() >= MAX_CONES:
			break
	return out


static func save_layout(pts: Array) -> void:
	var cones: Array = []
	for p in pts:
		var v: Vector2 = p
		cones.append([snappedf(v.x, 0.01), snappedf(v.y, 0.01)])
	SafeJson.write(PATH, JSON.stringify({"cones": cones}, "\t"))


## 直线 slalom：按 spacing 桩距从 -96m 铺到 96m，绕桩穿行的经典练习列。
static func preset_slalom(spacing: float = 12.0) -> Array:
	var out: Array = []
	var step := clampf(spacing, 4.0, 40.0)
	var z := -96.0
	while z <= 96.0:
		out.append(Vector2(0.0, z))
		z += step
	return out


## 定圆：半径 25m，按 spacing 弧距换算桩数，练长弧定圆漂。
static func preset_circle(spacing: float = 12.0) -> Array:
	var out: Array = []
	var radius := 25.0
	var n := int(clampf(round(TAU * radius / clampf(spacing, 4.0, 40.0)), 8, 64))
	for i in n:
		var a := TAU * float(i) / float(n)
		out.append(Vector2(cos(a) * radius, sin(a) * radius))
	return out


## 8 字：两个半径 22m 的圆相切，按 spacing 弧距换算桩数，练换向甩尾。
static func preset_figure8(spacing: float = 12.0) -> Array:
	var out: Array = []
	var radius := 22.0
	var n := int(clampf(round(TAU * radius / clampf(spacing, 4.0, 40.0)), 8, 48))
	for center: Vector2 in [Vector2(0.0, -26.0), Vector2(0.0, 26.0)]:
		for i in n:
			var a := TAU * float(i) / float(n)
			out.append(center + Vector2(cos(a) * radius, sin(a) * radius))
	return out
