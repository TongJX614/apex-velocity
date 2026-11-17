extends Node
## 结算按钮 + 暂停二次确认 验收探针（窗口化运行）：
##   Godot --path . --resolution 1600x900 res://tools/ui_flow_probe.tscn
## 验证：暂停破坏性操作两次按下才发信号 / 切换按钮或超时或 ESC 解除武装 /
## 结算面板三个可点按钮发信号且不溢出面板。截图 /tmp/ui_flow_*.png。

var failures: Array[String] = []
var pause: PauseScreen
var hud: RaceHUD
var counts := {"resume": 0, "restart": 0, "menu": 0, "settings": 0, "photo": 0}
var rcounts := {"restart": 0, "next": 0, "menu": 0}
var archive_done := false


func _ready() -> void:
	await get_tree().process_frame
	await _test_pause()
	await _test_results()
	await _test_archive()
	_check(archive_done, "archive test ran to completion")
	print("[PROBE] %s (%d checks failed)" % ["PASS" if failures.is_empty() else "FAIL", failures.size()])
	for f in failures:
		print("[PROBE][FAIL] " + f)
	get_tree().quit(0 if failures.is_empty() else 1)


func _check(ok: bool, msg: String) -> void:
	if ok:
		print("[PROBE][OK] " + msg)
	else:
		failures.append(msg)


func _test_pause() -> void:
	pause = PauseScreen.new()
	add_child(pause)
	pause.setup("霓虹都市环线", "BMW M3 E46 GTR")
	pause.resume_requested.connect(func() -> void: counts["resume"] += 1)
	pause.restart_requested.connect(func() -> void: counts["restart"] += 1)
	pause.menu_requested.connect(func() -> void: counts["menu"] += 1)
	pause.settings_requested.connect(func() -> void: counts["settings"] += 1)
	pause.photo_requested.connect(func() -> void: counts["photo"] += 1)
	await get_tree().process_frame
	await get_tree().create_timer(0.3).timeout
	_check(pause._buttons.size() == 5, "pause has 5 option buttons")
	var resume_btn: Button = pause._buttons[0]
	var restart_btn: Button = pause._buttons[1]
	var menu_btn: Button = pause._buttons[3]

	menu_btn.pressed.emit()
	_check(counts["menu"] == 0, "first menu press does NOT quit race")
	_check(pause._armed == menu_btn, "first menu press arms confirm")
	await get_tree().create_timer(0.2).timeout
	await _shot("/tmp/ui_flow_pause_armed.png")
	menu_btn.pressed.emit()
	_check(counts["menu"] == 1, "second menu press confirms")
	_check(pause._armed == null, "confirm disarms")

	restart_btn.pressed.emit()
	_check(pause._armed == restart_btn and counts["restart"] == 0, "restart arms without restarting")
	resume_btn.pressed.emit()
	_check(counts["resume"] == 1 and pause._armed == null, "pressing another option disarms and acts")

	restart_btn.pressed.emit()
	pause._tick_arm(3.1)
	_check(pause._armed == null and counts["restart"] == 0, "arm auto-expires after 3s")

	restart_btn.pressed.emit()
	var esc := InputEventKey.new()
	esc.keycode = KEY_ESCAPE
	esc.pressed = true
	if esc.is_action_pressed("ui_cancel"):
		var r0: int = counts["resume"]
		pause._handle_cancel()
		_check(pause._armed == null and counts["resume"] == r0, "ESC disarms instead of resuming")
		pause._handle_cancel()
		_check(counts["resume"] == r0 + 1, "ESC again resumes")
	else:
		print("[PROBE] skip ESC assertions (ui_cancel not bound to ESC)")
	pause.queue_free()
	await get_tree().process_frame


func _test_results() -> void:
	hud = RaceHUD.new()
	add_child(hud)
	await get_tree().process_frame
	var rm := RaceManager.new()
	rm.mode = "gp"
	rm.total_cars = 4
	rm.medal = "gold"
	rm.player_finish_time = 187.42
	rm.best_lap_time = 61.20
	rm.ai_fastest_lap = 61.90
	rm.ai_fastest_name = "Rival 1"
	rm.best_sector_times = [20.1, 20.4, 20.7]
	rm.record_summary = {"new_total": true, "best_total": 187.42, "new_lap": false, "best_lap": 61.2}
	rm.results = [
		{"rank": 1, "is_player": true, "name": "BMW M3 E46 GTR", "time_text": "3:07.42"},
		{"rank": 2, "is_player": false, "name": "Rival 1", "time_text": "+0.84"},
		{"rank": 3, "is_player": false, "name": "Rival 2", "time_text": "+2.10"},
		{"rank": 4, "is_player": false, "name": "Rival 3", "time_text": "+4.63"},
	]
	hud.result_restart_requested.connect(func() -> void: rcounts["restart"] += 1)
	hud.result_next_requested.connect(func() -> void: rcounts["next"] += 1)
	hud.result_menu_requested.connect(func() -> void: rcounts["menu"] += 1)
	hud.show_results(rm)
	await get_tree().process_frame
	await get_tree().create_timer(0.4).timeout
	_check(hud._result_buttons.size() == 3, "results has 3 action buttons")
	var panel_rect := hud._results_panel.get_global_rect()
	for i in hud._result_buttons.size():
		var b: Button = hud._result_buttons[i]
		_check(b.visible, "result button %d visible" % i)
		_check(panel_rect.encloses(b.get_global_rect()), "result button %d inside panel" % i)
	_check(panel_rect.encloses(hud.results_hint.get_global_rect()), "key hint inside panel")
	_check(panel_rect.encloses(hud.results_records.get_global_rect()), "records inside panel")
	hud._result_buttons[0].pressed.emit()
	hud._result_buttons[1].pressed.emit()
	hud._result_buttons[2].pressed.emit()
	_check(rcounts["restart"] == 1 and rcounts["next"] == 1 and rcounts["menu"] == 1,
		"result buttons emit restart/next/menu signals")
	await _shot("/tmp/ui_flow_results.png")


func _test_archive() -> void:
	var arc := CircuitArchive.new()
	add_child(arc)
	await get_tree().process_frame
	await get_tree().create_timer(0.3).timeout
	var sc := arc._grid_scroll
	_check(sc != null, "archive grid lives in a ScrollContainer")
	if sc == null:
		arc.queue_free()
		return
	var panel_rect := arc._panel.get_global_rect()
	_check(panel_rect.encloses(sc.get_global_rect()), "scroll viewport inside panel")
	_check(sc.get_global_rect().end.y <= panel_rect.end.y - 60, "scroll viewport clears panel footer")
	var scroll_max := int(sc.get_v_scroll_bar().max_value)
	_check(scroll_max > 0, "11 tracks overflow into a real scroll range")
	sc.scroll_vertical = scroll_max
	await get_tree().process_frame
	var cards := arc._grid_root.get_children()
	var last: Control = cards[cards.size() - 1]
	_check(sc.get_global_rect().encloses(last.get_global_rect()),
		"last track card fully reachable at scroll bottom")
	await _shot("/tmp/ui_flow_archive_bottom.png")
	sc.scroll_vertical = 0
	await get_tree().process_frame
	var first: Control = cards[0]
	_check(sc.get_global_rect().encloses(first.get_global_rect()), "first card visible at scroll top")
	arc._open_detail(String(GameData.tracks[0].get("id", "")))
	await get_tree().process_frame
	_check(arc._detail_open and not sc.visible, "detail view hides grid scroll")
	arc._close_detail()
	await get_tree().process_frame
	_check(not arc._detail_open and sc.visible, "closing detail restores grid scroll")
	arc.queue_free()
	await get_tree().process_frame
	archive_done = true


func _shot(path: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var err := img.save_png(path)
	print("[PROBE] shot %s err=%d %dx%d" % [path, err, img.get_width(), img.get_height()])