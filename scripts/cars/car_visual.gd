class_name CarVisual
extends RefCounted
## Shared GLB car rig used by both the player Car and the AICar rivals.
## Loads the legacy car model, finds the authored wheel nodes, optionally
## repaints the carpaint material and adds the cheap contact shadow.

const MODELS_DIR := "res://assets/cars/models"

# 车窗玻璃观感（用户要求：半透、别发白）
const GLASS_TINT := Color(0.045, 0.055, 0.065)
const GLASS_ALPHA := 0.17
const GLASS_ROUGHNESS := 0.13
const GLASS_SPECULAR := 0.16


static func build(spec: Dictionary, parent: Node3D, paint: Color = Color.TRANSPARENT) -> Dictionary:
	var result := {
		"model": null,
		"spin_wheels": [] as Array[Node3D],
		"steer_wheels": [] as Array[Node3D],
		"wheel_radius": 0.34,
		"wheels_found": 0,
	}
	var car_id := String(spec.get("id", ""))
	var model_file := String(spec.get("model", ""))
	if model_file.is_empty():
		model_file = car_id + ".glb"
	var res_path := MODELS_DIR.path_join(model_file)
	var packed: PackedScene = null
	if ResourceLoader.exists(res_path):
		packed = load(res_path) as PackedScene
	if packed == null:
		push_error("CarVisual: cannot load %s" % res_path)
		result["model"] = _build_fallback(parent)
		_build_blob_shadow(parent)
		return result
	var model := packed.instantiate() as Node3D
	if model == null:
		push_error("CarVisual: %s is not a Node3D scene" % res_path)
		result["model"] = _build_fallback(parent)
		_build_blob_shadow(parent)
		return result
	model.name = "Model"
	parent.add_child(model)
	result["model"] = model
	result["wheel_radius"] = wheel_radius_for(car_id)

	var spins: Array[Node3D] = []
	var steers: Array[Node3D] = []
	for suffix in ["FL", "FR", "RL", "RR"]:
		var spin := model.find_child("Spin_Wheel_" + suffix, true, false)
		if spin is Node3D:
			spins.append(spin as Node3D)
		if suffix.begins_with("F"):
			var steer := model.find_child("Wheel_" + suffix, true, false)
			if steer is Node3D:
				steers.append(steer as Node3D)
	result["spin_wheels"] = spins
	result["steer_wheels"] = steers
	result["wheels_found"] = spins.size()

	_fix_white_materials(model)
	_prepare_car_materials(model)
	_center_spin_wheels(spins)
	_apply_lod_bias(model)

	if paint.a > 0.001:
		apply_paint(model, paint)
	elif paint.a <= 0.001 and paint.b <= 0.001 and paint.g <= 0.001 and paint.r <= 0.001:
		pass
	_build_blob_shadow(parent)
	return result


## 低画质档 AI 车不参与实时阴影绘制（保留贴地的接触阴影），
## 省掉整车网格再进一遍阴影 pass；玩家车与高档位不受影响。
static func set_shadow_casting(root: Node3D, enabled: bool) -> void:
	if root == null:
		return
	var mode := GeometryInstance3D.SHADOW_CASTING_SETTING_ON if enabled \
		else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for node in root.find_children("*", "GeometryInstance3D", true, false):
		if String(node.name) == "BlobShadow":
			continue
		(node as GeometryInstance3D).cast_shadow = mode


static func wheel_radius_for(car_id: String) -> float:
	if GameData == null:
		return 0.34
	var cars_doc: Dictionary = GameData.car_manifest.get("cars", {})
	var entry: Dictionary = cars_doc.get(car_id, {})
	return float(entry.get("wheelRadius", 0.34))


## 按当前画质档给车模全部网格写 LOD 偏移：低档远车更早切低模，
## 超高档满精度留到更远。换档时由 main._apply_lod_bias_all() 全场同步。
static func _apply_lod_bias(root: Node3D) -> void:
	var bias := 1.0
	var loop := Engine.get_main_loop()
	if loop is SceneTree:
		var st := loop as SceneTree
		if st.root != null and st.root.has_node("Settings"):
			var settings: Node = st.root.get_node("Settings")
			if settings != null and settings.has_method("lod_bias"):
				bias = float(settings.call("lod_bias"))
	if root is GeometryInstance3D:
		(root as GeometryInstance3D).lod_bias = bias
	for node in root.find_children("*", "GeometryInstance3D", true, false):
		(node as GeometryInstance3D).lod_bias = bias


## 按这台车自己的轮胎网格实测轮径与胎宽（改装件按此生成，不做统一尺寸直插）。
## radius 兜底用 manifest 的 wheelRadius；width 从轮胎网格包围盒 X 轴（轮轴方向）量出。
static func wheel_dims(spin: Node3D, fallback_radius: float) -> Dictionary:
	var radius := maxf(fallback_radius, 0.20)
	var width := radius * 0.72
	if spin != null and is_instance_valid(spin):
		var box := _tyre_subtree_aabb(spin)
		if box.size.y > 0.02 and box.size.z > 0.02:
			radius = maxf(box.size.y, box.size.z) * 0.5
		if box.size.x > 0.04:
			width = box.size.x
	return {
		"radius": radius,
		"width": clampf(width, radius * 0.52, radius * 1.15),
	}


## 这台车的外观数据（车宽/车长/车顶高），供尾翼等大件按车尺寸挂载。
static func car_dims(car_id: String) -> Dictionary:
	var out := {"width": 1.85, "length": 4.45, "roof_y": 1.30}
	if GameData == null:
		return out
	var cars_doc: Dictionary = GameData.car_manifest.get("cars", {})
	var entry: Dictionary = cars_doc.get(car_id, {})
	var contact: Array = entry.get("contact", [])
	if contact.size() >= 2 and float(contact[0]) > 0.5:
		out["width"] = float(contact[0])
		out["length"] = float(contact[1])
	var cockpit: Dictionary = entry.get("cockpit", {})
	if cockpit.has("roofY") and float(cockpit.get("roofY", 0.0)) > 0.5:
		out["roof_y"] = float(cockpit.get("roofY"))
	return out


## 车模整体包围盒（改装件按实际模型定位用，例如尾翼落在行李箱盖上）。
static func model_aabb(model: Node3D) -> AABB:
	return _subtree_aabb(model)


static func cockpit_offset_for(car_id: String) -> Vector3:
	if GameData == null:
		return Vector3(0.0, 1.05, -0.1)
	var cars_doc: Dictionary = GameData.car_manifest.get("cars", {})
	var entry: Dictionary = cars_doc.get(car_id, {})
	var cockpit: Dictionary = entry.get("cockpit", {})
	return Vector3(
		float(cockpit.get("x", 0.0)),
		float(cockpit.get("y", 1.05)),
		float(cockpit.get("z", -0.1))
	)


static func apply_paint(root: Node, color: Color, matte: bool = false, authored_fallback: Color = Color.TRANSPARENT) -> void:
	## color.a <= 0 表示「原厂漆」：保留 Blender 原件里的车漆贴图/拉花/清漆，
	## 只把清漆/金属度调成游戏灯光下好看的值。否则按配置颜色覆盖（丢拉花换纯色）。
	## authored_fallback：原厂漆材质若没有贴图（少数车/旧模型），用调色板里的原厂色兜底。
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		var mesh := mi.mesh
		if mesh == null:
			continue
		for s in mesh.get_surface_count():
			var mat := mi.get_active_material(s)
			if not (mat is StandardMaterial3D):
				continue
			var src := mat as StandardMaterial3D
			var mat_name := src.resource_name.to_lower()
			if not (mat_name.contains("carpaint") or mat_name.contains("paint") or mat_name.contains("车漆") or mat_name.contains("coloured")):
				continue
			var dup := src.duplicate() as StandardMaterial3D
			if color.a > 0.001:
				# 换色：去掉原作者贴图（避免蓝漆×新色发黑），换纯色车漆
				dup.albedo_texture = null
				dup.albedo_color = color
				dup.metallic = 0.35 if not matte else 0.15
				dup.roughness = 0.18 if not matte else 0.62
			else:
				# 原厂漆：贴图/拉花/PBR 全部保留，仅统一到游戏光下的表现
				if dup.albedo_texture == null and authored_fallback.a > 0.001:
					dup.albedo_color = authored_fallback
				dup.metallic = clampf(dup.metallic, 0.0, 0.45)
				dup.roughness = clampf(dup.roughness, 0.10, 0.35)
			if dup.get("clearcoat_enabled") != null:
				var cc := not matte
				dup.set("clearcoat_enabled", cc)
				dup.set("clearcoat", 1.0 if cc else 0.0)
				dup.set("clearcoat_roughness", 0.03)
			mi.set_surface_override_material(s, dup)


static func _fix_white_materials(root: Node) -> void:
	## 只兜底「真正的空材质」：新版 GLB 保留了原件 PBR，不再按纯白盲改
	## （旧网页版 GLB 才有大量无贴图白膜，这里的规则对新车模几乎不触发）。
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			continue
		for s in mi.mesh.get_surface_count():
			var mat := mi.get_active_material(s) as StandardMaterial3D
			if mat == null:
				mi.set_surface_override_material(s, _material_fallback(""))
				continue
			var mat_name := String(mat.resource_name).to_lower()
			# 有贴图 / 有名字的材质一律不动；只有「无贴图 + 纯白 + 无名」才兜底
			if mat.albedo_texture != null:
				continue
			if mat_name.contains("paint") or mat_name.contains("carpaint") or mat_name.contains("车漆"):
				continue
			if mat_name.contains("glass") or mat_name.contains("glazing") or mat_name.contains("window") or mat_name.contains("灯"):
				continue
			var c := mat.albedo_color
			if c.r > 0.92 and c.g > 0.92 and c.b > 0.92 and mat_name.is_empty():
				mi.set_surface_override_material(s, _material_fallback(mat_name))


static func _prepare_car_materials(root: Node) -> void:
	## 新导出的车模：玻璃用 alpha 混合，关掉玻璃投影（否则车内一片死黑）；
	## 其余材质清掉意外的 alpha，保证走不透明管线（性能/排序）。
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			continue
		var all_transparent := true
		var any_surface := false
		for s in mi.mesh.get_surface_count():
			any_surface = true
			var mat := mi.get_active_material(s) as StandardMaterial3D
			if mat == null:
				all_transparent = false
				continue
			var mat_name := String(mat.resource_name).to_lower()
			# 个别源模型（比亚迪海豹/海豹06GT/海狮）的轮胎贴图是「白底胎纹」，
			# 直接渲染成白轮胎；这里把轮胎底色乘暗成正常橡胶色。
			if (mat_name.contains("tyre") or mat_name.contains("tire") or mat_name.contains("轮胎")) and mat.albedo_texture != null:
				if mat.albedo_color.r > 0.75 and mat.albedo_color.g > 0.75 and mat.albedo_color.b > 0.75:
					var tire_dup := mat.duplicate() as StandardMaterial3D
					tire_dup.albedo_color = Color(0.045, 0.047, 0.052, 1.0)
					mi.set_surface_override_material(s, tire_dup)
					mat = tire_dup
			var is_glass := mat_name.contains("glass") or mat_name.contains("glazing") or mat_name.contains("window") or mat_name.contains("挡风") or mat_name.contains("玻璃")
			if is_glass or mat.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
				var dup := mat.duplicate() as StandardMaterial3D
				dup.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
				dup.metallic = 0.0
				dup.roughness = GLASS_ROUGHNESS
				dup.cull_mode = BaseMaterial3D.CULL_DISABLED
				# 深色玻璃：底色压暗 + 低镜面，避免大面积白色反光糊在车窗上
				dup.albedo_color = Color(GLASS_TINT.r, GLASS_TINT.g, GLASS_TINT.b, GLASS_ALPHA)
				if dup.get("metallic_specular") != null:
					dup.set("metallic_specular", GLASS_SPECULAR)
				mi.set_surface_override_material(s, dup)
			else:
				all_transparent = false
		if any_surface and all_transparent:
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


static func _material_fallback(name: String) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.resource_name = name
	var is_glass := name.contains("glass") or name.contains("glazing") or name.contains("window") or name.contains("挡风") or name.contains("玻璃")
	var is_light := name.contains("light") or name.contains("deng") or name.contains("灯") or name.contains("glow") or name.contains("emis")
	var is_tire := name.contains("tyre") or name.contains("tire") or name.contains("轮胎")
	var is_rim := name.contains("rim") or name.contains("spoke") or name.contains("wheel") or name.contains("轮毂")
	var is_brake := name.contains("brake") or name.contains("disc") or name.contains("卡钳")
	var is_caliper := name.contains("caliper")
	var is_interior := name.contains("interior") or name.contains("车内") or name.contains("内饰") or name.contains("neishi") or name.contains("nappa") or name.contains("座") or name.contains("steer")
	var is_chrome := name.contains("chrome") or name.contains("chorme") or name.contains("镀铬") or name.contains("mirror") or name.contains("fanguang") or name.contains("反光")
	var is_plastic := name.contains("plastic") or name.contains("black") or name.contains("塑料") or name.contains("gaolianghei") or name.contains("moshahei") or name.contains("rubber") or name.contains("胶")
	if is_glass:
		mat.albedo_color = Color(0.045, 0.06, 0.08, 0.58)
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.roughness = 0.06
		mat.metallic = 0.0
		if is_light:
			mat.albedo_color = Color(0.75, 0.82, 0.9, 0.75)
			mat.emission_enabled = true
			mat.emission = Color(0.7, 0.8, 1.0)
			mat.emission_energy_multiplier = 0.35
	elif is_light:
		mat.albedo_color = Color(0.92, 0.94, 0.9)
		mat.emission_enabled = true
		mat.emission = Color(1.0, 0.9, 0.72)
		mat.emission_energy_multiplier = 0.5
		mat.roughness = 0.18
	elif is_tire:
		mat.albedo_color = Color(0.02, 0.021, 0.024)
		mat.roughness = 0.92
	elif is_rim:
		mat.albedo_color = Color(0.58, 0.60, 0.63)
		mat.metallic = 0.9
		mat.roughness = 0.22
	elif is_caliper:
		mat.albedo_color = Color(0.55, 0.12, 0.10)
		mat.metallic = 0.35
		mat.roughness = 0.35
	elif is_brake:
		mat.albedo_color = Color(0.30, 0.31, 0.33)
		mat.metallic = 0.85
		mat.roughness = 0.4
	elif is_interior:
		mat.albedo_color = Color(0.065, 0.07, 0.08)
		mat.roughness = 0.82
	elif is_chrome:
		mat.albedo_color = Color(0.82, 0.84, 0.88)
		mat.metallic = 1.0
		mat.roughness = 0.10
	elif is_plastic:
		mat.albedo_color = Color(0.045, 0.05, 0.055)
		mat.roughness = 0.62
	else:
		mat.albedo_color = Color(0.16, 0.17, 0.19)
		mat.metallic = 0.2
		mat.roughness = 0.6
	return mat


static func _relative_to(node: Node, ancestor: Node) -> Transform3D:
	var rel := Transform3D.IDENTITY
	var cur: Node = node
	while cur != null and cur != ancestor:
		if cur is Node3D:
			rel = (cur as Node3D).transform * rel
		cur = cur.get_parent()
	return rel


static func _subtree_aabb(node: Node3D) -> AABB:
	var box := AABB()
	var first := true
	for child in node.find_children("*", "MeshInstance3D", true, false):
		var mi := child as MeshInstance3D
		if mi.mesh == null:
			continue
		var rel := _relative_to(mi, node)
		var aabb: AABB = rel * mi.mesh.get_aabb()
		if first:
			box = aabb
			first = false
		else:
			box = box.merge(aabb)
	return box


static func _tyre_subtree_aabb(spin: Node3D) -> AABB:
	var box := AABB()
	var first := true
	for node in spin.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			continue
		var nm := String(mi.name).to_lower()
		if not (nm.contains("tyre") or nm.contains("tire") or nm.contains("轮胎")):
			continue
		var rel := _relative_to(mi, spin)
		var aabb: AABB = rel * mi.mesh.get_aabb()
		if first:
			box = aabb
			first = false
		else:
			box = box.merge(aabb)
	return box


static func _wrap_children(spin: Node3D, wrapper: Node3D) -> void:
	## 把 spin 现有子节点整体挪到 wrapper 下，再把 wrapper 挂回 spin
	var kids := spin.get_children()
	for k in kids:
		if k is Node3D:
			(k as Node3D).owner = null
		spin.remove_child(k)
		wrapper.add_child(k)
	spin.add_child(wrapper)


static func _center_spin_wheels(spins: Array[Node3D]) -> void:
	for spin in spins:
		if spin == null:
			continue
		var box := _subtree_aabb(spin)
		if box.size.length() <= 0.001:
			continue
		var center := box.get_center()
		# 把滚转枢轴挪到轮子几何中心：枢轴 +C、子节点 -C → 几何在世界里保持不动，
		# 但旋转中心变成轮心（否则偏心轮会上下跳/画椭圆）。原实现只挪枢轴、不补偿
		# 子节点，会把轮子整体平移出去，这里修正。
		if center.length() > 0.008:
			spin.position += center
			for k in spin.get_children():
				if k is Node3D:
					(k as Node3D).position -= center
		# 个别模型轮胎 Y/Z 被压扁成椭圆：绕轮心单轴缩放修正成正圆。
		# 判定用「轮胎网格」的包围盒（轮毂徽标/机械件会把整组 AABB 拉歪，不能拿来判椭圆）。
		var tyre_box := _tyre_subtree_aabb(spin)
		if tyre_box.size.y > 0.01 and tyre_box.size.z > 0.01:
			box = tyre_box
		if box.size.y > 0.01 and box.size.z > 0.01:
			var ratio := box.size.y / box.size.z
			if absf(ratio - 1.0) > 0.045:
				var target := maxf(box.size.y, box.size.z)
				var wrap := Node3D.new()
				wrap.name = "WheelRoundFix"
				wrap.scale = Vector3(1.0, target / box.size.y, target / box.size.z)
				_wrap_children(spin, wrap)
		spin.set_meta("wheel_fixed", true)


static func _build_fallback(parent: Node3D) -> Node3D:
	var body := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(1.9, 1.2, 4.4)
	body.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.12, 0.35, 0.7)
	body.material_override = mat
	body.position = Vector3(0.0, 0.6, 0.0)
	body.name = "Model"
	parent.add_child(body)
	return body


static func _build_blob_shadow(parent: Node3D) -> void:
	# Cheap contact shadow: real-time directional shadows still need a graphics
	# pass, this keeps every car visually planted in the meantime.
	var quad := QuadMesh.new()
	quad.size = Vector2(3.0, 4.8)
	var mi := MeshInstance3D.new()
	mi.name = "BlobShadow"
	mi.mesh = quad
	mi.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	mi.position = Vector3(0.0, 0.045, 0.0)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	var gradient := Gradient.new()
	gradient.set_color(0, Color(0.0, 0.0, 0.0, 0.34))
	gradient.set_color(1, Color(0.0, 0.0, 0.0, 0.0))
	gradient.add_point(0.55, Color(0.0, 0.0, 0.0, 0.16))
	var tex := GradientTexture2D.new()
	tex.gradient = gradient
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	tex.width = 128
	tex.height = 128

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_texture = tex
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_OPAQUE_ONLY
	mi.material_override = mat
	parent.add_child(mi)
