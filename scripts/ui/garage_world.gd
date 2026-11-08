class_name GarageWorld
extends Node3D
## 3D showroom（车库/展厅）影棚。
##
## 视觉目标：专业汽车摄影棚 —— 纯黑暗场 + 长条柔光箱在车漆/清漆上的高光、
## 低机位 3/4 视角、地面光池 + 涡轮台青色描边。所有参数集中在下面常量区，
## 调灯只需要改常量，不用动逻辑。
##
## 关键实现：真正的「灯」只有 4 盏 DirectionalLight + 1 盏顶部 SpotLight；
## 长条柔光箱不占用实时灯资源，而是用程序化 HDR Sky Shader 生成，只喂给
## 环境反射 / 环境光（背景仍是纯色暗场，因此在画面上看不到灯条本体）。

# ---------------------------------------------------------------------------
# 影棚调色板 / 总控
# ---------------------------------------------------------------------------

const BG_COLOR := Color(0.010, 0.012, 0.017)   # 背景与雾色（纯黑暗场）
const SUN_COLOR := Color(1.0, 0.96, 0.90)      # key / 主光色温 ~5600K
const FILL_COLOR := Color(0.55, 0.70, 1.0)     # fill 冷补光
const RIM_COLOR := Color(0.72, 0.86, 1.0)      # 轮廓光（偏冷）
const RING_COLOR := Color(0.22, 0.82, 0.92)    # 展台品牌青

# 影调：白色/亮色车漆多，用 AGX（高光滚降更柔，白漆不发死）配合 exposure。
# 若个别车漆过曝：先降 TONEMAP_EXPOSURE（1.10~1.20）再动灯；ACES 备选色更饱和。
const TONEMAP_MODE := Environment.TONE_MAPPER_AGX
const TONEMAP_EXPOSURE := 1.18

# 天空环境（只做反射/环境光）
const AMBIENT_ENERGY := 0.30
const SKY_RADIANCE := Sky.RADIANCE_SIZE_512
const CEILING_GLOW := 0.10      # 顶部大面积柔光（车顶/机盖上的柔和渐变）
const FLOOR_BOUNCE := 0.05      # 地面反弹（车身下部补一点暖光）
const STRIP_HERO_ENERGY := 26.0  # 细长主柔光箱亮度（HDR，车漆上形成白热长高光）
const STRIP_SOFT_ENERGY := 1.6   # 宽辅柔光箱亮度（软渐变）

# 实时灯
const KEY_ENERGY := 1.25
const FILL_ENERGY := 0.22
const RIM_L_ENERGY := 1.10
const RIM_R_ENERGY := 0.75
const POOL_ENERGY := 1.0       # 顶部聚光灯地面光池
const KEY_SHADOW_BLUR := 1.6
const SHADOW_MAX_DISTANCE := 22.0

# 雾：只淡出远处地面，车身（约 6~8m）不受影响
const FOG_DENSITY := 0.65
const FOG_DEPTH_BEGIN := 8.0
const FOG_DEPTH_END := 34.0

# 地面 / 展台
const FLOOR_Y := -0.085
const FLOOR_ALBEDO := Color(0.030, 0.034, 0.042)
const FLOOR_ROUGHNESS := 0.75
const FLOOR_METALLIC := 0.0
const FLOOR_SPECULAR := 0.18
const PLINTH_RADIUS := 3.15
const PLINTH_ALBEDO := Color(0.030, 0.035, 0.045)
const PLINTH_ROUGHNESS := 0.38
const PLINTH_METALLIC := 0.30
const RING_EMISSION := 1.2

# 相机（卡片 UI 在右侧，车身占画面左 2/3）。基准尺寸 = M3（4.49m 长），
# 其它车按 AABB 长度等比拉远，长车/大 SUV 不切边。
const CAMERA_POS := Vector3(6.35, 1.42, 4.45)
const CAMERA_LOOK := Vector3(1.90, 0.74, 0.0)
const CAMERA_FOV := 34.0
const BASE_CAR_LENGTH := 4.49
const CAMERA_OFFSET := Vector3(4.45, 0.68, 4.45)  # camera - look（基准车）

# 拖拽旋转灵敏度（横向像素 → 弧度）
const DRAG_SENSITIVITY := 0.008

var holder: Node3D
var current_car_id := ""
var _camera: Camera3D
var _dragging := false


func _ready() -> void:
	_setup_studio()
	_camera = Camera3D.new()
	_camera.name = "GarageCamera"
	_camera.fov = CAMERA_FOV
	add_child(_camera)
	_camera.position = CAMERA_POS
	_camera.look_at(CAMERA_LOOK)


# ---------------------------------------------------------------------------
# studio
# ---------------------------------------------------------------------------

func _setup_studio() -> void:
	_add_environment()
	_add_lights()
	_add_floor()
	_add_plinth()


func _add_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = BG_COLOR
	env.sky = _build_softbox_sky()
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = 1.0
	env.ambient_light_energy = AMBIENT_ENERGY
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = TONEMAP_MODE
	env.tonemap_exposure = TONEMAP_EXPOSURE
	if TONEMAP_MODE == Environment.TONE_MAPPER_AGX:
		env.tonemap_agx_contrast = 1.15
	env.glow_enabled = true
	env.glow_intensity = 0.04
	env.glow_strength = 1.0
	env.glow_bloom = 0.0
	env.glow_hdr_threshold = 1.5
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_ADDITIVE
	env.ssr_enabled = true
	env.ssr_max_steps = 64
	env.ssr_fade_in = 0.12
	env.ssr_fade_out = 2.0
	env.ssr_depth_tolerance = 0.4
	env.ssao_enabled = true
	env.ssao_radius = 1.0
	env.ssao_intensity = 1.6
	env.ssao_power = 1.6
	env.ssao_detail = 0.5
	env.ssao_sharpness = 0.98
	env.ssil_enabled = false
	env.sdfgi_enabled = false
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_light_color = BG_COLOR
	env.fog_light_energy = 1.0
	env.fog_density = FOG_DENSITY
	env.fog_depth_begin = FOG_DEPTH_BEGIN
	env.fog_depth_end = FOG_DEPTH_END
	env.fog_sky_affect = 0.0
	env.adjustment_enabled = true
	env.adjustment_contrast = 1.12
	env.adjustment_saturation = 1.08
	var world_env := WorldEnvironment.new()
	world_env.name = "StudioEnvironment"
	world_env.environment = env
	add_child(world_env)


func _build_softbox_sky() -> Sky:
	# 程序化 HDR 影棚天光：近黑的环境 + 4 条高强度细长柔光箱 + 2 条宽而暗的
	# 辅助柔光 + 顶部大面积柔光。只被环境反射/环境光使用（background 仍是
	# BG_COLOR），因此画面里不会出现灯条本体，只会在车漆上留下长条高光。
	var shader := Shader.new()
	shader.code = """
shader_type sky;

// 垂直长条柔光箱：以方位角 center 为中心，elevation 从 lo 到 hi 的软边条。
float strip(float az, float elev, float center, float half_w, float lo, float hi) {
	float da = abs(mod(az - center + 3.14159265, 6.28318531) - 3.14159265);
	float sx = 1.0 - smoothstep(half_w * 0.35, half_w, da);
	float sy = smoothstep(lo - 0.05, lo + 0.10, elev) * (1.0 - smoothstep(hi - 0.10, hi + 0.05, elev));
	return sx * sy;
}

void sky() {
	vec3 d = normalize(EYEDIR);
	float elev = asin(clamp(d.y, -1.0, 1.0));
	float az = atan(d.x, d.z);

	// 暗房壳：地平线附近稍微抬一点，避免车身侧面/缝隙全黑。
	float up = smoothstep(-0.10, 0.95, d.y);
	vec3 col = mix(vec3(0.020, 0.024, 0.032), vec3(0.006, 0.007, 0.010), up);

	// 顶部大面积柔光箱（车顶/机盖上的柔和渐变，不是硬边高光）。
	float ceiling = smoothstep(0.35, 1.30, elev);
	col += vec3(0.55, 0.62, 0.74) * CEILING_GLOW_STR;

	// 地面反射回来的暖色反弹。
	float bounce = smoothstep(0.02, -0.85, d.y);
	col += vec3(0.30, 0.24, 0.18) * FLOOR_BOUNCE_STR;

	// 长条柔光箱：4 条主灯（细而亮，形成车漆长高光）+ 2 条宽辅灯（软渐变）。
	float hero = 0.0;
	hero += strip(az, elev, 0.79, 0.150, 0.05, 1.18);
	hero += strip(az, elev, 2.36, 0.130, 0.05, 1.22);
	hero += strip(az, elev, 3.93, 0.165, 0.05, 1.12);
	hero += strip(az, elev, 5.50, 0.120, 0.05, 1.24);
	float soft = 0.0;
	soft += strip(az, elev, 1.57, 0.250, 0.03, 0.92) * 1.0;
	soft += strip(az, elev, 4.71, 0.260, 0.03, 0.92) * 1.2;
	col += vec3(1.0, 0.985, 0.96) * hero * STRIP_HERO_STR;
	col += vec3(0.85, 0.90, 1.0) * soft * STRIP_SOFT_STR;

	COLOR = col;
}
"""
	shader.code = shader.code.replace("CEILING_GLOW_STR", "%.4f" % CEILING_GLOW)
	shader.code = shader.code.replace("FLOOR_BOUNCE_STR", "%.4f" % FLOOR_BOUNCE)
	shader.code = shader.code.replace("STRIP_HERO_STR", "%.4f" % STRIP_HERO_ENERGY)
	shader.code = shader.code.replace("STRIP_SOFT_STR", "%.4f" % STRIP_SOFT_ENERGY)
	var sky_mat := ShaderMaterial.new()
	sky_mat.shader = shader
	var sky := Sky.new()
	sky.sky_material = sky_mat
	sky.process_mode = Sky.PROCESS_MODE_QUALITY
	sky.radiance_size = SKY_RADIANCE
	return sky


func _add_lights() -> void:
	# Key：高位、略靠相机一侧的暖白主光，唯一投影方向光。
	_add_directional("KeyLight", Vector3(5.2, 7.8, 6.8), KEY_ENERGY, SUN_COLOR, true)
	# Fill：低位、远侧的冷补光，让暗面保持可读。
	_add_directional("FillLight", Vector3(-7.0, 2.6, 3.6), FILL_ENERGY, FILL_COLOR, false)
	# Rim：身后的冷暖双轮廓光，把车顶线/后肩从暗背景里勾出来。
	_add_directional("RimLightL", Vector3(-3.4, 4.2, -8.0), RIM_L_ENERGY, RIM_COLOR, false)
	_add_directional("RimLightR", Vector3(6.2, 3.4, -7.4), RIM_R_ENERGY, SUN_COLOR, false)

	# 顶部聚光灯：地面上的柔和光池（同时给车顶一点顶光）。
	var pool := SpotLight3D.new()
	pool.name = "FloorPool"
	pool.position = Vector3(0.0, 7.6, 0.0)
	pool.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	pool.light_color = Color(1.0, 0.97, 0.92)
	pool.light_energy = POOL_ENERGY
	pool.spot_range = 16.0
	pool.spot_angle = 32.0
	pool.spot_angle_attenuation = 0.85
	pool.spot_attenuation = 0.9
	pool.shadow_enabled = true
	pool.shadow_blur = 2.0
	add_child(pool)


func _add_directional(name: String, from: Vector3, energy: float, color: Color, shadows: bool) -> void:
	var light := DirectionalLight3D.new()
	light.name = name
	light.light_energy = energy
	light.light_color = color
	light.shadow_enabled = shadows
	if shadows:
		light.shadow_blur = KEY_SHADOW_BLUR
		light.directional_shadow_max_distance = SHADOW_MAX_DISTANCE
	add_child(light)
	# 用「灯从哪来」的直觉布置：让光线的 -Z 从 from 指向车中心。
	light.transform = Transform3D(Basis(), from)
	light.look_at(Vector3(0.0, 0.65, 0.0), Vector3.UP)


func _add_floor() -> void:
	var floor_mesh := PlaneMesh.new()
	floor_mesh.size = Vector2(90.0, 90.0)
	var floor_mi := MeshInstance3D.new()
	floor_mi.name = "StudioFloor"
	floor_mi.mesh = floor_mesh
	var mat := StandardMaterial3D.new()
	mat.resource_name = "StudioFloor"
	mat.albedo_color = FLOOR_ALBEDO
	mat.metallic = FLOOR_METALLIC
	mat.roughness = FLOOR_ROUGHNESS
	mat.metallic_specular = FLOOR_SPECULAR
	floor_mi.material_override = mat
	floor_mi.position = Vector3(0.0, FLOOR_Y, 0.0)
	floor_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(floor_mi)


func _add_plinth() -> void:
	var plinth := MeshInstance3D.new()
	plinth.name = "Platform"
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = PLINTH_RADIUS
	cylinder.bottom_radius = PLINTH_RADIUS
	cylinder.height = 0.16
	plinth.mesh = cylinder
	var plate := StandardMaterial3D.new()
	plate.resource_name = "PlinthPlate"
	plate.albedo_color = PLINTH_ALBEDO
	plate.roughness = PLINTH_ROUGHNESS
	plate.metallic = PLINTH_METALLIC
	plate.metallic_specular = 0.6
	plinth.material_override = plate
	plinth.position = Vector3(0.0, -0.08, 0.0)
	add_child(plinth)

	var ring := MeshInstance3D.new()
	ring.name = "Ring"
	var torus := TorusMesh.new()
	torus.inner_radius = PLINTH_RADIUS - 0.035
	torus.outer_radius = PLINTH_RADIUS + 0.025
	ring.mesh = torus
	var ring_mat := StandardMaterial3D.new()
	ring_mat.resource_name = "RingGlow"
	ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ring_mat.albedo_color = RING_COLOR
	ring_mat.emission_enabled = true
	ring_mat.emission = RING_COLOR
	ring_mat.emission_energy_multiplier = RING_EMISSION
	ring.material_override = ring_mat
	ring.position = Vector3(0.0, 0.006, 0.0)
	add_child(ring)


# ---------------------------------------------------------------------------
# showcase car
# ---------------------------------------------------------------------------

## 车辆默认静止；按住左键左右拖拽时才旋转（右侧 UI 面板会先消费事件，
## 因此在面板上拖动不会触发旋转）。
func _unhandled_input(event: InputEvent) -> void:
	if holder == null:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_dragging = event.pressed
	elif event is InputEventMouseMotion and _dragging:
		holder.rotation.y += (event as InputEventMouseMotion).relative.x * DRAG_SENSITIVITY


func show_car(car_id: String) -> void:
	current_car_id = car_id
	if holder != null:
		holder.queue_free()
		holder = null
	holder = Node3D.new()
	holder.name = "ShowcaseCar"
	add_child(holder)
	var spec := Garage.effective_spec(car_id)
	if spec.is_empty():
		spec = GameData.car(String(GameData.cars_specs[0].get("id", "")))
	var result := CarVisual.build(spec, holder)
	var model := result["model"] as Node3D
	if model != null:
		GarageLook.apply(model, car_id, Garage.config(car_id))
		_frame_camera(model)


## 按当前车模 AABB 自适应机位：车越长→机位同比拉远；瞄准高度取车高 0.55。
## 保证 M3 / i8 / SU7 / URUS / GL8 这类 4.4~5.24m 的车都不切边、车顶留余量。
func _frame_camera(model: Node3D) -> void:
	if _camera == null:
		return
	var box := _model_aabb(model)
	if box.size.length() < 0.5:
		_camera.position = CAMERA_POS
		_camera.look_at(CAMERA_LOOK)
		return
	var scale := clampf(box.size.z / BASE_CAR_LENGTH, 0.82, 1.30)
	var look := Vector3(CAMERA_LOOK.x * scale, box.size.y * 0.55, box.position.z + box.size.z * 0.5)
	_camera.position = look + CAMERA_OFFSET * scale
	_camera.look_at(look)


func _model_aabb(model: Node3D) -> AABB:
	var box := AABB()
	var first := true
	for child in model.find_children("*", "MeshInstance3D", true, false):
		var mi := child as MeshInstance3D
		if mi.mesh == null:
			continue
		var rel := _relative_to(mi, model)
		var b: AABB = rel * mi.mesh.get_aabb()
		if first:
			box = b
			first = false
		else:
			box = box.merge(b)
	return box


func _relative_to(node: Node, ancestor: Node) -> Transform3D:
	var rel := Transform3D.IDENTITY
	var cur: Node = node
	while cur != null and cur != ancestor:
		if cur is Node3D:
			rel = (cur as Node3D).transform * rel
		cur = cur.get_parent()
	return rel
