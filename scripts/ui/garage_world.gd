class_name GarageWorld
extends Node3D
## 3D showroom（车库/展厅）影棚。
##
## 视觉目标：专业汽车摄影棚 —— 暗场渐变环幕 + 长条柔光箱在车漆/清漆上的高光、
## 低机位 3/4 视角、地面光池 + 涡轮台青色描边 + 车底接触阴影。
## 45 台车共用同一套灯：暖主光塑形、冷补光读暗面、双轮廓光勾边、顶光铺光池，
## 白漆不过曝、黑漆有细节、金属漆有长高光。参数集中在常量区。
##
## 真正的「灯」只有 4 盏 DirectionalLight + 1 盏顶部 SpotLight；长条柔光箱不占
## 实时灯资源，用程序化 HDR Sky Shader 生成，只喂环境反射/环境光（背景是环幕，
## 画面上看不到灯条本体）。

# ---------------------------------------------------------------------------
# 影棚调色板 / 总控
# ---------------------------------------------------------------------------

const BG_COLOR := Color(0.008, 0.010, 0.014)   # 环幕之外的底色
const SUN_COLOR := Color(1.0, 0.91, 0.79)      # key 主光 ~4800K 暖白
const FILL_COLOR := Color(0.55, 0.70, 1.0)     # fill 冷补光
const RIM_COLOR := Color(0.72, 0.86, 1.0)      # 轮廓光（偏冷）
const RING_COLOR := Color(0.22, 0.82, 0.92)    # 展台品牌青

# 影调：白/亮色车漆多，AGX 高光滚降更柔；曝光略收以保护白漆形体。
const TONEMAP_MODE := Environment.TONE_MAPPER_AGX
const TONEMAP_EXPOSURE := 1.00

# 天空环境（只做反射/环境光）
const AMBIENT_ENERGY := 0.30
const SKY_RADIANCE := Sky.RADIANCE_SIZE_512
const CEILING_GLOW := 0.115     # 顶部大面积柔光（车顶/机盖柔和渐变）
const FLOOR_BOUNCE := 0.095     # 地面反弹（车身下部暖光）
const STRIP_HERO_ENERGY := 14.0 # 细长主柔光箱（车漆长高光）
const STRIP_SOFT_ENERGY := 1.5  # 宽辅柔光箱（软渐变）

# 实时灯
const KEY_ENERGY := 1.55
const FILL_ENERGY := 0.34
const RIM_L_ENERGY := 1.45
const RIM_R_ENERGY := 0.95
const POOL_ENERGY := 2.6        # 顶部聚光地面光池
const KEY_SHADOW_BLUR := 1.8
const SHADOW_MAX_DISTANCE := 24.0

# 雾：只淡出远处地面，车身（约 6~8m）不受影响
const FOG_DENSITY := 0.65
const FOG_DEPTH_BEGIN := 9.0
const FOG_DEPTH_END := 36.0

# 地面 / 展台
const FLOOR_Y := -0.085
const FLOOR_ALBEDO := Color(0.030, 0.034, 0.042)
const FLOOR_ROUGHNESS := 0.80
const PLINTH_RADIUS := 3.15
const PLINTH_ALBEDO := Color(0.022, 0.026, 0.034)
const PLINTH_ROUGHNESS := 0.42
const PLINTH_METALLIC := 0.20
const RING_EMISSION := 1.3

# 相机（卡片 UI 在右侧，车身占画面左 2/3）。基准尺寸 = M3（4.49m 长）。
const CAMERA_POS := Vector3(6.35, 1.42, 4.45)
const CAMERA_LOOK := Vector3(1.90, 0.74, 0.0)
const CAMERA_FOV := 34.0
const BASE_CAR_LENGTH := 4.49
const CAMERA_OFFSET := Vector3(4.45, 0.68, 4.45)

const DRAG_SENSITIVITY := 0.008
const STICK_SPIN := 2.4

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


func _process(dt: float) -> void:
	if holder == null:
		return
	var rs := InputSetup.right_stick()
	if rs.length_squared() > 0.0:
		holder.rotation.y += rs.x * STICK_SPIN * dt


# ---------------------------------------------------------------------------
# studio
# ---------------------------------------------------------------------------

func _setup_studio() -> void:
	_add_environment()
	_add_backdrop()
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
		env.tonemap_agx_contrast = 1.14
	env.glow_enabled = true
	env.glow_intensity = 0.035
	env.glow_strength = 1.0
	env.glow_bloom = 0.0
	env.glow_hdr_threshold = 1.6
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_ADDITIVE
	# 黑场影棚不开 SSR：地面/展台会把 SSR miss 回退的天空柔光箱整片反射成灰白圆盘。
	# 车漆长条高光来自软盒天空的环境反射，与 SSR 无关。
	env.ssr_enabled = false
	env.ssao_enabled = true
	env.ssao_radius = 1.0
	env.ssao_intensity = 1.8
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
	env.adjustment_contrast = 1.13
	env.adjustment_saturation = 1.07
	var world_env := WorldEnvironment.new()
	world_env.name = "StudioEnvironment"
	world_env.environment = env
	add_child(world_env)


## 暗场渐变环幕：给纯黑背景一层纵深，车身后方一道冷色光带把车从背景里推出来。
func _add_backdrop() -> void:
	var cyc := MeshInstance3D.new()
	cyc.name = "Cyclorama"
	var cyl := CylinderMesh.new()
	cyl.top_radius = 40.0
	cyl.bottom_radius = 40.0
	cyl.height = 30.0
	cyl.radial_segments = 48
	cyl.rings = 1
	cyl.cap_top = false
	cyl.cap_bottom = false
	cyc.mesh = cyl
	cyc.position = Vector3(0.0, 9.0, 0.0)
	cyc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := ShaderMaterial.new()
	var shader := Shader.new()
	shader.code = """
shader_type spatial;
render_mode unshaded, cull_front, disable_fog;
varying float wy;
void vertex() {
	wy = (MODEL_MATRIX * vec4(VERTEX, 1.0)).y;
}
void fragment() {
	float h = clamp(wy / 24.0, 0.0, 1.0);
	vec3 bottom = vec3(0.012, 0.014, 0.020);
	vec3 mid = vec3(0.045, 0.055, 0.080);
	vec3 top = vec3(0.008, 0.010, 0.016);
	vec3 col = mix(bottom, mid, smoothstep(0.0, 0.28, h));
	col = mix(col, top, smoothstep(0.30, 0.85, h));
	ALBEDO = col;
}
"""
	mat.shader = shader
	cyc.material_override = mat
	add_child(cyc)


func _build_softbox_sky() -> Sky:
	# 程序化 HDR 影棚天光：近黑环境 + 4 条主柔光箱（暖主/冷轮廓分开）+ 2 条宽辅
	# + 顶部大柔光 + 地面反弹。只被环境反射/环境光使用，画面里不出现灯条本体。
	var shader := Shader.new()
	shader.code = """
shader_type sky;

float strip(float az, float elev, float center, float half_w, float lo, float hi) {
	float da = abs(mod(az - center + 3.14159265, 6.28318531) - 3.14159265);
	float sx = 1.0 - smoothstep(half_w * 0.30, half_w, da);
	float sy = smoothstep(lo - 0.05, lo + 0.10, elev) * (1.0 - smoothstep(hi - 0.10, hi + 0.05, elev));
	return sx * sy;
}

void sky() {
	vec3 d = normalize(EYEDIR);
	float elev = asin(clamp(d.y, -1.0, 1.0));
	float az = atan(d.x, d.z);

	float up = smoothstep(-0.10, 0.95, d.y);
	vec3 col = mix(vec3(0.022, 0.026, 0.034), vec3(0.006, 0.007, 0.010), up);

	float ceiling = smoothstep(0.30, 1.25, elev);
	col += vec3(0.62, 0.62, 0.64) * CEILING_GLOW_STR;

	float bounce = smoothstep(0.02, -0.85, d.y);
	col += vec3(0.36, 0.28, 0.20) * FLOOR_BOUNCE_STR;

	// 暖主柔光箱（相机侧两条）+ 冷轮廓柔光箱（背后两条），车漆长高光有冷暖层次。
	float warm = 0.0;
	warm += strip(az, elev, 0.79, 0.140, 0.05, 1.20);
	warm += strip(az, elev, 2.36, 0.120, 0.05, 1.24);
	float cool = 0.0;
	cool += strip(az, elev, 3.93, 0.150, 0.05, 1.14);
	cool += strip(az, elev, 5.50, 0.110, 0.05, 1.26);
	float soft = 0.0;
	soft += strip(az, elev, 1.57, 0.260, 0.03, 0.95) * 1.0;
	soft += strip(az, elev, 4.71, 0.270, 0.03, 0.95) * 1.2;
	col += vec3(1.0, 0.93, 0.82) * warm * STRIP_HERO_STR;
	col += vec3(0.78, 0.88, 1.0) * cool * STRIP_HERO_STR * 0.85;
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
	# Key：高位、相机左前侧暖白主光，唯一投影方向光，给车身明确的明暗交界。
	_add_directional("KeyLight", Vector3(5.6, 7.6, 6.2), KEY_ENERGY, SUN_COLOR, true)
	# Fill：低位远侧冷补光，暗面保持可读（黑漆不糊成剪影）。
	_add_directional("FillLight", Vector3(-7.0, 2.4, 3.8), FILL_ENERGY, FILL_COLOR, false)
	# Rim：身后冷暖双轮廓光，把车顶线/后肩从暗背景里勾出来。
	_add_directional("RimLightL", Vector3(-3.6, 4.4, -8.0), RIM_L_ENERGY, RIM_COLOR, false)
	_add_directional("RimLightR", Vector3(6.2, 3.4, -7.4), RIM_R_ENERGY, SUN_COLOR, false)

	# 顶部聚光：地面柔和光池 + 车顶顶光。
	var pool := SpotLight3D.new()
	pool.name = "FloorPool"
	pool.position = Vector3(0.0, 7.6, 0.0)
	pool.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	pool.light_color = Color(1.0, 0.97, 0.92)
	pool.light_energy = POOL_ENERGY
	pool.spot_range = 16.0
	pool.spot_angle = 30.0
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
	mat.metallic = 0.0
	mat.roughness = FLOOR_ROUGHNESS
	mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	floor_mi.material_override = mat
	floor_mi.position = Vector3(0.0, FLOOR_Y, 0.0)
	floor_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(floor_mi)
	# 展台外圈一层暖色光池渐变，让近处地面不是死黑_void。
	_add_light_pool()


func _add_light_pool() -> void:
	var quad := QuadMesh.new()
	quad.size = Vector2(15.0, 15.0)
	var mi := MeshInstance3D.new()
	mi.name = "FloorLightPool"
	mi.mesh = quad
	mi.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	mi.position = Vector3(0.0, FLOOR_Y + 0.004, 0.0)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.albedo_texture = _radial_texture(0.16, 0.13, 0.10)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = mat
	add_child(mi)


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
	plate.albedo_color = Color(1.0, 1.0, 1.0)
	plate.albedo_texture = _satin_texture()
	plate.roughness = PLINTH_ROUGHNESS
	plate.metallic = PLINTH_METALLIC
	plate.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
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


## 车底接触阴影：比全局 blob 更深的一层软 AO，把车「压」在展台上。
## 挂在展车 holder 下，随车一起旋转；按车身 footprint 缩放。
func _add_contact_shadow(parent: Node3D, box: AABB) -> void:
	var quad := QuadMesh.new()
	quad.size = Vector2(5.4, 5.4)
	var mi := MeshInstance3D.new()
	mi.name = "StudioContactShadow"
	mi.mesh = quad
	mi.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_texture = _contact_texture()
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_OPAQUE_ONLY
	mi.material_override = mat
	parent.add_child(mi)
	var sx := clampf(box.size.x / 1.85, 0.8, 1.5)
	var sz := clampf(box.size.z / 4.49, 0.8, 1.5)
	mi.scale = Vector3(sx, 1.0, sz)
	mi.position = Vector3(box.position.x + box.size.x * 0.5, 0.012, box.position.z + box.size.z * 0.5)


static var _contact_tex: ImageTexture = null
static func _contact_texture() -> ImageTexture:
	if _contact_tex != null:
		return _contact_tex
	var size := 256
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	for y in size:
		for x in size:
			var u := (float(x) + 0.5) / float(size)
			var v := (float(y) + 0.5) / float(size)
			var body := 1.0 - smoothstep(0.30, 0.92,
				Vector2((u - 0.5) / 0.40, (v - 0.5) / 0.46).length())
			var alpha := body * 0.50
			for wx: float in [0.30, 0.70]:
				for wy: float in [0.26, 0.74]:
					var d := Vector2((u - wx) / 0.09, (v - wy) / 0.12).length()
					alpha += (1.0 - smoothstep(0.55, 1.05, d)) * 0.28
			alpha = clampf(alpha, 0.0, 0.72)
			img.set_pixel(x, y, Color(0.0, 0.0, 0.0, alpha))
	img.generate_mipmaps()
	_contact_tex = ImageTexture.create_from_image(img)
	return _contact_tex


## 展台 satin 渐变：中心略亮、边缘压暗（RGB 渐变，opaque 材质不吃 alpha）。
static func _satin_texture() -> ImageTexture:
	var size := 128
	var img := Image.create(size, size, false, Image.FORMAT_RGB8)
	var center := Color(0.050, 0.058, 0.075)
	var edge := Color(0.016, 0.020, 0.028)
	for y in size:
		for x in size:
			var u := (float(x) + 0.5 - size * 0.5) / (size * 0.5)
			var v := (float(y) + 0.5 - size * 0.5) / (size * 0.5)
			var r := sqrt(u * u + v * v)
			var k := pow(clampf(1.0 - r, 0.0, 1.0), 1.6)
			var c := edge.lerp(center, k)
			img.set_pixel(x, y, c)
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


## 径向渐变贴图：中心亮/边暗（alpha 渐变），用于加色光池。
static func _radial_texture(cr: float, cg: float, cb: float, edge := 0.0) -> ImageTexture:
	var size := 128
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	for y in size:
		for x in size:
			var u := (float(x) + 0.5 - size * 0.5) / (size * 0.5)
			var v := (float(y) + 0.5 - size * 0.5) / (size * 0.5)
			var r := sqrt(u * u + v * v)
			var a := pow(clampf(1.0 - r, 0.0, 1.0), 2.0)
			img.set_pixel(x, y, Color(cr, cg, cb, a))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


# ---------------------------------------------------------------------------
# showcase car
# ---------------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if holder == null:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_dragging = event.pressed
	elif event is InputEventMouseMotion and _dragging:
		holder.rotation.y += (event as InputEventMouseMotion).relative.x * DRAG_SENSITIVITY


func show_car(car_id: String) -> void:
	var same_car := holder != null and car_id == current_car_id
	var kept_yaw := holder.rotation.y if same_car else 0.0
	current_car_id = car_id
	if holder != null:
		holder.visible = false
		holder.queue_free()
		holder = null
	holder = Node3D.new()
	holder.name = "ShowcaseCar"
	holder.rotation.y = kept_yaw
	add_child(holder)
	var spec := Garage.effective_spec(car_id)
	if spec.is_empty():
		spec = GameData.car(String(GameData.cars_specs[0].get("id", "")))
	var result := CarVisual.build(spec, holder)
	var model := result["model"] as Node3D
	if model != null:
		GarageLook.apply(model, car_id, Garage.config(car_id))
		if not same_car:
			_frame_camera(model)
		_add_contact_shadow(holder, _model_aabb(model))


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