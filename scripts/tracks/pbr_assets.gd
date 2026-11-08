class_name PbrAssets
extends RefCounted
## 统一画风模板 · APEX VISUAL STYLE
##
## 所有地表材质只从这里取：固定 CC0 PBR 贴图、固定物理平铺尺度、统一
## mipmap + 各向异性过滤。禁止再在赛道生成代码里用随机数画"噪点贴图"，
## 那正是高速时路面变成噪点/马赛克的根因。
##
## 模板尺度（以 1024px 贴图为准）：
##   路面  : 8m × 8m 一张（横向 20m / 2.5，纵向 12m / 1.5）
##   草地  : 3.6m 一张（世界空间 UV），大平面则 320 张铺满
## 贴图本身必须由 .import 生成 mipmap 并做 VRAM 压缩，交给 GPU 硬件过滤；
## CPU 侧不再做任何逐帧纹理/顶点噪声计算。

const ROOT := "res://assets/thirdparty/polyhaven/"

# --- 固定模板常量 ---------------------------------------------------------
const ROAD_TILE_METERS := 8.0
const ROAD_V_METERS := 12.0
const ROAD_UV_SCALE := Vector2(2.5, 1.5)
const WORLD_TILE_METERS := 3.6
const GRASS_PLANE_UV := Vector2(320.0, 320.0)

const ASPHALT_DIFF := "textures/asphalt_02/asphalt_02_diff.jpg"
const ASPHALT_NOR := "textures/asphalt_02/asphalt_02_nor.jpg"
const ASPHALT_ROUGH := "textures/asphalt_02/asphalt_02_rough.jpg"


static func tex(path: String) -> Texture2D:
	if path.is_empty():
		return null
	var full := ROOT + path
	if not ResourceLoader.exists(full):
		return null
	return load(full)


static func material(albedo: String, normal: String = "", rough: String = "",
		uv_scale: Vector2 = Vector2.ONE, tint: Color = Color.WHITE) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	# 统一过滤模板：线性 mipmap + 各向异性，远处高频纹理由 GPU 平滑降采样
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	var albedo_tex := tex(albedo)
	if albedo_tex != null:
		mat.albedo_texture = albedo_tex
	mat.albedo_color = tint
	var normal_tex := tex(normal)
	if normal_tex != null:
		mat.normal_enabled = true
		mat.normal_texture = normal_tex
		mat.normal_scale = 0.72
	var rough_tex := tex(rough)
	if rough_tex != null:
		mat.roughness_texture = rough_tex
		mat.roughness = 1.0
	mat.uv1_scale = Vector3(uv_scale.x, uv_scale.y, 1.0)
	return mat


## 路面唯一模板：固定沥青 PBR 三件套 + 8m 物理平铺 + 低强度法线。
static func road() -> StandardMaterial3D:
	var mat := material(ASPHALT_DIFF, ASPHALT_NOR, ASPHALT_ROUGH, ROAD_UV_SCALE)
	mat.albedo_color = Color(0.78, 0.785, 0.79)
	mat.normal_scale = 0.55
	mat.roughness = 0.92
	mat.metallic = 0.0
	return mat


static func asphalt() -> StandardMaterial3D:
	return road()


## 世界空间 UV 的丘陵/地形：网格已经按 3.6m 铺好，材质不要再放大 UV。
static func grass_world() -> StandardMaterial3D:
	var mat := grass()
	mat.uv1_scale = Vector3.ONE
	return mat


## UV 0..1 的大平面：按 320 次平铺。
static func grass_plane() -> StandardMaterial3D:
	return grass()


static func grass() -> StandardMaterial3D:
	return material(
		"textures/aerial_grass_rock/aerial_grass_rock_diff.jpg",
		"textures/aerial_grass_rock/aerial_grass_rock_nor.jpg",
		"textures/aerial_grass_rock/aerial_grass_rock_rough.jpg",
		GRASS_PLANE_UV)


static func sand() -> StandardMaterial3D:
	return material(
		"textures/coast_sand_01/coast_sand_01_diff.jpg",
		"textures/coast_sand_01/coast_sand_01_nor.jpg",
		"textures/coast_sand_01/coast_sand_01_rough.jpg",
		GRASS_PLANE_UV)


static func building_tile(uv_scale: Vector2, night: bool = false) -> StandardMaterial3D:
	var base := "res://assets/venues/facade_real_modular_urban_apartments_facade_objects_"
	var mat := StandardMaterial3D.new()
	if ResourceLoader.exists(base + "diff_1k.jpg"):
		mat.albedo_texture = load(base + "diff_1k.jpg")
	if ResourceLoader.exists(base + "nor_gl_1k.jpg"):
		mat.normal_enabled = true
		mat.normal_texture = load(base + "nor_gl_1k.jpg")
	mat.roughness = 0.82
	mat.uv1_scale = Vector3(uv_scale.x, uv_scale.y, 1.0)
	if night:
		mat.emission_enabled = true
		mat.emission_texture = mat.albedo_texture
		mat.emission = Color(1.0, 0.82, 0.58)
		mat.emission_energy_multiplier = 1.05
	return mat


static func snow() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.93, 0.95, 1.0)
	mat.roughness = 0.86
	mat.metallic = 0.0
	return mat


static func concrete(uv_scale: Vector2 = Vector2(2.0, 2.0)) -> StandardMaterial3D:
	return material(
		"textures/brushed_concrete/brushed_concrete_diff.jpg",
		"textures/brushed_concrete/brushed_concrete_nor.jpg",
		"textures/brushed_concrete/brushed_concrete_rough.jpg",
		uv_scale)


static func metal(uv_scale: Vector2 = Vector2(2.0, 2.0)) -> StandardMaterial3D:
	return material(
		"textures/metal_plate/metal_plate_diff.jpg",
		"textures/metal_plate/metal_plate_nor.jpg",
		"textures/metal_plate/metal_plate_rough.jpg",
		uv_scale)


# --- 第三批（场景补全）CC0 材质 -------------------------------------------
# 全部来自 Poly Haven（CC0），由 tools/fetch_scenery_textures.py 下载。
# 统一走上面的 material()：mipmap + 各向异性固定模板，不在别处手写材质参数。

## 海运集装箱侧壁（波纹钢板 + 锈迹），码头堆场用；按实例顶点色染色。
static func container_metal(uv_scale: Vector2 = Vector2(2.0, 2.0)) -> StandardMaterial3D:
	return material(
		"textures/container_side/container_side_diff.jpg",
		"textures/container_side/container_side_nor.jpg",
		"textures/container_side/container_side_rough.jpg",
		uv_scale)


## 镀锌波纹铁皮：仓库/工业棚屋外墙。
static func corrugated() -> StandardMaterial3D:
	return material(
		"textures/corrugated_iron/corrugated_iron_diff.jpg",
		"textures/corrugated_iron/corrugated_iron_nor.jpg",
		"textures/corrugated_iron/corrugated_iron_rough.jpg",
		Vector2(3.0, 3.0))


## 锈蚀波纹铁皮：熔岩赛道上的废弃工厂。
static func rusty_corrugated() -> StandardMaterial3D:
	return material(
		"textures/rusty_corrugated_iron/rusty_corrugated_iron_diff.jpg",
		"textures/rusty_corrugated_iron/rusty_corrugated_iron_nor.jpg",
		"textures/rusty_corrugated_iron/rusty_corrugated_iron_rough.jpg",
		Vector2(3.0, 3.0))


## 原木板：栈桥/木屋结构。
static func planks() -> StandardMaterial3D:
	return material(
		"textures/wood_planks/wood_planks_diff.jpg",
		"textures/wood_planks/wood_planks_nor.jpg",
		"textures/wood_planks/wood_planks_rough.jpg",
		Vector2(2.0, 2.0))


## 风化成灰木墙板：峡谷木棚 / 雪山木屋外墙。
static func weathered_planks() -> StandardMaterial3D:
	return material(
		"textures/weathered_planks/weathered_planks_diff.jpg",
		"textures/weathered_planks/weathered_planks_nor.jpg",
		"textures/weathered_planks/weathered_planks_rough.jpg",
		Vector2(2.0, 2.0))


## 深色玄武岩：熔岩赛道的黑岩柱。
static func dark_rock(uv_scale: Vector2 = Vector2(1.0, 2.0)) -> StandardMaterial3D:
	return material(
		"textures/dark_rock/dark_rock_diff.jpg",
		"textures/dark_rock/dark_rock_nor.jpg",
		"textures/dark_rock/dark_rock_rough.jpg",
		uv_scale)


## 雪面（带法线，雪堤/雪堆用）：比纯色 snow() 更有体积感。
static func snow_ground(uv_scale: Vector2 = Vector2(2.0, 2.0)) -> StandardMaterial3D:
	return material(
		"textures/snow_01/snow_01_diff.jpg",
		"textures/snow_01/snow_01_nor.jpg",
		"textures/snow_01/snow_01_rough.jpg",
		uv_scale)


# --- 按主题的地表模板（米制世界 UV 网格 / 0..1 大平面） ---------------------
# 世界 UV 网格（track_builder 的丘陵 Mesh 已按 3.6m 世界坐标写好 UV）：
# uv1_scale 必须是 1，只有大平面才按 320 次平铺。

## 沙地 / 戈壁地表（世界 UV 网格用）。
static func sand_world() -> StandardMaterial3D:
	var mat := sand()
	mat.uv1_scale = Vector3.ONE
	mat.roughness = 0.96
	return mat


## 雪地地表（世界 UV 网格用，带法线）。
static func snow_world() -> StandardMaterial3D:
	var mat := snow_ground(Vector2.ONE)
	mat.uv1_scale = Vector3.ONE
	mat.roughness = 0.84
	return mat


## 城市的湿沥青 / 混凝土广场地面：0..1 UV 的大平面，按 6m 一张平铺。
static func city_ground_plane(size_meters: float = 7000.0, night: bool = false) -> StandardMaterial3D:
	var tiles := size_meters / 6.0
	var mat := material(ASPHALT_DIFF, ASPHALT_NOR, ASPHALT_ROUGH,
		Vector2(tiles, tiles))
	mat.albedo_color = Color(0.30, 0.31, 0.34) if not night else Color(0.15, 0.16, 0.20)
	mat.roughness = 0.62 if night else 0.86
	mat.metallic = 0.12 if night else 0.0
	return mat


## 沙地 0..1 UV 大平面（戈壁远景）。
static func sand_plane(size_meters: float = 7000.0, tint: Color = Color.WHITE) -> StandardMaterial3D:
	var tiles := size_meters / 5.0
	var mat := sand()
	mat.uv1_scale = Vector3(tiles, tiles, 1.0)
	mat.albedo_color = tint
	mat.roughness = 0.96
	return mat


## 雪地 0..1 UV 大平面（雪山远景）。
static func snow_plane(size_meters: float = 7000.0) -> StandardMaterial3D:
	var tiles := size_meters / 5.0
	var mat := snow_ground(Vector2(tiles, tiles))
	mat.uv1_scale = Vector3(tiles, tiles, 1.0)
	mat.roughness = 0.84
	return mat
