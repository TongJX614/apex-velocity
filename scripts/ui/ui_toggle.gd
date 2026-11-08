class_name UIToggle
extends Control
## 商业赛车游戏风格的开关 v2：胶囊轨道 + 滑动旋钮 + 主题色辉光。
## 支持鼠标点击 / 键盘空格・回车 / 焦点描边，0.16s 动画。

signal toggled(on: bool)

var is_on := false
var accent := UIStyle.ACCENT
var _anim := 0.0
var _hover := false
var _focus := false
var _track_off: StyleBoxFlat
var _track_on: StyleBoxFlat
var _knob_glow: ImageTexture


func _ready() -> void:
	custom_minimum_size = Vector2(64, 30)
	size = custom_minimum_size
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	focus_mode = Control.FOCUS_ALL
	_anim = 1.0 if is_on else 0.0
	_track_off = StyleBoxFlat.new()
	_track_off.bg_color = Color(0.070, 0.092, 0.116, 0.95)
	_track_off.border_color = Color(0.36, 0.45, 0.53, 0.55)
	_track_off.set_border_width_all(1)
	_track_off.set_corner_radius_all(UIStyle.R_PILL)
	_track_on = StyleBoxFlat.new()
	_track_on.bg_color = Color(accent.r, accent.g, accent.b, 0.26)
	_track_on.border_color = Color(accent.r, accent.g, accent.b, 0.95)
	_track_on.set_border_width_all(1)
	_track_on.set_corner_radius_all(UIStyle.R_PILL)
	_track_on.shadow_color = Color(accent.r, accent.g, accent.b, 0.30)
	_track_on.shadow_size = 10
	_knob_glow = UIStyle.glow_texture(accent, 2.2)
	mouse_entered.connect(func() -> void:
		_hover = true
		queue_redraw())
	mouse_exited.connect(func() -> void:
		_hover = false
		queue_redraw())
	focus_entered.connect(func() -> void:
		_focus = true
		queue_redraw())
	focus_exited.connect(func() -> void:
		_focus = false
		queue_redraw())
	gui_input.connect(_on_gui_input)


func set_accent(value: Color) -> void:
	accent = value
	_track_on.border_color = Color(accent.r, accent.g, accent.b, 0.95)
	_track_on.shadow_color = Color(accent.r, accent.g, accent.b, 0.30)
	_knob_glow = UIStyle.glow_texture(accent, 2.2)
	queue_redraw()


func set_on(value: bool, emit_signal_: bool = false) -> void:
	var target := 1.0 if value else 0.0
	if is_on == value:
		if emit_signal_:
			toggled.emit(value)
		return
	is_on = value
	if is_inside_tree():
		var tw := create_tween()
		tw.tween_method(_apply_anim, _anim, target, 0.16).set_trans(Tween.TRANS_CUBIC) \
			.set_ease(Tween.EASE_OUT)
	if emit_signal_:
		toggled.emit(value)
	queue_redraw()


func _apply_anim(value: float) -> void:
	_anim = value
	queue_redraw()


func _on_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		set_on(not is_on, true)
		accept_event()
	elif event is InputEventKey and event.pressed and not event.echo:
		var key := (event as InputEventKey).keycode
		if key == KEY_SPACE or key == KEY_ENTER or key == KEY_KP_ENTER:
			set_on(not is_on, true)
			accept_event()
	elif event.is_action_pressed("ui_accept"):
		# 手柄 A / 键盘回车：切换
		set_on(not is_on, true)
		accept_event()
	elif event.is_action_pressed("ui_left"):
		set_on(false, true)
		accept_event()
	elif event.is_action_pressed("ui_right"):
		set_on(true, true)
		accept_event()


func _draw() -> void:
	var h := size.y
	var w := size.x
	var radius := h * 0.5
	var off_rect := Rect2(0.0, 0.0, w, h)
	if _anim < 0.999:
		draw_style_box(_track_off, off_rect)
	if _anim > 0.001:
		_track_on.bg_color = Color(accent.r, accent.g, accent.b, 0.26 * _anim)
		_track_on.border_color = Color(accent.r, accent.g, accent.b, 0.95 * _anim)
		draw_style_box(_track_on, off_rect)
	# 轨道内刻度
	for i in 3:
		var x := radius + (w - radius * 2.0) * (0.25 + float(i) * 0.25)
		draw_line(Vector2(x, h * 0.5 - 2.5), Vector2(x, h * 0.5 + 2.5),
			Color(1, 1, 1, 0.10 + 0.10 * _anim), 1.0)
	# 旋钮
	var kr := radius - 5.0
	var knob := Vector2(radius + (w - radius * 2.0) * _anim, h * 0.5)
	if _anim > 0.01:
		draw_texture_rect(_knob_glow, Rect2(knob - Vector2(kr + 12.0, kr + 12.0),
			Vector2((kr + 12.0) * 2.0, (kr + 12.0) * 2.0)), false,
			Color(1, 1, 1, 0.35 * _anim))
	# 旋钮阴影 + 本体
	draw_circle(knob + Vector2(0.0, 1.2), kr, Color(0, 0, 0, 0.35))
	draw_circle(knob, kr, Color(0.94, 0.97, 1.0, 1.0))
	draw_circle(knob, kr - 2.0, Color(0.62, 0.71, 0.79, 1.0) if not is_on else accent)
	if is_on:
		draw_circle(knob, kr - 5.2, Color(1, 1, 1, 0.92))
	if _hover or _focus:
		var ring := Color(accent.r, accent.g, accent.b, 0.60 if _focus else 0.28)
		draw_arc(Vector2(w * 0.5, h * 0.5), radius + 3.0, 0.0, TAU, 40, ring, 1.5, true)
