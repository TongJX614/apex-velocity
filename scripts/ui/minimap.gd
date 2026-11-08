class_name Minimap
extends Control
## 商业赛车游戏风格小地图 v2：暗色内芯 + 主题色发光赛道线 + 起跑线格子 +
## 对手圆点 + 玩家方向箭头。API 保持兼容：
## setup(track_path, player_car, ai_cars) / line_color / player_color。

var track: TrackPath
var player: Car
var ais: Array = []

var line_color := UIStyle.ACCENT
var player_color := Color(1.0, 0.85, 0.25, 1.0)
var show_start_line := true
var show_glow := true
var show_grid := true


func setup(track_path: TrackPath, player_car: Car, ai_cars: Array) -> void:
	track = track_path
	player = player_car
	ais = ai_cars


func _process(_dt: float) -> void:
	queue_redraw()


func _draw() -> void:
	if track == null or track.samples.is_empty():
		_draw_placeholder()
		return
	var mn := Vector2(INF, INF)
	var mx := Vector2(-INF, -INF)
	for s in track.samples:
		var p := Vector2(s.x, s.z)
		mn = Vector2(minf(mn.x, p.x), minf(mn.y, p.y))
		mx = Vector2(maxf(mx.x, p.x), maxf(mx.y, p.y))
	var span := mx - mn
	if span.x < 0.001 or span.y < 0.001:
		return
	var pad := 18.0
	var avail := size - Vector2(pad, pad) * 2.0
	var sc := minf(avail.x / span.x, avail.y / span.y)
	var mid := (mn + mx) * 0.5
	var center := size * 0.5

	var to_map := func(world: Vector2) -> Vector2:
		return center + (world - mid) * sc

	# 背景细网格（提升「仪表」专业感）
	if show_grid:
		var grid_col := Color(0.55, 0.75, 0.85, 0.05)
		for gx in range(1, 6):
			var x := size.x * float(gx) / 6.0
			draw_line(Vector2(x, 6), Vector2(x, size.y - 6), grid_col, 1.0)
		for gy in range(1, 4):
			var y := size.y * float(gy) / 4.0
			draw_line(Vector2(6, y), Vector2(size.x - 6, y), grid_col, 1.0)

	var pts := PackedVector2Array()
	for i in track.samples.size():
		pts.append(to_map.call(Vector2(track.samples[i].x, track.samples[i].z)))
	if pts.size() < 3:
		return
	var closed := pts.duplicate()
	closed.append(pts[0])

	# 赛道：外发光 → 暗色内芯 → 主题色主线
	if show_glow:
		draw_polyline(closed, Color(line_color.r, line_color.g, line_color.b, 0.13), 12.0, true)
		draw_polyline(closed, Color(line_color.r, line_color.g, line_color.b, 0.26), 7.0, true)
	draw_polyline(closed, Color(0.012, 0.020, 0.028, 0.92), 5.0, true)
	draw_polyline(closed, Color(line_color.r, line_color.g, line_color.b, 0.95), 2.0, true)

	# 赛段刻度：均匀分布的小垂直线
	if pts.size() > 8:
		for k in range(1, 8):
			var idx := int(float(pts.size()) * float(k) / 8.0) % pts.size()
			var a: Vector2 = pts[idx]
			var b: Vector2 = pts[(idx + 1) % pts.size()]
			var dir: Vector2 = (b - a).normalized()
			var nrm := Vector2(-dir.y, dir.x)
			draw_line(a - nrm * 3.0, a + nrm * 3.0, Color(1.0, 1.0, 1.0, 0.22), 1.0, true)

	# 起跑线：黑白格子
	if show_start_line and track.samples.size() > 2:
		var s0 := track.samples[0]
		var s1 := track.samples[mini(1, track.samples.size() - 1)]
		var a: Vector2 = to_map.call(Vector2(s0.x, s0.z))
		var b: Vector2 = to_map.call(Vector2(s1.x, s1.z))
		var dir: Vector2 = (b - a).normalized()
		var nrm := Vector2(-dir.y, dir.x)
		var half := 5.0
		draw_line(a - nrm * half, a + nrm * half, Color(1, 1, 1, 0.92), 2.2, true)
		for cell in 4:
			var t0 := -half + float(cell) * (half * 2.0 / 4.0)
			var t1 := t0 + half * 2.0 / 4.0
			var c := Color(1, 1, 1, 0.85) if cell % 2 == 0 else Color(0.02, 0.05, 0.06, 0.9)
			draw_line(a + nrm * t0, a + nrm * t1, c, 2.4, true)

	# 对手：实心圆 + 深色描边 + 微光
	for ai in ais:
		if ai == null:
			continue
		var p: Vector3 = ai.pos
		var pp: Vector2 = to_map.call(Vector2(p.x, p.z))
		draw_circle(pp, 5.2, Color(0.0, 0.0, 0.0, 0.55))
		draw_circle(pp, 3.8, Color(ai.car_color, 0.96))
		draw_arc(pp, 3.8, 0.0, TAU, 16, Color(1, 1, 1, 0.35), 0.8, true)

	# 玩家：带方向箭头 + 脉冲圆环
	if player != null:
		var p: Vector3 = player.pos
		var pp: Vector2 = to_map.call(Vector2(p.x, p.z))
		var heading_deg := rad_to_deg(player.heading)
		var fwd := Vector2(sin(deg_to_rad(heading_deg)), cos(deg_to_rad(heading_deg)))
		var side := Vector2(-fwd.y, fwd.x)
		var tri := PackedVector2Array([
			pp + fwd * 8.5,
			pp - fwd * 4.6 + side * 5.2,
			pp - fwd * 4.6 - side * 5.2,
		])
		var pulse := 0.5 + 0.5 * sin(Time.get_ticks_msec() * 0.004)
		draw_circle(pp, 10.0, Color(player_color.r, player_color.g, player_color.b, 0.10 + 0.06 * pulse))
		draw_circle(pp, 7.0, Color(0.0, 0.0, 0.0, 0.45))
		draw_colored_polygon(tri, player_color)
		draw_polyline(PackedVector2Array([tri[0], tri[1], tri[2], tri[0]]),
			Color(1.0, 1.0, 1.0, 0.92), 1.2, true)


func _draw_placeholder() -> void:
	var center := size * 0.5
	var r := minf(size.x, size.y) * 0.30
	for i in 3:
		draw_arc(center, r + float(i) * 6.0, 0.0, TAU, 40,
			Color(0.55, 0.82, 0.90, 0.10 - float(i) * 0.02), 1.0, true)
	draw_line(center - Vector2(r, 0), center + Vector2(r, 0), Color(0.4, 0.7, 0.8, 0.12), 1.0)
	draw_line(center - Vector2(0, r), center + Vector2(0, r), Color(0.4, 0.7, 0.8, 0.12), 1.0)
