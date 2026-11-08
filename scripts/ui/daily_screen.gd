class_name DailyScreen
extends CanvasLayer
## 每日合约：每天 3 条随机目标，完成后领取 XP。ESC 关闭。

signal closed

const ACCENT := UIStyle.ACCENT
const PANEL_W := 1040.0
const PANEL_H := 616.0

var _rows: VBoxContainer
var _summary_label: Label
var _toast: Label
var _panel: Panel


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

	var glow := TextureRect.new()
	glow.texture = UIStyle.glow_texture(UIStyle.GOLD, 1.8)
	glow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	glow.stretch_mode = TextureRect.STRETCH_SCALE
	glow.modulate = Color(1, 1, 1, 0.09)
	UIStyle.place(glow, 0.5, 0.5, 0.5, 0.5, -600, -420, 600, 420)
	glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(glow)

	_panel = Panel.new()
	_panel.add_theme_stylebox_override("panel", UIStyle.glass_style(UIStyle.GOLD, 0.95, UIStyle.R_LG, 0.30))
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UIStyle.place(_panel, 0.5, 0.5, 0.5, 0.5, -PANEL_W * 0.5, -PANEL_H * 0.5,
		PANEL_W * 0.5, PANEL_H * 0.5)
	root.add_child(_panel)
	UIStyle.add_top_glow(_panel, UIStyle.GOLD, 0.95)

	var kicker := UIStyle.label_tracked("APEX VELOCITY   /   DAILY CONTRACTS", 9,
		UIStyle.a(UIStyle.GOLD, 0.95), HORIZONTAL_ALIGNMENT_LEFT, 2)
	UIStyle.place(kicker, 0, 0, 1, 0, 40, 26, -40, 46)
	_panel.add_child(kicker)

	var title := UIStyle.label_display("每日合约   /   DAILY CONTRACTS", 30, UIStyle.TXT,
		HORIZONTAL_ALIGNMENT_LEFT, 2)
	UIStyle.place(title, 0, 0, 1, 0, 40, 48, -300, 92)
	_panel.add_child(title)

	var sub := UIStyle.label_tracked("每日 0 点刷新   ·   完成目标领取 XP   ·   ESC 关闭", 10,
		UIStyle.TXT_DIM, HORIZONTAL_ALIGNMENT_LEFT, 1)
	UIStyle.place(sub, 0, 0, 1, 0, 42, 94, -300, 114)
	_panel.add_child(sub)

	var close_btn := Button.new()
	close_btn.focus_mode = Control.FOCUS_ALL
	close_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	UIStyle.apply_button(close_btn, UIStyle.GOLD, "ghost", 11)
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
	close_row.add_child(UIStyle.label("✕", 12, UIStyle.a(UIStyle.GOLD, 0.95)))
	close_row.add_child(UIStyle.label("关闭  /  CLOSE", 11, UIStyle.TXT_SUB))
	close_row.add_child(UIStyle.spacer())
	close_row.add_child(UIStyle.keycap("ESC", UIStyle.GOLD, 9))

	# 日期 + 可领取摘要
	var date_row := HBoxContainer.new()
	date_row.add_theme_constant_override("separation", 12)
	UIStyle.place(date_row, 0, 0, 1, 0, 40, 124, -40, 156)
	_panel.add_child(date_row)
	date_row.add_child(UIStyle.keycap("TODAY", UIStyle.GOLD, 9))
	var date_label := UIStyle.label_tech(ProfileStore.today_key(), 15, UIStyle.TXT,
		HORIZONTAL_ALIGNMENT_LEFT, 1)
	date_row.add_child(date_label)
	date_row.add_child(UIStyle.spacer())
	_summary_label = UIStyle.label_tracked("", 10, UIStyle.GOLD, HORIZONTAL_ALIGNMENT_RIGHT, 1)
	date_row.add_child(_summary_label)

	_rows = VBoxContainer.new()
	_rows.add_theme_constant_override("separation", 10)
	UIStyle.place(_rows, 0, 0, 1, 1, 40, 170, -40, -72)
	_panel.add_child(_rows)

	_toast = UIStyle.label("", 11, UIStyle.GOLD, HORIZONTAL_ALIGNMENT_CENTER)
	UIStyle.place(_toast, 0, 1, 1, 1, 40, -60, -40, -34)
	_toast.modulate.a = 0.0
	_panel.add_child(_toast)

	var foot := HBoxContainer.new()
	foot.add_theme_constant_override("separation", 10)
	UIStyle.place(foot, 0, 1, 1, 1, 40, -52, -40, -24)
	_panel.add_child(foot)
	foot.add_child(UIStyle.keycap("ENTER", UIStyle.GOLD, 9))
	foot.add_child(UIStyle.label("检查可领取的合约   ·   每日刷新后重新累计", 10, UIStyle.TXT_DIM))

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


func _refresh() -> void:
	var contracts := ProfileStore.daily_contracts()
	var summary := ProfileStore.daily_summary()
	_summary_label.text = "已完成  %d / %d    ·   可领取 %d 条 / %d XP" % [
		int(summary["done"]), int(summary["total"]),
		int(summary["claimable"]), int(summary["xp_ready"])]
	for child in _rows.get_children():
		child.queue_free()
	for i in contracts.size():
		_rows.add_child(_make_card(contracts[i], i + 1))


func _make_card(contract: Dictionary, index: int) -> Control:
	var card := Panel.new()
	card.custom_minimum_size = Vector2(0, 112)
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var complete := bool(contract["complete"])
	var claimed := bool(contract["claimed"])
	var style := UIStyle.inset_style(UIStyle.GOLD if complete else ACCENT, 0.52)
	style.border_color = UIStyle.a(UIStyle.GOLD, 0.42) if complete else Color(0.28, 0.34, 0.41, 0.55)
	if claimed:
		style.bg_color = Color(0.055, 0.060, 0.058, 0.92)
	elif complete:
		style.bg_color = Color(0.075, 0.070, 0.048, 0.92)
	card.add_theme_stylebox_override("panel", style)

	var index_badge := Panel.new()
	var badge_style := StyleBoxFlat.new()
	badge_style.bg_color = UIStyle.a(UIStyle.GOLD, 0.14) if complete else Color(0.10, 0.12, 0.15, 0.85)
	badge_style.border_color = UIStyle.a(UIStyle.GOLD, 0.55) if complete else Color(0.24, 0.30, 0.36, 0.7)
	badge_style.set_border_width_all(1)
	badge_style.set_corner_radius_all(UIStyle.R_PILL)
	index_badge.add_theme_stylebox_override("panel", badge_style)
	index_badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UIStyle.place(index_badge, 0, 0, 0, 0, 16, 16, 60, 52)
	card.add_child(index_badge)
	var index_label := UIStyle.label_tech("%02d" % index, 15,
		UIStyle.GOLD if complete else UIStyle.TXT_SUB, HORIZONTAL_ALIGNMENT_CENTER)
	index_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	index_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	index_badge.add_child(index_label)

	var name_label := UIStyle.label(String(contract["name"]), 16,
		UIStyle.TXT if not claimed or complete else UIStyle.TXT_SUB)
	UIStyle.place(name_label, 0, 0, 1, 0, 76, 14, -220, 38)
	card.add_child(name_label)
	var desc := UIStyle.label(String(contract["desc"]), 10,
		UIStyle.TXT_DIM if not complete else Color(0.82, 0.78, 0.62, 1.0))
	UIStyle.place(desc, 0, 0, 1, 0, 76, 40, -220, 60)
	card.add_child(desc)

	var goal := maxi(1, int(contract["goal"]))
	var value := int(contract["progress"])
	var bar := ProgressBar.new()
	bar.max_value = float(goal)
	bar.value = float(value)
	bar.show_percentage = false
	UIStyle.style_progress(bar, UIStyle.GOLD if complete else ACCENT)
	UIStyle.place(bar, 0, 1, 1, 1, 76, -38, -220, -26)
	card.add_child(bar)
	var progress_label := UIStyle.label_tech("%d / %d" % [value, goal], 11,
		UIStyle.GOLD if complete else UIStyle.TXT_SUB, HORIZONTAL_ALIGNMENT_RIGHT, 1)
	UIStyle.place(progress_label, 0, 1, 1, 1, -210, -40, -84, -22)
	card.add_child(progress_label)

	var xp_label := UIStyle.label_tech("+%d XP" % int(contract["xp"]), 13,
		UIStyle.GOLD if complete else UIStyle.TXT_SUB, HORIZONTAL_ALIGNMENT_RIGHT)
	UIStyle.place(xp_label, 0, 0, 1, 0, -210, 14, -120, 36)
	card.add_child(xp_label)

	var claim := Button.new()
	claim.focus_mode = Control.FOCUS_ALL
	claim.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	UIStyle.apply_button(claim, UIStyle.GOLD, "ghost", 11)
	UIStyle.place(claim, 1, 0.5, 1, 0.5, -112, -18, -16, 18)
	card.add_child(claim)
	if claimed:
		claim.disabled = true
		claim.text = "已领取"
	elif complete:
		claim.text = "领取奖励"
		claim.pressed.connect(func() -> void: _claim(String(contract["id"])))
	else:
		claim.disabled = true
		claim.text = "进行中"
	return card


func _claim(id: String) -> void:
	var report := ProfileStore.claim_daily(id)
	if not bool(report.get("ok", false)):
		return
	var text := "已领取  %s   +%d XP" % [String(report.get("name", "")), int(report.get("xp", 0))]
	if bool(report.get("level_up", false)):
		text += "    ·    升级  LV %d" % int(report.get("level_after", 1))
	_toast.text = text
	_toast.modulate.a = 1.0
	var tw := _toast.create_tween()
	tw.tween_interval(2.0)
	tw.tween_property(_toast, "modulate:a", 0.0, 0.5)
	_refresh()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") \
			or (event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE):
		_close()
		get_viewport().set_input_as_handled()


func _close() -> void:
	closed.emit()
	queue_free()
