class_name PauseScreen
extends CanvasLayer
## 比赛暂停菜单 · 车队指挥台 / PIT WALL 风格 v2。
## 继续 / 重新开始 / 设置 / 返回主菜单。信号与 setup(track, car) 保持不变。

signal resume_requested
signal restart_requested
signal settings_requested
signal menu_requested

const ACCENT := UIStyle.ACCENT

var _track_name := ""
var _car_name := ""
var _sub: Label
var _root: Control
var _buttons: Array[Button] = []
var _frame: UIFrame


func _ready() -> void:
	layer = 84
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()


func setup(track_name: String, car_name: String) -> void:
	_track_name = track_name
	_car_name = car_name
	if _sub != null:
		_sub.text = "%s   ·   %s" % [track_name, car_name]


func _build() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.name = "Root"
	UIStyle.apply_theme(_root)
	add_child(_root)

	var dim := ColorRect.new()
	dim.color = Color(0.004, 0.008, 0.012, 0.74)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(dim)

	var left_glow := TextureRect.new()
	left_glow.texture = UIStyle.glow_texture(ACCENT, 1.8)
	left_glow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	left_glow.stretch_mode = TextureRect.STRETCH_SCALE
	left_glow.modulate = Color(1, 1, 1, 0.13)
	UIStyle.place(left_glow, 0, 0, 0, 0, -420, -260, 760, 1000)
	left_glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(left_glow)

	var vig := TextureRect.new()
	vig.texture = UIStyle.vignette_texture(Vector2(0.5, 0.5), 0.78, 0.26)
	vig.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	vig.stretch_mode = TextureRect.STRETCH_SCALE
	vig.set_anchors_preset(Control.PRESET_FULL_RECT)
	vig.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(vig)

	_frame = UIFrame.new()
	_frame.setup(ACCENT, 28.0, 0.22)
	UIStyle.place(_frame, 0, 0, 1, 1, 18, 18, -18, -18)
	_root.add_child(_frame)

	# 左上品牌
	var slash := ColorRect.new()
	slash.color = ACCENT
	UIStyle.place(slash, 0, 0, 0, 0, 46, 38, 50, 84)
	slash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(slash)
	var brand := UIStyle.label_display("APEX / VELOCITY", 19, UIStyle.TXT,
		HORIZONTAL_ALIGNMENT_LEFT, 2)
	UIStyle.place(brand, 0, 0, 0, 0, 62, 32, 560, 62)
	_root.add_child(brand)
	var tag := UIStyle.label_tracked("RACE CONTROL   /   车队指挥台", 9,
		Color(0.66, 0.84, 0.90, 1.0), HORIZONTAL_ALIGNMENT_LEFT, 2)
	UIStyle.place(tag, 0, 0, 0, 0, 64, 66, 560, 86)
	_root.add_child(tag)

	# 左侧：PAUSED 巨幅标题
	var paused := UIStyle.label_display("PAUSED", 108, UIStyle.TXT,
		HORIZONTAL_ALIGNMENT_LEFT, 8)
	paused.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.65))
	paused.add_theme_constant_override("outline_size", 8)
	UIStyle.place(paused, 0, 0.5, 0, 0.5, 54, -196, 760, -44)
	_root.add_child(paused)

	var paused_cn := UIStyle.label_tracked("比 赛 暂 停   ·   RACE PAUSED", 13,
		Color(ACCENT.r, ACCENT.g, ACCENT.b, 1.0), HORIZONTAL_ALIGNMENT_LEFT, 3)
	UIStyle.place(paused_cn, 0, 0.5, 0, 0.5, 60, -34, 720, -4)
	_root.add_child(paused_cn)

	var line := ColorRect.new()
	line.color = UIStyle.a(ACCENT, 0.45)
	UIStyle.place(line, 0, 0.5, 0, 0.5, 60, 8, 720, 9)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(line)

	var info := UIStyle.label_tracked("CURRENT SESSION   /   当前比赛", 9,
		Color(0.60, 0.76, 0.84, 0.95), HORIZONTAL_ALIGNMENT_LEFT, 2)
	UIStyle.place(info, 0, 0.5, 0, 0.5, 62, 26, 720, 44)
	_root.add_child(info)

	_sub = UIStyle.label_display("—", 22, UIStyle.TXT, HORIZONTAL_ALIGNMENT_LEFT, 1)
	_sub.add_theme_constant_override("outline_size", 0)
	_sub.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	UIStyle.place(_sub, 0, 0.5, 0, 0.5, 62, 48, 720, 86)
	_root.add_child(_sub)

	if not _track_name.is_empty():
		_sub.text = "%s   ·   %s" % [_track_name, _car_name]

	var session := UIStyle.label("比赛已暂停      ·      计时与 AI 已冻结      ·      返回菜单不会保留本场进度", 11,
		Color(0.58, 0.70, 0.79, 1.0))
	UIStyle.place(session, 0, 0.5, 0, 0.5, 62, 94, 760, 114)
	_root.add_child(session)

	# 右下：按键提示
	var hint_row := HBoxContainer.new()
	hint_row.add_theme_constant_override("separation", 8)
	hint_row.alignment = BoxContainer.ALIGNMENT_END
	UIStyle.place(hint_row, 1, 1, 1, 1, -560, -54, -48, -26)
	hint_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(hint_row)
	hint_row.add_child(UIStyle.keycap("ESC", ACCENT, 9))
	hint_row.add_child(UIStyle.label("继续比赛", 10, Color(0.60, 0.72, 0.81, 1.0)))
	hint_row.add_child(UIStyle.keycap("M", ACCENT, 9))
	hint_row.add_child(UIStyle.label("返回主菜单", 10, Color(0.60, 0.72, 0.81, 1.0)))

	# 右侧按钮列
	var panel := Panel.new()
	panel.add_theme_stylebox_override("panel", UIStyle.card_style(ACCENT, false, 0.93))
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UIStyle.place(panel, 1, 0.5, 1, 0.5, -540, -212, -60, 218)
	_root.add_child(panel)
	UIStyle.add_top_glow(panel, ACCENT, 0.95)

	var header := HBoxContainer.new()
	UIStyle.place(header, 0, 0, 1, 0, 20, 16, -20, 38)
	header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(header)
	header.add_child(UIStyle.kicker("OPTIONS   /   菜单", ACCENT))
	var fill := UIStyle.spacer()
	header.add_child(fill)
	header.add_child(UIStyle.label_tracked("PIT WALL", 9, UIStyle.TXT_FAINT,
		HORIZONTAL_ALIGNMENT_RIGHT, 1))

	var buttons_box := VBoxContainer.new()
	buttons_box.add_theme_constant_override("separation", 8)
	UIStyle.place(buttons_box, 0, 0, 1, 0, 16, 46, -16, 286)
	panel.add_child(buttons_box)

	_add_button(buttons_box, "01", "继续比赛", "RESUME RACE", resume_requested, ACCENT, true)
	_add_button(buttons_box, "02", "重新开始", "RESTART", restart_requested, UIStyle.SILVER, false)
	_add_button(buttons_box, "03", "设置", "SETTINGS", settings_requested, UIStyle.SILVER, false)
	_add_button(buttons_box, "04", "返回主菜单", "MAIN MENU", menu_requested, UIStyle.RED, false)

	var note := UIStyle.label("HUD 与画质设置可在「设置」中即时调整。", 9,
		Color(0.52, 0.64, 0.73, 0.95))
	UIStyle.place(note, 0, 0, 1, 0, 22, 292, -20, 310)
	panel.add_child(note)

	var info_panel := Panel.new()
	info_panel.add_theme_stylebox_override("panel", UIStyle.inset_style(ACCENT, 0.5))
	UIStyle.place(info_panel, 0, 1, 1, 1, 16, -96, -16, -18)
	panel.add_child(info_panel)
	var info_box := VBoxContainer.new()
	info_box.set_anchors_preset(Control.PRESET_FULL_RECT)
	info_box.offset_left = 12
	info_box.offset_right = -12
	info_box.offset_top = 8
	info_box.offset_bottom = -8
	info_box.add_theme_constant_override("separation", 2)
	info_panel.add_child(info_box)
	info_box.add_child(UIStyle.label_tracked("当前设置   /   ACTIVE SETUP", 8,
		Color(0.62, 0.82, 0.90, 0.95), HORIZONTAL_ALIGNMENT_LEFT, 1))
	var setup_label := UIStyle.label("", 9, UIStyle.TXT_DIM)
	setup_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	setup_label.text = "画质 %s   ·   %s   ·   %s\nHUD  小地图 %s   转速表 %s   速度表 %s" % [
		Settings.detail_name(), Settings.resolution_label(), Settings.fps_text(),
		"开" if Settings.hud_minimap else "关", "开" if Settings.hud_tach else "关",
		"开" if Settings.hud_speed else "关"]
	info_box.add_child(setup_label)

	_root.modulate.a = 0.0
	create_tween().tween_property(_root, "modulate:a", 1.0, 0.16)
	if _buttons.size() > 0:
		_buttons[0].grab_focus()
	panel.modulate.a = 0.0
	panel.create_tween().tween_property(panel, "modulate:a", 1.0, 0.22).set_delay(0.04)


func _add_button(parent: Control, num: String, cn: String, en: String, sig: Signal,
		accent: Color, primary: bool) -> void:
	var btn := Button.new()
	btn.text = ""
	btn.custom_minimum_size = Vector2(0, 60)
	btn.focus_mode = Control.FOCUS_ALL
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	UIStyle.apply_button(btn, accent, "primary" if primary else "ghost", 15)
	btn.pressed.connect(func() -> void: sig.emit())
	parent.add_child(btn)
	_buttons.append(btn)

	var row := HBoxContainer.new()
	row.set_anchors_preset(Control.PRESET_FULL_RECT)
	row.offset_left = 16
	row.offset_right = -16
	row.add_theme_constant_override("separation", 12)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	btn.add_child(row)
	var idx := UIStyle.label_tech(num, 12, UIStyle.a(accent, 0.85))
	idx.custom_minimum_size = Vector2(30, 0)
	row.add_child(idx)
	var text := VBoxContainer.new()
	text.add_theme_constant_override("separation", 0)
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.alignment = BoxContainer.ALIGNMENT_CENTER
	text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(text)
	var cn_label := UIStyle.label(cn, 17, UIStyle.TXT)
	text.add_child(cn_label)
	var en_label := UIStyle.label_tracked(en, 8, Color(0.56, 0.68, 0.77, 0.95),
		HORIZONTAL_ALIGNMENT_LEFT, 2)
	text.add_child(en_label)
	var arrow := UIStyle.label("›", 18, UIStyle.a(accent, 0.85), HORIZONTAL_ALIGNMENT_RIGHT)
	arrow.custom_minimum_size = Vector2(24, 0)
	row.add_child(arrow)

	var animate := func(active: bool) -> void:
		if not is_instance_valid(btn):
			return
		var tw := btn.create_tween()
		tw.set_parallel(true)
		tw.tween_property(cn_label, "modulate", Color(1.10, 1.10, 1.10, 1.0) if active else Color.WHITE, 0.14)
		tw.tween_property(arrow, "modulate:a", 1.0 if active else 0.45, 0.14)
		tw.tween_property(arrow, "position:x", 3.0 if active else 0.0, 0.14)
	btn.mouse_entered.connect(func() -> void: animate.call(true))
	btn.mouse_exited.connect(func() -> void: animate.call(false))
	btn.focus_entered.connect(func() -> void: animate.call(true))
	btn.focus_exited.connect(func() -> void: animate.call(false))


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		resume_requested.emit()
		return
	if event is InputEventKey and event.pressed and not event.echo:
		var key := (event as InputEventKey).keycode
		if key == KEY_M:
			get_viewport().set_input_as_handled()
			menu_requested.emit()
