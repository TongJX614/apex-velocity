class_name SunGlare
extends Node3D
## 太阳/月亮眩光：核心光斑 + 全屏薄雾 + 横向拉丝 + 镜头鬼影。
## 全部是带深度测试的 3D 自发光面片：被山体、建筑挡住会自然消失，
## 不需要屏幕空间遮挡检测；每帧跟随当前相机，位置固定在无穷远。
## 面片亮度 >1 会进入 Environment 的 Glow，形成真正的“炫光”。

const DISTANCE := 2600.0
const GHOST_FRACTIONS: Array[float] = [0.46, 0.68, 0.86]
const GHOST_DEGREES: Array[float] = [4.2, 2.5, 1.7]

var sun_dir := Vector3(0.3, 0.4, -1.0)
var intensity := 0.0
var tint := Color(1.0, 0.93, 0.82)

var _veil: MeshInstance3D
var _core: MeshInstance3D
var _streak: MeshInstance3D
var _ghosts: Array[MeshInstance3D] = []
var _veil_mat: StandardMaterial3D
var _core_mat: StandardMaterial3D
var _streak_mat: StandardMaterial3D
var _ghost_mats: Array[StandardMaterial3D] = []
var _screen_layer: CanvasLayer
var _screen_mat: ShaderMaterial

const SCREEN_GLARE_SHADER := """shader_type canvas_item;
render_mode blend_add, unshaded;
uniform vec2 sun_uv = vec2(0.5, 0.5);
uniform float strength = 0.0;
uniform vec3 tint = vec3(1.0, 0.9, 0.75);
uniform float aspect = 1.777;
void fragment() {
	vec2 p = (SCREEN_UV - 0.5) * vec2(aspect, 1.0);
	vec2 s = (sun_uv - 0.5) * vec2(aspect, 1.0);
	float r = length(p - s);
	// 镜头内的迎光薄雾：越靠近太阳越亮，覆盖整屏，山体挡住日轮也还在。
	float veil = exp(-r * r * 1.7) * 0.55 + exp(-r * 1.25) * 0.10;
	vec3 col = tint * veil;
	// 镜头鬼影：太阳与画面中心的连线上排三颗虚影。
	float ghosts = 0.0;
	for (int i = 0; i < 3; i++) {
		vec2 gp = s * (0.52 + float(i) * 0.16);
		float gr = length(p - gp);
		float rad = 0.026 + float(i) * 0.012;
		ghosts += smoothstep(rad, rad * 0.45, gr) * (0.12 - float(i) * 0.03);
	}
	col += tint * ghosts;
	COLOR = vec4(col * strength, 1.0);
}"""

static var _tex_veil: Texture2D
static var _tex_core: Texture2D
static var _tex_streak: Texture2D
static var _tex_ghost: Texture2D


func _ready() -> void:
	_tex_veil = _radial_texture(192, 2.2)
	_tex_core = _radial_texture(128, 4.5)
	_tex_streak = _streak_texture(256, 36)
	_tex_ghost = _ring_texture(96)
	_veil = _quad(_tex_veil, _angular_size(34.0))
	_veil_mat = _veil.material_override as StandardMaterial3D
	_veil_mat.render_priority = 1
	_core = _quad(_tex_core, _angular_size(8.0))
	_core_mat = _core.material_override as StandardMaterial3D
	_core_mat.render_priority = 3
	_streak = _quad(_tex_streak, _angular_size(46.0), 0.24)
	_streak_mat = _streak.material_override as StandardMaterial3D
	_streak_mat.render_priority = 2
	for i in GHOST_FRACTIONS.size():
		var g := _quad(_tex_ghost, _angular_size(GHOST_DEGREES[i]))
		var gm := g.material_override as StandardMaterial3D
		gm.render_priority = 2
		_ghosts.append(g)
		_ghost_mats.append(gm)
	# 屏幕空间迎光薄雾 + 镜头鬼影：放在负图层，压在世界之上、HUD 之下。
	_screen_layer = CanvasLayer.new()
	_screen_layer.name = "ScreenGlare"
	_screen_layer.layer = -1
	add_child(_screen_layer)
	var rect := ColorRect.new()
	rect.name = "ScreenGlareRect"
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.color = Color(1, 1, 1, 1)
	_screen_mat = ShaderMaterial.new()
	var shader := Shader.new()
	shader.code = SCREEN_GLARE_SHADER
	_screen_mat.shader = shader
	rect.material = _screen_mat
	_screen_layer.add_child(rect)
	_screen_layer.visible = false
	visible = false


func setup(dir: Vector3, color: Color, strength: float) -> void:
	sun_dir = dir.normalized()
	tint = color
	intensity = clampf(strength, 0.0, 2.0)
	visible = intensity > 0.002
	if not visible and _screen_layer != null:
		_screen_layer.visible = false


func _process(_dt: float) -> void:
	if not visible:
		if _screen_layer != null:
			_screen_layer.visible = false
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var cam_pos := cam.global_position
	var sun_pos := cam_pos + sun_dir * DISTANCE
	_veil.global_position = sun_pos
	_core.global_position = sun_pos
	_streak.global_position = sun_pos
	for i in _ghosts.size():
		_ghosts[i].global_position = cam_pos.lerp(sun_pos, GHOST_FRACTIONS[i])
	# 相机越正对太阳越亮；侧对/背对时自然淡出。
	var facing := clampf((-cam.global_transform.basis.z).dot(sun_dir), 0.0, 1.0)
	var k := smoothstep(0.18, 0.72, facing) * intensity
	if k <= 0.003:
		return
	_veil_mat.albedo_color = Color(tint.r, tint.g, tint.b, k * 0.5)
	_core_mat.albedo_color = Color(
		tint.r * 2.6, tint.g * 2.3, tint.b * 1.9, k * 0.95)
	_streak_mat.albedo_color = Color(
		tint.r * 1.5, tint.g * 1.35, tint.b * 1.15, k * 0.62)
	for i in _ghost_mats.size():
		var w := 0.30 - float(i) * 0.06
		_ghost_mats[i].albedo_color = Color(tint.r, tint.g, tint.b, k * w)
	# 屏幕光晕：只在太阳进入画面时出现，靠边缘淡出。
	var vp_size := get_viewport().get_visible_rect().size
	var in_front := not cam.is_position_behind(sun_pos)
	var uv := cam.unproject_position(sun_pos) / vp_size if in_front else Vector2(0.5, 0.5)
	var edge := maxf(absf(uv.x - 0.5) * 2.0, absf(uv.y - 0.5) * 2.0)
	var on_screen := clampf(1.0 - smoothstep(0.9, 1.3, edge), 0.0, 1.0) if in_front else 0.0
	var screen_strength := k * 0.34 * on_screen
	_screen_layer.visible = screen_strength > 0.002
	if _screen_layer.visible:
		_screen_mat.set_shader_parameter("sun_uv", uv)
		_screen_mat.set_shader_parameter("strength", screen_strength)
		_screen_mat.set_shader_parameter("tint", Vector3(tint.r, tint.g, tint.b))
		_screen_mat.set_shader_parameter("aspect", vp_size.x / maxf(vp_size.y, 1.0))


func _quad(tex: Texture2D, width: float, height_ratio := 1.0, priority := 1) -> MeshInstance3D:
	var quad := QuadMesh.new()
	quad.size = Vector2(width, width * height_ratio)
	var mat := _glow_material(tex)
	mat.render_priority = priority
	var mi := MeshInstance3D.new()
	mi.mesh = quad
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	add_child(mi)
	return mi


static func _angular_size(degrees: float) -> float:
	return 2.0 * DISTANCE * tan(deg_to_rad(degrees) * 0.5)


static func _glow_material(tex: Texture2D) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.billboard_keep_scale = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.disable_receive_shadows = true
	mat.disable_fog = true
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	mat.albedo_texture = tex
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	return mat


static func _radial_texture(n: int, power: float) -> Texture2D:
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var half := float(n) * 0.5
	for y in n:
		for x in n:
			var u := (float(x) + 0.5 - half) / half
			var v := (float(y) + 0.5 - half) / half
			var r := sqrt(u * u + v * v)
			# 到贴图边缘必须衰减到 0，否则大面片的方形边界会露出来。
			var a := pow(clampf(1.0 - r, 0.0, 1.0), power)
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, a))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


static func _streak_texture(w: int, h: int) -> Texture2D:
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	var half_w := float(w) * 0.5
	var half_h := float(h) * 0.5
	for y in h:
		for x in w:
			var u := absf((float(x) + 0.5 - half_w) / half_w)
			var v := absf((float(y) + 0.5 - half_h) / half_h)
			var across := pow(clampf(1.0 - v, 0.0, 1.0), 5.0)
			var along := pow(clampf(1.0 - u * u, 0.0, 1.0), 1.7)
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, across * along))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


static func _ring_texture(n: int) -> Texture2D:
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var half := float(n) * 0.5
	for y in n:
		for x in n:
			var u := (float(x) + 0.5 - half) / half
			var v := (float(y) + 0.5 - half) / half
			var r := sqrt(u * u + v * v)
			var ring := smoothstep(0.62, 0.9, r) * (1.0 - smoothstep(0.9, 1.0, r))
			var fill := pow(clampf(1.0 - r, 0.0, 1.0), 3.0) * 0.30
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, clampf(ring * 0.55 + fill, 0.0, 1.0)))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)