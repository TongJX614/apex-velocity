class_name CarVisual
extends RefCounted
## Shared GLB car rig used by both the player Car and the AICar rivals.
## Loads the legacy car model, finds the authored wheel nodes, optionally
## repaints the carpaint material and adds the cheap contact shadow.

const MODELS_DIR := "res://cars/assets/models"
const LOD_MODELS_DIR := "res://cars/assets/models_lod"
# 轮胎 Y/Z 椭圆容差：超过即绕轮心单轴缩放修正成正圆（2% 覆盖轻度压扁的胎体）。
const TYRE_ELLIPSE_TOL := 0.02
# 胎体滚转轴（PCA 最薄轴）与 X 夹角超过此值才旋转转正，避免误伤装配正常的车。
const TYRE_REALIGN_DEG := 6.0
# 转正/正圆后仍无法消除的滚动半径变化（%）超过此值，说明胎体网格本身是
# 不一致的椭圆环（如 m4_adro_kit 后轮两个朝向相差 90° 的子网格），仿射变换
# 修不好 → 用标准圆环重建胎体（保留轮毂）。
const TYRE_REBUILD_VAR := 3.0
# 滚动轮心漂移（m）超过此值也重建（歪斜子网格/偏心细节导致滚转时轮心跳动）。
const TYRE_REBUILD_DRIFT := 0.008

# 阴影 pass 优化：这些网格被车身/玻璃包住，投影贡献几乎为零，
# 但每个网格都要完整跑一遍阴影渲染。按节点名识别后直接关掉投影。
const SHADOWLESS_KEYWORDS := [
	"interior", "engine", "glass", "window", "windshield", "windscreen",
	"underbody", "cabin",
]
# AI 车 90m 外剔除的细节件：车内、引擎、卡钳、小标牌等。
const FAR_DETAIL_KEYWORDS := [
	"interior", "engine", "underbody", "cabin", "caliper", "disc", "rotor",
	"badge", "emblem", "logo", "wiper", "seat", "dashboard", "steering",
]
const AI_DETAIL_RANGE := 90.0

# 夜间车灯：两盏前照灯 + 灯珠自发光。光轴压向路面，保证车头前 3~40m
# 形成连续光斑，而不是只把远处雾照亮。
const HEADLIGHT_COLOR := Color(1.0, 0.94, 0.82)
const HEADLIGHT_RANGE := 72.0
const HEADLIGHT_ANGLE := 24.0
const HEADLIGHT_ENERGY := 85.0
const HEADLIGHT_LATERAL := 0.62

# 刹车尾灯：直接点亮车模「自己的」后尾灯，保留每台灯的原厂形状（一条上拐的
# 灯带、一个圆点……），不再外加通用灯条。实体红玻璃灯罩用红色自发光增强，
# 贴图灯罩用红色 texel 遮罩 next_pass；两者都只在几何位于车尾的灯面上生效。
# 尾灯烘死在车身贴图里、无法分离的车型（CSL/Sylphy）不做任何假灯。
const TAIL_RUNNING_STRENGTH := 0.55
const TAIL_BRAKE_STRENGTH := 2.1
const TAIL_BRAKE_EMISSION := 3.2
const TAIL_BRAKE_COLOR := Color(1.0, 0.06, 0.04)

# 车窗玻璃观感（用户要求：半透、别发白）
const GLASS_TINT := Color(0.045, 0.055, 0.065)
const GLASS_ALPHA := 0.17
const GLASS_ROUGHNESS := 0.13
const GLASS_SPECULAR := 0.16


static func build(spec: Dictionary, parent: Node3D, paint: Color = Color.TRANSPARENT,
		ai_low: bool = false) -> Dictionary:
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
	# AI 对手优先用低模（删内饰/引擎 + 减面）；没有低模的车型自动回落满模。
	if ai_low:
		var lod_path := LOD_MODELS_DIR.path_join(model_file)
		if ResourceLoader.exists(lod_path):
			res_path = lod_path
	var packed: PackedScene = null
	if ResourceLoader.exists(res_path):
		packed = load(res_path) as PackedScene
	# 低模缺失/损坏时回落到满模，绝不让对手变成占位盒。
	if packed == null and ai_low:
		var full_path := MODELS_DIR.path_join(model_file)
		if ResourceLoader.exists(full_path):
			packed = load(full_path) as PackedScene
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

	_fix_reversed_steers(model, steers)
	_fix_white_materials(model)
	_prepare_car_materials(model)
	setup_brake_lights(model, spec)
	_center_spin_wheels(spins, float(result["wheel_radius"]))
	_apply_lod_bias(model)

	if paint.a > 0.001:
		apply_paint(model, paint)
	elif paint.a <= 0.001 and paint.b <= 0.001 and paint.g <= 0.001 and paint.r <= 0.001:
		pass
	set_render_layer(model, RENDER_LAYER_CAR)
	_build_blob_shadow(parent)
	return result


## 低画质档 AI 车不参与实时阴影绘制（保留贴地的接触阴影），
## 省掉整车网格再进一遍阴影 pass；玩家车与高档位不受影响。
## 车体统一放到视觉层 2：主相机默认全层可见，反射探针 cull_mask=1 就能只拍
## 环境、不把车自己拍进漆面（否则车漆会反射自己的车身/内饰）。
const RENDER_LAYER_CAR := 2


static func set_render_layer(root: Node, layer: int) -> void:
	if root == null:
		return
	if root is GeometryInstance3D:
		(root as GeometryInstance3D).layers = layer
	for node in root.find_children("*", "GeometryInstance3D", true, false):
		(node as GeometryInstance3D).layers = layer


static func set_shadow_casting(root: Node3D, enabled: bool) -> void:
	if root == null:
		return
	var mode := GeometryInstance3D.SHADOW_CASTING_SETTING_ON if enabled \
		else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for node in root.find_children("*", "GeometryInstance3D", true, false):
		if String(node.name) == "BlobShadow":
			continue
		var gi := node as GeometryInstance3D
		# 车内/引擎/玻璃无论画质档都不参与阴影，换档时也不能被重新打开。
		if enabled and _matches_keywords(node, SHADOWLESS_KEYWORDS):
			gi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		else:
			gi.cast_shadow = mode


static func _matches_keywords(node: Node, keywords: Array) -> bool:
	var n := String(node.name).to_lower()
	for k in keywords:
		if n.contains(String(k)):
			return true
	return false


## 赛道内车模优化：车内/引擎/玻璃不投影；AI 车远离相机后剔除隐藏细节件。
## 车库/菜单走的是 CarVisual.build，不调用这里，展车保持满精度。
static func apply_race_optimizations(root: Node3D, is_ai: bool) -> void:
	if root == null:
		return
	for node in root.find_children("*", "GeometryInstance3D", true, false):
		if String(node.name) == "BlobShadow":
			continue
		var gi := node as GeometryInstance3D
		if _matches_keywords(node, SHADOWLESS_KEYWORDS):
			gi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if is_ai and _matches_keywords(node, FAR_DETAIL_KEYWORDS):
			gi.visibility_range_end = AI_DETAIL_RANGE
			gi.visibility_range_end_margin = 10.0


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


## 夜间车灯：玩家车与 AI 车共用。灯位/朝向取自车辆 manifest 的 lights 段，
## 两盏 SpotLight3D 压在路面上照明，另配两颗高亮灯珠让车头在远处也看得出「灯亮着」。
## energy_scale 由赛道主题的 headlightIntensity 换算，同一套灯在不同夜色里亮度一致。
static func add_headlights(model: Node3D, spec: Dictionary, energy_scale: float = 1.0) -> void:
	if model == null:
		return
	var energy := HEADLIGHT_ENERGY * clampf(energy_scale, 0.45, 2.0)
	var existing := model.find_child("Headlight_R", true, false) as SpotLight3D
	if existing != null:
		# 灯已经挂着时只更新亮度，不重复建灯。
		existing.light_energy = energy
		var other := model.find_child("Headlight_L", true, false) as SpotLight3D
		if other != null:
			other.light_energy = energy
		return
	var lights: Dictionary = spec.get("lights", {})
	var head: Array = lights.get("headlight", [0.0, 0.6, 2.1])
	var target: Array = lights.get("target", [0.0, -1.2, 32.0])
	var head_pos := Vector3(float(head[0]), float(head[1]), float(head[2]))
	var target_pos := Vector3(float(target[0]), float(target[1]), float(target[2]))
	# 光轴压低：原配置的落点几乎水平（1° 下倾），光斑全打在远处雾里。
	# 现在让光轴在 ~34m 处落地，锥面下半部同时覆盖 1~30m 的路面，
	# 形成一条从车头铺到远处的前照灯光带。
	var aim := Vector3(target_pos.x, -0.15, maxf(target_pos.z, 34.0))
	# 灯珠横向间距按车宽取，窄车/宽车都不会把灯挂到车身外面。
	var half_w := HEADLIGHT_LATERAL
	var contact: Array = spec.get("contact", [])
	if contact.size() >= 1 and float(contact[0]) > 1.0:
		half_w = clampf(float(contact[0]) * 0.27, 0.40, 0.72)
	# 灯珠贴着实际灯组表面往里收：manifest 锚点常常飘在灯罩前面（如 Aventador
	# 锚点 2.25 而灯组只到 2.1），直接挂在锚点上会看到灯球浮在车头外。这里量出
	# 前灯组网格的最前表面，把灯珠放到表面略内一点，只露出灯泡 mouth。
	var front_lamp_z := _front_lamp_surface_z(model)
	for sign_v: float in [-1.0, 1.0]:
		var side_name := "R" if sign_v > 0.0 else "L"
		var bulb_z := head_pos.z - 0.01
		if front_lamp_z > 0.8:
			bulb_z = front_lamp_z - 0.08
		var from := Vector3(head_pos.x + half_w * sign_v, head_pos.y, bulb_z)
		var direction := aim - from
		var spot := SpotLight3D.new()
		spot.name = "Headlight_" + side_name
		spot.transform = Transform3D(Basis.looking_at(direction, Vector3.UP), from)
		spot.spot_range = HEADLIGHT_RANGE
		spot.spot_angle = HEADLIGHT_ANGLE
		spot.spot_angle_attenuation = 4.0
		# 雨雾赛道里聚光灯会点亮整团体积雾：压低车灯的体积散射，
		# 只保留路面光斑和车身被照亮，避免迎面机位糊成白屏。
		spot.light_volumetric_fog_energy = 0.05
		spot.light_energy = energy
		spot.light_color = HEADLIGHT_COLOR
		spot.light_specular = 0.35
		spot.shadow_enabled = false
		# 远处 AI 的车灯到一定距离就淡出，省掉聚光灯的逐像素开销。
		spot.distance_fade_enabled = true
		spot.distance_fade_begin = 130.0
		spot.distance_fade_length = 50.0
		model.add_child(spot)

		var lamp := MeshInstance3D.new()
		lamp.name = "Headlamp_" + side_name
		var bulb := SphereMesh.new()
		bulb.radius = 0.05
		bulb.height = 0.09
		bulb.radial_segments = 12
		bulb.rings = 6
		lamp.mesh = bulb
		lamp.position = from
		lamp.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		lamp.layers = RENDER_LAYER_CAR
		lamp.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		var glow := StandardMaterial3D.new()
		glow.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		# 无光照材质直接输出 HDR 亮度，交给 Environment glow 形成灯泡光晕。
		glow.albedo_color = Color(1.9, 1.75, 1.45)
		glow.disable_receive_shadows = true
		lamp.material_override = glow
		model.add_child(lamp)


static func remove_headlights(model: Node3D) -> void:
	if model == null:
		return
	for n in ["Headlight_R", "Headlight_L", "Headlamp_R", "Headlamp_L"]:
		var node := model.find_child(n, true, false)
		if node != null:
			node.queue_free()


## 一个网格是不是「车灯」：节点名或任一材质名带 light/lamp/灯。
static func _mesh_is_lamp(mi: MeshInstance3D) -> bool:
	if _matches_keywords(mi, ["light", "lamp", "灯"]):
		return true
	for s in mi.mesh.get_surface_count():
		var mat := mi.get_active_material(s)
		if mat == null:
			continue
		var nm := String(mat.resource_name).to_lower()
		if nm.contains("light") or nm.contains("lamp") or nm.contains("灯"):
			return true
	return false


## 前灯组网格的最前表面 z（世界系，相对车模）。用来把灯珠贴回灯罩里，
## 而不是挂在 manifest 锚点上飘在车头外。找不到灯组返回 -1。
static func _front_lamp_surface_z(model: Node3D) -> float:
	var best := -1.0
	for node in model.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null or not _mesh_is_lamp(mi):
			continue
		var box := _relative_to(mi, model) * mi.mesh.get_aabb()
		var front := box.position.z + box.size.z
		if front > 0.8 and front > best:
			best = front
	return best


## 刹车灯装配：build 时调用一次。只点亮车模真实的后尾灯——
##  1. 几何位于车尾、高于轮心的实体红玻璃/自发光灯罩：逐面复制材质，刹车时
##     拉高红色 emission（保留原厂灯罩形状）；
##  2. 贴图灯罩：叠/复用红色 texel 遮罩 next_pass，刹车时拉高 strength，
##     亮的就是贴图里那块红色尾灯（前后共用灯贴图的车也只亮红色 texel）。
## 找不到可分离尾灯的车型不装任何东西，绝不外加假灯条。
static func setup_brake_lights(model: Node3D, spec: Dictionary) -> void:
	if model == null:
		return
	var shader := _tail_glow_shader()
	var emissive_mats: Array[StandardMaterial3D] = []
	var emissive_base: Array[float] = []
	for node in model.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			continue
		for s in mi.mesh.get_surface_count():
			var mat := mi.get_active_material(s) as StandardMaterial3D
			if mat == null or not _is_tail_material(mat):
				continue
			var box := _surface_aabb(mi, model, s)
			# 车尾朝 -Z：整面必须落在车尾，且高于轮心（排除红色卡钳/轮毂）。
			if box.position.z + box.size.z > -0.4 or box.position.y < 0.35:
				continue
			var dup := mat.duplicate() as StandardMaterial3D
			mi.set_surface_override_material(s, dup)
			# 车尾独立灯面：直接红色自发光增强，亮的就是这块灯罩的原厂形状。
			dup.emission_enabled = true
			dup.emission = TAIL_BRAKE_COLOR
			emissive_mats.append(dup)
			emissive_base.append(dup.emission_energy_multiplier)
	# 收集所有红光 next_pass（含前后共用灯贴图的车），刹车时统一拉高 strength。
	var glow_mats: Array[ShaderMaterial] = []
	if shader != null:
		for node in model.find_children("*", "MeshInstance3D", true, false):
			var mi := node as MeshInstance3D
			if mi.mesh == null:
				continue
			for s in mi.mesh.get_surface_count():
				var mat := mi.get_active_material(s) as StandardMaterial3D
				if mat == null:
					continue
				var np := mat.next_pass as ShaderMaterial
				if np != null and np.shader == shader and not glow_mats.has(np):
					glow_mats.append(np)
	model.set_meta("brake_glow", glow_mats)
	model.set_meta("brake_emissive", emissive_mats)
	model.set_meta("brake_emissive_base", emissive_base)
	model.set_meta("brake_on", false)
	_apply_brake_state(model, false)


## 刹车状态切换：玩家车/AI 车每帧调用，状态没变直接返回，开销几乎为零。
static func set_brake_lights(model: Node3D, on: bool) -> void:
	if model == null:
		return
	if bool(model.get_meta("brake_on", false)) == on:
		return
	model.set_meta("brake_on", on)
	_apply_brake_state(model, on)


static func _apply_brake_state(model: Node3D, on: bool) -> void:
	var strength := TAIL_BRAKE_STRENGTH if on else TAIL_RUNNING_STRENGTH
	for sm in model.get_meta("brake_glow", []):
		(sm as ShaderMaterial).set_shader_parameter("strength", strength)
	var mats: Array = model.get_meta("brake_emissive", [])
	var bases: Array = model.get_meta("brake_emissive_base", [])
	for i in mats.size():
		var m := mats[i] as StandardMaterial3D
		m.emission_energy_multiplier = float(bases[i]) + (TAIL_BRAKE_EMISSION if on else 0.0)


## 一个材质是不是「尾灯候选」：灯/红玻璃/自发光命名或红色底色，排除轮毂、
## 卡钳、刹车盘、车漆、内饰等同样可能偏红但并非尾灯的材质。
static func _is_tail_material(mat: StandardMaterial3D) -> bool:
	var nm := String(mat.resource_name).to_lower()
	for k in ["rim", "tyre", "tire", "wheel", "brake", "disc", "caliper", "rotor",
			"hub", "details", "paint", "carpaint", "车漆", "coloured", "body",
			"carbon", "interior", "seat", "engine"]:
		if nm.contains(k):
			return false
	if nm.contains("light") or nm.contains("lamp") or nm.contains("灯") \
			or nm.contains("neon") or nm.contains("deng") or nm.contains("tail") \
			or nm.contains("red"):
		return true
	var c := mat.albedo_color
	if c.r - maxf(c.g, c.b) > 0.25:
		return true
	if mat.emission_enabled and mat.emission_energy_multiplier > 0.05:
		return true
	return false


## 单个 surface 在车模坐标系下的包围盒（Godot 没有逐面 AABB，从顶点算）。
## 只对已通过材质筛选的灯面调用，顶点量很小。
static func _surface_aabb(mi: MeshInstance3D, model: Node3D, s: int) -> AABB:
	var verts: PackedVector3Array = mi.mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]
	var rel := _relative_to(mi, model)
	var box := AABB()
	var first := true
	for v in verts:
		var p := rel * v
		if first:
			box = AABB(p, Vector3.ZERO)
			first = false
		else:
			box = box.expand(p)
	return box


## 夜间车身的冷色轮廓补光：只挂在玩家车上，小范围、无阴影，把车顶/尾翼/后肩
## 从近黑的街道里勾出来；不照亮远处场景，也不改城市夜景的拍板亮度。
static func add_night_rim(model: Node3D, color: Color = Color(0.62, 0.78, 1.0)) -> void:
	if model == null:
		return
	var rim := model.find_child("NightRim", true, false) as OmniLight3D
	if rim == null:
		rim = OmniLight3D.new()
		rim.name = "NightRim"
		rim.position = Vector3(0.0, 3.0, -2.2)
		rim.omni_range = 4.8
		rim.omni_attenuation = 2.1
		rim.shadow_enabled = false
		rim.light_specular = 0.55
		model.add_child(rim)
	rim.light_color = color
	rim.light_energy = 1.15


static func remove_night_rim(model: Node3D) -> void:
	if model == null:
		return
	var rim := model.find_child("NightRim", true, false)
	if rim != null:
		rim.queue_free()


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
	var cc_mode := OS.get_environment("APEX_Q_PAINT_CC")
	# 清漆粗糙度：0.02 是纯镜面，晴天下太阳在展车漆面上会烧出一块移动的死白
	# 反光（车缓缓自转时尤其明显，像自发光）。0.09 仍是高光车漆，但把太阳
	# 镜反射的峰值摊开一个数量级，只留柔和高光条。
	var cc_rough := 0.03 if cc_mode == "flat" else 0.09
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
				var cc := not matte and cc_mode != "0"
				dup.set("clearcoat_enabled", cc)
				dup.set("clearcoat", 1.0 if cc else 0.0)
				dup.set("clearcoat_roughness", cc_rough)
			# 菲涅尔边缘高光：车漆在暗背景/夜景里靠轮廓反光把体积勾出来，
			# 数值压得很低，只加边缘不把整块车身提亮。
			dup.set("rim_enabled", true)
			dup.set("rim", 0.045 if matte else 0.11)
			dup.set("rim_tint", 0.45)
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


static var _tail_glow_shader_cache: Shader = null


static func _tail_glow_shader() -> Shader:
	if _tail_glow_shader_cache == null:
		var path := "res://shaders/car_tail_glow.gdshader"
		if ResourceLoader.exists(path):
			_tail_glow_shader_cache = load(path)
	return _tail_glow_shader_cache


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
			# 车灯：只给贴图里偏红的尾灯/示宽灯叠一层 next_pass 自发光，
			# 白色前灯、转向灯不参与，避免整组车灯一起发白。
			if (mat_name.contains("light") or mat_name.contains("lamp") or mat_name.contains("灯")) \
					and mat.albedo_texture != null and mat.next_pass == null:
				var lamp_dup := mat.duplicate() as StandardMaterial3D
				var glow_shader := _tail_glow_shader()
				if glow_shader != null:
					var glow := ShaderMaterial.new()
					glow.shader = glow_shader
					glow.set_shader_parameter("light_tex", lamp_dup.albedo_texture)
					glow.set_shader_parameter("strength", 0.85)
					lamp_dup.next_pass = glow
					mi.set_surface_override_material(s, lamp_dup)
					mat = lamp_dup
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


## 转向反向修正：个别 GLB（如 zeekr_7x）的 CarRoot 带 180° Y 翻转用来把车头朝前，
## 但转向节点挂在翻转坐标系下，car.gd 统一写 rotation.y 时左打会变成右打。
## 判定 = 转向节点模型空间基的 X 分量 < 0（左打前缘应往 +X 移）。修正 = 在模型根
## 插一个模型对齐的转向枢轴 SteerPivot_XX，把原转向节点带着原有旋转挂进去当静态
## 补偿；car.gd 驱动外层枢轴，转向就回到模型坐标系，方向正确且几何位置不变。
static func _fix_reversed_steers(model: Node3D, steers: Array[Node3D]) -> void:
	for i in steers.size():
		var steer := steers[i]
		if steer == null:
			continue
		var rel := _relative_to(steer, model)
		if rel.basis.x.x >= 0.0:
			continue
		var pivot := Node3D.new()
		pivot.name = "SteerPivot_" + String(steer.name).trim_prefix("Wheel_")
		model.add_child(pivot)
		pivot.transform = Transform3D(Basis.IDENTITY, rel.origin)
		var parent := steer.get_parent()
		if parent != null:
			parent.remove_child(steer)
		pivot.add_child(steer)
		steer.transform = Transform3D(rel.basis, Vector3.ZERO)
		steers[i] = pivot


static func _center_spin_wheels(spins: Array[Node3D], wheel_radius: float) -> void:
	for spin in spins:
		if spin == null:
			continue
		var tyre_meshes: Array[MeshInstance3D] = []
		var rim_meshes: Array[MeshInstance3D] = []
		for node in spin.find_children("*", "MeshInstance3D", true, false):
			var mi := node as MeshInstance3D
			if mi.mesh == null:
				continue
			var nm := String(mi.name).to_lower()
			if nm.contains("brake") or nm.contains("disc") or nm.contains("caliper"):
				continue
			if nm.contains("tyre") or nm.contains("tire") or nm.contains("胎"):
				tyre_meshes.append(mi)
			elif nm.contains("rim") or nm.contains("spoke") or nm.contains("轮") or nm.contains("毂"):
				rim_meshes.append(mi)
		# 以轮毂中心为整组车轮的装配基准；胎体与轮毂各自独立转正/正圆/同心，
		# 避免「只椭圆的是胎体却把整组（含轮毂）一起拉伸」把轮辐拉成 oval。
		var target := Vector3.ZERO
		if rim_meshes.size() > 0:
			target = _meshes_aabb_center_rel(rim_meshes, spin)
		elif tyre_meshes.size() > 0:
			target = _meshes_aabb_center_rel(tyre_meshes, spin)
		# 对齐/正圆会放大包围盒，重建尺寸须用对齐前的轮毂原始包围盒（短轴=真实半径）。
		var raw_rim := AABB()
		if rim_meshes.size() > 0:
			raw_rim = _meshes_aabb_rel(rim_meshes, spin)
		var raw_tyre := AABB()
		if tyre_meshes.size() > 0:
			raw_tyre = _meshes_aabb_rel(tyre_meshes, spin)
		# 重建外径取对齐前 胎体/轮毂 包围盒的最大 Y/Z（= 原厂轮外径）。manifest 的
		# wheelRadius 对宽体车偏小，直接用会让重建轮比原厂小、轮拱空、远侧轮露出。
		var outer_r := maxf(maxf(raw_rim.size.y, raw_rim.size.z), maxf(raw_tyre.size.y, raw_tyre.size.z)) * 0.5
		if outer_r < 0.10:
			outer_r = wheel_radius
		_align_wheel_group(tyre_meshes, spin, target)
		_align_wheel_group(rim_meshes, spin, target)
		var box := _subtree_aabb(spin)
		if box.size.length() <= 0.001:
			continue
		# 把滚转枢轴挪到轮子装配中心 target：枢轴 +T、子节点 -T → 几何在世界里保持
		# 不动，但旋转中心变成轮心。不能用整组 AABB 中心（刹车/卡钳/杂散几何会拉歪），
		# 否则胎体虽已同心于 target，枢轴却偏到别处 → 滚动轮心漂移。
		if target.length() > 0.001:
			spin.position += target
			for k in spin.get_children():
				if k is Node3D:
					(k as Node3D).position -= target
		# 仿射修正后仍非正圆/轮心漂移的胎体（网格本身是不一致椭圆环或带歪斜子网格）
		# → 重建为标准圆环。轮毂若也碎成错位连通块（rolling var 高，如 m4_adro_kit
		# 后轮辋），仿射同样修不好 → 整轮重建（干净胎体 + 干净辐条轮毂）。
		var tm := _roll_metrics_of(tyre_meshes, spin)
		var rm := _roll_metrics_of(rim_meshes, spin)
		var tyre_bad: bool = tm["var"] > TYRE_REBUILD_VAR or tm["drift"] > TYRE_REBUILD_DRIFT
		var rim_bad: bool = rm["var"] > TYRE_REBUILD_VAR
		if rim_bad:
			_rebuild_wheel(spin, tyre_meshes, rim_meshes, outer_r, raw_rim)
		elif tyre_bad:
			_rebuild_tyre(spin, tyre_meshes, raw_rim, outer_r)
		spin.set_meta("wheel_fixed", true)


## 单组车轮网格（胎体或轮毂）对齐到 target 中心：
##   · 滚转轴（PCA 最薄轴）偏斜超阈值 → 旋转回 X；
##   · Y/Z 椭圆超容差 → 绕自身中心单轴缩放成正圆；
##   · 平移使组中心落到 target（整组同心）。
## 变换直接烘焙进各网格节点（法线随节点旋转，光照不变）。装配正常的组此步≈no-op。
static func _align_wheel_group(meshes: Array[MeshInstance3D], spin: Node3D, target: Vector3) -> void:
	if meshes.is_empty():
		return
	var pts := PackedVector3Array()
	for mi in meshes:
		pts.append_array(_mesh_verts_rel(mi, spin))
	if pts.size() < 16:
		return
	var center := _points_center(pts)
	var axis := _pca_thinnest_axis(pts)
	var rot := Basis.IDENTITY
	if axis.length() > 0.5:
		var tilt := rad_to_deg(acos(clampf(absf(axis.normalized().x), 0.0, 1.0)))
		if tilt > TYRE_REALIGN_DEG:
			rot = Basis(Quaternion(axis.normalized(), Vector3(1, 0, 0)))
	# 转正后量 Y/Z 尺寸，决定正圆缩放
	var min_y := INF
	var max_y := -INF
	var min_z := INF
	var max_z := -INF
	for p in pts:
		var q := rot * (p - center)
		min_y = minf(min_y, q.y)
		max_y = maxf(max_y, q.y)
		min_z = minf(min_z, q.z)
		max_z = maxf(max_z, q.z)
	var ext_y := max_y - min_y
	var ext_z := max_z - min_z
	var scl := Basis.IDENTITY
	if ext_y > 0.01 and ext_z > 0.01 and absf(ext_y / ext_z - 1.0) > TYRE_ELLIPSE_TOL:
		var t := maxf(ext_y, ext_z)
		scl = Basis(Vector3(1, 0, 0), Vector3(0, t / ext_y, 0), Vector3(0, 0, t / ext_z))
	var lin := scl * rot
	var k := Transform3D(lin, target - lin * center)
	for mi in meshes:
		var parent_rel := _relative_to(mi.get_parent(), spin)
		var rel := _relative_to(mi, spin)
		mi.transform = parent_rel.affine_inverse() * k * rel


## 模拟绕 X 滚转一圈，量一组网格最大(Y,Z)外径变化率（var，%）与轮心漂移（drift，m）。
## 与运行时探针同口径，用于判定仿射修正后胎体/轮毂是否仍非正圆/偏心（网格本身损坏）。
static func _roll_metrics_of(meshes: Array[MeshInstance3D], spin: Node3D) -> Dictionary:
	var pts := PackedVector3Array()
	for mi in meshes:
		if mi.mesh == null:
			continue
		pts.append_array(_mesh_verts_rel(mi, spin))
	if pts.size() < 16:
		return {"var": 0.0, "drift": 0.0}
	var ext_min := INF
	var ext_max := 0.0
	var ext_sum := 0.0
	var centers: Array[Vector2] = []
	var steps := 12
	for k in steps:
		var th := TAU * float(k) / float(steps)
		var c := cos(th)
		var s := sin(th)
		var mny := INF
		var mxy := -INF
		var mnz := INF
		var mxz := -INF
		for p in pts:
			var y := p.y * c - p.z * s
			var z := p.y * s + p.z * c
			mny = minf(mny, y)
			mxy = maxf(mxy, y)
			mnz = minf(mnz, z)
			mxz = maxf(mxz, z)
		var e := maxf(mxy - mny, mxz - mnz)
		ext_min = minf(ext_min, e)
		ext_max = maxf(ext_max, e)
		ext_sum += e
		centers.append(Vector2((mny + mxy) * 0.5, (mnz + mxz) * 0.5))
	var mean := ext_sum / float(steps)
	var var_pct := (ext_max - ext_min) / maxf(mean, 0.0001) * 100.0
	var mc := Vector2.ZERO
	for ct in centers:
		mc += ct
	mc /= float(centers.size())
	var drift := 0.0
	for ct in centers:
		drift = maxf(drift, ct.distance_to(mc))
	return {"var": var_pct, "drift": drift}


## 胎体网格本身是不一致椭圆环、仿射修不好时，用标准圆环重建胎体（保留轮毂）。
## 外径/宽度取自对齐前的轮毂原始包围盒（短轴=真实半径，避免被放大后的胎体包围盒
## 撑出 oversized 圆环），同心于轮心、滚转轴 X，保证正圆滚动且与轮毂同心。
static func _rebuild_tyre(spin: Node3D, tyre_meshes: Array[MeshInstance3D], raw_rim: AABB, outer_r: float) -> void:
	var box := _tyre_subtree_aabb(spin)
	if box.size.y < 0.01 or box.size.z < 0.01:
		return
	var r := maxf(outer_r, 0.10)
	var w := clampf(raw_rim.size.x, r * 0.5, r * 1.2)
	if raw_rim.size.x <= 0.02:
		w = clampf(box.size.x, r * 0.5, r * 1.2)
	var center := box.get_center()
	var mat: Material = null
	for mi in tyre_meshes:
		if mi.mesh != null and mi.mesh.get_surface_count() > 0:
			mat = mi.get_active_material(0)
			if mat != null:
				break
	if mat == null:
		var rubber := StandardMaterial3D.new()
		rubber.albedo_color = Color(0.02, 0.02, 0.022)
		rubber.roughness = 0.94
		mat = rubber
	for mi in tyre_meshes:
		# 先给有效材质再释放，避免渲染服务器拆解 null 材质表面时报错。
		for s in mi.mesh.get_surface_count():
			mi.set_surface_override_material(s, mat)
		var p := mi.get_parent()
		if p != null:
			p.remove_child(mi)
		mi.free()
	var torus := TorusMesh.new()
	torus.inner_radius = r * 0.70
	torus.outer_radius = r
	torus.rings = 24
	torus.ring_segments = 48
	var rebuilt := MeshInstance3D.new()
	rebuilt.name = "Tyre_Rebuilt"
	rebuilt.mesh = torus
	rebuilt.material_override = mat
	# TorusMesh 环面在 XZ、轴为 Y；绕 Z -90° 把轴转到 X，再沿 X 拉宽到胎宽 w。
	var rz := Basis(Vector3(0, -1, 0), Vector3(1, 0, 0), Vector3(0, 0, 1))
	var axial := w / maxf(r - torus.inner_radius, 0.001)
	var lin := Basis(Vector3(axial, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1)) * rz
	rebuilt.transform = Transform3D(lin, center)
	spin.add_child(rebuilt)


## 轮毂网格本身碎成错位连通块（rolling var 高，仿射修不好，如 m4_adro_kit 后轮辋）
## 时，整轮重建：干净圆环胎体 + 5 辐条轮毂，按 manifest wheelRadius 定尺寸，同心于
## 滚转枢轴、滚转轴 X。胎体命名 Tyre_Rebuilt、轮毂命名 Rim_Rebuilt，兼容探针与 wheel_dims。
static func _rebuild_wheel(spin: Node3D, tyre_meshes: Array[MeshInstance3D],
		rim_meshes: Array[MeshInstance3D], outer_r: float, raw_rim: AABB) -> void:
	var r := maxf(outer_r, 0.20)
	var w := r * 0.72
	if raw_rim.size.x > 0.02:
		w = clampf(raw_rim.size.x, r * 0.5, r * 1.0)
	# 材质：胎体沿用原胎材质；轮毂用枪灰金属（辐条）+ 亮抛边。
	var rubber: Material = null
	for mi in tyre_meshes:
		if mi.mesh != null and mi.mesh.get_surface_count() > 0:
			rubber = mi.get_active_material(0)
			if rubber != null:
				break
	if rubber == null:
		var rubber_new := StandardMaterial3D.new()
		rubber_new.albedo_color = Color(0.02, 0.02, 0.022)
		rubber_new.roughness = 0.94
		rubber = rubber_new
	var rim_mat := StandardMaterial3D.new()
	rim_mat.albedo_color = Color(0.16, 0.17, 0.19)
	rim_mat.metallic = 0.9
	rim_mat.roughness = 0.3
	var rim_bright := StandardMaterial3D.new()
	rim_bright.albedo_color = Color(0.35, 0.36, 0.38)
	rim_bright.metallic = 1.0
	rim_bright.roughness = 0.18
	# 移除整组碎裂的原车轮网格（胎体 + 轮毂；刹车件在转向节点下，不动）。
	var doomed: Array[MeshInstance3D] = []
	for node in spin.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		var nm := String(mi.name).to_lower()
		if nm.contains("brake") or nm.contains("disc") or nm.contains("caliper"):
			continue
		doomed.append(mi)
	_free_meshes(doomed, rubber)
	# 胎体（圆环，轴 X，拉宽到胎宽 w）。
	var torus := TorusMesh.new()
	torus.inner_radius = r * 0.70
	torus.outer_radius = r
	torus.rings = 24
	torus.ring_segments = 48
	var tyre := MeshInstance3D.new()
	tyre.name = "Tyre_Rebuilt"
	tyre.mesh = torus
	tyre.material_override = rubber
	var rz := Basis(Vector3(0, -1, 0), Vector3(1, 0, 0), Vector3(0, 0, 1))
	var axial := w / maxf(r - torus.inner_radius, 0.001)
	tyre.transform = Transform3D(Basis(Vector3(axial, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1)) * rz, Vector3.ZERO)
	spin.add_child(tyre)
	# 轮毂（抛边 + 辐条 +  hub，挂在滚转枢轴下随轮滚转）。
	var rim_root := Node3D.new()
	rim_root.name = "Rim_Rebuilt"
	spin.add_child(rim_root)
	var rim_r := r * 0.72
	for sx in [-1.0, 1.0]:
		var lip := TorusMesh.new()
		lip.inner_radius = rim_r * 0.90
		lip.outer_radius = rim_r * 1.03
		lip.rings = 10
		lip.ring_segments = 40
		var li := MeshInstance3D.new()
		li.name = "Rim_Lip" if sx > 0.0 else "Rim_Lip_In"
		li.mesh = lip
		li.material_override = rim_bright
		li.transform = Transform3D(rz, Vector3(sx * w * 0.42, 0, 0))
		rim_root.add_child(li)
	# 辐条双面布置：从车外/车内任一侧看都是完整辐条轮，避免远侧轮露出空轮辋圈。
	var spokes := 5
	for i in spokes:
		var pivot := Node3D.new()
		pivot.rotation.x = TAU * float(i) / float(spokes)
		rim_root.add_child(pivot)
		for fx in [w * 0.30, -w * 0.30]:
			var sp := BoxMesh.new()
			sp.size = Vector3(w * 0.18, rim_r * 1.0, r * 0.11)
			var smi := MeshInstance3D.new()
			smi.name = "Rim_Spoke" if fx > 0.0 else "Rim_Spoke_In"
			smi.mesh = sp
			smi.material_override = rim_mat
			smi.position = Vector3(fx, rim_r * 0.5, 0)
			pivot.add_child(smi)
	var hub := CylinderMesh.new()
	hub.top_radius = rim_r * 0.26
	hub.bottom_radius = rim_r * 0.26
	hub.height = w * 0.62
	hub.radial_segments = 24
	var hmi := MeshInstance3D.new()
	hmi.name = "Rim_Hub"
	hmi.mesh = hub
	hmi.material_override = rim_mat
	hmi.transform = Transform3D(rz, Vector3.ZERO)
	rim_root.add_child(hmi)


## 释放一组网格：先给每个 surface 有效材质再 free，避免渲染服务器拆解 null 材质报错。
static func _free_meshes(meshes: Array[MeshInstance3D], mat: Material) -> void:
	for mi in meshes:
		if mi.mesh != null:
			for s in mi.mesh.get_surface_count():
				mi.set_surface_override_material(s, mat)
		var p := mi.get_parent()
		if p != null:
			p.remove_child(mi)
		mi.free()


static func _mesh_verts_rel(mi: MeshInstance3D, ancestor: Node3D) -> PackedVector3Array:
	var out := PackedVector3Array()
	var rel := _relative_to(mi, ancestor)
	for s in mi.mesh.get_surface_count():
		var arr := mi.mesh.surface_get_arrays(s)
		var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		for v in verts:
			out.append(rel * v)
	return out


static func _points_center(points: PackedVector3Array) -> Vector3:
	var box := AABB(points[0], Vector3.ZERO)
	for p in points:
		box = box.expand(p)
	return box.get_center()


static func _meshes_aabb_rel(meshes: Array[MeshInstance3D], ancestor: Node3D) -> AABB:
	var box := AABB()
	var first := true
	for mi in meshes:
		var rel := _relative_to(mi, ancestor)
		var aabb: AABB = rel * mi.mesh.get_aabb()
		if first:
			box = aabb
			first = false
		else:
			box = box.merge(aabb)
	return box


static func _meshes_aabb_center_rel(meshes: Array[MeshInstance3D], ancestor: Node3D) -> Vector3:
	var box := _meshes_aabb_rel(meshes, ancestor)
	return box.get_center() if box.size.length() > 0.0 else Vector3.ZERO


## 顶点 PCA 最薄轴（轮子滚转轴方向）。协方差补矩阵 tr*I-A 幂迭代求最小特征向量。
static func _pca_thinnest_axis(points: PackedVector3Array) -> Vector3:
	if points.size() < 16:
		return Vector3.ZERO
	var n := float(points.size())
	var mean := Vector3.ZERO
	for p in points:
		mean += p
	mean /= n
	var cxx := 0.0
	var cyy := 0.0
	var czz := 0.0
	var cxy := 0.0
	var cxz := 0.0
	var cyz := 0.0
	for p in points:
		var d := p - mean
		cxx += d.x * d.x
		cyy += d.y * d.y
		czz += d.z * d.z
		cxy += d.x * d.y
		cxz += d.x * d.z
		cyz += d.y * d.z
	cxx /= n
	cyy /= n
	czz /= n
	cxy /= n
	cxz /= n
	cyz /= n
	var tr := cxx + cyy + czz
	var v := Vector3(0.31, 0.53, 0.81).normalized()
	for iter in 200:
		var w := Vector3(
			(tr - cxx) * v.x - cxy * v.y - cxz * v.z,
			-cxy * v.x + (tr - cyy) * v.y - cyz * v.z,
			-cxz * v.x - cyz * v.y + (tr - czz) * v.z)
		if w.length() < 1e-12:
			return Vector3.ZERO
		v = w.normalized()
	return v


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
	quad.size = Vector2(2.4, 3.9)
	var mi := MeshInstance3D.new()
	mi.name = "BlobShadow"
	mi.mesh = quad
	mi.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	mi.position = Vector3(0.0, 0.045, 0.0)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.layers = 4

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_texture = _blob_shadow_texture()
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_OPAQUE_ONLY
	mi.material_override = mat
	parent.add_child(mi)


static var _blob_tex: ImageTexture = null


## 车形接触阴影：车身一圈软椭圆 + 四个轮胎接地点更深的暗斑。
## 比一张均匀径向渐变更像车压出来的影子，且随车体旋转，不额外吃灯光/阴影 pass。
## 这层是不受光的纯黑 alpha 叠加，追车机位下车周围整片地面都会被它压暗：
## 旧参数 3.0x4.8 m / 峰值 0.62 实测把车侧路面压掉 10~14 个灰阶，边缘还能看出
## 一块跟着车走的暗垫。车在最高画质也照样投真实方向光阴影，所以这里只留
## 「贴地」这一层信息，压到 0.24 上限并把衰减起点提前，肉眼不再有边界。
static func _blob_shadow_texture() -> ImageTexture:
	if _blob_tex != null:
		return _blob_tex
	var size := 256
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	for y in size:
		for x in size:
			var u := (float(x) + 0.5) / float(size)
			var v := (float(y) + 0.5) / float(size)
			# 外层柔光 + 车身椭圆
			var outer := 1.0 - smoothstep(0.34, 1.02,
				Vector2((u - 0.5) / 0.46, (v - 0.5) / 0.48).length())
			var body := 1.0 - smoothstep(0.60, 1.00,
				Vector2((u - 0.5) / 0.34, (v - 0.5) / 0.42).length())
			var alpha := outer * 0.05 + body * 0.08
			# 四轮接地点
			for wx: float in [0.31, 0.69]:
				for wy: float in [0.26, 0.74]:
					var d := Vector2((u - wx) / 0.075, (v - wy) / 0.10).length()
					alpha += (1.0 - smoothstep(0.45, 1.10, d)) * 0.10
			alpha = clampf(alpha, 0.0, 0.24)
			img.set_pixel(x, y, Color(0.0, 0.0, 0.0, alpha))
	img.generate_mipmaps()
	_blob_tex = ImageTexture.create_from_image(img)
	return _blob_tex
