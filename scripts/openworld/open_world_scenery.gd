class_name OpenWorldScenery
extends RefCounted
## 无界大陆的八域布景。
##
## 所有摆放都走 RealAssetKit 的 MultiMesh 批处理，一件资产一个 draw call 级别，
## 位置由高度场决定（建筑贴地、树避开坡度太陡的地方），并统一避开道路走廊。

## 当前正在布景的世界：登记静态碰撞体时要用。
static var _active_world: OpenWorld = null

## 建筑退线的路肩余量（米）：楼体外边缘离路面边缘至少留这么多。
## 楼是随机偏航摆的，用外接圆半径算占位，已经比真实轮廓保守，
## 这里留一点余量把「路肩」也算进去。
const ROAD_SHOULDER := 3.5

const NEON_SIGNS := [
	Color(1.0, 0.20, 0.55), Color(0.25, 0.95, 1.0), Color(1.0, 0.70, 0.20),
	Color(0.55, 0.35, 1.0), Color(0.25, 1.0, 0.55), Color(1.0, 0.35, 0.20),
]

const TREE_PINES := ["realtree_fir_full", "realtree_fir", "lowtree_pine", "realtree_pine"]
const TREE_BROAD := ["realtree_01", "realtree_02", "realtree_03", "realtree_broadleaf", "tree_broadleaf"]
const TREE_PALMS := ["tree_palm_tall", "tree_palm_bent", "lowtree_palm", "tree_palm"]
const ROCKS := ["boulder02", "boulder03", "rock_face", "mountain_real"]
const BUSHES := ["shrub_real", "shrub_real01", "shrub_real02", "shrub_real04", "shrub_coastal"]
const DEAD_TREES := ["realtree_dead", "realtree_quiver", "realtree_quiver01"]

## 城市楼体池：[资产名, 目标高度, 权重, 占位半径上限(米)]
##
## 占位半径上限是修「楼骑在路上」的核心：
## 净空判据从「楼心离路多远」改成「楼体离路多远」之后，
## 楼体就必须真的塞不进路里 —— 所以横向尺寸要压住。
##
## 高度目标也一起改了：downtown_large 天然 28m 高、20.6×16.6m 占地，
## 原来按 78~92m 目标高度放大，缩放倍率到 4.3，摊成 88m 宽的一堵墙；
## 实际按 40m 左右放才是一栋正常的楼。真正的高楼交给天然纤细的
## colony_tower（91m 高、16m 宽）和 station_tower。
const POOL_NEON := [
	["downtown_large", 40.0, 0.26, 15.0],
	["downtown_medium", 30.0, 0.34, 13.0],
	["downtown_small", 20.0, 0.40, 12.0],
	["station_tower", 58.0, 0.13, 15.0],
	["colony_tower", 108.0, 0.07, 16.0],
]
const POOL_SKYLINE := [
	["downtown_large", 46.0, 0.24, 15.0],
	["downtown_medium", 34.0, 0.32, 14.0],
	["downtown_small", 22.0, 0.26, 12.0],
	["station_tower", 66.0, 0.12, 15.0],
	["colony_tower", 132.0, 0.06, 16.0],
]
## 地标塔楼：全部用天然纤细的塔（长宽比都在 4:1 以上），
## 放大后依然是一根塔，而不是摊开的一堵墙。
const POOL_HERO := [
	["colony_tower", 176.0, 1.0, 18.0],
	["station_tower", 152.0, 1.0, 17.0],
	["blockchain_tower", 96.0, 1.0, 26.0],
	["memefactory_tower", 118.0, 1.0, 30.0],
]
## lovedeath_tower 是桥（LoveDeath_Tower_Bridge_Art），横着摆才有意义，
## 竖起来放大只会变成一堵横墙 —— 改到港湾当跨海桥用（见 _build_harbor）。


# ---------------------------------------------------------------------------
# 流式布景：走到哪，建到哪
# ---------------------------------------------------------------------------

## 各类布景的可见距离系数（所有画质档统一，最终距离 = vis_end × 系数）。
## 树占实测面数的 51.5%、楼占 25%，单棵树最高 10 万面、单栋楼 2~5 万面，
## 全距离常驻在 M1 Pro 上实测每帧 3500 万面、平均 5fps。远处反正有雾压着：
## 楼收得最狠（484m），树次之（306m），地标塔 / 大桥保留地平线剪影（1170m+）。
## 其余小件（岩石、灌木、杂物）按默认 0.30。
## 画质档不该放大开放世界的绘制距离（9×9km 图上一放大就是几百万面），
## 所以传参按 place_chunked 内部的画质系数归一化，各档实际距离一致。
const VIS_BUILDING := 0.22
const VIS_TREE := 0.34
const VIS_HERO := 0.45
const VIS_DEFAULT := 0.30
const VIS_CLASS := {
	"NeonBlock": VIS_BUILDING, "SkyBlock": VIS_BUILDING, "SkyApt": VIS_BUILDING,
	"HarborShed": VIS_BUILDING, "AlpineHut": VIS_BUILDING,
	"MagmaRefinery": VIS_BUILDING, "MagmaPipe": VIS_BUILDING,
	"StreetTree": VIS_TREE, "TransitionTree": VIS_TREE,
	"CoastPalm": VIS_TREE, "CoastBush": VIS_TREE, "CanyonDead": VIS_TREE,
	"AlpinePine": VIS_TREE, "GlacierPine": VIS_TREE, "MagmaBurnt": VIS_TREE,
	"CoastBroad": VIS_TREE, "CanyonBroad": VIS_TREE,
	"AlpineBroad": VIS_TREE, "GlacierMix": VIS_TREE,
	"NeonHero": VIS_HERO, "HarborBridge": VIS_HERO, "HarborTower": VIS_HERO,
	"HarborShip": VIS_HERO, "FrozenShip": VIS_HERO,
}

## 开局只建出生点周围这么远内的单元（出生域 + 相邻过渡带 ≈ 1.5s，替代原来 4.8s 全量）。
const INITIAL_RANGE := 3200.0
## 玩家逼近到「单元半径 + 这么远」就开始建。比所有可见距离都远，
## 建完时玩家还看不到域内任何东西，不会看到内容凭空弹出。
const STREAM_TRIGGER := 1700.0
## 建好的单元远离后整体隐藏 / 重新显示的阈值（带滞回防抖）。
const HIDE_EXTRA := 2400.0
const SHOW_EXTRA := 2100.0

## 布景单元：8 个域 + 8 条域间过渡带。
## {name: String, center: Vector2, radius: float, kind: "zone"/"band", idx: int}
static var _units: Array = []
static var _built_units: Dictionary = {}
static var _unit_containers: Dictionary = {}
static var _scenery_root: Node3D = null
static var _stream_cd := 0.0


## 开局：只建出生点周围的单元，其余由 main 每帧调 stream_tick 按需补建。
## 地形 / 路网 / 海面仍由 OpenWorld 一次性建好（物理贴地依赖全局高度场）。
static func build_initial(world: OpenWorld, parent: Node3D) -> Dictionary:
	var stats: Dictionary = {"nodes": 0, "instances": 0}
	_active_world = world
	_units.clear()
	_built_units.clear()
	_unit_containers.clear()
	_stream_cd = 0.0
	for i in OpenWorld.ZONES.size():
		var z: Dictionary = OpenWorld.ZONES[i]
		_units.append({"name": "zone_%d" % i, "center": z["center"],
			"radius": float(z["radius"]), "kind": "zone", "idx": i})
	for i in OpenWorld.ZONES.size():
		var a: Dictionary = OpenWorld.ZONES[i]
		var b: Dictionary = OpenWorld.ZONES[(i + 1) % OpenWorld.ZONES.size()]
		var ca: Vector2 = a["center"]
		var cb: Vector2 = b["center"]
		_units.append({"name": "band_%d" % i, "center": (ca + cb) * 0.5,
			"radius": ca.distance_to(cb) * 0.26, "kind": "band", "idx": i})
	var root := Node3D.new()
	root.name = "OpenWorldScenery"
	parent.add_child(root)
	_scenery_root = root
	var sp: Vector3 = world.spawn()["pos"]
	ensure_units_at(world, Vector2(sp.x, sp.z), INITIAL_RANGE, stats)
	return stats


## 建出 pos 周围 reach 米内所有未建单元（测试 / 传送后用；无冷却，同步建完）。
static func ensure_units_at(world: OpenWorld, pos: Vector2, reach: float,
		stats: Dictionary = {}) -> void:
	if _active_world != world or _scenery_root == null or not is_instance_valid(_scenery_root):
		return
	for unit in _units:
		if _built_units.has(String(unit["name"])):
			continue
		if pos.distance_to(unit["center"]) <= reach:
			_build_unit(unit, stats)


## 每帧驱动：逼近的单元排队建（每 0.25s 至多一个，把构建卡顿摊开），
## 远离的单元整体隐藏（碰撞体仍保留，看不见的建筑照样挡车）。
## 返回 true 表示这帧建了新单元，调用方应刷新扇区剔除器。
static func stream_tick(world: OpenWorld, pos: Vector2, dt: float) -> bool:
	if _active_world != world or _scenery_root == null or not is_instance_valid(_scenery_root):
		return false
	_stream_cd = maxf(0.0, _stream_cd - dt)
	for unit in _units:
		var uname := String(unit["name"])
		var d := pos.distance_to(unit["center"])
		var cont: Node3D = _unit_containers.get(uname)
		if _built_units.has(uname):
			if is_instance_valid(cont):
				if d > float(unit["radius"]) + HIDE_EXTRA:
					cont.visible = false
				elif d < float(unit["radius"]) + SHOW_EXTRA:
					cont.visible = true
			continue
		if _stream_cd > 0.0:
			continue
		if d <= float(unit["radius"]) + STREAM_TRIGGER:
			_build_unit(unit)
			_stream_cd = 0.25
			return true
	return false


static func _build_unit(unit: Dictionary, stats: Dictionary = {}) -> void:
	var t0 := Time.get_ticks_msec()
	var n0 := int(stats.get("nodes", 0))
	var i0 := int(stats.get("instances", 0))
	var container := Node3D.new()
	var uname := String(unit["name"])
	container.name = "Unit_%s" % uname
	_scenery_root.add_child(container)
	_unit_containers[uname] = container
	var world := _active_world
	if String(unit["kind"]) == "zone":
		match int(unit["idx"]):
			0: _build_neon_city(world, container, stats)
			1: _build_skyline_city(world, container, stats)
			2: _build_harbor(world, container, stats)
			3: _build_coast(world, container, stats)
			4: _build_canyon(world, container, stats)
			5: _build_alpine(world, container, stats)
			6: _build_glacier(world, container, stats)
			7: _build_magma(world, container, stats)
	else:
		_build_transition_band(world, container, int(unit["idx"]), stats)
	_built_units[uname] = true
	print("[OW-STREAM] %-10s nodes=%d instances=%d took=%d ms" % [uname,
		int(stats.get("nodes", 0)) - n0, int(stats.get("instances", 0)) - i0,
		Time.get_ticks_msec() - t0])


# ---------------------------------------------------------------------------
# 通用工具
# ---------------------------------------------------------------------------

static func _rng(seed_value: int) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	return rng


## 在圆形范围内撒点（极坐标 + 抖动），返回世界 XZ 坐标。
static func _scatter(center: Vector2, radius: float, count: int, rng: RandomNumberGenerator,
		inner_ratio: float = 0.0) -> Array[Vector2]:
	var out: Array[Vector2] = []
	for i in count:
		var a := rng.randf() * TAU
		var r := radius * sqrt(rng.randf())
		r = lerpf(radius * inner_ratio, radius, r / maxf(radius, 0.001))
		out.append(center + Vector2(cos(a) * r, sin(a) * r))
	return out


## 网格撒点（城市用），带随机抖动；结果打乱，
## 否则按行列顺序取前 N 个会把所有楼挤成一条线。
static func _grid(center: Vector2, radius: float, spacing: float, rng: RandomNumberGenerator) -> Array[Vector2]:
	var out: Array[Vector2] = []
	var n := int(radius * 2.0 / spacing)
	var start := -n / 2
	for i in range(start, start + n):
		for j in range(start, start + n):
			var p := center + Vector2(float(i) * spacing, float(j) * spacing)
			if p.distance_to(center) > radius:
				continue
			p += Vector2(rng.randf_range(-spacing * 0.22, spacing * 0.22),
				rng.randf_range(-spacing * 0.22, spacing * 0.22))
			out.append(p)
	_shuffle(out, rng)
	return out


static func _shuffle(arr: Array[Vector2], rng: RandomNumberGenerator) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp := arr[i]
		arr[i] = arr[j]
		arr[j] = tmp


static func _keep_clear(p: Vector2, world: OpenWorld, margin: float) -> bool:
	var spawn: Dictionary = world.spawn()
	var sp: Vector3 = spawn["pos"]
	return Vector2(sp.x, sp.z).distance_to(p) > margin


## 摆放一批真实资产，并同步登记静态碰撞体。
## 树 / 楼 / 墙 / 岩石都必须是实体：车要能撞上它们，不能直接穿过去。
## 碰撞体类别由 prefix 推断（见 _collider_kind_for），避免在 30 处调用点
## 逐个传参，也避免以后新增摆点时忘记登记。
static func _place(container: Node3D, asset: String, xforms: Array[Transform3D], prefix: String,
		vis_end: float, shadow: bool, stats: Dictionary) -> void:
	if xforms.is_empty():
		return
	var before := int(stats.get("instances", 0))
	var cls: float = VIS_CLASS.get(prefix, VIS_DEFAULT)
	var cast_shadow := shadow
	# 设置里的「树木阴影」开关以前没有任何代码读取（死设置）。
	# 这里让树类布景真正受它控制：关掉可省整个阴影通道里的树；
	# ULTRA 默认开，观感不变。
	if cls == VIS_TREE and not Settings.tree_shadows:
		cast_shadow = false
	RealAssetKit.place_chunked(container, asset, xforms, prefix,
		vis_end * cls / RealAssetKit.quality_mul(), cast_shadow, stats)
	stats["instances"] = before + xforms.size()
	_register_colliders(asset, xforms, prefix)


## 由摆放 prefix 推断碰撞体类别：
##   box —— 建筑（楼 / 棚 / 塔 / 屋），有明确平面轮廓
##   tree —— 树干（圆柱）
##   cyl —— 岩石 / 管道 / 杆（圆柱）
##   空 —— 灌木、轮胎、浮标、栈桥、远船：太小或不在地面，不参与碰撞
static func _collider_kind_for(prefix: String) -> String:
	var p := prefix.to_lower()
	for k in ["block", "hero", "apt", "shed", "tower", "hut", "refinery", "lighthouse", "deck"]:
		if p.contains(k):
			return "box"
	for k in ["palm", "pine", "dead", "burnt", "broad"]:
		if p.contains(k):
			return "tree"
	for k in ["rock", "pole", "pipe", "barrel"]:
		if p.contains(k):
			return "cyl"
	return ""


## 为一批实例登记静态碰撞体。
## 只登记真正会被摆出去的实例：RealAssetKit 会把压在道路上的摆放丢掉，
## 这里用同一套判据（keepout_clear + true_radius）过滤，
## 否则会出现「看得见的楼没有碰撞体、看不见的楼反而挡路」。
static func _register_colliders(asset: String, xforms: Array[Transform3D], prefix: String) -> void:
	var kind := _collider_kind_for(prefix)
	if kind == "":
		return
	var world := _active_world
	if world == null:
		return
	var sz := RealAssetKit.size(asset)
	var ar := RealAssetKit.true_radius(asset)
	for xform in xforms:
		var sc: float = maxf(xform.basis.get_scale().x, xform.basis.get_scale().z)
		if sc <= 0.001:
			continue
		if not RealAssetKit.keepout_clear(xform.origin, ar * sc):
			continue
		var base_y := xform.origin.y
		var hgt: float = maxf(sz.y * sc, 0.4)
		var half := Vector2(maxf(sz.x, 0.2) * sc * 0.5, maxf(sz.z, 0.2) * sc * 0.5)
		# 碰撞盒要跟着建筑的朝向走。楼是随机偏航摆的，用轴对齐盒会
		# 把斜放的楼撑成一堵堵斜墙 —— 视觉上明明能开过去，物理上却被挡住。
		var rot_basis := xform.basis.orthonormalized()
		var rot := atan2(-rot_basis.x.z, rot_basis.x.x)
		match kind:
			"tree":
				# 树干半径按树高推算（树冠宽不等于树干粗）：0.16×冠幅在
				# 稀树/林荫道里是一片隐形墙，车隔着树干一米多就被弹开。
				# 取 0.05×树高，带一点容错（高速下顶点穿细杆会隧穿）。
				var r: float = clampf(hgt * 0.05, 0.25, 0.85)
				half = Vector2(r, r)
				hgt = maxf(hgt * 0.75, 1.2)
			"cyl":
				var rock_like := RealAssetKit.category_of(asset) == "rock" \
					or asset.to_lower().contains("rock")
				if rock_like:
					# 岩石是实心体：0.42×占位宽是真实接触半径，
					# 再小车头就会视觉上扎进石头
					var r2: float = clampf(maxf(sz.x, sz.z) * sc * 0.42, 0.5, 7.0)
					half = Vector2(r2, r2)
				else:
					# 杆/管/桶按细截面算：电杆横臂 13m 宽也只是装饰，
					# 用 max 维会造出半径 4m 的隐形柱
					var r3: float = clampf(minf(sz.x, sz.z) * sc * 0.5, 0.18, 0.8)
					half = Vector2(r3, r3)
			"box":
				# 包围盒含阳台 / 雨棚，缩到 0.82 才是真正的墙线。
				half *= 0.82
				if half.x < 0.4:
					half.x = 0.4
				if half.y < 0.4:
					half.y = 0.4
		world.add_collider(Vector2(xform.origin.x, xform.origin.z), half, rot,
			base_y - 0.5, base_y + hgt)


## 依据目标高度与随机朝向生成实例变换。
## 往"按资产分组"的字典里塞一个变换。
## 字典值必须是 Array[Transform3D]（类型化数组），
## 否则 _place / RealAssetKit.place_chunked 会报
## "does not have the same element type as the expected typed array argument"。
static func _push_xf(bucket: Dictionary, asset: String, xf: Transform3D) -> void:
	if not bucket.has(asset):
		var empty: Array[Transform3D] = []
		bucket[asset] = empty
	var lst: Array[Transform3D] = bucket[asset]
	lst.append(xf)


static func _xform(world: OpenWorld, p: Vector2, target_h: float, asset: String, yaw: float,
		sink: float = 0.06) -> Transform3D:
	var h := world.height_at(p.x, p.y)
	var s := RealAssetKit.scale_for_height(asset, target_h)
	var basis := Basis(Vector3.UP, yaw).scaled(Vector3(s, s, s))
	return Transform3D(basis, Vector3(p.x, h - _scaled_height(asset, s) * sink, p.y))


## 资产按倍率缩放后的实际高度（米）。
## 下沉量要按实际高度算：目标高度可能被占位上限截断，
## 拿目标高度去算下沉会把楼整个埋进地里，或者悬空。
static func _scaled_height(asset: String, scale: float) -> float:
	return RealAssetKit.size(asset).y * scale


## 生成摆放变换，并给横向尺寸加一道「占位半径上限」。
##
## 很多 Poly Haven 建筑是躺平的低模：qt_block1_large 天然只有 4.67m 高、
## 8m 宽，按目标高度放大后会变成一块 60m 高、100m 宽的墙板横在路中间；
## lovedeath_tower 的节点名其实是 LoveDeath_Tower_Bridge_Art（是桥），
## 按 118m 目标高度放大后变成 270m 长的一堵横墙。
## 这里用占位半径兜底：宁可楼矮一点，也不让楼摊成一堵墙。
static func _xform_capped(world: OpenWorld, p: Vector2, target_h: float, asset: String,
		yaw: float, sink: float, max_footprint: float) -> Transform3D:
	var h := world.height_at(p.x, p.y)
	var s := RealAssetKit.scale_for_height_capped(asset, target_h, max_footprint)
	var basis := Basis(Vector3.UP, yaw).scaled(Vector3(s, s, s))
	return Transform3D(basis, Vector3(p.x, h - _scaled_height(asset, s) * sink, p.y))


## 建筑净空判据：楼体（连同它的占地半径）不能压到路面上。
##
## 原来的判据是「楼心离路中心线 > 26m」，只看楼心一个点：
## 一栋 88m 宽的楼摆在离路 30m 的地方，楼身照样压在路面上——
## 天际环城那面贴满画面的砖墙就是这么来的。
## 现在按楼体真实占位半径判：到「路面边缘」还得再留一段路肩。
##
## road_edge_distance_exact 用的是路网折线本身，不是 15.6m 量化过的
## 距离场，所以这个判据是精确的（误差 < 1m）。
static func _clear_of_road(world: OpenWorld, p: Vector2, footprint: float) -> bool:
	return world.road_edge_distance_exact(p.x, p.y) >= footprint + ROAD_SHOULDER


## 这栋楼能不能摆：按它实际会用的缩放算出占地半径，再判净空。
##
## 关键在「实际会用的缩放」：目标高度会被占位半径上限截断，
## 用未截断的倍率算占位，会把楼判得比实际更宽，
## 白白浪费街区里能摆楼的位置。
static func _building_clear(world: OpenWorld, asset: String, p: Vector2,
		target_h: float, max_footprint: float) -> bool:
	var fp := RealAssetKit.footprint_radius(asset,
		RealAssetKit.scale_for_height_capped(asset, target_h, max_footprint))
	return _clear_of_road(world, p, fp)


static func _emissive_mat(color: Color, energy: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = energy
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return mat


## 一批发光色块（霓虹招牌 / 窗带 / 熔岩缝）。
static func _glow_boxes(container: Node3D, name_hint: String, size: Vector3,
		xforms: Array[Transform3D], color: Color, energy: float) -> void:
	if xforms.is_empty():
		return
	var box := BoxMesh.new()
	box.size = size
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = box
	mm.instance_count = xforms.size()
	for i in xforms.size():
		mm.set_instance_transform(i, xforms[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.name = name_hint
	mmi.multimesh = mm
	mmi.material_override = _emissive_mat(color, energy)
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	container.add_child(mmi)


## 贴地薄片的累加器（顶点 / 法线 / UV / 索引）。
## 用来把几十块贴地网格合并成一次 draw call。
static func _patch_acc_new() -> Dictionary:
	return {"v": PackedVector3Array(), "n": PackedVector3Array(),
		"uv": PackedVector2Array(), "i": PackedInt32Array()}


## 往累加器里追加一块贴地薄片。
##
## 薄片的每个顶点都按 height_at 取当地地形高度，所以它永远贴着地表：
## 既不会在坡上一半悬空一半埋地，也不会把车盖住。
## clamp_max 大于 0 时，顶点高度再被它压住（冰层不能高过湖面）。
static func _patch_add(acc: Dictionary, world: OpenWorld, center: Vector2,
		size_x: float, size_z: float, yaw: float, lift: float, clamp_max: float,
		subdiv: int = 4) -> void:
	var verts: PackedVector3Array = acc["v"]
	var norms: PackedVector3Array = acc["n"]
	var uvs: PackedVector2Array = acc["uv"]
	var idxs: PackedInt32Array = acc["i"]
	var base := verts.size()
	var n := maxi(subdiv, 1)
	var ca := cos(yaw)
	var sa := sin(yaw)
	for j in range(n + 1):
		for i in range(n + 1):
			var u := (float(i) / float(n) - 0.5) * size_x
			var v := (float(j) / float(n) - 0.5) * size_z
			var wx := center.x + u * ca - v * sa
			var wz := center.y + u * sa + v * ca
			var h := world.height_at(wx, wz) + lift
			if clamp_max > 0.0:
				h = minf(h, clamp_max)
			verts.append(Vector3(wx, h, wz))
			norms.append(world.normal_at(wx, wz))
			uvs.append(Vector2(float(i) / float(n), float(j) / float(n)))
	for j in range(n):
		for i in range(n):
			var a := base + j * (n + 1) + i
			var b := a + 1
			var c := a + (n + 1)
			var d := c + 1
			idxs.append(a)
			idxs.append(b)
			idxs.append(c)
			idxs.append(b)
			idxs.append(d)
			idxs.append(c)
	acc["v"] = verts
	acc["n"] = norms
	acc["uv"] = uvs
	acc["i"] = idxs


## 把累加器里的贴地薄片做成一个 MeshInstance3D 挂上去。
static func _patch_build(container: Node3D, name_hint: String, acc: Dictionary,
		mat: Material) -> void:
	var idxs: PackedInt32Array = acc["i"]
	if idxs.is_empty():
		return
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = acc["v"]
	arr[Mesh.ARRAY_NORMAL] = acc["n"]
	arr[Mesh.ARRAY_TEX_UV] = acc["uv"]
	arr[Mesh.ARRAY_INDEX] = idxs
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	var mi := MeshInstance3D.new()
	mi.name = name_hint
	mi.mesh = mesh
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	container.add_child(mi)


## 地形下坡方向（XZ 平面内的单位向量）。
## 熔岩流顺着坡往下淌才像熔岩，随机朝向就只是一块贴地色斑。
static func _downhill(world: OpenWorld, p: Vector2) -> Vector2:
	var n := world.normal_at(p.x, p.y)
	var g := Vector2(n.x, n.z)
	if g.length() < 0.0005:
		return Vector2(1.0, 0.0)
	return -g.normalized()


## 一批金属构件（缆车格构塔）：单位立方体 + 实例缩放，一次 draw call。
static func _pylon_parts(container: Node3D, parts: Array[Transform3D]) -> void:
	if parts.is_empty():
		return
	var box := BoxMesh.new()
	box.size = Vector3.ONE
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = box
	mm.instance_count = parts.size()
	for i in parts.size():
		mm.set_instance_transform(i, parts[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "CablePylons"
	mmi.multimesh = mm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.28, 0.29, 0.33)
	mat.roughness = 0.58
	mat.metallic = 0.40
	mmi.material_override = mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	container.add_child(mmi)


## 平面水片（港湾水池 / 冰川湖）。
static func _water_disc(container: Node3D, name_hint: String, center: Vector3, radius: float,
		color_deep: Color, color_shallow: Color) -> void:
	var mesh := ArrayMesh.new()
	var rings := 12
	var segs := 40
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idxs := PackedInt32Array()
	verts.append(Vector3.ZERO)
	norms.append(Vector3.UP)
	uvs.append(Vector2(0.5, 0.5))
	for r in range(1, rings + 1):
		var rr := radius * float(r) / float(rings)
		for s in segs:
			var a := TAU * float(s) / float(segs)
			verts.append(Vector3(cos(a) * rr, 0.0, sin(a) * rr))
			norms.append(Vector3.UP)
			uvs.append(Vector2(0.5 + cos(a) * 0.5 * float(r) / float(rings),
				0.5 + sin(a) * 0.5 * float(r) / float(rings)))
	for s in segs:
		idxs.append(0)
		idxs.append(1 + s)
		idxs.append(1 + (s + 1) % segs)
	for r in range(1, rings):
		var b0 := 1 + (r - 1) * segs
		var b1 := 1 + r * segs
		for s in segs:
			var sn := (s + 1) % segs
			idxs.append(b0 + s)
			idxs.append(b1 + s)
			idxs.append(b0 + sn)
			idxs.append(b0 + sn)
			idxs.append(b1 + s)
			idxs.append(b1 + sn)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idxs
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/water.gdshader")
	mat.set_shader_parameter("deep_color", color_deep)
	mat.set_shader_parameter("shallow_color", color_shallow)
	mat.set_shader_parameter("crest_color", color_shallow.lightened(0.35))
	mat.set_shader_parameter("wave_scale", 0.05)
	mat.set_shader_parameter("wave_height", 0.18)
	var mi := MeshInstance3D.new()
	mi.name = name_hint
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = center
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	container.add_child(mi)


## 码头 / 防波堤：沿矩形围一圈石墙。
static func _quay_wall(container: Node3D, center: Vector2, half: Vector2, top_y: float,
		thickness: float, world: OpenWorld) -> void:
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var cols := PackedColorArray()
	var idxs := PackedInt32Array()
	var base := 0
	var corners := [
		center + Vector2(-half.x, -half.y), center + Vector2(half.x, -half.y),
		center + Vector2(half.x, half.y), center + Vector2(-half.x, half.y),
	]
	for i in 4:
		var a: Vector2 = corners[i]
		var b: Vector2 = corners[(i + 1) % 4]
		var steps := maxi(int(a.distance_to(b) / 12.0), 2)
		for k in steps:
			var p0 := a.lerp(b, float(k) / float(steps))
			var p1 := a.lerp(b, float(k + 1) / float(steps))
			var y0 := top_y
			var y1 := top_y
			var d0 := Vector2(-(p1.y - p0.y), p1.x - p0.x).normalized() * thickness * 0.5
			var d1 := Vector2(-(p1.y - p0.y), p1.x - p0.x).normalized() * thickness * 0.5
			var quad := [
				Vector3(p0.x - d0.x, y0 - 14.0, p0.y - d0.y),
				Vector3(p0.x + d0.x, y0, p0.y + d0.y),
				Vector3(p1.x + d1.x, y1, p1.y + d1.y),
				Vector3(p1.x - d1.x, y1 - 14.0, p1.y - d1.y),
			]
			for v in quad:
				verts.append(v)
				norms.append(Vector3.UP)
				cols.append(Color(0.46, 0.43, 0.38))
			idxs.append(base)
			idxs.append(base + 1)
			idxs.append(base + 2)
			idxs.append(base + 1)
			idxs.append(base + 3)
			idxs.append(base + 2)
			base += 4
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
	mat.roughness = 0.95
	# 石墙是竖直面，两侧都要看得见
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var mi := MeshInstance3D.new()
	mi.name = "QuayWall"
	mi.mesh = mesh
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	container.add_child(mi)
	# 石墙是实体：车撞上码头墙要被挡住，不能开进墙里或从墙里穿出来。
	# 沿墙每 12m 放一个长条碰撞盒，旋转对齐墙的方向。
	for i in 4:
		var wa: Vector2 = corners[i]
		var wb: Vector2 = corners[(i + 1) % 4]
		var wsteps := maxi(int(wa.distance_to(wb) / 12.0), 2)
		var wdir := (wb - wa).normalized()
		var wrot := atan2(wdir.x, wdir.y)
		for k in wsteps:
			var wp := wa.lerp(wb, (float(k) + 0.5) / float(wsteps))
			world.add_collider(wp, Vector2(thickness * 0.5 + 0.35, 7.0), wrot,
				top_y - 2.0, top_y + 1.2)


## 一排街灯（含灯头），city 用。
static func _street_lights_in_zone(world: OpenWorld, container: Node3D, zone_center: Vector2,
		zone_radius: float, spacing: float, color: Color, energy: float) -> void:
	var pole_x: Array[Transform3D] = []
	var head_x: Array[Transform3D] = []
	for road in world.roads:
		var pts: Array = road["pts"]
		var width: float = float(road["width"])
		var acc := 0.0
		for i in pts.size():
			var p: Vector2 = pts[i]
			if i > 0:
				var prev: Vector2 = pts[i - 1]
				acc += p.distance_to(prev)
			if acc < spacing:
				continue
			acc = 0.0
			if p.distance_to(zone_center) > zone_radius:
				continue
			var next: Vector2 = pts[mini(i + 1, pts.size() - 1)]
			var dir := next - p
			if dir.length() < 0.001:
				continue
			dir = dir.normalized()
			var side := Vector2(-dir.y, dir.x)
			var base := p + side * (width * 0.5 + 1.6)
			var h := world.height_at(base.x, base.y)
			pole_x.append(Transform3D(Basis.IDENTITY, Vector3(base.x, h + 4.6, base.y)))
			head_x.append(Transform3D(Basis.IDENTITY, Vector3(base.x, h + 9.1, base.y)))
	if pole_x.is_empty():
		return
	var pole_mesh := CylinderMesh.new()
	pole_mesh.top_radius = 0.14
	pole_mesh.bottom_radius = 0.20
	pole_mesh.height = 9.0
	pole_mesh.radial_segments = 6
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = pole_mesh
	mm.instance_count = pole_x.size()
	for i in pole_x.size():
		mm.set_instance_transform(i, pole_x[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "StreetPoles"
	mmi.multimesh = mm
	var pole_mat := StandardMaterial3D.new()
	pole_mat.albedo_color = Color(0.16, 0.17, 0.19)
	pole_mat.roughness = 0.7
	mmi.material_override = pole_mat
	container.add_child(mmi)
	_glow_boxes(container, "StreetHeads", Vector3(1.5, 0.22, 0.9), head_x, color, energy)


## 域类型 → 适配的树种池。
## 雪山是松林、海岸是棕榈、峡谷是枯木、火山是焦树——
## 树种跟着地貌走，过渡带才有"从一种地貌走进另一种地貌"的感觉。
static func _tree_pool_for(kind: String) -> Array:
	match kind:
		"urban":
			return TREE_BROAD
		"beach":
			return TREE_PALMS
		"canyon":
			return DEAD_TREES
		"alpine":
			return TREE_PINES
		"glacier":
			return TREE_PINES + DEAD_TREES
		"magma":
			return DEAD_TREES
	return TREE_BROAD


## 沿路两侧种行道树。
## 城市域原本只有楼和路灯，一条直路开过去两边空得发慌；
## 行道树把路网撑起来，也让车在九公里的大地图上"有路可循"。
## 所有树按资产分组后统一批量摆放（每个资产一个 MultiMesh），
## 几千棵树也只增加几个 draw call。
static func _street_trees_in_zone(world: OpenWorld, container: Node3D, zone_center: Vector2,
		zone_radius: float, spacing: float, pool: Array, h_min: float, h_max: float,
		seed_value: int, stats: Dictionary) -> void:
	if pool.is_empty():
		return
	var rng := _rng(seed_value)
	var by_asset: Dictionary = {}
	for road in world.roads:
		var pts: Array = road["pts"]
		var width: float = float(road["width"])
		var acc := 0.0
		for i in pts.size():
			var p: Vector2 = pts[i]
			if i > 0:
				acc += p.distance_to(pts[i - 1])
			if acc < spacing:
				continue
			acc = 0.0
			if p.distance_to(zone_center) > zone_radius:
				continue
			var nxt: Vector2 = pts[mini(i + 1, pts.size() - 1)]
			var dir := nxt - p
			if dir.length() < 0.001:
				continue
			dir = dir.normalized()
			var side := Vector2(-dir.y, dir.x)
			for sgn in [-1.0, 1.0]:
				var base := p + side * (width * 0.5 + 3.6) * float(sgn)
				if base.distance_to(zone_center) > zone_radius:
					continue
				var h := world.height_at(base.x, base.y)
				if h < 0.8:
					continue
				if world.slope_at(base.x, base.y) > 0.32:
					continue
				# 行道树要离路面足够远：太近挡住路，太远又不成列。
				if world.road_distance_at(base.x, base.y) < width * 0.5 + 2.4:
					continue
				var asset := String(pool[rng.randi() % pool.size()])
				var hh := rng.randf_range(h_min, h_max)
				var xf := _xform(world, base, hh, asset, rng.randf() * TAU, 0.02)
				_push_xf(by_asset, asset, xf)
	for asset in by_asset.keys():
		var lst: Array[Transform3D] = by_asset[asset]
		_place(container, String(asset), lst, "StreetTree", 900.0, true, stats)


## 域与域之间的过渡带植被。
## 颜色已经是渐变的，植被也应该渐变：两条域的中点同时出现两边的树，
## 开过去看到的是"雪山慢慢变成森林"，而不是一刀切。
## 单条域间过渡带的植被（band = 连接 ZONES[band] 与 ZONES[(band+1)%n]）。
## 每条带独立成单元，跟着相邻域一起流式生成。
static func _build_transition_band(world: OpenWorld, container: Node3D, band: int,
		stats: Dictionary) -> void:
	var rng := _rng(90909 + band * 131)
	var a: Dictionary = OpenWorld.ZONES[band]
	var b: Dictionary = OpenWorld.ZONES[(band + 1) % OpenWorld.ZONES.size()]
	var ca: Vector2 = a["center"]
	var cb: Vector2 = b["center"]
	var mid := (ca + cb) * 0.5
	var span: float = ca.distance_to(cb) * 0.26
	# 过渡带的树种 = 两边域的树种混在一起
	var pool: Array = []
	pool.append_array(_tree_pool_for(String(a["kind"])))
	for p2 in _tree_pool_for(String(b["kind"])):
		if not (p2 in pool):
			pool.append(p2)
	if pool.is_empty():
		return
	# 过渡带的海拔跨度大：按当地高程筛，只种能站住脚的树
	var by_asset: Dictionary = {}
	for p in _scatter(mid, span, 150, rng, 0.05):
		var h := world.height_at(p.x, p.y)
		if h < 0.6:
			continue
		if world.slope_at(p.x, p.y) > 0.62:
			continue
		if world.road_distance_at(p.x, p.y) < 15.0:
			continue
		# 越靠近过渡带中心，用另一域的树种越多
		var to_a := p.distance_to(ca)
		var to_b := p.distance_to(cb)
		var pick: Array = pool
		if to_b < to_a:
			pick = _tree_pool_for(String(b["kind"]))
			if pick.is_empty():
				pick = pool
		var asset := String(pick[rng.randi() % pick.size()])
		var hh := rng.randf_range(7.0, 17.0)
		var xf := _xform(world, p, hh, asset, rng.randf() * TAU, 0.02)
		_push_xf(by_asset, asset, xf)
	for asset in by_asset.keys():
		var lst: Array[Transform3D] = by_asset[asset]
		_place(container, String(asset), lst, "TransitionTree", 1500.0, true, stats)



## 域内混交林：在主树种之外补一层别的树种。
## 一片林子只有一种树会显得像复制粘贴；混两种（甚至三种）之后，
## 远看才有真实林地的层次。高模高精模的树资产在这里派上用场。
static func _mixed_woodland(world: OpenWorld, container: Node3D, c: Vector2, radius: float,
		count: int, pool: Array, h_min: float, h_max: float, min_h: float, max_h: float,
		max_slope: float, seed_value: int, prefix: String, stats: Dictionary) -> void:
	if pool.is_empty():
		return
	var rng := _rng(seed_value)
	var by_asset: Dictionary = {}
	for asset in pool:
		var xforms: Array[Transform3D] = []
		for p in _scatter(c, radius, count, rng, 0.08):
			var h := world.height_at(p.x, p.y)
			if h < min_h or h > max_h:
				continue
			if world.slope_at(p.x, p.y) > max_slope:
				continue
			if world.road_distance_at(p.x, p.y) < 15.0:
				continue
			xforms.append(_xform(world, p, rng.randf_range(h_min, h_max), String(asset),
				rng.randf() * TAU, 0.02))
		by_asset[String(asset)] = xforms
	for asset in by_asset.keys():
		var arr: Array[Transform3D] = by_asset[asset]
		if arr.is_empty():
			continue
		_place(container, String(asset), arr, prefix, 1300.0, true, stats)

# ---------------------------------------------------------------------------
# ① 霓虹都市
# ---------------------------------------------------------------------------

static func _build_neon_city(world: OpenWorld, container: Node3D, stats: Dictionary) -> void:
	var zone: Dictionary = OpenWorld.ZONES[0]
	var c: Vector2 = zone["center"]
	var radius := float(zone["radius"])
	var rng := _rng(10001)

	# 楼群
	# 顺手记下每栋楼的锚点，霓虹招牌要真的贴在楼立面上（见下）。
	var sign_anchors: Array = []
	for entry in POOL_NEON:
		var asset := String(entry[0])
		var h := float(entry[1])
		var weight := float(entry[2])
		var max_fp := float(entry[3])
		var count := int(760.0 * weight)
		var pts := _grid(c, radius * 0.92, 37.0, rng)
		var xforms: Array[Transform3D] = []
		for p in pts:
			if xforms.size() >= count:
				break
			if not _keep_clear(p, world, 110.0):
				continue
			var bh := h * rng.randf_range(0.55, 1.25)
			var byaw := rng.randf() * TAU
			# 净空按楼体实际占位算：楼心离路远，不代表楼身不压路。
			if not _building_clear(world, asset, p, bh, max_fp):
				continue
			if world.slope_at(p.x, p.y) > 0.30:
				continue
			var xf := _xform_capped(world, p, bh, asset, byaw, 0.10, max_fp)
			xforms.append(xf)
			if xforms.size() % 3 == 0:
				sign_anchors.append({"xf": xf, "asset": asset,
					"h": _scaled_height(asset, xf.basis.get_scale().x)})
		_place(container, asset, xforms, "NeonBlock", 2200.0, false, stats)

	# 地标塔楼
	var hero_assets: Array[String] = []
	for e in POOL_HERO:
		hero_assets.append(String(e[0]))
	# 塔楼锚点：招牌要贴在真正的塔上，不能重新随机一次位置
	# （原来两处各随机一次，招牌全都飘在没有楼的空中）。
	var hero_anchors: Array = []
	for i in hero_assets.size():
		var a := TAU * float(i) / float(hero_assets.size()) + 0.4
		var p := c + Vector2(cos(a), sin(a)) * radius * rng.randf_range(0.42, 0.72)
		var asset2 := hero_assets[i]
		var hh := float(POOL_HERO[i][1]) * rng.randf_range(0.85, 1.15)
		var max_fp := float(POOL_HERO[i][3])
		if not _building_clear(world, asset2, p, hh, max_fp):
			continue
		var xf := _xform_capped(world, p, hh, asset2, rng.randf() * TAU, 0.0, max_fp)
		_place(container, asset2, [xf] as Array[Transform3D], "NeonHero", 3000.0, true, stats)
		hero_anchors.append({"xf": xf, "asset": asset2,
			"h": _scaled_height(asset2, xf.basis.get_scale().x)})

	# 霓虹招牌：贴在楼侧的发光板。
	# 原来是在城市范围里随机撒半空中的盒子（离地 9~46m，背后没有楼），
	# 航拍下来就是几根悬空的蓝色光条——最典型的"奇怪结构"。
	# 现在按楼的外立面贴上去：沿楼的局部 X 方向往外推半个进深，
	# 高度按楼高取，宽度不超楼宽。
	var sign_x: Array[Transform3D] = []
	for anc in sign_anchors:
		var xf: Transform3D = anc["xf"]
		var aasset: String = anc["asset"]
		var bh2: float = anc["h"]
		var sz := RealAssetKit.size(aasset)
		var sc: float = maxf(xf.basis.get_scale().x, 0.001)
		var half_depth: float = maxf(sz.x, 0.5) * sc * 0.5
		var facade_w: float = maxf(sz.z, 1.0) * sc
		var ob := xf.basis.orthonormalized()
		var out := Vector3(ob.x.x, 0.0, ob.x.z)
		if out.length() < 0.001:
			continue
		out = out.normalized()
		var sy := bh2 * rng.randf_range(0.18, 0.78)
		var pos := Vector3(xf.origin.x, xf.origin.y + sy, xf.origin.z) \
			+ out * (half_depth + 0.35)
		sign_x.append(Transform3D(Basis(Vector3.UP, atan2(out.x, out.z)), pos))
	# 地标塔楼也贴招牌
	for anc2 in hero_anchors:
		var hxf: Transform3D = anc2["xf"]
		var hasset: String = anc2["asset"]
		var hh3: float = anc2["h"]
		var hsz := RealAssetKit.size(hasset)
		var hob := hxf.basis.orthonormalized()
		var hout := Vector3(hob.x.x, 0.0, hob.x.z).normalized()
		var hpos := Vector3(hxf.origin.x, hxf.origin.y + hh3 * 0.62, hxf.origin.z) \
			+ hout * (maxf(hsz.x, 0.5) * maxf(hxf.basis.get_scale().x, 0.001) * 0.5 + 0.5)
		sign_x.append(Transform3D(Basis(Vector3.UP, atan2(hout.x, hout.z)), hpos))
	if not sign_x.is_empty():
		var sign_size := Vector3(clampf(3.2, 1.2, 5.0), 6.0, 0.5)
		for cidx in NEON_SIGNS.size():
			var batch: Array[Transform3D] = []
			for i in sign_x.size():
				if i % NEON_SIGNS.size() == cidx:
					batch.append(sign_x[i])
			if batch.is_empty():
				continue
			_glow_boxes(container, "NeonSign_%d" % cidx, sign_size, batch,
				NEON_SIGNS[cidx], 3.4)

	# 路灯：沿本域内的道路布
	_street_lights_in_zone(world, container, c, radius * 1.05, 52.0, Color(1.0, 0.86, 0.62), 4.5)
	# 行道树：原来只有楼和路灯，路两边空得发慌
	_street_trees_in_zone(world, container, c, radius * 1.02, 44.0, TREE_BROAD,
		6.5, 11.5, 10002, stats)


# ---------------------------------------------------------------------------
# ② 天际环城
# ---------------------------------------------------------------------------

static func _build_skyline_city(world: OpenWorld, container: Node3D, stats: Dictionary) -> void:
	var zone: Dictionary = OpenWorld.ZONES[1]
	var c: Vector2 = zone["center"]
	var radius := float(zone["radius"])
	var rng := _rng(20002)

	for entry in POOL_SKYLINE:
		var asset := String(entry[0])
		var h := float(entry[1])
		var weight := float(entry[2])
		var max_fp := float(entry[3])
		var count := int(700.0 * weight)
		var pts := _grid(c, radius * 0.90, 39.0, rng)
		var xforms: Array[Transform3D] = []
		for p in pts:
			if xforms.size() >= count:
				break
			var bh := h * rng.randf_range(0.55, 1.3)
			if not _building_clear(world, asset, p, bh, max_fp):
				continue
			if world.slope_at(p.x, p.y) > 0.28:
				continue
			xforms.append(_xform_capped(world, p, bh, asset,
				rng.randf() * TAU, 0.10, max_fp))
		_place(container, asset, xforms, "SkyBlock", 2400.0, false, stats)

	# 高架快速路：横跨城区的高架桥墩 + 桥面
	_build_elevated_road(world, container, c, radius * 0.7, rng)

	# 住宅楼群
	var apt_pool := ["qt_apt2", "qt_apt3", "qt_apt4_a", "qt_apt4_b", "qt_apt6", "qt_block2_large",
		"qt_block3", "qt_block4"]
	for asset3 in apt_pool:
		var pts := _scatter(c, radius * 0.82, 95, rng, 0.35)
		var xforms: Array[Transform3D] = []
		for p in pts:
			var bh := rng.randf_range(14.0, 34.0)
			if not _building_clear(world, asset3, p, bh, 11.0):
				continue
			if world.slope_at(p.x, p.y) > 0.25:
				continue
			xforms.append(_xform_capped(world, p, bh, asset3, rng.randf() * TAU, 0.02, 11.0))
		_place(container, asset3, xforms, "SkyApt", 1600.0, false, stats)

	# 行道树：黄昏未来城的街道两侧也要有绿
	_street_trees_in_zone(world, container, c, radius * 1.0, 50.0, TREE_BROAD,
		5.5, 10.0, 20003, stats)


static func _build_elevated_road(world: OpenWorld, container: Node3D, c: Vector2,
		span: float, rng: RandomNumberGenerator) -> void:
	var a := rng.randf() * TAU
	var dir := Vector2(cos(a), sin(a))
	var yaw := atan2(dir.x, dir.y)
	var deck_w := 13.0
	var piers: Array[Transform3D] = []
	var deck: Array[Transform3D] = []
	var rail_l: Array[Transform3D] = []
	var rail_r: Array[Transform3D] = []
	for t in range(-1.0, 1.01, 0.06):
		var p := c + dir * (span * t)
		var h := world.height_at(p.x, p.y)
		var deck_y := h + 13.0
		var basis := Basis(Vector3.UP, yaw)
		piers.append(Transform3D(Basis.IDENTITY, Vector3(p.x, h + 6.5, p.y)))
		deck.append(Transform3D(basis, Vector3(p.x, deck_y, p.y)))
		# 护栏在桥面两侧边缘。原来护栏是"桥面正中央上方 1.2m 的一块横板"，
		# 那既是块悬在半空的怪东西，又在路中间凭空造出两堵看不见的墙。
		# 现在压到 ±(半宽 - 0.3)，做成竖直的护栏板。
		var sx := basis.x * (deck_w * 0.5 - 0.3)
		rail_l.append(Transform3D(basis, Vector3(p.x, deck_y, p.y) + sx))
		rail_r.append(Transform3D(basis, Vector3(p.x, deck_y, p.y) - sx))
	# 桥墩
	var pier_mesh := CylinderMesh.new()
	pier_mesh.top_radius = 1.5
	pier_mesh.bottom_radius = 2.1
	pier_mesh.height = 13.0
	pier_mesh.radial_segments = 8
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = pier_mesh
	mm.instance_count = piers.size()
	for i in piers.size():
		mm.set_instance_transform(i, piers[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "ExpresswayPiers"
	mmi.multimesh = mm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.52, 0.50, 0.47)
	mat.roughness = 0.9
	mmi.material_override = mat
	container.add_child(mmi)
	# 桥面（带厚度，从地面仰视也看得见）
	_build_deck_solid(container, deck, deck_w, 1.2, Color(0.30, 0.31, 0.34))
	# 护栏（竖直板 + 顶部横条）
	_build_rail_strip(container, rail_l, 1.25, Color(0.70, 0.72, 0.76))
	_build_rail_strip(container, rail_r, 1.25, Color(0.70, 0.72, 0.76))
	# 护栏是实体：车不能从桥面边缘直接掉到地面，也不能从护栏中间穿过去。
	for rail_set: Array in [rail_l, rail_r]:
		for xf in rail_set:
			var fwd: Vector3 = xf.basis.z
			var d2 := Vector2(fwd.x, fwd.z).normalized()
			if d2.length() < 0.001:
				continue
			world.add_collider(Vector2(xf.origin.x, xf.origin.z), Vector2(0.45, 8.0),
				atan2(d2.x, d2.y), xf.origin.y - 0.2, xf.origin.y + 1.25)


## 带厚度的带状网格（高架桥面）。
## 原来只是一张零厚度的平面：法线朝上，从地面仰视时整条桥面被背面剔除，
## 只剩一排桥墩悬在半空——这就是"奇怪结构"的来源。
## 现在做出顶面 / 底面 / 两侧立面，桥面是有体积的实体。
static func _build_deck_solid(container: Node3D, centers: Array[Transform3D],
		width: float, thickness: float, color: Color) -> void:
	if centers.size() < 2:
		return
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var cols := PackedColorArray()
	var idxs := PackedInt32Array()
	var side_col := color.darkened(0.25)
	var under_col := color.darkened(0.45)
	for xf in centers:
		var side := xf.basis.x
		var o := xf.origin
		var top_l := o - side * width * 0.5 + Vector3.UP * thickness * 0.5
		var top_r := o + side * width * 0.5 + Vector3.UP * thickness * 0.5
		var bot_l := o - side * width * 0.5 - Vector3.UP * thickness * 0.5
		var bot_r := o + side * width * 0.5 - Vector3.UP * thickness * 0.5
		# 顺序：顶左 / 顶右 / 底右 / 底左
		verts.append(top_l)
		verts.append(top_r)
		verts.append(bot_r)
		verts.append(bot_l)
		norms.append(Vector3.UP)
		norms.append(Vector3.UP)
		norms.append(-side)
		norms.append(-side)
		cols.append(color)
		cols.append(color)
		cols.append(side_col)
		cols.append(side_col)
		# 第二组（底面朝下）
		verts.append(bot_l)
		verts.append(bot_r)
		verts.append(top_r)
		verts.append(top_l)
		norms.append(Vector3.DOWN)
		norms.append(Vector3.DOWN)
		norms.append(side)
		norms.append(side)
		cols.append(under_col)
		cols.append(under_col)
		cols.append(side_col)
		cols.append(side_col)
	for i in range(centers.size() - 1):
		var a := i * 8
		var b := a + 8
		# 顶面
		idxs.append(a); idxs.append(a + 1); idxs.append(b + 1)
		idxs.append(a); idxs.append(b + 1); idxs.append(b)
		# 底面
		idxs.append(a + 4); idxs.append(b + 5); idxs.append(a + 5)
		idxs.append(a + 4); idxs.append(b + 4); idxs.append(b + 5)
		# 左侧
		idxs.append(a + 3); idxs.append(b + 2); idxs.append(a + 2)
		idxs.append(a + 3); idxs.append(b + 3); idxs.append(b + 2)
		# 右侧
		idxs.append(a + 1); idxs.append(a + 2); idxs.append(b + 2)
		idxs.append(a + 1); idxs.append(b + 2); idxs.append(b + 1)
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
	mat.roughness = 0.85
	# 桥面是薄板，两侧都要看得见
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var mi := MeshInstance3D.new()
	mi.name = "Deck"
	mi.mesh = mesh
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	container.add_child(mi)


## 竖直护栏板 + 顶部横条（高架桥两侧）。
## 原来是"桥面正中央上方 1.2m 的一块横板"：既是悬在半空的怪东西，
## 又在路中间凭空造出两堵看不见的碰撞墙。
static func _build_rail_strip(container: Node3D, centers: Array[Transform3D],
		height: float, color: Color) -> void:
	if centers.size() < 2:
		return
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var cols := PackedColorArray()
	var idxs := PackedInt32Array()
	for xf in centers:
		var side := xf.basis.x
		var o := xf.origin
		verts.append(o)
		verts.append(o + Vector3.UP * height)
		norms.append(side)
		norms.append(side)
		cols.append(color)
		cols.append(color)
		# 顶部横条（向桥面内侧挑出 0.35m）
		verts.append(o + Vector3.UP * height)
		verts.append(o + Vector3.UP * height - side * 0.35)
		norms.append(Vector3.UP)
		norms.append(Vector3.UP)
		cols.append(color.lightened(0.18))
		cols.append(color.lightened(0.18))
	for i in range(centers.size() - 1):
		var a := i * 4
		var b := a + 4
		# 竖直板
		idxs.append(a); idxs.append(a + 1); idxs.append(b + 1)
		idxs.append(a); idxs.append(b + 1); idxs.append(b)
		# 顶部横条
		idxs.append(a + 2); idxs.append(a + 3); idxs.append(b + 3)
		idxs.append(a + 2); idxs.append(b + 3); idxs.append(b + 2)
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
	mat.roughness = 0.62
	mat.metallic = 0.25
	# 护栏板是竖直面，两侧都要看得见
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var mi := MeshInstance3D.new()
	mi.name = "GuardRail"
	mi.mesh = mesh
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	container.add_child(mi)


# ---------------------------------------------------------------------------
# ③ 落日港湾
# ---------------------------------------------------------------------------

static func _build_harbor(world: OpenWorld, container: Node3D, stats: Dictionary) -> void:
	var zone: Dictionary = OpenWorld.ZONES[2]
	var c: Vector2 = zone["center"]
	var radius := float(zone["radius"])
	var rng := _rng(30003)

	# 港池
	var basin_c := c + Vector2(0.0, 330.0)
	_water_disc(container, "HarborBasin", Vector3(basin_c.x, 0.4, basin_c.y), 300.0,
		Color(0.03, 0.13, 0.22), Color(0.10, 0.34, 0.40))
	_quay_wall(container, basin_c, Vector2(300.0, 210.0), 6.0, 6.0, world)

	# 集装箱堆场：彩色箱体
	var box := BoxMesh.new()
	box.size = Vector3(12.0, 2.9, 2.9)
	var container_mats: Array[StandardMaterial3D] = []
	for col in [Color(0.75, 0.22, 0.18), Color(0.16, 0.42, 0.62), Color(0.72, 0.60, 0.18),
			Color(0.22, 0.50, 0.34), Color(0.62, 0.62, 0.64)]:
		var m := StandardMaterial3D.new()
		m.albedo_color = col
		m.roughness = 0.78
		container_mats.append(m)
	for mi in container_mats.size():
		var xforms: Array[Transform3D] = []
		for i in 46:
			var p := c + Vector2(rng.randf_range(-radius * 0.82, radius * 0.30),
				rng.randf_range(-radius * 0.85, radius * 0.05))
			if world.road_distance_at(p.x, p.y) < 22.0:
				continue
			var h := world.height_at(p.x, p.y)
			if h < 3.0:
				continue
			var stack := rng.randi_range(1, 4)
			for s in stack:
				var basis := Basis(Vector3.UP, rng.randf_range(-0.1, 0.1))
				xforms.append(Transform3D(basis,
					Vector3(p.x, h + 1.5 + float(s) * 2.95, p.y)))
		if xforms.is_empty():
			continue
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = box
		mm.instance_count = xforms.size()
		for i in xforms.size():
			mm.set_instance_transform(i, xforms[i])
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "Containers_%d" % mi
		mmi.multimesh = mm
		mmi.material_override = container_mats[mi]
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		container.add_child(mmi)
		stats["instances"] = int(stats.get("instances", 0)) + xforms.size()

	# 厂房 / 仓库立面
	# factory_facade 天然就有 53m 宽、29m 高，是个横向摊开的大立面：
	# 按目标高度放大后再按"楼心离路 24m"判净空，厂房的墙就直接压在路上。
	# 现在占位半径压到 20m，净空按楼体实际占位判。
	for asset in ["factory_facade", "pit_building"]:
		var xforms2: Array[Transform3D] = []
		for p in _scatter(c, radius * 0.85, 16, rng, 0.25):
			var bh := rng.randf_range(12.0, 26.0)
			if not _building_clear(world, asset, p, bh, 20.0):
				continue
			xforms2.append(_xform_capped(world, p, bh, asset, rng.randf() * TAU, 0.0, 20.0))
		_place(container, asset, xforms2, "HarborShed", 2000.0, true, stats)

	# 跨海大桥：lovedeath_tower 的节点名就叫 LoveDeath_Tower_Bridge_Art，
	# 是一段 62m 长的桥身，横着架在港湾入口才是它该有的用法。
	# 之前它被当成"塔楼"按 118m 目标高度竖起来放大，
	# 变成一堵 270m 长、136m 高的横墙横在城中间。
	for i in 2:
		var ba := TAU * float(i) / 2.0 + 0.9
		var bp := basin_c + Vector2(cos(ba), sin(ba)) * 520.0
		var bxf := _xform_capped(world, bp, 40.0, "lovedeath_tower", ba + PI * 0.5, 0.0, 34.0)
		_place(container, "lovedeath_tower", [bxf] as Array[Transform3D], "HarborBridge",
			2600.0, true, stats)

	# 龙门吊
	for i in 5:
		var p := basin_c + Vector2(-240.0 + float(i) * 120.0, -250.0)
		var h := world.height_at(p.x, p.y)
		_build_gantry(container, Vector3(p.x, h, p.y))

	# 灯塔 / 高杆灯
	var towers: Array[Transform3D] = []
	for i in 7:
		var p := c + Vector2(rng.randf_range(-radius * 0.7, radius * 0.7),
			rng.randf_range(-radius * 0.7, radius * 0.7))
		if not _building_clear(world, "light_tower", p, 22.0, 8.0):
			continue
		towers.append(_xform_capped(world, p, 22.0, "light_tower", rng.randf() * TAU, 0.0, 8.0))
	_place(container, "light_tower", towers, "HarborTower", 2400.0, true, stats)
	# 港口行道树：棕榈把码头和仓库区连起来
	_street_trees_in_zone(world, container, c, radius * 1.0, 42.0, TREE_PALMS,
		7.0, 13.0, 30004, stats)

	# 停泊的船
	var ships: Array[Transform3D] = []
	for i in 3:
		var p := basin_c + Vector2(-180.0 + float(i) * 180.0, 60.0 + rng.randf_range(-30.0, 30.0))
		ships.append(Transform3D(Basis(Vector3.UP, rng.randf_range(-0.4, 0.4)),
			Vector3(p.x, 0.0, p.y)))
	_place(container, "ship_real", ships, "HarborShip", 2600.0, true, stats)


## 龙门吊：门架 + 悬臂。
static func _build_gantry(container: Node3D, base: Vector3) -> void:
	var node := Node3D.new()
	node.name = "Gantry"
	node.position = base
	container.add_child(node)
	var leg_mat := StandardMaterial3D.new()
	leg_mat.albedo_color = Color(0.78, 0.52, 0.16)
	leg_mat.roughness = 0.6
	var beam := BoxMesh.new()
	beam.size = Vector3(1.6, 33.0, 1.6)
	var legs: Array[Transform3D] = []
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			legs.append(Transform3D(Basis.IDENTITY, Vector3(sx * 13.0, 16.5, sz * 9.0)))
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = beam
	mm.instance_count = legs.size()
	for i in legs.size():
		mm.set_instance_transform(i, legs[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "GantryLegs"
	mmi.multimesh = mm
	mmi.material_override = leg_mat
	node.add_child(mmi)
	var top := MeshInstance3D.new()
	var top_mesh := BoxMesh.new()
	top_mesh.size = Vector3(30.0, 2.2, 3.0)
	top.mesh = top_mesh
	top.material_override = leg_mat
	top.position = Vector3(0.0, 33.0, 0.0)
	node.add_child(top)
	var boom := MeshInstance3D.new()
	var boom_mesh := BoxMesh.new()
	boom_mesh.size = Vector3(3.0, 2.0, 46.0)
	boom.mesh = boom_mesh
	boom.material_override = leg_mat
	boom.position = Vector3(0.0, 36.0, -16.0)
	node.add_child(boom)
	_glow_boxes(node, "GantryLamp", Vector3(1.0, 0.6, 1.0),
		[Transform3D(Basis.IDENTITY, Vector3(0.0, 30.0, 0.0))] as Array[Transform3D],
		Color(1.0, 0.85, 0.45), 5.0)


# ---------------------------------------------------------------------------
# ④ 翡翠海岸
# ---------------------------------------------------------------------------

static func _build_coast(world: OpenWorld, container: Node3D, stats: Dictionary) -> void:
	var zone: Dictionary = OpenWorld.ZONES[3]
	var c: Vector2 = zone["center"]
	var radius := float(zone["radius"])
	var rng := _rng(40004)

	# 棕榈
	for asset in TREE_PALMS:
		var xforms: Array[Transform3D] = []
		for p in _scatter(c, radius * 1.02, 300, rng, 0.25):
			var h := world.height_at(p.x, p.y)
			if h < 1.2 or h > 30.0:
				continue
			if world.slope_at(p.x, p.y) > 0.50:
				continue
			if world.road_distance_at(p.x, p.y) < 15.0:
				continue
			xforms.append(_xform(world, p, rng.randf_range(8.0, 15.0), asset, rng.randf() * TAU, 0.02))
		_place(container, asset, xforms, "CoastPalm", 1100.0, true, stats)

	# 灌木 / 草丛
	for asset2 in BUSHES:
		var xforms2: Array[Transform3D] = []
		for p in _scatter(c, radius * 1.05, 150, rng, 0.2):
			var h := world.height_at(p.x, p.y)
			if h < 0.8 or h > 34.0:
				continue
			if world.road_distance_at(p.x, p.y) < 14.0:
				continue
			xforms2.append(_xform(world, p, rng.randf_range(1.2, 3.2), asset2, rng.randf() * TAU, 0.05))
		_place(container, asset2, xforms2, "CoastBush", 700.0, false, stats)

	# 礁石
	for asset3 in ROCKS:
		var xforms3: Array[Transform3D] = []
		for p in _scatter(c, radius * 1.15, 80, rng, 0.1):
			var h := world.height_at(p.x, p.y)
			if h < -2.0 or h > 40.0:
				continue
			if world.road_distance_at(p.x, p.y) < 15.0:
				continue
			xforms3.append(_xform(world, p, rng.randf_range(3.0, 11.0), asset3, rng.randf() * TAU, 0.20))
		_place(container, asset3, xforms3, "CoastRock", 1300.0, true, stats)

	# 海岸内陆补一层阔叶林：全棕榈会太单调
	_mixed_woodland(world, container, c, radius * 1.1, 220, TREE_BROAD,
		8.0, 15.0, 9.0, 44.0, 0.42, 40005, "CoastBroad", stats)

	# 栈桥
	var pier_c := c + Vector2(-120.0, 240.0)
	var pier_dir := Vector2(0.42, 0.91).normalized()
	var pier_x: Array[Transform3D] = []
	for i in 16:
		var p := pier_c + pier_dir * (float(i) * 12.0)
		pier_x.append(Transform3D(Basis(Vector3.UP, atan2(pier_dir.x, pier_dir.y)),
			Vector3(p.x, 3.4, p.y)))
	_place(container, "pier_real", pier_x, "CoastPier", 1800.0, true, stats)

	# 灯塔
	var lt := pier_c + pier_dir * 210.0
	_place(container, "light_tower",
		[_xform(world, Vector2(lt.x, lt.y), 34.0, "light_tower", 0.0, 0.0)] as Array[Transform3D],
		"CoastLighthouse", 3000.0, true, stats)

	# 沙滩遮阳伞 / 救生设施
	var flags: Array[Transform3D] = []
	for i in 24:
		var p := c + Vector2(rng.randf_range(-radius * 0.7, radius * 0.7),
			rng.randf_range(-radius * 0.2, radius * 0.75))
		var h := world.height_at(p.x, p.y)
		if h < 1.0 or h > 12.0:
			continue
		flags.append(_xform(world, p, 3.0, "sea_marker_real", rng.randf() * TAU, 0.0))
	_place(container, "sea_marker_real", flags, "CoastMarker", 900.0, true, stats)


# ---------------------------------------------------------------------------
# ⑤ 赤岩峡谷
# ---------------------------------------------------------------------------

static func _build_canyon(world: OpenWorld, container: Node3D, stats: Dictionary) -> void:
	var zone: Dictionary = OpenWorld.ZONES[4]
	var c: Vector2 = zone["center"]
	var radius := float(zone["radius"])
	var rng := _rng(50005)

	# 台地岩柱
	for asset in ROCKS:
		var xforms: Array[Transform3D] = []
		for p in _scatter(c, radius * 1.05, 150, rng, 0.15):
			var h := world.height_at(p.x, p.y)
			if h < 8.0:
				continue
			if world.road_distance_at(p.x, p.y) < 16.0:
				continue
			xforms.append(_xform(world, p, rng.randf_range(8.0, 34.0), asset, rng.randf() * TAU, 0.16))
		_place(container, asset, xforms, "CanyonRock", 1800.0, true, stats)

	# 枯树
	for asset2 in DEAD_TREES:
		var xforms2: Array[Transform3D] = []
		for p in _scatter(c, radius * 1.1, 130, rng, 0.2):
			var h := world.height_at(p.x, p.y)
			if h < 10.0:
				continue
			if world.road_distance_at(p.x, p.y) < 15.0:
				continue
			xforms2.append(_xform(world, p, rng.randf_range(5.0, 11.0), asset2, rng.randf() * TAU, 0.03))
		_place(container, asset2, xforms2, "CanyonDead", 900.0, true, stats)

	# 峡谷边缘的顽强的绿：枯木为主，边缘有活树
	_mixed_woodland(world, container, c, radius * 1.05, 150, TREE_BROAD,
		6.0, 12.0, 20.0, 95.0, 0.40, 50006, "CanyonBroad", stats)

	# 电线杆 + 铁丝网
	# power_pole 天然就有 13m 长（带横担），放大后横臂会伸到路面上。
	var poles: Array[Transform3D] = []
	for i in 26:
		var p := c + Vector2(rng.randf_range(-radius * 0.9, radius * 0.9),
			rng.randf_range(-radius * 0.9, radius * 0.9))
		if not _building_clear(world, "power_pole", p, 12.0, 9.0):
			continue
		poles.append(_xform_capped(world, p, 12.0, "power_pole", 0.0, 0.0, 9.0))
	_place(container, "power_pole", poles, "CanyonPole", 1500.0, true, stats)

	# 油桶 / 轮胎堆
	var barrels: Array[Transform3D] = []
	for i in 40:
		var p := c + Vector2(rng.randf_range(-radius * 0.8, radius * 0.8),
			rng.randf_range(-radius * 0.8, radius * 0.8))
		if world.road_distance_at(p.x, p.y) < 18.0:
			continue
		barrels.append(_xform(world, p, 1.2, "barrel_real", rng.randf() * TAU, 0.0))
	_place(container, "barrel_real", barrels, "CanyonBarrel", 700.0, true, stats)

	var tyres: Array[Transform3D] = []
	for i in 46:
		var p := c + Vector2(rng.randf_range(-radius * 0.9, radius * 0.9),
			rng.randf_range(-radius * 0.9, radius * 0.9))
		if world.road_distance_at(p.x, p.y) < 18.0:
			continue
		tyres.append(_xform(world, p, 1.1, "tyre_real", rng.randf() * TAU, 0.0))
	_place(container, "tyre_real", tyres, "CanyonTyre", 600.0, true, stats)


# ---------------------------------------------------------------------------
# ⑥ 雪山隘口
# ---------------------------------------------------------------------------

static func _build_alpine(world: OpenWorld, container: Node3D, stats: Dictionary) -> void:
	var zone: Dictionary = OpenWorld.ZONES[5]
	var c: Vector2 = zone["center"]
	var radius := float(zone["radius"])
	var rng := _rng(60006)

	for asset in TREE_PINES:
		var xforms: Array[Transform3D] = []
		for p in _scatter(c, radius * 1.15, 360, rng, 0.1):
			var h := world.height_at(p.x, p.y)
			if h < 22.0 or h > 190.0:
				continue
			if world.slope_at(p.x, p.y) > 0.70:
				continue
			if world.road_distance_at(p.x, p.y) < 16.0:
				continue
			xforms.append(_xform(world, p, rng.randf_range(8.0, 20.0), asset, rng.randf() * TAU, 0.02))
		_place(container, asset, xforms, "AlpinePine", 1400.0, true, stats)

	for asset2 in ROCKS:
		var xforms2: Array[Transform3D] = []
		for p in _scatter(c, radius * 1.2, 130, rng, 0.05):
			var h := world.height_at(p.x, p.y)
			if h < 30.0:
				continue
			if world.road_distance_at(p.x, p.y) < 15.0:
				continue
			xforms2.append(_xform(world, p, rng.randf_range(4.0, 16.0), asset2, rng.randf() * TAU, 0.18))
		_place(container, asset2, xforms2, "AlpineRock", 1700.0, true, stats)

	# 山腰混交林：纯松林太整齐，加阔叶打破节奏
	_mixed_woodland(world, container, c, radius * 1.1, 200, TREE_BROAD,
		7.0, 14.0, 24.0, 150.0, 0.52, 60007, "AlpineBroad", stats)

	# 木屋（山间小屋）。
	# 原来这里摆的是 realtree_broadleaf——一棵树。远看就是雪山上立着
	# 几棵特别大的树，是最扎眼的"奇怪结构"。换成真的房子模型。
	var hut_pool: Array[String] = ["qt_house1", "qt_house2"]
	for hi in hut_pool.size():
		var huts: Array[Transform3D] = []
		for i in 6:
			var a := TAU * float(i) / 6.0 + float(hi) * 0.5
			var p := c + Vector2(cos(a), sin(a)) * radius * (0.52 + 0.06 * float(hi))
			if world.road_distance_at(p.x, p.y) < 26.0:
				continue
			if world.slope_at(p.x, p.y) > 0.35:
				continue
			huts.append(_xform(world, p, 8.0, hut_pool[hi], rng.randf() * TAU, 0.0))
		_place(container, hut_pool[hi], huts, "AlpineHut", 1600.0, true, stats)

	# 缆车索道
	_build_cable_car(world, container, c, radius)


static func _build_cable_car(world: OpenWorld, container: Node3D, c: Vector2, radius: float) -> void:
	var a := 0.6
	var dir := Vector2(cos(a), sin(a))
	var p0 := c - dir * radius * 0.85
	var p1 := c + dir * radius * 0.85
	# 塔架高度：地面 → 塔顶横担，缆绳正好架在横担上。
	var tower_h := 30.0
	var tower_pos: Array[Vector2] = []
	var tower_top: Array[float] = []
	var tower_ts: Array[float] = [0.0, 0.25, 0.5, 0.75, 1.0]
	for t in tower_ts:
		var p := p0.lerp(p1, t)
		# 塔基不能压在主路上：往最近道路的外侧推开 14m
		var tp := Vector2(p.x, p.y)
		var rp3: Vector3 = world.nearest_road_point(tp.x, tp.y)
		var away := tp - Vector2(rp3.x, rp3.z)
		if away.length() < 1.0:
			away = Vector2(-dir.y, dir.x)
		else:
			away = away.normalized()
		tp += away * 14.0
		tower_pos.append(tp)
		tower_top.append(world.height_at(tp.x, tp.y) + tower_h)
	# 缆绳：塔与塔之间下垂（原来是 + sin(t*PI)*10，缆绳反而往上鼓）
	var ropes: Array[Vector3] = []
	for i in tower_ts.size() - 1:
		var t0: float = tower_ts[i]
		var t1: float = tower_ts[i + 1]
		var p_a := tower_pos[i]
		var p_b := tower_pos[i + 1]
		var y_a := tower_top[i]
		var y_b := tower_top[i + 1]
		var seg_len := p_a.distance_to(p_b)
		var steps := maxi(int(seg_len / 14.0), 4)
		for k in steps:
			var u := float(k) / float(steps)
			var q := p_a.lerp(p_b, u)
			# 垂度按跨距给，最多 9m
			var sag: float = minf(9.0, seg_len * 0.045) * sin(u * PI)
			ropes.append(Vector3(q.x, lerpf(y_a, y_b, u) - sag, q.y))
	var last_p: Vector2 = tower_pos[tower_pos.size() - 1]
	ropes.append(Vector3(last_p.x, tower_top[tower_top.size() - 1], last_p.y))
	var towers: Array[Transform3D] = []
	for i in tower_pos.size():
		var tp2: Vector2 = tower_pos[i]
		towers.append(Transform3D(Basis.IDENTITY,
			Vector3(tp2.x, world.height_at(tp2.x, tp2.y) + tower_h * 0.5, tp2.y)))
	var tower_mesh := CylinderMesh.new()
	tower_mesh.top_radius = 0.45
	tower_mesh.bottom_radius = 0.80
	tower_mesh.height = tower_h
	tower_mesh.radial_segments = 6
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = tower_mesh
	mm.instance_count = towers.size()
	for i in towers.size():
		mm.set_instance_transform(i, towers[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "CableTowers"
	mmi.multimesh = mm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.26, 0.27, 0.30)
	mat.roughness = 0.62
	mat.metallic = 0.35
	mmi.material_override = mat
	container.add_child(mmi)
	# 格构塔架：四根主腿 + 横向缀条 + 顶部横担，比光溜溜一根管子像样
	var parts: Array[Transform3D] = []
	for i in towers.size():
		var tf: Transform3D = towers[i]
		var half := tower_h * 0.5
		var sp := 0.75
		# 四根主腿
		for sx in [-1.0, 1.0]:
			for sz in [-1.0, 1.0]:
				parts.append(Transform3D(Basis(Vector3.UP, 0.0).scaled(Vector3(0.30, half * 2.0, 0.30)),
					tf.origin + Vector3(sx * sp, 0.0, sz * sp)))
		# 横向缀条
		for lvl in range(6):
			var y := -half + 1.5 + float(lvl) * 4.4
			for sz2 in [-1.0, 1.0]:
				parts.append(Transform3D(Basis(Vector3.UP, 0.0).scaled(Vector3(sp * 2.0, 0.16, 0.16)),
					tf.origin + Vector3(0.0, y, sz2 * sp)))
			for sx2 in [-1.0, 1.0]:
				parts.append(Transform3D(Basis(Vector3.UP, 0.0).scaled(Vector3(0.16, 0.16, sp * 2.0)),
					tf.origin + Vector3(sx2 * sp, y, 0.0)))
		# 顶部横担（两个方向）。压在缆绳正下方 0.3m，
		# 缆绳真的搭在横担上，不会从塔顶穿过去，也不会飘在天上。
		parts.append(Transform3D(Basis(Vector3.UP, 0.0).scaled(Vector3(5.2, 0.26, 0.26)),
			tf.origin + Vector3(0.0, half - 0.3, 0.0)))
		parts.append(Transform3D(Basis(Vector3.UP, 0.0).scaled(Vector3(0.26, 0.26, 5.2)),
			tf.origin + Vector3(0.0, half - 0.3, 0.0)))
	_pylon_parts(container, parts)
	# 缆绳。
	# 原来每个采样点只塞了 1 个顶点，索引却按每点 2 个顶点算，
	# 于是每个三角形都是"两个点重合"的退化面——缆绳根本画不出来，
	# 远看只剩几座光秃秃的塔架。现在按真实截面生成实体缆绳。
	var rope_verts := PackedVector3Array()
	var rope_norms := PackedVector3Array()
	var rope_idxs := PackedInt32Array()
	var rw := 0.11
	var rh := 0.20
	var rings: Array = []
	for i in ropes.size():
		var prev: Vector3 = ropes[maxi(i - 1, 0)]
		var nxt: Vector3 = ropes[mini(i + 1, ropes.size() - 1)]
		var tan := (nxt - prev)
		if tan.length() < 0.0001:
			tan = Vector3(1.0, 0.0, 0.0)
		tan = tan.normalized()
		var nrm := Vector3(-tan.z, 0.0, tan.x)
		if nrm.length() < 0.0001:
			nrm = Vector3(1.0, 0.0, 0.0)
		nrm = nrm.normalized()
		var p: Vector3 = ropes[i]
		var ring := [
			p + nrm * rw,
			p - nrm * rw,
			p - nrm * rw + Vector3.UP * rh,
			p + nrm * rw + Vector3.UP * rh,
		]
		rings.append(ring)
		for corner in ring:
			rope_verts.append(corner)
			rope_norms.append(nrm)
	for i in range(rings.size() - 1):
		var r0 := i * 4
		var r1 := r0 + 4
		for k in 4:
			var k2 := (k + 1) % 4
			rope_idxs.append(r0 + k)
			rope_idxs.append(r0 + k2)
			rope_idxs.append(r1 + k2)
			rope_idxs.append(r0 + k)
			rope_idxs.append(r1 + k2)
			rope_idxs.append(r1 + k)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = rope_verts
	arrays[Mesh.ARRAY_NORMAL] = rope_norms
	arrays[Mesh.ARRAY_INDEX] = rope_idxs
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var rope_mat := StandardMaterial3D.new()
	rope_mat.albedo_color = Color(0.16, 0.17, 0.18)
	rope_mat.roughness = 0.45
	rope_mat.metallic = 0.55
	# 缆绳是细长带状体，两侧都要看得见
	rope_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var rmi := MeshInstance3D.new()
	rmi.name = "CableRope"
	rmi.mesh = mesh
	rmi.material_override = rope_mat
	container.add_child(rmi)


# ---------------------------------------------------------------------------
# ⑦ 冰川湖
# ---------------------------------------------------------------------------

static func _build_glacier(world: OpenWorld, container: Node3D, stats: Dictionary) -> void:
	var zone: Dictionary = OpenWorld.ZONES[6]
	var c: Vector2 = zone["center"]
	var radius := float(zone["radius"])
	var rng := _rng(70007)

	# 冰湖水面
	_water_disc(container, "GlacierLake",
		Vector3(OpenWorld.LAKE_CENTER.x, OpenWorld.LAKE_LEVEL, OpenWorld.LAKE_CENTER.y),
		OpenWorld.LAKE_RADIUS * 0.92, Color(0.05, 0.16, 0.28), Color(0.30, 0.60, 0.74))

	# 冰层：湖面上的浮冰。
	#
	# 原来这里是 18~52m 的大发光 BoxMesh，固定摆在 LAKE_LEVEL-0.2，
	# 遇到湖岸的斜坡就整块翘出来——航拍里雪坡上浮着几片白平行四边形。
	# 现在改成逐顶点贴合地形、并且高度不超过湖面高度的薄冰片。
	var ice_acc := _patch_acc_new()
	for i in 44:
		var a := rng.randf() * TAU
		var rr := OpenWorld.LAKE_RADIUS * rng.randf_range(0.50, 1.05)
		var p := OpenWorld.LAKE_CENTER + Vector2(cos(a) * rr, sin(a) * rr)
		var h := world.height_at(p.x, p.y)
		if h > OpenWorld.LAKE_LEVEL + 1.0:
			continue
		# 冰片不能压住路面
		if world.road_edge_distance_exact(p.x, p.y) < 8.0:
			continue
		_patch_add(ice_acc, world, p, rng.randf_range(7.0, 17.0),
			rng.randf_range(5.0, 12.0), rng.randf() * TAU, 0.05,
			OpenWorld.LAKE_LEVEL + 0.05, 3)
	_patch_build(container, "IceSheet", ice_acc, _emissive_mat(Color(0.68, 0.86, 0.96), 0.55))

	for asset in TREE_PINES:
		var xforms: Array[Transform3D] = []
		for p in _scatter(c, radius * 1.15, 320, rng, 0.15):
			var h := world.height_at(p.x, p.y)
			if h < OpenWorld.LAKE_LEVEL + 1.0 or h > 170.0:
				continue
			if world.slope_at(p.x, p.y) > 0.68:
				continue
			if world.road_distance_at(p.x, p.y) < 16.0:
				continue
			xforms.append(_xform(world, p, rng.randf_range(7.0, 17.0), asset, rng.randf() * TAU, 0.02))
		_place(container, asset, xforms, "GlacierPine", 1400.0, true, stats)

	for asset2 in ROCKS:
		var xforms2: Array[Transform3D] = []
		for p in _scatter(c, radius * 1.2, 110, rng, 0.05):
			var h := world.height_at(p.x, p.y)
			if h < OpenWorld.LAKE_LEVEL:
				continue
			if world.road_distance_at(p.x, p.y) < 15.0:
				continue
			xforms2.append(_xform(world, p, rng.randf_range(4.0, 14.0), asset2, rng.randf() * TAU, 0.18))
		_place(container, asset2, xforms2, "GlacierRock", 1700.0, true, stats)

	# 冰川边缘的枯木与矮林
	_mixed_woodland(world, container, c, radius * 1.1, 170, DEAD_TREES + TREE_BROAD,
		6.0, 13.0, 12.0, 105.0, 0.50, 70008, "GlacierMix", stats)

	# 冻住的船
	var ship := OpenWorld.LAKE_CENTER + Vector2(150.0, -60.0)
	_place(container, "ship_real",
		[Transform3D(Basis(Vector3.UP, 0.7), Vector3(ship.x, OpenWorld.LAKE_LEVEL - 1.4, ship.y))]
			as Array[Transform3D], "FrozenShip", 2600.0, true, stats)


# ---------------------------------------------------------------------------
# ⑧ 熔岩盆地
# ---------------------------------------------------------------------------

static func _build_magma(world: OpenWorld, container: Node3D, stats: Dictionary) -> void:
	var zone: Dictionary = OpenWorld.ZONES[7]
	var c: Vector2 = zone["center"]
	var radius := float(zone["radius"])
	var rng := _rng(80008)

	# 熔岩流：贴着地表的熔岩带。
	#
	# 原来这里是 70 块「一个大 BoxMesh」发光板：单块最大 46×30m，
	# 中心按地形高度 +0.45 摆过去（盒子横跨 h+0.20 ~ h+0.70），
	# 落到坡上就是一半悬空一半埋地，航拍下去满坡散着橙色"扑克牌"；
	# 车开进去还会被整块盖住。
	# 现在改成按 height_at 逐顶点贴合地形的薄片，并顺着坡往下淌。
	var lava_acc := _patch_acc_new()
	var lava_acc2 := _patch_acc_new()
	for i in 90:
		var a := rng.randf() * TAU
		var rr := OpenWorld.VOLCANO_RADIUS * rng.randf_range(0.22, 1.30)
		var p := OpenWorld.VOLCANO_CENTER + Vector2(cos(a) * rr, sin(a) * rr)
		var h := world.height_at(p.x, p.y)
		if h > 78.0:
			continue
		# 熔岩不能盖住路面：离路面边缘留出余量。
		if world.road_edge_distance_exact(p.x, p.y) < 9.0:
			continue
		var dir := _downhill(world, p)
		var yaw := atan2(dir.y, dir.x)
		var len_x := rng.randf_range(9.0, 20.0)
		var len_z := rng.randf_range(3.5, 7.5)
		var acc := lava_acc if (i % 3 != 0) else lava_acc2
		_patch_add(acc, world, p, len_x, len_z, yaw, 0.06, 0.0, 3)
	_patch_build(container, "LavaFlow", lava_acc, _emissive_mat(Color(1.0, 0.36, 0.08), 3.2))
	_patch_build(container, "LavaFlowHot", lava_acc2, _emissive_mat(Color(1.0, 0.72, 0.18), 3.6))

	# 火山岩
	for asset in ROCKS:
		var xforms: Array[Transform3D] = []
		for p in _scatter(c, radius * 1.25, 240, rng, 0.05):
			var h := world.height_at(p.x, p.y)
			if h < 6.0:
				continue
			if world.road_distance_at(p.x, p.y) < 15.0:
				continue
			xforms.append(_xform(world, p, rng.randf_range(5.0, 20.0), asset, rng.randf() * TAU, 0.16))
		_place(container, asset, xforms, "MagmaRock", 1700.0, true, stats)

	# 焦木
	for asset2 in DEAD_TREES:
		var xforms2: Array[Transform3D] = []
		for p in _scatter(c, radius * 1.3, 110, rng, 0.05):
			var h := world.height_at(p.x, p.y)
			if h < 8.0:
				continue
			if world.road_distance_at(p.x, p.y) < 15.0:
				continue
			xforms2.append(_xform(world, p, rng.randf_range(5.0, 13.0), asset2, rng.randf() * TAU, 0.03))
		_place(container, asset2, xforms2, "MagmaBurnt", 1000.0, true, stats)

	# 炼油厂 / 管道
	var pipes: Array[Transform3D] = []
	for i in 16:
		var p := c + Vector2(rng.randf_range(-radius * 0.7, radius * 0.7),
			rng.randf_range(-radius * 0.7, radius * 0.7))
		var bh := rng.randf_range(8.0, 18.0)
		if not _building_clear(world, "industrial_pipes", p, bh, 8.0):
			continue
		pipes.append(_xform_capped(world, p, bh, "industrial_pipes", rng.randf() * TAU, 0.0, 8.0))
	_place(container, "industrial_pipes", pipes, "MagmaPipe", 1600.0, true, stats)

	var facades: Array[Transform3D] = []
	for i in 6:
		var p := c + Vector2(rng.randf_range(-radius * 0.6, radius * 0.6),
			rng.randf_range(-radius * 0.6, radius * 0.6))
		var bh := rng.randf_range(14.0, 30.0)
		# factory_facade 天然 53m 宽，必须压住占位，否则厂房墙压在路面上。
		if not _building_clear(world, "factory_facade", p, bh, 20.0):
			continue
		facades.append(_xform_capped(world, p, bh, "factory_facade", rng.randf() * TAU, 0.0, 20.0))
	_place(container, "factory_facade", facades, "MagmaRefinery", 1800.0, true, stats)

	# 火山口蒸汽柱：原来是 12~26m 见方的大发光板浮在火山口上，
	# 航拍下去就是几块悬在山尖的橙色方板。改成贴着地面的熔岩口。
	var vent_acc := _patch_acc_new()
	for i in 7:
		var p := OpenWorld.VOLCANO_CENTER + Vector2(rng.randf_range(-70.0, 70.0),
			rng.randf_range(-70.0, 70.0))
		var s := rng.randf_range(7.0, 14.0)
		_patch_add(vent_acc, world, p, s, s * rng.randf_range(0.6, 1.0),
			rng.randf() * TAU, 0.08, 0.0, 3)
	_patch_build(container, "CraterVent", vent_acc, _emissive_mat(Color(1.0, 0.42, 0.10), 4.0))
