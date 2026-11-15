class_name WeatherFX
extends Node3D
## Weather particles driven by the legacy theme's `weather` field:
## rain (city), snow (alpine/glacier), dust (canyon/magma). The emitter follows
## the player so the weather always surrounds the action.

var kind := "none"
var particles: GPUParticles3D
var _follow: Node3D
var _spray: GPUParticles3D


func setup(weather: String, theme: Dictionary, follow_target: Node3D) -> void:
	kind = weather
	_follow = follow_target
	if OS.get_environment("APEX_Q_WEATHER_OFF") == "1":
		visible = false
		return
	visible = kind != "none"
	if kind == "none" or kind.is_empty():
		return
	particles = GPUParticles3D.new()
	particles.name = "WeatherParticles"
	particles.layers = 4
	particles.local_coords = false
	particles.visibility_aabb = AABB(Vector3(-70.0, -30.0, -70.0), Vector3(140.0, 70.0, 140.0))
	particles.draw_order = GPUParticles3D.DRAW_ORDER_VIEW_DEPTH

	var quad := QuadMesh.new()
	var mat := StandardMaterial3D.new()
	var quad_mat: Material = mat
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.vertex_color_use_as_albedo = false
	mat.disable_receive_shadows = true
	# 雨丝保留硬边；雪/尘用程序化柔边圆点，避免白色方块贴脸。
	var soft_dot := _soft_dot_texture()

	var proc := ParticleProcessMaterial.new()
	proc.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	proc.direction = Vector3(0.0, -1.0, 0.0)
	proc.spread = 8.0
	proc.scale_min = 0.8
	proc.scale_max = 1.2

	match kind:
		"rain":
			# 雨粒子跟随发射器（车头前方盒子）移动，避免高速行驶时旧雨丝落到
			# 相机附近变成贴脸大白条；下落速度仍由 gravity 主导。
			particles.local_coords = true
			quad.size = Vector2(0.07, 0.9)
			var rain_mat := ShaderMaterial.new()
			rain_mat.shader = load("res://shaders/rain_streak.gdshader")
			rain_mat.set_shader_parameter("rain_tex", _rain_streak_texture())
			rain_mat.set_shader_parameter("tint", Color(0.66, 0.77, 0.92, 0.50))
			rain_mat.set_shader_parameter("near_fade_start", 1.5)
			rain_mat.set_shader_parameter("near_fade_end", 4.0)
			quad_mat = rain_mat
			particles.amount = int(6500 * Settings.particle_scale())
			particles.lifetime = 0.9
			particles.preprocess = 0.45
			proc.emission_box_extents = Vector3(36.0, 12.0, 36.0)
			proc.initial_velocity_min = 30.0
			proc.initial_velocity_max = 42.0
			proc.gravity = Vector3(2.0, -24.0, 0.6)
			proc.spread = 3.5
			mat.billboard_keep_scale = true
		"snow":
			quad.size = Vector2(0.20, 0.20)
			mat.albedo_color = Color(0.95, 0.97, 1.0, 0.82)
			mat.albedo_texture = soft_dot
			mat.billboard_keep_scale = true
			particles.amount = int(900 * Settings.particle_scale())
			particles.lifetime = 5.0
			particles.preprocess = 1.5
			proc.emission_box_extents = Vector3(42.0, 16.0, 42.0)
			proc.initial_velocity_min = 1.2
			proc.initial_velocity_max = 3.2
			proc.gravity = Vector3(0.4, -1.4, 0.2)
			proc.spread = 40.0
			proc.turbulence_enabled = true
			proc.turbulence_noise_strength = 0.6
			proc.turbulence_noise_scale = 2.4
			proc.turbulence_influence_min = 0.05
			proc.turbulence_influence_max = 0.18
		"dust":
			quad.size = Vector2(0.11, 0.11)
			mat.albedo_color = Color(0.86, 0.62, 0.42, 0.42)
			mat.albedo_texture = soft_dot
			mat.billboard_keep_scale = true
			particles.amount = int(800 * Settings.particle_scale())
			particles.lifetime = 6.0
			particles.preprocess = 2.0
			proc.emission_box_extents = Vector3(48.0, 12.0, 48.0)
			proc.initial_velocity_min = 0.8
			proc.initial_velocity_max = 2.6
			proc.gravity = Vector3(0.8, -0.25, 0.3)
			proc.spread = 70.0
			proc.turbulence_enabled = true
			proc.turbulence_noise_strength = 1.0
			proc.turbulence_noise_scale = 3.0
			proc.turbulence_influence_min = 0.08
			proc.turbulence_influence_max = 0.25
		_:
			return

	quad.material = quad_mat
	particles.process_material = proc
	particles.draw_pass_1 = quad
	particles.emitting = true
	add_child(particles)
	if kind == "rain":
		_spawn_rain_splashes()
		_spawn_rain_spray()
		if OS.get_environment("APEX_Q_RAIN_STREAKS_OFF") == "1":
			particles.visible = false
		if OS.get_environment("APEX_Q_RAIN_SPLASH_OFF") == "1":
			var spl := _follow.find_child("RainSplashes", true, false)
			if spl != null:
				spl.visible = false
		if OS.get_environment("APEX_Q_RAIN_SPRAY_OFF") == "1" and _spray != null:
			_spray.visible = false


func _soft_dot_texture() -> Texture2D:
	var img := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	for y in 64:
		for x in 64:
			var d := Vector2(float(x) - 31.5, float(y) - 31.5).length() / 31.5
			var a := clampf(1.0 - d, 0.0, 1.0)
			a = a * a * (3.0 - 2.0 * a)
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, a))
	return ImageTexture.create_from_image(img)


## 雨丝贴图：中间实、两端渐隐、左右软边。比 1px 硬线更容易在 1600×900 看见，
## 又不会像一堵白墙——远处由 mipmap 自动收细。
func _rain_streak_texture() -> Texture2D:
	var w := 16
	var h := 128
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in h:
		var t := float(y) / float(h - 1)
		var vertical := smoothstep(0.0, 0.08, t) * (1.0 - smoothstep(0.80, 1.0, t))
		for x in w:
			var dx := absf(float(x) - float(w - 1) * 0.5) / (float(w - 1) * 0.5)
			var edge := 1.0 - smoothstep(0.55, 1.0, dx)
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, vertical * edge))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


func _spawn_rain_splashes() -> void:
	var splash := GPUParticles3D.new()
	splash.name = "RainSplashes"
	splash.layers = 4
	splash.local_coords = false
	splash.visibility_aabb = AABB(Vector3(-40.0, -6.0, -40.0), Vector3(80.0, 12.0, 80.0))
	var mesh := QuadMesh.new()
	mesh.size = Vector2(0.08, 0.05)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_texture = _soft_dot_texture()
	mat.albedo_color = Color(0.82, 0.88, 0.95, 0.18)
	mesh.material = mat
	var proc := ParticleProcessMaterial.new()
	proc.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	proc.emission_box_extents = Vector3(30.0, 0.2, 30.0)
	proc.direction = Vector3(0.0, 1.3, 0.0)
	proc.spread = 55.0
	proc.initial_velocity_min = 2.0
	proc.initial_velocity_max = 4.5
	proc.gravity = Vector3(0.0, -12.0, 0.0)
	proc.scale_min = 0.6
	proc.scale_max = 1.4
	splash.process_material = proc
	splash.draw_pass_1 = mesh
	splash.amount = int(220 * Settings.particle_scale())
	splash.lifetime = 0.32
	splash.preprocess = 0.2
	splash.emitting = true
	# 挂到跟随目标（玩家车/展车）上：雨体积前移后，地面溅水仍铺在车周围。
	splash.position = Vector3(0.0, 0.08, 0.0)
	_follow.add_child(splash)


func _process(_dt: float) -> void:
	if _follow == null or kind == "none":
		return
	if _follow is Car:
		var car := _follow as Car
		# 雨体积整体移到车头前方并按车头朝向旋转：追尾相机不会在镜头和车之间
		# 生成贴脸的大雨条（斜向行驶时轴对齐盒子会把相机包进角落）。
		global_rotation = Vector3(0.0, car.heading, 0.0)
		global_position = car.global_position + car.forward() * 26.0 + Vector3(0.0, 7.5, 0.0)
		if _spray != null:
			_spray.emitting = kind == "rain" and car.speed_kph > 28.0
	else:
		global_position = _follow.global_position + Vector3(0.0, 7.5, 0.0)


## 雨战后轮水雾：挂在车尾的 GPU 粒子，低速不喷、超过约 28km/h 才拖出水花。
## 只跟随玩家车，菜单展车没有 Car 类型，因此不会误开。
func _spawn_rain_spray() -> void:
	if _follow == null:
		return
	var spray := GPUParticles3D.new()
	spray.name = "RainSpray"
	spray.layers = 4
	spray.local_coords = false
	spray.visibility_aabb = AABB(Vector3(-8.0, -3.0, -14.0), Vector3(16.0, 8.0, 24.0))
	var mesh := QuadMesh.new()
	mesh.size = Vector2(0.30, 0.30)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_texture = _soft_dot_texture()
	mat.albedo_color = Color(0.72, 0.82, 0.95, 0.10)
	mesh.material = mat
	var proc := ParticleProcessMaterial.new()
	proc.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	proc.emission_box_extents = Vector3(0.85, 0.05, 0.12)
	proc.direction = Vector3(0.0, 0.25, -1.0)
	proc.spread = 20.0
	proc.initial_velocity_min = 1.8
	proc.initial_velocity_max = 3.8
	proc.gravity = Vector3(0.0, -1.8, 0.0)
	proc.scale_min = 0.7
	proc.scale_max = 1.6
	spray.process_material = proc
	spray.draw_pass_1 = mesh
	spray.amount = int(56 * Settings.particle_scale())
	spray.lifetime = 0.55
	spray.emitting = false
	spray.position = Vector3(0.0, 0.28, -1.8)
	_follow.add_child(spray)
	_spray = spray
