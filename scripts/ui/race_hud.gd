class_name RaceHUD
extends CanvasLayer
## 商业赛车游戏风格比赛 HUD v2（优先保证信息可读性）。
##   · 左上：赛道/模式/相机 信息牌 + 紧凑计时条   · 顶部正中：赛段小地图
##   · 右上：巨大的名次数字 P4
##   · 右下：紧凑仪表卡（小转速环 + 速度 + 档位 + 换挡灯 + 油门/刹车 + 氮气）
##   · 中央：3-2-1-GO 发令、超车提示、尾流提示、最终圈提示
##   · 结算：完整比赛结果面板（名次 / 时间 / 纪录 / 奖牌）
## 对外 API 完全保持：refresh(race, car, path) / bind_race / show_results /
## hide_results / set_camera_name，以及现有公开字段。

var time_label: Label
var lap_label: Label
var lap_time_label: Label
var position_label: Label
var track_label: Label
var mode_label: Label
var speed_gauge: Gauge
var tach_gauge: Gauge
var gear_panel: Panel
var gear_label: Label
var gear_caption: Label
var hint_label: Label
var countdown_label: Label
var toast_label: Label
var camera_label: Label
var minimap: Minimap
var continent_map: ContinentMap

var results_root: Control
var results_title: Label
var results_subtitle: Label
var results_rows: VBoxContainer
var results_records: Label
var results_hint: Label

var _prev_position := 0
var _toast_timer := 0.0
var camera_name := "追尾"
var ghost_delta := NAN

var _accent := UIStyle.ACCENT
var _track_accent := UIStyle.ACCENT
var _track_plate: Control
var _timing_panel: Control
var _position_panel: Control
var _map_panel: Panel
var _map_header: Label
var _cluster: Control
var _speed_label: Label
var _speed_unit: Label
var _rpm_label: Label
var _rpm_value: Label
var _rpm_caption: Label
var _gear_name: Label
var _position_total: Label
var _final_lap: Label
var _fps_label: Label
var _nitro_bar: UIBar
var _nitro_label: Label
var _nitro_badge: Label
var _thr_bar: UIBar
var _brk_bar: UIBar
var _shift_lights: ShiftLights
var _shift_hint: Label
var _slip_label: Label
var _position_caption: Label
var _drift_panel: Panel
var _drift_caption: Label
var _drift_score_label: Label
var _drift_combo_label: Label
var _drift_total_label: Label
var _drift_bar: UIBar
var _drift_prev_combo := 1
var _shift_slot := 0
var _last_countdown := ""
var _vignette: TextureRect
var _results_panel: Control
var _result_stat_values: Array[Label] = []
var _result_medal_label: Label
var _duel_panel: Panel
var _duel_label: Label
var _duel_mode := false
var _duel_other: Car

# ── 开放世界（无界大陆）模式 ──
# 开放世界同样是一条赛道：左上信息牌、计时条、右下仪表卡、底部提示
# 全部复用赛道那套控件，只是内容换成自由漫游。
# 唯一独有的是右上角的「无界大陆」全域图，其余一律与前八条赛道保持一致。
var _open_world_mode := false
var _ow_world: OpenWorld = null
var _ow_car: Car = null
var _ow_time := 0.0
var _ow_distance := 0.0
var _ow_last_pos := Vector3.ZERO
var _ow_zone_id := ""
var _ow_accent := UIStyle.ACCENT
var _ow_toast_timer := 0.0
var _continent_panel: Panel
var _continent_header: Label


## 换挡灯条：一个 Control 内绘制 8 段发光块，避免每帧重建大量节点。
class ShiftLights:
	extends Control
	var count := 8
	var lit := 0
	var hot_blink := 1.0
	var levels: Array[Color] = []

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func update_state(lit_count: int, blink: float) -> void:
		if lit == lit_count and absf(blink - hot_blink) < 0.02:
			return
		lit = lit_count
		hot_blink = blink
		queue_redraw()

	func _draw() -> void:
		if count <= 0:
			return
		var gap := 4.0
		var seg_w := (size.x - gap * float(count - 1)) / float(count)
		for i in count:
			var x := float(i) * (seg_w + gap)
			var rect := Rect2(x, 0.0, seg_w, size.y)
			if i < lit:
				var col := UIStyle.GREEN
				if i >= count - 2:
					col = UIStyle.RED
				elif i >= count - 4:
					col = UIStyle.GOLD
				var alpha := 1.0
				if i >= count - 2 and hot_blink < 0.98:
					alpha = maxf(hot_blink, 0.35)
				draw_rect(Rect2(x - 1.0, -2.0, seg_w + 2.0, size.y + 4.0),
					Color(col.r, col.g, col.b, 0.16 * alpha))
				draw_rect(rect, Color(col.r, col.g, col.b, alpha))
				draw_rect(Rect2(x, 0.0, seg_w, maxf(size.y * 0.4, 1.0)),
					Color(1.0, 1.0, 1.0, 0.22 * alpha))
			else:
				draw_rect(rect, Color(0.075, 0.100, 0.125, 0.92))
				draw_rect(Rect2(x, 0.0, seg_w, 1.0), Color(0.55, 0.70, 0.80, 0.12))


## 无界大陆全域图（开放世界右上角）。
## 世界轮廓与路网在 setup 时一次性烘焙成 256×256 贴图，运行时只叠
## 一个玩家箭头和一根比例尺，每帧开销可以忽略。
class ContinentMap:
	extends Control
	const MAP_RES := 256

	var world: OpenWorld = null
	var car: Car = null
	var _tex: ImageTexture = null

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func setup(world_node: OpenWorld, player: Car) -> void:
		world = world_node
		car = player
		_bake()
		queue_redraw()

	func _bake() -> void:
		if world == null:
			return
		var img := Image.create(MAP_RES, MAP_RES, false, Image.FORMAT_RGBA8)
		img.fill(Color(0.05, 0.08, 0.11, 1.0))
		var half := OpenWorld.HALF
		for j in MAP_RES:
			for i in MAP_RES:
				var wx := -half + (float(i) + 0.5) / float(MAP_RES) * OpenWorld.WORLD_SIZE
				var wz := -half + (float(j) + 0.5) / float(MAP_RES) * OpenWorld.WORLD_SIZE
				var h := world.height_at(wx, wz)
				var c := Color(0.04, 0.07, 0.10, 1.0)
				if h > 0.4:
					var z: Dictionary = world.zone_at(wx, wz)
					c = Color(0.16, 0.22, 0.20, 1.0)
					if not z.is_empty():
						c = UIStyle.accent_from(z.get("accent", "#55e7d2"), Color(0.4, 0.5, 0.5))
						c = c.darkened(0.42)
					if h > 130.0:
						c = c.lerp(Color(0.92, 0.95, 1.0), 0.55)
				elif h > -3.0:
					c = Color(0.16, 0.20, 0.17, 1.0)
				img.set_pixel(i, j, c)
		# 路网：路面比地面亮一档，八条辐射主干道一眼就能认出来
		for road in world.roads:
			var pts: Array = road["pts"]
			var prev := Vector2i.ZERO
			for k in pts.size():
				var p: Vector2 = pts[k]
				var ip := Vector2i(int((p.x + half) / OpenWorld.WORLD_SIZE * float(MAP_RES)),
					int((p.y + half) / OpenWorld.WORLD_SIZE * float(MAP_RES)))
				ip.x = clampi(ip.x, 0, MAP_RES - 1)
				ip.y = clampi(ip.y, 0, MAP_RES - 1)
				if k > 0:
					_draw_line_px(img, prev, ip, Color(0.88, 0.84, 0.62, 1.0))
				prev = ip
		_tex = ImageTexture.create_from_image(img)

	static func _draw_line_px(img: Image, a: Vector2i, b: Vector2i, color: Color) -> void:
		var dx := absi(b.x - a.x)
		var dy := absi(b.y - a.y)
		var sx := 1 if a.x < b.x else -1
		var sy := 1 if a.y < b.y else -1
		var err := dx - dy
		var x := a.x
		var y := a.y
		while true:
			if x >= 0 and x < MAP_RES and y >= 0 and y < MAP_RES:
				img.set_pixel(x, y, color)
			if x == b.x and y == b.y:
				break
			var e2 := err * 2
			if e2 > -dy:
				err -= dy
				x += sx
			if e2 < dx:
				err += dx
				y += sy

	func _draw() -> void:
		if _tex == null:
			return
		var side := minf(size.x, size.y)
		var off := Vector2((size.x - side) * 0.5, (size.y - side) * 0.5)
		draw_texture_rect(_tex, Rect2(off, Vector2(side, side)), false)
		# 比例尺：1 km
		var bar_px := 1000.0 / OpenWorld.WORLD_SIZE * side
		var bar_y := off.y + side - 16.0
		var bar_x := off.x + 10.0
		var bar_col := Color(0.95, 0.98, 1.0, 0.75)
		draw_rect(Rect2(bar_x, bar_y, bar_px, 3), bar_col)
		draw_rect(Rect2(bar_x, bar_y, 1.5, 8), bar_col)
		draw_rect(Rect2(bar_x + bar_px - 1.5, bar_y, 1.5, 8), bar_col)
		if car == null:
			return
		# 玩家箭头：跟着车头方向转（地图 x → 世界 x，地图 y → 世界 z）
		var half := OpenWorld.HALF
		var cx := off.x + (car.pos.x + half) / OpenWorld.WORLD_SIZE * side
		var cy := off.y + (car.pos.z + half) / OpenWorld.WORLD_SIZE * side
		var a := car.heading - PI
		var base := [
			Vector2(0.0, -7.0), Vector2(-5.0, 5.0),
			Vector2(0.0, 2.0), Vector2(5.0, 5.0),
		]
		var pts := PackedVector2Array()
		for b in base:
			pts.append(Vector2(cx, cy) + Vector2(
				b.x * cos(a) + b.y * sin(a),
				-b.x * sin(a) + b.y * cos(a)))
		draw_colored_polygon(pts, Color(1.0, 0.86, 0.30, 1.0))
		draw_polyline(PackedVector2Array([pts[0], pts[1], pts[2], pts[3], pts[0]]),
			Color(0.05, 0.07, 0.10, 0.9), 1.2)


func _ready() -> void:
	layer = 10
	_vignette = TextureRect.new()
	_vignette.name = "Vignette"
	_vignette.texture = UIStyle.vignette_texture(Vector2(0.5, 0.5), 0.70, 0.30)
	_vignette.set_anchors_preset(Control.PRESET_FULL_RECT)
	_vignette.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_vignette.stretch_mode = TextureRect.STRETCH_SCALE
	_vignette.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_vignette)

	var root := Control.new()
	root.name = "Root"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UIStyle.apply_theme(root)
	add_child(root)

	_build_track_plate(root)
	_build_timing(root)
	_build_position(root)
	_build_minimap(root)
	_build_continent(root)
	_build_cluster(root)
	_build_drift_card(root)
	_build_overlays(root)
	_build_duel(root)
	_build_results(root)
	_animate_minimap_entrance()
	hide_results()
	_apply_visibility()
	Settings.changed.connect(_apply_visibility)


# ---------------------------------------------------------------------------
# 构建
# ---------------------------------------------------------------------------

## 顶部小地图入场：从屏幕上方浮下来 + 淡入（每场比赛开始时一次）。
func _animate_minimap_entrance() -> void:
	if _map_panel == null:
		return
	var rest_top := _map_panel.offset_top
	var rest_bottom := _map_panel.offset_bottom
	_map_panel.offset_top = rest_top - 140.0
	_map_panel.offset_bottom = rest_bottom - 140.0
	_map_panel.modulate.a = 0.0
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(_map_panel, "offset_top", rest_top, 0.55) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(_map_panel, "offset_bottom", rest_bottom, 0.55) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(_map_panel, "modulate:a", 1.0, 0.38) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)

func _build_duel(root: Control) -> void:
	_duel_panel = Panel.new()
	_duel_panel.add_theme_stylebox_override("panel",
		UIStyle.glass_style(UIStyle.ACCENT, 0.72, UIStyle.R_MD, 0.30))
	UIStyle.place(_duel_panel, 0.5, 0, 0.5, 0, -250, 198, 250, 236)
	_duel_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_duel_panel.visible = false
	root.add_child(_duel_panel)
	_duel_label = UIStyle.label("", 13, UIStyle.TXT, HORIZONTAL_ALIGNMENT_CENTER)
	_duel_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_duel_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_duel_panel.add_child(_duel_label)


## 计时赛幽灵差距（秒）：负数 = 领先幽灵。NAN 表示隐藏。
func set_ghost_delta(value: float) -> void:
	ghost_delta = value


func bind_duel(other: Car) -> void:
	_duel_mode = true
	_duel_other = other
	if _duel_panel != null:
		_duel_panel.visible = true
		_duel_label.text = "本地双人  ·  P1 方向键 / Shift 氮气     P2 WASD / L 氮气"


func update_duel(p1_laps: int, p2_laps: int, p2_kph: float, winner: String) -> void:
	if not _duel_mode or _duel_label == null:
		return
	var w := ""
	if winner != "":
		w = "   ·   胜者 %s" % winner
	_duel_label.text = "P1  L%d      P2  L%d      P2 %d km/h%s" % [p1_laps, p2_laps, int(round(p2_kph)), w]
	_duel_label.add_theme_color_override("font_color", Color(1.0, 0.78, 0.35, 1.0) if winner != "" else UIStyle.TXT)


func show_duel_result(winner: String, p1_time: float, p2_time: float) -> void:
	if not _duel_mode:
		return
	var line := "本地双人  ·  胜者 %s" % winner
	if p1_time > 0.0:
		line += "      P1 %s" % RaceManager.format_time(p1_time)
	if p2_time > 0.0:
		line += "      P2 %s" % RaceManager.format_time(p2_time)
	if results_records != null:
		results_records.text = (results_records.text + "        " + line) if not results_records.text.is_empty() else line


func _build_track_plate(root: Control) -> void:
	_track_plate = Control.new()
	UIStyle.place(_track_plate, 0, 0, 0, 0, 0, 0, 580, 140)
	_track_plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_track_plate)

	var shade := TextureRect.new()
	shade.texture = UIStyle.gradient_texture(Color(0.0, 0.0, 0.0, 0.58), Color(0.0, 0.0, 0.0, 0.0))
	shade.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	shade.stretch_mode = TextureRect.STRETCH_SCALE
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_track_plate.add_child(shade)

	var bar := ColorRect.new()
	bar.color = UIStyle.ACCENT
	UIStyle.place(bar, 0, 0, 0, 0, 26, 18, 29, 92)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_track_plate.add_child(bar)
	_track_plate.set_meta("accent_bar", bar)

	var kicker := UIStyle.label_tracked("APEX VELOCITY   /   RACE CONTROL", 8,
		UIStyle.a(UIStyle.ACCENT, 0.85), HORIZONTAL_ALIGNMENT_LEFT, 2)
	UIStyle.place(kicker, 0, 0, 0, 0, 40, 12, 552, 28)
	_track_plate.add_child(kicker)

	track_label = UIStyle.label_display("", 23, UIStyle.TXT,
		HORIZONTAL_ALIGNMENT_LEFT, 1)
	track_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.62))
	track_label.add_theme_constant_override("outline_size", 3)
	UIStyle.place(track_label, 0, 0, 0, 0, 40, 28, 552, 64)
	_track_plate.add_child(track_label)

	mode_label = UIStyle.label("", 10, Color(0.74, 0.86, 0.92, 1.0))
	UIStyle.place(mode_label, 0, 0, 0, 0, 41, 64, 552, 82)
	_track_plate.add_child(mode_label)

	camera_label = UIStyle.label("", 9, Color(0.60, 0.72, 0.81, 1.0))
	UIStyle.place(camera_label, 0, 0, 0, 0, 41, 86, 552, 102)
	_track_plate.add_child(camera_label)

	_fps_label = UIStyle.label("", 9, Color(0.50, 0.88, 0.70, 1.0))
	UIStyle.place(_fps_label, 0, 0, 0, 0, 41, 106, 300, 122)
	_track_plate.add_child(_fps_label)


func _build_timing(root: Control) -> void:
	_timing_panel = Control.new()
	# 紧凑计时条：放到左上信息牌下面（小地图移到顶部正中）
	UIStyle.place(_timing_panel, 0, 0, 0, 0, 26, 130, 386, 222)
	_timing_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_timing_panel)

	var bg := Panel.new()
	bg.add_theme_stylebox_override("panel",
		UIStyle.glass_style(UIStyle.ACCENT, 0.70, UIStyle.R_MD, 0.24))
	UIStyle.place(bg, 0, 0, 1, 1, 0, 0, 0, 0)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_timing_panel.add_child(bg)
	UIStyle.add_top_glow(bg, UIStyle.ACCENT, 0.9)

	time_label = UIStyle.label_tech("00:00.000", 28, UIStyle.TXT,
		HORIZONTAL_ALIGNMENT_LEFT, 0)
	time_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.55))
	time_label.add_theme_constant_override("outline_size", 3)
	UIStyle.place(time_label, 0, 0, 0, 0, 14, 4, 250, 40)
	_timing_panel.add_child(time_label)

	lap_label = UIStyle.label_tech("LAP 1/3", 13, UIStyle.GOLD, HORIZONTAL_ALIGNMENT_RIGHT, 1)
	UIStyle.place(lap_label, 0, 0, 1, 0, 0, 12, -14, 34)
	_timing_panel.add_child(lap_label)

	lap_time_label = UIStyle.label("", 8, Color(0.72, 0.82, 0.89, 1.0), HORIZONTAL_ALIGNMENT_LEFT)
	UIStyle.place(lap_time_label, 0, 0, 1, 0, 14, 44, -14, 58)
	_timing_panel.add_child(lap_time_label)

	var rule := ColorRect.new()
	rule.color = Color(0.55, 0.70, 0.80, 0.14)
	UIStyle.place(rule, 0, 0, 1, 0, 14, 62, -14, 63)
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_timing_panel.add_child(rule)

	_final_lap = UIStyle.label_tracked("FINAL LAP   ·   最终圈", 10, UIStyle.GOLD,
		HORIZONTAL_ALIGNMENT_CENTER, 2)
	_final_lap.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	_final_lap.add_theme_constant_override("outline_size", 4)
	UIStyle.place(_final_lap, 0, 0, 0, 0, 26, 230, 386, 252)
	_final_lap.visible = false
	root.add_child(_final_lap)


func _build_position(root: Control) -> void:
	_position_panel = Control.new()
	UIStyle.place(_position_panel, 1, 0, 1, 0, -340, 8, -28, 140)
	_position_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_position_panel)

	var shade := TextureRect.new()
	shade.texture = UIStyle.gradient_texture(Color(0.0, 0.0, 0.0, 0.40), Color(0.0, 0.0, 0.0, 0.0))
	shade.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	shade.stretch_mode = TextureRect.STRETCH_SCALE
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_position_panel.add_child(shade)

	_position_caption = UIStyle.label_tracked("POSITION   /   名次", 9,
		Color(0.68, 0.84, 0.90, 0.95), HORIZONTAL_ALIGNMENT_RIGHT, 2)
	UIStyle.place(_position_caption, 0, 0, 1, 0, 0, 2, 0, 22)
	_position_panel.add_child(_position_caption)

	position_label = UIStyle.label_tech("P1", 64, UIStyle.GOLD, HORIZONTAL_ALIGNMENT_RIGHT, 1)
	position_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.6))
	position_label.add_theme_constant_override("outline_size", 5)
	UIStyle.place(position_label, 0, 0, 1, 0, 0, 14, 0, 94)
	_position_panel.add_child(position_label)

	_position_total = UIStyle.label_tech("/ 4", 16, Color(0.78, 0.87, 0.93, 1.0),
		HORIZONTAL_ALIGNMENT_RIGHT)
	UIStyle.place(_position_total, 0, 0, 1, 0, 0, 94, 0, 116)
	_position_panel.add_child(_position_total)

	var line := ColorRect.new()
	line.color = UIStyle.a(UIStyle.ACCENT, 0.45)
	UIStyle.place(line, 1, 0, 1, 0, -120, 118, 0, 119)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_position_panel.add_child(line)


func _build_minimap(root: Control) -> void:
	_map_panel = Panel.new()
	_map_panel.add_theme_stylebox_override("panel",
		UIStyle.glass_style(UIStyle.ACCENT, 0.72, UIStyle.R_MD, 0.26))
	UIStyle.place(_map_panel, 0.5, 0, 0.5, 0, -190, 8, 190, 210)
	_map_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_map_panel)
	UIStyle.add_top_glow(_map_panel, UIStyle.ACCENT, 0.8)

	_map_header = UIStyle.label_tracked("SECTOR MAP   ·   CIRCUIT", 9,
		Color(0.70, 0.88, 0.94, 0.95), HORIZONTAL_ALIGNMENT_LEFT, 2)
	UIStyle.place(_map_header, 0, 0, 1, 0, 14, 8, -14, 26)
	_map_panel.add_child(_map_header)

	minimap = Minimap.new()
	minimap.name = "Minimap"
	minimap.set_anchors_preset(Control.PRESET_FULL_RECT)
	minimap.offset_left = 12
	minimap.offset_top = 30
	minimap.offset_right = -12
	minimap.offset_bottom = -12
	minimap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_map_panel.add_child(minimap)


## 右上角：无界大陆全域图（只有开放世界用得上，默认隐藏）。
## 位置沿用原来开放世界 HUD 的右上角，视觉样式与 _map_panel 完全一致。
func _build_continent(root: Control) -> void:
	_continent_panel = Panel.new()
	_continent_panel.name = "ContinentPanel"
	_continent_panel.add_theme_stylebox_override("panel",
		UIStyle.glass_style(UIStyle.ACCENT, 0.72, UIStyle.R_MD, 0.26))
	UIStyle.place(_continent_panel, 1, 0, 1, 0, -286, 8, -26, 286)
	_continent_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_continent_panel.visible = false
	root.add_child(_continent_panel)
	UIStyle.add_top_glow(_continent_panel, UIStyle.ACCENT, 0.8)

	_continent_header = UIStyle.label_tracked("CONTINENT MAP   ·   无界大陆", 9,
		Color(0.70, 0.88, 0.94, 0.95), HORIZONTAL_ALIGNMENT_LEFT, 2)
	UIStyle.place(_continent_header, 0, 0, 1, 0, 14, 8, -14, 26)
	_continent_panel.add_child(_continent_header)

	continent_map = ContinentMap.new()
	continent_map.name = "ContinentMap"
	continent_map.set_anchors_preset(Control.PRESET_FULL_RECT)
	continent_map.offset_left = 12
	continent_map.offset_top = 30
	continent_map.offset_right = -12
	continent_map.offset_bottom = -12
	continent_map.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_continent_panel.add_child(continent_map)


func _build_cluster(root: Control) -> void:
	# 紧凑仪表组：右下角一张小玻璃卡（432×196），信息密度高但不抢画面。
	_cluster = Control.new()
	UIStyle.place(_cluster, 1, 1, 1, 1, -454, -218, -22, -22)
	_cluster.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_cluster)

	var panel := Panel.new()
	panel.name = "ClusterPanel"
	panel.add_theme_stylebox_override("panel",
		UIStyle.glass_style(UIStyle.ACCENT, 0.80, UIStyle.R_LG, 0.22))
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cluster.add_child(panel)
	var top_line := ColorRect.new()
	top_line.color = Color(0.333, 0.906, 0.824, 0.20)
	UIStyle.place(top_line, 0, 0, 1, 0, 16, 0, -16, 1)
	top_line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cluster.add_child(top_line)

	# 换挡灯（8 段小灯）+ 换挡提示
	_shift_lights = ShiftLights.new()
	_shift_lights.name = "ShiftLights"
	UIStyle.place(_shift_lights, 0, 0, 0, 0, 18, 16, 168, 24)
	_cluster.add_child(_shift_lights)
	_shift_hint = UIStyle.label_display("", 10, UIStyle.GOLD, HORIZONTAL_ALIGNMENT_RIGHT, 0)
	_shift_hint.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	_shift_hint.add_theme_constant_override("outline_size", 3)
	UIStyle.place(_shift_hint, 0, 0, 1, 0, 176, 8, -16, 26)
	_cluster.add_child(_shift_hint)

	# 小转速环（无刻度数字/小刻度，只保留数值弧和指针）
	tach_gauge = Gauge.new()
	tach_gauge.name = "TachGauge"
	tach_gauge.setup(Gauge.Kind.RPM, 8000.0, 1000.0)
	tach_gauge.custom_minimum_size = Vector2.ZERO
	tach_gauge.redline_from = 7000.0
	tach_gauge.unit_text = ""
	tach_gauge.show_numbers = false
	tach_gauge.show_minor = false
	tach_gauge.accent = UIStyle.ACCENT
	tach_gauge.needle_color = Color(1.0, 0.45, 0.24)
	# 表盘接近不透明：护栏立柱/广告牌透过玻璃卡时会把指针和刻度切碎。
	tach_gauge.dial_face = Color(0.02, 0.03, 0.045, 0.90)
	UIStyle.place(tach_gauge, 0, 0, 0, 0, 16, 40, 134, 158)
	_cluster.add_child(tach_gauge)
	_rpm_value = UIStyle.label_tech("", 17, UIStyle.TXT, HORIZONTAL_ALIGNMENT_CENTER)
	_rpm_value.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.5))
	_rpm_value.add_theme_constant_override("outline_size", 3)
	UIStyle.place(_rpm_value, 0, 0, 0, 0, 16, 100, 134, 122)
	_cluster.add_child(_rpm_value)
	_rpm_caption = UIStyle.label_tracked("RPM", 7, Color(0.62, 0.76, 0.86, 0.95),
		HORIZONTAL_ALIGNMENT_CENTER, 2)
	UIStyle.place(_rpm_caption, 0, 0, 0, 0, 16, 122, 134, 134)
	_cluster.add_child(_rpm_caption)
	_rpm_label = UIStyle.label_tech("", 8, Color(0.60, 0.73, 0.82, 0.9), HORIZONTAL_ALIGNMENT_CENTER)
	UIStyle.place(_rpm_label, 0, 0, 0, 0, 10, 160, 140, 174)
	_cluster.add_child(_rpm_label)

	var divider := ColorRect.new()
	divider.color = Color(0.333, 0.906, 0.824, 0.12)
	UIStyle.place(divider, 0, 0, 0, 1, 146, 40, 147, -22)
	divider.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cluster.add_child(divider)

	# 速度（大数字 + 单位）
	_speed_label = UIStyle.label_tech("0", 76, UIStyle.TXT, HORIZONTAL_ALIGNMENT_LEFT, 0)
	_speed_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.55))
	_speed_label.add_theme_constant_override("outline_size", 5)
	UIStyle.place(_speed_label, 0, 0, 0, 0, 158, 10, 282, 96)
	_cluster.add_child(_speed_label)
	_speed_unit = UIStyle.label_tracked("KM/H", 10, Color(0.72, 0.86, 0.94, 1.0),
		HORIZONTAL_ALIGNMENT_LEFT, 2)
	UIStyle.place(_speed_unit, 0, 0, 0, 0, 160, 96, 260, 110)
	_cluster.add_child(_speed_unit)

	# 档位（金色小胶囊）
	gear_panel = Panel.new()
	gear_panel.name = "GearPanel"
	gear_panel.add_theme_stylebox_override("panel",
		UIStyle.glass_style(UIStyle.GOLD, 0.62, UIStyle.R_MD, 0.34))
	UIStyle.place(gear_panel, 0, 0, 0, 0, 290, 26, 348, 88)
	gear_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cluster.add_child(gear_panel)
	_gear_name = UIStyle.label_tech("N", 32, UIStyle.GOLD, HORIZONTAL_ALIGNMENT_CENTER)
	UIStyle.place(_gear_name, 0, 0, 1, 0, 0, 6, 0, 48)
	gear_panel.add_child(_gear_name)
	gear_caption = UIStyle.label("", 8, Color(0.66, 0.79, 0.88, 0.95), HORIZONTAL_ALIGNMENT_LEFT)
	UIStyle.place(gear_caption, 0, 0, 0, 0, 290, 90, 414, 104)
	_cluster.add_child(gear_caption)
	gear_label = _gear_name

	# 油门 / 刹车（细条）
	var pedals := VBoxContainer.new()
	pedals.add_theme_constant_override("separation", 5)
	UIStyle.place(pedals, 0, 0, 1, 0, 158, 116, -14, 150)
	_cluster.add_child(pedals)
	_thr_bar = _pedal_bar(pedals, "THR", UIStyle.GREEN)
	_brk_bar = _pedal_bar(pedals, "BRK", UIStyle.RED)

	# 氮气（同一行：标签 + 细条）
	var nitro_row := HBoxContainer.new()
	nitro_row.add_theme_constant_override("separation", 6)
	UIStyle.place(nitro_row, 0, 0, 1, 0, 158, 156, -14, 174)
	_cluster.add_child(nitro_row)
	_nitro_label = UIStyle.label_tech("N2O  0%", 9, Color(0.62, 0.86, 0.96, 0.95))
	_nitro_label.custom_minimum_size = Vector2(92, 0)
	nitro_row.add_child(_nitro_label)
	_nitro_bar = UIBar.new()
	_nitro_bar.setup(UIStyle.ACCENT)
	_nitro_bar.segments = 16
	_nitro_bar.chamfer = 2.5
	_nitro_bar.danger_from = 1.2
	_nitro_bar.custom_minimum_size = Vector2(0, 7)
	_nitro_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_nitro_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_nitro_bar.show_ticks = false
	nitro_row.add_child(_nitro_bar)
	_nitro_badge = null


func _pedal_bar(parent: Control, caption: String, color: Color) -> UIBar:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.custom_minimum_size = Vector2(0, 14)
	parent.add_child(row)
	var lbl := UIStyle.label(caption, 8, Color(0.68, 0.79, 0.87, 0.95))
	lbl.custom_minimum_size = Vector2(26, 0)
	row.add_child(lbl)
	var bar := UIBar.new()
	bar.setup(color)
	bar.segments = 12
	bar.chamfer = 2.0
	bar.custom_minimum_size = Vector2(0, 6)
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	bar.show_ticks = false
	row.add_child(bar)
	return bar


func _build_drift_card(root: Control) -> void:
	_drift_panel = Panel.new()
	_drift_panel.name = "DriftCard"
	_drift_panel.add_theme_stylebox_override("panel",
		UIStyle.glass_style(UIStyle.GOLD, 0.66, UIStyle.R_MD, 0.26))
	UIStyle.place(_drift_panel, 1, 1, 1, 1, -454, -334, -22, -230)
	_drift_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_drift_panel.visible = false
	root.add_child(_drift_panel)

	_drift_caption = UIStyle.label_tracked("DRIFT COMBO", 8, UIStyle.GOLD,
		HORIZONTAL_ALIGNMENT_LEFT, 2)
	UIStyle.place(_drift_caption, 0, 0, 0, 0, 14, 6, 300, 22)
	_drift_panel.add_child(_drift_caption)

	_drift_score_label = UIStyle.label_tech("0", 30, UIStyle.TXT, HORIZONTAL_ALIGNMENT_LEFT, 0)
	_drift_score_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.55))
	_drift_score_label.add_theme_constant_override("outline_size", 3)
	UIStyle.place(_drift_score_label, 0, 0, 0, 0, 14, 18, 300, 60)
	_drift_panel.add_child(_drift_score_label)

	_drift_combo_label = UIStyle.label_tech("×1", 26, UIStyle.GOLD, HORIZONTAL_ALIGNMENT_RIGHT, 0)
	_drift_combo_label.pivot_offset = Vector2(30, 20)
	UIStyle.place(_drift_combo_label, 1, 0, 1, 0, -112, 20, -14, 58)
	_drift_panel.add_child(_drift_combo_label)

	_drift_total_label = UIStyle.label_tech("", 8, Color(0.72, 0.82, 0.90, 0.92),
		HORIZONTAL_ALIGNMENT_RIGHT)
	UIStyle.place(_drift_total_label, 1, 0, 1, 0, -180, 60, -14, 74)
	_drift_panel.add_child(_drift_total_label)

	_drift_bar = UIBar.new()
	_drift_bar.setup(UIStyle.GOLD)
	_drift_bar.segments = 20
	_drift_bar.chamfer = 2.0
	_drift_bar.show_ticks = false
	UIStyle.place(_drift_bar, 0, 1, 1, 1, 14, -14, -14, -7)
	_drift_panel.add_child(_drift_bar)


func _update_drift(rm: RaceManager, car: Car) -> void:
	if _drift_panel == null or car == null:
		return
	var show := false
	var caption := "DRIFT COMBO  ·  漂移连击"
	var score_text := ""
	var combo_text := ""
	var col := UIStyle.GOLD
	var alpha := 1.0
	if car.drift_lost_timer > 0.0:
		show = true
		caption = "COMBO LOST  ·  连击中断"
		score_text = "撞墙断连"
		col = UIStyle.RED
		alpha = clampf(car.drift_lost_timer / 0.4, 0.0, 1.0)
	elif car.drift_bank_flash > 0.0:
		show = true
		caption = "DRIFT SCORE  ·  漂移入账"
		score_text = "+%d" % car.drift_bank_last
		col = UIStyle.GREEN
		alpha = clampf(car.drift_bank_flash / 0.6, 0.0, 1.0)
	elif car.drift_chain_score >= 1.0 or (car.drift_active and car.speed_kph > 22.0):
		show = true
		score_text = "%d" % int(round(car.drift_chain_score))
		combo_text = "×%d" % car.drift_combo
		if car.drift_combo >= 4:
			col = Color(1.0, 0.56, 0.18)
	_drift_panel.visible = show
	if not show:
		_drift_prev_combo = car.drift_combo
		return
	_drift_panel.modulate.a = alpha
	_drift_caption.text = caption
	_drift_caption.add_theme_color_override("font_color", col)
	_drift_score_label.text = score_text
	_drift_score_label.add_theme_color_override("font_color", col)
	_drift_combo_label.text = combo_text
	_drift_combo_label.add_theme_color_override("font_color", col)
	_drift_total_label.text = "本场漂移  %d" % car.drift_bank
	_drift_bar.visible = car.drift_chain_score > 0.5
	_drift_bar.accent = col
	_drift_bar.queue_redraw()
	_drift_bar.set_value(fmod(car.drift_chain_time, 2.2) / 2.2)
	if car.drift_combo > _drift_prev_combo:
		_drift_combo_label.scale = Vector2(1.45, 1.45)
		var tw := create_tween()
		tw.tween_property(_drift_combo_label, "scale", Vector2.ONE, 0.26) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_drift_prev_combo = car.drift_combo


func _build_overlays(root: Control) -> void:
	hint_label = UIStyle.label("", 9, Color(0.62, 0.72, 0.80, 0.92))
	UIStyle.place(hint_label, 0, 1, 0, 1, 26, -36, 980, -16)
	root.add_child(hint_label)

	_slip_label = UIStyle.label_tracked("SLIPSTREAM   尾流加速", 12, UIStyle.ACCENT,
		HORIZONTAL_ALIGNMENT_CENTER, 2)
	_slip_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	_slip_label.add_theme_constant_override("outline_size", 5)
	UIStyle.place(_slip_label, 0.5, 0.5, 0.5, 0.5, -200, 118, 200, 146)
	_slip_label.visible = false
	root.add_child(_slip_label)

	countdown_label = UIStyle.label_tech("", 160, Color(1.0, 0.95, 0.72, 1.0),
		HORIZONTAL_ALIGNMENT_CENTER)
	countdown_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.75))
	countdown_label.add_theme_constant_override("outline_size", 12)
	countdown_label.pivot_offset = Vector2(220, 110)
	UIStyle.place(countdown_label, 0.5, 0.5, 0.5, 0.5, -220, -140, 220, 120)
	root.add_child(countdown_label)

	toast_label = UIStyle.label_display("", 22, UIStyle.GREEN, HORIZONTAL_ALIGNMENT_CENTER, 2)
	toast_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.75))
	toast_label.add_theme_constant_override("outline_size", 5)
	UIStyle.place(toast_label, 0.5, 0, 0.5, 0, -320, 194, 320, 230)
	root.add_child(toast_label)


# ---------------------------------------------------------------------------
# 每帧刷新（API 不变）
# ---------------------------------------------------------------------------

func refresh(rm: RaceManager, car: Car, track: TrackPath) -> void:
	if rm == null or car == null or track == null:
		return
	var accent := _accent
	track_label.text = "%s" % track.display_name
	if _duel_mode:
		mode_label.text = "%s  ·  本地双人 LOCAL DUEL  ·  %d 圈" % [track.id.to_upper(), rm.race_laps]
	elif rm.mode == "gp":
		mode_label.text = "%s  ·  大奖赛 GP  ·  %d 圈" % [track.id.to_upper(), rm.race_laps]
	else:
		mode_label.text = "%s  ·  计时赛 TIME TRIAL" % track.id.to_upper()
	if not is_nan(ghost_delta):
		var ahead := ghost_delta < 0.0
		mode_label.text += "   ·   幽灵 Δ %+.2f s" % ghost_delta
		mode_label.add_theme_color_override("font_color",
			Color(0.46, 1.0, 0.62, 1.0) if ahead else Color(1.0, 0.58, 0.42, 1.0))
	else:
		mode_label.add_theme_color_override("font_color", Color(0.74, 0.86, 0.92, 1.0))
	camera_label.text = "相机  %s      ·      START 暂停     M 主菜单" % camera_name
	var race_text := RaceManager.format_time(rm.race_time)
	if time_label.text != race_text:
		time_label.text = race_text
	lap_label.text = "LAP  %d / %d" % [mini(rm.player_laps + 1, rm.race_laps), rm.race_laps]
	var last_text := RaceManager.format_time(rm.last_lap_time)
	var best_text := RaceManager.format_time(rm.best_lap_time)
	var current_lap := maxf(rm.race_time - rm.lap_start_time, 0.0)
	if rm.state == RaceManager.State.COUNTDOWN:
		current_lap = 0.0
	lap_time_label.text = "本圈 %s      ·      上圈 %s      ·      最佳 %s" % [
		RaceManager.format_time(current_lap), last_text, best_text]
	position_label.text = "P%d" % rm.player_position
	_position_total.text = "/ %d" % rm.total_cars
	if rm.player_position == 1:
		position_label.add_theme_color_override("font_color", UIStyle.GOLD)
	elif rm.player_position <= 3:
		position_label.add_theme_color_override("font_color", UIStyle.SILVER)
	else:
		position_label.add_theme_color_override("font_color", Color(0.88, 0.92, 0.97, 1.0))
	var final_lap := rm.mode == "gp" and rm.player_laps >= rm.race_laps - 1 and rm.race_laps > 1
	_final_lap.visible = final_lap and rm.state == RaceManager.State.RACING

	_refresh_cluster(car, rm)
	_update_drift(rm, car)
	_update_slipstream(rm, car)
	_update_countdown(rm)
	_update_toast(rm)
	_refresh_common()
	if _map_header != null:
		_map_header.text = "SECTOR MAP   ·   %s" % track.id.to_upper()
	if minimap != null:
		minimap.line_color = _track_accent
	if _track_plate != null:
		var bar := _track_plate.get_meta("accent_bar", null) as ColorRect
		if bar != null:
			bar.color = accent


## 右下仪表卡：转速环 / 速度 / 档位 / 换挡灯 / 油门刹车 / 氮气。
## 赛道和开放世界共用这一套控件，rm 传 null 表示「没有比赛管理器」，
## 此时按「一直在跑」处理（开放世界没有发令倒计时）。
func _refresh_cluster(car: Car, rm: RaceManager) -> void:
	if car == null:
		return
	var speed := speed_value(car.speed_kph)
	if _speed_label != null:
		_speed_label.text = "%d" % int(round(speed))
		_speed_unit.text = "MPH" if Settings.hud_units == "mph" else "KM/H"
	if speed_gauge != null:
		speed_gauge.set_value(speed)
		speed_gauge.digital_text = "%d" % int(round(speed))
	if tach_gauge != null:
		var rpm_actual := car.rpm * 8000.0
		var redline_norm := clampf(car.redline, 0.8, 1.0)
		tach_gauge.set_value(rpm_actual)
		tach_gauge.digital_text = ""
		tach_gauge.redline_from = 8000.0 * redline_norm
		tach_gauge.warn_from = 8000.0 * redline_norm * 0.88
		tach_gauge.hot = car.limiter_active
		if _rpm_value != null:
			_rpm_value.text = "%d" % int(round(rpm_actual))
		if _rpm_label != null:
			_rpm_label.text = "红线 %d" % (int(round(car.redline * 80.0)) * 100)
		_update_shift_lights(car, rm)
	if _gear_name != null:
		var gl := car.gear_label()
		var short := gl
		if gl.begins_with("D"):
			short = gl.substr(1)
		elif gl == "D":
			short = "D"
		_gear_name.text = short
		var gear_col := Color(0.88, 0.92, 0.97)
		if gl == "R":
			gear_col = Color(1.0, 0.42, 0.32)
		elif car.limiter_active:
			gear_col = Color(1.0, 0.24, 0.20)
		elif car.is_manual() or car.rpm > car.redline * 0.88:
			gear_col = UIStyle.GOLD
		elif rm == null or rm.state == RaceManager.State.RACING:
			gear_col = Color(1.0, 0.74, 0.30)
		_gear_name.add_theme_color_override("font_color", gear_col)
	if gear_caption != null:
		var profile := String(car.spec.get("engineProfile", "")).to_upper()
		var mode_text := "EV 单速"
		if car.is_ev():
			mode_text = "EV 单速"
		elif car.is_manual():
			mode_text = "M 手动 · " + profile
		else:
			mode_text = "A 自动 · " + profile
		gear_caption.text = mode_text
	_update_shift_hint(car, rm)
	if _thr_bar != null:
		_thr_bar.set_value(clampf(car.throttle, 0.0, 1.0))
	if _brk_bar != null:
		_brk_bar.set_value(clampf(-car.throttle, 0.0, 1.0))
	_update_nitro(rm, car)


## 相机提示行 + 底部操作提示 + FPS：赛道与开放世界共用。
func _refresh_common() -> void:
	var joy := InputSetup.last_input_was_joy
	if camera_label != null:
		camera_label.text = ("相机  %s      ·      START 暂停     Ⓑ 切视角" if joy \
			else "相机  %s      ·      START 暂停     M 主菜单") % camera_name
	if hint_label != null:
		hint_label.visible = Settings.hud_hints
		hint_label.text = "左摇杆 转向   RT 油门   LT 刹车·倒车   Ⓐ 手刹   Ⓧ 氮气   LB/RB 升降档   Ⓨ 手动/自动   BACK 复位   Ⓑ 相机" if joy \
			else "W/↑ 油门   S/↓ 刹车·倒车   A/D 转向   SPACE 手刹   左SHIFT 氮气   E/Q 升降档   T 手动/自动   R 复位   C 相机"
	if _fps_label != null:
		_fps_label.visible = Settings.show_fps
		if Settings.show_fps:
			_fps_label.text = "%d FPS" % Engine.get_frames_per_second()


func bind_race(rm: RaceManager, car: Car, track: TrackPath) -> void:
	minimap.setup(track, car, rm.ais)
	_prev_position = rm.player_position
	var accent_hex: String = ""
	if track != null:
		var def: Dictionary = GameData.track(track.id)
		accent_hex = String(def.get("cardColor", ""))
	if accent_hex.is_empty() and car != null:
		accent_hex = String(car.spec.get("cardColor", ""))
	_track_accent = UIStyle.accent_from(accent_hex, UIStyle.ACCENT)
	_accent = UIStyle.ACCENT
	_apply_visibility()


## 开放世界（无界大陆）绑定：开放世界也是一条赛道，HUD 用的是同一套控件。
## 差别只有两处：
##   · 没有圈数 / AI / 名次 → 名次牌与顶部赛段小地图退掉；
##   · 右上角换成一张「无界大陆」全域图（大陆轮廓 + 路网 + 玩家箭头）。
func bind_open_world(world_node: OpenWorld, player: Car) -> void:
	_open_world_mode = true
	_ow_world = world_node
	_ow_car = player
	_ow_time = 0.0
	_ow_distance = 0.0
	_ow_zone_id = ""
	_ow_toast_timer = 0.0
	_ow_last_pos = player.pos if player != null else Vector3.ZERO
	_track_accent = UIStyle.ACCENT
	_accent = UIStyle.ACCENT
	if continent_map != null:
		continent_map.setup(world_node, player)
	if _continent_header != null:
		_continent_header.text = "CONTINENT MAP   ·   无界大陆"
	_apply_visibility()
	_animate_continent_entrance()


## 全域图入场：和顶部小地图一样，从屏幕上方浮下来 + 淡入。
func _animate_continent_entrance() -> void:
	if _continent_panel == null:
		return
	var rest_top := _continent_panel.offset_top
	var rest_bottom := _continent_panel.offset_bottom
	_continent_panel.offset_top = rest_top - 140.0
	_continent_panel.offset_bottom = rest_bottom - 140.0
	_continent_panel.modulate.a = 0.0
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(_continent_panel, "offset_top", rest_top, 0.55) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(_continent_panel, "offset_bottom", rest_bottom, 0.55) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(_continent_panel, "modulate:a", 1.0, 0.38) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)


## 开放世界每帧刷新。左上信息牌 / 计时条 / 右下仪表卡 / 底部提示
## 全部沿用赛道那套控件，内容换成自由漫游。
func refresh_open_world(world_node: OpenWorld, player: Car, dt: float) -> void:
	if not _open_world_mode or player == null:
		return
	_ow_time += dt
	var moved := player.pos - _ow_last_pos
	moved.y = 0.0
	_ow_distance += moved.length()
	_ow_last_pos = player.pos

	# ── 当前区域
	var zone: Dictionary = {}
	if world_node != null:
		zone = world_node.zone_at(player.pos.x, player.pos.z)
	var zid := String(zone.get("id", ""))
	if zid != _ow_zone_id:
		_ow_zone_id = zid
		_ow_accent = UIStyle.accent_from(zone.get("accent", "#55e7d2"), _ow_accent)
		_show_zone_toast(zone)

	# ── 左上信息牌
	track_label.text = "无界大陆  CONTINENT"
	mode_label.text = "自由漫游  FREE ROAM   ·   9 × 9 km   ·   无圈速"
	mode_label.add_theme_color_override("font_color", Color(0.74, 0.86, 0.92, 1.0))

	# ── 计时条：赛道这里显示「本圈 / 上圈 / 最佳」，开放世界改成
	#    「总时长 + 当前区域 + 遥测」，控件本身完全一样。
	var ow_text := RaceManager.format_time(_ow_time)
	if time_label.text != ow_text:
		time_label.text = ow_text
	if zid != "":
		lap_label.text = "%s   %s" % [String(zone.get("cn", "")), String(zone.get("en", ""))]
		lap_label.add_theme_color_override("font_color", _ow_accent)
	else:
		lap_label.text = "无界大陆  CONTINENT"
		lap_label.add_theme_color_override("font_color", UIStyle.GOLD)
	lap_time_label.text = "海拔 %d m      ·      地表 %s      ·      里程 %.2f km" % [
		int(round(player.pos.y)), _surface_cn(player.world_surface), _ow_distance / 1000.0]
	_final_lap.visible = false

	# ── 仪表卡 + 提示行（和赛道完全一致）
	_refresh_cluster(player, null)
	_update_drift(null, player)
	_refresh_common()

	if continent_map != null:
		continent_map.queue_redraw()
	_update_ow_toast(dt)


## 进入新区域时在屏幕中央弹一次区域名（复用赛道的 toast 通道）。
func _show_zone_toast(zone: Dictionary) -> void:
	if toast_label == null:
		return
	var cn := String(zone.get("cn", "无界大陆"))
	var en := String(zone.get("en", ""))
	if en.is_empty():
		toast_label.text = cn
	else:
		toast_label.text = "%s   ·   %s" % [cn, en]
	toast_label.add_theme_color_override("font_color", _ow_accent)
	toast_label.modulate.a = 1.0
	_ow_toast_timer = 2.6


func _update_ow_toast(dt: float) -> void:
	if toast_label == null:
		return
	if _ow_toast_timer > 0.0:
		_ow_toast_timer = maxf(0.0, _ow_toast_timer - dt)
		toast_label.modulate.a = clampf(_ow_toast_timer / 0.6, 0.0, 1.0)
		if _ow_toast_timer <= 0.0:
			toast_label.text = ""


static func _surface_cn(surf: String) -> String:
	return String({
		"road": "公路", "sand": "沙地", "grass": "草地", "rock": "岩石",
		"snow": "积雪", "ice": "冰面", "lava": "熔岩", "water": "水面",
	}.get(surf, surf))


func set_camera_name(name: String) -> void:
	camera_name = name


# ---------------------------------------------------------------------------
# 视觉细节
# ---------------------------------------------------------------------------

func speed_value(kph: float) -> float:
	return kph * 0.621371 if Settings.hud_units == "mph" else kph


func _update_shift_lights(car: Car, rm: RaceManager) -> void:
	if _shift_lights == null or car == null:
		return
	var redline := maxf(car.redline, 0.5)
	var frac := clampf(car.rpm / redline, 0.0, 1.0)
	var lit := 0
	if rm == null or rm.state == RaceManager.State.RACING:
		lit = int(round(frac * _shift_lights.count))
	var blink := 1.0
	if car.limiter_active:
		blink = 0.55 + 0.45 * sin(Time.get_ticks_msec() * 0.03)
	_shift_lights.update_state(lit, blink)


## 换挡提示：黄区/红区升档、顶挡、降挡保护。只读 car 的真实状态。
func _update_shift_hint(car: Car, rm: RaceManager) -> void:
	if _shift_hint == null:
		return
	var text := ""
	var col := UIStyle.GOLD
	match car.shift_hint:
		"UP":
			text = "▲ 升档  SHIFT UP"
			col = UIStyle.GOLD
		"REDLINE":
			text = "红线断油  REDLINE → 升档!"
			col = Color(1.0, 0.30, 0.22)
		"MAX":
			text = "顶挡 · 已达极速"
			col = UIStyle.SILVER
		"DOWN":
			text = "▼ 降档  SHIFT DOWN"
			col = Color(0.66, 0.90, 0.98)
		"DENY":
			text = "✕ 降档保护 · 转速过高"
			col = Color(1.0, 0.42, 0.26)
		"MANUAL":
			text = "手动模式  MANUAL"
			col = UIStyle.ACCENT
		"AUTO":
			text = "自动模式  AUTO"
			col = UIStyle.ACCENT
	if car.limiter_active:
		var blink := 0.45 + 0.55 * absf(sin(Time.get_ticks_msec() * 0.025))
		_shift_hint.modulate.a = blink
	else:
		_shift_hint.modulate.a = 1.0
	if _shift_hint.text != text:
		_shift_hint.text = text
	_shift_hint.add_theme_color_override("font_color", col)


## 氮气条：真实读取 car.nitro_charge / nitro_active / nitro_gaining / drift_active
func _update_nitro(rm: RaceManager, car: Car) -> void:
	if _nitro_bar == null or car == null:
		return
	var charge := clampf(car.nitro_charge, 0.0, 1.0)
	_nitro_bar.set_value(charge)
	# rm 为 null = 开放世界：没有发令流程，一直在跑，氮气随时可用
	var racing := rm == null or rm.state == RaceManager.State.RACING
	var active := car.nitro_active and racing
	var charging := car.nitro_gaining and not active
	var col := UIStyle.ACCENT
	var text := "N2O  %d%%" % int(round(charge * 100.0))
	var badge := "SHIFT 按住 · 漂移充能"
	if active:
		col = Color(0.40, 1.0, 0.64)
		text = "N2O  注入  %d%%" % int(round(charge * 100.0))
		badge = "N2O BOOST"
	elif charging:
		col = UIStyle.GREEN
		text = "N2O  充能  %d%%" % int(round(charge * 100.0))
		badge = "DRIFT CHARGE"
	elif charge < 0.02:
		col = Color(0.60, 0.66, 0.72)
		text = "N2O  耗尽"
	if _nitro_bar.accent != col:
		_nitro_bar.accent = col
		_nitro_bar.queue_redraw()
	if _nitro_label != null:
		_nitro_label.text = text
		_nitro_label.add_theme_color_override("font_color", col)
	if _nitro_badge != null:
		_nitro_badge.text = badge


func _update_slipstream(rm: RaceManager, car: Car) -> void:
	if _slip_label == null:
		return
	var active := false
	if rm != null and rm.state == RaceManager.State.RACING and car != null:
		var fwd := car.forward()
		var side := car.right()
		for ai in rm.ais:
			if ai == null:
				continue
			var rel: Vector3 = ai.pos - car.pos
			var ahead := rel.dot(fwd)
			var lateral := absf(rel.dot(side))
			if ahead > 2.0 and ahead < 26.0 and lateral < 3.6:
				active = true
				break
	_slip_label.visible = active
	if active:
		_slip_label.modulate.a = 0.65 + 0.35 * sin(Time.get_ticks_msec() * 0.008)


func _update_countdown(rm: RaceManager) -> void:
	if countdown_label == null:
		return
	var text := rm.countdown_text()
	if text == _last_countdown:
		return
	_last_countdown = text
	countdown_label.text = text
	if text.is_empty():
		return
	var is_go := text == "GO!"
	countdown_label.add_theme_color_override("font_color",
		Color(0.46, 1.0, 0.62, 1.0) if is_go else Color(1.0, 0.95, 0.72, 1.0))
	countdown_label.pivot_offset = countdown_label.size * 0.5
	countdown_label.scale = Vector2(1.45, 1.45)
	var tw := countdown_label.create_tween()
	tw.tween_property(countdown_label, "scale", Vector2.ONE, 0.32) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _update_toast(rm: RaceManager) -> void:
	if rm.player_position != _prev_position:
		if _prev_position > 0 and rm.state == RaceManager.State.RACING:
			var gained := _prev_position - rm.player_position
			toast_label.text = ("▲   超越  P%d      +%d" % [rm.player_position, gained]) if gained > 0 \
				else ("▼   被超越  P%d" % rm.player_position)
			toast_label.add_theme_color_override("font_color", UIStyle.GREEN if gained > 0 else UIStyle.RED)
			_toast_timer = 2.2
		_prev_position = rm.player_position
	if _toast_timer > 0.0:
		_toast_timer -= get_physics_process_delta_time()
		toast_label.modulate.a = clampf(_toast_timer / 0.6, 0.0, 1.0)
	elif toast_label != null:
		toast_label.text = ""
		toast_label.modulate.a = 1.0


func _apply_visibility() -> void:
	if _vignette != null:
		_vignette.visible = Settings.vignette
	if _map_panel != null:
		# 开放世界没有赛道，顶部赛段小地图退掉；右上角换成无界大陆全域图
		_map_panel.visible = Settings.hud_minimap and not _open_world_mode
	if _continent_panel != null:
		_continent_panel.visible = Settings.hud_minimap and _open_world_mode
	if _position_panel != null:
		# 自由漫游没有对手，名次牌没有意义
		_position_panel.visible = not _open_world_mode
	if tach_gauge != null:
		tach_gauge.visible = Settings.hud_tach
	if _speed_label != null:
		_speed_label.visible = Settings.hud_speed
	if _speed_unit != null:
		_speed_unit.visible = Settings.hud_speed
	if gear_panel != null:
		gear_panel.visible = Settings.hud_speed
	if _shift_lights != null:
		_shift_lights.visible = Settings.hud_tach
	if _rpm_label != null:
		_rpm_label.visible = Settings.hud_tach
	if _rpm_value != null:
		_rpm_value.visible = Settings.hud_tach
	if _rpm_caption != null:
		_rpm_caption.visible = Settings.hud_tach
	if hint_label != null:
		hint_label.visible = Settings.hud_hints


# ---------------------------------------------------------------------------
# 结算
# ---------------------------------------------------------------------------

## 把车手成长/成就结果追加到结算面板（Lead 在 show_results 之后调用）。
func show_profile_progress(summary: Dictionary) -> void:
	if results_records == null or summary.is_empty():
		return
	var bits: Array[String] = []
	var xp_gain := int(summary.get("xp_gain", 0))
	if xp_gain > 0:
		bits.append("+%d XP" % xp_gain)
	if bool(summary.get("level_up", false)):
		bits.append("等级提升  LV%d → LV%d" % [int(summary.get("level_before", 1)), int(summary.get("level_after", 1))])
	else:
		bits.append("车手等级  LV%d" % int(summary.get("level_after", summary.get("level_before", 1))))
	var ach: Array = summary.get("achievements", [])
	if not ach.is_empty():
		var names: Array[String] = []
		for a in ach:
			if a is Dictionary:
				names.append(String(a.get("name", a.get("id", "成就"))))
		if not names.is_empty():
			bits.append("成就解锁：" + " / ".join(names))
	var mastery: Dictionary = summary.get("mastery", {})
	if not mastery.is_empty() and int(mastery.get("after", 0)) > int(mastery.get("before", 0)):
		bits.append("赛道精通 %s → %s  +%d XP" % [
			String(mastery.get("before_label", "未精通")),
			String(mastery.get("label", "")),
			int(mastery.get("xp", 0))])
	var credits := int(summary.get("credit_balance", -1))
	if credits >= 0:
		bits.append("可用积分  %d XP" % credits)
	if not bits.is_empty():
		var line := "成长  ·  " + "      ".join(bits)
		results_records.text = (results_records.text + "        " + line) if not results_records.text.is_empty() else line


func append_result_line(line: String) -> void:
	if results_records == null or line.is_empty():
		return
	results_records.text = (results_records.text + "        " + line) if not results_records.text.is_empty() else line


func show_results(rm: RaceManager) -> void:
	if rm == null or rm.results.is_empty():
		return
	results_root.visible = true
	var player_rank := 1
	for row in rm.results:
		if bool(row["is_player"]):
			player_rank = int(row["rank"])
			break
	results_title.text = "比赛结束   /   RACE FINISH"
	var medal_text := ""
	var medal_color := UIStyle.SILVER
	match rm.medal:
		"gold":
			medal_text = "金牌  GOLD"
			medal_color = UIStyle.GOLD
		"silver":
			medal_text = "银牌  SILVER"
			medal_color = UIStyle.SILVER
		"bronze":
			medal_text = "铜牌  BRONZE"
			medal_color = Color(0.86, 0.55, 0.32, 1.0)
		_:
			medal_text = "完赛  FINISHED"
			medal_color = Color(0.70, 0.80, 0.90, 1.0)
	var subtitle := ""
	if rm.mode == "ta":
		subtitle = "总时间  %s       ·       %s" % [
			RaceManager.format_time(rm.player_finish_time), medal_text]
	else:
		subtitle = "名次  P%d / %d       ·       总时间  %s       ·       %s" % [
			player_rank, rm.total_cars, RaceManager.format_time(rm.player_finish_time), medal_text]
	results_subtitle.text = subtitle
	results_subtitle.add_theme_color_override("font_color", medal_color)
	var total_text := RaceManager.format_time(rm.player_finish_time)
	var best_lap_text := RaceManager.format_time(rm.best_lap_time)
	if _result_stat_values.size() == 4:
		_result_stat_values[0].text = "P%d / %d" % [player_rank, rm.total_cars]
		_result_stat_values[1].text = total_text
		_result_stat_values[2].text = best_lap_text
		_result_stat_values[3].text = medal_text
		_result_stat_values[3].add_theme_color_override("font_color", medal_color)

	for child in results_rows.get_children():
		child.queue_free()
	var row_index := 0
	for row in rm.results:
		var is_player := bool(row["is_player"])
		var rank := int(row["rank"])
		var rank_color := Color(0.86, 0.91, 0.96, 1.0)
		if rank == 1:
			rank_color = UIStyle.GOLD
		elif rank == 2:
			rank_color = UIStyle.SILVER
		elif rank == 3:
			rank_color = Color(0.86, 0.60, 0.38, 1.0)
		var holder := Panel.new()
		var row_style := StyleBoxFlat.new()
		row_style.set_corner_radius_all(UIStyle.R_SM)
		row_style.corner_detail = 4
		if is_player:
			row_style.bg_color = Color(0.10, 0.115, 0.09, 0.92)
			row_style.border_color = UIStyle.a(UIStyle.GOLD, 0.55)
			row_style.set_border_width_all(1)
			row_style.shadow_color = UIStyle.a(UIStyle.GOLD, 0.10)
			row_style.shadow_size = 8
		else:
			row_style.bg_color = Color(0.030, 0.045, 0.058, 0.82)
			row_style.border_color = UIStyle.a(Color.WHITE, 0.05)
			row_style.set_border_width_all(1)
		holder.add_theme_stylebox_override("panel", row_style)
		holder.custom_minimum_size = Vector2(0, 42)
		holder.modulate.a = 0.0
		results_rows.add_child(holder)
		var hbox := HBoxContainer.new()
		hbox.set_anchors_preset(Control.PRESET_FULL_RECT)
		hbox.offset_left = 14
		hbox.offset_right = -14
		hbox.add_theme_constant_override("separation", 16)
		hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
		holder.add_child(hbox)
		var rank_label := UIStyle.label_tech("P%d" % rank, 20, rank_color)
		rank_label.custom_minimum_size = Vector2(64, 0)
		hbox.add_child(rank_label)
		var name_text := String(row["name"])
		if is_player:
			name_text += "    （你）"
		var name_label := UIStyle.label(name_text, 15,
			UIStyle.TXT if not is_player else UIStyle.a(UIStyle.GOLD, 0.98))
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		hbox.add_child(name_label)
		var time_label_row := UIStyle.label_tech(String(row["time_text"]), 15,
			Color(0.88, 0.93, 0.97, 1.0), HORIZONTAL_ALIGNMENT_RIGHT)
		time_label_row.custom_minimum_size = Vector2(210, 0)
		hbox.add_child(time_label_row)
		if is_player:
			var tag := UIStyle.label_tracked("YOU", 8, UIStyle.a(UIStyle.GOLD, 0.9),
				HORIZONTAL_ALIGNMENT_CENTER, 1)
			tag.custom_minimum_size = Vector2(34, 0)
			hbox.add_child(tag)
		holder.create_tween().tween_property(holder, "modulate:a", 1.0, 0.22).set_delay(0.03 * row_index)
		row_index += 1

	var record_bits: Array[String] = []
	if rm.record_summary.get("new_total", false):
		record_bits.append("★ 新纪录  总时间 %s" % RaceManager.format_time(float(rm.record_summary["best_total"])))
	elif float(rm.record_summary.get("best_total", -1.0)) > 0.0:
		record_bits.append("最佳总时间  %s" % RaceManager.format_time(float(rm.record_summary["best_total"])))
	if rm.record_summary.get("new_lap", false):
		record_bits.append("★ 新纪录  单圈 %s" % RaceManager.format_time(float(rm.record_summary["best_lap"])))
	elif float(rm.record_summary.get("best_lap", -1.0)) > 0.0:
		record_bits.append("最佳单圈  %s" % RaceManager.format_time(float(rm.record_summary["best_lap"])))
	if rm.ai_fastest_lap > 0.0:
		record_bits.append("对手最快圈  %s（%s）" % [
			RaceManager.format_time(rm.ai_fastest_lap), rm.ai_fastest_name])
	results_records.text = "        ".join(record_bits)
	results_hint.text = "Ⓐ  返回菜单      ·      Ⓧ  重新比赛      ·      Ⓨ  下一场比赛" if InputSetup.last_input_was_joy \
		else "R  重新比赛      ·      M  返回菜单      ·      ENTER  下一场比赛"
	_results_panel.pivot_offset = _results_panel.size * 0.5
	_results_panel.scale = Vector2(0.96, 0.96)
	_results_panel.modulate.a = 0.0
	var tw := _results_panel.create_tween()
	tw.set_parallel(true)
	tw.tween_property(_results_panel, "scale", Vector2.ONE, 0.30).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(_results_panel, "modulate:a", 1.0, 0.22)


func hide_results() -> void:
	if results_root != null:
		results_root.visible = false


func _build_results(root: Control) -> void:
	results_root = Control.new()
	results_root.name = "Results"
	results_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	results_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(results_root)

	var dim := ColorRect.new()
	dim.color = Color(0.004, 0.008, 0.012, 0.88)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	results_root.add_child(dim)

	var glow := TextureRect.new()
	glow.texture = UIStyle.glow_texture(UIStyle.GOLD, 2.0)
	glow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	glow.stretch_mode = TextureRect.STRETCH_SCALE
	glow.modulate = Color(1, 1, 1, 0.10)
	UIStyle.place(glow, 0.5, 0.5, 0.5, 0.5, -560, -420, 560, 420)
	glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	results_root.add_child(glow)

	var panel := Panel.new()
	panel.add_theme_stylebox_override("panel",
		UIStyle.glass_style(UIStyle.ACCENT, 0.95, UIStyle.R_LG, 0.32))
	UIStyle.place(panel, 0.5, 0.5, 0.5, 0.5, -490, -268, 490, 268)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	results_root.add_child(panel)
	_results_panel = panel
	UIStyle.add_top_glow(panel, UIStyle.GOLD, 0.95)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.offset_left = 38
	vbox.offset_top = 24
	vbox.offset_right = -38
	vbox.offset_bottom = -24
	vbox.add_theme_constant_override("separation", 8)
	panel.add_child(vbox)

	var kicker := UIStyle.label_tracked("APEX VELOCITY   /   OFFICIAL RESULT", 9,
		UIStyle.a(UIStyle.ACCENT, 0.92), HORIZONTAL_ALIGNMENT_LEFT, 2)
	vbox.add_child(kicker)

	results_title = UIStyle.label_display("比赛结束   /   RACE FINISH", 32, UIStyle.TXT,
		HORIZONTAL_ALIGNMENT_LEFT, 2)
	results_title.add_theme_constant_override("outline_size", 0)
	vbox.add_child(results_title)

	results_subtitle = UIStyle.label_tech("", 16, UIStyle.GOLD, HORIZONTAL_ALIGNMENT_LEFT)
	vbox.add_child(results_subtitle)

	var sep := HSeparator.new()
	UIStyle.style_separator(sep, UIStyle.ACCENT, 0.22)
	vbox.add_child(sep)

	results_rows = VBoxContainer.new()
	results_rows.add_theme_constant_override("separation", 5)
	vbox.add_child(results_rows)

	var stats_row := HBoxContainer.new()
	stats_row.add_theme_constant_override("separation", 8)
	stats_row.custom_minimum_size = Vector2(0, 72)
	vbox.add_child(stats_row)
	var stat_captions := ["名次  POSITION", "完赛时间  TOTAL", "最快单圈  BEST LAP", "奖牌  MEDAL"]
	for i in 4:
		var cell := Panel.new()
		cell.add_theme_stylebox_override("panel", UIStyle.inset_style(UIStyle.ACCENT, 0.55))
		cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cell.mouse_filter = Control.MOUSE_FILTER_IGNORE
		stats_row.add_child(cell)
		var caption := UIStyle.label_tracked(stat_captions[i], 8, UIStyle.TXT_FAINT,
			HORIZONTAL_ALIGNMENT_LEFT, 1)
		UIStyle.place(caption, 0, 0, 1, 0, 12, 8, -12, 24)
		cell.add_child(caption)
		var value := UIStyle.label_tech("", 20, UIStyle.TXT, HORIZONTAL_ALIGNMENT_LEFT)
		UIStyle.place(value, 0, 0, 1, 0, 12, 28, -12, 60)
		cell.add_child(value)
		_result_stat_values.append(value)
	_result_medal_label = _result_stat_values[3]

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(spacer)

	var rule := ColorRect.new()
	rule.color = UIStyle.a(UIStyle.ACCENT, 0.14)
	rule.custom_minimum_size = Vector2(0, 1)
	vbox.add_child(rule)

	results_records = UIStyle.label("", 11, Color(0.66, 0.88, 0.76, 1.0))
	results_records.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(results_records)

	results_hint = UIStyle.label_tracked("", 10, Color(0.62, 0.76, 0.85, 1.0),
		HORIZONTAL_ALIGNMENT_LEFT, 1)
	vbox.add_child(results_hint)
