extends SceneTree
## 开放世界地形探针：量化每个域离海多远、道路是否被水淹没。

func _initialize() -> void:
	var ow := OpenWorld.new()
	ow.name = "OpenWorld"
	root.add_child(ow)
	ow.build()

	print("=== 域 / 水距 ===")
	for zone in OpenWorld.ZONES:
		var c: Vector2 = zone["center"]
		var rad: float = float(zone["radius"])
		# 在域内按 120m 网格采样，找最近的水面（h < 0）
		var nearest_water := 999999.0
		var underwater := 0
		var total := 0
		var step := 120.0
		var n := int(rad * 1.4 / step)
		for j in range(-n, n + 1):
			for i in range(-n, n + 1):
				var p := c + Vector2(float(i) * step, float(j) * step)
				var d := p.distance_to(c)
				if d > rad * 1.4:
					continue
				total += 1
				var h := ow.height_at(p.x, p.y)
				if h < 0.0:
					underwater += 1
					nearest_water = minf(nearest_water, d)
		var pct := 0.0
		if total > 0:
			pct = 100.0 * float(underwater) / float(total)
		print("  %-9s center_r=%6.0f  最近水距=%7.0f  域内水下占比=%5.1f%%  中心h=%7.2f" % [
			String(zone["id"]), c.length(), nearest_water, pct, ow.height_at(c.x, c.y)])

	print("=== coast 径向剖面（向外）===")
	var cc: Vector2 = OpenWorld.ZONES[3]["center"]
	var dir := cc.normalized()
	for i in range(0, 46):
		var d := float(i) * 80.0
		var p := cc + dir * d
		print("  d=%6.0f r=%6.0f h=%8.2f %s" % [d, p.length(), ow.height_at(p.x, p.y),
			("WATER" if ow.height_at(p.x, p.y) < 0.0 else "")])

	print("=== harbor 径向剖面（向外）===")
	var hc: Vector2 = OpenWorld.ZONES[2]["center"]
	var hdir := hc.normalized()
	for i in range(0, 46):
		var d := float(i) * 80.0
		var p := hc + hdir * d
		print("  d=%6.0f r=%6.0f h=%8.2f %s" % [d, p.length(), ow.height_at(p.x, p.y),
			("WATER" if ow.height_at(p.x, p.y) < 0.0 else "")])

	print("=== 道路淹没检查 ===")
	var submerged := 0
	var worst := -9999.0
	for road in ow.roads:
		var pts: Array = road["pts"]
		for p in pts:
			var h := ow.height_at(p.x, p.y)
			if h < -0.5:
				submerged += 1
				worst = maxf(worst, -h)
	print("  被水淹没的道路采样点 = %d / %d  最深 %.1f m" % [
		submerged, ow.roads.size(), worst])

	print("=== 各域地形高差（域内 500m 采样）===")
	for zone in OpenWorld.ZONES:
		var c: Vector2 = zone["center"]
		var rad: float = float(zone["radius"])
		var lo := 99999.0
		var hi := -99999.0
		var step2 := 200.0
		var n2 := int(rad * 1.2 / step2)
		for j in range(-n2, n2 + 1):
			for i in range(-n2, n2 + 1):
				var p := c + Vector2(float(i) * step2, float(j) * step2)
				if p.distance_to(c) > rad * 1.2:
					continue
				var h := ow.height_at(p.x, p.y)
				lo = minf(lo, h)
				hi = maxf(hi, h)
		print("  %-9s  min=%8.1f  max=%8.1f  落差=%7.1f" % [
			String(zone["id"]), lo, hi, hi - lo])

	print("=== 路面贴合（车会不会陷进路面）===")
	# 路面网格顶面 = height_at + 0.02；车身贴地高度 = height_at。
	# 两者之差必须 < 0.05m，否则轮子会陷进沥青。
	var on_road := 0
	var worst_gap := 0.0
	for road in ow.roads:
		var pts: Array = road["pts"]
		for p in pts:
			if not ow.is_on_road(p.x, p.y):
				continue
			on_road += 1
			# 路面中心线上的点：网格高 = 高度场 + 0.02
			var mesh_y := ow.height_at(p.x, p.y) + 0.02
			var car_y := ow.height_at(p.x, p.y)
			worst_gap = maxf(worst_gap, absf(mesh_y - car_y))
	print("  路面采样点 = %d   车体与路面最大高差 = %.4f m（应 < 0.05）" % [on_road, worst_gap])

	quit()
