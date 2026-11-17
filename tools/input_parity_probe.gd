extends Node
## 手柄映射与界面焦点探针（可无头运行）：
##   Godot --headless --path . res://tools/input_parity_probe.tscn

var failures: Array[String] = []


func _ready() -> void:
	await get_tree().process_frame
	InputSetup.ensure_actions()
	_test_mappings()
	_test_drive_input()
	await _test_pause()
	await _test_hud_hints()
	await _test_tutorial_and_settings()
	await _test_screens()
	print("[PROBE] %s (%d checks failed)" % ["PASS" if failures.is_empty() else "FAIL", failures.size()])
	for f in failures:
		print("[PROBE][FAIL] " + f)
	get_tree().quit(0 if failures.is_empty() else 1)


func _check(ok: bool, msg: String) -> void:
	if ok:
		print("[PROBE][OK] " + msg)
	else:
		failures.append(msg)


func _has_joy(action: String, button: int) -> bool:
	if not InputMap.has_action(action):
		return false
	for ev in InputMap.action_get_events(action):
		if ev is InputEventJoypadButton and (ev as InputEventJoypadButton).button_index == button:
			return true
	return false


func _has_joy_axis(action: String, axis: int, value: float) -> bool:
	if not InputMap.has_action(action):
		return false
	for ev in InputMap.action_get_events(action):
		if ev is InputEventJoypadMotion:
			var motion := ev as InputEventJoypadMotion
			if motion.axis == axis and signf(motion.axis_value) == signf(value):
				return true
	return false


func _has_key(action: String, key: int) -> bool:
	if not InputMap.has_action(action):
		return false
	for ev in InputMap.action_get_events(action):
		if ev is InputEventKey and (ev as InputEventKey).physical_keycode == key:
			return true
	return false


func _test_mappings() -> void:
	_check(_has_key("look_back", KEY_H), "H -> look_back")
	_check(_has_key("camera_mode", KEY_C), "C -> camera_mode")
	_check(_has_key("reset_car", KEY_R), "R -> reset_car")
	_check(_has_joy("handbrake", JOY_BUTTON_A), "A -> handbrake")
	_check(not _has_joy("handbrake", JOY_BUTTON_B), "B no longer handbrake")
	_check(_has_joy("nitro", JOY_BUTTON_X), "X -> nitro")
	_check(_has_joy("camera_mode", JOY_BUTTON_B), "B -> camera_mode")
	_check(_has_joy("manual_toggle", JOY_BUTTON_Y), "Y -> manual_toggle")
	_check(_has_joy("reset_car", JOY_BUTTON_BACK), "BACK -> reset_car")
	_check(_has_joy("look_back", JOY_BUTTON_RIGHT_STICK), "R3 -> look_back")
	_check(_has_joy("camera_reset", JOY_BUTTON_LEFT_STICK), "L3 -> camera_reset")
	_check(_has_joy("shift_up", JOY_BUTTON_RIGHT_SHOULDER) and _has_joy("shift_up", JOY_BUTTON_DPAD_UP),
		"RB + D-pad up -> shift_up")
	_check(_has_joy("shift_down", JOY_BUTTON_LEFT_SHOULDER) and _has_joy("shift_down", JOY_BUTTON_DPAD_DOWN),
		"LB + D-pad down -> shift_down")
	_check(_has_joy("ui_accept", JOY_BUTTON_A), "A -> ui_accept")
	_check(_has_joy("ui_cancel", JOY_BUTTON_B) and _has_joy("ui_cancel", JOY_BUTTON_START),
		"B / START -> ui_cancel")
	_check(_has_joy("ui_up", JOY_BUTTON_DPAD_UP), "D-pad up -> ui_up")
	_check(_has_joy("ui_down", JOY_BUTTON_DPAD_DOWN), "D-pad down -> ui_down")
	_check(_has_joy("ui_left", JOY_BUTTON_DPAD_LEFT), "D-pad left -> ui_left")
	_check(_has_joy("ui_right", JOY_BUTTON_DPAD_RIGHT), "D-pad right -> ui_right")
	_check(_has_joy_axis("ui_left", JOY_AXIS_LEFT_X, -1.0), "left stick X- -> ui_left")
	_check(_has_joy_axis("ui_right", JOY_AXIS_LEFT_X, 1.0), "left stick X+ -> ui_right")
	_check(_has_joy_axis("ui_up", JOY_AXIS_LEFT_Y, -1.0), "left stick Y- -> ui_up")
	_check(_has_joy_axis("ui_down", JOY_AXIS_LEFT_Y, 1.0), "left stick Y+ -> ui_down")


func _test_pause() -> void:
	var pause := PauseScreen.new()
	add_child(pause)
	pause.setup("霓虹都市环线", "BMW M3 E46 GTR")
	await get_tree().process_frame
	await get_tree().create_timer(0.25).timeout
	_check(pause._buttons.size() == 5, "pause has 5 options")
	if pause._buttons.size() == 5:
		var photo_btn: Button = pause._buttons[4]
		var resume_btn: Button = pause._buttons[0]
		_check(not photo_btn.focus_neighbor_right.is_empty(), "pause photo -> resume focus")
		_check(not resume_btn.focus_neighbor_left.is_empty(), "pause resume -> photo focus")
		var counts := {"photo": 0, "restart": 0}
		pause.photo_requested.connect(func() -> void: counts["photo"] += 1)
		pause._on_option_pressed(photo_btn)
		_check(counts["photo"] == 1, "pause photo option emits")
		pause.restart_requested.connect(func() -> void: counts["restart"] += 1)
		var restart_btn: Button = pause._buttons[1]
		pause._on_option_pressed(restart_btn)
		_check(counts["restart"] == 0 and pause._armed == restart_btn, "pause destructive action arms")
		pause._on_option_pressed(restart_btn)
		_check(counts["restart"] == 1 and pause._armed == null, "pause destructive action confirms")
	var kb := pause._hint_kb != null and pause._hint_pad != null
	_check(kb, "pause has keyboard + pad hint rows")
	pause.queue_free()
	await get_tree().process_frame


func _test_screens() -> void:
	var ach := AchievementsScreen.new()
	add_child(ach)
	await get_tree().process_frame
	await get_tree().create_timer(0.2).timeout
	_check(ach._scroll != null, "achievements scroll container exists")
	_check(ach._scroll != null and ach._scroll.get_v_scroll_bar() != null, "achievements scrollbar exists")
	if ach._scroll != null:
		ach._scroll.scroll_vertical = 0
		Input.action_press("ui_down")
		for i in 3:
			await get_tree().process_frame
		Input.action_release("ui_down")
		_check(ach._scroll.scroll_vertical > 0, "achievements scrolls with ui_down")
	ach.queue_free()
	await get_tree().process_frame

	_seed_daily_complete()
	var daily := DailyScreen.new()
	add_child(daily)
	await get_tree().process_frame
	await get_tree().create_timer(0.2).timeout
	_check(daily._close_btn != null, "daily close button exists")
	_check(daily._claim_buttons.size() > 0, "daily has claimable buttons in seeded profile")
	if daily._close_btn != null and not daily._claim_buttons.is_empty():
		_check(not daily._close_btn.focus_neighbor_bottom.is_empty(),
			"daily close -> first claim focus")
		var first: Button = daily._claim_buttons[0]
		_check(not first.focus_neighbor_top.is_empty(), "daily claim -> close/claim focus")
		var before := daily._claim_buttons.size()
		first.pressed.emit()
		await get_tree().process_frame
		_check(daily._claim_buttons.size() == before - 1, "daily claim refreshes claim list")
	daily.queue_free()
	await get_tree().process_frame


func _seed_daily_complete() -> void:
	var profile := ProfileStore.load_profile()
	var progress := {}
	for c in ProfileStore.daily_contracts(profile):
		progress[String(c["id"])] = maxi(1, int(c["goal"]))
	profile["daily"] = {"date": ProfileStore.today_key(), "progress": progress, "claimed": {}}
	ProfileStore.save_profile(profile)


func _test_drive_input() -> void:
	Input.action_press("throttle")
	var drive := InputSetup.read_drive_input()
	Input.action_release("throttle")
	_check(float(drive["throttle"]) > 0.99, "keyboard throttle -> drive input")
	Input.action_press("brake")
	drive = InputSetup.read_drive_input()
	Input.action_release("brake")
	_check(float(drive["throttle"]) < -0.99, "keyboard brake -> reverse throttle")
	Input.action_press("handbrake")
	drive = InputSetup.read_drive_input()
	Input.action_release("handbrake")
	_check(bool(drive["handbrake"]), "keyboard handbrake -> drive input")


func _test_hud_hints() -> void:
	var hud := RaceHUD.new()
	add_child(hud)
	await get_tree().process_frame
	InputSetup.last_input_was_joy = true
	hud._refresh_common()
	await get_tree().process_frame
	_check(hud.hint_label.get_combined_minimum_size().x <= 954.0,
		"pad driving hint fits HUD width")
	_check(hud.camera_label.get_combined_minimum_size().x <= 511.0,
		"pad camera hint fits plate width")
	InputSetup.last_input_was_joy = false
	hud._refresh_common()
	await get_tree().process_frame
	_check(hud.hint_label.get_combined_minimum_size().x <= 954.0,
		"keyboard driving hint fits HUD width")
	_check(hud.camera_label.get_combined_minimum_size().x <= 511.0,
		"keyboard camera hint fits plate width")
	hud.queue_free()
	await get_tree().process_frame


func _test_tutorial_and_settings() -> void:
	var tutorial := TutorialOverlay.new()
	add_child(tutorial)
	await get_tree().process_frame
	await get_tree().create_timer(0.2).timeout
	var grid_rows := 0
	for child in tutorial._key_grid.get_children():
		if child is HBoxContainer:
			grid_rows += 1
			var row := child as HBoxContainer
			_check(row.get_combined_minimum_size().x <= 178.0,
				"tutorial key row fits 177px column")
			_check(row.position.y + row.size.y <= 236.0,
				"tutorial key row above footer note")
	_check(grid_rows == 32, "tutorial key grid has 32 rows (4 x 8)")
	if DisplayServer.get_name() != "headless":
		tutorial._key_grid.visible = true
		await _shot("/tmp/parity_tutorial_grid.png")
	tutorial.queue_free()
	await get_tree().process_frame

	var settings := SettingsScreen.new()
	add_child(settings)
	settings.visible = true
	settings._select_tab(2)
	await get_tree().process_frame
	await get_tree().create_timer(0.3).timeout
	for i in settings._pages.size():
		settings._pages[i].visible = i == 2
	await get_tree().process_frame
	await get_tree().create_timer(0.1).timeout
	var columns := 0
	for child in settings._pages[2].get_children():
		if child is VBoxContainer:
			var col := child as VBoxContainer
			if is_equal_approx(col.size.x, 720.0) or is_equal_approx(col.size.x, 540.0):
				columns += 1
				var bottom := 0.0
				for sub in col.get_children():
					var c := sub as Control
					bottom = maxf(bottom, c.position.y + c.size.y)
				_check(bottom <= 621.0,
					"settings controls column fits 620px height (x=%.0f bottom=%.0f)" % [
						col.size.x, bottom])
	_check(columns == 2, "settings controls page has two columns")
	if DisplayServer.get_name() != "headless":
		await _shot("/tmp/parity_settings_controls.png")
	settings.queue_free()
	await get_tree().process_frame


func _shot(path: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var err := img.save_png(path)
	print("[PROBE] shot %s err=%d %dx%d" % [path, err, img.get_width(), img.get_height()])
