class_name ConeEditor
extends Control
## 漂移练习场俯视图摆桩编辑器：光标在 1km 场地俯视图上落锥/删锥，
## 一键预设、清空、扶正；退出时由主流程保存布局。打开期间整棵树暂停（本节点 ALWAYS）。

signal closed

const CURSOR_SPEED := 160.0

var cone_field: ConeField = null
var car: Car = null
var field_half := 500.0

var cursor := Vector2.ZERO
var spacing := 12.0

var _title: Label
var _help: Label
var _count: Label
var _acc := 0.0
var _prev_buttons: Dictionary = {}


func _init() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func setup(field: ConeField, player: Car, half: float) -> void:
	cone_field = field
	car = player
	field_half = half
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	var scrim := ColorRect.new()
	scrim.color = Color(0.02, 0.04, 0.06, 0.72)
	scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(scrim)
	_title = UIStyle.label_tracked("摆桩编辑  CONE EDITOR", 22, UIStyle.GOLD, HORIZONTAL_ALIGNMENT_CENTER, 4)
	UIStyle.place(_title, 0.5, 0, 0.5, 0, -400, 26, 400, 60)
	add_child(_title)
	_count = UIStyle.label_tracked("", 13, UIStyle.TXT, HORIZONTAL_ALIGNMENT_CENTER, 2)
	UIStyle.place(_count, 0.5, 0, 0.5, 0, -400, 62, 400, 84)
	add_child(_count)
	_help = UIStyle.label_tracked(
		"鼠标：左键 落锥 · 右键 删除附近 · 1 直线 · 2 定圆 · 3 八字 · [ / ] 或滚轮 调间距 · C 清空 · R 扶正 · V / ESC 保存退出\n"
		+ "手柄：左摇杆 / 十字键 移动光标 · A 落锥 · X 删除 · Y 扶正 · LB/RB 调间距 · B / START 保存退出",
		11, UIStyle.TXT, HORIZONTAL_ALIGNMENT_CENTER, 1)
	UIStyle.place(_help, 0.5, 1, 0.5, 1, -760, -68, 760, -20)
	add_child(_help)


func _process(dt: float) -> void:
	_pad_update(dt)
	_acc += dt
	if _acc < 0.033:
		return
	_acc = 0.0
	if _count != null and cone_field != null:
		_count.text = "锥桶 %d / %d      撞倒 %d      预设间距 %.1f m" % [
			cone_field.positions.size(), ConeStore.MAX_CONES, cone_field.knocked_count(), spacing]
	queue_redraw()


func _pad_update(dt: float) -> void:
	if cone_field == null:
		return
	var v := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	if v.length_squared() > 0.0:
		cursor += v * CURSOR_SPEED * dt
		var lim := field_half - 2.0
		cursor = Vector2(clampf(cursor.x, -lim, lim), clampf(cursor.y, -lim, lim))
	var device := InputSetup.primary_joypad()
	if device < 0:
		return
	if _pad_edge(device, JOY_BUTTON_A):
		cone_field.add_cone(cursor)
	if _pad_edge(device, JOY_BUTTON_X):
		_remove_near(cursor)
	if _pad_edge(device, JOY_BUTTON_Y):
		cone_field.stand_all()
	if _pad_edge(device, JOY_BUTTON_LEFT_SHOULDER):
		_adjust_spacing(-1.0)
	if _pad_edge(device, JOY_BUTTON_RIGHT_SHOULDER):
		_adjust_spacing(1.0)
	if _pad_edge(device, JOY_BUTTON_B) or _pad_edge(device, JOY_BUTTON_START):
		closed.emit()


func _pad_edge(device: int, button: int) -> bool:
	var key := "%d:%d" % [device, button]
	var now := Input.is_joy_button_pressed(device, button)
	var was := bool(_prev_buttons.get(key, false))
	_prev_buttons[key] = now
	return now and not was


func _gui_input(event: InputEvent) -> void:
	if cone_field == null:
		return
	if event is InputEventMouseMotion:
		cursor = _screen_to_field((event as InputEventMouseMotion).position)
		accept_event()
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if not mb.pressed:
			accept_event()
			return
		var p := _screen_to_field(mb.position)
		if mb.button_index == MOUSE_BUTTON_LEFT:
			cone_field.add_cone(p)
		elif mb.button_index == MOUSE_BUTTON_RIGHT:
			_remove_near(p)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_adjust_spacing(1.0)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_adjust_spacing(-1.0)
		accept_event()


func _unhandled_input(event: InputEvent) -> void:
	if cone_field == null:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		var key := (event as InputEventKey).keycode
		match key:
			KEY_1:
				cone_field.set_layout(ConeStore.preset_slalom(spacing))
			KEY_2:
				cone_field.set_layout(ConeStore.preset_circle(spacing))
			KEY_3:
				cone_field.set_layout(ConeStore.preset_figure8(spacing))
			KEY_C:
				cone_field.set_layout([])
			KEY_R:
				cone_field.stand_all()
			KEY_BRACKETLEFT:
				_adjust_spacing(-1.0)
			KEY_BRACKETRIGHT:
				_adjust_spacing(1.0)
			KEY_V, KEY_ESCAPE, KEY_ENTER:
				closed.emit()
		get_viewport().set_input_as_handled()


func _adjust_spacing(delta: float) -> void:
	spacing = clampf(snappedf(spacing + delta, 0.5), 4.0, 40.0)


func _remove_near(p: Vector2) -> void:
	var best := -1
	var best_d := 10.0
	for i in cone_field.positions.size():
		var d: float = (cone_field.positions[i] as Vector2).distance_to(p)
		if d < best_d:
			best_d = d
			best = i
	if best >= 0:
		cone_field.remove_cone(best)


func _map_rect() -> Rect2:
	var s := minf(size.x, size.y) * 0.80
	return Rect2((size.x - s) * 0.5, (size.y - s) * 0.5 + 20.0, s, s)


func _field_to_screen(p: Vector2) -> Vector2:
	var r := _map_rect()
	return Vector2(
		r.position.x + (p.x + field_half) / (field_half * 2.0) * r.size.x,
		r.position.y + (p.y + field_half) / (field_half * 2.0) * r.size.y)


func _screen_to_field(s: Vector2) -> Vector2:
	var r := _map_rect()
	var fx := (s.x - r.position.x) / r.size.x * (field_half * 2.0) - field_half
	var fy := (s.y - r.position.y) / r.size.y * (field_half * 2.0) - field_half
	var lim := field_half - 2.0
	return Vector2(clampf(fx, -lim, lim), clampf(fy, -lim, lim))


func _draw() -> void:
	if cone_field == null:
		return
	var r := _map_rect()
	var accent := UIStyle.GOLD
	draw_rect(r, Color(0.05, 0.09, 0.12, 0.85), true)
	draw_rect(r, accent, false, 2.0)
	for g in range(1, 10):
		var t := float(g) / 10.0
		var gx := r.position.x + r.size.x * t
		var gy := r.position.y + r.size.y * t
		draw_line(Vector2(gx, r.position.y), Vector2(gx, r.end.y), Color(1, 1, 1, 0.06), 1.0)
		draw_line(Vector2(r.position.x, gy), Vector2(r.end.x, gy), Color(1, 1, 1, 0.06), 1.0)
	for i in cone_field.positions.size():
		var sp := _field_to_screen(cone_field.positions[i])
		if cone_field.knocked[i]:
			draw_circle(sp, 4.0, Color(0.45, 0.45, 0.45, 0.7))
		else:
			draw_circle(sp, 5.0, Color(0.95, 0.35, 0.06, 0.95))
			draw_arc(sp, 5.0, 0.0, TAU, 12, Color(1, 1, 1, 0.5), 1.0)
	if car != null:
		var cp := _field_to_screen(Vector2(car.pos.x, car.pos.z))
		var fwd := Vector2(sin(car.heading), cos(car.heading))
		var side := Vector2(-fwd.y, fwd.x)
		var tri := PackedVector2Array([
			cp + fwd * 14.0,
			cp - fwd * 8.0 + side * 8.0,
			cp - fwd * 8.0 - side * 8.0,
		])
		draw_colored_polygon(tri, UIStyle.ACCENT)
	var cs := _field_to_screen(cursor)
	draw_line(cs - Vector2(14, 0), cs + Vector2(14, 0), Color(1, 1, 1, 0.8), 1.5)
	draw_line(cs - Vector2(0, 14), cs + Vector2(0, 14), Color(1, 1, 1, 0.8), 1.5)
	draw_arc(cs, 9.0, 0.0, TAU, 16, Color(0.95, 0.35, 0.06, 0.9), 1.5)
