extends Node3D
## 临时探针：车轮滚转特写连拍。相机沿轮轴从车外侧正对轮子，spin.rotation.x
## 每 45° 拍一张 —— 轮缘/轮辐若歪着转，圆圈会来回摆。
## 用法: Godot --path <abs> res://tools/car_audit/wheel_roll_shot.tscn -- \
##         --car=byd_dolphin --wheel=FL --out=/tmp/wheelchk/roll

var _car := "byd_dolphin"
var _wheel := "FL"
var _out := "/tmp/wheelchk/roll"
var _frames := 8
var _dist := 1.15
var _view := "axle"


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--car="):
			_car = arg.substr(6)
		elif arg.begins_with("--wheel="):
			_wheel = arg.substr(8)
		elif arg.begins_with("--out="):
			_out = arg.substr(6)
		elif arg.begins_with("--frames="):
			_frames = int(arg.substr(9))
		elif arg.begins_with("--dist="):
			_dist = float(arg.substr(8))
		elif arg.begins_with("--view="):
			_view = arg.substr(7)
	DirAccess.make_dir_recursive_absolute(_out)
	_build_scene()
	await _capture()
	get_tree().quit(0)


func _build_scene() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.16, 0.17, 0.19)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.57, 0.6)
	env.ambient_light_energy = 0.9
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48.0, -35.0, 0.0)
	sun.light_energy = 1.5
	sun.shadow_enabled = true
	add_child(sun)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-20.0, 140.0, 0.0)
	fill.light_energy = 0.5
	add_child(fill)

	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(40, 40)
	ground.mesh = pm
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.22, 0.22, 0.24)
	gm.roughness = 0.95
	ground.material_override = gm
	ground.position = Vector3(0, 0, 0)
	add_child(ground)

	var entry: Dictionary = GameData.car_manifest.get("cars", {}).get(_car, {})
	var built := CarVisual.build({"id": _car, "model": String(entry.get("model", ""))}, self)
	var model: Node3D = built.get("model", null)
	if model == null:
		print("[SHOT] load fail ", _car)
		return
	var spin := model.find_child("Spin_Wheel_" + _wheel, true, false) as Node3D
	if spin == null:
		print("[SHOT] no spin ", _wheel)
		return
	# 轮心（车体坐标）：用胎体 AABB 中心
	var centre := Vector3.ZERO
	var meshes := spin.find_children("*", "MeshInstance3D", true, false)
	var mn := Vector3(INF, INF, INF)
	var mx := Vector3(-INF, -INF, -INF)
	for n in meshes:
		var mi := n as MeshInstance3D
		if mi.mesh == null:
			continue
		var rel := _rel(mi, self)
		var box: AABB = rel * mi.mesh.get_aabb()
		mn = Vector3(minf(mn.x, box.position.x), minf(mn.y, box.position.y), minf(mn.z, box.position.z))
		mx = Vector3(maxf(mx.x, box.end.x), maxf(mx.y, box.end.y), maxf(mx.z, box.end.z))
	centre = (mn + mx) * 0.5
	var radius := maxf(mx.y - mn.y, mx.z - mn.z) * 0.5
	# 车外侧 = 轮心 X 的符号方向
	var outward := signf(centre.x)
	if absf(outward) < 0.5:
		outward = -1.0
	var cam := Camera3D.new()
	cam.fov = 38.0
	if _view == "quarter":
		cam.position = centre + Vector3(outward * _dist * 0.8, 0.28, _dist * 0.72)
	else:
		cam.position = centre + Vector3(outward * _dist, 0.06, 0.0)
	add_child(cam)
	cam.look_at(centre, Vector3.UP)
	cam.make_current()
	set_meta("spin", spin)
	set_meta("centre", centre)
	print("[SHOT] car=%s wheel=%s centre=%s radius=%.3f cam=%s" % [_car, _wheel, str(centre), radius, str(cam.position)])


func _capture() -> void:
	var spin: Node3D = get_meta("spin", null)
	if spin == null:
		return
	var authored := spin.rotation
	for k in _frames:
		spin.rotation.x = authored.x + TAU * float(k) / float(_frames)
		for i in 5:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		var path := "%s/%s_%s_%02d.png" % [_out, _car, _wheel, k]
		img.save_png(path)
		print("[SHOT] saved ", path)
	spin.rotation = authored


func _rel(node: Node3D, ancestor: Node) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var n: Node = node
	while n != null and n != ancestor:
		if n is Node3D:
			xf = (n as Node3D).transform * xf
		n = n.get_parent()
	return xf