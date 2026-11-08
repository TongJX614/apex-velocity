class_name WeatherFX
extends Node3D
## Weather particles driven by the legacy theme's `weather` field:
## rain (city), snow (alpine/glacier), dust (canyon/magma). The emitter follows
## the player so the weather always surrounds the action.

var kind := "none"
var particles: GPUParticles3D
var _follow: Node3D


func setup(weather: String, theme: Dictionary, follow_target: Node3D) -> void:
	kind = weather
	_follow = follow_target
	visible = kind != "none"
	if kind == "none" or kind.is_empty():
		return
	particles = GPUParticles3D.new()
	particles.name = "WeatherParticles"
	particles.local_coords = false
	particles.visibility_aabb = AABB(Vector3(-70.0, -30.0, -70.0), Vector3(140.0, 70.0, 140.0))
	particles.draw_order = GPUParticles3D.DRAW_ORDER_VIEW_DEPTH

	var quad := QuadMesh.new()
	var mat := StandardMaterial3D.new()
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
			quad.size = Vector2(0.024, 1.0)
			mat.albedo_color = Color(0.66, 0.77, 0.92, 0.34)
			particles.amount = int(2400 * Settings.particle_scale())
			particles.lifetime = 1.0
			particles.preprocess = 0.5
			proc.emission_box_extents = Vector3(48.0, 14.0, 48.0)
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

	quad.material = mat
	particles.process_material = proc
	particles.draw_pass_1 = quad
	particles.emitting = true
	add_child(particles)


func _soft_dot_texture() -> Texture2D:
	var img := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	for y in 64:
		for x in 64:
			var d := Vector2(float(x) - 31.5, float(y) - 31.5).length() / 31.5
			var a := clampf(1.0 - d, 0.0, 1.0)
			a = a * a * (3.0 - 2.0 * a)
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, a))
	return ImageTexture.create_from_image(img)


func _streak_texture() -> Texture2D:
	var img := Image.create(8, 64, false, Image.FORMAT_RGBA8)
	for y in 64:
		var t := float(y) / 63.0
		var a := pow(1.0 - absf(t - 0.5) * 2.0, 1.6)
		img.set_pixel(1, y, Color(1.0, 1.0, 1.0, a))
	return ImageTexture.create_from_image(img)


func _spawn_rain_splashes() -> void:
	var splash := GPUParticles3D.new()
	splash.name = "RainSplashes"
	splash.local_coords = false
	splash.visibility_aabb = AABB(Vector3(-40.0, -6.0, -40.0), Vector3(80.0, 12.0, 80.0))
	var mesh := QuadMesh.new()
	mesh.size = Vector2(0.16, 0.10)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = Color(0.82, 0.88, 0.95, 0.55)
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
	splash.amount = int(700 * Settings.particle_scale())
	splash.lifetime = 0.32
	splash.preprocess = 0.2
	splash.emitting = true
	splash.position = Vector3(0.0, -7.4, 0.0)
	add_child(splash)


func _process(_dt: float) -> void:
	if _follow == null or kind == "none":
		return
	global_position = _follow.global_position + Vector3(0.0, 7.5, 0.0)
