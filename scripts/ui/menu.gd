class_name Menu
extends CanvasLayer
## 选车 / 选赛道主菜单 · 高级赛车玻璃拟态版 v2。
## 布局保持用户确认过的「左侧 3D 真车 + 真实赛道，右侧浮动信息卡」：
##   · 左上：品牌标题 + 车手档案 + 成就入口
##   · 右上：画质状态 + 唯一设置入口
##   · 右侧：车辆卡（01 MACHINE）/ 赛道卡（02 CIRCUIT）/ 模式 + 巨型发车按钮
##   · 左下：站次编号 + 赛道简介 / 底部按键提示
## 所有信号与 selected_track_id()/selected_car_id() 等 API 与旧版完全一致。

signal start_requested(track_id: String, car_id: String, mode: String)
signal garage_requested(car_id: String)
signal settings_requested
signal achievements_requested
signal daily_requested
signal archive_requested
signal selection_changed(car_id: String)
signal track_changed(track_id: String)

const MODE_IDS := ["gp", "ta", "duel"]
const MODE_NAMES := ["GRAND PRIX", "TIME TRIAL", "LOCAL DUEL"]
const MODE_CN := ["大奖赛", "计时赛", "本地双人"]

const ACCENT := UIStyle.ACCENT
const CARD_X0 := -500.0
const CARD_X1 := -24.0

var track_index := 0
var car_index := 0
var mode_index := 0
var profile_badge: Label
var track_lengths: Dictionary = {}
var track_paths: Dictionary = {}

static var _path_cache: Dictionary = {}
static var _bg_cache: Dictionary = {}

# 公开给 main / 旧逻辑读取的节点（保持字段名兼容）
var car_name_label: Label
var car_cn_label: Label
var car_stats_label: Label
var car_swatch: ColorRect
var car_index_label: Label
var track_name_label: Label
var track_en_label: Label
var track_meta_label: Label
var track_record_label: Label
var mode_label: Label
var mode_button: Button
var quality_label: Label
var station_label: Label
var footer_label: Label
var preview: Minimap
var bg_image: TextureRect
var stage_rect: TextureRect
var car_card: Panel
var garage_card: Panel
var track_card: Panel
var station_buttons: Array[Button] = []
var car_nav_label: Label

var _accent := UIStyle.ACCENT
var _track_accent := UIStyle.ACCENT
var _mode_buttons: Array[Button] = []
var _stat_bars: Array[UIBar] = []
var _stat_values: Array[Label] = []
var _station_meta: Label
var _station_big: Label
var _station_total: Label
var _frame: UIFrame
var _slash: ColorRect
var _launch_btn: Button
var _launch_glow: TextureRect
var _launch_arrow: Label
var _launch_play: Label
var _track_stats_row: HBoxContainer
var _track_stats: Array[Label] = []
var _track_stat_titles: Array[Label] = []
var _launch_title: Label
var _map_holder: Panel
var _record_best: Label
var _record_lap: Label
var _display_label: Label
var _track_chip_row: HBoxContainer
var _car_rule: TextureRect
var _track_rule: TextureRect
var _track_title_rule: ColorRect
var _daily_badge: Label
var _mastery_label: Label
var _history_label: Label

var _prev_track_id := ""
var _prev_car_id := ""
var _prev_mode := -1
var _nav_cooldown := 0.0
var _nav_latched := false


func _ready() -> void:
	layer = 20
	_restore_selection()
	_compute_lengths()
	_build()
	refresh()
	_animate_in()
	_launch_btn.grab_focus.call_deferred()


# ---------------------------------------------------------------------------
# 构建工具
# ---------------------------------------------------------------------------

func _make_card(ol: float, ot: float, orr: float, ob: float) -> Panel:
	var card := Panel.new()
	card.add_theme_stylebox_override("panel", UIStyle.card_style(ACCENT, false, 0.90))
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UIStyle.place(card, 1, 0, 1, 0, ol, ot, orr, ob)
	return card


func _card_header(card: Panel, index_text: String, title_en: String, title_cn: String,
		accent: Color) -> Label:
	var badge := UIStyle.index_badge(index_text, accent)
	UIStyle.place(badge, 0, 0, 0, 0, 18, 13, 52, 37)
	card.add_child(badge)
	var kicker := UIStyle.label_tracked("%s   /   %s" % [title_en, title_cn], 10,
		UIStyle.a(accent, 0.92), HORIZONTAL_ALIGNMENT_LEFT, 2)
	UIStyle.place(kicker, 0, 0, 1, 0, 60, 13, -18, 37)
	card.add_child(kicker)
	var right := UIStyle.label_tracked("", 10, UIStyle.TXT_DIM, HORIZONTAL_ALIGNMENT_RIGHT, 1)
	UIStyle.place(right, 0, 0, 1, 0, 60, 13, -18, 37)
	card.add_child(right)
	var rule := ColorRect.new()
	rule.color = UIStyle.a(accent, 0.16)
	UIStyle.place(rule, 0, 0, 1, 0, 18, 43, -18, 44)
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(rule)
	return right


func _build_profile_badge(root: Control) -> void:
	profile_badge = UIStyle.label("", 10, Color(0.70, 0.80, 0.87, 1.0))
	profile_badge.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UIStyle.place(profile_badge, 0, 0, 0, 0, 60, 96, 1000, 124)
	profile_badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(profile_badge)
	_refresh_profile_badge()


func _refresh_profile_badge() -> void:
	if profile_badge == null:
		return
	var lines: Array[String] = []
	if ResourceLoader.exists("res://scripts/core/profile_store.gd"):
		var ps := load("res://scripts/core/profile_store.gd")
		if ps.has_method("format_summary"):
			var raw: Array = ps.format_summary()
			for i in mini(3, raw.size()):
				lines.append(String(raw[i]))
	if lines.is_empty():
		profile_badge.text = ""
		return
	profile_badge.text = "   ·   ".join(lines)


func _refresh_mastery(track_id: String, track_length: float, difficulty: int) -> void:
	if _mastery_label == null:
		return
	var state := ProfileStore.mastery_state(
		ProfileStore.load_profile(), track_id, track_length, difficulty)
	var tier := int(state.get("tier", 0))
	var best := float(state.get("best_lap", -1.0))
	var next_target := float(state.get("next_target", 0.0))
	var text := "赛道精通  %s" % String(state.get("label", "未精通"))
	if tier >= 3:
		text += "   ·   最佳单圈 %s   ·   已满级" % RaceManager.format_time(best)
	else:
		if best > 0.0:
			text += "   ·   最佳单圈 %s" % RaceManager.format_time(best)
		if next_target > 0.0:
			text += "   ·   下一目标 %s" % RaceManager.format_time(next_target)
			if best > 0.0:
				text += "（差 %.2fs）" % maxf(0.0, best - next_target)
	_mastery_label.text = text
	var color := Color(0.62, 0.72, 0.80, 1.0)
	match tier:
		3:
			color = Color(1.0, 0.82, 0.36, 1.0)
		2:
			color = Color(0.80, 0.87, 0.96, 1.0)
		1:
			color = Color(0.88, 0.64, 0.42, 1.0)
	_mastery_label.add_theme_color_override("font_color", color)


func _refresh_daily_badge() -> void:
	if _daily_badge == null:
		return
	var summary := ProfileStore.daily_summary()
	var claimable := int(summary.get("claimable", 0))
	if claimable > 0:
		_daily_badge.text = "可领 %d" % claimable
		_daily_badge.add_theme_color_override("font_color", UIStyle.GOLD)
	else:
		_daily_badge.text = "%d / %d" % [int(summary.get("done", 0)), int(summary.get("total", 3))]
		_daily_badge.add_theme_color_override("font_color", UIStyle.TXT_DIM)


func _restore_selection() -> void:
	var wanted_track := Settings.last_track
	if not wanted_track.is_empty():
		for i in GameData.tracks.size():
			if String(GameData.tracks[i].get("id", "")) == wanted_track:
				track_index = i
				break
	var wanted_car := Settings.last_car
	if wanted_car.is_empty():
		wanted_car = "bmw_m3_e46_gtr"
	for i in GameData.cars_specs.size():
		if String(GameData.cars_specs[i].get("id", "")) == wanted_car:
			car_index = i
			break
	mode_index = 0
	for mi in MODE_IDS.size():
		if MODE_IDS[mi] == Settings.last_mode:
			mode_index = mi


func _compute_lengths() -> void:
	for def in GameData.tracks:
		var id := String(def.get("id", ""))
		if _path_cache.has(id):
			var cached := _path_cache[id] as TrackPath
			track_paths[id] = cached
			track_lengths[id] = cached.total_length
			continue
		var path := TrackPath.new()
		path.build_from_def(def, 2.0)
		_path_cache[id] = path
		track_paths[id] = path
		track_lengths[id] = path.total_length


func selected_track_id() -> String:
	if GameData.tracks.is_empty():
		return ""
	return String(GameData.tracks[posmod(track_index, GameData.tracks.size())].get("id", ""))


func selected_car_id() -> String:
	if GameData.cars_specs.is_empty():
		return ""
	return String(GameData.cars_specs[posmod(car_index, GameData.cars_specs.size())].get("id", ""))


# ---------------------------------------------------------------------------
# actions (keyboard + mouse share these)
# ---------------------------------------------------------------------------

func _step_track(delta: int) -> void:
	track_index += delta
	refresh()


func _toggle_mode() -> void:
	mode_index = (mode_index + 1) % MODE_IDS.size()
	refresh()


func _start() -> void:
	Settings.set_selection(selected_track_id(), selected_car_id(), MODE_IDS[mode_index])
	start_requested.emit(selected_track_id(), selected_car_id(), MODE_IDS[mode_index])


func _select_station(i: int) -> void:
	track_index = i
	refresh()


# ---------------------------------------------------------------------------
# 布局
# ---------------------------------------------------------------------------

func _build() -> void:
	var root := Control.new()
	root.name = "Root"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UIStyle.apply_theme(root)
	add_child(root)

	# 全屏极淡压暗 + 上下渐隐 + 暗角：保留左侧 3D 实景的纵深
	var bg := ColorRect.new()
	bg.color = Color(0.004, 0.007, 0.010, 0.18)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(bg)
	UIStyle.cinematic_backdrop(root, 0.52, 0.86, 0.52)

	# 右侧信息栏横向渐隐底
	UIStyle.side_rail(root, 720.0, 0.94)

	# 顶部极细的品牌青扫描线
	var top_scan := UIStyle.accent_line(ACCENT, 1.0, 0.30)
	top_scan.set_anchors_preset(Control.PRESET_TOP_WIDE)
	top_scan.offset_bottom = 2
	root.add_child(top_scan)

	# 屏幕四角科技框（收敛为细线 + 角标）
	_frame = UIFrame.new()
	_frame.setup(ACCENT, 26.0, 0.22)
	UIStyle.place(_frame, 0, 0, 1, 1, 18, 18, -18, -18)
	root.add_child(_frame)

	# ---- 左上：品牌 ------------------------------------------------------
	_slash = ColorRect.new()
	_slash.color = ACCENT
	UIStyle.place(_slash, 0, 0, 0, 0, 40, 24, 44, 78)
	_slash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_slash)

	var brand := UIStyle.label_display("APEX / VELOCITY", 34, UIStyle.TXT,
		HORIZONTAL_ALIGNMENT_LEFT, 2)
	UIStyle.place(brand, 0, 0, 0, 0, 58, 20, 760, 64)
	root.add_child(brand)

	var brand_cn := UIStyle.label_tracked("极 速 巅 峰      RACING LEGACY", 11,
		Color(0.58, 0.78, 0.84, 1.0), HORIZONTAL_ALIGNMENT_LEFT, 2)
	UIStyle.place(brand_cn, 0, 0, 0, 0, 60, 66, 760, 88)
	root.add_child(brand_cn)
	_build_profile_badge(root)

	# 成就入口：金色小徽章 + 键帽，作为品牌区的次级入口
	var ach_btn := Button.new()
	ach_btn.focus_mode = Control.FOCUS_ALL
	ach_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	UIStyle.apply_button(ach_btn, UIStyle.GOLD, "ghost", 11)
	ach_btn.custom_minimum_size = Vector2(0, 34)
	UIStyle.place(ach_btn, 0, 0, 0, 0, 58, 132, 328, 168)
	ach_btn.pressed.connect(func() -> void: achievements_requested.emit())
	root.add_child(ach_btn)
	var ach_row := HBoxContainer.new()
	ach_row.set_anchors_preset(Control.PRESET_FULL_RECT)
	ach_row.offset_left = 12
	ach_row.offset_right = -10
	ach_row.add_theme_constant_override("separation", 8)
	ach_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ach_btn.add_child(ach_row)
	ach_row.add_child(UIStyle.label("★", 12, UIStyle.GOLD, HORIZONTAL_ALIGNMENT_CENTER))
	ach_row.add_child(UIStyle.label("成就  /  ACHIEVEMENTS", 11, UIStyle.TXT_SUB))
	var ach_fill := UIStyle.spacer()
	ach_row.add_child(ach_fill)
	ach_row.add_child(UIStyle.keycap("A", UIStyle.GOLD, 10))

	# 每日合约入口：紧跟成就下方，右侧角标显示今天还有几条可领
	var daily_btn := Button.new()
	daily_btn.focus_mode = Control.FOCUS_ALL
	daily_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	UIStyle.apply_button(daily_btn, UIStyle.GOLD, "ghost", 11)
	daily_btn.custom_minimum_size = Vector2(0, 34)
	UIStyle.place(daily_btn, 0, 0, 0, 0, 58, 174, 328, 210)
	daily_btn.pressed.connect(func() -> void: daily_requested.emit())
	root.add_child(daily_btn)
	var daily_row := HBoxContainer.new()
	daily_row.set_anchors_preset(Control.PRESET_FULL_RECT)
	daily_row.offset_left = 12
	daily_row.offset_right = -10
	daily_row.add_theme_constant_override("separation", 8)
	daily_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	daily_btn.add_child(daily_row)
	daily_row.add_child(UIStyle.label("◈", 13, UIStyle.GOLD, HORIZONTAL_ALIGNMENT_CENTER))
	daily_row.add_child(UIStyle.label("每日合约  /  DAILY", 11, UIStyle.TXT_SUB))
	var daily_fill := UIStyle.spacer()
	daily_row.add_child(daily_fill)
	_daily_badge = UIStyle.label_tech("", 11, UIStyle.GOLD, HORIZONTAL_ALIGNMENT_RIGHT, 1)
	daily_row.add_child(_daily_badge)
	daily_row.add_child(UIStyle.keycap("D", UIStyle.GOLD, 10))

	# 赛道档案入口：8 站精通 / 纪录总览，发车前先看进度
	var archive_btn := Button.new()
	archive_btn.focus_mode = Control.FOCUS_ALL
	archive_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	UIStyle.apply_button(archive_btn, ACCENT, "ghost", 11)
	archive_btn.custom_minimum_size = Vector2(0, 34)
	UIStyle.place(archive_btn, 0, 0, 0, 0, 58, 216, 328, 252)
	archive_btn.pressed.connect(func() -> void: archive_requested.emit())
	root.add_child(archive_btn)
	var archive_row := HBoxContainer.new()
	archive_row.set_anchors_preset(Control.PRESET_FULL_RECT)
	archive_row.offset_left = 12
	archive_row.offset_right = -10
	archive_row.add_theme_constant_override("separation", 8)
	archive_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	archive_btn.add_child(archive_row)
	archive_row.add_child(UIStyle.label("▤", 13, ACCENT, HORIZONTAL_ALIGNMENT_CENTER))
	archive_row.add_child(UIStyle.label("赛道档案  /  ARCHIVE", 11, UIStyle.TXT_SUB))
	var archive_fill := UIStyle.spacer()
	archive_row.add_child(archive_fill)
	archive_row.add_child(UIStyle.label_tracked("8 TRACKS", 9, UIStyle.a(ACCENT, 0.72),
		HORIZONTAL_ALIGNMENT_RIGHT, 1))
	archive_row.add_child(UIStyle.keycap("P", ACCENT, 10))

	# 车库入口移到右侧车辆卡旁边的大卡片（见 _build_garage_card）

	# ---- 右上：画质 + 设置 -------------------------------------------------
	quality_label = UIStyle.label_tracked("", 10, Color(0.68, 0.83, 0.90, 1.0),
		HORIZONTAL_ALIGNMENT_RIGHT, 1)
	# 右端留出与设置按钮的间距，避免画质信息文字顶到按钮边框
	UIStyle.place(quality_label, 1, 0, 1, 0, -700, 24, -326, 44)
	root.add_child(quality_label)

	_display_label = UIStyle.label_tracked("", 9, Color(0.54, 0.66, 0.75, 1.0),
		HORIZONTAL_ALIGNMENT_RIGHT, 1)
	UIStyle.place(_display_label, 1, 0, 1, 0, -700, 46, -326, 64)
	root.add_child(_display_label)

	var settings_btn := Button.new()
	settings_btn.focus_mode = Control.FOCUS_ALL
	settings_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	UIStyle.apply_button(settings_btn, ACCENT, "ghost", 12)
	UIStyle.place(settings_btn, 1, 0, 1, 0, -300, 22, -24, 62)
	settings_btn.pressed.connect(func() -> void: settings_requested.emit())
	root.add_child(settings_btn)
	var st_row := HBoxContainer.new()
	st_row.set_anchors_preset(Control.PRESET_FULL_RECT)
	st_row.offset_left = 12
	st_row.offset_right = -10
	st_row.add_theme_constant_override("separation", 8)
	st_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	settings_btn.add_child(st_row)
	st_row.alignment = BoxContainer.ALIGNMENT_CENTER
	st_row.add_child(UIStyle.keycap("S", ACCENT, 10))
	st_row.add_child(UIStyle.label("设置  /  SETTINGS", 12, UIStyle.TXT_SUB))

	# ---- 右侧上：车辆卡 + 车库大入口（原卡片一分为二）---------------------
	car_card = _make_card(CARD_X0, 96, -268, 300)
	root.add_child(car_card)
	_build_car_card(car_card)

	garage_card = _make_card(-260, 96, CARD_X1, 300)
	root.add_child(garage_card)
	_build_garage_card(garage_card)

	# ---- 右侧中：赛道卡 ----------------------------------------------------
	track_card = _make_card(CARD_X0, 306, CARD_X1, 680)
	root.add_child(track_card)
	_build_track_card(track_card)

	# ---- 右侧下：模式 + 发车 ----------------------------------------------
	_build_mode_row(root)
	_build_launch(root)

	# ---- 左下：当前站信息（赛道是主页主体，站号缩成右侧卡头的小标）---------
	var station_caption := UIStyle.label_tracked("CURRENT CIRCUIT   /   当前站", 10,
		Color(0.62, 0.80, 0.87, 1.0), HORIZONTAL_ALIGNMENT_LEFT, 2)
	UIStyle.place(station_caption, 0, 1, 0, 1, 48, -150, 520, -132)
	root.add_child(station_caption)

	station_label = UIStyle.label("", 14, Color(0.82, 0.89, 0.95, 1.0))
	station_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UIStyle.place(station_label, 0, 1, 0, 1, 48, -130, 900, -92)
	root.add_child(station_label)

	_mastery_label = UIStyle.label_tracked("", 11, Color(0.62, 0.72, 0.80, 1.0),
		HORIZONTAL_ALIGNMENT_LEFT, 1)
	_mastery_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	UIStyle.place(_mastery_label, 0, 1, 0, 1, 54, -89, 960, -67)
	root.add_child(_mastery_label)

	# ---- 底部按键提示（统一键帽样式）--------------------------------------
	footer_label = UIStyle.label("", 10, Color(0.55, 0.68, 0.78, 1.0))
	footer_label.visible = false
	UIStyle.place(footer_label, 0, 1, 0, 1, 44, -60, 900, -34)
	root.add_child(footer_label)
	_build_key_hints(root)

	_apply_accent(_track_accent)


func _build_key_hints(root: Control) -> void:
	var hints := [
		["摇杆", "选择"], ["LB/RB", "赛道"], ["Ⓐ", "发车 / 确认"], ["START", "返回 / 设置"],
		["X", "成就"], ["D", "合约"], ["P", "档案"], ["M", "模式"], ["Y", "车库"],
	]
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	row.alignment = BoxContainer.ALIGNMENT_BEGIN
	UIStyle.place(row, 0, 1, 0, 1, 44, -62, 980, -30)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(row)
	for entry in hints:
		var pair := HBoxContainer.new()
		pair.add_theme_constant_override("separation", 6)
		pair.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(pair)
		pair.add_child(UIStyle.keycap(String(entry[0]), ACCENT, 9))
		var lbl := UIStyle.label(String(entry[1]), 10, Color(0.76, 0.85, 0.92, 1.0))
		pair.add_child(lbl)


func accent_ref() -> Color:
	return _accent


func _build_car_card(card: Panel) -> void:
	UIStyle.add_top_glow(card, ACCENT, 0.9)
	car_index_label = _card_header(card, "01", "MACHINE", "车辆", ACCENT)

	# 车辆名 + 车漆色条
	car_swatch = ColorRect.new()
	car_swatch.custom_minimum_size = Vector2(3, 40)
	UIStyle.place(car_swatch, 0, 0, 0, 0, 14, 54, 17, 94)
	car_swatch.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(car_swatch)

	car_name_label = UIStyle.label_display("", 23, UIStyle.TXT, HORIZONTAL_ALIGNMENT_LEFT, 1)
	car_name_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	car_name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	UIStyle.place(car_name_label, 0, 0, 1, 0, 24, 50, -12, 88)
	card.add_child(car_name_label)

	car_cn_label = UIStyle.label("", 10, Color(0.64, 0.77, 0.86, 1.0))
	car_cn_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	UIStyle.place(car_cn_label, 0, 0, 1, 0, 24, 88, -12, 104)
	card.add_child(car_cn_label)

	# 性能三条（数值用琥珀色数据字体）
	var stats := VBoxContainer.new()
	stats.add_theme_constant_override("separation", 4)
	UIStyle.place(stats, 0, 0, 1, 0, 14, 112, -12, 170)
	card.add_child(stats)
	var stat_names := ["疾速", "加速", "操控"]
	for i in 3:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 7)
		row.custom_minimum_size = Vector2(0, 17)
		stats.add_child(row)
		var lbl := UIStyle.label(stat_names[i], 9, UIStyle.TXT_DIM)
		lbl.custom_minimum_size = Vector2(36, 0)
		row.add_child(lbl)
		var bar := UIBar.new()
		bar.setup(ACCENT)
		bar.show_ticks = true
		bar.segments = 12
		bar.chamfer = 3.0
		bar.custom_minimum_size = Vector2(0, 8)
		bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(bar)
		_stat_bars.append(bar)
		var value := UIStyle.label_tech("", 11, UIStyle.GOLD, HORIZONTAL_ALIGNMENT_RIGHT)
		value.custom_minimum_size = Vector2(24, 0)
		row.add_child(value)
		_stat_values.append(value)
	car_stats_label = UIStyle.label("", 1, Color.TRANSPARENT)
	car_stats_label.visible = false
	card.add_child(car_stats_label)

	var rule := ColorRect.new()
	rule.color = UIStyle.a(ACCENT, 0.14)
	UIStyle.place(rule, 0, 0, 1, 0, 14, 174, -12, 175)
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(rule)

	car_nav_label = UIStyle.label_tech("", 8, Color(0.60, 0.74, 0.84, 1.0),
		HORIZONTAL_ALIGNMENT_LEFT, 1)
	car_nav_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	car_nav_label.visible = false
	UIStyle.place(car_nav_label, 0, 0, 1, 0, 14, 176, -12, 194)
	card.add_child(car_nav_label)


## 首页车库大入口：放在车辆卡右侧，与车辆卡等高。
func _build_garage_card(card: Panel) -> void:
	UIStyle.add_top_glow(card, ACCENT, 0.95)
	var btn := Button.new()
	btn.focus_mode = Control.FOCUS_ALL
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	UIStyle.apply_button(btn, ACCENT, "ghost", 12)
	btn.set_anchors_preset(Control.PRESET_FULL_RECT)
	btn.offset_left = 2
	btn.offset_top = 2
	btn.offset_right = -2
	btn.offset_bottom = -2
	btn.pressed.connect(func() -> void: garage_requested.emit(selected_car_id()))
	card.add_child(btn)

	var glyph := UIStyle.label("▦", 46, UIStyle.a(ACCENT, 0.95), HORIZONTAL_ALIGNMENT_CENTER)
	UIStyle.place(glyph, 0, 0, 0, 0, 12, 34, 76, 94)
	btn.add_child(glyph)

	var title := UIStyle.label_display("车库", 30, UIStyle.TXT, HORIZONTAL_ALIGNMENT_LEFT, 2)
	UIStyle.place(title, 0, 0, 1, 0, 78, 32, -10, 72)
	btn.add_child(title)
	var en := UIStyle.label_tracked("GARAGE", 9, UIStyle.a(ACCENT, 0.92),
		HORIZONTAL_ALIGNMENT_LEFT, 2)
	UIStyle.place(en, 0, 0, 1, 0, 80, 72, -10, 90)
	btn.add_child(en)

	var desc := UIStyle.label("选车  ·  改装  ·  上赛道", 10, Color(0.68, 0.80, 0.88, 1.0))
	UIStyle.place(desc, 0, 0, 1, 0, 16, 104, -12, 124)
	btn.add_child(desc)

	var count := UIStyle.label_tech("", 13, UIStyle.GOLD)
	UIStyle.place(count, 0, 0, 1, 0, 16, 128, -12, 152)
	btn.add_child(count)
	count.text = "%02d  台可驾驶" % GameData.cars_specs.size()

	var keys := HBoxContainer.new()
	keys.add_theme_constant_override("separation", 6)
	UIStyle.place(keys, 0, 0, 0, 0, 16, 160, 150, 184)
	keys.mouse_filter = Control.MOUSE_FILTER_IGNORE
	btn.add_child(keys)
	keys.add_child(UIStyle.keycap("G", ACCENT, 10))
	keys.add_child(UIStyle.keycap("Y", ACCENT, 10))

	var arrow := UIStyle.label("›", 38, UIStyle.a(ACCENT, 0.95), HORIZONTAL_ALIGNMENT_RIGHT)
	UIStyle.place(arrow, 0, 1, 1, 1, 120, -66, -14, -12)
	btn.add_child(arrow)


func _build_track_card(card: Panel) -> void:
	UIStyle.add_top_glow(card, _track_accent, 0.9)
	_station_meta = _card_header(card, "02", "CIRCUIT", "赛道", ACCENT)

	# 赛道名 / 副标题
	track_name_label = UIStyle.label_display("", 26, UIStyle.TXT, HORIZONTAL_ALIGNMENT_LEFT, 1)
	track_name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	UIStyle.place(track_name_label, 0, 0, 1, 0, 18, 56, -204, 90)
	card.add_child(track_name_label)

	_track_title_rule = ColorRect.new()
	_track_title_rule.color = UIStyle.a(_track_accent, 0.7)
	UIStyle.place(_track_title_rule, 0, 0, 0, 0, 18, 92, 96, 94)
	card.add_child(_track_title_rule)

	track_en_label = UIStyle.label_tracked("", 9, UIStyle.a(UIStyle.GOLD, 0.95),
		HORIZONTAL_ALIGNMENT_LEFT, 2)
	UIStyle.place(track_en_label, 0, 0, 0, 0, 18, 98, 300, 114)
	card.add_child(track_en_label)

	track_meta_label = UIStyle.label("", 10, Color(0.70, 0.81, 0.89, 1.0))
	UIStyle.place(track_meta_label, 0, 0, 1, 0, 18, 116, -18, 132)
	card.add_child(track_meta_label)

	_record_best = UIStyle.label("", 10, Color(0.50, 0.86, 0.66, 1.0))
	_record_best.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	UIStyle.place(_record_best, 0, 0, 1, 0, 18, 134, -204, 150)
	card.add_child(_record_best)
	_record_lap = UIStyle.label("", 10, Color(0.50, 0.86, 0.66, 1.0))
	_record_lap.visible = false
	card.add_child(_record_lap)
	track_record_label = _record_best

	# 迷你地图
	_map_holder = Panel.new()
	_map_holder.add_theme_stylebox_override("panel", UIStyle.inset_style(ACCENT, 0.62))
	UIStyle.place(_map_holder, 1, 0, 1, 0, -192, 56, -18, 152)
	card.add_child(_map_holder)
	preview = Minimap.new()
	preview.set_anchors_preset(Control.PRESET_FULL_RECT)
	preview.offset_left = 7
	preview.offset_top = 7
	preview.offset_right = -7
	preview.offset_bottom = -7
	preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_map_holder.add_child(preview)

	# 站次切换 chips
	var chips_row := HBoxContainer.new()
	chips_row.add_theme_constant_override("separation", 5)
	chips_row.custom_minimum_size = Vector2(0, 26)
	UIStyle.place(chips_row, 0, 0, 1, 0, 18, 158, -18, 184)
	_track_chip_row = chips_row
	card.add_child(chips_row)
	for i in GameData.tracks.size():
		var btn := Button.new()
		btn.text = "%02d" % (i + 1)
		btn.toggle_mode = true
		btn.custom_minimum_size = Vector2(0, 24)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.add_theme_font_override("font", UIStyle.display_font())
		btn.add_theme_font_size_override("font_size", 10)
		btn.add_theme_color_override("font_color", UIStyle.TXT_DIM)
		btn.add_theme_color_override("font_hover_color", UIStyle.TXT)
		btn.add_theme_color_override("font_pressed_color", UIStyle.BG_DEEP)
		btn.add_theme_color_override("font_hover_pressed_color", UIStyle.BG_DEEP)
		for state in ["normal", "hover", "pressed", "focus", "hover_pressed"]:
			var active: bool = state in ["pressed", "hover_pressed"]
			var hover: bool = state in ["hover", "focus"]
			btn.add_theme_stylebox_override(state, UIStyle.chip_style(ACCENT, active, hover))
		btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		btn.pressed.connect(func() -> void: _select_station(i))
		chips_row.add_child(btn)
		station_buttons.append(btn)

	# 赛道数据小方块：长度 / 弯角 / 难度 / 圈数
	var stat_row := HBoxContainer.new()
	stat_row.add_theme_constant_override("separation", 6)
	UIStyle.place(stat_row, 0, 0, 1, 0, 18, 190, -18, 224)
	_track_stats_row = stat_row
	card.add_child(stat_row)
	var stat_titles := ["长度 LENGTH", "弯角 CORNERS", "难度 DIFF", "圈数 LAPS"]
	_track_stat_titles.clear()
	for i in 4:
		var cell := PanelContainer.new()
		cell.add_theme_stylebox_override("panel", UIStyle.inset_style(ACCENT, 0.5))
		cell.custom_minimum_size = Vector2(0, 34)
		cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		stat_row.add_child(cell)
		var col := VBoxContainer.new()
		col.add_theme_constant_override("separation", 0)
		cell.add_child(col)
		var title_label := UIStyle.label_tracked(stat_titles[i], 7, UIStyle.TXT_FAINT, HORIZONTAL_ALIGNMENT_LEFT, 1)
		col.add_child(title_label)
		_track_stat_titles.append(title_label)
		var value := UIStyle.label_tech("", 12, Color(0.90, 0.95, 1.0, 1.0))
		col.add_child(value)
		_track_stats.append(value)

	# 前后站
	var prev_track := UIStyle.make_button("▲    上一站", ACCENT, "ghost", 11, 28.0)
	UIStyle.place(prev_track, 0, 0, 0, 0, 18, 230, 234, 258)
	prev_track.pressed.connect(func() -> void: _step_track(-1))
	card.add_child(prev_track)
	var next_track := UIStyle.make_button("下一站    ▼", ACCENT, "ghost", 11, 28.0)
	UIStyle.place(next_track, 1, 0, 1, 0, -234, 230, -18, 258)
	next_track.pressed.connect(func() -> void: _step_track(1))
	card.add_child(next_track)

	# 最近 10 次成绩 / AI 路线库摘要：让主页直接看到持久化数据在生效
	var history_panel := Panel.new()
	history_panel.add_theme_stylebox_override("panel", UIStyle.inset_style(ACCENT, 0.48))
	UIStyle.place(history_panel, 0, 0, 1, 0, 18, 268, -18, 362)
	card.add_child(history_panel)
	_history_label = UIStyle.label("", 9, Color(0.62, 0.76, 0.85, 1.0))
	_history_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_history_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	UIStyle.place(_history_label, 0, 0, 1, 1, 12, 8, -12, -8)
	history_panel.add_child(_history_label)


func _build_mode_row(root: Control) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.alignment = BoxContainer.ALIGNMENT_END
	UIStyle.place(row, 1, 0, 1, 0, CARD_X0, 686, CARD_X1, 722)
	root.add_child(row)

	mode_label = UIStyle.label("M   模式  /  MODE", 10, Color(0.52, 0.68, 0.78, 1.0))
	mode_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mode_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(mode_label)
	for i in MODE_IDS.size():
		var btn := Button.new()
		btn.text = "%s  %s" % [MODE_NAMES[i], MODE_CN[i]]
		btn.toggle_mode = true
		btn.custom_minimum_size = Vector2(126, 36)
		btn.add_theme_font_override("font", UIStyle.display_font())
		btn.add_theme_font_size_override("font_size", 10)
		btn.add_theme_color_override("font_color", UIStyle.TXT_DIM)
		btn.add_theme_color_override("font_hover_color", UIStyle.TXT)
		btn.add_theme_color_override("font_pressed_color", UIStyle.BG_DEEP)
		btn.add_theme_color_override("font_hover_pressed_color", UIStyle.BG_DEEP)
		for state in ["normal", "hover", "pressed", "focus", "hover_pressed"]:
			var active: bool = state in ["pressed", "hover_pressed"]
			var hover: bool = state in ["hover", "focus"]
			btn.add_theme_stylebox_override(state, UIStyle.chip_style(ACCENT, active, hover))
		btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		btn.pressed.connect(_on_mode_button.bind(i))
		row.add_child(btn)
		_mode_buttons.append(btn)
	mode_button = _mode_buttons[0]


func _build_launch(root: Control) -> void:
	_launch_btn = Button.new()
	_launch_btn.focus_mode = Control.FOCUS_ALL
	_launch_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_launch_btn.add_theme_stylebox_override("normal", _launch_style(ACCENT, "normal"))
	_launch_btn.add_theme_stylebox_override("hover", _launch_style(ACCENT, "hover"))
	_launch_btn.add_theme_stylebox_override("pressed", _launch_style(ACCENT, "pressed"))
	_launch_btn.add_theme_stylebox_override("focus", _launch_style(ACCENT, "focus"))
	UIStyle.place(_launch_btn, 1, 1, 1, 1, CARD_X0, -170, CARD_X1, -42)
	_launch_btn.pressed.connect(_start)
	_launch_btn.mouse_entered.connect(_on_launch_hover.bind(true))
	_launch_btn.mouse_exited.connect(_on_launch_hover.bind(false))
	_launch_btn.focus_entered.connect(_on_launch_hover.bind(true))
	_launch_btn.focus_exited.connect(_on_launch_hover.bind(false))
	root.add_child(_launch_btn)

	# 内部渐变底 + 悬停辉光
	var tint := TextureRect.new()
	tint.texture = UIStyle.gradient_texture(Color(0.333, 0.906, 0.824, 0.10),
		Color(0.243, 0.760, 0.941, 0.02))
	tint.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tint.stretch_mode = TextureRect.STRETCH_SCALE
	tint.set_anchors_preset(Control.PRESET_FULL_RECT)
	tint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_launch_btn.add_child(tint)

	_launch_glow = TextureRect.new()
	_launch_glow.texture = UIStyle.glow_texture(ACCENT, 1.6)
	_launch_glow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_launch_glow.stretch_mode = TextureRect.STRETCH_SCALE
	_launch_glow.set_anchors_preset(Control.PRESET_FULL_RECT)
	_launch_glow.modulate = Color(1, 1, 1, 0.0)
	_launch_glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_launch_btn.add_child(_launch_glow)

	var bar := ColorRect.new()
	bar.color = ACCENT
	UIStyle.place(bar, 0, 0, 0, 1, 0, 10, 4, -10)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_launch_btn.add_child(bar)

	_launch_play = UIStyle.label("▶", 30, UIStyle.a(ACCENT, 0.98))
	UIStyle.place(_launch_play, 0, 0, 0, 1, 34, 0, 88, 0)
	_launch_play.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_launch_play.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_launch_btn.add_child(_launch_play)

	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	box.offset_left = 92
	box.offset_right = -188
	box.offset_top = 16
	box.offset_bottom = -16
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 1)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_launch_btn.add_child(box)
	_launch_title = UIStyle.label_display("START RACE", 33, UIStyle.TXT,
		HORIZONTAL_ALIGNMENT_LEFT, 3)
	box.add_child(_launch_title)
	var sub := UIStyle.label_tracked("开始比赛   ·   进入起跑线", 11,
		Color(0.80, 0.91, 0.95, 0.86), HORIZONTAL_ALIGNMENT_LEFT, 2)
	box.add_child(sub)

	var enter_key := UIStyle.keycap("ENTER  ⏎", ACCENT, 11)
	UIStyle.place(enter_key, 1, 0.5, 1, 0.5, -174, -16, -26, 20)
	_launch_btn.add_child(enter_key)

	_launch_arrow = UIStyle.label("›", 30, UIStyle.a(ACCENT, 0.0), HORIZONTAL_ALIGNMENT_RIGHT)
	UIStyle.place(_launch_arrow, 1, 0, 1, 1, -214, 0, -184, 0)
	_launch_arrow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_launch_btn.add_child(_launch_arrow)


func _launch_style(accent: Color, state: String) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	var hover: bool = state in ["hover", "focus"]
	s.bg_color = Color(0.026, 0.055, 0.068, 0.94) if not hover else Color(0.040, 0.098, 0.108, 0.97)
	if state == "pressed":
		s.bg_color = Color(0.020, 0.044, 0.055, 0.98)
	s.border_color = Color(accent.r, accent.g, accent.b, 0.62 if not hover else 1.0)
	s.set_border_width_all(1)
	s.set_corner_radius_all(UIStyle.R_LG)
	s.corner_detail = 5
	s.shadow_color = Color(accent.r, accent.g, accent.b, 0.20 if hover else 0.08)
	s.shadow_size = 20 if hover else 8
	s.anti_aliasing = true
	return s


func _on_launch_hover(hover: bool) -> void:
	var tw := _launch_btn.create_tween()
	tw.set_parallel(true)
	tw.tween_property(_launch_glow, "modulate:a", 0.30 if hover else 0.0, 0.20)
	tw.tween_property(_launch_title, "modulate", Color(1.10, 1.10, 1.10, 1.0) if hover else Color.WHITE, 0.18)
	tw.tween_property(_launch_play, "modulate", Color(1.30, 1.30, 1.30, 1.0) if hover else Color.WHITE, 0.18)
	tw.tween_property(_launch_arrow, "modulate:a", 1.0 if hover else 0.0, 0.18)
	tw.tween_property(_launch_arrow, "position:x", -6.0 if hover else 0.0, 0.18)


func _on_mode_button(i: int) -> void:
	if mode_index == i:
		return
	mode_index = i
	refresh()


# ---------------------------------------------------------------------------
# refresh
# ---------------------------------------------------------------------------

func _animate_in() -> void:
	for entry in [car_card, garage_card, track_card]:
		var card := entry as Control
		if card == null:
			continue
		card.modulate.a = 0.0
		var base: Vector2 = card.position
		card.position = base + Vector2(60.0, 0.0)
		var tw: Tween = card.create_tween()
		tw.set_parallel(true)
		tw.tween_property(card, "modulate:a", 1.0, 0.30)
		tw.tween_property(card, "position", base, 0.45).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	if _launch_btn != null:
		_launch_btn.modulate.a = 0.0
		_launch_btn.create_tween().tween_property(_launch_btn, "modulate:a", 1.0, 0.4).set_delay(0.18)
	if _frame != null:
		_frame.modulate.a = 0.0
		_frame.create_tween().tween_property(_frame, "modulate:a", 1.0, 0.6)


func set_stage_texture(tex: Texture2D) -> void:
	if stage_rect != null:
		stage_rect.texture = tex


func _radial_shade_texture() -> Texture2D:
	var size := 256
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.0, 0.0, 0.0, 0.0))
	for y in size:
		for x in size:
			var dx := (float(x) - size * 0.42) / (size * 0.55)
			var dy := (float(y) - size * 0.72) / (size * 0.40)
			var d := sqrt(dx * dx + dy * dy)
			var alpha := clampf(1.0 - d, 0.0, 1.0)
			alpha = alpha * alpha * 0.55
			img.set_pixel(x, y, Color(0.0, 0.0, 0.0, alpha))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


func _apply_backdrop() -> void:
	if bg_image == null:
		return
	var id := selected_track_id()
	if id.is_empty():
		return
	if not _bg_cache.has(id):
		var path := "res://assets/backdrops/%s.png" % id
		_bg_cache[id] = load(path) if ResourceLoader.exists(path) else null
	bg_image.texture = _bg_cache.get(id, null) as Texture2D


func refresh() -> void:
	_refresh_profile_badge()
	_refresh_daily_badge()
	if GameData.tracks.is_empty() or GameData.cars_specs.is_empty():
		return
	track_index = posmod(track_index, GameData.tracks.size())
	car_index = posmod(car_index, GameData.cars_specs.size())
	var track: Dictionary = GameData.tracks[track_index]
	var track_id := String(track.get("id", ""))
	var car_spec: Dictionary = GameData.cars_specs[car_index]
	var car_id := String(car_spec.get("id", ""))
	var mode: String = MODE_IDS[mode_index]
	var accent := Color.from_string(String(track.get("cardColor", "#55e7d2")), UIStyle.ACCENT)

	# 品牌青为主色，赛道主题色只用于赛道相关的小面积点缀
	_track_accent = accent
	_apply_accent(accent)

	var path: TrackPath = track_paths.get(track_id)
	if preview != null and path != null:
		preview.line_color = accent
		preview.setup(path, null, [])

	var length_km := float(track_lengths.get(track_id, 0.0)) / 1000.0
	track_name_label.text = String(track.get("name", track_id))
	track_en_label.text = "%s   ·   %s" % [String(track.get("en", "")), String(track.get("cornerType", ""))]
	track_meta_label.text = "%.2f km   ·   %d 圈   ·   难度 %s   ·   %s" % [
		length_km, int(track.get("laps", 3)), _difficulty_dots(int(track.get("difficulty", 2))),
		_weather_cn(String(track.get("weather", "none")))]
	_station_meta.text = "%02d / %02d" % [track_index + 1, GameData.tracks.size()]
	if bool(track.get("openWorld", false)):
		# 开放世界：没有赛道长度与圈数，改成面积 / 区域 / 难度 / 边界
		var ow_titles := ["面积 AREA", "区域 ZONES", "难度 DIFF", "边界 BORDER"]
		for i in mini(_track_stat_titles.size(), 4):
			_track_stat_titles[i].text = ow_titles[i]
		track_meta_label.text = "81 km²   ·   8 区域   ·   自由漫游   ·   没有边界"
		_track_stats[0].text = "81 km²"
		_track_stats[1].text = "8 域"
		_track_stats[2].text = "●".repeat(clampi(int(track.get("difficulty", 2)), 1, 5))
		_track_stats[3].text = "∞"
	else:
		var norm_titles := ["长度 LENGTH", "弯角 CORNERS", "难度 DIFF", "圈数 LAPS"]
		for i in mini(_track_stat_titles.size(), 4):
			_track_stat_titles[i].text = norm_titles[i]
		track_meta_label.text = "%.2f km   ·   %d 圈   ·   难度 %s   ·   %s" % [
			length_km, int(track.get("laps", 3)), _difficulty_dots(int(track.get("difficulty", 2))),
			_weather_cn(String(track.get("weather", "none")))]
		_track_stats[0].text = "%.2f km" % length_km
		_track_stats[1].text = str((track.get("points", []) as Array).size())
		_track_stats[2].text = "●".repeat(clampi(int(track.get("difficulty", 2)), 1, 5))
		_track_stats[3].text = str(int(track.get("laps", 3)))

	var best := RecordsStore.best_total(track_id, mode)
	var best_lap := RecordsStore.best_lap(track_id, mode)
	if best > 0.0:
		_record_best.text = "最佳总成绩  %s    ·    最佳单圈  %s" % [
			RaceManager.format_time(best), RaceManager.format_time(best_lap)]
	else:
		_record_best.text = "最佳总成绩  --:--.---    ·    最佳单圈  --:--.---"
	_record_lap.visible = false
	_refresh_mastery(track_id, float(track_lengths.get(track_id, 0.0)),
		int(track.get("difficulty", 2)))

	var tuned := Garage.effective_spec(car_id)
	car_swatch.color = Garage.paint_color(car_id)
	car_name_label.text = String(car_spec.get("name", "?"))
	car_cn_label.text = "%s   ·   %s" % [String(car_spec.get("cn", "")), String(car_spec.get("tag", ""))]
	var stats: Dictionary = tuned.get("stats", car_spec.get("stats", {}))
	_stat_bars[0].set_value(float(stats.get("speed", 50)) / 100.0)
	_stat_bars[1].set_value(float(stats.get("accel", 50)) / 100.0)
	_stat_bars[2].set_value(float(stats.get("handling", 50)) / 100.0)
	for i in 3:
		_stat_values[i].text = str(int(stats.get(["speed", "accel", "handling"][i], 50)))
	car_index_label.text = ""
	car_nav_label.visible = true
	car_nav_label.text = "极速 %d km/h   ·   %s" % [
		int(tuned.get("topKph", car_spec.get("topKph", 0))),
		"改装已应用" if _has_tuning(car_id) else "原厂状态"]

	mode_label.text = "M   模式  /  MODE"
	for i in _mode_buttons.size():
		_mode_buttons[i].button_pressed = (i == mode_index)
	quality_label.text = "画质  %s" % Settings.detail_name()
	_display_label.text = "%s   ·   %s" % [Settings.resolution_label(), Settings.fps_text()]

	for i in station_buttons.size():
		station_buttons[i].button_pressed = (i == track_index)

	if _station_big != null:
		_station_big.text = "%02d" % (track_index + 1)
	if _station_total != null:
		_station_total.text = "/ %02d" % GameData.tracks.size()
	station_label.text = "%s   ·   %s" % [String(track.get("name", track_id)), String(track.get("desc", ""))]
	_refresh_history(track_id, mode)

	# 只有真正变化时才通知主场景重建 3D 世界 / 换车
	var dirty := false
	if track_id != _prev_track_id:
		_prev_track_id = track_id
		track_changed.emit(track_id)
		dirty = true
		_flash_track()
	if car_id != _prev_car_id:
		_prev_car_id = car_id
		selection_changed.emit(car_id)
		dirty = true
	if mode_index != _prev_mode:
		_prev_mode = mode_index
		dirty = true
	if dirty:
		Settings.set_selection(track_id, car_id, mode)


func _has_tuning(car_id: String) -> bool:
	var cfg: Dictionary = Garage.config(car_id)
	for key in ["engine", "tires", "aero", "nitro"]:
		if int(cfg.get(key, 0)) > 0:
			return true
	return false


func _refresh_history(track_id: String, _mode: String) -> void:
	if _history_label == null:
		return
	var hist := RecordsStore.history(track_id)
	var routes := RecordsStore.line_candidates(track_id, 6).size()
	var lines: Array[String] = []
	if hist.is_empty():
		lines.append("赛道记录   暂无 · 完赛后自动保存最近 10 次与走线")
	else:
		lines.append("赛道记录   最近 %d 次   ·   AI 路线库 %d 条" % [hist.size(), routes])
		for i in mini(3, hist.size()):
			var run: Dictionary = hist[i]
			var car_name := String(GameData.car(String(run.get("car", ""))).get("name", "--"))
			lines.append("%02d   %s   %-3s   %s" % [i + 1,
				RaceManager.format_time(float(run.get("total", 0.0))),
				String(run.get("mode", "")).to_upper(), car_name])
		if hist.size() > 3:
			lines.append("… 其余 %d 次可在赛道档案里排序查看" % (hist.size() - 3))
	_history_label.text = "\n".join(lines)


func _flash_track() -> void:
	if track_card == null:
		return
	track_card.modulate = Color(1.15, 1.15, 1.15, 1.0)
	var tw := track_card.create_tween()
	tw.tween_property(track_card, "modulate", Color.WHITE, 0.35)


## 赛道主题色只作用于「赛道相关」的小面积元素，品牌青保持不变。
func _apply_accent(accent: Color) -> void:
	_track_accent = accent
	if _map_holder != null:
		_map_holder.add_theme_stylebox_override("panel", UIStyle.inset_style(accent, 0.62))
	if _frame != null:
		_frame.accent = UIStyle.ACCENT
		_frame.queue_redraw()
	if _slash != null:
		_slash.color = UIStyle.ACCENT
	if preview != null:
		preview.line_color = accent
	if _track_title_rule != null:
		_track_title_rule.color = UIStyle.a(accent, 0.7)
	if track_en_label != null:
		track_en_label.add_theme_color_override("font_color", UIStyle.a(UIStyle.GOLD, 0.95))
	for bar in _stat_bars:
		bar.setup(UIStyle.ACCENT)
	for btn in _mode_buttons:
		for state in ["normal", "hover", "pressed", "focus", "hover_pressed"]:
			var active: bool = state in ["pressed", "hover_pressed"]
			var hover: bool = state in ["hover", "focus"]
			btn.add_theme_stylebox_override(state, UIStyle.chip_style(UIStyle.ACCENT, active, hover))
	for btn in station_buttons:
		for state in ["normal", "hover", "pressed", "focus", "hover_pressed"]:
			var active: bool = state in ["pressed", "hover_pressed"]
			var hover: bool = state in ["hover", "focus"]
			btn.add_theme_stylebox_override(state, UIStyle.chip_style(accent, active, hover))
	if _launch_btn != null:
		_launch_btn.add_theme_stylebox_override("normal", _launch_style(UIStyle.ACCENT, "normal"))
		_launch_btn.add_theme_stylebox_override("hover", _launch_style(UIStyle.ACCENT, "hover"))
		_launch_btn.add_theme_stylebox_override("pressed", _launch_style(UIStyle.ACCENT, "pressed"))
		_launch_btn.add_theme_stylebox_override("focus", _launch_style(UIStyle.ACCENT, "focus"))
	if _launch_arrow != null:
		_launch_arrow.add_theme_color_override("font_color", UIStyle.a(UIStyle.ACCENT, 1.0))


func _difficulty_dots(value: int) -> String:
	var filled := clampi(value, 1, 5)
	return "●".repeat(filled) + "○".repeat(5 - filled)


func _weather_cn(weather: String) -> String:
	match weather:
		"rain":
			return "雨战"
		"wet":
			return "湿滑"
		"fog":
			return "雾战"
		"night":
			return "夜战"
		"snow":
			return "雪战"
	return "晴天"


func _modal_open() -> bool:
	# 上层成就 / 合约 / 档案 / 车库是独立 CanvasLayer，主菜单仍在场景里；
	# 不做门禁的话方向键会在弹层背后把赛道切走。
	var parent := get_parent()
	if parent == null:
		return false
	for child in parent.get_children():
		if child == self or not (child is CanvasLayer):
			continue
		var cl := child as CanvasLayer
		if cl.visible and cl.layer > layer:
			return true
	return false


func _process(delta: float) -> void:
	if not visible or _modal_open():
		_nav_cooldown = 0.0
		_nav_latched = false
		return
	# 弹层关闭 / 点击空白后焦点可能丢失，A 会变成空按：默认回到发车按钮。
	if get_viewport().gui_get_focus_owner() == null and _launch_btn != null:
		_launch_btn.grab_focus()
	# 键盘方向键 / 手柄左摇杆统一驱动焦点；这里做长按重复（十字键已解绑）。
	var v := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	if v.length() < 0.55:
		_nav_cooldown = 0.0
		_nav_latched = false
		return
	if _nav_cooldown > 0.0:
		_nav_cooldown -= delta
		return
	_nav_cooldown = 0.15 if _nav_latched else 0.34
	_nav_latched = true
	if absf(v.x) > absf(v.y):
		_move_focus(SIDE_RIGHT if v.x > 0.0 else SIDE_LEFT)
	else:
		_move_focus(SIDE_BOTTOM if v.y > 0.0 else SIDE_TOP)


func _move_focus(side: int) -> void:
	var owner := get_viewport().gui_get_focus_owner()
	if owner == null:
		if _launch_btn != null:
			_launch_btn.grab_focus()
		return
	var target := owner.find_valid_focus_neighbor(side)
	if target != null:
		target.grab_focus()


func _input(event: InputEvent) -> void:
	if not visible or _modal_open():
		return
	# 方向键/摇杆的焦点移动全部由 _process 轮询完成（带长按重复），
	# 这里吞掉事件，避免 GUI 原生焦点导航再走一遍导致一次拨杆跳两格。
	if event.is_action("ui_left") or event.is_action("ui_right") \
			or event.is_action("ui_up") or event.is_action("ui_down"):
		if event.is_action_pressed("ui_left") or event.is_action_pressed("ui_right") \
				or event.is_action_pressed("ui_up") or event.is_action_pressed("ui_down"):
			get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("ui_cancel"):
		settings_requested.emit()
		get_viewport().set_input_as_handled()
		return
	if event is InputEventJoypadButton and event.pressed:
		match (event as InputEventJoypadButton).button_index:
			JOY_BUTTON_X:
				achievements_requested.emit()
			JOY_BUTTON_Y:
				garage_requested.emit(selected_car_id())
			JOY_BUTTON_LEFT_SHOULDER:
				_step_track(-1)
			JOY_BUTTON_RIGHT_SHOULDER:
				_step_track(1)
			_:
				return
		get_viewport().set_input_as_handled()
		return
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var key := (event as InputEventKey).keycode
	match key:
		KEY_M:
			_toggle_mode()
		KEY_G:
			garage_requested.emit(selected_car_id())
			return
		KEY_A:
			achievements_requested.emit()
			return
		KEY_D:
			daily_requested.emit()
			return
		KEY_P:
			archive_requested.emit()
			return
		KEY_S, KEY_ESCAPE:
			settings_requested.emit()
			return
		KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6, KEY_7, KEY_8, KEY_9, KEY_0:
			# 9/0 分别顺延为第 10/11 张图（键位行 1..8 9 0）
			var station := key - KEY_1
			if key == KEY_9:
				station = 8
			elif key == KEY_0:
				station = 9
			if station < GameData.tracks.size():
				_select_station(station)
		_:
			return
	get_viewport().set_input_as_handled()


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

func _bar(value_0_100: int) -> String:
	var filled := clampi(int(round(value_0_100 / 10.0)), 0, 10)
	return "■".repeat(filled) + "□".repeat(10 - filled)
