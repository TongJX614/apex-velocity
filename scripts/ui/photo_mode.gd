class_name PhotoMode
extends Node3D
## 拍照模式：自由飞行机位。
## 鼠标：旋转视角 + 滚轮变焦；键盘：WASD 前后左右、Q/E 下降/上升。
## 树处于 paused，本节点 PROCESS_MODE_ALWAYS，保证相机与 UI 仍然响应。

signal closed

const MOVE_SPEED := 12.0
const FAST_MUL := 3.2
const ORBIT_SENS := 0.0024
const STICK_LOOK_RATE := 2.4
const STICK_PITCH_RATE := 1.7
const MIN_FOV := 18.0
const MAX_FOV := 95.0
const PHOTO_DIR := "user://photos"

var camera: Camera3D
var _chase: Camera3D
var _car: Node3D
var _pos := Vector3.ZERO
var _yaw := 0.0
var _pitch := -0.10
var _fov := 55.0
var _home_pos := Vector3.ZERO
var _home_yaw := 0.0
var _home_pitch := -0.10
var _home_fov := 55.0
var _ui: CanvasLayer
var _hint: Label
var _saved: Label
var _fov_label: Label
var _flash: ColorRect
var _flash_t := 0.0
var _saving := false
var _fast := false
var _hud_hidden := false
var _prev_buttons: Dictionary = {}


func setup(chase_cam: Camera3D, car: Node3D) -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_chase = chase_cam
	_car = car
	# 初始机位直接继承追尾相机：玩家进入拍照时看到的就是刚才的画面。
	if chase_cam != null and is_instance_valid(chase_cam):
		_pos = chase_cam.global_position
		_yaw = chase_cam.global_rotation.y
		_pitch = clampf(chase_cam.global_rotation.x, -1.35, 1.35)
		_fov = clampf(chase_cam.fov, MIN_FOV, MAX_FOV)
	elif car != null:
		_pos = car.global_position + Vector3(0.0, 4.0, 9.0)
		_yaw = PI
		_pitch = -0.18
	_home_pos = _pos
	_home_yaw = _yaw
	_home_pitch = _pitch
	_home_fov = _fov
	camera = Camera3D.new()
	camera.name = "PhotoCamera"
	camera.fov = _fov
	camera.near = 0.05
	camera.far = 4000.0
	add_child(camera)
	camera.current = true
	camera.global_position = _pos
	camera.rotation = Vector3(_pitch, _yaw, 0.0)
	_build_ui()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _build_ui() -> void:
	_ui = CanvasLayer.new()
	_ui.name = "PhotoUI"
	_ui.layer = 96
	add_child(_ui)
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui.add_child(root)

	# 上下电影黑边
	for y_anchor in [0.0, 1.0]:
		var bar := ColorRect.new()
		bar.color = Color(0.0, 0.0, 0.0, 0.86)
		bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if y_anchor < 0.5:
			UIStyle.place(bar, 0, 0, 1, 0, 0, 0, 0, 34)
		else:
			UIStyle.place(bar, 0, 1, 1, 1, 0, -34, 0, 0)
		root.add_child(bar)

	# 左上角半透明底，保证亮天空下文字可读
	var cap := ColorRect.new()
	cap.color = Color(0.0, 0.0, 0.0, 0.24)
	cap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UIStyle.place(cap, 0, 0, 0, 0, 18, 18, 396, 102)
	root.add_child(cap)

	var title := UIStyle.label_display("PHOTO MODE", 20, UIStyle.TXT,
		HORIZONTAL_ALIGNMENT_LEFT, 3)
	title.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.8))
	title.add_theme_constant_override("outline_size", 4)
	UIStyle.place(title, 0, 0, 0, 0, 34, 30, 380, 66)
	root.add_child(title)
	var sub := UIStyle.label_tracked("拍 照 模 式   ·   比赛已暂停", 9,
		Color(0.66, 0.88, 0.94, 1.0), HORIZONTAL_ALIGNMENT_LEFT, 2)
	sub.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.7))
	sub.add_theme_constant_override("outline_size", 3)
	UIStyle.place(sub, 0, 0, 0, 0, 36, 66, 390, 88)
	root.add_child(sub)

	_fov_label = UIStyle.label_tracked("FOV 55°", 10, Color(0.82, 0.90, 0.96, 0.95),
		HORIZONTAL_ALIGNMENT_RIGHT, 1)
	_fov_label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.75))
	_fov_label.add_theme_constant_override("outline_size", 3)
	UIStyle.place(_fov_label, 1, 0, 1, 0, -180, 30, -30, 52)
	root.add_child(_fov_label)

	# 中心准星：自由机位需要一个“看向哪里”的参照
	var cross_h := ColorRect.new()
	cross_h.color = Color(1.0, 1.0, 1.0, 0.38)
	cross_h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UIStyle.place(cross_h, 0.5, 0.5, 0.5, 0.5, -7, -0.5, 7, 0.5)
	root.add_child(cross_h)
	var cross_v := ColorRect.new()
	cross_v.color = Color(1.0, 1.0, 1.0, 0.38)
	cross_v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UIStyle.place(cross_v, 0.5, 0.5, 0.5, 0.5, -0.5, -7, 0.5, 7)
	root.add_child(cross_v)

	_hint = UIStyle.label(
		"键盘  鼠标 旋转 · 滚轮/[/] 变焦 · WASD 移动 · Q/E 升降 · Shift 加速 · R 复位 · F12 截图 · ESC 退出\n"
		+ "手柄  左摇杆/十字键 移动 · 右摇杆 旋转 · LT/RT 降/升 · LB/RB 变焦 · A 拍照 · X 复位 · Y 加速 · L3 隐藏界面 · B 退出",
		10, Color(0.86, 0.92, 0.96, 0.98))
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.75))
	_hint.add_theme_constant_override("outline_size", 3)
	UIStyle.place(_hint, 0, 1, 1, 1, 0, -96, 0, -48)
	root.add_child(_hint)

	_saved = UIStyle.label("", 11, Color(0.55, 0.92, 0.70, 1.0))
	_saved.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_saved.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_saved.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.75))
	_saved.add_theme_constant_override("outline_size", 3)
	UIStyle.place(_saved, 0, 1, 1, 1, 120, -132, -120, -102)
	root.add_child(_saved)

	_flash = ColorRect.new()
	_flash.color = Color(1.0, 1.0, 1.0, 0.0)
	_flash.set_anchors_preset(Control.PRESET_FULL_RECT)
	_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_flash)


func _process(dt: float) -> void:
	var device := InputSetup.primary_joypad()
	_poll_pad_buttons(device)
	var step := dt * (FAST_MUL if (Input.is_key_pressed(KEY_SHIFT) or _fast) else 1.0)
	var move := Vector3.ZERO
	if Input.is_key_pressed(KEY_W):
		move -= camera.global_transform.basis.z
	if Input.is_key_pressed(KEY_S):
		move += camera.global_transform.basis.z
	if Input.is_key_pressed(KEY_D):
		move += camera.global_transform.basis.x
	if Input.is_key_pressed(KEY_A):
		move -= camera.global_transform.basis.x
	if Input.is_key_pressed(KEY_E) or Input.is_key_pressed(KEY_SPACE):
		move += Vector3.UP
	if Input.is_key_pressed(KEY_Q) or Input.is_key_pressed(KEY_CTRL):
		move -= Vector3.UP
	# 手柄左摇杆 + 十字键：平面移动。
	var pad_move := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	if pad_move.length_squared() > 0.0:
		move += camera.global_transform.basis.x * pad_move.x
		move += camera.global_transform.basis.z * pad_move.y
	if device >= 0:
		# 扳机升降；右摇杆环视。
		var rt := Input.get_joy_axis(device, JOY_AXIS_TRIGGER_RIGHT)
		var lt := Input.get_joy_axis(device, JOY_AXIS_TRIGGER_LEFT)
		if rt > 0.12:
			move += Vector3.UP * rt
		if lt > 0.12:
			move -= Vector3.UP * lt
		var rs := InputSetup.right_stick()
		if rs.length_squared() > 0.0:
			_yaw -= rs.x * STICK_LOOK_RATE * dt
			_pitch = clampf(_pitch - rs.y * STICK_PITCH_RATE * dt, -1.45, 1.45)
	if move.length_squared() > 0.0:
		_pos += move.normalized() * MOVE_SPEED * step
	# 防止钻到地形下面：高度场地图用真实地面，其余地图以 0.4m 为下限。
	if Terrain.active:
		_pos.y = maxf(_pos.y, Terrain.height_at(_pos) + 0.35)
	else:
		_pos.y = maxf(_pos.y, 0.4)
	camera.global_position = _pos
	camera.rotation = Vector3(_pitch, _yaw, 0.0)
	camera.fov = lerpf(camera.fov, _fov, 1.0 - exp(-dt * 14.0))
	if _flash_t > 0.0 and _flash != null:
		_flash_t = maxf(0.0, _flash_t - dt)
		_flash.color.a = 0.35 * (_flash_t / 0.45)


func _poll_pad_buttons(device: int) -> void:
	if device < 0:
		return
	if _pad_edge(device, JOY_BUTTON_A):
		_save_photo()
	if _pad_edge(device, JOY_BUTTON_B) or _pad_edge(device, JOY_BUTTON_START):
		close()
		return
	if _pad_edge(device, JOY_BUTTON_X):
		_reset_view()
	if _pad_edge(device, JOY_BUTTON_Y):
		_fast = not _fast
		_saved.text = "快速移动  %s" % ("开" if _fast else "关")
	if _pad_edge(device, JOY_BUTTON_RIGHT_SHOULDER):
		_set_fov(_fov - 3.0)
	if _pad_edge(device, JOY_BUTTON_LEFT_SHOULDER):
		_set_fov(_fov + 3.0)
	if _pad_edge(device, JOY_BUTTON_LEFT_STICK):
		_hud_hidden = not _hud_hidden
		if _ui != null:
			_ui.visible = not _hud_hidden
	if _pad_edge(device, JOY_BUTTON_RIGHT_STICK):
		_yaw = _home_yaw
		_pitch = _home_pitch


func _pad_edge(device: int, button: int) -> bool:
	var key := "%d:%d" % [device, button]
	var now := Input.is_joy_button_pressed(device, button)
	var was := bool(_prev_buttons.get(key, false))
	_prev_buttons[key] = now
	return now and not was


func _input(event: InputEvent) -> void:
	InputSetup.note_input(event)
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var mm := event as InputEventMouseMotion
		_yaw -= mm.relative.x * ORBIT_SENS
		_pitch = clampf(_pitch - mm.relative.y * ORBIT_SENS, -1.45, 1.45)
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.pressed:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_set_fov(_fov - 2.5)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_set_fov(_fov + 2.5)
	elif event is InputEventKey and event.pressed and not event.echo:
		var key := (event as InputEventKey).keycode
		match key:
			KEY_ESCAPE:
				close()
				get_viewport().set_input_as_handled()
			KEY_F12, KEY_ENTER:
				_save_photo()
				get_viewport().set_input_as_handled()
			KEY_R:
				_reset_view()
			KEY_BRACKETLEFT:
				_set_fov(_fov - 3.0)
			KEY_BRACKETRIGHT:
				_set_fov(_fov + 3.0)


func _set_fov(value: float) -> void:
	_fov = clampf(value, MIN_FOV, MAX_FOV)
	if _fov_label != null:
		_fov_label.text = "FOV %d°" % int(round(_fov))


func _reset_view() -> void:
	_pos = _home_pos
	_yaw = _home_yaw
	_pitch = _home_pitch
	_set_fov(_home_fov)
	camera.global_position = _pos
	camera.rotation = Vector3(_pitch, _yaw, 0.0)


func _save_photo() -> void:
	if _saving:
		return
	_saving = true
	_saved.text = "保存中……"
	if _ui != null:
		_ui.visible = false
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(PHOTO_DIR))
	var stamp := Time.get_datetime_string_from_system().replace(":", "-").replace(" ", "_")
	var path := PHOTO_DIR.path_join("apex_%s.png" % stamp)
	var err := img.save_png(path)
	if _ui != null:
		_ui.visible = not _hud_hidden
	if err == OK:
		_saved.text = "已保存  %s" % ProjectSettings.globalize_path(path)
	else:
		_saved.text = "保存失败（%d）" % err
	_flash_t = 0.45
	_flash.color = Color(1.0, 1.0, 1.0, 0.35)
	_saving = false


func close() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if _chase != null and is_instance_valid(_chase):
		_chase.current = true
	closed.emit()
	queue_free()