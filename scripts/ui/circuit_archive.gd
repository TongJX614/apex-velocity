class_name CircuitArchive
extends CanvasLayer
## 赛道档案：8 站精通等级 / 个人最佳 / 下一目标 / 纪录保持车总览。
## 选中卡片后切回主菜单并定位到该赛道；ESC 关闭。

signal closed
signal track_selected(track_id: String)

const ACCENT := UIStyle.ACCENT
const PANEL_W := 1240.0
const PANEL_H := 680.0
const PAD := 40.0
const COL_GAP := 14.0
const CARD_H := 100.0
const ROW_GAP := 12.0
const GRID_TOP := 166.0

var track_lengths: Dictionary = {}
var current_track_id := ""

var _panel: Panel
var _cards: Array[Button] = []
var _detail_root: Control
var _detail_title: Label
var _detail_meta: Label
var _detail_list: VBoxContainer
var _detail_scroll: ScrollContainer
var _detail_track_id := ""
var _sort_mode := 0
var _sort_buttons: Array[Button] = []
var _detail_open := false


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
	glow.texture = UIStyle.glow_texture(ACCENT, 1.8)
	glow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	glow.stretch_mode = TextureRect.STRETCH_SCALE
	glow.modulate = Color(1, 1, 1, 0.09)
	UIStyle.place(glow, 0.5, 0.5, 0.5, 0.5, -640, -440, 640, 440)
	glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(glow)

	_panel = Panel.new()
	_panel.add_theme_stylebox_override("panel",
		UIStyle.glass_style(ACCENT, 0.95, UIStyle.R_LG, 0.30))
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UIStyle.place(_panel, 0.5, 0.5, 0.5, 0.5, -PANEL_W * 0.5, -PANEL_H * 0.5,
		PANEL_W * 0.5, PANEL_H * 0.5)
	root.add_child(_panel)
	UIStyle.add_top_glow(_panel, ACCENT, 0.95)

	var kicker := UIStyle.label_tracked("APEX VELOCITY   /   CIRCUIT ARCHIVE", 9,
		UIStyle.a(ACCENT, 0.95), HORIZONTAL_ALIGNMENT_LEFT, 2)
	UIStyle.place(kicker, 0, 0, 1, 0, PAD, 26, -PAD, 46)
	_panel.add_child(kicker)

	var title := UIStyle.label_display("赛道档案   /   CIRCUIT ARCHIVE", 30, UIStyle.TXT,
		HORIZONTAL_ALIGNMENT_LEFT, 2)
	UIStyle.place(title, 0, 0, 1, 0, PAD, 48, -300, 92)
	_panel.add_child(title)

	var sub := UIStyle.label_tracked("8 站精通 · 个人最佳 · ENTER / 点击卡片 查看全部成绩并可排序   ·   ESC 关闭",
		10, UIStyle.TXT_DIM, HORIZONTAL_ALIGNMENT_LEFT, 1)
	UIStyle.place(sub, 0, 0, 1, 0, PAD + 2, 94, -PAD, 114)
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
	close_row.add_child(UIStyle.spacer())
	close_row.add_child(UIStyle.keycap("ESC", ACCENT, 9))

	var profile := ProfileStore.load_profile()
	var summary := UIStyle.label_tech(_summary_text(profile), 12, UIStyle.TXT_SUB,
		HORIZONTAL_ALIGNMENT_LEFT, 1)
	UIStyle.place(summary, 0, 0, 1, 0, PAD, 124, -PAD, 154)
	_panel.add_child(summary)

	_build_grid(profile)
	_build_detail()

	var foot := HBoxContainer.new()
	foot.add_theme_constant_override("separation", 10)
	UIStyle.place(foot, 0, 1, 1, 1, PAD, -56, -PAD, -26)
	_panel.add_child(foot)
	foot.add_child(UIStyle.keycap("↑ ↓ ← →", ACCENT, 9))
	foot.add_child(UIStyle.label("选择赛道", 10, UIStyle.TXT_DIM))
	foot.add_child(UIStyle.keycap("ENTER", ACCENT, 9))
	foot.add_child(UIStyle.label("查看全部成绩", 10, UIStyle.TXT_DIM))
	foot.add_child(UIStyle.spacer())
	foot.add_child(UIStyle.label_tracked("MASTERY  BRONZE · SILVER · GOLD", 9,
		UIStyle.a(UIStyle.GOLD, 0.72), HORIZONTAL_ALIGNMENT_RIGHT, 2))

	_panel.pivot_offset = Vector2(PANEL_W, PANEL_H) * 0.5
	_panel.scale = Vector2(0.97, 0.97)
	_panel.modulate.a = 0.0
	var tw := _panel.create_tween()
	tw.set_parallel(true)
	tw.tween_property(_panel, "scale", Vector2.ONE, 0.32) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(_panel, "modulate:a", 1.0, 0.22)

	_focus_current()


## 档案只覆盖 8 条 GP 赛道；开放世界是自由漫游，不参与圈速精通。
func _archive_tracks() -> Array:
	var out: Array = []
	for def in GameData.tracks:
		if not bool(def.get("openWorld", false)):
			out.append(def)
	return out


func _summary_text(profile: Dictionary) -> String:
	var tier_counts := [0, 0, 0, 0]
	var covered := 0
	var lap_total := 0
	var tracks := _archive_tracks()
	for def in tracks:
		var id := String(def.get("id", ""))
		var state := ProfileStore.mastery_state(profile, id, _length_for(def),
			int(def.get("difficulty", 2)))
		tier_counts[clampi(int(state.get("tier", 0)), 0, 3)] += 1
		var by_car := _laps_for(profile, id)
		if not by_car.is_empty():
			covered += 1
		for car_id in by_car:
			var times = by_car[car_id]
			if typeof(times) == TYPE_ARRAY:
				lap_total += (times as Array).size()
	return "精通   铜 %d  ·  银 %d  ·  金 %d      ·      纪录覆盖 %d / %d 站      ·      圈速记录 %d 条      ·      Lv.%d" % [
		tier_counts[1], tier_counts[2], tier_counts[3], covered,
		tracks.size(), lap_total, int(profile.get("level", 1))]


func _build_grid(profile: Dictionary) -> void:
	var inner_w := PANEL_W - PAD * 2.0
	var card_w := (inner_w - COL_GAP) * 0.5
	var tracks := _archive_tracks()
	for i in tracks.size():
		var track: Dictionary = tracks[i]
		var col := i % 2
		var row := i / 2
		var left := PAD + col * (card_w + COL_GAP)
		var top := GRID_TOP + row * (CARD_H + ROW_GAP)
		var card := _make_card(track, i + 1, profile)
		UIStyle.place(card, 0, 0, 0, 0, left, top, left + card_w, top + CARD_H)
		_panel.add_child(card)
		_cards.append(card)


func _make_card(track: Dictionary, index: int, profile: Dictionary) -> Button:
	var track_id := String(track.get("id", ""))
	var accent := UIStyle.accent_from(track.get("cardColor", ""), ACCENT)
	var difficulty := clampi(int(track.get("difficulty", 2)), 1, 5)
	var length_km := _length_for(track) / 1000.0
	var state := ProfileStore.mastery_state(profile, track_id, _length_for(track), difficulty)
	var tier := clampi(int(state.get("tier", 0)), 0, 3)
	var best := float(state.get("best_lap", -1.0))
	var by_car := _laps_for(profile, track_id)
	var lap_count := 0
	for car_id in by_car:
		var times = by_car[car_id]
		if typeof(times) == TYPE_ARRAY:
			lap_count += (times as Array).size()

	var card := Button.new()
	card.focus_mode = Control.FOCUS_ALL
	card.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	UIStyle.apply_button(card, accent, "ghost", 1)
	card.pressed.connect(func() -> void: _open_detail(track_id))

	var bar := ColorRect.new()
	bar.color = UIStyle.a(accent, 0.85)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UIStyle.place(bar, 0, 0, 0, 0, 0, 10, 3, CARD_H - 10)
	card.add_child(bar)

	var number := UIStyle.label_tech("%02d" % index, 17, accent, HORIZONTAL_ALIGNMENT_CENTER)
	UIStyle.place(number, 0, 0, 0, 0, 10, 20, 58, 44)
	card.add_child(number)
	var station := UIStyle.label_tracked("STN", 8, UIStyle.a(accent, 0.62), HORIZONTAL_ALIGNMENT_CENTER, 2)
	UIStyle.place(station, 0, 0, 0, 0, 10, 44, 58, 58)
	card.add_child(station)
	var rule := ColorRect.new()
	rule.color = UIStyle.a(accent, 0.22)
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UIStyle.place(rule, 0, 0, 0, 0, 66, 18, 67, CARD_H - 18)
	card.add_child(rule)

	var name_label := UIStyle.label_display(String(track.get("name", track_id)), 17,
		UIStyle.TXT, HORIZONTAL_ALIGNMENT_LEFT, 1)
	UIStyle.place(name_label, 0, 0, 0, 0, 76, 14, 300, 38)
	card.add_child(name_label)
	var en_label := UIStyle.label_tracked(String(track.get("en", "")), 9,
		UIStyle.a(accent, 0.88), HORIZONTAL_ALIGNMENT_LEFT, 2)
	UIStyle.place(en_label, 0, 0, 0, 0, 76, 40, 300, 56)
	card.add_child(en_label)
	var meta_text := "%.2f km · %d 圈 · %s · %d车 · %d圈" % [
		length_km, int(track.get("laps", 3)), _difficulty_dots(difficulty),
		by_car.size(), lap_count]
	var meta := UIStyle.label(meta_text, 10, UIStyle.TXT_DIM)
	meta.clip_text = true
	meta.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	UIStyle.place(meta, 0, 0, 0, 0, 76, 64, 304, 84)
	card.add_child(meta)

	var mastery := UIStyle.label_tech("精通  %s" % ProfileStore.mastery_label(tier), 11,
		_tier_color(tier), HORIZONTAL_ALIGNMENT_LEFT, 1)
	UIStyle.place(mastery, 0, 0, 0, 0, 312, 16, 424, 36)
	card.add_child(mastery)
	var pips := UIStyle.label_tracked(_tier_pips(tier), 13, _tier_color(tier),
		HORIZONTAL_ALIGNMENT_LEFT, 3)
	UIStyle.place(pips, 0, 0, 0, 0, 312, 38, 424, 56)
	card.add_child(pips)
	var next_text := _next_target_text(state, tier)
	var next_label := UIStyle.label(String(next_text[0]), 9, UIStyle.TXT_DIM)
	next_label.clip_text = true
	next_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	UIStyle.place(next_label, 0, 0, 0, 0, 312, 57, 428, 73)
	card.add_child(next_label)
	var gap_label := UIStyle.label(String(next_text[1]), 9, _tier_color(maxi(tier, 1)))
	UIStyle.place(gap_label, 0, 0, 0, 0, 312, 72, 428, 88)
	card.add_child(gap_label)

	var best_caption := UIStyle.label_tracked("最佳单圈  BEST LAP", 8, UIStyle.TXT_FAINT,
		HORIZONTAL_ALIGNMENT_RIGHT, 2)
	UIStyle.place(best_caption, 0, 0, 1, 0, 436, 12, -16, 26)
	card.add_child(best_caption)
	var best_label := UIStyle.label_tech(RaceManager.format_time(best), 16,
		UIStyle.GOLD if best > 0.0 else UIStyle.TXT_FAINT, HORIZONTAL_ALIGNMENT_RIGHT)
	UIStyle.place(best_label, 0, 0, 1, 0, 420, 26, -16, 50)
	card.add_child(best_label)
	var holder := _record_holder(profile, track_id)
	var holder_text := "尚无纪录"
	if not String(holder["car"]).is_empty():
		holder_text = "纪录  %s" % _car_name(String(holder["car"]))
	var holder_label := UIStyle.label(holder_text, 9, UIStyle.TXT_DIM, HORIZONTAL_ALIGNMENT_RIGHT)
	holder_label.clip_text = true
	holder_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	UIStyle.place(holder_label, 0, 0, 1, 0, 436, 62, -16, 80)
	card.add_child(holder_label)
	return card


func _tier_color(tier: int) -> Color:
	match clampi(tier, 0, 3):
		3:
			return UIStyle.GOLD
		2:
			return Color(0.80, 0.87, 0.96, 1.0)
		1:
			return Color(0.88, 0.64, 0.42, 1.0)
	return UIStyle.TXT_FAINT


func _tier_pips(tier: int) -> String:
	var t := clampi(tier, 0, 3)
	return "◆".repeat(t) + "◇".repeat(3 - t)


func _next_target_text(state: Dictionary, tier: int) -> Array:
	var best := float(state.get("best_lap", -1.0))
	var targets: Dictionary = state.get("targets", {})
	if tier >= 3:
		return ["金牌精通已达成", "保持这个圈速"]
	var next_target := float(state.get("next_target", 0.0))
	if next_target <= 0.0:
		return ["暂无精通目标", ""]
	var tier_name := ProfileStore.mastery_label(tier + 1)
	if best <= 0.0:
		return ["%s目标  %s" % [tier_name, RaceManager.format_time(next_target)], "跑出首个有效单圈"]
	var gap := best - next_target
	if gap <= 0.05:
		return ["%s目标  %s" % [tier_name, RaceManager.format_time(next_target)], "已达标"]
	return ["%s目标  %s" % [tier_name, RaceManager.format_time(next_target)],
		"距目标  %.3f s" % gap]


func _difficulty_dots(level: int) -> String:
	return "●".repeat(clampi(level, 1, 5))


func _laps_for(profile: Dictionary, track_id: String) -> Dictionary:
	var all_laps = profile.get("best_laps", {})
	if typeof(all_laps) != TYPE_DICTIONARY:
		return {}
	var by_car = (all_laps as Dictionary).get(track_id, {})
	if typeof(by_car) != TYPE_DICTIONARY:
		return {}
	return by_car


func _record_holder(profile: Dictionary, track_id: String) -> Dictionary:
	var best := -1.0
	var car_id := ""
	var by_car := _laps_for(profile, track_id)
	for key in by_car:
		var times = by_car[key]
		if typeof(times) != TYPE_ARRAY:
			continue
		for t in (times as Array):
			var value := float(t)
			if value > 0.0 and (best < 0.0 or value < best):
				best = value
				car_id = String(key)
	return {"car": car_id, "lap": best}


func _car_name(car_id: String) -> String:
	var spec := GameData.car(car_id)
	if spec.is_empty():
		return car_id
	return String(spec.get("name", car_id))


func _length_for(track: Dictionary) -> float:
	var id := String(track.get("id", ""))
	if track_lengths.has(id) and float(track_lengths[id]) > 0.0:
		return float(track_lengths[id])
	var path := TrackPath.new()
	path.build_from_def(track, 2.0)
	track_lengths[id] = path.total_length
	return path.total_length


func _focus_current() -> void:
	var index := _track_index(current_track_id)
	if index >= 0 and index < _cards.size():
		_cards[index].grab_focus()
	elif not _cards.is_empty():
		_cards[0].grab_focus()


func _track_index(track_id: String) -> int:
	if track_id.is_empty():
		return -1
	var tracks := _archive_tracks()
	for i in tracks.size():
		if String(tracks[i].get("id", "")) == track_id:
			return i
	return -1


# ---------------------------------------------------------------------------
# 全部成绩（点击赛道卡片进入，可排序）
# ---------------------------------------------------------------------------

func _build_detail() -> void:
	_detail_root = Control.new()
	_detail_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_detail_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_detail_root.visible = false
	_panel.add_child(_detail_root)

	var bg := ColorRect.new()
	bg.color = Color(0.010, 0.019, 0.026, 0.965)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	UIStyle.place(bg, 0, 0, 1, 1, PAD - 8, 104, -PAD + 8, -16)
	_detail_root.add_child(bg)

	_detail_title = UIStyle.label_display("", 22, UIStyle.TXT, HORIZONTAL_ALIGNMENT_LEFT, 1)
	UIStyle.place(_detail_title, 0, 0, 1, 0, PAD + 16, 118, -PAD - 16, 148)
	_detail_root.add_child(_detail_title)

	_detail_meta = UIStyle.label_tech("", 10, UIStyle.TXT_DIM, HORIZONTAL_ALIGNMENT_LEFT, 1)
	UIStyle.place(_detail_meta, 0, 0, 1, 0, PAD + 16, 150, -PAD - 16, 170)
	_detail_root.add_child(_detail_meta)

	var sort_caption := UIStyle.label_tracked("排序  SORT", 9, UIStyle.TXT_FAINT,
		HORIZONTAL_ALIGNMENT_LEFT, 1)
	UIStyle.place(sort_caption, 0, 0, 0, 0, PAD + 16, 182, PAD + 76, 202)
	_detail_root.add_child(sort_caption)
	var sort_names := ["圈速最快", "最近比赛", "按车辆"]
	for i in sort_names.size():
		var sort_i := i
		var btn := Button.new()
		btn.focus_mode = Control.FOCUS_ALL
		btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		btn.text = sort_names[i]
		UIStyle.apply_button(btn, ACCENT, "ghost", 10)
		UIStyle.place(btn, 0, 0, 0, 0, PAD + 78 + i * 112, 178,
			PAD + 78 + i * 112 + 104, 204)
		btn.pressed.connect(func() -> void:
			_sort_mode = sort_i
			_refresh_detail())
		_detail_root.add_child(btn)
		_sort_buttons.append(btn)

	var header := Panel.new()
	header.add_theme_stylebox_override("panel", UIStyle.inset_style(ACCENT, 0.5))
	UIStyle.place(header, 0, 0, 1, 0, PAD + 16, 212, -PAD - 16, 240)
	_detail_root.add_child(header)
	var head_row := HBoxContainer.new()
	head_row.add_theme_constant_override("separation", 8)
	UIStyle.place(head_row, 0, 0, 1, 1, 12, 2, -12, -2)
	header.add_child(head_row)
	head_row.add_child(_row_label("#", 30, UIStyle.TXT_FAINT, HORIZONTAL_ALIGNMENT_LEFT, 9))
	var hcar := _row_label("车辆", 300, UIStyle.TXT_FAINT, HORIZONTAL_ALIGNMENT_LEFT, 9)
	hcar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head_row.add_child(hcar)
	head_row.add_child(_row_label("最佳单圈", 120, UIStyle.TXT_FAINT, HORIZONTAL_ALIGNMENT_RIGHT, 9))
	head_row.add_child(_row_label("比赛用时", 120, UIStyle.TXT_FAINT, HORIZONTAL_ALIGNMENT_RIGHT, 9))
	head_row.add_child(_row_label("模式", 54, UIStyle.TXT_FAINT, HORIZONTAL_ALIGNMENT_CENTER, 9))
	head_row.add_child(_row_label("奖牌", 46, UIStyle.TXT_FAINT, HORIZONTAL_ALIGNMENT_CENTER, 9))
	head_row.add_child(_row_label("日期", 96, UIStyle.TXT_FAINT, HORIZONTAL_ALIGNMENT_RIGHT, 9))

	_detail_scroll = ScrollContainer.new()
	_detail_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_detail_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	UIStyle.place(_detail_scroll, 0, 0, 1, 0, PAD + 16, 246, -PAD - 16, 568)
	_detail_root.add_child(_detail_scroll)
	_detail_list = VBoxContainer.new()
	_detail_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail_list.add_theme_constant_override("separation", 4)
	_detail_scroll.add_child(_detail_list)

	var back := UIStyle.make_button("ESC   返回赛道列表", ACCENT, "ghost", 11, 30.0)
	UIStyle.place(back, 0, 0, 0, 0, PAD + 16, 580, PAD + 236, 612)
	back.pressed.connect(_close_detail)
	_detail_root.add_child(back)

	var choose := UIStyle.make_button("ENTER   切换到该赛道", UIStyle.GOLD, "primary", 11, 30.0)
	UIStyle.place(choose, 0, 0, 1, 0, -PAD - 272, 580, -PAD - 16, 612)
	choose.pressed.connect(func() -> void: _choose(_detail_track_id))
	_detail_root.add_child(choose)


func _open_detail(track_id: String) -> void:
	_detail_track_id = track_id
	_detail_open = true
	_detail_root.visible = true
	for card in _cards:
		card.visible = false
	_refresh_detail()
	if not _sort_buttons.is_empty():
		_sort_buttons[_sort_mode].grab_focus()


func _close_detail() -> void:
	_detail_open = false
	_detail_root.visible = false
	for card in _cards:
		card.visible = true
	var index := _track_index(_detail_track_id)
	if index >= 0 and index < _cards.size():
		_cards[index].grab_focus()


func _refresh_detail() -> void:
	if _detail_list == null:
		return
	var track := {}
	for def in GameData.tracks:
		if String(def.get("id", "")) == _detail_track_id:
			track = def
			break
	for child in _detail_list.get_children():
		_detail_list.remove_child(child)
		child.queue_free()
	var profile := ProfileStore.load_profile()
	var entries := _detail_entries(_detail_track_id, profile)
	_sort_entries(entries)
	_detail_title.text = "%s   /   %s" % [
		String(track.get("name", _detail_track_id)),
		String(track.get("en", "")).to_upper()]
	var best_lap := -1.0
	var best_total := -1.0
	var cars := {}
	for e in entries:
		var lap := float(e.get("lap", 0.0))
		if lap > 0.0 and (best_lap < 0.0 or lap < best_lap):
			best_lap = lap
		var total := float(e.get("total", 0.0))
		if total > 0.0 and (best_total < 0.0 or total < best_total):
			best_total = total
		var car := String(e.get("car", ""))
		if not car.is_empty():
			cars[car] = true
	_detail_meta.text = "共 %d 条成绩   ·   %d 台车   ·   最快单圈 %s   ·   最快比赛 %s" % [
		entries.size(), cars.size(), _time_or_dash(best_lap), _time_or_dash(best_total)]
	if entries.is_empty():
		var empty := UIStyle.label(
			"这条赛道还没有成绩。跑一场比赛后，最近 10 次比赛和每台车的最佳圈都会出现在这里。",
			11, UIStyle.TXT_DIM)
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		empty.custom_minimum_size = Vector2(0, 48)
		_detail_list.add_child(empty)
	else:
		for i in entries.size():
			_detail_list.add_child(_detail_row(entries[i], i + 1))
	_apply_sort_styles()
	if _detail_scroll != null:
		_detail_scroll.scroll_vertical = 0


func _apply_sort_styles() -> void:
	for i in _sort_buttons.size():
		UIStyle.apply_button(_sort_buttons[i], ACCENT,
			"primary" if i == _sort_mode else "ghost", 10)


func _detail_entries(track_id: String, profile: Dictionary) -> Array:
	var entries: Array = []
	var seen := {}
	var history := RecordsStore.history(track_id)
	for item in history:
		var lap := float(item.get("lap", 0.0))
		var car := String(item.get("car", ""))
		entries.append({
			"car": car,
			"lap": lap,
			"total": float(item.get("total", 0.0)),
			"mode": String(item.get("mode", "")),
			"medal": String(item.get("medal", "none")),
			"date": int(item.get("date", 0)),
			"record": false,
		})
		if lap > 0.0:
			seen[_lap_key(car, lap)] = true
	var by_car := _laps_for(profile, track_id)
	for car_id in by_car:
		var times = by_car[car_id]
		if typeof(times) != TYPE_ARRAY:
			continue
		for t in (times as Array):
			var lap := float(t)
			if lap <= 0.0:
				continue
			var key := _lap_key(String(car_id), lap)
			if seen.has(key):
				continue
			seen[key] = true
			entries.append({
				"car": String(car_id),
				"lap": lap,
				"total": 0.0,
				"mode": "",
				"medal": "none",
				"date": 0,
				"record": false,
			})
	# 老存档只有赛道总纪录、没有 history 时，补一条总览，避免详情空白。
	if history.is_empty():
		var record_entry := RecordsStore.for_track(track_id)
		for mode in ["gp", "ta"]:
			var mode_entry = record_entry.get(mode, {})
			if typeof(mode_entry) != TYPE_DICTIONARY:
				continue
			var total := float((mode_entry as Dictionary).get("total", -1.0))
			if total <= 0.0:
				continue
			entries.append({
				"car": "",
				"lap": float((mode_entry as Dictionary).get("lap", 0.0)),
				"total": total,
				"mode": mode,
				"medal": String((mode_entry as Dictionary).get("medal", "none")),
				"date": 0,
				"record": true,
			})
	return entries


func _sort_entries(entries: Array) -> void:
	match _sort_mode:
		1:
			entries.sort_custom(func(a, b) -> bool:
				var da := int(a.get("date", 0))
				var db := int(b.get("date", 0))
				if da != db:
					return da > db
				return _lap_order(a) < _lap_order(b))
		2:
			entries.sort_custom(func(a, b) -> bool:
				var ca := _car_display(String(a.get("car", "")))
				var cb := _car_display(String(b.get("car", "")))
				if ca != cb:
					return ca < cb
				return _lap_order(a) < _lap_order(b))
		_:
			entries.sort_custom(func(a, b) -> bool:
				return _lap_order(a) < _lap_order(b))


func _lap_order(entry: Dictionary) -> float:
	var lap := float(entry.get("lap", 0.0))
	return lap if lap > 0.0 else 1.0e9


func _lap_key(car_id: String, lap: float) -> String:
	return "%s|%d" % [car_id, int(round(lap * 1000.0))]


func _detail_row(entry: Dictionary, rank: int) -> Control:
	var row := Panel.new()
	row.custom_minimum_size = Vector2(0, 34)
	row.add_theme_stylebox_override("panel",
		UIStyle.inset_style(ACCENT, 0.28 if rank % 2 == 1 else 0.16))
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 8)
	UIStyle.place(hb, 0, 0, 1, 1, 12, 3, -12, -3)
	row.add_child(hb)
	var rank_color := UIStyle.GOLD if rank <= 3 else UIStyle.a(ACCENT, 0.72)
	hb.add_child(_row_label("%02d" % rank, 30, rank_color, HORIZONTAL_ALIGNMENT_LEFT, 9))
	var car := _row_label(_car_display(String(entry.get("car", ""))), 300,
		UIStyle.TXT, HORIZONTAL_ALIGNMENT_LEFT, 10)
	car.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	car.clip_text = true
	car.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	hb.add_child(car)
	var lap := float(entry.get("lap", 0.0))
	hb.add_child(_row_label(_time_or_dash(lap), 120,
		UIStyle.GOLD if lap > 0.0 else UIStyle.TXT_FAINT,
		HORIZONTAL_ALIGNMENT_RIGHT, 10))
	var total := float(entry.get("total", 0.0))
	hb.add_child(_row_label(_time_or_dash(total), 120, UIStyle.TXT_SUB,
		HORIZONTAL_ALIGNMENT_RIGHT, 10))
	hb.add_child(_row_label(_mode_text(String(entry.get("mode", ""))), 54,
		UIStyle.a(ACCENT, 0.88), HORIZONTAL_ALIGNMENT_CENTER, 9))
	var medal := String(entry.get("medal", "none"))
	hb.add_child(_row_label(_medal_text(medal), 46, _medal_color(medal),
		HORIZONTAL_ALIGNMENT_CENTER, 9))
	hb.add_child(_row_label(_date_text(int(entry.get("date", 0))), 96, UIStyle.TXT_DIM,
		HORIZONTAL_ALIGNMENT_RIGHT, 9))
	return row


func _row_label(text: String, width: float, color: Color, align: int,
		size: int = 10) -> Label:
	var lbl := UIStyle.label_tech(text, size, color, align, 1)
	lbl.custom_minimum_size = Vector2(width, 0)
	lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return lbl


func _time_or_dash(t: float) -> String:
	if t <= 0.0 or not is_finite(t):
		return "--:--.---"
	return RaceManager.format_time(t)


func _car_display(car_id: String) -> String:
	if car_id.is_empty():
		return "赛道总纪录"
	return _car_name(car_id)


func _mode_text(mode: String) -> String:
	match mode:
		"gp":
			return "GP"
		"ta":
			return "TA"
	return "最佳"


func _medal_text(medal: String) -> String:
	match medal:
		"gold":
			return "金"
		"silver":
			return "银"
		"bronze":
			return "铜"
	return "—"


func _medal_color(medal: String) -> Color:
	match medal:
		"gold":
			return UIStyle.GOLD
		"silver":
			return Color(0.80, 0.87, 0.96, 1.0)
		"bronze":
			return Color(0.88, 0.64, 0.42, 1.0)
	return UIStyle.TXT_FAINT


func _date_text(unix_time: int) -> String:
	if unix_time <= 0:
		return "存档最佳"
	var d := Time.get_datetime_dict_from_unix_time(unix_time)
	return "%02d-%02d %02d:%02d" % [int(d["month"]), int(d["day"]), int(d["hour"]), int(d["minute"])]


func _process(delta: float) -> void:
	if not _detail_open or _detail_scroll == null:
		return
	var v := Input.get_joy_axis(0, JOY_AXIS_RIGHT_Y)
	if absf(v) > 0.35:
		_detail_scroll.scroll_vertical += int(v * 620.0 * delta)


func _choose(track_id: String) -> void:
	track_selected.emit(track_id)
	queue_free()


func _unhandled_input(event: InputEvent) -> void:
	if _detail_open:
		if event is InputEventJoypadButton and event.pressed:
			var jb := event as InputEventJoypadButton
			if jb.button_index == JOY_BUTTON_LEFT_SHOULDER:
				_sort_mode = posmod(_sort_mode - 1, 3)
				_refresh_detail()
				get_viewport().set_input_as_handled()
				return
			if jb.button_index == JOY_BUTTON_RIGHT_SHOULDER:
				_sort_mode = posmod(_sort_mode + 1, 3)
				_refresh_detail()
				get_viewport().set_input_as_handled()
				return
		if event is InputEventKey and event.pressed and not event.echo:
			var key := (event as InputEventKey).keycode
			if key >= KEY_1 and key <= KEY_3:
				_sort_mode = key - KEY_1
				_refresh_detail()
				get_viewport().set_input_as_handled()
				return
		if event.is_action_pressed("ui_cancel"):
			_close_detail()
			get_viewport().set_input_as_handled()
			return
	if event.is_action_pressed("ui_cancel") \
			or (event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE):
		_close()
		get_viewport().set_input_as_handled()


func _close() -> void:
	closed.emit()
	queue_free()
