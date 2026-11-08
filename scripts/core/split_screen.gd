class_name SplitScreen
extends Control
## 本地双人左右分屏：两个 SubViewport 各渲染一套世界。
## P1 世界保留真实物理/天气/相机；P2 世界用烘焙赛道场景副本 + 车辆视觉镜像，
## 每帧同步两辆车的变换与轮子旋转；HUD 仍由 main 的 RaceHUD 全屏叠加。

const WHEELS := ["FL", "FR", "RL", "RR"]

var main_ref: Node
var p1: Car
var p2: Car
var cam1: ChaseCamera
var cam2: ChaseCamera
var track: TrackPath
var vp1: SubViewport
var vp2: SubViewport
var proxy1: Node3D
var proxy2: Node3D
var proxy_model1: Node3D
var proxy_model2: Node3D
var label1: Label
var label2: Label
var center_label: Label
var countdown_label: Label
var panel1_speed: Label
var panel1_gear: Label
var panel2_speed: Label
var panel2_gear: Label
var p1_laps := 0
var p2_laps := 0
var race_laps := 3
var race_time := 0.0
var race_state := 1
var countdown := 0.0


func setup(main_node: Node, scene_path: String, car1: Car, car2: Car,
		camera1: ChaseCamera, track_path: TrackPath) -> void:
	main_ref = main_node
	p1 = car1
	p2 = car2
	cam1 = camera1
	track = track_path
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	var hbox := HBoxContainer.new()
	hbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hbox.add_theme_constant_override("separation", 0)
	hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(hbox)
	var divider := ColorRect.new()
	divider.color = Color(0.02, 0.9, 1.0, 0.65)
	divider.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	UIStyle.place(divider, 0.5, 0, 0.5, 1, -1, 0, 1, 0)
	divider.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(divider)

	vp1 = _make_viewport()
	vp2 = _make_viewport()
	var c1 := SubViewportContainer.new()
	c1.stretch = true
	c1.custom_minimum_size = Vector2(480, 540)
	c1.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c1.size_flags_vertical = Control.SIZE_EXPAND_FILL
	c1.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c1.add_child(vp1)
	hbox.add_child(c1)
	var c2 := SubViewportContainer.new()
	c2.stretch = true
	c2.custom_minimum_size = Vector2(480, 540)
	c2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c2.size_flags_vertical = Control.SIZE_EXPAND_FILL
	c2.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c2.add_child(vp2)
	hbox.add_child(c2)

	# P1: 把真实世界、两辆真实车、天气、相机搬进 vp1
	for node in [main_ref.get("race_root"), car1, car2, camera1, main_ref.get("weather")]:
		if node == null or not is_instance_valid(node):
			continue
		var n3 := node as Node
		if n3 == null:
			continue
		var parent := n3.get_parent()
		if parent != null and parent != vp1:
			parent.remove_child(n3)
			vp1.add_child(n3)
	if camera1 != null:
		camera1.current = true

	# P2: 烘焙场景副本
	var world2 := Node3D.new()
	world2.name = "TrackWorldP2"
	vp2.add_child(world2)
	if not scene_path.is_empty() and ResourceLoader.exists(scene_path):
		var packed := load(scene_path) as PackedScene
		if packed != null:
			var copy := packed.instantiate() as Node3D
			if copy != null:
				for cam in copy.find_children("*", "Camera3D", true, false):
					cam.queue_free()
				var pivot := copy.get_node_or_null("MenuCarPivot")
				if pivot != null:
					pivot.queue_free()
				world2.add_child(copy)
	# 视觉车辆镜像
	proxy1 = _make_proxy("P1Proxy", p1)
	proxy2 = _make_proxy("P2Proxy", p2)
	proxy_model1 = proxy1.get_node_or_null("Model") as Node3D
	proxy_model2 = proxy2.get_node_or_null("Model") as Node3D

	cam2 = ChaseCamera.new()
	cam2.name = "ChaseCameraP2"
	vp2.add_child(cam2)
	cam2.follow(p2, track_path)
	cam2.current = true
	cam2.global_position = p2.global_position - p2.forward() * 6.4 + Vector3(0, 3.3, 0)

	_build_labels()
	_update_models()
	print("[SPLIT] vp1 size=", vp1.size, " cam1=", vp1.get_camera_3d(), " vp2 size=", vp2.size, " cam2=", vp2.get_camera_3d(), " world1 children=", vp1.get_child_count(), " world2=", vp2.get_child_count())


func _make_viewport() -> SubViewport:
	var vp := SubViewport.new()
	vp.size = Vector2i(800, 900)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.handle_input_locally = false
	vp.own_world_3d = true
	vp.msaa_3d = Viewport.MSAA_2X
	return vp


func _make_proxy(nodename: String, car: Car) -> Node3D:
	var root := Node3D.new()
	root.name = nodename
	vp2.add_child(root)
	if car == null:
		return root
	var result := CarVisual.build(car.spec, root)
	var model := result.get("model") as Node3D
	if model != null:
		model.name = "Model"
	# 复制车库外观
	if GameData != null and Garage != null:
		GarageLook.apply(model, String(car.spec.get("id", "")), Garage.config(String(car.spec.get("id", ""))))
	return root


func _build_labels() -> void:
	var overlay := Control.new()
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(overlay)
	center_label = UIStyle.label("LAP 1/3   00:00.0", 18, Color(0.95, 0.97, 1.0, 1.0), HORIZONTAL_ALIGNMENT_CENTER)
	UIStyle.place(center_label, 0, 0, 1, 0, 0, 6, 0, 42)
	center_label.add_theme_constant_override("outline_size", 6)
	center_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	overlay.add_child(center_label)

	countdown_label = UIStyle.label("", 72, Color(1.0, 0.85, 0.4, 1.0), HORIZONTAL_ALIGNMENT_CENTER)
	UIStyle.place(countdown_label, 0, 0.5, 1, 0.5, 0, -110, 0, 30)
	countdown_label.add_theme_constant_override("outline_size", 12)
	countdown_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	overlay.add_child(countdown_label)

	var bar1 := PanelContainer.new()
	bar1.add_theme_stylebox_override("panel", UIStyle.chip_style(Color(0.3, 0.9, 1.0, 1.0), false, false))
	UIStyle.place(bar1, 0, 1, 0, 1, 20, -132, 430, -70)
	bar1.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_child(bar1)
	var col1 := VBoxContainer.new()
	col1.add_theme_constant_override("separation", -2)
	bar1.add_child(col1)
	panel1_speed = UIStyle.label("P1  0 KM/H", 30, Color(0.35, 0.95, 1.0, 1.0))
	col1.add_child(panel1_speed)
	panel1_gear = UIStyle.label("L0/3   A  ·  V8", 12, UIStyle.TXT_DIM)
	col1.add_child(panel1_gear)

	var bar2 := PanelContainer.new()
	bar2.add_theme_stylebox_override("panel", UIStyle.chip_style(Color(1.0, 0.55, 0.25, 1.0), false, false))
	UIStyle.place(bar2, 1, 1, 1, 1, -430, -132, -20, -70)
	bar2.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_child(bar2)
	var col2 := VBoxContainer.new()
	col2.add_theme_constant_override("separation", -2)
	bar2.add_child(col2)
	panel2_speed = UIStyle.label("P2  0 KM/H", 30, Color(1.0, 0.6, 0.3, 1.0), HORIZONTAL_ALIGNMENT_RIGHT)
	col2.add_child(panel2_speed)
	panel2_gear = UIStyle.label("L0/3   A  ·  V8", 12, UIStyle.TXT_DIM, HORIZONTAL_ALIGNMENT_RIGHT)
	col2.add_child(panel2_gear)


func set_race_info(laps_now: int, laps_total: int, t: float, state: int, countdown_now: float) -> void:
	race_laps = maxi(1, laps_total)
	race_time = t
	race_state = state
	countdown = countdown_now


func update_visuals() -> void:
	_update_models()
	if cam2 != null and is_instance_valid(cam2):
		cam2.follow_update(1.0 / 60.0)
	if center_label != null:
		center_label.text = "P1 L%d     P2 L%d     %s" % [p1_laps, p2_laps, _format_time(race_time)]
	if countdown_label != null:
		if race_state == 0 and countdown > 0.0:
			countdown_label.visible = true
			countdown_label.text = str(int(ceil(countdown)))
		elif race_state == 1 and race_time < 0.9:
			countdown_label.visible = true
			countdown_label.text = "GO!"
		else:
			countdown_label.visible = false
	if panel1_speed != null and p1 != null:
		panel1_speed.text = "P1  %d KM/H" % int(round(p1.speed_kph))
		panel1_gear.text = "L%d/%d   %s  ·  %s" % [p1_laps, race_laps, p1.gear_label(), p1.engine_profile.to_upper()]
	if panel2_speed != null and p2 != null:
		panel2_speed.text = "P2  %d KM/H" % int(round(p2.speed_kph))
		panel2_gear.text = "L%d/%d   %s  ·  %s" % [p2_laps, race_laps, p2.gear_label(), p2.engine_profile.to_upper()]


func _format_time(t: float) -> String:
	var m := int(t) / 60
	var s := fmod(t, 60.0)
	return "%02d:%04.1f" % [m, s]


func set_duel_laps(l1: int, l2: int) -> void:
	p1_laps = l1
	p2_laps = l2


func _update_models() -> void:
	if proxy1 != null and p1 != null:
		proxy1.global_transform = p1.global_transform
	if proxy2 != null and p2 != null:
		proxy2.global_transform = p2.global_transform
	_sync_wheels(proxy_model1, p1)
	_sync_wheels(proxy_model2, p2)


func _sync_wheels(proxy: Node3D, car: Car) -> void:
	if proxy == null or car == null:
		return
	for suffix in WHEELS:
		var a := proxy.find_child("Spin_Wheel_" + suffix, true, false) as Node3D
		if a == null:
			continue
		var b := car.find_child("Spin_Wheel_" + suffix, true, false) as Node3D
		if b != null:
			a.rotation.x = b.rotation.x
		var sa := proxy.find_child("Wheel_" + suffix, true, false) as Node3D
		var sb := car.find_child("Wheel_" + suffix, true, false) as Node3D
		if sa != null and sb != null and suffix.begins_with("F"):
			sa.rotation.y = sb.rotation.y
