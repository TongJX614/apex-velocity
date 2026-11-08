extends SceneTree
## 地形 ASCII 高度图：一眼看清海陆分布与山体。
## 用法：Godot --headless --path . --script res://tools/ow_map.gd -- <zone_id> [半径m]

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var zone_id := "coast"
	var span := 2200.0
	if args.size() > 0:
		zone_id = String(args[0])
	if args.size() > 1:
		span = float(args[1])

	var ow := OpenWorld.new()
	ow.name = "OpenWorld"
	root.add_child(ow)
	ow.build()

	var c := Vector2.ZERO
	for z in OpenWorld.ZONES:
		if String(z["id"]) == zone_id:
			c = z["center"]
	print("=== %s  中心=%s  r=%.0f  跨度=±%.0f m ===" % [zone_id, str(c), c.length(), span])

	# 顶视：北(-z)在上，东(+x) 在右
	var step := span / 30.0
	var lines: Array = []
	for j in range(30, -1, -1):
		var row := ""
		for i in range(0, 31):
			var p := c + Vector2((float(i) - 15.0) * step, (float(j) - 15.0) * step)
			var h := ow.height_at(p.x, p.y)
			row += _glyph(h, ow.road_distance_at(p.x, p.y))
		lines.append(row)
	for l in lines:
		print("  " + l)
	print("  图例: ~ 深水  ≈ 浅水  . 沙滩  - 平地  : 草地  ^ 岩石  A 雪/冰  M 峰  # 建筑区  R 路")


func _glyph(h: float, rd: float) -> String:
	if rd <= 12.0:
		return "R"
	if h < -6.0:
		return "~"
	if h < 0.0:
		return "≈"
	if h < 6.0:
		return "."
	if h < 30.0:
		return "-"
	if h < 70.0:
		return ":"
	if h < 110.0:
		return "^"
	if h < 170.0:
		return "A"
	return "M"
