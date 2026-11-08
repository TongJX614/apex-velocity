extends RefCounted

## Replaces the flat-colored materials of the metro city model with a
## world-space projected facade shader. Building materials are picked by the
## albedo names produced by the city export (C_RRR_GGG_BBB); roads, sidewalks,
## vegetation and street furniture keep their original materials.

const SHADER := preload("res://shaders/city_facade.gdshader")
const TEX_DIR := "res://assets/thirdparty/city_ring/facades/"

const STYLE_CONCRETE := 0
const STYLE_CONCRETE_WARM := 1
const STYLE_OFFICE := 2
const STYLE_BRICK := 3
const STYLE_GLASS := 4

const STYLE_TEXTURES := {
	STYLE_CONCRETE: "facade_concrete.png",
	STYLE_CONCRETE_WARM: "facade_concrete_warm.png",
	STYLE_OFFICE: "facade_office.png",
	STYLE_BRICK: "facade_brick.png",
	STYLE_GLASS: "facade_glass.png",
}

const STYLE_PARAMS := {
	STYLE_CONCRETE: {"wall_rough": 0.90, "window_rough": 0.17, "window_metal": 0.15, "lit": 0.10},
	STYLE_CONCRETE_WARM: {"wall_rough": 0.93, "window_rough": 0.19, "window_metal": 0.12, "lit": 0.10},
	STYLE_OFFICE: {"wall_rough": 0.76, "window_rough": 0.12, "window_metal": 0.30, "lit": 0.14},
	STYLE_BRICK: {"wall_rough": 0.96, "window_rough": 0.21, "window_metal": 0.08, "lit": 0.09},
	STYLE_GLASS: {"wall_rough": 0.52, "window_rough": 0.075, "window_metal": 0.58, "lit": 0.05},
}

# material name (before a possible .001 suffix) -> facade style pool.
# Whites dominate the city model; dark materials are the glass towers.
const MATERIAL_STYLES := {
	"C_204_204_204": [STYLE_CONCRETE, STYLE_CONCRETE, STYLE_OFFICE, STYLE_CONCRETE_WARM],
	"C_255_255_255": [STYLE_CONCRETE, STYLE_CONCRETE, STYLE_OFFICE],
	"C_224_224_224": [STYLE_CONCRETE, STYLE_CONCRETE, STYLE_OFFICE],
	"C_255_237_237": [STYLE_CONCRETE, STYLE_CONCRETE_WARM],
	"C_052_042_042": [STYLE_BRICK, STYLE_BRICK, STYLE_CONCRETE_WARM],
	"C_124_102_092": [STYLE_BRICK, STYLE_BRICK, STYLE_CONCRETE_WARM],
	"C_108_076_062": [STYLE_BRICK, STYLE_CONCRETE_WARM],
	"C_103_086_070": [STYLE_BRICK, STYLE_CONCRETE_WARM],
	"C_074_058_034": [STYLE_BRICK, STYLE_CONCRETE_WARM],
	"C_021_016_011": [STYLE_BRICK, STYLE_CONCRETE_WARM],
	"C_061_061_061": [STYLE_CONCRETE, STYLE_OFFICE],
	"C_080_080_080": [STYLE_CONCRETE, STYLE_OFFICE],
	"C_072_072_072": [STYLE_CONCRETE, STYLE_CONCRETE_WARM],
	"C_050_050_050": [STYLE_CONCRETE, STYLE_OFFICE],
	"C_127_127_127": [STYLE_CONCRETE, STYLE_CONCRETE_WARM],
	"C_133_133_133": [STYLE_CONCRETE, STYLE_CONCRETE_WARM],
	"C_019_019_019": [STYLE_CONCRETE, STYLE_OFFICE],
	"C_029_029_029": [STYLE_CONCRETE, STYLE_CONCRETE_WARM],
	"C_003_003_003": [STYLE_GLASS],
	"C_004_005_006": [STYLE_GLASS],
	"C_005_007_009": [STYLE_GLASS],
	"C_006_008_010": [STYLE_GLASS],
	"C_002_002_002": [STYLE_GLASS],
	"C_013_013_013": [STYLE_GLASS],
	"C_002_009_024": [STYLE_GLASS],
	"C_007_007_007": [STYLE_GLASS],
	"C_004_004_017": [STYLE_GLASS],
	"C_010_018_049": [STYLE_CONCRETE, STYLE_CONCRETE_WARM],
	"C_010_049_030": [STYLE_CONCRETE, STYLE_CONCRETE_WARM],
	"C_123_040_010": [STYLE_CONCRETE, STYLE_CONCRETE_WARM],
	"C_049_010_012": [STYLE_CONCRETE, STYLE_CONCRETE_WARM],
	"C_100_017_108": [STYLE_CONCRETE, STYLE_CONCRETE_WARM],
	"C_108_002_002": [STYLE_CONCRETE, STYLE_CONCRETE_WARM],
	# 浅灰/白色块：郊区小楼与独立住宅，之前漏掉会保持一块纯白石膏
	"C_163_163_163": [STYLE_CONCRETE, STYLE_CONCRETE_WARM],
	"C_153_153_153": [STYLE_CONCRETE, STYLE_OFFICE],
	"C_109_105_088": [STYLE_CONCRETE, STYLE_CONCRETE_WARM],
	"C_101_101_101": [STYLE_CONCRETE, STYLE_OFFICE],
	"C_082_082_082": [STYLE_CONCRETE, STYLE_CONCRETE_WARM],
	"C_071_071_079": [STYLE_CONCRETE, STYLE_OFFICE],
	"C_056_056_056": [STYLE_CONCRETE, STYLE_CONCRETE_WARM],
	"C_055_055_055": [STYLE_CONCRETE],
	"C_053_053_053": [STYLE_CONCRETE, STYLE_CONCRETE_WARM],
	"C_040_040_040": [STYLE_CONCRETE, STYLE_OFFICE],
	"C_032_027_024": [STYLE_CONCRETE_WARM, STYLE_BRICK],
	"C_030_030_030": [STYLE_CONCRETE, STYLE_CONCRETE_WARM],
	"C_024_024_028": [STYLE_CONCRETE, STYLE_OFFICE],
	"C_024_024_024": [STYLE_CONCRETE, STYLE_OFFICE],
	"C_020_016_014": [STYLE_CONCRETE_WARM],
	"C_014_014_014": [STYLE_CONCRETE],
	"C_012_012_012": [STYLE_CONCRETE],
	"C_011_011_011": [STYLE_CONCRETE],
	"C_010_010_010": [STYLE_CONCRETE, STYLE_OFFICE],
	"C_023_013_006": [STYLE_CONCRETE_WARM, STYLE_BRICK],
	"C_065_041_021": [STYLE_CONCRETE_WARM],
	"C_031_000_000": [STYLE_CONCRETE_WARM],
	"C_036_001_001": [STYLE_BRICK],
	"C_138_087_002": [STYLE_CONCRETE_WARM],
}

# 城市模型里成片的草地/绿化地面（2048m 郊区环、街道垫层、公园）。
# 这些面只有一个纯绿色 albedo，用世界三平面草地 PBR 铺一遍。
const GROUND_MATERIALS := ["C_001_027_002"]

# Materials used by flat decks and roofs (stadium roof, mall roofs, parking
# garage slabs, elevated plazas). Only their up-facing surfaces are textured;
# walls keep the original flat color so sidewalks and curbs stay untouched.
const ROOF_ONLY_MATERIALS := [
	"C_036_036_036",
	"C_137_137_137",
	"C_057_050_042",
	"C_039_039_039",
	"C_009_009_009",
	"C_147_130_117",
	"C_071_071_071",
]

static var _textures: Dictionary = {}
static var _materials: Dictionary = {}
static var _storefront: Texture2D = null
static var _roof: Texture2D = null
static var _pavement: Texture2D = null
static var _detail := 1.0
static var _ground: StandardMaterial3D = null


## 画质档 → 立面程序化细节强度（窗框/凹窗/空调/阳台）。
## 低档完全关掉，只留贴图，保住楼群满屏时的像素开销。
static func set_detail(index: int) -> void:
	_detail = [0.0, 0.55, 0.82, 1.0][clampi(index, 0, 3)]
	for mat in _materials.values():
		(mat as ShaderMaterial).set_shader_parameter("detail_amt", _detail)


static func apply(root: Node) -> int:
	if root == null or root.has_meta("city_facades_applied"):
		return 0
	if not _looks_like_city(root):
		return 0
	root.set_meta("city_facades_applied", true)

	var applied := 0
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.append(child)
		if not node is MeshInstance3D:
			continue
		var mi := node as MeshInstance3D
		if mi.mesh == null or mi.has_meta("city_facades_applied"):
			continue
		var mesh := mi.mesh
		var touched := false
		for si in mesh.get_surface_count():
			var src := mesh.surface_get_material(si)
			if not (src is StandardMaterial3D):
				continue
			var base := src as StandardMaterial3D
			var mat_key := _normalized_name(base)
			if GROUND_MATERIALS.has(mat_key):
				mi.set_surface_override_material(si, _ground_material())
				applied += 1
				touched = true
				continue
			var style := -1
			var roof_only := false
			if ROOF_ONLY_MATERIALS.has(mat_key):
				roof_only = true
			elif not MATERIAL_STYLES.has(mat_key):
				continue
			var existing := mi.get_surface_override_material(si)
			if existing is ShaderMaterial and (existing as ShaderMaterial).shader == SHADER:
				continue
			var hash_key := "%s|%d" % [mi.name, si]
			var h := absi(hash(hash_key))
			if roof_only:
				style = STYLE_CONCRETE
			else:
				var pool: Array = MATERIAL_STYLES[mat_key]
				style = pool[h % pool.size()]
			var variant: int = (h / 7) % 8
			var shader_mat := _material_for(mat_key, base.albedo_color, style, variant, h, roof_only)
			mi.set_surface_override_material(si, shader_mat)
			applied += 1
			touched = true
		if touched:
			mi.set_meta("city_facades_applied", true)
	if applied > 0:
		print("[CITY-FACADE] textured %d surfaces under %s" % [applied, root.name])
	return applied


static func _looks_like_city(root: Node) -> bool:
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var nm := String(node.name)
		if nm.begins_with("City_") or nm.begins_with("Big_"):
			return true
	return false


static func _normalized_name(mat: StandardMaterial3D) -> String:
	var key := String(mat.resource_name)
	var dot := key.find(".")
	if dot > 0:
		key = key.substr(0, dot)
	return key


static func _ground_material() -> StandardMaterial3D:
	if _ground != null:
		return _ground
	var base := "res://assets/thirdparty/polyhaven/textures/aerial_grass_rock/aerial_grass_rock_"
	var mat := StandardMaterial3D.new()
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	var diff := load(base + "diff.jpg") as Texture2D
	if diff != null:
		mat.albedo_texture = diff
	var nor := load(base + "nor.jpg") as Texture2D
	if nor != null:
		mat.normal_enabled = true
		mat.normal_texture = nor
		mat.normal_scale = 0.55
	mat.uv1_triplanar = true
	mat.uv1_world_triplanar = true
	mat.uv1_scale = Vector3(0.12, 0.12, 0.12)
	mat.albedo_color = Color(0.66, 0.80, 0.58)
	mat.roughness = 0.97
	_ground = mat
	return mat


static func _facade_texture(style: int) -> Texture2D:
	if _textures.has(style):
		return _textures[style]
	var path := TEX_DIR + String(STYLE_TEXTURES[style])
	var tex := load(path) as Texture2D
	if tex == null:
		push_error("CityFacades: missing %s" % path)
	_textures[style] = tex
	return tex


static func _shared_texture(kind: String) -> Texture2D:
	if kind == "storefront":
		if _storefront == null:
			_storefront = load(TEX_DIR + "storefront.png") as Texture2D
		return _storefront
	if kind == "pavement":
		if _pavement == null:
			_pavement = load(TEX_DIR + "pavement.png") as Texture2D
		return _pavement
	if _roof == null:
		_roof = load(TEX_DIR + "roof.png") as Texture2D
	return _roof


static func _material_for(mat_key: String, base_color: Color, style: int, variant: int, h: int, roof_only := false) -> ShaderMaterial:
	var cache_key := "%s|%d|%d|%s" % [mat_key, style, variant, roof_only]
	if _materials.has(cache_key):
		return _materials[cache_key]
	var mat := ShaderMaterial.new()
	mat.shader = SHADER
	var params: Dictionary = STYLE_PARAMS[style]
	var rng := RandomNumberGenerator.new()
	rng.seed = h
	mat.set_shader_parameter("base_color", base_color)
	mat.set_shader_parameter("facade_tint", _tint_for(base_color, style, variant))
	mat.set_shader_parameter("facade_tex", _facade_texture(style))
	mat.set_shader_parameter("storefront_tex", _shared_texture("storefront"))
	mat.set_shader_parameter("roof_tex", _shared_texture("roof"))
	mat.set_shader_parameter("pavement_tex", _shared_texture("pavement"))
	mat.set_shader_parameter("wall_rough", float(params["wall_rough"]))
	mat.set_shader_parameter("window_rough", float(params["window_rough"]))
	mat.set_shader_parameter("window_metal", float(params["window_metal"]))
	mat.set_shader_parameter("lit_chance", float(params["lit"]))
	mat.set_shader_parameter("facade_offset", Vector2(rng.randf(), rng.randf()))
	mat.set_shader_parameter("storefront_offset", Vector2(rng.randf(), 0.0))
	mat.set_shader_parameter("roof_offset", Vector2(rng.randf(), rng.randf()))
	mat.set_shader_parameter("seed", rng.randf_range(0.0, 1.0))
	mat.set_shader_parameter("detail_amt", _detail)
	if roof_only:
		mat.set_shader_parameter("roof_only", 1.0)
		mat.set_shader_parameter("wall_rough", 0.82)
	_materials[cache_key] = mat
	return mat


static func _tint_for(base_color: Color, style: int, variant: int) -> Color:
	var lin := base_color.srgb_to_linear()
	var lum := lin.get_luminance()
	var tint: Color
	if style == STYLE_GLASS:
		# dark glass stays readable: lift the base color toward a cool sky tone
		tint = Color(
			minf(0.40 + lin.r * 2.4, 0.90),
			minf(0.46 + lin.g * 2.0, 0.92),
			minf(0.53 + lin.b * 1.4, 0.95))
	else:
		# keep the original wall albedo: normalize the material luminance
		var target := clampf(lum * 1.30 + 0.12, 0.24, 0.96)
		var scale := target / maxf(lum, 0.035)
		tint = Color(
			minf(lin.r * scale, 0.98),
			minf(lin.g * scale, 0.98),
			minf(lin.b * scale, 0.98))
	var jitter := 0.94 + 0.03 * float(variant)
	tint = Color(tint.r * jitter, tint.g * jitter, tint.b * jitter, 1.0)
	return tint.linear_to_srgb()
