class_name AchievementsScreen
extends CanvasLayer
## 车手档案 / 成就墙 · v2 视觉（玻璃面板 + 金色解锁态 + 数据头图）。
## 等级、XP、战绩、15 个成就（锁定灰显）。ESC 关闭。

signal closed

const ACCENT := UIStyle.ACCENT
const PANEL_W := 1240.0
const PANEL_H := 796.0

var _list: GridContainer
var _summary_label: Label
var _panel: Panel
var _xp_bar: ProgressBar
var _stat_values: Array[Label] = []


func _ready() -> void:
	layer = 25
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	root.name = "Root"
	add_child(root)
	UIStyle.apply_theme(root)

	var dim := ColorRect.new()
	dim.color = Color(0.004, 0.008, 0.012, 0.90)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(dim)

	# 氛围光：左上品牌青、中央金色微光
	var cyan_glow := TextureRect.new()
	cyan_glow.texture = UIStyle.glow_texture(ACCENT, 1.6)
	cyan_glow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	cyan_glow.stretch_mode = TextureRect.STRETCH_SCALE
	cyan_glow.modulate = Color(1, 1, 1, 0.10)
	UIStyle.place(cyan_glow, 0, 0, 0, 0, -420, -380, 640, 520)
	cyan_glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(cyan_glow)

	var gold_glow := TextureRect.new()
	gold_glow.texture = UIStyle.glow_texture(UIStyle.GOLD, 2.0)
	gold_glow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	gold_glow.stretch_mode = TextureRect.STRETCH_SCALE
	gold_glow.modulate = Color(1, 1, 1, 0.07)
	UIStyle.place(gold_glow, 0.5, 0.5, 0.5, 0.5, -700, -520, 700, 520)
	gold_glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(gold_glow)

	_panel = Panel.new()
	_panel.add_theme_stylebox_override("panel", UIStyle.glass_style(ACCENT, 0.95, UIStyle.R_LG, 0.30))
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UIStyle.place(_panel, 0.5, 0.5, 0.5, 0.5, -PANEL_W * 0.5, -PANEL_H * 0.5,
		PANEL_W * 0.5, PANEL_H * 0.5)
	root.add_child(_panel)
	UIStyle.add_top_glow(_panel, ACCENT, 0.95)

	# ---- 标题区 -----------------------------------------------------------
	var kicker := UIStyle.label_tracked("APEX VELOCITY   /   DRIVER PROFILE", 9,
		UIStyle.a(ACCENT, 0.95), HORIZONTAL_ALIGNMENT_LEFT, 2)
	UIStyle.place(kicker, 0, 0, 1, 0, 40, 26, -40, 46)
	_panel.add_child(kicker)

	var title := UIStyle.label_display("车手档案   /   DRIVER PROFILE", 30, UIStyle.TXT,
		HORIZONTAL_ALIGNMENT_LEFT, 2)
	UIStyle.place(title, 0, 0, 1, 0, 40, 48, -260, 92)
	_panel.add_child(title)

	var sub := UIStyle.label_tracked("成就墙   ·   等级 / 经验 / 最快圈   ·   ESC 关闭", 10,
		UIStyle.TXT_DIM, HORIZONTAL_ALIGNMENT_LEFT, 1)
	UIStyle.place(sub, 0, 0, 1, 0, 42, 94, -260, 114)
	_panel.add_child(sub)

	var close_btn := Button.new()
	close_btn.focus_mode = Control.FOCUS_ALL
	close_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	UIStyle.apply_button(close_btn, ACCENT, "ghost", 11)
	UIStyle.place(close_btn, 1, 0, 1, 0, -276, 28, -40, 68)
	close_btn.pressed.connect(_close)
	_panel.add_child(close_btn)
	var close_row := HBoxContainer.new()
	close_row.set_anchors_preset(Control.PRESET_FULL_RECT)
	close_row.offset_left = 14
	close_row.offset_right = -12
	close_row.add_theme_constant_override("separation", 8)
	close_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	close_btn.add_child(close_row)
	close_row.add_child(UIStyle.label("✕", 12, UIStyle.a(ACCENT, 0.95)))
	close_row.add_child(UIStyle.label("关闭  /  CLOSE", 11, UIStyle.TXT_SUB))
	var close_fill := UIStyle.spacer()
	close_row.add_child(close_fill)
	close_row.add_child(UIStyle.keycap("ESC", ACCENT, 9))

	# ---- 数据条 -----------------------------------------------------------
	_build_stats_row()

	# ---- 成就列表 ---------------------------------------------------------
	var list_head := HBoxContainer.new()
	UIStyle.place(list_head, 0, 0, 1, 0, 40, 256, -40, 278)
	_panel.add_child(list_head)
	list_head.add_child(UIStyle.kicker("ACHIEVEMENTS   /   成就", ACCENT))
	var head_fill := UIStyle.spacer()
	list_head.add_child(head_fill)
	_summary_label = UIStyle.label_tracked("", 9, UIStyle.TXT_DIM, HORIZONTAL_ALIGNMENT_RIGHT, 1)
	list_head.add_child(_summary_label)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.add_theme_constant_override("scrollbar_width", 6)
	UIStyle.place(scroll, 0, 0, 1, 1, 34, 284, -34, -66)
	_panel.add_child(scroll)
	_list = GridContainer.new()
	_list.columns = 2
	_list.add_theme_constant_override("h_separation", 10)
	_list.add_theme_constant_override("v_separation", 8)
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_list)

	var foot := HBoxContainer.new()
	foot.add_theme_constant_override("separation", 10)
	UIStyle.place(foot, 0, 1, 1, 1, 40, -52, -40, -24)
	_panel.add_child(foot)
	foot.add_child(UIStyle.keycap("↑↓", ACCENT, 9))
	foot.add_child(UIStyle.label("滚轮 / 方向键  浏览成就", 10, UIStyle.TXT_DIM))
	var foot_fill := UIStyle.spacer()
	foot.add_child(foot_fill)
	foot.add_child(UIStyle.label_tracked("全部 %d 项成就  ·  免费游玩" % ProfileStore.achievements_total(),
		9, UIStyle.TXT_FAINT, HORIZONTAL_ALIGNMENT_RIGHT, 1))

	_refresh()
	close_btn.grab_focus()

	_panel.pivot_offset = Vector2(PANEL_W, PANEL_H) * 0.5
	_panel.scale = Vector2(0.97, 0.97)
	_panel.modulate.a = 0.0
	var tw := _panel.create_tween()
	tw.set_parallel(true)
	tw.tween_property(_panel, "scale", Vector2.ONE, 0.32) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(_panel, "modulate:a", 1.0, 0.22)


func _build_stats_row() -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	UIStyle.place(row, 0, 0, 1, 0, 40, 126, -40, 222)
	_panel.add_child(row)

	var profile := ProfileStore.load_profile()
	var progress := ProfileStore.level_progress(int(profile.get("xp", 0)))
	var unlocked := (profile.get("achievements", {}) as Dictionary).size()

	var cells := [
		["车手等级  /  LEVEL", "LV %d" % int(progress.get("level", 1)), UIStyle.GOLD],
		["总经验  /  XP", "%d XP" % int(progress.get("total_xp", 0)), UIStyle.TXT],
		["战绩  /  RECORD", "%d 场 · %d 胜 · %d 登台" % [
			int(profile.get("races", 0)), int(profile.get("wins", 0)),
			int(profile.get("podiums", 0))], UIStyle.TXT],
		["成就  /  ACHIEVEMENTS", "%d / %d" % [unlocked, ProfileStore.achievements_total()], UIStyle.GOLD],
	]
	for i in cells.size():
		var cell := Panel.new()
		cell.add_theme_stylebox_override("panel", UIStyle.inset_style(ACCENT, 0.55))
		cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cell.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(cell)
		var caption := UIStyle.label_tracked(String(cells[i][0]), 8, UIStyle.TXT_FAINT,
			HORIZONTAL_ALIGNMENT_LEFT, 1)
		UIStyle.place(caption, 0, 0, 1, 0, 14, 10, -14, 26)
		cell.add_child(caption)
		var value := UIStyle.label_tech(String(cells[i][1]), 20, cells[i][2],
			HORIZONTAL_ALIGNMENT_LEFT, 1)
		UIStyle.place(value, 0, 0, 1, 0, 14, 28, -14, 58)
		cell.add_child(value)
		_stat_values.append(value)
		if i == 1:
			_xp_bar = ProgressBar.new()
			_xp_bar.max_value = 1.0
			_xp_bar.step = 0.001
			UIStyle.style_progress(_xp_bar, ACCENT)
			UIStyle.place(_xp_bar, 0, 1, 1, 1, 14, -18, -14, -10)
			cell.add_child(_xp_bar)
			_xp_bar.value = float(progress.get("ratio", 0.0))

	# 第二行小数据
	var extra := HBoxContainer.new()
	extra.add_theme_constant_override("separation", 18)
	UIStyle.place(extra, 0, 0, 1, 0, 42, 228, -40, 248)
	_panel.add_child(extra)
	var extra_text := "累计 %.1f km    ·    氮气 %d 次    ·    漂移 %.1f s    ·    最佳单圈 %s" % [
		float(profile.get("total_km", 0.0)), int(profile.get("total_nitro", 0)),
		float(profile.get("total_drift_time", 0.0)), _best_lap_text(profile)]
	var extra_lbl := UIStyle.label(extra_text, 10, Color(0.62, 0.76, 0.85, 1.0))
	extra.add_child(extra_lbl)


func _best_lap_text(profile: Dictionary) -> String:
	var best := -1.0
	var laps: Dictionary = profile.get("best_laps", {})
	for track_id in laps.keys():
		var by_car: Variant = laps[track_id]
		if typeof(by_car) != TYPE_DICTIONARY:
			continue
		for car_id in (by_car as Dictionary).keys():
			var times: Variant = (by_car as Dictionary)[car_id]
			if typeof(times) != TYPE_ARRAY:
				continue
			for t in (times as Array):
				var value := float(t)
				if value > 0.0 and (best < 0.0 or value < best):
					best = value
	if best <= 0.0:
		return "--:--.---"
	return RaceManager.format_time(best)


func _refresh() -> void:
	if _summary_label == null:
		return
	var unlocked_count := 0
	for child in _list.get_children():
		child.queue_free()
	var profile := ProfileStore.load_profile()
	var unlocked: Dictionary = profile.get("achievements", {})
	unlocked_count = unlocked.size()
	for def in ProfileStore.achievement_defs():
		var got := unlocked.has(String(def.get("id", "")))
		_list.add_child(_make_card(def, got))
	_summary_label.text = "已解锁  %d / %d" % [unlocked_count, ProfileStore.achievements_total()]


func _make_card(def: Dictionary, got: bool) -> Control:
	var card := Panel.new()
	card.custom_minimum_size = Vector2(0, 68)
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := UIStyle.inset_style(UIStyle.GOLD if got else Color(0.35, 0.42, 0.5), 0.52)
	style.border_color = UIStyle.a(UIStyle.GOLD, 0.42) if got else Color(0.28, 0.34, 0.41, 0.55)
	if got:
		style.bg_color = Color(0.075, 0.070, 0.048, 0.92)
	card.add_theme_stylebox_override("panel", style)

	if got:
		var bar := ColorRect.new()
		bar.color = UIStyle.a(UIStyle.GOLD, 0.95)
		UIStyle.place(bar, 0, 0, 0, 1, 0, 9, 3, -9)
		bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		card.add_child(bar)

	var icon_badge := Panel.new()
	var icon_style := StyleBoxFlat.new()
	icon_style.bg_color = UIStyle.a(UIStyle.GOLD, 0.14) if got else Color(0.10, 0.12, 0.15, 0.85)
	icon_style.border_color = UIStyle.a(UIStyle.GOLD, 0.55) if got else Color(0.24, 0.30, 0.36, 0.7)
	icon_style.set_border_width_all(1)
	icon_style.set_corner_radius_all(UIStyle.R_PILL)
	icon_badge.add_theme_stylebox_override("panel", icon_style)
	icon_badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UIStyle.place(icon_badge, 0, 0.5, 0, 0.5, 12, -19, 50, 19)
	card.add_child(icon_badge)
	var icon := UIStyle.label("★" if got else "◇", 15,
		UIStyle.GOLD if got else Color(0.42, 0.49, 0.56), HORIZONTAL_ALIGNMENT_CENTER)
	icon.set_anchors_preset(Control.PRESET_FULL_RECT)
	icon.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	icon_badge.add_child(icon)

	var name_label := UIStyle.label(String(def.get("name", "成就")), 13,
		UIStyle.TXT if got else Color(0.56, 0.64, 0.72))
	UIStyle.place(name_label, 0, 0, 1, 0, 62, 10, -110, 32)
	card.add_child(name_label)
	var desc := UIStyle.label(String(def.get("desc", "")), 9,
		UIStyle.a(UIStyle.TXT_DIM, 0.95) if got else Color(0.42, 0.49, 0.56))
	desc.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	UIStyle.place(desc, 0, 0, 1, 0, 62, 34, -110, 52)
	card.add_child(desc)

	var xp_text := ("+%d XP" % int(def.get("xp", 0))) if not got else "已解锁"
	var xp := UIStyle.label_tech(xp_text, 11,
		UIStyle.GOLD if got else Color(0.46, 0.53, 0.60), HORIZONTAL_ALIGNMENT_RIGHT)
	# 右端多留一点，避免被 ScrollContainer 滚动条压住
	UIStyle.place(xp, 0, 0, 1, 0.5, -124, -10, -30, 10)
	card.add_child(xp)
	if got:
		var check := UIStyle.label("✓", 9, UIStyle.a(UIStyle.GOLD, 0.9), HORIZONTAL_ALIGNMENT_RIGHT)
		UIStyle.place(check, 0, 1, 1, 1, -124, -26, -30, -10)
		card.add_child(check)
	return card


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") \
			or (event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE):
		_close()
		get_viewport().set_input_as_handled()


func _close() -> void:
	closed.emit()
	queue_free()
