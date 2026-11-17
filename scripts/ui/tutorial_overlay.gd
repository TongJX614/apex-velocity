class_name TutorialOverlay
extends CanvasLayer
## 新手教程 · 顶部浮动任务条。
## 首次进入或从主菜单「新手教程」进入时，由 main.gd 创建并绑定到一场
## 1 圈计时赛上：8 个驾驶任务依次以浮动小字呈现，实时判定车辆/比赛状态，
## 完成后绿闪换下一项；冲线后结算页上方换成毕业条（含毕业奖励与去向按钮）。
## 不改动现有 HUD 布局，只把 toast 与结算面板轻轻下移避让任务条。

signal skip_requested
signal completed
signal menu_requested
signal race_requested

const GOLD := UIStyle.GOLD
const BANNER_W := 1000.0
## 画面中间偏上：避开顶部计时/提示 toast，也不压住中央倒数数字。
const BANNER_Y := 256.0
const BANNER_H := 180.0
## 毕业后回到顶部小条位置（结算面板上方），把中央视野还给驾驶。
const GRAD_Y := 218.0
const GRAD_H := 54.0
const FLASH_TIME := 0.85
const TOAST_SHIFT := 80.0
const RESULTS_SHIFT := 104.0
## 教程期间倒数数字整体下移：放大动画的顶端不碰浮条底边。
const COUNTDOWN_SHIFT := 120.0
const FROST_SHADER := preload("res://scripts/ui/frosted_glass.gdshader")

## need > 0 表示按秒累计判定；progress 类型：0 无进度条 1 累计 2 车速 3 氮气量
const STEPS := [
	{"id": "welcome", "title": "欢迎上车", "need": 12.0, "progress": 1,
		"hint": "先看懂下方键位总览 · 倒数结束后出发，1 圈学会全部操作",
		"kb": [], "joy": []},
	{"id": "throttle", "title": "油门起步", "need": 0.0, "progress": 2,
		"hint": "按住油门，把速度提到 40 km/h",
		"kb": ["W", "↑"], "joy": ["RT"]},
	{"id": "steer", "title": "转向过弯", "need": 1.6, "progress": 1,
		"hint": "左右转向沿赛道行驶，感受车头指向",
		"kb": ["A", "D"], "joy": ["左摇杆"]},
	{"id": "brake", "title": "刹车减速", "need": 0.5, "progress": 1,
		"hint": "入弯前按住刹车，把车速降下来",
		"kb": ["S", "↓"], "joy": ["LT"]},
	{"id": "drift", "title": "手刹漂移", "need": 1.2, "progress": 1,
		"hint": "转向时按住手刹让车尾滑出去 · 漂移还能攒氮气",
		"kb": ["空格"], "joy": ["Ⓐ"]},
	{"id": "nitro", "title": "氮气爆发", "need": 0.0, "progress": 3,
		"hint": "直道上按住氮气并带着油门，爆发冲刺",
		"kb": ["SHIFT"], "joy": ["Ⓧ"]},
	{"id": "camera", "title": "切换视角", "need": 0.0, "progress": 0,
		"hint": "换一个顺手的驾驶视角",
		"kb": ["C"], "joy": ["Ⓑ"]},
	{"id": "finish", "title": "冲线毕业", "need": 0.0, "progress": 0,
		"hint": "沿小地图指引跑完这一圈，冲过终点！",
		"kb": [], "joy": []},
]

var _step := 0
var _accum := 0.0
var _flash := 0.0
var _graduated := false
var _cam_mode := -1
var _device_joy := false
var _hud: RaceHUD
var _toast_shifted := false
var _results_shifted := false
var _countdown_shifted := false

var _panel: Panel
var _frost: ColorRect
var _badge: Label
var _divider: ColorRect
var _step_label: Label
var _vtitle: Control
var _vchars: Array[Label] = []
var _hint_row: HBoxContainer
var _hint: Label
var _keys_box: HBoxContainer
var _skip_btn: Button
var _progress_track: ColorRect
var _progress_fill: ColorRect
var _grad_box: Control
var _grad_sub: Label
var _grad_menu_btn: Button
var _key_grid: Panel


func _ready() -> void:
	layer = 12
	_build()
	_enter_step(0)


func _build() -> void:
	var root := Control.new()
	root.name = "Root"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UIStyle.apply_theme(root)
	add_child(root)

	_panel = Panel.new()
	_panel.add_theme_stylebox_override("panel", _banner_style(GOLD, 0.16))
	UIStyle.place(_panel, 0.5, 0, 0.5, 0, -BANNER_W * 0.5, BANNER_Y, BANNER_W * 0.5, BANNER_Y + BANNER_H)
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_panel)

	_frost = ColorRect.new()
	var fm := ShaderMaterial.new()
	fm.shader = FROST_SHADER
	fm.set_shader_parameter("rect_size", Vector2(BANNER_W - 2.0, BANNER_H - 2.0))
	_frost.material = fm
	_frost.set_anchors_preset(Control.PRESET_FULL_RECT)
	_frost.offset_left = 1.0
	_frost.offset_top = 1.0
	_frost.offset_right = -1.0
	_frost.offset_bottom = -1.0
	_frost.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(_frost)

	_badge = UIStyle.label_tracked("✦ 新手教程", 9, UIStyle.a(GOLD, 0.60), HORIZONTAL_ALIGNMENT_LEFT, 2)
	UIStyle.place(_badge, 0, 0, 0, 0, 84, 12, 260, 28)
	_panel.add_child(_badge)

	_step_label = UIStyle.label_tech("", 10, UIStyle.a(GOLD, 0.65), HORIZONTAL_ALIGNMENT_LEFT, 1)
	UIStyle.place(_step_label, 0, 0, 0, 0, 84, 30, 260, 46)
	_panel.add_child(_step_label)

	var divider := ColorRect.new()
	divider.color = UIStyle.a(GOLD, 0.18)
	divider.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UIStyle.place(divider, 0, 0, 0, 0, 72, 14, 73, BANNER_H - 14)
	_panel.add_child(divider)
	_divider = divider

	_vtitle = Control.new()
	_vtitle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_vtitle.rotation = -0.05
	UIStyle.place(_vtitle, 0, 0, 0, 0, 24, 12, 70, BANNER_H - 12)
	_panel.add_child(_vtitle)

	_hint_row = HBoxContainer.new()
	_hint_row.add_theme_constant_override("separation", 7)
	UIStyle.place(_hint_row, 0, 0, 1, 0, 84, 64, -210, 112)
	_hint_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(_hint_row)
	_hint = UIStyle.label("", 12, UIStyle.a(UIStyle.TXT_SUB, 0.85), HORIZONTAL_ALIGNMENT_LEFT)
	_hint_row.add_child(_hint)
	_keys_box = HBoxContainer.new()
	_keys_box.add_theme_constant_override("separation", 4)
	_keys_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hint_row.add_child(_keys_box)

	_skip_btn = Button.new()
	_skip_btn.text = "跳过教程 ›"
	UIStyle.place(_skip_btn, 1, 0, 1, 0, -196, 70, -14, 110)
	UIStyle.apply_button(_skip_btn, UIStyle.TXT_DIM, "ghost", 11)
	_skip_btn.pressed.connect(func() -> void: skip_requested.emit())
	_panel.add_child(_skip_btn)

	_progress_track = ColorRect.new()
	_progress_track.color = Color(0.075, 0.105, 0.135, 0.5)
	UIStyle.place(_progress_track, 0, 1, 1, 1, 10, -5, -10, -2)
	_progress_track.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(_progress_track)
	_progress_fill = ColorRect.new()
	_progress_fill.color = UIStyle.a(GOLD, 0.8)
	UIStyle.place(_progress_fill, 0, 1, 0, 1, 10, -5, 10, -2)
	_progress_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(_progress_fill)

	_build_graduation()
	_build_key_grid(root)


## 任务框融进背景：无底色无投影，只留细边；磨砂与淡色由 frost shader 承担。
func _banner_style(accent: Color, border_alpha: float) -> StyleBoxFlat:
	var sb := UIStyle.glass_style(accent, 0.0, UIStyle.R_LG, border_alpha)
	sb.shadow_size = 0
	return sb


## 竖排艺术标题：逐字缩小、淡出并轻微右移，模拟由近及远的透视虚化。
func _rebuild_title(text: String, color: Color) -> void:
	for c in _vchars:
		c.queue_free()
	_vchars.clear()
	for i in text.length():
		var lbl := UIStyle.label(text[i], 30 - i * 3, color, HORIZONTAL_ALIGNMENT_CENTER)
		lbl.modulate.a = maxf(0.95 - 0.18 * float(i), 0.30)
		var x := 2.0 * float(i)
		var y := 36.0 * float(i)
		UIStyle.place(lbl, 0, 0, 0, 0, x, y, x + 40.0, y + 34.0)
		_vtitle.add_child(lbl)
		_vchars.append(lbl)


## 键位总览：所有常驻键位提示默认隐藏后，全部键位教学集中在这里。
## 只在欢迎步、倒数与 GO 闪结束后展示；避开左下小地图与右下仪表区。
func _build_key_grid(root: Control) -> void:
	_key_grid = Panel.new()
	_key_grid.add_theme_stylebox_override("panel", UIStyle.glass_style(GOLD, 0.90, UIStyle.R_LG, 0.40))
	UIStyle.place(_key_grid, 0, 0, 0, 0, 400, 580, 1140, 840)
	_key_grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_key_grid.visible = false
	root.add_child(_key_grid)
	UIStyle.add_top_glow(_key_grid, GOLD, 0.9)

	var title := UIStyle.label_tracked("✦ 键位总览 · 全部操作一次学会", 10, GOLD,
		HORIZONTAL_ALIGNMENT_LEFT, 2)
	UIStyle.place(title, 0, 0, 1, 0, 16, 10, -16, 28)
	_key_grid.add_child(title)

	var headers := [["驾驶操作", 16.0], ["系统", 193.0], ["主菜单", 370.0], ["车库", 547.0]]
	for h in headers:
		var lbl := UIStyle.label_tracked(String(h[0]), 9, UIStyle.a(GOLD, 0.80),
			HORIZONTAL_ALIGNMENT_LEFT, 2)
		UIStyle.place(lbl, 0, 0, 0, 0, float(h[1]), 34, float(h[1]) + 177.0, 50)
		_key_grid.add_child(lbl)

	var drive := [
		["W/↑ · RT", "油门"], ["S/↓ · LT", "刹车 · 倒车"], ["A/D · 左摇杆", "转向"],
		["SPACE · Ⓐ", "手刹漂移"], ["SHIFT · Ⓧ", "氮气"], ["E/Q · LB/RB", "升降档"],
		["H · R3", "按住回头"], ["右摇杆", "环视 · L3 回正"],
	]
	var system := [
		["T · Ⓨ", "手动 / 自动"], ["R · BACK", "复位"], ["C · Ⓑ", "切视角"],
		["ESC · START", "暂停"], ["M", "主菜单"], ["P · 十字←", "拍照模式"],
		["F2 · 十字→", "比赛设置"], ["N", "重学教程"],
	]
	var menu := [
		["摇杆/十字", "选择"], ["LB/RB", "切换赛道"], ["Ⓐ / ENTER", "发车 · 确认"],
		["D · Ⓑ", "每日合约"], ["X", "成就"], ["P", "赛道档案"],
		["Y", "车库"], ["START", "设置"],
	]
	var garage := [
		["拖拽/右摇杆", "旋转车身"], ["TAB · Ⓨ", "网格 · 改装"], ["十字 / 摇杆", "选择"],
		["Ⓐ / ENTER", "选车 · 升级"], ["LB/RB", "切换改装项"], ["SPACE · Ⓧ", "上赛道"],
		["L", "重置升级"], ["B / START", "返回"],
	]
	for i in drive.size():
		_grid_row(16.0, 54.0 + i * 22.0, 177.0, String(drive[i][0]), String(drive[i][1]))
	for i in system.size():
		_grid_row(193.0, 54.0 + i * 22.0, 177.0, String(system[i][0]), String(system[i][1]))
	for i in menu.size():
		_grid_row(370.0, 54.0 + i * 22.0, 177.0, String(menu[i][0]), String(menu[i][1]))
	for i in garage.size():
		_grid_row(547.0, 54.0 + i * 22.0, 177.0, String(garage[i][0]), String(garage[i][1]))

	var note := UIStyle.label("常驻键位提示默认关闭 · 设置 › 比赛 HUD › 键位提示 可开启", 9, UIStyle.TXT_DIM)
	UIStyle.place(note, 0, 0, 1, 0, 16, 236, -16, 252)
	_key_grid.add_child(note)


func _grid_row(x: float, y: float, w: float, key: String, text: String) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UIStyle.place(row, 0, 0, 0, 0, x, y, x + w, y + 22.0)
	_key_grid.add_child(row)
	row.add_child(UIStyle.keycap(key, GOLD, 9))
	row.add_child(UIStyle.label(text, 11, UIStyle.TXT_SUB))


func _build_graduation() -> void:
	_grad_box = Control.new()
	_grad_box.set_anchors_preset(Control.PRESET_FULL_RECT)
	_grad_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_grad_box.visible = false
	_panel.add_child(_grad_box)

	var title := UIStyle.label("✦ 新手教程完成 · 正式毕业", 15, GOLD, HORIZONTAL_ALIGNMENT_LEFT)
	title.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.5))
	title.add_theme_constant_override("outline_size", 2)
	UIStyle.place(title, 0, 0, 1, 0, 18, 7, -330, 27)
	_grad_box.add_child(title)

	var sub := UIStyle.label("", 11, UIStyle.TXT_SUB, HORIZONTAL_ALIGNMENT_LEFT)
	UIStyle.place(sub, 0, 0, 1, 0, 18, 29, -330, 47)
	_grad_box.add_child(sub)
	_grad_sub = sub

	_grad_menu_btn = Button.new()
	_grad_menu_btn.text = "返回主菜单"
	UIStyle.place(_grad_menu_btn, 1, 0, 1, 0, -318, 11, -176, GRAD_H - 11)
	UIStyle.apply_button(_grad_menu_btn, GOLD, "primary", 12)
	_grad_menu_btn.pressed.connect(func() -> void: menu_requested.emit())
	_grad_box.add_child(_grad_menu_btn)

	var race_btn := Button.new()
	race_btn.text = "再赛一场"
	UIStyle.place(race_btn, 1, 0, 1, 0, -166, 11, -14, GRAD_H - 11)
	UIStyle.apply_button(race_btn, UIStyle.ACCENT, "ghost", 12)
	race_btn.pressed.connect(func() -> void: race_requested.emit())
	_grad_box.add_child(race_btn)


## 绑定到一场新比赛（教程中按 R 重开时复用同一浮层与任务进度）。
func bind(hud: RaceHUD) -> void:
	_restore_hud_offsets()
	_hud = hud
	_cam_mode = -1
	# 毕业条回到顶部时才需要给 toast 让位；任务期间浮条在画面中部，不冲突。
	if _graduated:
		_shift_toast()
		_panel.offset_top = GRAD_Y
		_panel.offset_bottom = GRAD_Y + GRAD_H
	if hud != null and hud.countdown_label != null and not _countdown_shifted:
		hud.countdown_label.offset_top += COUNTDOWN_SHIFT
		hud.countdown_label.offset_bottom += COUNTDOWN_SHIFT
		_countdown_shifted = true


func _shift_toast() -> void:
	if _hud != null and is_instance_valid(_hud) and _hud.toast_label != null and not _toast_shifted:
		_hud.toast_label.offset_top += TOAST_SHIFT
		_hud.toast_label.offset_bottom += TOAST_SHIFT
		_toast_shifted = true


func uninstall() -> void:
	_restore_hud_offsets()
	_hud = null
	queue_free()


func _restore_hud_offsets() -> void:
	if _hud != null and is_instance_valid(_hud):
		if _toast_shifted and _hud.toast_label != null:
			_hud.toast_label.offset_top -= TOAST_SHIFT
			_hud.toast_label.offset_bottom -= TOAST_SHIFT
		if _results_shifted and _hud._results_panel != null:
			_hud._results_panel.offset_top -= RESULTS_SHIFT
			_hud._results_panel.offset_bottom -= RESULTS_SHIFT
		if _countdown_shifted and _hud.countdown_label != null:
			_hud.countdown_label.offset_top -= COUNTDOWN_SHIFT
			_hud.countdown_label.offset_bottom -= COUNTDOWN_SHIFT
	_toast_shifted = false
	_results_shifted = false
	_countdown_shifted = false


func step_index() -> int:
	return _step


func is_graduated() -> bool:
	return _graduated


## 物理帧驱动：判定当前任务、刷新进度与键位提示。
func tick(dt: float, car: Car, race: RaceManager, cam: ChaseCamera) -> void:
	if car == null or race == null:
		return
	if _key_grid != null:
		_key_grid.visible = _step == 0 and _flash <= 0.0 \
			and race.state != RaceManager.State.COUNTDOWN and race.start_flash <= 0.0
	if _graduated:
		return
	if _flash > 0.0:
		_flash -= dt
		if _flash <= 0.0:
			if _step + 1 >= STEPS.size():
				_graduated = true
				_show_graduation()
			else:
				_enter_step(_step + 1)
		return
	var device_joy := InputSetup.last_input_was_joy
	if device_joy != _device_joy:
		_device_joy = device_joy
		_rebuild_keys()
	var step: Dictionary = STEPS[_step]
	var progress := 0.0
	var done := false
	match String(step["id"]):
		"welcome":
			if race.state != RaceManager.State.COUNTDOWN:
				_accum += dt
			progress = clampf(_accum / float(step["need"]), 0.0, 1.0)
			done = _accum >= float(step["need"])
		"throttle":
			progress = clampf(car.speed_kph / 40.0, 0.0, 1.0)
			done = car.speed_kph >= 40.0
			var speed_hint := "%s   ·   当前 %d km/h" % [String(step["hint"]), int(car.speed_kph)]
			if _hint.text != speed_hint:
				_hint.text = speed_hint
		"steer":
			if absf(car.steer) > 0.22 and car.speed_kph > 25.0:
				_accum += dt
			progress = clampf(_accum / float(step["need"]), 0.0, 1.0)
			done = _accum >= float(step["need"])
		"brake":
			if car.throttle < -0.25 and car.speed_kph > 30.0:
				_accum += dt
			progress = clampf(_accum / float(step["need"]), 0.0, 1.0)
			done = _accum >= float(step["need"])
		"drift":
			if car.drift_active and car.speed_kph > 25.0:
				_accum += dt
			progress = clampf(_accum / float(step["need"]), 0.0, 1.0)
			done = _accum >= float(step["need"])
		"nitro":
			progress = clampf(car.nitro_charge, 0.0, 1.0)
			done = car.nitro_active
		"camera":
			if cam != null:
				if _cam_mode < 0:
					_cam_mode = cam.mode
				done = cam.mode != _cam_mode
		"finish":
			done = race.player_finished
	_update_progress(int(step["progress"]), progress)
	if done:
		_complete_step()


func _update_progress(kind: int, value: float) -> void:
	var show := kind != 0
	_progress_track.visible = show
	_progress_fill.visible = show
	if show:
		_progress_fill.offset_right = 10.0 + value * (BANNER_W - 20.0)


func _enter_step(index: int) -> void:
	_step = index
	_accum = 0.0
	_cam_mode = -1
	var step: Dictionary = STEPS[index]
	_step_label.text = "任务 %d / %d" % [index + 1, STEPS.size()]
	_rebuild_title(String(step["title"]), GOLD)
	_hint.text = String(step["hint"])
	_panel.add_theme_stylebox_override("panel", _banner_style(GOLD, 0.16))
	_progress_fill.color = UIStyle.a(GOLD, 0.8)
	_set_frost_tint(0.30)
	_rebuild_keys()
	_update_progress(int(step["progress"]), 0.0)
	_panel.modulate.a = 0.0
	_panel.offset_top = BANNER_Y - 10.0
	_panel.offset_bottom = BANNER_Y + BANNER_H - 10.0
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(_panel, "modulate:a", 1.0, 0.28)
	tw.tween_property(_panel, "offset_top", BANNER_Y, 0.32).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(_panel, "offset_bottom", BANNER_Y + BANNER_H, 0.32).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


func _rebuild_keys() -> void:
	for child in _keys_box.get_children():
		child.queue_free()
	var step: Dictionary = STEPS[_step]
	var keys: Array = step["joy"] if _device_joy else step["kb"]
	for key in keys:
		_keys_box.add_child(UIStyle.keycap(String(key), GOLD, 9))


func _complete_step() -> void:
	var step: Dictionary = STEPS[_step]
	_rebuild_title("✓完成", UIStyle.GREEN)
	_hint.text = "「%s」做得好，准备下一项" % String(step["title"])
	for child in _keys_box.get_children():
		child.queue_free()
	_panel.add_theme_stylebox_override("panel", _banner_style(UIStyle.GREEN, 0.35))
	_set_frost_tint(0.34, Color(0.03, 0.09, 0.05))
	_update_progress(1, 1.0)
	_progress_fill.color = UIStyle.a(UIStyle.GREEN, 0.8)
	_flash = FLASH_TIME


func _set_frost_tint(alpha: float, rgb := Color(0.035, 0.05, 0.075)) -> void:
	var fm := _frost.material as ShaderMaterial
	fm.set_shader_parameter("tint", Vector4(rgb.r, rgb.g, rgb.b, alpha))


func _show_graduation() -> void:
	_badge.visible = false
	_divider.visible = false
	_step_label.visible = false
	_vtitle.visible = false
	_hint_row.visible = false
	_skip_btn.visible = false
	_progress_track.visible = false
	_progress_fill.visible = false
	_grad_box.visible = true
	if ProfileStore.tutorial_state() == "done":
		_grad_sub.text = "%d 项驾驶任务全部达成 · 复习完成，奖励不重复发放" % STEPS.size()
	else:
		_grad_sub.text = "%d 项驾驶任务全部达成 · 毕业奖励 +%d XP 已入账" % [STEPS.size(), ProfileStore.XP_TUTORIAL]
	_panel.add_theme_stylebox_override("panel", UIStyle.glass_style(GOLD, 0.94, UIStyle.R_MD, 0.55))
	(_frost.material as ShaderMaterial).set_shader_parameter("rect_size", Vector2(BANNER_W - 2.0, GRAD_H - 2.0))
	(_frost.material as ShaderMaterial).set_shader_parameter("corner_radius", float(UIStyle.R_MD))
	_set_frost_tint(0.88)
	_shift_toast()
	var tw := create_tween().set_parallel(true)
	tw.tween_property(_panel, "offset_top", GRAD_Y, 0.35).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(_panel, "offset_bottom", GRAD_Y + GRAD_H, 0.35).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	if _hud != null and is_instance_valid(_hud) and _hud._results_panel != null and not _results_shifted:
		_hud._results_panel.offset_top += RESULTS_SHIFT
		_hud._results_panel.offset_bottom += RESULTS_SHIFT
		_results_shifted = true
	# 冲线瞬间玩家可能还按着手刹/油门（空格也是 ui_accept），
	# 延迟一拍再抓焦点，避免误触「返回主菜单」。
	get_tree().create_timer(1.2).timeout.connect(func() -> void:
		if is_instance_valid(_grad_menu_btn) and _grad_box.visible:
			_grad_menu_btn.grab_focus())
	completed.emit()