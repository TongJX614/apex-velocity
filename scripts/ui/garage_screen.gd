class_name GarageScreen
extends CanvasLayer
## 车库 / 改装工坊 · v3（大网格选车 + 单条改装横条）。
##
## 布局：
##   · 左侧：3D 展台 + 左上车辆名称 / 规格（保持原设计）
##   · 右上：常驻大网格 —— 45 台车的离屏缩略图 + 名称，点击 / 摇杆直接选车
##   · 右中：一条突出的改装横条（轮毂 / 轮毂色 / 轮胎 / 尾翼 / 卡钳 / 车漆 / 升级）
##   · 右中下：性能数据卡（原厂 → 改装后）
##   · 右下：8 项性能升级（4×2）+ 积分 + 操作行（上赛道 / 重置 / 返回）
## 选车与改装是两类独立区域：TAB / 手柄 Y 在「网格」和「改装条」间切换。
##
## 对外 API 保持：closed / race_requested / world / initial_car / car_index /
## category / upgrade_index / refresh() / _current_car_id() / _open_car_grid()。

signal closed
signal race_requested(car_id: String)

const CATEGORIES := ["轮毂 WHEELS", "轮毂色 FINISH", "轮胎 TIRES", "尾翼 WINGS",
	"卡钳 CALIPERS", "车漆 PAINT", "升级 UPGRADES"]
const CATEGORY_KEYS := ["wheel", "rim", "tire", "wing", "caliper", "paint", ""]
const CATEGORY_SHORT := ["轮毂", "轮毂色", "轮胎", "尾翼", "卡钳", "车漆", "升级"]
const PAINT_CATEGORY := 5
const UPGRADE_CATEGORY := 6
const UPGRADE_LABELS := {
	"engine": "动力",
	"tires": "轮胎",
	"aero": "空力",
	"nitro": "氮气",
	"gearbox": "变速箱",
	"brakes": "制动",
	"weight": "轻量化",
	"suspension": "悬挂",
}

const GRID_COLUMNS := 5
const RAIL_X0 := -600.0
const RAIL_X1 := -32.0

## 缩略图：随包预烘焙（res://）优先，缺失时离屏补拍并缓存到 user://。
const THUMB_DIR := "user://car_thumbs/v1"
const STOCK_THUMB_DIR := "res://assets/ui/car_thumbs"
const THUMB_SIZE := Vector2i(320, 180)

var world: GarageWorld
var initial_car := ""

var car_index := 0
var category := 0
var upgrade_index := 0

var car_name_label: Label
var car_cn_label: Label
var car_footer_label: Label
var stats_title: Label
var stats_labels: Array[Label] = []
var upgrade_name_labels: Array[Label] = []
var upgrade_level_labels: Array[Label] = []
var hint_label: Label

var _accent := UIStyle.ACCENT
var _root: Control
var _frame: UIFrame
var _header_slash: ColorRect
var _car_swatch: ColorRect
var _index_label: Label
var _race_btn: Button

var _grid_card: Panel
var _grid_scroll: ScrollContainer
var _grid_count: Label
var _grid_cells: Array[Button] = []
var _grid_thumbs: Array[TextureRect] = []
var _grid_bgs: Array[ColorRect] = []
var _grid_names: Array[Label] = []

var _tuning_card: Panel
var _tuning_segs: Array[Button] = []
var _tuning_titles: Array[Label] = []
var _tuning_values: Array[Label] = []
var _value_flash: Label
var _paint_row: HBoxContainer
var _paint_chips: Array[Panel] = []
var _paint_index := 0
var _paint_label: Label

var _perf_card: Panel
var _stat_values: Array[Label] = []
var _stat_bars: Array[UIBar] = []
var _perf_note: Label

var _upgrades_card: Panel
var _upgrade_cells: Array[Panel] = []
var _upgrade_bars: Array[UIBar] = []
var _upgrade_note: Label
var _credit_label: Label

var _panel_focus := 0          # 0 = 车网格，1 = 改装条
var _grid_focus := 0           # 兼容旧逻辑：当前网格焦点（= car_index）
var _grid_open := false
var _nav_cooldown := 0.0

# 缩略图摄影棚
var _thumb_vp: SubViewport
var _thumb_cam: Camera3D
var _thumb_subject: Node3D
var _thumb_tex: Dictionary = {}
var _thumb_queue: Array[String] = []
var _thumb_busy := false


func _ready() -> void:
	layer = 25
	_resolve_initial_car()
	_build()
	refresh()
	_show_current_car()
	_setup_thumb_studio()
	_animate_in()
	_scroll_to_selected.call_deferred()


func _scroll_to_selected() -> void:
	if _grid_cells.is_empty() or _grid_scroll == null:
		return
	_grid_scroll.ensure_control_visible(_grid_cells[clampi(car_index, 0, _grid_cells.size() - 1)])


func _resolve_initial_car() -> void:
	car_index = 0
	var wanted := initial_car
	if wanted.is_empty():
		wanted = Garage.cars.keys()[0] if not Garage.cars.is_empty() else ""
	for i in GameData.cars_specs.size():
		if String(GameData.cars_specs[i].get("id", "")) == wanted:
			car_index = i
			return


func _current_car_id() -> String:
	if GameData.cars_specs.is_empty():
		return ""
	return String(GameData.cars_specs[clampi(car_index, 0, GameData.cars_specs.size() - 1)].get("id", ""))


func _show_current_car() -> void:
	if world != null:
		world.show_car(_current_car_id())


# ---------------------------------------------------------------------------
# 构建工具
# ---------------------------------------------------------------------------

func _make_panel(parent: Control, style: StyleBoxFlat) -> Panel:
	var panel := Panel.new()
	panel.add_theme_stylebox_override("panel", style)
	panel.mouse_filter = Control.MOUSE_FILTER_PASS
	parent.add_child(panel)
	return panel


func _kicker(parent: Control, text: String, y: float) -> Label:
	var kicker := UIStyle.kicker(text, _accent)
	UIStyle.place(kicker, 0, 0, 1, 0, 16, y, -200, y + 20)
	parent.add_child(kicker)
	return kicker


func _rule(parent: Control, y: float) -> void:
	var rule := ColorRect.new()
	rule.color = UIStyle.a(_accent, 0.14)
	UIStyle.place(rule, 0, 0, 1, 0, 16, y, -16, y + 1)
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(rule)


# ---------------------------------------------------------------------------
# UI
# ---------------------------------------------------------------------------

func _build() -> void:
	_root = Control.new()
	_root.name = "Root"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UIStyle.apply_theme(_root)
	add_child(_root)

	var bg := ColorRect.new()
	bg.color = Color(0.004, 0.007, 0.010, 0.12)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(bg)
	UIStyle.cinematic_backdrop(_root, 0.50, 0.80, 0.50)
	UIStyle.side_rail(_root, 660.0, 0.94)

	var top_scan := UIStyle.accent_line(UIStyle.ACCENT, 1.0, 0.28)
	top_scan.set_anchors_preset(Control.PRESET_TOP_WIDE)
	top_scan.offset_bottom = 2
	_root.add_child(top_scan)

	_frame = UIFrame.new()
	_frame.setup(UIStyle.ACCENT, 26.0, 0.20)
	UIStyle.place(_frame, 0, 0, 1, 1, 18, 18, -18, -18)
	_root.add_child(_frame)

	# ---- 左上：标题 + 车辆信息 -------------------------------------------
	_header_slash = ColorRect.new()
	_header_slash.color = UIStyle.ACCENT
	UIStyle.place(_header_slash, 0, 0, 0, 0, 40, 24, 44, 78)
	_header_slash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_header_slash)

	var title := UIStyle.label_display("GARAGE", 38, UIStyle.TXT,
		HORIZONTAL_ALIGNMENT_LEFT, 2)
	UIStyle.place(title, 0, 0, 0, 0, 58, 20, 520, 68)
	_root.add_child(title)

	var sub := UIStyle.label_tracked("改 装 工 坊   /   TUNING WORKSHOP", 10,
		Color(0.66, 0.82, 0.88, 1.0), HORIZONTAL_ALIGNMENT_LEFT, 2)
	UIStyle.place(sub, 0, 0, 0, 0, 60, 70, 720, 92)
	_root.add_child(sub)

	_car_swatch = ColorRect.new()
	_car_swatch.custom_minimum_size = Vector2(4, 44)
	UIStyle.place(_car_swatch, 0, 0, 0, 0, 42, 118, 46, 162)
	_car_swatch.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_car_swatch)

	car_name_label = UIStyle.label_display("", 34, UIStyle.TXT,
		HORIZONTAL_ALIGNMENT_LEFT, 1)
	car_name_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.72))
	car_name_label.add_theme_constant_override("outline_size", 5)
	car_name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	UIStyle.place(car_name_label, 0, 0, 0, 0, 58, 110, 940, 160)
	_root.add_child(car_name_label)

	car_cn_label = UIStyle.label("", 13, Color(0.72, 0.83, 0.91, 1.0))
	UIStyle.place(car_cn_label, 0, 0, 0, 0, 60, 162, 940, 184)
	_root.add_child(car_cn_label)

	car_footer_label = UIStyle.label("", 11, Color(0.55, 0.70, 0.80, 1.0))
	car_footer_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	UIStyle.place(car_footer_label, 0, 0, 0, 0, 60, 188, 940, 208)
	_root.add_child(car_footer_label)

	_index_label = UIStyle.label("", 10, Color(0.56, 0.72, 0.82, 1.0))
	UIStyle.place(_index_label, 0, 0, 0, 0, 60, 214, 940, 236)
	_root.add_child(_index_label)

	_build_car_grid_card()
	_build_tuning_card()
	_build_perf_card()
	_build_upgrades_card()
	_build_actions()
	_build_hint_row()


# ---------------------------------------------------------------------------
# 右上：常驻大网格选车
# ---------------------------------------------------------------------------

func _build_car_grid_card() -> void:
	_grid_card = _make_panel(_root, UIStyle.card_style(UIStyle.ACCENT, false, 0.92))
	UIStyle.place(_grid_card, 1, 0, 1, 0, RAIL_X0, 56, RAIL_X1, 414)
	UIStyle.add_top_glow(_grid_card, _accent, 0.9)
	_kicker(_grid_card, "SELECT MACHINE   /   选车", 7)
	_grid_count = UIStyle.label_tracked("", 9, Color(0.62, 0.78, 0.86, 1.0),
		HORIZONTAL_ALIGNMENT_RIGHT, 1)
	UIStyle.place(_grid_count, 0, 0, 1, 0, 280, 10, -16, 30)
	_grid_card.add_child(_grid_count)
	_rule(_grid_card, 32)

	_grid_scroll = ScrollContainer.new()
	_grid_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_grid_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	UIStyle.place(_grid_scroll, 0, 0, 1, 1, 14, 36, -14, -6)
	_grid_card.add_child(_grid_scroll)

	var grid := GridContainer.new()
	grid.columns = GRID_COLUMNS
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 6)
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid_scroll.add_child(grid)

	for i in GameData.cars_specs.size():
		var spec: Dictionary = GameData.cars_specs[i]
		var car_id := String(spec.get("id", ""))
		var btn := Button.new()
		btn.name = "Car_%02d" % i
		btn.focus_mode = Control.FOCUS_ALL
		btn.custom_minimum_size = Vector2(103, 74)
		btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		btn.add_theme_stylebox_override("normal", _tile_style(false, false))
		btn.add_theme_stylebox_override("hover", _tile_style(false, true))
		btn.add_theme_stylebox_override("pressed", _tile_style(true, false))
		btn.add_theme_stylebox_override("focus", _tile_style(false, true))
		var idx := i
		btn.pressed.connect(func() -> void: _pick_car(idx, true))
		grid.add_child(btn)
		_grid_cells.append(btn)

		var bg := ColorRect.new()
		bg.color = UIStyle.a(Garage.paint_color(car_id), 0.16)
		bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		bg.set_anchors_preset(Control.PRESET_FULL_RECT)
		bg.offset_left = 5
		bg.offset_top = 5
		bg.offset_right = -5
		bg.offset_bottom = -24
		btn.add_child(bg)
		_grid_bgs.append(bg)

		var thumb := TextureRect.new()
		thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
		thumb.set_anchors_preset(Control.PRESET_FULL_RECT)
		thumb.offset_left = 5
		thumb.offset_top = 5
		thumb.offset_right = -5
		thumb.offset_bottom = -24
		btn.add_child(thumb)
		_grid_thumbs.append(thumb)

		var name_label := UIStyle.label(String(spec.get("name", "?")), 9,
			Color(0.78, 0.86, 0.93, 1.0), HORIZONTAL_ALIGNMENT_CENTER)
		name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		UIStyle.place(name_label, 0, 1, 1, 1, 4, -20, -4, -4)
		btn.add_child(name_label)
		_grid_names.append(name_label)


func _tile_style(selected: bool, hover: bool) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	if selected:
		s.bg_color = Color(0.070, 0.142, 0.160, 0.96)
	else:
		s.bg_color = Color(0.058, 0.084, 0.108, 0.94) if hover else Color(0.030, 0.046, 0.060, 0.90)
	s.border_color = UIStyle.a(UIStyle.ACCENT, 0.95 if selected else (0.45 if hover else 0.14))
	s.set_border_width_all(2 if selected else 1)
	s.set_corner_radius_all(4)
	s.corner_detail = 3
	s.anti_aliasing = true
	if selected:
		s.shadow_color = UIStyle.a(UIStyle.ACCENT, 0.16)
		s.shadow_size = 6
	return s


# ---------------------------------------------------------------------------
# 右中：改装横条
# ---------------------------------------------------------------------------

func _build_tuning_card() -> void:
	_tuning_card = _make_panel(_root, UIStyle.card_style(UIStyle.ACCENT, false, 0.92))
	UIStyle.place(_tuning_card, 1, 0, 1, 0, RAIL_X0, 422, RAIL_X1, 514)
	UIStyle.add_top_glow(_tuning_card, _accent, 0.9)
	_kicker(_tuning_card, "TUNING   /   改装", 4)
	_value_flash = UIStyle.label_tracked("", 9, Color(0.62, 0.78, 0.86, 1.0),
		HORIZONTAL_ALIGNMENT_RIGHT, 1)
	_value_flash.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	UIStyle.place(_value_flash, 0, 0, 1, 0, 220, 6, -16, 26)
	_tuning_card.add_child(_value_flash)

	for i in CATEGORIES.size():
		var seg := Button.new()
		seg.focus_mode = Control.FOCUS_ALL
		seg.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		seg.add_theme_stylebox_override("normal", _seg_style(false, false))
		seg.add_theme_stylebox_override("hover", _seg_style(false, true))
		seg.add_theme_stylebox_override("pressed", _seg_style(true, false))
		seg.add_theme_stylebox_override("focus", _seg_style(false, true))
		# 横条总长 = 操作行（上赛道 + 返回/重置）总宽，按钮等分铺满
		var seg_w := (RAIL_X1 - RAIL_X0 - 6.0 * 4.0) / 7.0
		var seg_x := i * (seg_w + 4.0)
		UIStyle.place(seg, 0, 0, 0, 0, seg_x, 27, seg_x + seg_w, 67)
		var idx := i
		seg.pressed.connect(func() -> void: _select_category(idx))
		_tuning_card.add_child(seg)
		_tuning_segs.append(seg)

		var title := UIStyle.label(CATEGORY_SHORT[i], 10, Color(0.82, 0.89, 0.95, 1.0),
			HORIZONTAL_ALIGNMENT_CENTER)
		UIStyle.place(title, 0, 0, 1, 0, 2, 3, -2, 19)
		seg.add_child(title)
		_tuning_titles.append(title)

		var value := UIStyle.label_tech("", 8, UIStyle.GOLD, HORIZONTAL_ALIGNMENT_CENTER)
		value.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		UIStyle.place(value, 0, 0, 1, 0, 2, 18, -2, 34)
		seg.add_child(value)
		_tuning_values.append(value)

	# 车漆色板：只在「车漆」分类下出现，嵌在横条内
	_paint_row = HBoxContainer.new()
	_paint_row.add_theme_constant_override("separation", 8)
	_paint_row.alignment = BoxContainer.ALIGNMENT_BEGIN
	UIStyle.place(_paint_row, 0, 0, 1, 0, 16, 71, -180, 88)
	_paint_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tuning_card.add_child(_paint_row)
	for i in 8:
		var chip := Panel.new()
		chip.custom_minimum_size = Vector2(30, 15)
		chip.mouse_filter = Control.MOUSE_FILTER_STOP
		chip.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		chip.visible = false
		var chip_idx := i
		chip.gui_input.connect(func(event: InputEvent) -> void:
			if event is InputEventMouseButton and event.pressed \
					and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
				_select_paint(chip_idx))
		_paint_row.add_child(chip)
		_paint_chips.append(chip)
	_paint_label = UIStyle.label("", 9, UIStyle.TXT_DIM, HORIZONTAL_ALIGNMENT_RIGHT)
	_paint_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	UIStyle.place(_paint_label, 0, 0, 1, 0, 260, 70, -16, 88)
	_tuning_card.add_child(_paint_label)


func _seg_style(selected: bool, hover: bool) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	if selected:
		s.bg_color = UIStyle.a(UIStyle.ACCENT, 0.86)
	else:
		s.bg_color = Color(0.078, 0.118, 0.146, 0.95) if hover else Color(0.035, 0.052, 0.066, 0.92)
	s.border_color = UIStyle.a(UIStyle.ACCENT, 0.98 if selected else (0.50 if hover else 0.16))
	s.set_border_width_all(1)
	s.set_corner_radius_all(3)
	s.corner_detail = 3
	s.anti_aliasing = true
	if selected:
		s.shadow_color = UIStyle.a(UIStyle.ACCENT, 0.22)
		s.shadow_size = 6
	return s


# ---------------------------------------------------------------------------
# 右中下：性能数据
# ---------------------------------------------------------------------------

func _build_perf_card() -> void:
	_perf_card = _make_panel(_root, UIStyle.card_style(UIStyle.ACCENT, false, 0.91))
	UIStyle.place(_perf_card, 1, 0, 1, 0, RAIL_X0, 522, RAIL_X1, 626)
	UIStyle.add_top_glow(_perf_card, _accent, 0.85)
	_kicker(_perf_card, "PERFORMANCE   /   性能", 4)
	_perf_note = UIStyle.label_tracked("原厂  →  改装后", 9,
		Color(0.55, 0.68, 0.78, 1.0), HORIZONTAL_ALIGNMENT_RIGHT, 1)
	_perf_note.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	UIStyle.place(_perf_note, 0, 0, 1, 0, 240, 6, -16, 26)
	_perf_card.add_child(_perf_note)

	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 0)
	UIStyle.place(grid, 0, 0, 1, 0, 16, 30, -16, 62)
	_perf_card.add_child(grid)
	var stat_names := ["极速 TOP", "零百 0-100", "抓地 GRIP", "氮气 NITRO"]
	for i in 4:
		var cell := VBoxContainer.new()
		cell.add_theme_constant_override("separation", 0)
		cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		grid.add_child(cell)
		cell.add_child(UIStyle.label(stat_names[i], 8, UIStyle.TXT_DIM))
		var value := UIStyle.label_tech("", 11, Color(0.90, 0.94, 0.98, 1.0))
		value.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		cell.add_child(value)
		_stat_values.append(value)
	stats_title = _stat_values[0]

	var bars := VBoxContainer.new()
	bars.add_theme_constant_override("separation", 3)
	UIStyle.place(bars, 0, 0, 1, 0, 16, 66, -16, 98)
	_perf_card.add_child(bars)
	var bar_names := ["疾速  SPEED", "加速  ACCEL", "操控  HANDLING"]
	for i in 3:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		row.custom_minimum_size = Vector2(0, 9)
		bars.add_child(row)
		var lbl := UIStyle.label(bar_names[i], 8, UIStyle.TXT_DIM)
		lbl.custom_minimum_size = Vector2(98, 0)
		row.add_child(lbl)
		var bar := UIBar.new()
		bar.setup(_accent)
		bar.segments = 16
		bar.chamfer = 3.0
		bar.custom_minimum_size = Vector2(0, 7)
		bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(bar)
		_stat_bars.append(bar)


# ---------------------------------------------------------------------------
# 右下：性能升级
# ---------------------------------------------------------------------------

func _build_upgrades_card() -> void:
	_upgrades_card = _make_panel(_root, UIStyle.card_style(UIStyle.ACCENT, false, 0.91))
	UIStyle.place(_upgrades_card, 1, 0, 1, 0, RAIL_X0, 634, RAIL_X1, 766)
	UIStyle.add_top_glow(_upgrades_card, _accent, 0.85)
	_kicker(_upgrades_card, "UPGRADES   /   性能升级   ·   每项 10 档", 3)
	_credit_label = UIStyle.label_tech("", 10, UIStyle.GOLD, HORIZONTAL_ALIGNMENT_RIGHT)
	UIStyle.place(_credit_label, 0, 0, 1, 0, 300, 5, -16, 25)
	_upgrades_card.add_child(_credit_label)

	for i in Garage.UPGRADE_KEYS.size():
		var key: String = Garage.UPGRADE_KEYS[i]
		var cell := Panel.new()
		cell.add_theme_stylebox_override("panel", UIStyle.inset_style(_accent, 0.34))
		cell.mouse_filter = Control.MOUSE_FILTER_STOP
		cell.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		var col_index := i % 4
		var row_index := i / 4
		UIStyle.place(cell, 0, 0, 0, 0, 16 + col_index * 134, 30 + row_index * 32,
			144 + col_index * 134, 58 + row_index * 32)
		_upgrades_card.add_child(cell)
		_upgrade_cells.append(cell)

		var name_label := UIStyle.label_display(UPGRADE_LABELS.get(key, key), 10,
			Color(0.82, 0.88, 0.94, 1.0), HORIZONTAL_ALIGNMENT_LEFT, 1)
		UIStyle.place(name_label, 0, 0, 1, 0, 8, 2, -46, 18)
		cell.add_child(name_label)
		upgrade_name_labels.append(name_label)

		var level_label := UIStyle.label_tech("", 9, UIStyle.GREEN, HORIZONTAL_ALIGNMENT_RIGHT)
		UIStyle.place(level_label, 0, 0, 1, 0, -46, 2, -8, 18)
		cell.add_child(level_label)
		upgrade_level_labels.append(level_label)

		var bar := UIBar.new()
		bar.setup(UIStyle.GREEN)
		bar.show_ticks = true
		bar.segments = 10
		bar.chamfer = 2.0
		bar.danger_from = 1.2
		UIStyle.place(bar, 0, 0, 1, 0, 8, 20, -8, 26)
		cell.add_child(bar)
		_upgrade_bars.append(bar)

		var cell_i := i
		cell.mouse_entered.connect(func() -> void:
			category = UPGRADE_CATEGORY
			upgrade_index = cell_i
			_panel_focus = 1
			_refresh_tuning_styles()
			_refresh_upgrade_styles()
			_refresh_upgrade_note(_current_car_id()))
		cell.gui_input.connect(func(event: InputEvent) -> void:
			if event is InputEventMouseButton and event.pressed \
					and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
				category = UPGRADE_CATEGORY
				upgrade_index = cell_i
				_panel_focus = 1
				_confirm()
				cell.accept_event())

	_upgrade_note = UIStyle.label("", 9, UIStyle.TXT_FAINT)
	_upgrade_note.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	UIStyle.place(_upgrade_note, 0, 0, 1, 0, 16, 98, -16, 122)
	_upgrades_card.add_child(_upgrade_note)


# ---------------------------------------------------------------------------
# 操作行 / 提示
# ---------------------------------------------------------------------------

func _build_actions() -> void:
	var actions := Control.new()
	UIStyle.place(actions, 1, 0, 1, 0, RAIL_X0, 774, RAIL_X1, 846)
	actions.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(actions)

	_race_btn = Button.new()
	_race_btn.focus_mode = Control.FOCUS_ALL
	_race_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	UIStyle.apply_button(_race_btn, UIStyle.ACCENT, "primary", 14)
	UIStyle.place(_race_btn, 0, 0, 0, 0, 0, 0, 380, 58)
	_race_btn.pressed.connect(func() -> void: race_requested.emit(_current_car_id()))
	actions.add_child(_race_btn)
	var race_row := HBoxContainer.new()
	race_row.set_anchors_preset(Control.PRESET_FULL_RECT)
	race_row.offset_left = 14
	race_row.offset_right = -14
	race_row.add_theme_constant_override("separation", 10)
	race_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_race_btn.add_child(race_row)
	race_row.add_child(UIStyle.keycap("SPACE", UIStyle.ACCENT, 10))
	race_row.add_child(UIStyle.label_display("上赛道   /   START RACE", 14, UIStyle.TXT,
		HORIZONTAL_ALIGNMENT_LEFT, 2))
	race_row.add_child(UIStyle.spacer())
	race_row.add_child(UIStyle.label("›", 20, UIStyle.a(UIStyle.ACCENT, 0.95),
		HORIZONTAL_ALIGNMENT_RIGHT))

	var reset := UIStyle.make_button("L   重置升级", UIStyle.GOLD, "ghost", 11, 27.0)
	UIStyle.place(reset, 0, 0, 0, 0, 388, 31, 568, 58)
	reset.pressed.connect(func() -> void:
		Garage.reset_upgrades(_current_car_id())
		refresh())
	actions.add_child(reset)

	var back := UIStyle.make_button("START / ESC   返回", UIStyle.ACCENT, "ghost", 10, 27.0)
	UIStyle.place(back, 0, 0, 0, 0, 388, 0, 568, 27)
	back.pressed.connect(func() -> void: closed.emit())
	actions.add_child(back)

	hint_label = UIStyle.label("", 10, Color(0.58, 0.70, 0.79, 1.0))
	hint_label.visible = false
	_root.add_child(hint_label)


func _build_hint_row() -> void:
	var hints := [
		["拖拽", "旋转车身"], ["TAB / Ⓨ", "网格·改装"], ["←→↑↓", "选择"],
		["Ⓐ / ENTER", "选车·升级"], ["SPACE", "上赛道"], ["START", "返回"],
	]
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	UIStyle.place(row, 1, 1, 1, 1, RAIL_X0 - 40, -48, RAIL_X1, -22)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(row)
	for entry in hints:
		var pair := HBoxContainer.new()
		pair.add_theme_constant_override("separation", 5)
		pair.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(pair)
		pair.add_child(UIStyle.keycap(String(entry[0]), UIStyle.ACCENT, 9))
		pair.add_child(UIStyle.label(String(entry[1]), 9, Color(0.60, 0.72, 0.81, 1.0)))


# ---------------------------------------------------------------------------
# 逻辑：选车
# ---------------------------------------------------------------------------

func _pick_car(index: int, grab: bool = false) -> void:
	if index < 0 or index >= GameData.cars_specs.size():
		return
	car_index = index
	_grid_focus = index
	_panel_focus = 0
	# 选中即默认：持久化后首页重建菜单会读 Settings.last_car，展示车同步更换。
	var picked_id := _current_car_id()
	if Settings.last_car != picked_id:
		Settings.last_car = picked_id
		Settings.save_settings()
	_show_current_car()
	refresh()
	if grab and not _grid_cells.is_empty():
		var cell := _grid_cells[car_index]
		cell.grab_focus()
		_grid_scroll.ensure_control_visible(cell)


func _select_category(index: int) -> void:
	category = posmod(index, CATEGORIES.size())
	_panel_focus = 1
	refresh()


func _select_paint(index: int) -> void:
	var car_id := _current_car_id()
	if Garage.get_option(car_id, "paint") == index:
		return
	Garage.set_option(car_id, "paint", index)
	_after_look_change(car_id)
	refresh()


func _after_look_change(car_id: String) -> void:
	_show_current_car()


func _reset_upgrades() -> void:
	Garage.reset_upgrades(_current_car_id())
	refresh()


# ---------------------------------------------------------------------------
# 缩略图摄影棚
# ---------------------------------------------------------------------------

func _thumb_path(car_id: String) -> String:
	return THUMB_DIR.path_join(car_id + ".png")


func _setup_thumb_studio() -> void:
	if DisplayServer.get_name() == "headless":
		return   # headless 无真实渲染，缩略图会全黑
	_thumb_vp = SubViewport.new()
	_thumb_vp.name = "CarThumbStudio"
	_thumb_vp.size = THUMB_SIZE
	_thumb_vp.transparent_bg = true
	_thumb_vp.own_world_3d = true
	_thumb_vp.msaa_3d = Viewport.MSAA_4X
	_thumb_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_thumb_vp)

	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.74, 0.80, 0.88)
	env.ambient_light_energy = 1.25
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.tonemap_exposure = 1.15
	env.glow_enabled = true
	env.glow_intensity = 0.03
	var we := WorldEnvironment.new()
	we.environment = env
	_thumb_vp.add_child(we)

	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-40.0, 34.0, 0.0)
	key.light_energy = 2.0
	_thumb_vp.add_child(key)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-16.0, -118.0, 0.0)
	fill.light_energy = 0.60
	fill.light_color = Color(0.78, 0.86, 1.0)
	_thumb_vp.add_child(fill)
	var rim := DirectionalLight3D.new()
	rim.rotation_degrees = Vector3(-28.0, 168.0, 0.0)
	rim.light_energy = 1.30
	rim.light_color = Color(0.72, 0.88, 1.0)
	_thumb_vp.add_child(rim)

	_thumb_cam = Camera3D.new()
	_thumb_cam.fov = 28.0
	_thumb_vp.add_child(_thumb_cam)

	# 先读用户缓存，再读随包预烘焙图（首次进车库即秒开），最后才补拍
	var missing: Array[String] = []
	for spec in GameData.cars_specs:
		var car_id := String(spec.get("id", ""))
		if car_id.is_empty():
			continue
		var path := _thumb_path(car_id)
		if FileAccess.file_exists(path):
			var img := Image.load_from_file(ProjectSettings.globalize_path(path))
			if img != null and not img.is_empty():
				_thumb_tex[car_id] = ImageTexture.create_from_image(img)
				continue
		var stock_path := STOCK_THUMB_DIR.path_join(car_id + ".png")
		var stock: Texture2D = null
		if ResourceLoader.exists(stock_path):
			stock = ResourceLoader.load(stock_path, "Texture2D") as Texture2D
		else:
			# 资源尚未导入（编辑器直跑）时直接解码源 PNG；导出包走上面的导入路径
			var bytes := FileAccess.get_file_as_bytes(stock_path)
			if not bytes.is_empty():
				var stock_img := Image.new()
				if stock_img.load_png_from_buffer(bytes) == OK:
					stock = ImageTexture.create_from_image(stock_img)
		if stock != null:
			_thumb_tex[car_id] = stock
			continue
		missing.append(car_id)
	_refresh_thumb_textures()

	# 队列：当前车优先，然后按列表顺序
	if not missing.is_empty():
		var current := _current_car_id()
		if missing.has(current):
			_thumb_queue.append(current)
		for car_id in missing:
			if car_id != current:
				_thumb_queue.append(car_id)


func _refresh_thumb_textures() -> void:
	for i in _grid_thumbs.size():
		var car_id := String(GameData.cars_specs[i].get("id", ""))
		_grid_thumbs[i].texture = _thumb_tex.get(car_id, null)


func _process_thumb_queue() -> void:
	if _thumb_busy or _thumb_queue.is_empty() or _thumb_vp == null:
		return
	_thumb_busy = true
	var car_id := String(_thumb_queue.pop_front())
	_render_thumb(car_id)


## 供截图/烘焙工具判断：所有缺图是否都拍完了。
func thumbs_ready() -> bool:
	return _thumb_queue.is_empty() and not _thumb_busy


func _render_thumb(car_id: String) -> void:
	var holder := Node3D.new()
	holder.name = "ThumbCar"
	_thumb_vp.add_child(holder)
	_thumb_subject = holder
	var spec := Garage.effective_spec(car_id)
	if spec.is_empty():
		spec = GameData.car(car_id)
	var result := CarVisual.build(spec, holder)
	var model := result.get("model") as Node3D
	var box := AABB(Vector3(-2.2, 0.0, -1.0), Vector3(4.4, 1.3, 2.0))
	if model != null:
		GarageLook.apply(model, car_id, Garage.config(car_id))
		box = _model_aabb(model)
	if box.size.length() < 0.5:
		box = AABB(Vector3(-2.2, 0.0, -1.0), Vector3(4.4, 1.3, 2.0))
	var center := box.position + box.size * 0.5
	var radius := maxf(box.size.length() * 0.5, 0.6)
	var dist := radius / tan(deg_to_rad(_thumb_cam.fov * 0.5)) * 0.88
	_thumb_cam.near = maxf(dist * 0.05, 0.05)
	_thumb_cam.far = dist * 12.0
	_thumb_cam.position = center + Vector3(dist * 0.60, dist * 0.34, dist * 0.74)
	_thumb_cam.look_at(center, Vector3.UP)

	_thumb_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := _thumb_vp.get_texture().get_image()
	_thumb_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED

	_thumb_subject.queue_free()
	_thumb_subject = null

	if img != null and not img.is_empty():
		var tex := ImageTexture.create_from_image(img)
		_thumb_tex[car_id] = tex
		for i in _grid_thumbs.size():
			if String(GameData.cars_specs[i].get("id", "")) == car_id:
				_grid_thumbs[i].texture = tex
				break
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(THUMB_DIR))
		img.save_png(_thumb_path(car_id))
	_thumb_busy = false


func _model_aabb(model: Node3D) -> AABB:
	var box := AABB()
	var first := true
	for child in model.find_children("*", "MeshInstance3D", true, false):
		var mi := child as MeshInstance3D
		if mi.mesh == null or not mi.visible:
			continue
		var rel := _relative_to(mi, model)
		var b: AABB = rel * mi.mesh.get_aabb()
		if first:
			box = b
			first = false
		else:
			box = box.merge(b)
	return box


func _relative_to(node: Node, ancestor: Node) -> Transform3D:
	var rel := Transform3D.IDENTITY
	var cur: Node = node
	while cur != null and cur != ancestor:
		if cur is Node3D:
			rel = (cur as Node3D).transform * rel
		cur = cur.get_parent()
	return rel


# ---------------------------------------------------------------------------
# refresh
# ---------------------------------------------------------------------------

func refresh() -> void:
	if GameData.cars_specs.is_empty():
		return
	car_index = posmod(car_index, GameData.cars_specs.size())
	category = posmod(category, CATEGORIES.size())
	upgrade_index = posmod(upgrade_index, Garage.UPGRADE_KEYS.size())
	_grid_focus = car_index
	var car_id := _current_car_id()
	var spec: Dictionary = GameData.car(car_id)
	var tuned := Garage.effective_spec(car_id)

	_car_swatch.color = Garage.paint_color(car_id)
	car_name_label.text = String(spec.get("name", car_id))
	car_cn_label.text = "%s   ·   %s" % [String(spec.get("cn", "")), String(spec.get("badge", ""))]
	car_footer_label.text = "%s   ·   极速 %d km/h   ·   零百 %.1fs   ·   %s" % [
		String(spec.get("brand", "")), int(spec.get("topKph", 0)),
		float(spec.get("zeroTo100", 0.0)), String(spec.get("tag", ""))]
	_index_label.text = "车辆  %02d / %02d   ·   右侧网格直接选车   ·   TAB / Ⓨ 切换改装条   ·   拖拽车身旋转" % [
		car_index + 1, GameData.cars_specs.size()]
	if _grid_count != null:
		_grid_count.text = "%d 台  ·  当前 %02d" % [GameData.cars_specs.size(), car_index + 1]

	_refresh_grid_styles()
	_refresh_tuning_styles()
	_refresh_perf(car_id, spec, tuned)
	_refresh_upgrades(car_id)
	_refresh_paint_row(car_id)


func _refresh_grid_styles() -> void:
	for i in _grid_cells.size():
		var selected := i == car_index
		_grid_cells[i].add_theme_stylebox_override("normal", _tile_style(selected, false))
		_grid_cells[i].add_theme_stylebox_override("pressed", _tile_style(true, false))
		_grid_cells[i].add_theme_stylebox_override("focus", _tile_style(selected, true))
		_grid_cells[i].add_theme_stylebox_override("hover", _tile_style(selected, true))
		_grid_names[i].add_theme_color_override("font_color",
			UIStyle.TXT if selected else Color(0.70, 0.80, 0.88, 1.0))


func _refresh_tuning_styles() -> void:
	for i in _tuning_segs.size():
		var active := i == category
		_tuning_segs[i].add_theme_stylebox_override("normal", _seg_style(active, false))
		_tuning_segs[i].add_theme_stylebox_override("pressed", _seg_style(true, false))
		_tuning_segs[i].add_theme_stylebox_override("hover", _seg_style(active, true))
		_tuning_segs[i].add_theme_stylebox_override("focus", _seg_style(active, true))
		_tuning_titles[i].add_theme_color_override("font_color",
			Color(0.02, 0.07, 0.08, 1.0) if active else Color(0.82, 0.89, 0.95, 1.0))
		_tuning_values[i].add_theme_color_override("font_color",
			Color(0.04, 0.12, 0.13, 0.9) if active else UIStyle.GOLD)
		_tuning_values[i].text = _option_short(_current_car_id(), i)
	if _value_flash != null:
		_value_flash.text = _option_detail(_current_car_id(), category)


func _refresh_perf(car_id: String, spec: Dictionary, tuned: Dictionary) -> void:
	var stock_kph := float(spec.get("topKph", 0))
	var tuned_stats: Dictionary = tuned.get("stats", {})
	var stock_stats: Dictionary = spec.get("stats", {})
	_stat_values[0].text = "%d → %d km/h" % [int(stock_kph), int(tuned.get("topKph", 0))]
	_stat_values[1].text = "%.1f → %.1f s" % [
		float(spec.get("zeroTo100", 0.0)), float(tuned.get("zeroTo100", 0.0))]
	_stat_values[2].text = "%.2f → %.2f" % [
		float(spec.get("grip", 0.0)), float(tuned.get("grip", 0.0))]
	_stat_values[3].text = "%.1f → %.1f s" % [
		3.7, float(tuned.get("nitroTime", 3.7))]
	for i in 3:
		var key: String = ["speed", "accel", "handling"][i]
		_stat_bars[i].set_value(float(tuned_stats.get(key, stock_stats.get(key, 50))) / 100.0)
	if _perf_note != null:
		_perf_note.text = "%s   ·   原厂 → 改装" % Garage.option_name(car_id, "paint")


func _refresh_upgrades(car_id: String) -> void:
	for i in Garage.UPGRADE_KEYS.size():
		var key: String = Garage.UPGRADE_KEYS[i]
		var level := Garage.upgrade_level(car_id, key)
		var max_level := Garage._upgrade_max(key)
		upgrade_name_labels[i].text = String(UPGRADE_LABELS.get(key, key))
		upgrade_level_labels[i].text = "%d/%d" % [level, max_level]
		var selected := category == UPGRADE_CATEGORY and i == upgrade_index
		upgrade_level_labels[i].add_theme_color_override("font_color",
			UIStyle.GOLD if selected else UIStyle.GREEN)
		_upgrade_bars[i].segments = maxi(max_level, 1)
		_upgrade_bars[i].set_value(0.0 if max_level <= 0 else float(level) / float(max_level), true)
	if _credit_label != null:
		_credit_label.text = "积分  %d XP" % ProfileStore.credit_balance()
	_refresh_upgrade_styles()
	_refresh_upgrade_note(car_id)


func _refresh_upgrade_styles() -> void:
	var up_active := category == UPGRADE_CATEGORY
	for i in _upgrade_cells.size():
		var active := up_active and i == upgrade_index
		var style := UIStyle.inset_style(_accent, 0.55)
		style.border_color = UIStyle.a(_accent, 0.85 if active else 0.12)
		if active:
			style.bg_color = Color(0.072, 0.128, 0.145, 0.92)
			style.shadow_color = UIStyle.a(_accent, 0.12)
			style.shadow_size = 8
		_upgrade_cells[i].add_theme_stylebox_override("panel", style)
		upgrade_name_labels[i].add_theme_color_override("font_color",
			Color(1.0, 1.0, 1.0, 1.0) if active else Color(0.76, 0.84, 0.92, 1.0))
		_upgrade_bars[i].setup(UIStyle.ACCENT if active else UIStyle.GREEN)


func _refresh_upgrade_note(car_id: String) -> void:
	if _upgrade_note == null:
		return
	var key: String = Garage.UPGRADE_KEYS[upgrade_index]
	var label := String(UPGRADE_LABELS.get(key, key))
	var level := Garage.upgrade_level(car_id, key)
	var cost := Garage.upgrade_cost(car_id, key)
	var balance := ProfileStore.credit_balance()
	if cost < 0:
		_upgrade_note.text = "%s 已满级   ·   重置可退还 XP   ·   手柄 A / ENTER 升级" % label
		_upgrade_note.add_theme_color_override("font_color", UIStyle.TXT_FAINT)
	elif cost == 0:
		_upgrade_note.text = "%s  Lv.%d → %d   ·   首档免费   ·   余额 %d XP" % [
			label, level, level + 1, balance]
		_upgrade_note.add_theme_color_override("font_color", UIStyle.GREEN)
	else:
		_upgrade_note.text = "%s  Lv.%d → %d   ·   需要 %d XP   ·   余额 %d XP" % [
			label, level, level + 1, cost, balance]
		_upgrade_note.add_theme_color_override("font_color",
			UIStyle.GREEN if balance >= cost else UIStyle.RED)


func _refresh_paint_row(car_id: String) -> void:
	var palette := GameData.palette_for(car_id)
	var paint_on := category == PAINT_CATEGORY
	_paint_index = Garage.get_option(car_id, "paint")
	_paint_row.visible = paint_on
	_paint_label.visible = paint_on
	if paint_on:
		_paint_label.text = "点击色块换漆   ·   %d 色" % palette.size()
	for i in _paint_chips.size():
		if i >= palette.size():
			_paint_chips[i].visible = false
			continue
		_paint_chips[i].visible = paint_on
		var entry: Dictionary = palette[i]
		var col := Color.from_string(String(entry.get("color", "#ffffff")), Color.WHITE)
		var style := StyleBoxFlat.new()
		style.bg_color = col
		style.set_corner_radius_all(3)
		style.border_color = UIStyle.a(Color.WHITE, 0.20)
		style.set_border_width_all(1)
		if i == _paint_index:
			style.border_color = UIStyle.a(UIStyle.ACCENT, 0.98)
			style.set_border_width_all(2)
			style.shadow_color = UIStyle.a(UIStyle.ACCENT, 0.35)
			style.shadow_size = 6
		_paint_chips[i].add_theme_stylebox_override("panel", style)
		_paint_chips[i].tooltip_text = String(entry.get("name", ""))


## 横条内的小字值（短）
func _option_short(car_id: String, category_index: int) -> String:
	if category_index >= 0 and category_index <= 4:
		var key: String = CATEGORY_KEYS[category_index]
		var count := Garage._option_count(car_id, key)
		if key == "wing":
			var usable: Array[int] = []
			for wi in count:
				if Garage.wing_option_usable(car_id, wi):
					usable.append(wi)
			var current := Garage.get_option(car_id, "wing")
			var pos := usable.find(current)
			return "%d/%d" % [(pos + 1) if pos >= 0 else 0, usable.size()]
		return "%d/%d" % [Garage.get_option(car_id, key) + 1, count]
	match category_index:
		PAINT_CATEGORY:
			return Garage.option_name(car_id, "paint")
		UPGRADE_CATEGORY:
			return "%d/10" % Garage.upgrade_level(car_id, Garage.UPGRADE_KEYS[upgrade_index])
	return ""


## 横条右上角的详细说明
func _option_detail(car_id: String, category_index: int) -> String:
	if category_index >= 0 and category_index <= 4:
		var key: String = CATEGORY_KEYS[category_index]
		return "%s   ·   %s" % [CATEGORY_SHORT[category_index], Garage.option_name(car_id, key)]
	if category_index == PAINT_CATEGORY:
		return "车漆   ·   %s" % Garage.option_name(car_id, "paint")
	var up_key: String = Garage.UPGRADE_KEYS[upgrade_index]
	return "升级   ·   %s  Lv.%d / 10" % [
		String(UPGRADE_LABELS.get(up_key, up_key)), Garage.upgrade_level(car_id, up_key)]


func _animate_in() -> void:
	var cards: Array[Control] = [_grid_card, _tuning_card, _perf_card, _upgrades_card]
	for i in cards.size():
		var node := cards[i]
		if node == null:
			continue
		node.modulate.a = 0.0
		node.create_tween().tween_property(node, "modulate:a", 1.0, 0.28).set_delay(0.03 * i)
	if _frame != null:
		_frame.modulate.a = 0.0
		_frame.create_tween().tween_property(_frame, "modulate:a", 1.0, 0.6)


# ---------------------------------------------------------------------------
# 输入：网格 / 改装条两区导航
# ---------------------------------------------------------------------------

func _open_car_grid() -> void:
	_grid_open = true
	_panel_focus = 0
	_grid_focus = clampi(car_index, 0, maxi(_grid_cells.size() - 1, 0))
	if not _grid_cells.is_empty():
		_grid_cells[_grid_focus].grab_focus()
		_grid_scroll.ensure_control_visible(_grid_cells[_grid_focus])


func _close_car_grid() -> void:
	_grid_open = false


func _nav_step(axis: Vector2) -> void:
	if GameData.cars_specs.is_empty():
		return
	if _panel_focus == 0:
		if absf(axis.x) >= absf(axis.y):
			if absf(axis.x) <= 0.3:
				return
			var d := 1 if axis.x > 0.0 else -1
			_pick_car(clampi(car_index + d, 0, GameData.cars_specs.size() - 1), true)
		else:
			var drow := 1 if axis.y > 0.0 else -1
			_pick_car(clampi(car_index + drow * GRID_COLUMNS, 0,
				GameData.cars_specs.size() - 1), true)
		return
	var car_id := _current_car_id()
	if absf(axis.x) > absf(axis.y):
		var d := 1 if axis.x > 0.0 else -1
		if category == UPGRADE_CATEGORY:
			upgrade_index = posmod(upgrade_index + d, Garage.UPGRADE_KEYS.size())
			refresh()
		else:
			Garage.cycle_option(car_id, CATEGORY_KEYS[category], d)
			_after_look_change(car_id)
			refresh()
	else:
		category = posmod(category + (1 if axis.y > 0.0 else -1), CATEGORIES.size())
		refresh()


func _process(delta: float) -> void:
	_process_thumb_queue()
	if not visible:
		_nav_cooldown = 0.0
		return
	if get_tree().paused:
		_nav_cooldown = 0.0
		return
	var axis := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	if axis.length() < 0.55:
		_nav_cooldown = 0.0
		return
	if _nav_cooldown > 0.0:
		_nav_cooldown -= delta
		return
	_nav_cooldown = 0.18
	_nav_step(axis)


func _confirm() -> void:
	if GameData.cars_specs.is_empty():
		return
	if _panel_focus == 0:
		_pick_car(car_index, true)
		return
	var car_id := _current_car_id()
	var denied := ""
	if category == UPGRADE_CATEGORY:
		var key: String = Garage.UPGRADE_KEYS[upgrade_index]
		var cost := Garage.upgrade_cost(car_id, key)
		var balance := ProfileStore.credit_balance()
		if cost < 0:
			denied = "已满级"
		elif cost > 0 and balance < cost:
			denied = "XP 不足 · 还差 %d XP" % (cost - balance)
		elif not Garage.add_upgrade_level(car_id, key):
			denied = "升级失败"
	else:
		Garage.cycle_option(car_id, CATEGORY_KEYS[category], 1)
		_after_look_change(car_id)
	refresh()
	if not denied.is_empty() and _upgrade_note != null:
		_upgrade_note.text = "%s   ·   %s" % [
			String(UPGRADE_LABELS.get(Garage.UPGRADE_KEYS[upgrade_index], "")), denied]
		_upgrade_note.add_theme_color_override("font_color", UIStyle.RED)


func _toggle_panel_focus() -> void:
	_panel_focus = 1 - _panel_focus
	if _panel_focus == 0 and not _grid_cells.is_empty():
		_grid_cells[car_index].grab_focus()
		_grid_scroll.ensure_control_visible(_grid_cells[car_index])
	refresh()


func _cancel() -> void:
	closed.emit()


func _input(event: InputEvent) -> void:
	if not visible:
		return
	# 方向导航由 _process 统一处理（带长按重复）；吞掉事件防止原生焦点导航再走一遍。
	if event.is_action("ui_left") or event.is_action("ui_right") \
			or event.is_action("ui_up") or event.is_action("ui_down"):
		if event.is_action_pressed("ui_left") or event.is_action_pressed("ui_right") \
				or event.is_action_pressed("ui_up") or event.is_action_pressed("ui_down"):
			get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("ui_cancel"):
		_cancel()
		get_viewport().set_input_as_handled()
		return
	if event is InputEventJoypadButton and event.pressed:
		match (event as InputEventJoypadButton).button_index:
			JOY_BUTTON_A:
				_confirm()
			JOY_BUTTON_Y:
				_toggle_panel_focus()
			JOY_BUTTON_LEFT_SHOULDER:
				_panel_focus = 1
				category = posmod(category - 1, CATEGORIES.size())
				refresh()
			JOY_BUTTON_RIGHT_SHOULDER:
				_panel_focus = 1
				category = posmod(category + 1, CATEGORIES.size())
				refresh()
			_:
				return
		get_viewport().set_input_as_handled()
		return
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var key := (event as InputEventKey).keycode
	match key:
		KEY_ENTER, KEY_KP_ENTER:
			_confirm()
		KEY_TAB:
			_toggle_panel_focus()
		KEY_L:
			_reset_upgrades()
		KEY_SPACE:
			race_requested.emit(_current_car_id())
			return
		KEY_ESCAPE:
			_cancel()
			return
		_:
			return
	get_viewport().set_input_as_handled()


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

func _bar(value_0_100: int) -> String:
	var filled := clampi(int(round(value_0_100 / 10.0)), 0, 10)
	return "■".repeat(filled) + "□".repeat(10 - filled)
