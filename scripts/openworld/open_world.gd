class_name OpenWorld
extends Node3D
## 无界大陆：把八张封闭赛道的地貌缝进同一张 9km × 9km 的连续大地图。
##
## 设计要点：
##   · 高度场：481×481 双线性采样网格，整岛一张高度场；道路走廊在高度场里
##     被压平，所以粗网格也能开出平整、可跑的道路。
##   · 八域：按环形布局排布，每域有自己的地貌函数（城市平台 / 雪山 / 峡谷台地 /
##     冰川湖 / 熔岩火山 / 港湾 / 海岸 / 天际新城），域与域之间按距离权重融合。
##   · 路网：环形主干道 + 八条放射支线 + 海岸环线 + 城内街道，所有道路都是
##     样条采样后按高度场压平，并生成沥青路面与标线。
##   · 无边界：没有隐形墙，越界只会开进海里（可冲回最近道路）。

const WORLD_SIZE := 9000.0
const HALF := WORLD_SIZE * 0.5
const GRID := 577
const CELL := WORLD_SIZE / float(GRID - 1)
const ISLAND_R := 3900.0
const SEA_LEVEL := 0.0
## 域近岸下沉的触发高程：岛屿基底低于这个高度时，域的地台不再生效，
## 否则域会把海填平——海岸域就变成一块没有海的白色滩涂。
## 这个值必须小：只有真正贴水的一小圈才让位给基底，
## 否则峡谷 / 雪山这种高台域会被整个削平到海平面。
const SHORE_FADE := 2.0
## 沿海道路的最低路面高程（海平面以上）。低于它的路段自动抬成堤道 / 栈桥，
## 否则海岸环线有一段会直接沉在海里，主干道断掉。
const ROAD_MIN_Y := 1.8
## 路面抬升：沥青路铺在原地形之上 10cm（相当于路基）。
## 这个抬升必须写进高度场，否则物理贴地高度与视觉路面高度会差 10cm，
## 车轮会有三分之一陷进路面。
const ROAD_LIFT := 0.10
const HUB_CENTER := Vector2(0.0, 0.0)
const HUB_HEIGHT := 22.0
const CHUNKS := 4

## 八域：环形排布，0 号在最东，其余按顺时针。
const ZONES: Array = [
	{"id": "neon", "cn": "霓虹都市", "en": "NEON CITY", "accent": "#ff4d8d",
		"center": Vector2(2450.0, 0.0), "radius": 1150.0, "kind": "urban", "flat": 12.0},
	{"id": "skyline", "cn": "天际环城", "en": "SKYLINE RING", "accent": "#ffb547",
		"center": Vector2(1732.0, 1732.0), "radius": 1150.0, "kind": "urban", "flat": 17.0},
	{"id": "harbor", "cn": "落日港湾", "en": "SUNSET PORT", "accent": "#ffb45e",
		"center": Vector2(0.0, 2450.0), "radius": 1250.0, "kind": "urban", "flat": 5.0},
	{"id": "coast", "cn": "翡翠海岸", "en": "EMERALD COAST", "accent": "#4fe9ff",
		"center": Vector2(-1732.0, 1732.0), "radius": 1250.0, "kind": "beach", "flat": 0.0},
	{"id": "canyon", "cn": "赤岩峡谷", "en": "RED CANYON", "accent": "#ff7a3d",
		"center": Vector2(-2450.0, 0.0), "radius": 1250.0, "kind": "canyon", "flat": 62.0},
	{"id": "alpine", "cn": "雪山隘口", "en": "ALPINE PASS", "accent": "#9fd8ff",
		"center": Vector2(-1732.0, -1732.0), "radius": 1200.0, "kind": "alpine", "flat": 28.0},
	{"id": "glacier", "cn": "冰川湖", "en": "GLACIER LAKE", "accent": "#7fd8ff",
		"center": Vector2(0.0, -2450.0), "radius": 1200.0, "kind": "glacier", "flat": 40.0},
	{"id": "magma", "cn": "熔岩盆地", "en": "MAGMA BASIN", "accent": "#ff7a3d",
		"center": Vector2(1732.0, -1732.0), "radius": 1100.0, "kind": "magma", "flat": 20.0},
]

const ZONE_HUB := {"id": "hub", "cn": "中央枢纽", "en": "CENTRAL HUB", "accent": "#55e7d2",
	"center": Vector2(0.0, 0.0), "radius": 620.0, "kind": "urban", "flat": 22.0}

## 熔岩火山锥参数
const VOLCANO_CENTER := Vector2(1732.0, -1732.0)
const VOLCANO_RADIUS := 620.0
const VOLCANO_HEIGHT := 232.0
## 冰川湖（偏在域中心一侧，给主路让出位置，否则路会直接穿过湖面）
const LAKE_CENTER := Vector2(700.0, -2700.0)
const LAKE_RADIUS := 360.0
const LAKE_LEVEL := 26.0
## 峡谷主槽
const CANYON_CENTER := Vector2(-2450.0, 0.0)

## 地貌特效类别：雪线 / 岩层 / 陡坡露岩按它判定。
## 下标和 KIND_NAMES 一致，存进 kind_ids 供地形着色直接查。
## 注意：这里判定"主导域"必须用**地形权重**（_zone_weight，半径 1.55 倍），
## 不能用颜色权重（_color_zone_weight，半径 2.6 倍）——
## 颜色过渡带被拉到 2.6 倍域半径之后，隔着 1.8km 的冰川会把 39% 的
## 颜色权重渗进熔岩域中心，于是"主导域权重不足 90%"的过渡带判定
## 在域中心也成立，熔岩火山顶被当成过渡带，套上了"过渡带=中性野地"
## 的雪线规则，火山口被刷成一片雪白。
const KIND_NAMES := ["wild", "urban", "beach", "canyon", "alpine", "glacier", "magma"]

var heights := PackedFloat32Array()
var road_dist := PackedFloat32Array()
## 每个格点处最近路面的半宽（米）。路面有宽有窄（主干道 / 支线 / 街道），
## 用固定阈值判"在不在路上"会把路肩算成路面：那里物理给沥青抓地，
## 视觉上却是野地起伏，车就会陷进路肩的土里。
var road_half := PackedFloat32Array()
## 每个格点处「最近那条路」的半宽（米）。
## road_half 只在路面格点上非零，判断楼体有没有压到路面时用不上；
## 这里单独记一份：road_dist 减去它，才是"到最近路面边缘的真实距离"。
var road_half_near := PackedFloat32Array()

# --- 静态实体碰撞（自管，不进 Godot 物理系统）------------------------------
# 开放世界里有几千栋楼、几千棵树、几十公里护栏。全部建成 StaticBody3D +
# trimesh，物理内存和 broadphase 会直接爆掉，帧率也会跟着塌。
# 改成自管一份简化碰撞体（盒 / 柱），按 120m 的空间哈希分格；
# 车辆每帧只查附近几格做圆-盒推出：保证「撞不穿」，开销几乎为零。
const COLL_CELL := 120.0
var _collider_hash: Dictionary = {}
var zone_ids := PackedByteArray()
## 每个格点的地貌特效类别（见 KIND_NAMES）。
var kind_ids := PackedByteArray()
var roads: Array = []
## --- 路网空间索引（精确净空查询）-------------------------------------------
## road_dist 是按 15.6m 高度场格点存的距离场，量化误差可达 ±11m。
## 判断"一栋楼有没有压到路面上"要的是精确值（差 3m 就是楼身骑在路肩上），
## 所以另建一份路网线段的空间哈希：查询只看点周围几个格子。
const ROAD_IDX_CELL := 64.0
var _road_idx: Dictionary = {}
var built := false
var stats: Dictionary = {}

var _n_base := FastNoiseLite.new()
var _n_detail := FastNoiseLite.new()
var _n_ridge := FastNoiseLite.new()
var _n_massif := FastNoiseLite.new()
var _n_warp := FastNoiseLite.new()


func _init() -> void:
	name = "OpenWorld"
	_setup_noise()


func _setup_noise() -> void:
	_n_base.seed = 20261107
	_n_base.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_n_base.fractal_type = FastNoiseLite.FRACTAL_FBM
	_n_base.fractal_octaves = 4
	_n_base.fractal_gain = 0.48
	_n_base.frequency = 0.00085

	_n_detail.seed = 991
	_n_detail.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_n_detail.fractal_type = FastNoiseLite.FRACTAL_FBM
	_n_detail.fractal_octaves = 3
	_n_detail.frequency = 0.0058

	_n_ridge.seed = 4242
	_n_ridge.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_n_ridge.fractal_type = FastNoiseLite.FRACTAL_FBM
	_n_ridge.fractal_octaves = 5
	_n_ridge.frequency = 0.00120

	# 山体层：低频、圆滑，用来铺出连绵的大山骨架（细节脊线叠在它上面）
	_n_massif.seed = 8317
	_n_massif.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_n_massif.fractal_type = FastNoiseLite.FRACTAL_FBM
	_n_massif.fractal_octaves = 3
	_n_massif.fractal_gain = 0.42
	_n_massif.frequency = 0.00046

	_n_warp.seed = 777
	_n_warp.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_n_warp.frequency = 0.0011


# ---------------------------------------------------------------------------
# 构建
# ---------------------------------------------------------------------------

func build() -> void:
	if built:
		return
	_generate_heightfield()
	_build_road_network()
	_compute_road_distances()
	_init_road_profiles()
	# 迭代压平：每一轮都从当前高度场重新读回路的高程，
	# 让路口处各条路的高程收敛到同一个值（否则低的那条路被地形埋掉）。
	for i in 2:
		_splat_roads_into_heightfield()
		_refine_road_profiles()
	_splat_roads_into_heightfield()
	_generate_road_meshes()
	_build_terrain()
	_build_sea()
	build_areas()
	built = true


## 分帧版本：各阶段之间让出一帧，加载界面才不会卡成死机。
func build_stepped() -> void:
	if built:
		return
	_generate_heightfield()
	await get_tree().process_frame
	_build_road_network()
	_build_road_index()
	_compute_road_distances()
	_init_road_profiles()
	for i in 2:
		_splat_roads_into_heightfield()
		_refine_road_profiles()
		await get_tree().process_frame
	_splat_roads_into_heightfield()
	await get_tree().process_frame
	_generate_road_meshes()
	await get_tree().process_frame
	_build_terrain()
	await get_tree().process_frame
	_build_sea()
	build_areas()
	built = true


## 供外部（scenery 模块）扩展：地形与路网建好后再挂装饰。
func build_areas() -> void:
	pass


func _generate_heightfield() -> void:
	heights.resize(GRID * GRID)
	road_dist.resize(GRID * GRID)
	road_half.resize(GRID * GRID)
	road_half_near.resize(GRID * GRID)
	zone_ids.resize(GRID * GRID)
	kind_ids.resize(GRID * GRID)
	var zone_count := ZONES.size()
	for j in GRID:
		var wz := -HALF + float(j) * CELL
		var row := j * GRID
		for i in GRID:
			var wx := -HALF + float(i) * CELL
			var idx := row + i
			var h := _terrain_at(wx, wz)
			heights[idx] = h
			road_dist[idx] = 99999.0
			road_half[idx] = 0.0
			road_half_near[idx] = 0.0
			zone_ids[idx] = _dominant_zone(wx, wz)
			kind_ids[idx] = _effect_kind(wx, wz)


## 单点地貌求值：岛屿基底 + 域权重融合 + 细节噪声。
func _terrain_at(x: float, z: float) -> float:
	var base := _island_base(x, z)
	var total := 0.0
	var acc := 0.0
	var best_w := 0.0
	var best_zone := -1
	var zone_count := ZONES.size()
	for i in zone_count:
		var zone: Dictionary = ZONES[i]
		var c: Vector2 = zone["center"]
		var rad: float = zone["radius"]
		var d := Vector2(x - c.x, z - c.y).length()
		var w := _zone_weight(d, rad)
		if w <= 0.0005:
			continue
		var hz := _zone_height(zone, x, z, base)
		# 近岸下沉：域的地台不能把海填平。岛屿基底才是海岸线的权威，
		# 域只能叠加在陆地上；越靠近岸线，域高度越要交给基底接管，
		# 海才能真正渗进海岸域 / 港湾域。
		if base < SHORE_FADE:
			var k := clampf((SHORE_FADE - base) / (SHORE_FADE + 1.2), 0.0, 1.0)
			hz = lerpf(hz, minf(hz, base - 1.2), k)
		acc += w * hz
		total += w
		if w > best_w:
			best_w = w
			best_zone = i
	# 中央枢纽
	var dh := Vector2(x - HUB_CENTER.x, z - HUB_CENTER.y).length()
	var wh := _zone_weight(dh, float(ZONE_HUB["radius"]))
	if wh > 0.0005:
		acc += wh * float(ZONE_HUB["flat"])
		total += wh
		if wh > best_w:
			best_w = wh
			best_zone = zone_count
	var h := base
	if total > 0.0001:
		h = acc / total
	# 细节起伏：城市域几乎全平，野外域按域类型给起伏量
	var relief := 0.0
	if best_zone >= 0:
		var kind := "urban"
		if best_zone == zone_count:
			kind = "urban"
		else:
			kind = String(ZONES[best_zone]["kind"])
		relief = _relief_for_kind(kind)
	if relief > 0.01:
		var d1 := _n_detail.get_noise_2d(x, z)
		var d2 := _n_base.get_noise_2d(x * 2.3, z * 2.3)
		h += (d1 * 3.4 + d2 * 6.2) * relief
	return h


## 该点的主导区域编号（8 个域 + 中央枢纽），255 = 无。
func _dominant_zone(x: float, z: float) -> int:
	var best := -1
	var best_w := 0.0
	for i in ZONES.size():
		var zone: Dictionary = ZONES[i]
		var c: Vector2 = zone["center"]
		var d := Vector2(x - c.x, z - c.y).length()
		var w := _zone_weight(d, float(zone["radius"]))
		if w > best_w:
			best_w = w
			best = i
	if best_w <= 0.0:
		return 255
	var dh := Vector2(x - HUB_CENTER.x, z - HUB_CENTER.y).length()
	var wh := _zone_weight(dh, float(ZONE_HUB["radius"]))
	if wh > best_w:
		return ZONES.size()
	return best


func _relief_for_kind(kind: String) -> float:
	match kind:
		"urban":
			return 0.04
		"beach":
			return 0.45
		"canyon":
			return 0.55
		"alpine":
			return 0.9
		"glacier":
			return 0.6
		"magma":
			return 0.7
	return 0.4


## 这一格该用哪套地貌特效（雪线 / 岩层 / 露岩）。
##
## 判定用的是**地形权重**而不是颜色权重：
## 颜色过渡带被拉到 2.6 倍域半径（用户要的"长渐变"），
## 域与域之间本来就互相渗透——隔着 1.8km 的冰川会把 39% 的颜色权重
## 渗进熔岩域中心。用颜色权重判主导域的话，"主导域权重不足 90%"
## 这个过渡带条件在域中心也成立，于是熔岩火山顶被判成过渡带，
## 套上"过渡带 = 中性野地"的雪线规则，整个火山口被刷成雪白色。
##
## 地形权重（1.55 倍半径）才是"这一块地貌到底属于谁"的答案：
## 域中心永远是 100% 主导，只有真正的过渡带才会退化成中性野地。
func _effect_kind(x: float, z: float) -> int:
	var total := 0.0
	var dom := -1
	var dom_w := 0.0
	for i in ZONES.size():
		var zone: Dictionary = ZONES[i]
		var c: Vector2 = zone["center"]
		var w := _zone_weight(Vector2(x - c.x, z - c.y).length(), float(zone["radius"]))
		if w <= 0.0:
			continue
		total += w
		if w > dom_w:
			dom_w = w
			dom = i
	var wh := _zone_weight(Vector2(x - HUB_CENTER.x, z - HUB_CENTER.y).length(),
		float(ZONE_HUB["radius"]))
	if wh > 0.0:
		total += wh
		if wh > dom_w:
			dom_w = wh
			dom = ZONES.size()
	# 主导域权重不到 90%：正处在两域的过渡带上，用中性野地规则，
	# 免得雪线 / 岩层 / 露岩在边界上来回跳。
	if dom < 0 or dom_w < total * 0.9:
		return 0
	var kind := String(ZONE_HUB["kind"]) if dom == ZONES.size() else String(ZONES[dom]["kind"])
	for i in KIND_NAMES.size():
		if KIND_NAMES[i] == kind:
			return i
	return 0


func _zone_weight(d: float, radius: float) -> float:
	# 域中心权重 1，到 radius*1.5 衰减到 0
	var inner := radius * 0.34
	var outer := radius * 1.55
	if d <= inner:
		return 1.0
	if d >= outer:
		return 0.0
	var t := (d - inner) / maxf(outer - inner, 0.001)
	return 1.0 - t * t * (3.0 - 2.0 * t)


## 颜色过渡用的域权重：过渡带比地形权重长得多。
## 地形必须保持域的形状（城区要平、雪山要陡），但颜色可以慢慢渗过去——
## 9km 的大陆如果按地形权重的 1.55 倍半径硬切，域与域之间只有几十米缓冲，
## 看起来像八块拼贴板；把过渡拉到 2.6 倍半径，相邻域会在中点混色，
## 整块大陆才连成一片连续的地貌。
func _color_zone_weight(d: float, radius: float) -> float:
	var inner := radius * 0.18
	var outer := radius * 2.60
	if d <= inner:
		return 1.0
	if d >= outer:
		return 0.0
	var t := (d - inner) / maxf(outer - inner, 0.001)
	return 1.0 - t * t * (3.0 - 2.0 * t)


## 光照过渡用的域权重（已归一化）。
## 过渡带比颜色短：光照渐变太长会让人晕（天色半天不变），
## 太短又会在域边界上"啪"地一下换掉。
func zone_weights_at(x: float, z: float) -> Array:
	var out: Array = []
	var total := 0.0
	for i in ZONES.size():
		var zone: Dictionary = ZONES[i]
		var c: Vector2 = zone["center"]
		var d := Vector2(x - c.x, z - c.y).length()
		var w := _zone_weight(d, float(zone["radius"]))
		if w <= 0.002:
			continue
		out.append({"id": i, "w": w})
		total += w
	var dh := Vector2(x - HUB_CENTER.x, z - HUB_CENTER.y).length()
	var wh := _zone_weight(dh, float(ZONE_HUB["radius"]))
	if wh > 0.002:
		out.append({"id": ZONES.size(), "w": wh})
		total += wh
	if total <= 0.0:
		return []
	for e in out:
		e["w"] = float(e["w"]) / total
	return out


## 各域地面基色（预计算，避免 33 万个顶点各自跑一遍 match）。
## 顺序必须和 ZONES 一致。
const ZONE_BASE_COLORS := [
	Color(0.32, 0.30, 0.29),   # 0 neon    夜城：地面只吃到冷色环境光
	Color(0.40, 0.38, 0.35),   # 1 skyline 黄昏未来城：混凝土
	Color(0.40, 0.38, 0.35),   # 2 harbor  港口：压实混凝土
	Color(0.64, 0.57, 0.42),   # 3 coast   沙地（再高会过曝死白）
	Color(0.52, 0.28, 0.18),   # 4 canyon  红岩
	Color(0.55, 0.59, 0.66),   # 5 alpine  雪线以下的碎石
	Color(0.57, 0.65, 0.75),   # 6 glacier 冰原
	Color(0.34, 0.20, 0.17),   # 7 magma   焦土
]
const HUB_BASE_COLOR := Color(0.40, 0.38, 0.35)
const WILD_BASE_COLOR := Color(0.34, 0.47, 0.23)


## 岛屿轮廓：随角度变化的半径 + 两处海湾。
## 海岸环线必须和它用同一套公式，否则环线会画到湾外的海里。
func _island_shape(ang: float) -> float:
	var shape := 1.0
	shape += 0.105 * sin(ang * 3.0 + 0.7)
	shape += 0.068 * sin(ang * 5.0 + 1.9)
	shape += 0.042 * sin(ang * 7.0 + 0.3)
	shape += 0.026 * sin(ang * 11.0 + 2.4)
	# 翡翠海岸湾（135°）：把海拉进海岸域
	shape *= _bay(ang, 2.3562, 0.62, 0.34)
	# 落日港湾湾（90°）：没有它，港湾域离岸 1.6km，根本不是港口
	shape *= _bay(ang, 1.5708, 0.58, 0.12)
	return shape


## 单个海湾的凹陷系数（1 = 不凹，1-depth = 最深处）。
func _bay(ang: float, center: float, halfw: float, depth: float) -> float:
	var d := absf(wrapf(ang - center, -PI, PI))
	var k := clampf(1.0 - d / halfw, 0.0, 1.0)
	return 1.0 - depth * k * k * (3.0 - 2.0 * k)


## 岛屿基底：内陆是一整片 14m 高原，靠近岸线直接切成海崖。
## 之前用的是「从内陆一路缓降到岸线」的斜坡，结果是——
##   · 域中心离岸线只有 400m，域的一半泡在海里；
##   · 峡谷 / 雪山 / 熔岩这些高台型域在近岸被削成洼地。
## 现在改成高原 + 断崖：域完整地立在高原上，到岸线才被切断。
func _island_base(x: float, z: float) -> float:
	var r := sqrt(x * x + z * z)
	var ang := atan2(z, x)
	var R := ISLAND_R * _island_shape(ang)
	var t := r / maxf(R, 1.0)
	if t >= 1.0:
		return -6.0 - 46.0 * minf(t - 1.0, 4.0)
	if t > 0.86:
		# 海岸断崖：u=0 是高原顶，u=1 是 -6m 的海底。
		var u := (t - 0.86) / 0.14
		return lerpf(14.0, -6.0, u * u * (3.0 - 2.0 * u))
	return 14.0


## 各域局部高度。
func _zone_height(zone: Dictionary, x: float, z: float, base: float) -> float:
	var kind := String(zone["kind"])
	match kind:
		"urban":
			var flat := float(zone["flat"])
			return flat + _n_detail.get_noise_2d(x, z) * 0.35
		"beach":
			# 海岸：保留岛屿基底（自然向海倾斜）+ 沙丘起伏
			return base + _n_detail.get_noise_2d(x, z) * 2.6
		"alpine":
			# 雪山：脊线噪声堆出连绵雪峰（脊线频率提高、掩膜平滑，峰形才立得住）
			var c: Vector2 = zone["center"]
			var d := Vector2(x - c.x, z - c.y).length()
			var mask := clampf(1.0 - d / (float(zone["radius"]) * 1.45), 0.0, 1.0)
			mask = mask * mask * (3.0 - 2.0 * mask)
			var ridge := _ridged(x, z)
			var h := float(zone["flat"]) + ridge * 178.0 * mask
			return h
		"glacier":
			# 冰川：高台 + 冰碛丘陵，中间是冰湖洼地
			var gc: Vector2 = zone["center"]
			var gd := Vector2(x - gc.x, z - gc.y).length()
			var gh := float(zone["flat"]) + _n_detail.get_noise_2d(x, z) * 26.0 \
				+ _n_base.get_noise_2d(x * 1.7, z * 1.7) * 34.0
			var lake := clampf(1.0 - gd / LAKE_RADIUS, 0.0, 1.0)
			gh = lerpf(gh, LAKE_LEVEL - 16.0, lake * lake * (3.0 - 2.0 * lake))
			return gh
		"canyon":
			# 峡谷：高台 + 一条南北走向、窄而深的下切槽（台面要平，不能是沙丘）
			var cc: Vector2 = zone["center"]
			var cd := Vector2(x - cc.x, z - cc.y).length()
			var mask := clampf(1.0 - cd / (float(zone["radius"]) * 1.4), 0.0, 1.0)
			var mesa := float(zone["flat"]) + _n_detail.get_noise_2d(x, z) * 6.0 \
				+ _n_base.get_noise_2d(x * 1.4, z * 1.4) * 52.0 * mask
			# 槽线沿 z 方向蜿蜒。半宽 ~85m（总宽 170m）、深 108m：
			# 之前半宽只有 38m，从高处看就是一道划痕，落地也只是一条浅沟，
			# 整个域看着像沙漠平原而不是峡谷。
			var chan := absf(sin((z * 0.9 + _n_warp.get_noise_2d(x, z) * 900.0) * 0.0026))
			var cut := clampf(1.0 - cd / (float(zone["radius"]) * 1.05), 0.0, 1.0)
			var carve := (1.0 - smoothstep(0.0, 0.20, chan)) * cut * 108.0
			# 谷肩：主槽两侧再抬一道矮台，谷壁才有硬边
			var rim := smoothstep(0.20, 0.30, chan) * (1.0 - smoothstep(0.30, 0.46, chan)) * cut * 16.0
			return mesa - carve + rim
		"magma":
			# 熔岩：火山锥 + 熔岩原
			var mc: Vector2 = zone["center"]
			var md := Vector2(x - mc.x, z - mc.y).length()
			var cone := 0.0
			if md < VOLCANO_RADIUS:
				var u := 1.0 - md / VOLCANO_RADIUS
				cone = VOLCANO_HEIGHT * pow(u, 1.85)
				cone *= 0.86 + 0.14 * _n_detail.get_noise_2d(x, z)
			var plain := float(zone["flat"]) + _n_detail.get_noise_2d(x, z) * 3.2
			return plain + cone
	return base


func _ridged(x: float, z: float) -> float:
	# 细节脊线：三次方，不是五次方。五次方会把山切成一根根独立的白色尖刺，
	# 三次方才能连成有体量、能连绵展开的山脊线。
	var v := _n_ridge.get_noise_2d(x, z)
	var r := 1.0 - absf(v)
	r = r * r * r
	# 低频山体：先铺出成片的山，再叠上面的细节脊
	var v2 := _n_massif.get_noise_2d(x, z)
	var r2 := 1.0 - absf(v2)
	r2 = r2 * r2
	return clampf((r * 0.55 + r2 * 0.62) * 1.15 - 0.10, 0.0, 1.2)


# ---------------------------------------------------------------------------
# 路网
# ---------------------------------------------------------------------------

func _build_road_network() -> void:
	roads.clear()
	# ① 环形主干道：串起八域
	var ring_pts: Array[Vector2] = []
	for i in ZONES.size():
		ring_pts.append(ZONES[i]["center"])
	var ring := _catmull_loop(ring_pts, 18.0)
	_add_road(ring, 17.0, "ring")
	# ② 放射支线：中央枢纽 → 八域
	for i in ZONES.size():
		var c: Vector2 = ZONES[i]["center"]
		var mid := c * 0.52
		var path := _catmull_open([HUB_CENTER, mid, c], 14.0)
		_add_road(path, 13.0, "spoke")
	# ③ 海岸环线：贴着海岸线兜一圈
	var coast_pts: Array[Vector2] = []
	for i in 48:
		var a := TAU * float(i) / 48.0
		var rr := _coast_radius(a) - 210.0
		coast_pts.append(Vector2(cos(a) * rr, sin(a) * rr))
	var coast := _catmull_loop(coast_pts, 22.0)
	_add_road(coast, 14.0, "coast")
	# ④ 城内街道：霓虹都市 / 天际环城 / 港湾
	for zi in [0, 1, 2]:
		_add_city_streets(ZONES[zi])


func _coast_radius(a: float) -> float:
	# 和岛屿基底共用同一套轮廓（含两处海湾），
	# 否则海岸环线在湾里会画到岸线之外，直接泡在海里。
	return ISLAND_R * _island_shape(a)


## 把路网拆成线段塞进空间哈希，供「精确到路边缘的距离」查询。
##
## 为什么不能直接用 road_dist：那张表是按 15.6m 高度场格点存的，
## 查询点离格点最远能差 11m，而净空判据的容差只有几米——
## 直接拿它判"楼有没有压路"，会有三成概率判错。
## 这里保留折线本身，用点-线段投影算真实距离，误差只有采样步长（14~22m）
## 带来的那一点点曲率误差。
func _build_road_index() -> void:
	_road_idx.clear()
	for road in roads:
		var pts: Array = road["pts"]
		var half: float = float(road.get("width", 12.0)) * 0.5
		for i in range(pts.size() - 1):
			var a: Vector2 = pts[i]
			var b: Vector2 = pts[i + 1]
			if a.distance_squared_to(b) < 0.01:
				continue
			var seg := {"a": a, "b": b, "h": half}
			for key in [_road_idx_key(a.x, a.y), _road_idx_key(b.x, b.y)]:
				if not _road_idx.has(key):
					_road_idx[key] = []
				(_road_idx[key] as Array).append(seg)


func _road_idx_key(x: float, z: float) -> Vector2i:
	return Vector2i(int(floor(x / ROAD_IDX_CELL)), int(floor(z / ROAD_IDX_CELL)))


## 精确的「到最近路面边缘的距离」（米）。
##
## 返回值 = 到最近那段路的中心线的垂距 - 该路的半宽。
## 附近没有路时返回一个大值（视为离路很远）。
##
## 净空判据最多关心 40m 内的路，搜 3×3 格（±64m）足够；
## 再往外找只会白费时间——这个函数每个域要调用上万次。
func road_edge_distance_exact(x: float, z: float) -> float:
	var best := 99999.0
	var key0 := _road_idx_key(x, z)
	var p := Vector2(x, z)
	for dj in range(-1, 2):
		for di in range(-1, 2):
			var key := key0 + Vector2i(di, dj)
			if not _road_idx.has(key):
				continue
			for seg in _road_idx[key] as Array:
				var a: Vector2 = seg["a"]
				var b: Vector2 = seg["b"]
				var ab := b - a
				var l2 := ab.length_squared()
				var u := 0.0
				if l2 > 0.0001:
					u = clampf((p - a).dot(ab) / l2, 0.0, 1.0)
				var q := a + ab * u
				var d := p.distance_to(q) - float(seg["h"])
				if d < best:
					best = d
	return best


func _add_city_streets(zone: Dictionary) -> void:
	var c: Vector2 = zone["center"]
	var rad: float = float(zone["radius"]) * 0.80
	# 街区网格：横竖两组平行街道 + 两条环街。
	# 不用「八条放射主街」——那会在域中心聚成一个放射状星芒，太假。
	var block := 124.0
	var half := int(rad / block)
	for j in range(-half, half + 1):
		var oz := float(j) * block + (block * 0.5 if j % 2 == 0 else 0.0)
		if absf(oz) > rad:
			continue
		var pts: Array[Vector2] = []
		var n := 11
		for k in n:
			var t := float(k) / float(n - 1)
			var x := -rad * 1.05 + t * rad * 2.1
			pts.append(c + Vector2(x, oz + sin(t * 2.6 + float(j) * 0.7) * 9.0))
		_add_road(_catmull_open(pts, 15.0), 12.0, "street")
	for i in range(-half, half + 1):
		var ox := float(i) * block + (block * 0.5 if i % 2 == 0 else 0.0)
		if absf(ox) > rad:
			continue
		var pts2: Array[Vector2] = []
		var n2 := 11
		for k in n2:
			var t := float(k) / float(n2 - 1)
			var z := -rad * 1.05 + t * rad * 2.1
			pts2.append(c + Vector2(ox + sin(t * 2.4 + float(i) * 0.9) * 9.0, z))
		_add_road(_catmull_open(pts2, 15.0), 12.0, "street")
	# 同心环街：给网格加两条环线，避免全是方格
	for ring_i in 2:
		var rr := rad * (0.38 + 0.32 * float(ring_i))
		var pts3: Array[Vector2] = []
		var count := 30
		for i in count:
			var a := TAU * float(i) / float(count)
			pts3.append(c + Vector2(cos(a) * rr, sin(a) * rr))
		_add_road(_catmull_loop(pts3, 15.0), 12.0, "street")


func _add_road(pts: Array, width: float, kind: String) -> void:
	if pts.size() < 2:
		return
	roads.append({"pts": pts, "width": width, "kind": kind, "ys": []})


## Catmull-Rom 采样成折线。closed=true 时首尾相接。
func _catmull_loop(ctrl: Array[Vector2], step: float) -> Array:
	var out: Array = []
	var n := ctrl.size()
	if n < 3:
		return ctrl.duplicate()
	for i in n:
		var p0: Vector2 = ctrl[(i - 1 + n) % n]
		var p1: Vector2 = ctrl[i]
		var p2: Vector2 = ctrl[(i + 1) % n]
		var p3: Vector2 = ctrl[(i + 2) % n]
		out.append_array(_catmull_segment(p0, p1, p2, p3, step))
	out.append(ctrl[0])
	return out


func _catmull_open(ctrl: Array[Vector2], step: float) -> Array:
	var out: Array = []
	var n := ctrl.size()
	if n < 2:
		return ctrl.duplicate()
	for i in range(n - 1):
		var p0: Vector2 = ctrl[maxi(i - 1, 0)]
		var p1: Vector2 = ctrl[i]
		var p2: Vector2 = ctrl[i + 1]
		var p3: Vector2 = ctrl[mini(i + 2, n - 1)]
		out.append_array(_catmull_segment(p0, p1, p2, p3, step))
	out.append(ctrl[n - 1])
	return out


func _catmull_segment(p0: Vector2, p1: Vector2, p2: Vector2, p3: Vector2, step: float) -> Array:
	var seg_len := p1.distance_to(p2)
	var count := maxi(int(seg_len / step), 2)
	var out: Array = []
	for k in count:
		var t := float(k) / float(count)
		var t2 := t * t
		var t3 := t2 * t
		var pt := 0.5 * ((2.0 * p1) + (-p0 + p2) * t
			+ (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2
			+ (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3)
		out.append(pt)
	return out


## 初始化每条路的高程剖面（解析地形 + 平滑）。
func _init_road_profiles() -> void:
	for road in roads:
		road["ys"] = _prepare_road_points(road["pts"])


## 从当前高度场重新采样每条路的高程并平滑。
##
## 路口处两条路的高程必须一致：环形主干道、放射支线、海岸环线、
## 城内街道是各自独立生成的，各自的平滑窗口位置不同，
## 同一个路口上两条路能差出好几米。压平时取平均，
## 地形就被抬到两条路中间——低的那条直接被地形埋掉，
## 远看就是"路在路口断成一截"。
##
## 迭代几轮之后，所有路在路口的高度都会收敛到同一个值。
func _refine_road_profiles() -> void:
	for road in roads:
		var pts: Array = road["pts"]
		var raw: Array = []
		for p in pts:
			var v: Vector2 = p
			raw.append(height_at(v.x, v.y))
		var sm := _smooth_series(raw, 3)
		sm = _smooth_series(sm, 2)
		road["ys"] = sm


## 道路中心线采样：给每个采样点求地面高度并做平滑（避免道路起伏颠簸）。
func _prepare_road_points(pts: Array) -> Array:
	var raw: Array = []
	for p in pts:
		var v: Vector2 = p
		raw.append(_terrain_at(v.x, v.y))
	var smoothed := _smooth_series(raw, 9)
	smoothed = _smooth_series(smoothed, 5)
	# 沿海路段不许沉在海面以下：低于海平面 +1.8m 的路段抬成海堤 / 栈桥。
	# 高度场会跟着路面一起填平，于是这条路变成一条填海造陆的沿海堤道——
	# 既不会断，也不会把玩家坑进水里。
	var out: Array = []
	for y in smoothed:
		out.append(maxf(float(y), ROAD_MIN_Y))
	return out


func _smooth_series(src: Array, radius: int) -> Array:
	var n := src.size()
	var out: Array = []
	for i in n:
		var sum := 0.0
		var cnt := 0
		for k in range(-radius, radius + 1):
			var j := clampi(i + k, 0, n - 1)
			sum += float(src[j])
			cnt += 1
		out.append(sum / float(cnt))
	return out


## 记录每个格点离最近路面的距离。
## 只跟路网形状有关，跟高程无关，所以迭代压平时不用重复算。
##
## 同时记下「最近那条路」的半宽（road_half_near）：
## 判楼体有没有压到路面时，要拿「到路边缘的距离」，
## 不能拿「到路中心线的距离」——否则 12m 宽的街道只算 6m，
## 净空会凭空少 6m，楼就骑到路上了。
func _compute_road_distances() -> void:
	var reach := 78.0
	for road in roads:
		var pts: Array = road["pts"]
		var half: float = float(road.get("width", 12.0)) * 0.5
		for i in pts.size():
			var p: Vector2 = pts[i]
			var ci := int(round((p.x + HALF) / CELL))
			var cj := int(round((p.y + HALF) / CELL))
			var rad := int(ceil(reach / CELL))
			for dj in range(-rad, rad + 1):
				var j := cj + dj
				if j < 0 or j >= GRID:
					continue
				for di in range(-rad, rad + 1):
					var ii := ci + di
					if ii < 0 or ii >= GRID:
						continue
					var wx := -HALF + float(ii) * CELL
					var wz := -HALF + float(j) * CELL
					var d := Vector2(wx - p.x, wz - p.y).length()
					if d > reach:
						continue
					var idx := j * GRID + ii
					if d < road_dist[idx]:
						road_dist[idx] = d
						road_half_near[idx] = half


## 把道路走廊压进高度场：附近格子向道路高程靠拢。
##
## 这里踩过两个坑，都直接表现为"路面被地形戳成锯齿"：
##
## 1) 距离用的是「到最近采样点」而不是「到折线的垂距」。
##    采样点之间有 15m 空档，坡道上这段空档里的格子拿到的路面高程
##    是某一个端点的值（不是插值），路面网格却在两点之间拉直线，
##    地形就会从直线的下方鼓上来，把路切成一段段的锯齿。
##    → 改成按线段做投影，取投影点上的插值高程。
##
## 2) 权重是顺序累加的：heights[idx] = lerp(heights[idx], target, w)，
##    每处理一个采样点就把上一个的结果往新目标推一次。w 接近 1 时
##    这不是平均而是覆盖，最后一个采样点独大，整条路基跟着它走。
##    → 改成先累加权重和加权和，最后一次性按 w_sum / (w_sum) 求平均。
##
## 另外路堤只铺到路缘外 BANK 米：原来铺到 78m，整条路变成一大片
## 平台，路基高度和路面几乎共面，采样误差就够让地形戳穿路面。
func _splat_roads_into_heightfield() -> void:
	var reach := 78.0
	# 路缘外 flat 米内完全压平成路面高程，再 blend 米过渡回原地形。
	# 必须压得比路面半宽多出至少一个格子（15.6m）：
	# 高度场是 15.6m 一格，路的边坡只要有一个格子没压到，
	# 崖壁的顶点就会插进路面里，把路顶出一块楔子。
	var flat := 20.0
	var blend := 30.0
	var wsum := PackedFloat32Array()
	var ysum := PackedFloat32Array()
	wsum.resize(GRID * GRID)
	ysum.resize(GRID * GRID)
	for road in roads:
		var pts: Array = road["pts"]
		var ys: Array = road.get("ys", [])
		if ys.is_empty():
			ys = _prepare_road_points(pts)
		var half := float(road["width"]) * 0.5
		var flat_here := half + flat
		# ---- 路基：按线段精确投影 ----
		var max_seg := 1.0
		for k in range(pts.size() - 1):
			max_seg = maxf(max_seg, (pts[k] as Vector2).distance_to(pts[k + 1] as Vector2))
		var scan := flat_here + blend + max_seg
		for i in pts.size():
			var p2: Vector2 = pts[i]
			var ci2 := int(round((p2.x + HALF) / CELL))
			var cj2 := int(round((p2.y + HALF) / CELL))
			var rad2 := int(ceil(scan / CELL))
			for dj2 in range(-rad2, rad2 + 1):
				var j2 := cj2 + dj2
				if j2 < 0 or j2 >= GRID:
					continue
				for di2 in range(-rad2, rad2 + 1):
					var ii2 := ci2 + di2
					if ii2 < 0 or ii2 >= GRID:
						continue
					var wx2 := -HALF + float(ii2) * CELL
					var wz2 := -HALF + float(j2) * CELL
					var cell := Vector2(wx2, wz2)
					var idx2 := j2 * GRID + ii2
					for seg in range(maxi(i - 1, 0), mini(i, pts.size() - 2) + 1):
						var a: Vector2 = pts[seg]
						var b: Vector2 = pts[seg + 1]
						var ab := b - a
						var l2 := ab.length_squared()
						if l2 < 0.0001:
							continue
						var u := clampf((cell - a).dot(ab) / l2, 0.0, 1.0)
						var q := a + ab * u
						var d2 := cell.distance_to(q)
						if d2 > flat_here + blend:
							continue
						if d2 <= half and half > road_half[idx2]:
							road_half[idx2] = half
						var w := 1.0
						if d2 > flat_here:
							w = 1.0 - smoothstep(flat_here, flat_here + blend, d2)
							w = w * w * (3.0 - 2.0 * w)
						# 路面比原地形抬高 ROAD_LIFT（路基厚度），并把这个抬升写进高度场。
						# 这样物理高度 = 视觉路面高度，两者永远一致；否则车身会按地形高
						# 悬在路面下方，看起来像半个轮子陷进沥青里。
						var ry := lerpf(float(ys[seg]), float(ys[seg + 1]), u) + ROAD_LIFT
						wsum[idx2] += w
						ysum[idx2] += w * ry
	# ---- 一次性按权重平均写回 ----
	for idx3 in GRID * GRID:
		var w3 := wsum[idx3]
		if w3 <= 0.0001:
			continue
		var cov: float = clampf(w3, 0.0, 1.0)
		heights[idx3] = lerpf(heights[idx3], ysum[idx3] / w3, cov)


## 把道路折线加密到 step 米。
## 采样点之间有 15m 空档，路面网格如果只在采样点之间拉直线，
## 坡道上就会切进地形（地形从直线上方鼓出来），远看是一路的锯齿碎块。
## 加密后网格每 4m 就重新采一次地形高度，整条路是贴着地面的。
static func _densify_road(pts: Array, ys: Array, step: float) -> Dictionary:
	var dp: Array[Vector2] = []
	var dy: Array = []
	var n := pts.size()
	for i in range(n - 1):
		var a: Vector2 = pts[i]
		var b: Vector2 = pts[i + 1]
		var seg := a.distance_to(b)
		var k := maxi(int(ceil(seg / maxf(step, 0.5))), 1)
		for j in k:
			var t := float(j) / float(k)
			dp.append(a.lerp(b, t))
			dy.append(lerpf(float(ys[i]), float(ys[i + 1]), t))
	if n > 0:
		dp.append(pts[n - 1])
		dy.append(ys[n - 1])
	return {"pts": dp, "ys": dy}


## 路面网格：沥青带 + 中央虚线 + 两侧边线。
func _generate_road_meshes() -> void:
	var root := Node3D.new()
	root.name = "Roads"
	add_child(root)
	for ri in roads.size():
		var road: Dictionary = roads[ri]
		var pts: Array = road["pts"]
		var width: float = road["width"]
		var ys: Array = road.get("ys", [])
		if ys.is_empty():
			ys = _prepare_road_points(pts)
		_build_road_strip(root, pts, ys, width, ri)


func _build_road_strip(root: Node3D, pts: Array, ys: Array, width: float, idx: int) -> void:
	var dense := _densify_road(pts, ys, 4.0)
	var dpts: Array = dense["pts"]
	var n := dpts.size()
	if n < 2:
		return
	var half := width * 0.5
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var cols := PackedColorArray()
	var idxs := PackedInt32Array()
	var dist := 0.0
	for i in n:
		var p: Vector2 = dpts[i]
		var prev: Vector2 = dpts[maxi(i - 1, 0)]
		var next: Vector2 = dpts[mini(i + 1, n - 1)]
		var dir := (next - prev)
		if dir.length() < 0.0001:
			dir = Vector2(0.0, 1.0)
		dir = dir.normalized()
		var side := Vector2(-dir.y, dir.x)
		if i > 0:
			dist += p.distance_to(prev)
		# 路面高度直接取最终高度场（splat 之后），不能拿 ys 插值：
		# ys 是沿路采样点的高程，高度场是按格点写的，两者在近岸陡坡段
		# 会对不上，路面被地形埋掉半截，只剩几块黑色碎片浮在沙地上。
		#
		# 横向取三个点（路缘 / 中线 / 路缘），各自按所在位置的地形高度取值：
		# 路是"贴"在地形上的，横向有坡度时整条横截面都跟着斜，
		# 否则上坡那一侧的路缘会被地形埋掉，只剩半条路。
		var y_c: float = height_at(p.x, p.y) + 0.025
		var lx := p.x - side.x * half
		var lz := p.y - side.y * half
		var rx := p.x + side.x * half
		var rz := p.y + side.y * half
		var y_l: float = height_at(lx, lz) + 0.025
		var y_r: float = height_at(rx, rz) + 0.025
		verts.append(Vector3(lx, y_l, lz))
		verts.append(Vector3(p.x, y_c, p.y))
		verts.append(Vector3(rx, y_r, rz))
		norms.append(Vector3.UP)
		norms.append(Vector3.UP)
		norms.append(Vector3.UP)
		uvs.append(Vector2(0.0, dist / 9.0))
		uvs.append(Vector2(width * 0.5 / 9.0, dist / 9.0))
		uvs.append(Vector2(width / 9.0, dist / 9.0))
		cols.append(Color.WHITE)
		cols.append(Color.WHITE)
		cols.append(Color.WHITE)
	for i in range(n - 1):
		var a := i * 3
		# Godot 正面为顺时针绕序：顶视时 (左,右,下一个左) 是逆时针 → 会被背面剔除。
		# 左半块
		idxs.append(a)
		idxs.append(a + 3)
		idxs.append(a + 1)
		idxs.append(a + 1)
		idxs.append(a + 3)
		idxs.append(a + 4)
		# 右半块
		idxs.append(a + 1)
		idxs.append(a + 4)
		idxs.append(a + 2)
		idxs.append(a + 2)
		idxs.append(a + 4)
		idxs.append(a + 5)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = cols
	arrays[Mesh.ARRAY_INDEX] = idxs
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mi := MeshInstance3D.new()
	mi.name = "Road_%d" % idx
	mi.mesh = mesh
	var road_mat := PbrAssets.road()
	road_mat.uv1_scale = Vector3.ONE
	# 沥青压暗，才能和城市混凝土地面拉开层次（但不能压成死黑）
	road_mat.albedo_color = Color(0.54, 0.545, 0.56)
	mi.material_override = road_mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(mi)
	_build_lane_markings(root, pts, ys, width, idx)


func _build_lane_markings(root: Node3D, pts: Array, ys: Array, width: float, idx: int) -> void:
	var dense := _densify_road(pts, ys, 4.0)
	var dpts: Array = dense["pts"]
	var n := dpts.size()
	if n < 2:
		return
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var cols := PackedColorArray()
	var idxs := PackedInt32Array()
	var base := 0
	var dist := 0.0
	var dash_on := true
	var next_dash := 0.0
	for i in n:
		var p: Vector2 = dpts[i]
		var prev: Vector2 = dpts[maxi(i - 1, 0)]
		var next: Vector2 = dpts[mini(i + 1, n - 1)]
		var dir := (next - prev)
		if dir.length() < 0.0001:
			dir = Vector2(0.0, 1.0)
		dir = dir.normalized()
		var side := Vector2(-dir.y, dir.x)
		if i > 0:
			dist += p.distance_to(prev)
		var y: float = height_at(p.x, p.y) + 0.04
		# 中央虚线（黄）
		if dist >= next_dash:
			dash_on = not dash_on
			next_dash = dist + (4.0 if dash_on else 9.0)
		if dash_on and i % 2 == 0:
			var w := 0.22
			verts.append(Vector3(p.x - side.x * w, y, p.y - side.y * w))
			verts.append(Vector3(p.x + side.x * w, y, p.y + side.y * w))
			norms.append(Vector3.UP)
			norms.append(Vector3.UP)
			cols.append(Color(0.95, 0.82, 0.25))
			cols.append(Color(0.95, 0.82, 0.25))
			idxs.append(base)
			idxs.append(base + 2)
			idxs.append(base + 1)
			idxs.append(base + 1)
			idxs.append(base + 2)
			idxs.append(base + 3)
			base += 4
	if verts.is_empty():
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_COLOR] = cols
	arrays[Mesh.ARRAY_INDEX] = idxs
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 1.0, 1.0)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var mi := MeshInstance3D.new()
	mi.name = "RoadMark_%d" % idx
	mi.mesh = mesh
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(mi)


# ---------------------------------------------------------------------------
# 地形网格
# ---------------------------------------------------------------------------

func _build_terrain() -> void:
	var root := Node3D.new()
	root.name = "Terrain"
	add_child(root)
	var per := int(GRID / CHUNKS)
	for cz in CHUNKS:
		for cx in CHUNKS:
			_build_terrain_chunk(root, cx * per, cz * per, per)


func _build_terrain_chunk(root: Node3D, i0: int, j0: int, span: int) -> void:
	var side := span + 1
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var cols := PackedColorArray()
	verts.resize(side * side)
	norms.resize(side * side)
	uvs.resize(side * side)
	cols.resize(side * side)
	for j in side:
		var gj := j0 + j
		var wz := -HALF + float(gj) * CELL
		for i in side:
			var gi := i0 + i
			var wx := -HALF + float(gi) * CELL
			var idx := gj * GRID + gi
			var h := heights[idx]
			verts[j * side + i] = Vector3(wx, h, wz)
			norms[j * side + i] = _normal_at_grid(gi, gj)
			uvs[j * side + i] = Vector2(wx, wz) * (1.0 / 3.6)
			cols[j * side + i] = _ground_color(wx, wz, h, kind_ids[idx], 1.0 - norms[j * side + i].y)
	var idxs := PackedInt32Array()
	idxs.resize(span * span * 6)
	var w := 0
	for j in span:
		for i in span:
			var a := j * side + i
			# 顶视时 (左下, 右下, 左上) 是逆时针 → Godot 会背面剔除，整块地形会消失。
			# 正面要顺时针，所以把第二个和第三个顶点对调。
			idxs[w] = a
			idxs[w + 1] = a + 1
			idxs[w + 2] = a + side
			idxs[w + 3] = a + 1
			idxs[w + 4] = a + side + 1
			idxs[w + 5] = a + side
			w += 6
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = cols
	arrays[Mesh.ARRAY_INDEX] = idxs
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.albedo_color = Color(1.0, 1.0, 1.0)
	# 地面 PBR 贴图 × 顶点色：顶点色定色域，贴图给近景细节。
	# 反照率用灰度细节图（均值为 1 的亮度图），色相完全交给顶点色——
	# 直接用原彩色草地贴图会把所有域都染绿，城区会黑成一块。
	# UV 系数 1/3.6 → 3.6m 一张，和主赛道的地表尺度一致。
	var ground_tex := PbrAssets.tex("textures/aerial_grass_rock/aerial_grass_rock_detail.jpg")
	if ground_tex != null:
		mat.albedo_texture = ground_tex
		mat.uv1_scale = Vector3.ONE
	var ground_nor := PbrAssets.tex("textures/aerial_grass_rock/aerial_grass_rock_nor.jpg")
	if ground_nor != null:
		mat.normal_enabled = true
		mat.normal_texture = ground_nor
		mat.normal_scale = 0.85
	var ground_rough := PbrAssets.tex("textures/aerial_grass_rock/aerial_grass_rock_rough.jpg")
	if ground_rough != null:
		mat.roughness_texture = ground_rough
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	mat.roughness = 1.0
	mat.metallic = 0.0
	mat.metallic_specular = 0.10
	mat.specular_mode = BaseMaterial3D.SPECULAR_SCHLICK_GGX
	var mi := MeshInstance3D.new()
	mi.name = "Chunk_%d_%d" % [cx_index(i0, span), cz_index(j0, span)]
	mi.mesh = mesh
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(mi)


func cx_index(i0: int, span: int) -> int:
	return i0 / span


func cz_index(j0: int, span: int) -> int:
	return j0 / span


func _normal_at_grid(gi: int, gj: int) -> Vector3:
	var h_l := heights[gj * GRID + maxi(gi - 1, 0)]
	var h_r := heights[gj * GRID + mini(gi + 1, GRID - 1)]
	var h_d := heights[maxi(gj - 1, 0) * GRID + gi]
	var h_u := heights[mini(gj + 1, GRID - 1) * GRID + gi]
	return Vector3(h_l - h_r, 2.0 * CELL, h_d - h_u).normalized()


## 顶点色：按区域给基色，再按海拔 / 坡度叠沙滩、雪线、岩壁。
## 不叠高频噪声——网格只有 ~15m 一格，逐顶点噪声会变成明显的横向条纹。
## slope：0 = 水平，1 = 垂直。陡坡要退回岩石色，否则整座雪山是一块白板、没有体积。
##
## kind_id 是「地貌特效类别」（见 KIND_NAMES / _effect_kind），
## 它按地形权重判定，和基色用的颜色权重是两套独立的东西：
## 基色要长过渡（域与域之间慢慢渗），特效必须认死理（这一块就是雪域就是岩域）。
func _ground_color(x: float, z: float, h: float, kind_id: int, slope: float = 0.0) -> Color:
	var kind := "wild"
	if kind_id >= 0 and kind_id < KIND_NAMES.size():
		kind = String(KIND_NAMES[kind_id])
	# 基色按域权重渐变混合：相邻域在两域中点混色，
	# 整块 9km 大陆连成一片，而不是八块拼贴板。
	# 这一步在 33 万个顶点上跑，所以必须零分配：直接累加颜色和权重，
	# 不建字典、不建数组（早期版本每个顶点建一个 dict 数组，
	# 构建时间直接翻了 1.5 倍）。
	var total := 0.0
	var acc := Color(0.0, 0.0, 0.0)
	for i in ZONES.size():
		var zi: Dictionary = ZONES[i]
		var zc: Vector2 = zi["center"]
		var w := _color_zone_weight(Vector2(x - zc.x, z - zc.y).length(), float(zi["radius"]))
		if w <= 0.002:
			continue
		total += w
		acc += ZONE_BASE_COLORS[i] * w
	var hub_d := Vector2(x - HUB_CENTER.x, z - HUB_CENTER.y).length()
	var wh := _color_zone_weight(hub_d, float(ZONE_HUB["radius"]))
	if wh > 0.002:
		total += wh
		acc += HUB_BASE_COLOR * wh
	# 兜底：所有域的权重都是 0（离所有域都很远）→ 荒野色。
	var c := WILD_BASE_COLOR
	if total > 0.001:
		c = acc / total
	# 近海沙滩
	if h < 4.5 and h > -4.0:
		c = c.lerp(Color(0.64, 0.57, 0.42), clampf(1.0 - (h + 4.0) / 8.5, 0.0, 1.0))
	# 高处岩石 / 雪线
	if h > 95.0:
		var snow := clampf((h - 95.0) / 85.0, 0.0, 1.0)
		if kind == "magma":
			c = c.lerp(Color(0.15, 0.10, 0.09), snow)
		elif kind != "urban":
			c = c.lerp(Color(0.78, 0.82, 0.88), snow)
	# 水下
	if h < -1.0:
		c = c.lerp(Color(0.11, 0.18, 0.21), clampf(-h / 26.0, 0.0, 0.85))
	# 陡坡露岩 —— 必须放在最后：雪坡挂不住雪，陡面露深色岩体，山才有明暗和体积。
	# 放在雪线之前会被「高处全白」覆盖掉，出来的还是一块白板。
	match kind:
		"canyon":
			# 水平岩层：按海拔做色带（周期 ~45m），越深越暗，才有沉积岩层理
			var band := fposmod(h * 0.022, 1.0)
			c = c.lerp(Color(0.36, 0.17, 0.12), band * 0.42)
		_:
			pass
	match kind:
		"alpine", "glacier":
			c = c.lerp(Color(0.27, 0.29, 0.33), clampf((slope - 0.035) * 3.6, 0.0, 0.82))
		"canyon":
			c = c.lerp(Color(0.36, 0.20, 0.15), clampf((slope - 0.08) * 2.6, 0.0, 0.70))
		"magma":
			c = c.lerp(Color(0.16, 0.10, 0.09), clampf((slope - 0.07) * 2.4, 0.0, 0.62))
		"wild":
			c = c.lerp(Color(0.38, 0.36, 0.31), clampf((slope - 0.12) * 2.4, 0.0, 0.58))
		_:
			pass
	return c


func _build_sea() -> void:
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/water.gdshader")
	mat.set_shader_parameter("deep_color", Color(0.02, 0.10, 0.20))
	mat.set_shader_parameter("shallow_color", Color(0.06, 0.36, 0.44))
	mat.set_shader_parameter("crest_color", Color(0.52, 0.80, 0.84))
	mat.set_shader_parameter("wave_scale", 0.035)
	mat.set_shader_parameter("wave_height", 0.30)
	var plane := PlaneMesh.new()
	plane.size = Vector2(WORLD_SIZE * 3.4, WORLD_SIZE * 3.4)
	plane.subdivide_width = 1
	plane.subdivide_depth = 1
	var mi := MeshInstance3D.new()
	mi.name = "Sea"
	mi.mesh = plane
	mi.material_override = mat
	mi.position = Vector3(0.0, SEA_LEVEL, 0.0)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)


# ---------------------------------------------------------------------------
# 采样与查询
# ---------------------------------------------------------------------------

## 双线性高度（平滑版）。
## 只用于法线 / 坡度：如果法线也用三角面高度，
## 坡度会一块一块地跳（每 15.6m 一档），植被撒点会被整格整格地筛掉。
func _height_bilinear(x: float, z: float) -> float:
	var gx := (x + HALF) / CELL
	var gz := (z + HALF) / CELL
	if gx < 0.0 or gz < 0.0 or gx > float(GRID - 1) or gz > float(GRID - 1):
		return -30.0
	var i := int(floor(gx))
	var j := int(floor(gz))
	var fx := gx - float(i)
	var fz := gz - float(j)
	var i1 := mini(i + 1, GRID - 1)
	var j1 := mini(j + 1, GRID - 1)
	var h00 := heights[j * GRID + i]
	var h10 := heights[j * GRID + i1]
	var h01 := heights[j1 * GRID + i]
	var h11 := heights[j1 * GRID + i1]
	return lerpf(lerpf(h00, h10, fx), lerpf(h01, h11, fx), fz)


## 地形网格的真实表面高度（与 _build_terrain_chunk 的三角化完全一致）。
##
## 地形网格每个格被切成两个三角形，双线性插值和真实三角面并不相等：
## 差值 = (h10 + h01 - h00 - h11) / 4，陡坡上实测能到 1.4m。
## 以前车辆贴地、路面网格都取双线性值，而画面上的地形是三角面，
## 于是：地形从路面下戳出来把路切成锯齿，车也相对可见地面浮起来 / 陷下去。
## 现在统一用三角面高度：物理 = 画面 = 路面，三者永远一致。
func height_at(x: float, z: float) -> float:
	var gx := (x + HALF) / CELL
	var gz := (z + HALF) / CELL
	if gx < 0.0 or gz < 0.0 or gx > float(GRID - 1) or gz > float(GRID - 1):
		return -30.0
	var i := int(floor(gx))
	var j := int(floor(gz))
	var fx := gx - float(i)
	var fz := gz - float(j)
	var i1 := mini(i + 1, GRID - 1)
	var j1 := mini(j + 1, GRID - 1)
	var h00 := heights[j * GRID + i]
	var h10 := heights[j * GRID + i1]
	var h01 := heights[j1 * GRID + i]
	var h11 := heights[j1 * GRID + i1]
	# 第一个三角形 (h00, h10, h01) 覆盖 fx+fz <= 1 的那半
	if fx + fz <= 1.0:
		return h00 + (h10 - h00) * fx + (h01 - h00) * fz
	# 第二个三角形 (h10, h11, h01)
	var wa := fx + fz - 1.0
	var wb := 1.0 - fz
	var wc := 1.0 - fx
	return wa * h11 + wb * h10 + wc * h01


## 地形网格的真实表面高度（= height_at，保留旧名方便外部调用）。
func surface_height_at(x: float, z: float) -> float:
	return height_at(x, z)


## 路面贴合自检：路面网格画在 height_at() + off，地形按三角面画。
## 这里沿路横向取样，算地形真实表面比路面高出多少——
## 这个值就是"地形从路面下戳出来"的深度。
func probe_road_fit(off: float = 0.025) -> Dictionary:
	var worst_poke := -1e9
	var worst_tri := 0.0
	var worst_at := Vector3.ZERO
	var samples := 0
	var over := [0, 0, 0, 0, 0]   # >0.05 / >0.2 / >0.5 / >1.0 / >3.0 m
	var over_total := 0
	for road in roads:
		var pts: Array = road["pts"]
		var width: float = float(road["width"])
		var half := width * 0.5
		for i in range(pts.size() - 1):
			var a: Vector2 = pts[i]
			var b: Vector2 = pts[i + 1]
			var seg := a.distance_to(b)
			var n := maxi(int(ceil(seg / 1.0)), 1)
			for k in n:
				var p := a.lerp(b, float(k) / float(n))
				var hb := height_at(p.x, p.y)
				var ht := surface_height_at(p.x, p.y)
				worst_tri = maxf(worst_tri, absf(ht - hb))
				var dir := (b - a)
				if dir.length() < 0.0001:
					continue
				dir = dir.normalized()
				var side := Vector2(-dir.y, dir.x)
				# 路面是横向三点贴合地形的：路缘 / 中线 / 路缘
				var lp := p - side * half
				var rp := p + side * half
				var y_l := height_at(lp.x, lp.y) + off
				var y_r := height_at(rp.x, rp.y) + off
				for t in [-1.0, -0.6, -0.3, 0.0, 0.3, 0.6, 1.0]:
					var q := p + side * (half * float(t))
					var hq := surface_height_at(q.x, q.y)
					var y_road := lerpf(y_l, y_r, (float(t) + 1.0) * 0.5)
					var pk := hq - y_road
					if pk > worst_poke:
						worst_poke = pk
						worst_at = Vector3(q.x, hq, q.y)
					if pk > 0.05:
						over[0] += 1
						over_total += 1
						if pk > 0.2:
							over[1] += 1
						if pk > 0.5:
							over[2] += 1
						if pk > 1.0:
								over[3] += 1
						if pk > 3.0:
							over[4] += 1
				samples += 1
	return {"poke": worst_poke, "tri": worst_tri, "at": worst_at, "samples": samples,
		"over": over, "over_total": over_total}


func normal_at(x: float, z: float) -> Vector3:
	var e := CELL
	# 用双线性高度算法线：三角面高度会让法线一块一块地跳，
	# 坡度跟着跳，植被撒点就会被整格整格地筛掉（树上山一片一片）。
	var hl := _height_bilinear(x - e, z)
	var hr := _height_bilinear(x + e, z)
	var hd := _height_bilinear(x, z - e)
	var hu := _height_bilinear(x, z + e)
	return Vector3(hl - hr, 2.0 * e, hd - hu).normalized()


## 坡度（0 = 平地，1 = 45°）。
func slope_at(x: float, z: float) -> float:
	var n := normal_at(x, z)
	return clampf(1.0 - n.y, 0.0, 1.0) * 1.4142


func road_distance_at(x: float, z: float) -> float:
	var gx := int(round((x + HALF) / CELL))
	var gz := int(round((z + HALF) / CELL))
	if gx < 0 or gz < 0 or gx >= GRID or gz >= GRID:
		return 99999.0
	return road_dist[gz * GRID + gx]


## 到最近「路面边缘」的距离（米）。
##
## road_distance_at 给的是到路中心线的距离，可路面本身还有半宽
## （街道 6m、环城路 8.5m）。判断一栋楼有没有压到路面上，
## 必须用边缘距离：拿中心线距离去比楼体占位半径，
## 等于凭空给楼放行了半个路宽，楼就直接骑在路上。
##
## 注意 road_dist 是按 15.6m 高度场格点存的，带量化误差，
## 调用方还要自己留一点安全余量。
func road_edge_distance_at(x: float, z: float) -> float:
	var gx := int(round((x + HALF) / CELL))
	var gz := int(round((z + HALF) / CELL))
	if gx < 0 or gz < 0 or gx >= GRID or gz >= GRID:
		return 99999.0
	var idx := gz * GRID + gx
	return road_dist[idx] - road_half_near[idx]


func is_on_road(x: float, z: float) -> bool:
	# 用每个格点实际记录的路面半宽判断，而不是固定阈值：
	# 固定阈值会把路肩算成路面（那里其实还是野地），
	# 结果是车在路肩上按沥青抓地、却跟着土路起伏走，直接陷进地里。
	var gx := int(round((x + HALF) / CELL))
	var gz := int(round((z + HALF) / CELL))
	if gx < 0 or gz < 0 or gx >= GRID or gz >= GRID:
		return false
	var idx := gz * GRID + gx
	var half: float = road_half[idx]
	if half <= 0.0:
		return false
	return road_dist[idx] <= half + 0.6


# ---------------------------------------------------------------------------
# 静态实体碰撞
# ---------------------------------------------------------------------------

## 登记一个静态碰撞体。half 为局部半尺寸（未旋转），rot 为绕 Y 的偏航角，
## y0/y1 为它在世界里的垂直范围。
func add_collider(pos: Vector2, half: Vector2, rot: float, y0: float, y1: float) -> void:
	# rad 是外接半径：车辆每帧要扫几千个碰撞体，先用一次平方距离比较
	# 把绝大多数挡路的排除掉，再做昂贵的坐标变换。
	var rad := half.length()
	var c := {"pos": pos, "half": half, "rot": rot, "y0": y0, "y1": y1, "rad": rad}
	var key := "%d_%d" % [int(floor(pos.x / COLL_CELL)), int(floor(pos.y / COLL_CELL))]
	if not _collider_hash.has(key):
		_collider_hash[key] = []
	_collider_hash[key].append(c)


## 查询附近 r 米内的静态碰撞体。
func query_colliders(x: float, z: float, r: float) -> Array:
	var out: Array = []
	var cx := int(floor(x / COLL_CELL))
	var cz := int(floor(z / COLL_CELL))
	var span := int(ceil(r / COLL_CELL))
	for dx in range(-span, span + 1):
		for dz in range(-span, span + 1):
			var arr: Array = _collider_hash.get("%d_%d" % [cx + dx, cz + dz], [])
			for c in arr:
				out.append(c)
	return out


## 把 (x, z) 推出附近所有静态碰撞体。
## 几何逻辑放在世界里而不是车辆里：全世界只有这一份实现，
## 也不会每帧为了返回结果而新建一个数组。
## 返回 {pos: Vector2, hit: bool, normal: Vector2, depth: float}。
func push_out(x: float, z: float, radius: float, y: float) -> Dictionary:
	var px := x
	var pz := z
	var hit := false
	var n_acc := Vector2.ZERO
	var depth_acc := 0.0
	var cx := int(floor(x / COLL_CELL))
	var cz := int(floor(z / COLL_CELL))
	var span := int(ceil(radius / COLL_CELL))
	for dx in range(-span, span + 1):
		for dz in range(-span, span + 1):
			var arr: Array = _collider_hash.get("%d_%d" % [cx + dx, cz + dz], [])
			for c in arr:
				# 粗筛：外接半径都够不着就直接跳过（树多起来后这一步最关键）
				var cpos: Vector2 = c["pos"]
				var dx0 := px - cpos.x
				var dz0 := pz - cpos.y
				var reach := radius + float(c["rad"])
				if dx0 * dx0 + dz0 * dz0 > reach * reach:
					continue
				# 只有与车身高度有交集的障碍才参与推出
				if y + 1.2 < float(c["y0"]) or y + 0.1 > float(c["y1"]):
					continue
				var cp: Vector2 = c["pos"]
				var half: Vector2 = c["half"]
				var rot: float = c["rot"]
				# 世界 → 局部（绕 Y 旋转的逆变换）。
				# Basis(Vector3.UP, yaw) 的 x 轴是 (cos, 0, -sin)，所以逆变换是
				# lx = dx*cos - dz*sin、lz = dx*sin + dz*cos。
				# 符号写反的话，斜放的楼会变成一堵堵错位的墙。
				var cs := cos(rot)
				var sn := sin(rot)
				var ox := px - cp.x
				var oz := pz - cp.y
				var lx := ox * cs - oz * sn
				var lz := ox * sn + oz * cs
				# 圆心到盒的最近点
				var qx := clampf(lx, -half.x, half.x)
				var qz := clampf(lz, -half.y, half.y)
				var ddx := lx - qx
				var ddz := lz - qz
				var dist := sqrt(ddx * ddx + ddz * ddz)
				var push_len := 0.0
				var lnx := 0.0
				var lnz := 0.0
				if dist > 0.0001:
					if dist >= radius:
						continue
					push_len = radius - dist
					lnx = ddx / dist
					lnz = ddz / dist
				else:
					# 圆心已经在盒内：沿最近的面把它挤出去
					var dxa := half.x - absf(lx)
					var dza := half.y - absf(lz)
					if dxa < dza:
						push_len = dxa + radius
						lnx = 1.0 if lx >= 0.0 else -1.0
						lnz = 0.0
					else:
						push_len = dza + radius
						lnx = 0.0
						lnz = 1.0 if lz >= 0.0 else -1.0
				# 局部 → 世界
				var cs2 := cos(rot)
				var sn2 := sin(rot)
				var wnx := lnx * cs2 + lnz * sn2
				var wnz := -lnx * sn2 + lnz * cs2
				px += wnx * push_len
				pz += wnz * push_len
				hit = true
				n_acc += Vector2(wnx, wnz) * push_len
				depth_acc += push_len
	return {
		"pos": Vector2(px, pz),
		"hit": hit,
		"normal": (n_acc / maxf(depth_acc, 0.0001)).normalized() if hit else Vector2.ZERO,
		"depth": depth_acc,
	}


func collider_count() -> int:
	var n := 0
	for k in _collider_hash.keys():
		n += (_collider_hash[k] as Array).size()
	return n


## 水深：海面为 0 高程，冰川湖为 LAKE_LEVEL，其余为 0。
func depth_at(x: float, z: float) -> float:
	var h := height_at(x, z)
	if h < SEA_LEVEL:
		return SEA_LEVEL - h
	var lc := Vector2(x - LAKE_CENTER.x, z - LAKE_CENTER.y).length()
	if lc < LAKE_RADIUS and h < LAKE_LEVEL:
		return LAKE_LEVEL - h
	return 0.0


## 返回该点所属区域定义；不在任何域内返回 {}。
func zone_at(x: float, z: float) -> Dictionary:
	var best := -1
	var best_w := 0.0
	for i in ZONES.size():
		var zone: Dictionary = ZONES[i]
		var c: Vector2 = zone["center"]
		var d := Vector2(x - c.x, z - c.y).length()
		var w := _zone_weight(d, float(zone["radius"]))
		if w > best_w:
			best_w = w
			best = i
	if best < 0:
		return {}
	return ZONES[best]


func zone_index_at(x: float, z: float) -> int:
	var best := -1
	var best_w := 0.0
	for i in ZONES.size():
		var zone: Dictionary = ZONES[i]
		var c: Vector2 = zone["center"]
		var d := Vector2(x - c.x, z - c.y).length()
		var w := _zone_weight(d, float(zone["radius"]))
		if w > best_w:
			best_w = w
			best = i
	if best_w <= 0.0:
		return -1
	return best


func zone_center(id: String) -> Vector2:
	for z in ZONES:
		if String(z["id"]) == id:
			return z["center"]
	return Vector2.ZERO


## 地面类型：road / sand / grass / rock / snow / ice / lava / water
func surface_at(x: float, z: float) -> String:
	var h := height_at(x, z)
	if h < SEA_LEVEL - 0.6:
		return "water"
	var zone := zone_at(x, z)
	var kind := String(zone.get("kind", "wild"))
	if is_on_road(x, z):
		return "road"
	if kind == "magma":
		var vc := Vector2(x - VOLCANO_CENTER.x, z - VOLCANO_CENTER.y).length()
		if vc < VOLCANO_RADIUS * 0.62 and h < 60.0:
			return "lava"
		return "rock"
	if kind == "alpine":
		return "snow" if h > 110.0 else "rock"
	if kind == "glacier":
		var lc := Vector2(x - LAKE_CENTER.x, z - LAKE_CENTER.y).length()
		if lc < LAKE_RADIUS * 0.85 and h < LAKE_LEVEL:
			return "water"
		return "ice"
	if kind == "canyon":
		return "rock"
	if kind == "beach":
		return "sand" if h < 9.0 else "grass"
	if kind == "urban":
		return "road" if is_on_road(x, z) else "grass"
	return "sand" if h < 4.0 else "grass"


## 出生点：霓虹都市外环的一个路口，朝向主干道。
func spawn() -> Dictionary:
	var zone: Dictionary = ZONES[0]
	var c: Vector2 = zone["center"]
	var p := c + Vector2(-260.0, 0.0)
	var h := height_at(p.x, p.y)
	return {"pos": Vector3(p.x, h, p.y), "heading": 0.0, "zone": "neon"}


## 把越界的点拉回最近的陆地区域（防止玩家永久卡在海里）。
func clamp_to_land(pos: Vector3) -> Vector3:
	var p := pos
	for i in 8:
		var h := height_at(p.x, p.z)
		if h > 1.2:
			break
		var d := road_distance_at(p.x, p.z)
		if d < 9000.0:
			break
		p = Vector3(p.x * 0.86, p.y, p.z * 0.86)
	p.y = height_at(p.x, p.z)
	return p


## 找到离给定点最近的道路中心点（用于救援 / AI 目标）。
## 最近道路点 + 该点的道路切线方向。
## 把车摆到公路上时要用切线定朝向，否则车会横着扎进路肩再滑到野地里。
func nearest_road_frame(x: float, z: float) -> Dictionary:
	var best := Vector3(x, height_at(x, z), z)
	var best_d := 1.0e20
	var best_dir := Vector3(0.0, 0.0, 1.0)
	for road in roads:
		var pts: Array = road["pts"]
		for i in pts.size():
			var p: Vector2 = pts[i]
			var d := Vector2(x - p.x, z - p.y).length_squared()
			if d < best_d:
				best_d = d
				best = Vector3(p.x, height_at(p.x, p.y), p.y)
				var prev: Vector2 = pts[maxi(i - 1, 0)]
				var nxt: Vector2 = pts[mini(i + 1, pts.size() - 1)]
				best_dir = Vector3(nxt.x - prev.x, 0.0, nxt.y - prev.y)
	if best_dir.length_squared() < 0.0001:
		best_dir = Vector3(0.0, 0.0, 1.0)
	return {"pos": best, "dir": best_dir.normalized()}


func nearest_road_point(x: float, z: float) -> Vector3:
	var best := Vector3(x, height_at(x, z), z)
	var best_d := 1.0e20
	for road in roads:
		var pts: Array = road["pts"]
		for i in pts.size():
			var p: Vector2 = pts[i]
			var d := Vector2(x - p.x, z - p.y).length_squared()
			if d < best_d:
				best_d = d
				best = Vector3(p.x, height_at(p.x, p.y), p.y)
	return best
