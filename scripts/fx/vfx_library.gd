class_name VfxLibrary
extends RefCounted
## 程序化高质量 VFX 贴图/材质（烟雾、火焰、火花），不依赖外部下载。
## 全部用 Image/NoiseTexture 生成并缓存；headless 下也安全。

static var _smoke: Texture2D
static var _flame: Texture2D
static var _spark: Texture2D
static var _nitro_vignette: Texture2D
static var _nitro_streaks: Texture2D
static var _nitro_flash: Texture2D
static var _smoke_mat: StandardMaterial3D
static var _flame_mat: ShaderMaterial


static func smoke_texture() -> Texture2D:
	if _smoke != null:
		return _smoke
	var n := 128
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var noise := FastNoiseLite.new()
	noise.seed = 7311
	noise.frequency = 0.035
	noise.fractal_octaves = 4
	for y in n:
		for x in n:
			var u := (float(x) + 0.5) / float(n) - 0.5
			var v := (float(y) + 0.5) / float(n) - 0.5
			var r := sqrt(u * u + v * v) * 2.0
			var falloff := clampf(1.0 - r, 0.0, 1.0)
			falloff = pow(falloff, 1.55)
			var nv := (noise.get_noise_2d(float(x) * 1.15, float(y) * 1.15) + 1.0) * 0.5
			var a := falloff * (0.42 + 0.58 * nv)
			var c := 0.72 + 0.22 * nv
			img.set_pixel(x, y, Color(c, c * 0.99, c * 0.98, a))
	img.generate_mipmaps()
	_smoke = ImageTexture.create_from_image(img)
	return _smoke


static func flame_texture() -> Texture2D:
	if _flame != null:
		return _flame
	var w := 96
	var h := 192
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	var noise := FastNoiseLite.new()
	noise.seed = 913
	noise.frequency = 0.06
	noise.fractal_octaves = 3
	for y in h:
		for x in w:
			var u := (float(x) + 0.5) / float(w)
			var v := (float(y) + 0.5) / float(h)  # 0 top ... 1 bottom (nozzle)
			var core := smoothstep(0.5, 0.18, absf(u - 0.5) * 2.0)
			var shape := pow(clampf(1.0 - v, 0.0, 1.0), 0.55)
			var nv := (noise.get_noise_2d(float(x) * 1.0, float(y) * 1.3 + float(Time.get_ticks_msec()) * 0.0) + 1.0) * 0.5
			var a := clampf(core * shape * (0.55 + 0.7 * nv), 0.0, 1.0)
			var c := Color(1.0, 0.55, 0.18).lerp(Color(0.62, 0.84, 1.0), core * (1.0 - v) * 0.85)
			img.set_pixel(x, y, Color(c.r, c.g, c.b, a))
	img.generate_mipmaps()
	_flame = ImageTexture.create_from_image(img)
	return _flame


static func spark_texture() -> Texture2D:
	if _spark != null:
		return _spark
	var n := 32
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in n:
		for x in n:
			var u := (float(x) + 0.5) / float(n) - 0.5
			var v := (float(y) + 0.5) / float(n) - 0.5
			var r := sqrt(u * u + v * v) * 2.0
			var a := clampf(1.0 - r, 0.0, 1.0)
			a = pow(a, 2.2)
			img.set_pixel(x, y, Color(1.0, 0.82, 0.35, a))
	img.generate_mipmaps()
	_spark = ImageTexture.create_from_image(img)
	return _spark


## 氮气全屏边缘蓝光：中心透明，四周向内渐亮的冷蓝渐晕。
static func nitro_vignette_texture() -> Texture2D:
	if _nitro_vignette != null:
		return _nitro_vignette
	var n := 128
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in n:
		for x in n:
			var u := (float(x) + 0.5) / float(n) * 2.0 - 1.0
			var v := (float(y) + 0.5) / float(n) * 2.0 - 1.0
			var r := sqrt(u * u + v * v)
			var edge := smoothstep(0.40, 1.26, r)
			var a := pow(edge, 1.7) * 0.92
			img.set_pixel(x, y, Color(0.16, 0.50, 1.0, a))
	img.generate_mipmaps()
	_nitro_vignette = ImageTexture.create_from_image(img)
	return _nitro_vignette


## 氮气冲刺速度线：中心透明、四周放射状条纹，叠加在画面中心制造“往前窜”的错觉。
static func nitro_streak_texture() -> Texture2D:
	if _nitro_streaks != null:
		return _nitro_streaks
	var n := 256
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in n:
		for x in n:
			var u := (float(x) + 0.5) / float(n) * 2.0 - 1.0
			var v := (float(y) + 0.5) / float(n) * 2.0 - 1.0
			var r := sqrt(u * u + v * v)
			var ang := atan2(v, u)
			var streak := 0.5 + 0.5 * sin(ang * 36.0 + 2.2 * sin(ang * 7.0 + 1.7))
			streak = pow(streak, 6.0)
			var radial := smoothstep(0.34, 1.10, r) * (1.0 - smoothstep(1.05, 1.38, r))
			var a := radial * (0.05 + 0.95 * streak) * 0.52
			img.set_pixel(x, y, Color(0.36, 0.68, 1.0, a))
	img.generate_mipmaps()
	_nitro_streaks = ImageTexture.create_from_image(img)
	return _nitro_streaks


## 氮气脉冲中心光斑：每次“噗”的瞬时冲击感。
static func nitro_flash_texture() -> Texture2D:
	if _nitro_flash != null:
		return _nitro_flash
	var n := 96
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in n:
		for x in n:
			var u := (float(x) + 0.5) / float(n) - 0.5
			var v := (float(y) + 0.5) / float(n) - 0.5
			var r := sqrt(u * u + v * v) * 2.0
			var a := pow(clampf(1.0 - r, 0.0, 1.0), 2.8) * 0.95
			img.set_pixel(x, y, Color(0.62, 0.84, 1.0, a))
	img.generate_mipmaps()
	_nitro_flash = ImageTexture.create_from_image(img)
	return _nitro_flash


static func smoke_material(additive := false) -> StandardMaterial3D:
	if _smoke_mat != null and not additive:
		return _smoke_mat
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.billboard_keep_scale = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.disable_receive_shadows = true
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	mat.vertex_color_use_as_albedo = true
	mat.albedo_texture = smoke_texture()
	mat.albedo_color = Color(1, 1, 1, 1)
	if additive:
		mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	else:
		_smoke_mat = mat
	return mat


static func flame_material() -> ShaderMaterial:
	if _flame_mat != null:
		return _flame_mat
	var shader := Shader.new()
	shader.code = """shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, fog_disabled;
uniform sampler2D flame_tex : hint_default_white;
uniform float intensity = 1.0;
uniform vec4 tint : source_color = vec4(1.0, 0.85, 0.55, 1.0);
void fragment() {
	vec2 uv = UV;
	float n = texture(flame_tex, uv * vec2(1.0, 1.0)).r;
	vec4 f = texture(flame_tex, uv);
	float flick = 0.82 + 0.18 * sin(TIME * 42.0 + uv.y * 18.0);
	ALBEDO = f.rgb * tint.rgb * intensity * flick * 1.35;
	ALPHA = clamp(f.a * intensity * flick, 0.0, 1.0);
}"""
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("flame_tex", flame_texture())
	mat.set_shader_parameter("intensity", 1.0)
	return mat
