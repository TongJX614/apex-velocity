class_name ThemeScenery
extends RefCounted
## 4 类主题家族的场景装配器（用户要求：只在赛道左右两侧布景 + 远山雾化剪影）。
##
##   desert : canyon / magma  —— 戈壁/荒漠：沙砾、风蚀岩、台地峡谷，无树无草
##   city   : city / skyline  —— 城市峡谷：楼群贴路两排、路灯、霓虹
##   valley : alpine / glacier—— 山谷：两侧低模山壁夹道 + 雪/岩 + 松树
##   coast  : coast / harbor  —— 海边：海面贴路（track_builder 负责），沙岸/礁石/棕榈/码头
##
## 硬性规则：
##   · 所有可玩细节的横向距离 ≤ path.half_width + 90m（MAX_EXTRA），更远不摆；
##   · 远景只有「低模剪影山环」+ 环境雾，不再摆高模远山/远景物件；
##   · 每张图只出现本主题的物件（戈壁不出树草、城市不出树草、雪地只有松/雪/岩）；
##   · 起跑主直道（场馆区）附近不摆中景，保证发车视野干净；
##   · 全部走 MultiMesh / 少量低模网格，避免逐帧 new 节点。
##
## 依赖 SceneryKit 的通用工具函数（材质/多网格/贴地），不重复实现。

const MAX_EXTRA := 90.0  # 从路肩算起的最大横向距离（米）
const ROOT := "res://assets/venues/"


# ===========================================================================
# 入口
# ===========================================================================

static func family_of(track_id: String) -> String:
	match track_id:
		"canyon", "magma":
			return "desert"
		"city", "skyline", "metro":
			return "city"
		"alpine", "glacier", "pass":
			return "valley"
		"coast", "harbor":
			return "coast"
	return "coast"


static func build(container: Node3D, path: TrackPath, def: Dictionary, theme: Dictionary,
		rng: RandomNumberGenerator, stats: Dictionary) -> void:
	var track_id := String(def.get("id", ""))
	var family := family_of(track_id)
	var venue := path.venue_span()
	# 每条赛道一个固定的山脊噪声，山形稳定可复现（截图/烘焙一致）
	var ridge := FastNoiseLite.new()
	ridge.seed = hash(track_id) + 4242
	ridge.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	ridge.frequency = 0.0022
	ridge.fractal_type = FastNoiseLite.FRACTAL_FBM
	ridge.fractal_octaves = 3
	if track_id == "pass":
		# 雾岭山道整张图直接复刻 .blend 场景排布，不走通用山谷模板
		_build_pass(container, path, theme, rng, stats, venue, ridge)
	else:
		match family:
			"desert":
				_build_desert(container, path, theme, rng, stats, venue, ridge, track_id)
			"city":
				_build_city(container, path, theme, rng, stats, venue, track_id)
			"valley":
				_build_valley(container, path, theme, rng, stats, venue, ridge, track_id)
			_:
				_build_coast(container, path, theme, rng, stats, venue, track_id)
		# 山路跨度是普通环道的数倍，通用剪影山环会变成贴脸的灰墙；
		# 远景由场景自带的真实山体承担，只在更远处补一圈雾化山脊。
		if track_id != "pass":
			_build_far_ring(container, path, theme, family, rng, stats, ridge)


# ===========================================================================
# 通用小工具
# ===========================================================================

static func _near_venue(path: TrackPath, dist: float, venue: Dictionary, margin: float = 26.0) -> bool:
	var center := float(venue.get("center_dist", 0.0))
	var half_len := float(venue.get("half_len", 0.0)) + margin
	var delta := wrapf(dist - center, -path.total_length * 0.5, path.total_length * 0.5)
	return absf(delta) <= half_len


static func _near_hero(path: TrackPath, hero: Dictionary, dist: float, margin: float) -> bool:
	if hero.is_empty():
		return false
	var hd := float(hero.get("hero_dist", -1.0e9))
	if hd < -1.0e8:
		return false
	return absf(wrapf(dist - hd, -path.total_length * 0.5, path.total_length * 0.5)) <= margin


## 横向点：side_sign = +1 外圈（海侧）/ -1 内圈（陆侧）。extra 从路肩算起。
static func _lat_pos(frame: Dictionary, half: float, extra: float, side_sign: float) -> Vector3:
	var p: Vector3 = (frame["pos"] as Vector3) \
		+ (frame["side"] as Vector3) * ((half + extra) * side_sign)
	p.y = Terrain.height_at(p) if Terrain.active else 0.0
	return p


## 沿整条赛道撒真实 CC0 资产（MultiMesh + 分块剔除）。
## side_mask: 0 两侧 / 1 只外圈(海侧) / -1 只内圈(陆侧)。
static func _scatter(container: Node3D, path: TrackPath, rng: RandomNumberGenerator,
		asset: String, count: int, extra_min: float, extra_max: float,
		hmin: float, hmax: float, prefix: String, vis_end: float,
		extra_clear: float = 4.0, side_mask: int = 0, venue: Dictionary = {},
		venue_margin: float = 30.0, hero_gap: Dictionary = {}, hero_margin: float = 0.0,
		stats: Dictionary = {}, sink_frac: float = 0.0) -> void:
	if count <= 0 or not RealAssetKit.has(asset):
		return
	var lo := clampf(extra_min, 0.0, MAX_EXTRA)
	var hi := clampf(extra_max, lo, MAX_EXTRA)
	var half := path.half_width
	var xforms: Array[Transform3D] = []
	var attempts := count * 4
	while xforms.size() < count and attempts > 0:
		attempts -= 1
		var dist := rng.randf() * path.total_length
		if not venue.is_empty() and _near_venue(path, dist, venue, venue_margin):
			continue
		if not hero_gap.is_empty() and _near_hero(path, hero_gap, dist, hero_margin):
			continue
		var frame := path.frame_at(dist)
		if frame.is_empty():
			continue
		var side_sign := 1.0
		if side_mask == 0:
			side_sign = 1.0 if rng.randf() < 0.5 else -1.0
		elif side_mask < 0:
			side_sign = -1.0
		var pos := _lat_pos(frame, half, rng.randf_range(lo, hi), side_sign)
		if not VenueKit.clear_of_track(path, pos, extra_clear):
			continue
		var target_h := rng.randf_range(hmin, hmax)
		var s := RealAssetKit.scale_for_height(asset, target_h)
		# 尺寸感知净空：按「顶点实测渲染半径」×缩放 加大离路距离，
		# 保证任何 yaw 旋转下树冠/石角都不压路面（AABB 会低估 1.5~1.9 倍）。
		var footprint := RealAssetKit.true_radius(asset) * s
		if not VenueKit.clear_of_track(path, pos, maxf(extra_clear, footprint + 1.6)):
			continue
		# 山丘/巨石模型是窄底宽腰的锥体，底座落在地表时腰身会悬空；
		# 按目标高度下沉一截，让地面从腰部切进去，远看才像长在地上的石头。
		pos.y -= target_h * sink_frac
		var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3.ONE * s)
		xforms.append(Transform3D(basis, pos))
	# Ultra 档给路边树木真实投影（低/中/高默认关掉，保住帧率；
	# 树木是这片场景里数量最多的投影源，开一档就要多一整轮阴影几何）
	var cast_shadow := RealAssetKit.is_vegetation(asset) and RealAssetKit._quality_index() >= 3
	RealAssetKit.place_chunked(container, asset, xforms, prefix, vis_end, cast_shadow, stats)


## 程序化低模碎石/砾石带（戈壁与雪地共用）：12 面盒体 MultiMesh，极低开销。
static func _scatter_gravel(container: Node3D, path: TrackPath, rng: RandomNumberGenerator,
		count: int, extra_min: float, extra_max: float, size_min: float, size_max: float,
		color_a: Color, color_b: Color, prefix: String,
		venue: Dictionary, venue_margin: float = 30.0, stats: Dictionary = {},
		side_mask: int = 0) -> void:
	if count <= 0:
		return
	var half := path.half_width
	var xforms: Array[Transform3D] = []
	var colors: Array[Color] = []
	var attempts := count * 3
	while xforms.size() < count and attempts > 0:
		attempts -= 1
		var dist := rng.randf() * path.total_length
		if not venue.is_empty() and _near_venue(path, dist, venue, venue_margin):
			continue
		var frame := path.frame_at(dist)
		if frame.is_empty():
			continue
		var side_sign := 1.0
		if side_mask == 0:
			side_sign = 1.0 if rng.randf() < 0.5 else -1.0
		elif side_mask < 0:
			side_sign = -1.0
		var pos := _lat_pos(frame, half, rng.randf_range(extra_min, extra_max), side_sign)
		# 砾石带半宽可达 ~0.8m，净距必须让边缘远离护栏（half+1.2）
		if not VenueKit.clear_of_track(path, pos, 3.2):
			continue
		var s := rng.randf_range(size_min, size_max)
		var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(
			Vector3(s, s * rng.randf_range(0.22, 0.55), s * rng.randf_range(0.6, 1.1)))
		xforms.append(Transform3D(basis, pos + Vector3(0.0, -0.02, 0.0)))
		colors.append(color_a.lerp(color_b, snappedf(rng.randf(), 0.25)))
	var mesh := BoxMesh.new()
	mesh.size = Vector3(1.0, 1.0, 1.0)
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.96
	SceneryKit._prop_mm_tinted(container, mesh, mat, xforms, colors, prefix, stats, 420.0, false)


## 沿赛道等距排放（路灯、护栏灯、旗杆等），返回 [距离] 列表。
static func _even_distances(path: TrackPath, step: float, offset: float = 0.0) -> Array[float]:
	var out: Array[float] = []
	var d := offset
	var guard := 0
	while d < path.total_length and guard < 4000:
		out.append(d)
		d += step
		guard += 1
	return out


# ===========================================================================
# 1) 戈壁 / 荒漠（canyon / magma）
# ===========================================================================

static func _build_desert(container: Node3D, path: TrackPath, theme: Dictionary,
		rng: RandomNumberGenerator, stats: Dictionary, venue: Dictionary,
		ridge: FastNoiseLite, track_id: String) -> void:
	var volcanic := track_id == "magma"
	var hero := SceneryKit._hero_spot(path)
	# --- 两侧台地峡谷壁：整个赛道夹在戈壁山谷里 ---
	var low_col := Color(0.30, 0.17, 0.13) if volcanic else Color(0.55, 0.33, 0.22)
	var high_col := Color(0.16, 0.11, 0.12) if volcanic else Color(0.74, 0.48, 0.31)
	var wall_style := {
		"kind": "mesa",
		"base_extra": 22.0,
		"height": 46.0 if volcanic else 58.0,
		"low_color": low_col,
		"high_color": high_col,
		"texture": "desert",
		"fill_color": SceneryKit._color(String(theme.get("hemiSky", "#6b5a8c")),
			Color(0.5, 0.42, 0.5)).lightened(0.08),
		"fill_energy": 0.62 if volcanic else 0.48,
		"haze_color": SceneryKit._color(String(theme.get("fogColor", "#8a4c40")),
			Color(0.6, 0.45, 0.4)).darkened(0.12),
	}
	_build_valley_walls(container, path, rng, stats, venue, hero, 80.0, wall_style, ridge)
	# 两侧孤峰台地：戈壁峡谷的主力剪影
	_build_desert_buttes(container, path, rng, stats, venue, volcanic)

	# 木棚先建先登记实体，巨石/废车散点才有得躲（顺序反了就是 pen=80 穿模）
	_build_canyon_shack_near(container, path, rng, stats, venue)

	# --- 风蚀岩 / 巨石（真实 CC0 扫描几何） ---
	var boulder := "boulder02" if RealAssetKit.has("boulder02") else "boulder03"
	_scatter(container, path, rng, boulder, 50, 4.0, 20.0, 1.2, 5.5,
		"DesertBoulders", 520.0, 4.5, 0, venue, 30.0, hero, 0.0, stats)
	_scatter(container, path, rng, "boulder03", 34, 6.0, 21.0, 2.0, 7.5,
		"DesertMegaliths", 620.0, 6.0, 0, venue, 30.0, hero, 0.0, stats)
	# --- 地表砾石带 ---
	_scatter_gravel(container, path, rng, 260, 1.6, 26.0, 0.35, 1.5,
		Color(0.62, 0.42, 0.30) if not volcanic else Color(0.34, 0.24, 0.22),
		Color(0.42, 0.27, 0.2) if not volcanic else Color(0.2, 0.14, 0.14),
		"DesertGravel", venue, 24.0, stats)

	# --- 熔岩地貌只在 magma 出现，并且收敛成「少量热裂缝」 ---
	if volcanic:
		_build_magma_heat(container, path, rng, stats, venue)
		_build_refinery_near(container, path, rng, stats, venue)
		_scatter(container, path, rng, "barrel_real", 10, 3.5, 22.0, 0.9, 1.05,
			"MagmaBarrels", 320.0, 3.0, 0, venue, 26.0, {}, 0.0, stats)
		_scatter(container, path, rng, "industrial_pipes", 6, 6.0, 28.0, 1.4, 2.2,
			"MagmaPipeScrap", 480.0, 5.0, 0, venue, 26.0, {}, 0.0, stats)
	else:
		# 赤岩峡谷：电线杆先建先登记实体，油桶/废车散点才有得躲
		_build_desert_power_line(container, path, rng, stats, venue)
		# 路边油桶 / 废弃蒙布车（都是荒漠公路该有的东西）
		_scatter(container, path, rng, "barrel_real", 10, 3.5, 20.0, 0.9, 1.05,
			"CanyonBarrels", 320.0, 3.0, 0, venue, 26.0, {}, 0.0, stats)
		_scatter(container, path, rng, "car_wreck_real", 5, 5.0, 26.0, 1.4, 1.6,
			"CanyonWrecks", 480.0, 6.0, 0, venue, 26.0, {}, 0.0, stats)

	# --- 路肩轮胎墙 / 反光标记（荒漠拉力风格，贴边不压路） ---
	_build_desert_track_furniture(container, path, rng, stats, venue, volcanic)


## 熔岩热感：少量发光裂缝 + 远处的暗红天光柱（不铺满熔岩湖）。
static func _build_magma_heat(container: Node3D, path: TrackPath, rng: RandomNumberGenerator,
		stats: Dictionary, venue: Dictionary) -> void:
	var lava := SceneryKit._lava_material()
	var ribbons: Array[ArrayMesh] = []
	for k in 3:
		ribbons.append(SceneryKit._lava_ribbon_mesh(16.0 + float(k) * 8.0, 1.6 + float(k) * 0.5, 18))
	var buckets: Array = [[], [], []]
	var half := path.half_width
	var placed := 0
	var attempts := 120
	while placed < 22 and attempts > 0:
		attempts -= 1
		var dist := rng.randf() * path.total_length
		if _near_venue(path, dist, venue, 30.0):
			continue
		var frame := path.frame_at(dist)
		if frame.is_empty():
			continue
		var side_sign := 1.0 if rng.randf() < 0.5 else -1.0
		var pos := _lat_pos(frame, half, rng.randf_range(5.0, 36.0), side_sign)
		if not VenueKit.clear_of_track(path, pos, 4.0):
			continue
		(buckets[placed % 3] as Array).append(Transform3D(
			Basis(Vector3.UP, rng.randf() * TAU).scaled(
				Vector3(rng.randf_range(0.7, 1.4), 1.0, rng.randf_range(0.7, 1.4))),
			pos + Vector3(0.0, 0.05, 0.0)))
		placed += 1
	for k in 3:
		var typed: Array[Transform3D] = []
		for xf in (buckets[k] as Array):
			typed.append(xf as Transform3D)
		SceneryKit._prop_mm(container, ribbons[k], lava, typed, [], "MagmaLavaCracks_%d" % k,
			stats, 700.0, false)
	# 远处炼油厂的火炬光（几根低模热柱，只是暖光点缀）
	var glow_mesh := CylinderMesh.new()
	glow_mesh.top_radius = 1.4
	glow_mesh.bottom_radius = 2.6
	glow_mesh.height = 1.0
	glow_mesh.radial_segments = 7
	glow_mesh.rings = 1
	var glows: Array[Transform3D] = []
	var glow_mat := SceneryKit._emissive_mat(Color(1.0, 0.42, 0.12), 1.4)
	for k in 3:
		var dist := path.total_length * (0.17 + float(k) * 0.31)
		if _near_venue(path, dist, venue, 40.0):
			continue
		var frame := path.frame_at(dist)
		if frame.is_empty():
			continue
		var side_sign := -1.0 if k % 2 == 0 else 1.0
		var pos := _lat_pos(frame, path.half_width, 62.0 + float(k) * 6.0, side_sign)
		pos.y = 0.0
		glows.append(Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(
			Vector3(1.0, rng.randf_range(9.0, 14.0), 1.0)), pos + Vector3(0.0, 6.0, 0.0)))
	SceneryKit._prop_mm(container, glow_mesh, glow_mat, glows, [], "MagmaHeatGlow", stats, 1600.0, false)
	_build_magma_pools(container, path, rng, stats, venue)
	_build_magma_lakes(container, path, rng, stats, venue)
	_build_magma_flows(container, path, rng, stats, venue)


## 熔岩池：贴地曲面（按地形高度采样）+ 程序化流动熔岩 + 少量红色照明。
## 放在赛道可见的 8~28m 外侧，不压路；近处两处加 OmniLight 让车身有火光反照。
static func _build_magma_pools(container: Node3D, path: TrackPath, rng: RandomNumberGenerator,
		stats: Dictionary, venue: Dictionary) -> void:
	var pool_mat := _magma_pool_material()
	var half := path.half_width
	var placed := 0
	var attempts := 70
	var lights := 0
	while placed < 9 and attempts > 0:
		attempts -= 1
		var dist := rng.randf() * path.total_length
		if _near_venue(path, dist, venue, 45.0):
			continue
		var frame := path.frame_at(dist)
		if frame.is_empty():
			continue
		var side_sign := 1.0 if rng.randf() < 0.5 else -1.0
		var extra := rng.randf_range(8.0, 28.0)
		var pos := _lat_pos(frame, half, extra, side_sign)
		var radius := rng.randf_range(2.4, 5.0)
		if not VenueKit.clear_of_track(path, pos, radius + 2.0):
			continue
		var mi := MeshInstance3D.new()
		mi.name = "MagmaPool_%d" % placed
		mi.mesh = _magma_pool_mesh(pos, radius, rng)
		mi.material_override = pool_mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		container.add_child(mi)
		stats["nodes"] = int(stats.get("nodes", 0)) + 1
		stats["meshes"] = int(stats.get("meshes", 0)) + 1
		if lights < 2:
			var light := OmniLight3D.new()
			light.name = "MagmaGlowLight_%d" % lights
			light.light_color = Color(1.0, 0.34, 0.08)
			light.light_energy = 2.4
			light.omni_range = radius * 5.0
			light.omni_attenuation = 1.4
			light.shadow_enabled = false
			light.position = pos + Vector3(0.0, 1.6, 0.0)
			container.add_child(light)
			lights += 1
		placed += 1


static func _magma_pool_mesh(center: Vector3, radius: float, rng: RandomNumberGenerator) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var segs := 26
	var mid := center + Vector3(0.0, 0.07, 0.0)
	var edge_pts: Array[Vector3] = []
	for i in segs:
		var a := TAU * float(i) / float(segs)
		var wobble := radius * (0.86 + 0.20 * sin(a * 3.0 + rng.randf() * 0.4))
		var p := center + Vector3(cos(a) * wobble, 0.0, sin(a) * wobble)
		p.y = Terrain.height_at(p) + 0.07
		edge_pts.append(p)
	for i in segs:
		var a0 := TAU * float(i) / float(segs)
		var a1 := TAU * float(i + 1) / float(segs)
		var p0 := edge_pts[i]
		var p1 := edge_pts[(i + 1) % segs]
		st.set_normal(Vector3.UP)
		st.set_uv(Vector2(0.5, 0.5))
		st.add_vertex(mid)
		st.set_normal(Vector3.UP)
		st.set_uv(Vector2(0.5 + cos(a0) * 0.5, 0.5 + sin(a0) * 0.5))
		st.add_vertex(p0)
		st.set_normal(Vector3.UP)
		st.set_uv(Vector2(0.5 + cos(a1) * 0.5, 0.5 + sin(a1) * 0.5))
		st.add_vertex(p1)
	return st.commit()


## 熔岩湖：大片贴地熔岩（6 个，近处小而亮、远处大而缓），
## 用环状网格按地形高度采样，避免湖面切进山丘；上面加两盏暖光把岩壁烤红。
static func _build_magma_lakes(container: Node3D, path: TrackPath, rng: RandomNumberGenerator,
		stats: Dictionary, venue: Dictionary) -> void:
	var mat := _magma_lake_material()
	var half := path.half_width
	var total := path.total_length
	var spots: Array[float] = []
	if not venue.is_empty():
		# 保证起跑直道出口就有一片熔岩，开局镜头一定能看到
		var d0 := float(venue.get("center_dist", 0.0)) + float(venue.get("half_len", 0.0)) + 55.0
		spots.append(fposmod(d0, total))
	for frac in [0.10, 0.24, 0.40, 0.56, 0.72, 0.88]:
		spots.append(total * frac)
	var placed := 0
	var lights := 0
	var placed_centers: Array = []
	for dist in spots:
		if placed >= 6:
			break
		if _near_venue(path, dist, venue, 32.0):
			continue
		var frame := path.frame_at(dist)
		if frame.is_empty():
			continue
		var best := {}
		var best_score := 1.0e9
		for side_sign: float in [-1.0, 1.0]:
			for extra: float in [30.0, 44.0, 62.0, 88.0, 120.0, 155.0]:
				var radius := 9.0 + minf(extra, 155.0) * 0.14
				var pos := _lat_pos(frame, half, extra, side_sign)
				if not VenueKit.clear_of_track(path, pos, radius + 7.0):
					continue
				var overlap := false
				for c in placed_centers:
					if pos.distance_to(c["pos"] as Vector3) < radius + float(c["r"]) + 14.0:
						overlap = true
						break
				if overlap:
					continue
				var hmin := 1.0e9
				var hmax := -1.0e9
				for k in 18:
					var a := TAU * float(k) / 18.0
					var p := pos + Vector3(cos(a), 0.0, sin(a)) * radius
					var h := Terrain.height_at(p)
					hmin = minf(hmin, h)
					hmax = maxf(hmax, h)
				var flat := hmax - hmin
				if flat > 13.0:
					continue
				var score: float = flat + absf(hmax) * 0.35 + extra * 0.02
				if score < best_score:
					best_score = score
					best = {"pos": pos, "r": radius, "extra": extra, "flat": flat}
		if best.is_empty():
			continue
		var pos: Vector3 = best["pos"]
		var radius := float(best["r"])
		var mi := MeshInstance3D.new()
		mi.name = "MagmaLake_%d" % placed
		mi.mesh = _magma_lake_mesh(pos, radius, rng)
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		container.add_child(mi)
		placed_centers.append({"pos": pos, "r": radius})
		stats["nodes"] = int(stats.get("nodes", 0)) + 1
		stats["meshes"] = int(stats.get("meshes", 0)) + 1
		if lights < 2:
			var light := OmniLight3D.new()
			light.name = "MagmaLakeLight_%d" % lights
			light.light_color = Color(1.0, 0.30, 0.06)
			light.light_energy = 3.6
			light.omni_range = radius * 5.2
			light.omni_attenuation = 1.25
			light.shadow_enabled = false
			light.position = pos + Vector3(0.0, 2.6, 0.0)
			container.add_child(light)
			lights += 1
		placed += 1


## 路肩熔岩流：沿赛道等距铺 12 条贴地熔岩带（14~24m 外侧），
## 起跑直道出口额外加一条，保证开局和每个弯都能看到流动的橙红熔岩。
static func _build_magma_flows(container: Node3D, path: TrackPath, rng: RandomNumberGenerator,
		stats: Dictionary, venue: Dictionary) -> void:
	var mat := _magma_flow_material()
	var total := path.total_length
	var dists: Array[float] = []
	for i in 12:
		dists.append(total * (float(i) + 0.35) / 12.0)
	if not venue.is_empty():
		dists.append(fposmod(float(venue.get("center_dist", 0.0))
			+ float(venue.get("half_len", 0.0)) + 30.0, total))
	var placed := 0
	for dist in dists:
		var frame := path.frame_at(dist)
		if frame.is_empty():
			continue
		var side_sign := 1.0 if placed % 2 == 0 else -1.0
		var extra := rng.randf_range(13.0, 22.0)
		var center := _lat_pos(frame, path.half_width, extra, side_sign)
		var length := rng.randf_range(26.0, 46.0)
		var width := rng.randf_range(4.0, 7.0)
		var tangent: Vector3 = frame["tangent"]
		if not VenueKit.clear_of_track(path, center, maxf(width, 6.0) + 1.0):
			continue
		var end_a := center - tangent * length * 0.5
		var end_b := center + tangent * length * 0.5
		if not VenueKit.clear_of_track(path, end_a, width + 2.0) \
				or not VenueKit.clear_of_track(path, end_b, width + 2.0):
			continue
		var yaw := atan2(-tangent.z, tangent.x)
		var mi := MeshInstance3D.new()
		mi.name = "MagmaFlow_%d" % placed
		mi.mesh = SceneryKit._lava_ribbon_mesh(length, width, 16)
		mi.material_override = mat
		mi.transform = Transform3D(Basis(Vector3.UP, yaw), center + Vector3(0.0, 0.07, 0.0))
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		container.add_child(mi)
		stats["nodes"] = int(stats.get("nodes", 0)) + 1
		stats["meshes"] = int(stats.get("meshes", 0)) + 1
		placed += 1


static func _magma_flow_material() -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = """shader_type spatial;
render_mode unshaded, cull_disabled, fog_disabled;
float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}
float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}
float fbm(vec2 p) {
	float s = 0.0;
	float a = 0.5;
	for (int i = 0; i < 4; i++) {
		s += vnoise(p) * a;
		p *= 2.05;
		a *= 0.5;
	}
	return s;
}
void fragment() {
	float edge = smoothstep(0.5, 0.34, abs(UV.y - 0.5));
	vec2 q = vec2(UV.x * 6.0 - TIME * 0.20, UV.y * 2.4);
	float n = fbm(q * 1.8);
	float flow = fbm(q * 3.4 + vec2(n * 1.6, TIME * 0.05));
	float veins = smoothstep(0.30, 0.80, flow);
	vec3 deep = vec3(0.38, 0.028, 0.003);
	vec3 hot = mix(vec3(0.92, 0.17, 0.008), vec3(0.95, 0.46, 0.07), veins);
	vec3 col = mix(deep, hot, 0.35 + veins * 0.65);
	ALBEDO = col * edge;
	EMISSION = col * (0.45 + veins * 0.55) * edge;
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = sh
	return mat


static func _magma_lake_mesh(center: Vector3, radius: float, rng: RandomNumberGenerator) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rings := 5
	var segs := 40
	var pts: Array = []
	for r in rings + 1:
		var rr := radius * float(r) / float(rings)
		var ring: Array[Vector3] = []
		for i in segs:
			var a := TAU * float(i) / float(segs)
			var wobble := 1.0 + 0.16 * sin(a * 3.0 + float(r) * 1.7)
			var p := center + Vector3(cos(a) * rr * wobble, 0.0, sin(a) * rr * wobble)
			p.y = Terrain.height_at(p) + 0.12
			ring.append(p)
		pts.append(ring)
	for r in rings:
		var ring_a: Array = pts[r]
		var ring_b: Array = pts[r + 1]
		var fa := 0.5 * float(r) / float(rings)
		var fb := 0.5 * float(r + 1) / float(rings)
		for i in segs:
			var i2 := (i + 1) % segs
			var a0: Vector3 = ring_a[i]
			var a1: Vector3 = ring_a[i2]
			var b0: Vector3 = ring_b[i]
			var b1: Vector3 = ring_b[i2]
			var ca := TAU * float(i) / float(segs)
			var cb := TAU * float(i2) / float(segs)
			var ua0 := Vector2(0.5 + cos(ca) * fa, 0.5 + sin(ca) * fa)
			var ua1 := Vector2(0.5 + cos(cb) * fa, 0.5 + sin(cb) * fa)
			var ub0 := Vector2(0.5 + cos(ca) * fb, 0.5 + sin(ca) * fb)
			var ub1 := Vector2(0.5 + cos(cb) * fb, 0.5 + sin(cb) * fb)
			st.set_normal(Vector3.UP)
			st.set_uv(ua0)
			st.add_vertex(a0)
			st.set_normal(Vector3.UP)
			st.set_uv(ua1)
			st.add_vertex(a1)
			st.set_normal(Vector3.UP)
			st.set_uv(ub0)
			st.add_vertex(b0)
			st.set_normal(Vector3.UP)
			st.set_uv(ua1)
			st.add_vertex(a1)
			st.set_normal(Vector3.UP)
			st.set_uv(ub1)
			st.add_vertex(b1)
			st.set_normal(Vector3.UP)
			st.set_uv(ub0)
			st.add_vertex(b0)
	return st.commit()


static func _magma_lake_material() -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = """shader_type spatial;
render_mode unshaded, cull_disabled, fog_disabled;
float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}
float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}
float fbm(vec2 p) {
	float s = 0.0;
	float a = 0.5;
	for (int i = 0; i < 4; i++) {
		s += vnoise(p) * a;
		p *= 2.05;
		a *= 0.5;
	}
	return s;
}
void fragment() {
	vec2 p = UV - vec2(0.5);
	float r = length(p) * 2.0;
	float edge = smoothstep(1.0, 0.70, r);
	vec2 q = p * 5.0 + vec2(TIME * 0.035, -TIME * 0.026);
	float n = fbm(q * 1.7);
	float flow = fbm(q * 3.1 + vec2(n * 2.4 + TIME * 0.08, -TIME * 0.05));
	float veins = smoothstep(0.28, 0.78, flow);
	vec3 deep = vec3(0.44, 0.045, 0.006);
	vec3 hot = mix(vec3(0.95, 0.20, 0.010), vec3(1.0, 0.60, 0.14), veins);
	vec3 col = mix(deep, hot, 0.32 + veins * 0.68);
	float crust = smoothstep(0.62, 0.99, r);
	col *= mix(1.0, 0.22, crust);
	ALBEDO = col * edge;
	EMISSION = col * (0.55 + veins * 0.65) * edge;
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = sh
	return mat


static func _magma_pool_material() -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = """shader_type spatial;
render_mode unshaded, cull_disabled, fog_disabled;
void fragment() {
	vec2 p = UV - vec2(0.5);
	float r = length(p) * 2.0;
	float edge = smoothstep(1.0, 0.62, r);
	vec2 q = p * 7.0 + vec2(TIME * 0.07, -TIME * 0.05);
	float n = sin(q.x * 2.9 + sin(q.y * 2.1 + TIME * 0.4)) * sin(q.y * 2.4 + sin(q.x * 1.7 - TIME * 0.3));
	float veins = smoothstep(0.05, 0.85, n * 0.5 + 0.5);
	vec3 hot = mix(vec3(0.56, 0.060, 0.008), vec3(1.0, 0.50, 0.10), veins);
	ALBEDO = hot * edge;
	EMISSION = hot * (0.55 + veins * 0.70) * edge;
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = sh
	return mat


## magma：废弃炼油厂贴到路边（原来在 hero 附近 34m，这里固定一段直道旁重摆）。
static func _build_refinery_near(container: Node3D, path: TrackPath, rng: RandomNumberGenerator,
		stats: Dictionary, venue: Dictionary) -> void:
	var hero := SceneryKit._hero_spot(path)
	var chosen := -1.0
	if not hero.is_empty():
		# 山壁在 hero 处留了缺口，炼油厂正好放进去，不会埋进山体
		chosen = float(hero["hero_dist"]) + 58.0
	if _near_venue(path, chosen, venue, 60.0):
		return
	if chosen < 0.0:
		return
	var f := path.frame_at(chosen)
	var side_sign := -1.0 if rng.randf() < 0.6 else 1.0
	var center := _lat_pos(f, path.half_width, 30.0, side_sign)
	var yaw := atan2((f["tangent"] as Vector3).x, (f["tangent"] as Vector3).z)
	var basis := Basis(Vector3.UP, yaw)
	var rusty := PbrAssets.rusty_corrugated()
	var metal := PbrAssets.metal(Vector2(4.0, 6.0))
	var lava := SceneryKit._lava_material()
	# 两根烟囱
	var chim_mesh := CylinderMesh.new()
	chim_mesh.top_radius = 0.85
	chim_mesh.bottom_radius = 1.7
	chim_mesh.height = 1.0
	chim_mesh.radial_segments = 9
	chim_mesh.rings = 1
	var chims: Array[Transform3D] = []
	var glows: Array[Transform3D] = []
	var glow_mesh := CylinderMesh.new()
	glow_mesh.top_radius = 1.0
	glow_mesh.bottom_radius = 1.0
	glow_mesh.height = 0.4
	glow_mesh.radial_segments = 9
	glow_mesh.rings = 1
	for k in 2:
		var p := center + basis * Vector3(-9.0 + float(k) * 18.0, 0.0, 0.0)
		var h := 20.0 + float(k) * 6.0
		chims.append(Transform3D(basis.scaled(Vector3(1.0, h, 1.0)), p + Vector3(0.0, h * 0.5, 0.0)))
		glows.append(Transform3D(basis.scaled(Vector3(1.35, 1.0, 1.35)),
			p + Vector3(0.0, h + 0.25, 0.0)))
	SceneryKit._prop_mm(container, chim_mesh, rusty, chims, [], "MagmaChimneys", stats, 1300.0, true)
	SceneryKit._prop_mm(container, glow_mesh, lava, glows, [], "MagmaChimneyGlow", stats, 1200.0, false)
	# 储罐
	var tank_mesh := CylinderMesh.new()
	tank_mesh.top_radius = 1.0
	tank_mesh.bottom_radius = 1.0
	tank_mesh.height = 1.0
	tank_mesh.radial_segments = 10
	tank_mesh.rings = 1
	var tanks: Array[Transform3D] = []
	for k in 2:
		var p := center + basis * Vector3(-4.0 + float(k) * 11.0, 0.0, -9.0)
		tanks.append(Transform3D(basis.scaled(Vector3(4.6, 8.0, 4.6)), p + Vector3(0.0, 4.0, 0.0)))
	SceneryKit._prop_mm(container, tank_mesh, metal, tanks, [], "MagmaStorageTanks", stats, 1200.0, true)


## 荒漠电线杆：沿陆侧等距，顶部细横担 + 两根电线（低模圆柱）。
static func _build_desert_power_line(container: Node3D, path: TrackPath,
		rng: RandomNumberGenerator, stats: Dictionary, venue: Dictionary) -> void:
	var use_asset := RealAssetKit.has("power_pole")
	var dists := _even_distances(path, 108.0, 34.0)
	var pole_x: Array[Transform3D] = []
	var arm_x: Array[Transform3D] = []
	var wire_x: Array[Transform3D] = []
	var tops: Array[Vector3] = []
	var half := path.half_width
	for d in dists:
		if _near_venue(path, d, venue, 40.0):
			continue
		var f := path.frame_at(d)
		if f.is_empty():
			continue
		var base := _lat_pos(f, half, 17.0, -1.0)
		var yaw := atan2((f["tangent"] as Vector3).x, (f["tangent"] as Vector3).z)
		var basis := Basis(Vector3.UP, yaw)
		if use_asset:
			# 真实电杆自带 13m 横担（资产高 7m），别再叠自定义横臂，
			# 挂线点取横担高度而不是杆顶
			pole_x.append(Transform3D(basis, base))
			tops.append(base + Vector3(0.0, 6.4, 0.0))
		else:
			var top := base + Vector3(0.0, 8.4, 0.0)
			tops.append(top)
			# 没有资产时用低模圆杆（1 个 MultiMesh）
			pole_x.append(Transform3D(basis.scaled(Vector3(0.18, 8.4, 0.18)),
				base + Vector3(0.0, 4.2, 0.0)))
			arm_x.append(Transform3D(basis.scaled(Vector3(2.4, 0.16, 0.16)), top + Vector3(0.0, 0.4, 0.0)))
	if pole_x.is_empty():
		return
	if use_asset:
		RealAssetKit.place_chunked(container, "power_pole", pole_x, "CanyonPoles", 900.0, false, stats)
	else:
		var pole_mesh := CylinderMesh.new()
		pole_mesh.top_radius = 1.0
		pole_mesh.bottom_radius = 1.0
		pole_mesh.height = 1.0
		pole_mesh.radial_segments = 6
		pole_mesh.rings = 1
		SceneryKit._prop_mm(container, pole_mesh, PbrAssets.weathered_planks(), pole_x, [],
			"CanyonPoles", stats, 900.0, false)
	if not arm_x.is_empty():
		var arm_mesh := BoxMesh.new()
		arm_mesh.size = Vector3(1.0, 1.0, 1.0)
		SceneryKit._prop_mm(container, arm_mesh, PbrAssets.metal(Vector2(1.0, 1.0)), arm_x, [],
			"CanyonPoleArms", stats, 900.0, false)
	if tops.size() >= 2:
		var wire_mesh := CylinderMesh.new()
		wire_mesh.top_radius = 1.0
		wire_mesh.bottom_radius = 1.0
		wire_mesh.height = 1.0
		wire_mesh.radial_segments = 4
		wire_mesh.rings = 1
		for k in tops.size() - 1:
			var a: Vector3 = tops[k]
			var b: Vector3 = tops[k + 1]
			if a.distance_to(b) > 240.0:
				continue
			for lane: float in [-1.0, 1.0]:
				var aa := a + Vector3(lane, 0.35, 0.0)
				var bb := b + Vector3(lane, 0.35, 0.0)
				var mid := (aa + bb) * 0.5 - Vector3(0.0, 2.4, 0.0)
				wire_x.append(SceneryKit._beam_xform(aa, mid, 0.035))
				wire_x.append(SceneryKit._beam_xform(mid, bb, 0.035))
		SceneryKit._prop_mm(container, wire_mesh, PbrAssets.metal(Vector2(0.5, 0.5)),
			wire_x, [], "CanyonPowerWires", stats, 800.0, false)


## 峡谷木棚：路边废弃木屋（真实风化木 PBR）。
static func _build_canyon_shack_near(container: Node3D, path: TrackPath,
		rng: RandomNumberGenerator, stats: Dictionary, venue: Dictionary) -> void:
	var dists := _even_distances(path, 260.0, 90.0)
	for d in dists:
		if _near_venue(path, d, venue, 50.0):
			continue
		var f := path.frame_at(d + rng.randf_range(-20.0, 20.0))
		if f.is_empty():
			continue
		var side_sign := 1.0 if rng.randf() < 0.5 else -1.0
		var center := _lat_pos(f, path.half_width, rng.randf_range(10.0, 19.0), side_sign)
		if not VenueKit.clear_of_track(path, center, 10.0):
			continue
		var yaw := atan2((f["tangent"] as Vector3).x, (f["tangent"] as Vector3).z) + rng.randf_range(-0.2, 0.2)
		var basis := Basis(Vector3.UP, yaw)
		var planks := PbrAssets.weathered_planks()
		var w := rng.randf_range(4.5, 6.5)
		var h := rng.randf_range(2.6, 3.4)
		var dp := rng.randf_range(3.5, 5.0)
		# 木棚登记为实体：孤丘/巨石/砾石散点靠这个躲开棚体
		# （Megaliths×棚体 pen=83 的根因就是棚子没登记）
		RealAssetKit.register_solid(center, 0.5 * sqrt(w * w + dp * dp) + 0.6)
		var body := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(w, h, dp)
		body.mesh = bm
		body.material_override = planks
		body.transform = Transform3D(basis, center + Vector3(0.0, h * 0.5, 0.0))
		body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		container.add_child(body)
		var roof := MeshInstance3D.new()
		var rm := BoxMesh.new()
		rm.size = Vector3(w + 0.8, 0.14, dp + 0.8)
		roof.mesh = rm
		var roof_mat := PbrAssets.rusty_corrugated()
		roof_mat.albedo_color = Color(0.55, 0.34, 0.24)
		roof.material_override = roof_mat
		roof.transform = Transform3D(basis * Basis(Vector3.RIGHT, 0.12), center + Vector3(0.0, h + 0.3, 0.0))
		container.add_child(roof)
		stats["nodes"] = int(stats.get("nodes", 0)) + 2


## 荒漠路肩：轮胎墙 / 反光柱（都是低模 MultiMesh）。
static func _build_desert_track_furniture(container: Node3D, path: TrackPath,
		rng: RandomNumberGenerator, stats: Dictionary, venue: Dictionary, volcanic: bool) -> void:
	var tyre_mesh := CylinderMesh.new()
	tyre_mesh.top_radius = 0.34
	tyre_mesh.bottom_radius = 0.34
	tyre_mesh.height = 0.22
	tyre_mesh.radial_segments = 8
	tyre_mesh.rings = 1
	var tyres: Array[Transform3D] = []
	var half := path.half_width
	var dist := 60.0
	var placed := 0
	while dist < path.total_length and placed < 40:
		if _near_venue(path, dist, venue, 40.0):
			dist += 40.0
			continue
		var f := path.frame_at(dist)
		if not f.is_empty():
			var curv := 0.0
			var idx := int(dist / maxf(path.total_length, 1.0) * float(path.samples.size())) % path.samples.size()
			curv = path.curvatures[idx]
			if absf(curv) > 0.010:
				var out_sign := -signf(curv)
				for k in 3:
					var p := _lat_pos(f, half, 2.1, out_sign)
					p += (f["tangent"] as Vector3) * (float(k) - 1.0) * 0.78
					tyres.append(Transform3D(Basis(Vector3.UP, rng.randf() * TAU), p + Vector3(0.0, 0.11, 0.0)))
				placed += 1
				dist += 46.0
				continue
		dist += 18.0
	if not tyres.is_empty():
		SceneryKit._prop_mm(container, tyre_mesh, SceneryKit._mat(Color(0.09, 0.09, 0.1)),
			tyres, [], "DesertTyres", stats, 480.0, false)
	# 反光路桩：贴边一排，荒漠公路夜里也能看见路
	var post_mesh := BoxMesh.new()
	post_mesh.size = Vector3(0.14, 0.9, 0.14)
	var reflector_mesh := BoxMesh.new()
	reflector_mesh.size = Vector3(0.18, 0.18, 0.06)
	var posts: Array[Transform3D] = []
	var reflectors: Array[Transform3D] = []
	var colors: Array[Color] = []
	for d in _even_distances(path, 34.0, 17.0):
		if _near_venue(path, d, venue, 30.0):
			continue
		var f := path.frame_at(d)
		if f.is_empty():
			continue
		var side_sign := 1.0 if rng.randf() < 0.5 else -1.0
		var p := _lat_pos(f, half, 1.8, side_sign)
		var yaw := atan2((f["tangent"] as Vector3).x, (f["tangent"] as Vector3).z)
		var basis := Basis(Vector3.UP, yaw)
		posts.append(Transform3D(basis, p + Vector3(0.0, 0.45, 0.0)))
		reflectors.append(Transform3D(basis, p + Vector3(0.0, 0.72, 0.0)))
		colors.append(Color(1.0, 0.55, 0.12) if volcanic else Color(1.0, 0.72, 0.2))
	if not posts.is_empty():
		SceneryKit._prop_mm(container, post_mesh, PbrAssets.metal(Vector2(1.0, 1.0)),
			posts, [], "DesertMarkerPosts", stats, 520.0, false)
		SceneryKit._prop_mm_tinted(container, reflector_mesh,
			SceneryKit._emissive_mat(Color(1.0, 0.7, 0.2), 0.6), reflectors, colors,
			"DesertReflectors", stats, 480.0, false)


# ===========================================================================
# 2) 城市（city / skyline）
# ===========================================================================

static func _build_city(container: Node3D, path: TrackPath, theme: Dictionary,
		rng: RandomNumberGenerator, stats: Dictionary, venue: Dictionary, track_id: String) -> void:
	var night := SceneryKit.is_night_theme(theme)
	var landmark := track_id == "skyline"
	var accent := SceneryKit._color(String(theme.get("accent", "#ff4d8d")), Color(1.0, 0.3, 0.55))
	# --- 两侧密集楼群：两排楼夹道形成「城市峡谷」 ---
	var near_count := 120 if landmark else 132
	var back_count := 84 if landmark else 96
	# 近排楼挂真实 Poly Haven 立面贴片：纯程序窗格近看精度不够
	SceneryKit._build_real_city(container, path, rng, stats, near_count + back_count,
		accent, landmark, night, true, venue, near_count)
	# --- 路灯 + 消防栓 / 配电箱 / 井盖 ---
	SceneryKit._build_real_lamps(container, path, rng, stats, 62.0, path.half_width + 3.4, night)
	_scatter(container, path, rng, "hydrant_real", 10, 3.0, 6.5, 0.85, 1.05,
		"CityHydrants", 220.0, 2.8, 0, venue, 26.0, {}, 0.0, stats)
	_scatter(container, path, rng, "utility_box_real", 8, 3.2, 7.0, 1.0, 1.3,
		"CityUtilityBoxes", 240.0, 2.8, 0, venue, 26.0, {}, 0.0, stats)
	_scatter(container, path, rng, "manhole", 10, 2.6, 9.0, 0.95, 1.05,
		"CityManholes", 190.0, 2.4, 0, venue, 26.0, {}, 0.02, stats)
	# --- 路边霓虹招牌 / 广告牌 / 大屏 ---
	SceneryKit._build_neon_street(container, path, rng, stats, accent)
	SceneryKit._build_billboards(container, path, theme, rng, stats, 3,
		"SKYLINE  CIRCUIT" if landmark else "NEO CITY  /  APEX")
	SceneryKit._build_ad_screens(container, path, rng, stats, 2)
	# --- 跨路天桥（不是高楼，是真正的街道结构，压在路面上方 8.6m） ---
	var bridge_dists: Array[float] = []
	for frac in [0.19, 0.52, 0.78]:
		var d: float = path.total_length * float(frac)
		if not _near_venue(path, d, venue, 60.0):
			bridge_dists.append(d)
	for d in bridge_dists.slice(0, 2):
		SceneryKit._build_sky_bridge(container, path, rng, stats, accent, d)
	# --- 天际环城：城郊高架快速路 + 地标楼 ---
	if landmark:
		var hero := SceneryKit._hero_spot(path)
		SceneryKit._build_elevated_expressway(container, path, hero, rng, stats, accent)


# ===========================================================================
# 3) 山谷 / 雪山（alpine / glacier）
# ===========================================================================

static func _build_valley(container: Node3D, path: TrackPath, theme: Dictionary,
		rng: RandomNumberGenerator, stats: Dictionary, venue: Dictionary,
		ridge: FastNoiseLite, track_id: String) -> void:
	var hero := SceneryKit._hero_spot(path)
	var glacier := track_id == "glacier"
	var low_col := Color(0.52, 0.54, 0.58) if not glacier else Color(0.44, 0.52, 0.62)
	var high_col := Color(0.98, 0.99, 1.0) if not glacier else Color(0.88, 0.95, 1.0)
	var wall_style := {
		"kind": "mountain",
		"base_extra": 24.0,
		"height": 100.0 if not glacier else 112.0,
		"low_color": low_col,
		"high_color": high_col,
		"texture": "ice" if glacier else "snow",
		"tile": 26.0,
		"snow_line": 34.0 if glacier else 62.0,
		"snow_soft": 70.0,
		"snow_tint": Color(0.84, 0.92, 1.0) if glacier else Color(0.97, 0.99, 1.0),
		"rock_tint": Color(1.05, 1.08, 1.16) if glacier else Color(1.18, 1.13, 1.06),
		"fill_color": SceneryKit._color(String(theme.get("hemiSky", "#b9d6f2")),
			Color(0.72, 0.80, 0.9)).lightened(0.06),
		"fill_energy": 0.40 if glacier else 0.34,
		"haze_color": SceneryKit._color(String(theme.get("fogColor", "#b9c9d6")),
			Color(0.8, 0.85, 0.9)).darkened(0.18),
	}
	_build_valley_walls(container, path, rng, stats, venue, hero, 95.0, wall_style, ridge)

	if glacier:
		# --- 冰川湖道：山下松林 + 冰面 + 冰柱 + 雪堤 + 极地旗 ---
		var pines := "realtree_fir_lod" if RealAssetKit.has("realtree_fir_lod") else "realtree_pine"
		_scatter(container, path, rng, pines, 34, 4.0, 19.0, 6.0, 12.0,
			"GlacierPines", 620.0, 5.0, 0, venue, 26.0, hero, 0.0, stats)
		_scatter(container, path, rng, "realtree_pine", 28, 5.0, 20.0, 3.0, 6.0,
			"GlacierPineSmall", 540.0, 4.5, 0, venue, 26.0, hero, 0.0, stats)
		_scatter(container, path, rng, "boulder02", 26, 5.0, 20.0, 1.5, 5.0,
			"GlacierBoulders", 560.0, 4.5, 0, venue, 26.0, hero, 0.0, stats)
		_build_ice_sheets(container, path, rng, stats, venue)
		_build_ice_shards_near(container, path, rng, stats, venue)
		SceneryKit._build_snow_banks(container, path, rng, stats)
		SceneryKit._build_marker_flags(container, path, rng, stats, Color(0.3, 0.68, 1.0))
	else:
		# --- 雪山隘口：松林 + 岩石 + 雪堤 + 山间木屋 + 缆车 ---
		var pines := "realtree_pine" if RealAssetKit.has("realtree_pine") else "realtree_fir_lod"
		_scatter(container, path, rng, pines, 26, 4.0, 19.0, 5.0, 11.0,
			"AlpinePines", 640.0, 5.0, 0, venue, 26.0, hero, 0.0, stats)
		_scatter(container, path, rng, "realtree_fir_lod", 44, 5.0, 21.0, 8.0, 15.0,
			"AlpineFirs", 700.0, 5.0, 0, venue, 26.0, hero, 0.0, stats)
		_scatter(container, path, rng, "rock_face", 22, 4.0, 20.0, 2.0, 5.0,
			"AlpineRocks", 560.0, 4.5, 0, venue, 26.0, hero, 0.0, stats)
		_build_alpine_hut_near(container, path, rng, stats, venue)
		_build_cable_car_near(container, path, rng, stats, venue)
		SceneryKit._build_snow_banks(container, path, rng, stats)
		SceneryKit._build_marker_flags(container, path, rng, stats, Color(1.0, 0.42, 0.16))
	# 雪地碎石
	_scatter_gravel(container, path, rng, 160 if not glacier else 130, 2.0, 30.0, 0.3, 1.2,
		Color(0.72, 0.76, 0.84), Color(0.42, 0.48, 0.58), "ValleyGravel", venue, 24.0, stats)


## 两侧山壁：沿赛道扫出「山体」网格。
## 近处（24~90m）是带岩石/雪面贴图、能看清坡形的山脚；更远只剩低模剪影。
## 急弯处理：曲率限制的允许偏移 → 平滑过渡（缓变），再用高度 taper 收掉
## 过陡的薄片，避免出现横跨天空的大三角。
static func _build_valley_walls(container: Node3D, path: TrackPath,
		rng: RandomNumberGenerator, stats: Dictionary, venue: Dictionary,
		hero: Dictionary, hero_margin: float, style: Dictionary, ridge: FastNoiseLite) -> void:
	var kind := String(style.get("kind", "mountain"))
	var base_extra := float(style.get("base_extra", 24.0))
	var base_h := float(style.get("height", 85.0))
	var low_col: Color = style.get("low_color", Color(0.25, 0.3, 0.38))
	var high_col: Color = style.get("high_color", Color(0.95, 0.97, 1.0))
	var tex_kind := String(style.get("texture", "snow"))
	var profile_e: Array[float] = []
	var profile_h: Array[float] = []
	# 剖面 = 前坡 + 山脊 + 背坡，山体有体积（不是一张薄片），
	# 从赛道看是山坡，从对面赛道看是山的背面，不会出现「大翅膀」。
	if kind == "mountain":
		profile_e = [0.0, 5.0, 11.0, 18.0, 28.0, 42.0, 62.0, 88.0, 122.0,
			152.0, 188.0, 230.0]
		profile_h = [0.0, 0.03, 0.07, 0.12, 0.20, 0.32, 0.47, 0.68, 1.0,
			0.70, 0.36, 0.0]
	else:
		profile_e = [0.0, 8.0, 16.0, 24.0, 34.0, 48.0, 68.0, 92.0, 118.0,
			146.0, 186.0, 232.0]
		profile_h = [0.0, 0.04, 0.16, 0.24, 0.28, 0.46, 0.52, 0.76, 1.0,
			0.76, 0.42, 0.0]
	var profile_span := profile_e[profile_e.size() - 1]
	# 中心线网格哈希：山壁顶点要检查是否压到「别的赛段」的路面（回头弯/并行段）
	var grid_cell := 40.0
	var grid: Dictionary = {}
	for gi in range(path.samples.size()):
		var gsp: Vector3 = path.samples[gi]
		var gkey := Vector2i(floori(gsp.x / grid_cell), floori(gsp.z / grid_cell))
		if grid.has(gkey):
			(grid[gkey] as PackedInt32Array).append(gi)
		else:
			grid[gkey] = PackedInt32Array([gi])
	var foreign_dist := func(p: Vector3, own_dist: float) -> float:
		var best := 1e12
		var cx := floori(p.x / grid_cell)
		var cz := floori(p.z / grid_cell)
		for gx in range(cx - 1, cx + 2):
			for gz in range(cz - 1, cz + 2):
				var arr: PackedInt32Array = grid.get(Vector2i(gx, gz), PackedInt32Array())
				for jj in arr.size():
					var j: int = arr[jj]
					if absf(path.accumulated[j] - own_dist) < 60.0:
						continue
					# 只看 XZ 平面：山体悬在别的赛道正上方也算穿模，一并切掉
					var sq: Vector3 = path.samples[j]
					var dx := sq.x - p.x
					var dz := sq.z - p.z
					best = minf(best, dx * dx + dz * dz)
		return sqrt(best)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var sample_step := 4
	var m := path.samples.size()
	var half := path.half_width
	var any := false
	for side_sign: float in [-1.0, 1.0]:
		var prev_row: Array = []
		var prev_cols: Array = []
		var prev_normals: Array = []
		var smooth_scale := 0.6
		var smooth_taper := 1.0
		for i in range(0, m + sample_step, sample_step):
			var idx := i % m
			var dist := path.accumulated[idx]
			if _near_venue(path, dist, venue, 40.0) or _near_hero(path, hero, dist, hero_margin):
				prev_row = []
				smooth_scale = 0.6
				smooth_taper = 1.0
				continue
			var curv := absf(path.curvatures[idx])
			var max_off := 0.38 / maxf(curv, 0.0001)
			var allowed := clampf((max_off - base_extra) / profile_span, 0.0, 1.0)
			# 平滑：山壁在急弯附近缓缓收进来，而不是突然跳变/翻折
			smooth_scale = lerpf(smooth_scale, allowed, 0.28)
			var use_scale := minf(minf(smooth_scale, allowed), 1.0)
			var target_taper := clampf(allowed / 0.30, 0.0, 1.0)
			smooth_taper = lerpf(smooth_taper, target_taper, 0.30)
			if use_scale < 0.02 or smooth_taper < 0.02:
				prev_row = []
				continue
			var s: Vector3 = path.samples[idx]
			var side: Vector3 = path.sides[idx]
			var out := side * side_sign
			# 山脊高度：低频大起伏 + 中频小起伏（山形不呆板）
			var n := ridge.get_noise_2d(dist, side_sign * 37.0) * 0.5 + 0.5
			var n2 := ridge.get_noise_2d(dist * 4.3, side_sign * 13.0 + 9.0) * 0.5 + 0.5
			var n3 := ridge.get_noise_2d(dist * 11.0, side_sign * 71.0 + 3.0) * 0.5 + 0.5
			var h_scale := (0.50 + n * 0.75 + n2 * 0.30) * (0.45 + 0.55 * smooth_taper)
			var ridge_shift := (n3 - 0.5) * 0.30  # 脊线横向不齐，避免平顶长墙
			var row: Array = []
			var row_cols: Array = []
			var row_normals: Array = []
			for k in profile_e.size():
				var kt := float(k) / float(profile_e.size() - 1)
				var e: float = base_extra + profile_e[k] * use_scale * (1.0 + ridge_shift * kt)
				var h: float = profile_h[k] * base_h * h_scale * smooth_taper
				var p: Vector3 = s + out * (half + e)
				p.y = h
				# 顶点落到其他赛段路面附近时，把山体沉到地面（山在赛道处断成垭口）
				if k > 0 and h > 0.5:
					var fd: float = foreign_dist.call(p, dist)
					if fd < half + 4.0:
						h *= clampf((fd - half) / 6.0, 0.0, 1.0)
						p.y = h
				row.append(p)
				var t := profile_h[k]
				var c := low_col.lerp(high_col, smoothstep(0.16, 0.72, t))
				# 岩层横纹 + 高频色噪：低模也有“山”的层次
				var strata := ridge.get_noise_2d(dist * 2.9, h * 0.42)
				c = c * (0.98 + n2 * 0.22 + n3 * 0.12)
				c = c.lerp(low_col.darkened(0.16), clampf(1.0 - t * 3.2, 0.0, 0.22))
				c = c * (0.96 + strata * 0.10)
				row_cols.append(c)
				# 法线 = 剖面切线旋转 90°：前坡朝上偏路，背坡朝上偏外
				var kprev := maxi(k - 1, 0)
				var knext := mini(k + 1, profile_e.size() - 1)
				var d_e: float = profile_e[knext] * use_scale - profile_e[kprev] * use_scale
				var d_h: float = (profile_h[knext] - profile_h[kprev]) * base_h * h_scale * smooth_taper
				var nrm := (Vector3.UP * maxf(d_e, 0.01) - out * d_h).normalized()
				row_normals.append(nrm)
			if prev_row.size() == row.size():
				for k in profile_e.size() - 1:
					_emit_quad(st,
						prev_row[k] as Vector3, prev_row[k + 1] as Vector3,
						row[k] as Vector3, row[k + 1] as Vector3,
						prev_cols[k] as Color, prev_cols[k + 1] as Color,
						row_cols[k] as Color, row_cols[k + 1] as Color,
						prev_normals[k] as Vector3, prev_normals[k + 1] as Vector3,
						row_normals[k] as Vector3, row_normals[k + 1] as Vector3)
					any = true
			prev_row = row
			prev_cols = row_cols
			prev_normals = row_normals
	if not any:
		return
	var body := StaticBody3D.new()
	body.name = "ValleyWalls"
	var mi := MeshInstance3D.new()
	mi.name = "ValleyWallsMesh"
	mi.mesh = st.commit()
	mi.material_override = _wall_material(tex_kind, style)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	body.add_child(mi)
	# 山体加实心碰撞：车不能再穿过山壁
	var col := CollisionShape3D.new()
	col.name = "ValleyWallsCollision"
	col.shape = mi.mesh.create_trimesh_shape()
	body.add_child(col)
	container.add_child(body)
	stats["nodes"] = int(stats.get("nodes", 0)) + 1
	stats["meshes"] = int(stats.get("meshes", 0)) + 1


## 山壁材质：岩石 + 积雪两层真实 CC0 贴图做三平面混合。
## 低处是带岩层的裸岩，高处按坡向积雪，顶点色继续做宏观明暗；
## 这样远看是山、近看有真实石纹，而不再是一块光滑灰板。
static func _wall_material(kind: String, style: Dictionary = {}) -> ShaderMaterial:
	var rock_diff := "textures/coast_sand_01/coast_sand_01_diff.jpg"
	var rock_rough := "textures/coast_sand_01/coast_sand_01_rough.jpg"
	var snow_amount := 0.0
	match kind:
		"snow":
			rock_diff = "textures/dark_rock/dark_rock_diff.jpg"
			rock_rough = "textures/dark_rock/dark_rock_rough.jpg"
			snow_amount = 1.0
		"ice":
			rock_diff = "textures/dark_rock/dark_rock_diff.jpg"
			rock_rough = "textures/dark_rock/dark_rock_rough.jpg"
			snow_amount = 1.0
		_:
			snow_amount = float(style.get("snow", 0.0))
	var sh := Shader.new()
	sh.code = """shader_type spatial;
render_mode cull_disabled;

uniform sampler2D rock_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D rock_roughness : hint_roughness_r, filter_linear_mipmap, repeat_enable;
uniform sampler2D snow_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec3 rock_tint : source_color = vec3(1.0);
uniform vec3 snow_tint : source_color = vec3(1.0);
uniform float tile = 24.0;
uniform float snow_amount = 1.0;
uniform float snow_line = 70.0;
uniform float snow_soft = 55.0;
uniform float rough = 0.92;
uniform float rock_gain = 7.0;
uniform float snow_gain = 1.25;
uniform vec3 fill_color : source_color = vec3(0.62, 0.70, 0.80);
uniform float fill_energy = 0.36;
uniform vec3 haze_color : source_color = vec3(0.72, 0.78, 0.85);

varying vec3 v_world;
varying vec3 v_nrm;
varying vec3 v_col;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}
float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}
float fbm(vec2 p) {
	float s = 0.0;
	float a = 0.5;
	for (int i = 0; i < 3; i++) {
		s += vnoise(p) * a;
		p *= 2.07;
		a *= 0.5;
	}
	return s;
}
vec3 tri_weights(vec3 n) {
	vec3 b = pow(abs(n), vec3(6.0));
	return b / max(b.x + b.y + b.z, 0.0001);
}
vec3 tri_sample(sampler2D tex, vec3 p, vec3 w, float t) {
	return texture(tex, p.zy / t).rgb * w.x
		+ texture(tex, p.xz / t).rgb * w.y
		+ texture(tex, p.xy / t).rgb * w.z;
}

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_nrm = normalize(MODEL_NORMAL_MATRIX * NORMAL);
	v_col = COLOR.rgb;
}

void fragment() {
	vec3 n = normalize(v_nrm);
	if (!FRONT_FACING) {
		n = -n;
	}
	vec3 w = tri_weights(n);
	float macro = fbm(v_world.xz * 0.011 + v_world.y * 0.017);
	vec3 rock = tri_sample(rock_albedo, v_world, w, tile) * rock_gain;
	rock *= rock_tint * v_col * (0.76 + macro * 0.46);
	// 岩面近看细节：沙岩贴图本身对比低，叠一层中频斑驳 + 水平层理。
	float fine = fbm(v_world.xz * 0.070 + v_world.y * 0.090);
	rock *= 0.82 + 0.34 * fine;
	float bands = sin(v_world.y * 0.55 + macro * 3.2) * 0.5 + 0.5;
	rock *= 0.935 + 0.11 * bands;
	vec3 snow = tri_sample(snow_albedo, v_world, w, tile * 0.62) * snow_gain;
	snow *= snow_tint * (0.90 + macro * 0.16);
	float cover = smoothstep(snow_line + macro * 34.0,
		snow_line + snow_soft + macro * 34.0, v_world.y);
	cover *= (0.28 + 0.72 * smoothstep(0.22, 0.70, n.y)) * snow_amount;
	vec3 col = mix(rock, snow, clamp(cover, 0.0, 1.0));
	float rv = texture(rock_roughness, v_world.zy / tile).r * w.x
		+ texture(rock_roughness, v_world.xz / tile).r * w.y
		+ texture(rock_roughness, v_world.xy / tile).r * w.z;
	ALBEDO = col;
	ROUGHNESS = mix(clamp(rv, 0.55, 1.0), 0.70, cover);
	SPECULAR = 0.15;
	// 天空补光：背光/夜间山体只有环境光时会黑成纸片，
	// 用自发光补一层随法线朝向变化的散射，并让远景混入空气透视。
	float cam_dist = length(v_world - CAMERA_POSITION_WORLD);
	float aerial = smoothstep(320.0, 2400.0, cam_dist);
	float sky_bounce = clamp(n.y * 0.6 + 0.4, 0.0, 1.0);
	vec3 fill = fill_color * fill_energy * col * (0.50 + 0.50 * sky_bounce);
	fill = mix(fill, haze_color * 0.55, aerial * 0.55);
	EMISSION = fill;
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = sh
	mat.set_shader_parameter("rock_albedo", PbrAssets.tex(rock_diff))
	mat.set_shader_parameter("rock_roughness", PbrAssets.tex(rock_rough))
	mat.set_shader_parameter("snow_albedo", PbrAssets.tex("textures/snow_01/snow_01_diff.jpg"))
	mat.set_shader_parameter("tile", float(style.get("tile", 24.0)))
	mat.set_shader_parameter("snow_amount", snow_amount)
	mat.set_shader_parameter("snow_line", float(style.get("snow_line", 70.0)))
	mat.set_shader_parameter("snow_soft", float(style.get("snow_soft", 55.0)))
	var rock_gain := 7.0 if kind in ["snow", "ice"] else 1.9
	mat.set_shader_parameter("rock_gain", float(style.get("rock_gain", rock_gain)))
	mat.set_shader_parameter(
		"rock_tint",
		style.get("rock_tint", Color(1.0, 1.0, 1.0)))
	mat.set_shader_parameter(
		"snow_tint",
		style.get("snow_tint", Color(0.94, 0.97, 1.0)))
	mat.set_shader_parameter("rough", float(style.get("rough", 0.92)))
	mat.set_shader_parameter("fill_color", style.get("fill_color", Color(0.62, 0.70, 0.80)))
	mat.set_shader_parameter("fill_energy", float(style.get("fill_energy", 0.36)))
	mat.set_shader_parameter("haze_color",
		style.get("haze_color", Color(0.72, 0.78, 0.85)))
	return mat


## 山壁四边形（单面，cull_disabled）：法线按剖面切线计算，
## 所以无论从赛道侧还是从山背面看都是正确受光的山体。
static func _emit_quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3,
		ca: Color, cb: Color, cc: Color, cd: Color,
		na: Vector3, nb: Vector3, nc: Vector3, nd: Vector3) -> void:
	st.set_normal(na)
	st.set_color(ca)
	st.add_vertex(a)
	st.set_normal(nc)
	st.set_color(cc)
	st.add_vertex(c)
	st.set_normal(nb)
	st.set_color(cb)
	st.add_vertex(b)
	st.set_normal(nb)
	st.set_color(cb)
	st.add_vertex(b)
	st.set_normal(nc)
	st.set_color(cc)
	st.add_vertex(c)
	st.set_normal(nd)
	st.set_color(cd)
	st.add_vertex(d)


## 荒漠孤峰台地（buttes）：低模圆柱叠 3 层，一个 MultiMesh 画完。
## 这是 canyon / magma「两侧全是戈壁台地」的主力，且完全不会在急弯翻折。
static func _build_desert_buttes(container: Node3D, path: TrackPath,
		rng: RandomNumberGenerator, stats: Dictionary, venue: Dictionary, volcanic: bool) -> void:
	var palette: Array[Color] = []
	if volcanic:
		palette = [Color(0.22, 0.16, 0.16), Color(0.30, 0.20, 0.18),
			Color(0.16, 0.12, 0.13), Color(0.36, 0.22, 0.18)]
	else:
		palette = [Color(0.62, 0.36, 0.24), Color(0.74, 0.47, 0.30),
			Color(0.52, 0.30, 0.21), Color(0.68, 0.42, 0.28)]
	var xforms: Array[Transform3D] = []
	var colors: Array[Color] = []
	var half := path.half_width
	var dist := 26.0
	var guard := 0
	while dist < path.total_length and guard < 400:
		guard += 1
		if _near_venue(path, dist, venue, 46.0):
			dist += 40.0
			continue
		var f := path.frame_at(dist + rng.randf_range(-16.0, 16.0))
		if f.is_empty():
			dist += 62.0
			continue
		var side_sign := 1.0 if rng.randf() < 0.5 else -1.0
		var extra := rng.randf_range(26.0, 52.0)
		var base := _lat_pos(f, half, extra, side_sign)
		if not VenueKit.clear_of_track(path, base, 16.0):
			dist += 62.0
			continue
		# 孤丘登记为实体：后摆的散石/电杆/碎石带按它避让（基座半径 r0）
		var yaw := rng.randf() * TAU
		var col: Color = palette[rng.randi() % palette.size()]
		var r0 := rng.randf_range(9.0, 22.0)
		RealAssetKit.register_solid(base, r0)
		var h0 := rng.randf_range(6.0, 16.0)
		var r1 := r0 * rng.randf_range(0.62, 0.82)
		var h1 := rng.randf_range(5.0, 14.0)
		var r2 := r1 * rng.randf_range(0.55, 0.8)
		var h2 := rng.randf_range(3.0, 10.0)
		var b0 := Basis(Vector3.UP, yaw).scaled(Vector3(r0, h0, r0 * rng.randf_range(0.7, 1.0)))
		xforms.append(Transform3D(b0, base + Vector3(0.0, h0 * 0.5 - 0.4, 0.0)))
		colors.append(col)
		var b1 := Basis(Vector3.UP, yaw + rng.randf_range(-0.2, 0.2)).scaled(
			Vector3(r1, h1, r1 * rng.randf_range(0.7, 1.0)))
		xforms.append(Transform3D(b1, base + Vector3(0.0, h0 - 0.2 + h1 * 0.5, 0.0)))
		colors.append(col.darkened(rng.randf_range(0.02, 0.12)))
		var b2 := Basis(Vector3.UP, yaw + rng.randf_range(-0.3, 0.3)).scaled(
			Vector3(r2, h2, r2 * rng.randf_range(0.7, 1.0)))
		xforms.append(Transform3D(b2, base + Vector3(0.0, h0 + h1 - 0.1 + h2 * 0.5, 0.0)))
		colors.append(col.darkened(rng.randf_range(0.06, 0.2)))
		dist += rng.randf_range(120.0, 190.0)
	var mesh := CylinderMesh.new()
	mesh.top_radius = rng.randf_range(0.62, 0.85)
	mesh.bottom_radius = 1.0
	mesh.height = 1.0
	mesh.radial_segments = 10
	mesh.rings = 1
	var mat := _wall_material("dark_rock" if volcanic else "desert")
	mat.set_shader_parameter("rough", 0.97)
	SceneryKit._prop_mm(container, mesh, mat, xforms, colors, "DesertButtes", stats, 1500.0, false)


static func _build_ice_sheets(container: Node3D, path: TrackPath, rng: RandomNumberGenerator,
		stats: Dictionary, venue: Dictionary) -> void:
	var ice := SceneryKit._ice_material()
	var pool_mesh := CylinderMesh.new()
	pool_mesh.top_radius = 1.0
	pool_mesh.bottom_radius = 1.0
	pool_mesh.height = 0.08
	pool_mesh.radial_segments = 18
	pool_mesh.rings = 1
	var pools: Array[Transform3D] = []
	var half := path.half_width
	var dists := _even_distances(path, 300.0, 110.0)
	for d in dists:
		if _near_venue(path, d, venue, 40.0):
			continue
		var f := path.frame_at(d)
		if f.is_empty():
			continue
		var side_sign := -1.0
		var p := _lat_pos(f, half, rng.randf_range(8.0, 16.0), side_sign)
		p.y = 0.04
		var r := rng.randf_range(9.0, 16.0)
		pools.append(Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(
			Vector3(r, 1.0, r * rng.randf_range(0.6, 1.0))), p))
	if not pools.is_empty():
		SceneryKit._prop_mm(container, pool_mesh, ice, pools, [], "GlacierIceSheets", stats, 700.0, false)


static func _build_ice_shards_near(container: Node3D, path: TrackPath,
		rng: RandomNumberGenerator, stats: Dictionary, venue: Dictionary) -> void:
	var ice := SceneryKit._ice_material()
	var shard_mesh := CylinderMesh.new()
	shard_mesh.top_radius = 0.06
	shard_mesh.bottom_radius = 1.0
	shard_mesh.height = 1.0
	shard_mesh.radial_segments = 6
	shard_mesh.rings = 1
	var shards: Array[Transform3D] = []
	var half := path.half_width
	var attempts := 120
	while shards.size() < 40 and attempts > 0:
		attempts -= 1
		var dist := rng.randf() * path.total_length
		if _near_venue(path, dist, venue, 32.0):
			continue
		var f := path.frame_at(dist)
		if f.is_empty():
			continue
		var side_sign := 1.0 if rng.randf() < 0.5 else -1.0
		var p := _lat_pos(f, half, rng.randf_range(4.0, 20.0), side_sign)
		if not VenueKit.clear_of_track(path, p, 4.0):
			continue
		var h := rng.randf_range(2.5, 14.0)
		var w := rng.randf_range(0.6, 2.6)
		var b := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(w, h, w))
		b = b * Basis(Vector3.RIGHT, rng.randf_range(-0.12, 0.12))
		shards.append(Transform3D(b, p + Vector3(0.0, -0.1, 0.0)))
	SceneryKit._prop_mm(container, shard_mesh, ice, shards, [], "GlacierIceShards", stats, 900.0, false)


## 山间木屋：挑一段视野好的直道，放在陆侧 24m 的台地上。
static func _build_alpine_hut_near(container: Node3D, path: TrackPath,
		rng: RandomNumberGenerator, stats: Dictionary, venue: Dictionary) -> void:
	var chosen := -1.0
	for d in _even_distances(path, 240.0, 80.0):
		if _near_venue(path, d, venue, 70.0):
			continue
		chosen = d
		break
	if chosen < 0.0:
		return
	var f := path.frame_at(chosen)
	var center := _lat_pos(f, path.half_width, 14.0, -1.0)
	if not VenueKit.clear_of_track(path, center, 9.0):
		return
	var yaw := atan2((f["tangent"] as Vector3).x, (f["tangent"] as Vector3).z)
	var basis := Basis(Vector3.UP, yaw)
	var planks := PbrAssets.weathered_planks()
	# 木屋登记为实体：岩石/树散点靠这个躲开屋体
	RealAssetKit.register_solid(center, 4.2)
	var body := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(6.2, 2.9, 4.6)
	body.mesh = bm
	body.material_override = planks
	body.transform = Transform3D(basis, center + Vector3(0.0, 1.45, 0.0))
	body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	container.add_child(body)
	for sgn: float in [-1.0, 1.0]:
		var roof := MeshInstance3D.new()
		var rm := BoxMesh.new()
		rm.size = Vector3(3.9, 0.22, 5.4)
		roof.mesh = rm
		var roof_mat := PbrAssets.metal(Vector2(4.0, 2.0))
		roof_mat.albedo_color = Color(0.42, 0.2, 0.16)
		roof.material_override = roof_mat
		roof.transform = Transform3D(basis * Basis(Vector3.FORWARD, 0.62 * sgn),
			center + basis * Vector3(1.55 * sgn, 3.5, 0.0))
		container.add_child(roof)
		var snow := MeshInstance3D.new()
		var sm := BoxMesh.new()
		sm.size = Vector3(3.7, 0.1, 5.2)
		snow.mesh = sm
		snow.material_override = PbrAssets.snow_ground(Vector2(2.0, 2.0))
		snow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		snow.transform = Transform3D(basis * Basis(Vector3.FORWARD, 0.62 * sgn),
			center + basis * Vector3(1.55 * sgn, 3.66, 0.0))
		container.add_child(snow)
	var chimney := MeshInstance3D.new()
	var cm := BoxMesh.new()
	cm.size = Vector3(0.7, 2.2, 0.7)
	chimney.mesh = cm
	chimney.material_override = PbrAssets.concrete(Vector2(1.0, 1.0))
	chimney.transform = Transform3D(basis, center + basis * Vector3(-1.4, 4.6, -1.0))
	container.add_child(chimney)
	stats["nodes"] = int(stats.get("nodes", 0)) + 6


## 缆车塔：山壁脚下一排低模塔架 + 缆绳（贴在陆侧 30~40m）。
static func _build_cable_car_near(container: Node3D, path: TrackPath,
		rng: RandomNumberGenerator, stats: Dictionary, venue: Dictionary) -> void:
	var metal := PbrAssets.metal(Vector2(3.0, 5.0))
	var leg_mesh := BoxMesh.new()
	leg_mesh.size = Vector3(0.34, 1.0, 0.34)
	var brace_mesh := BoxMesh.new()
	brace_mesh.size = Vector3(3.4, 0.24, 0.24)
	var legs: Array[Transform3D] = []
	var braces: Array[Transform3D] = []
	var tops: Array[Vector3] = []
	var half := path.half_width
	for d in _even_distances(path, 96.0, 60.0):
		if _near_venue(path, d, venue, 40.0):
			continue
		var f := path.frame_at(d)
		if f.is_empty():
			continue
		var base := _lat_pos(f, half, 15.0, -1.0)
		var h := 15.0 + float(tops.size()) * 1.2
		var yaw := atan2((f["tangent"] as Vector3).x, (f["tangent"] as Vector3).z)
		var basis := Basis(Vector3.UP, yaw)
		var top := base + Vector3(0.0, h, 0.0)
		tops.append(top)
		for lx: float in [-1.5, 1.5]:
			for lz: float in [-1.1, 1.1]:
				var lp: Vector3 = base + basis * Vector3(lx, h * 0.5, lz)
				legs.append(Transform3D(basis.scaled(Vector3(1.0, h, 1.0)), lp))
		braces.append(Transform3D(basis.scaled(Vector3(3.2, 0.22, 0.22)), base + Vector3(0.0, h * 0.55, 0.0)))
		if tops.size() >= 6:
			break
	if legs.is_empty():
		return
	SceneryKit._prop_mm(container, leg_mesh, metal, legs, [], "CableCarLegs", stats, 1400.0, false)
	SceneryKit._prop_mm(container, brace_mesh, metal, braces, [], "CableCarBraces", stats, 1400.0, false)
	if tops.size() >= 2:
		var cable_mesh := CylinderMesh.new()
		cable_mesh.top_radius = 1.0
		cable_mesh.bottom_radius = 1.0
		cable_mesh.height = 1.0
		cable_mesh.radial_segments = 5
		cable_mesh.rings = 1
		var cables: Array[Transform3D] = []
		for k in tops.size() - 1:
			var a: Vector3 = tops[k]
			var b: Vector3 = tops[k + 1]
			for lane: float in [-1.4, 1.4]:
				var aa := a + Vector3(lane, 0.0, 0.0)
				var bb := b + Vector3(lane, 0.0, 0.0)
				var mid := (aa + bb) * 0.5 - Vector3(0.0, 2.0, 0.0)
				cables.append(SceneryKit._beam_xform(aa, mid, 0.05))
				cables.append(SceneryKit._beam_xform(mid, bb, 0.05))
		SceneryKit._prop_mm(container, cable_mesh, PbrAssets.metal(Vector2(1.0, 1.0)),
			cables, [], "CableCarLines", stats, 1500.0, false)


# ===========================================================================
# 3.5) 山路 / 雾岭（pass）—— .blend 场景全量落位
# ===========================================================================

## 场景单件（施工楼、水塔、路牌、输电塔……）：沿场景原公路的里程 + 横向偏移摆放。
## side_sign = +1 行进方向左侧（北），-1 右侧（内圈）。yaw_offset 用来让
## 路牌正面/路灯灯臂朝向路面。
static func _pass_unique(container: Node3D, path: TrackPath, stats: Dictionary,
		asset: String, dist: float, extra: float, side_sign: float,
		target_h: float, yaw_offset: float, node_name: String, sink: float = 0.0) -> void:
	if not RealAssetKit.has(asset):
		return
	var f := path.frame_at(dist)
	if f.is_empty():
		return
	var pos := _lat_pos(f, path.half_width, extra, side_sign)
	var tangent: Vector3 = f["tangent"]
	var yaw := atan2(tangent.x, tangent.z) + yaw_offset
	var s := RealAssetKit.scale_for_height(asset, target_h)
	var basis := Basis(Vector3.UP, yaw).scaled(Vector3.ONE * s)
	RealAssetKit.place_unique(container, asset,
		Transform3D(basis, pos - Vector3(0.0, sink, 0.0)), node_name, stats)


## 远景山体/盆地按世界坐标落位：尺寸就是场景原比例，不属于「路边 90m 细节」。
static func _pass_world_unique(container: Node3D, stats: Dictionary, asset: String,
		world: Vector3, target_h: float, yaw: float, node_name: String, sink: float = 0.0) -> void:
	if not RealAssetKit.has(asset):
		return
	var pos := Vector3(world.x, Terrain.height_at(world), world.z)
	var s := RealAssetKit.scale_for_height(asset, target_h)
	var basis := Basis(Vector3.UP, yaw).scaled(Vector3.ONE * s)
	RealAssetKit.place_unique(container, asset,
		Transform3D(basis, pos - Vector3(0.0, sink, 0.0)), node_name, stats)


## 雾岭山道：.blend 里所有可见物件都进游戏，1.4km 主直道按原场景排布。
## 右侧（内圈）：松树、施工段、料件、木板、水塔、路灯；
## 左侧（北）：弯道/减速路牌、三座输电塔、碎石堆、起终点山丘；
## 远景：三座真实山体 + 山谷盆地 + 高压线塔，后半程是松林山谷。
static func _build_pass(container: Node3D, path: TrackPath, theme: Dictionary,
		rng: RandomNumberGenerator, stats: Dictionary, venue: Dictionary,
		ridge: FastNoiseLite) -> void:
	# --- 原场景右侧：松树 + 施工段 ------------------------------------------
	_pass_unique(container, path, stats, "pass_pine_a", 320.0, 24.0, -1.0, 18.0, 0.6, "PassPineA_01")
	_pass_unique(container, path, stats, "pass_pine_a", 400.0, 27.0, -1.0, 17.0, 2.4, "PassPineA_02")
	_pass_unique(container, path, stats, "pass_pine_b", 412.0, 20.0, -1.0, 14.0, 4.1, "PassPineB_01")
	_pass_unique(container, path, stats, "pass_pine_b", 560.0, 18.0, -1.0, 12.0, 1.2, "PassPineB_02")
	_pass_unique(container, path, stats, "pass_pine_a", 1120.0, 22.0, -1.0, 16.0, 3.3, "PassPineA_03")

	# 大水泥构筑物 footprint 深 21m：近端面 = extra − 10.4，必须退到料件
	# （16–19m）之外，否则整片料件/木板全被吞进墙体（audit plank pen=61）
	_pass_unique(container, path, stats, "pass_construction_a", 460.0, 32.0, -1.0, 9.0, 0.10, "PassSiteBuilding")
	for i in 4:
		_pass_unique(container, path, stats, "pass_site_props", 448.0 + float(i) * 4.5,
			16.0 + float(i % 2) * 1.5, -1.0, 1.7, float(i) * 1.4, "PassSiteProp_%02d" % i)
	_pass_unique(container, path, stats, "pass_plank_a", 466.0, 13.5, -1.0, 0.30, 0.9, "PassPlank_01")
	_pass_unique(container, path, stats, "pass_plank_a", 472.0, 13.5, -1.0, 0.30, 2.2, "PassPlank_02")
	_pass_unique(container, path, stats, "pass_construction_b", 660.0, 22.0, -1.0, 7.0, 0.0, "PassSiteTower_01")
	_pass_unique(container, path, stats, "pass_construction_b", 690.0, 27.0, -1.0, 7.0, 0.8, "PassSiteTower_02")
	_pass_unique(container, path, stats, "pass_construction_b", 720.0, 34.0, -1.0, 7.0, 1.7, "PassSiteTower_03")

	_pass_unique(container, path, stats, "pass_tower", 1000.0, 30.0, -1.0, 28.0, 1.0, "PassWaterTower")

	var lamp_ds: Array[float] = [380.0, 650.0, 920.0, 1190.0]
	for i in lamp_ds.size():
		# side -1 → yaw +π/2，灯臂转向路面
		_pass_unique(container, path, stats, "pass_lamp", lamp_ds[i], 5.4, -1.0, 5.6,
			PI * 0.5, "PassLamp_%02d" % i)

	# --- 原场景左侧：路牌 + 输电塔 + 碎石堆 ----------------------------------
	# 牌面朝向迎面来车；两张 GLB 的有贴图面分别在局部 +Z / -X，各加 π 翻转。
	# 位置避开 264/352 两块同侧广告牌，避免牌面被遮住。
	_pass_unique(container, path, stats, "pass_sign_curve", 290.0, 5.2, 1.0, 3.2,
		PI, "PassSignCurve")
	_pass_unique(container, path, stats, "pass_sign_reduce", 325.0, 5.2, 1.0, 3.0,
		-PI * 0.5, "PassSignReduce")
	_pass_unique(container, path, stats, "pass_pole_tall_a", 40.0, 70.0, 1.0, 55.6, 1.0, "PassPylonA", 1.2)
	_pass_unique(container, path, stats, "pass_pole_tall_b", 150.0, 75.0, 1.0, 55.6, 2.0, "PassPylonB", 1.2)
	_pass_unique(container, path, stats, "pass_pole_tall_c", 700.0, 38.0, 1.0, 95.4, 0.6, "PassPylonC", 1.5)

	_pass_unique(container, path, stats, "pass_rock_a", 772.0, 26.0, 1.0, 2.8, 5.2, "PassRockA_01", 0.5)
	_pass_unique(container, path, stats, "pass_rock_a", 780.0, 16.0, 1.0, 4.2, 0.4, "PassRockA_02", 0.8)
	_pass_unique(container, path, stats, "pass_rock_a", 800.0, 22.0, 1.0, 3.6, 3.6, "PassRockA_03", 0.6)
	_pass_unique(container, path, stats, "pass_rock_b", 790.0, 15.0, 1.0, 2.6, 1.8, "PassRockB_01", 0.4)
	_pass_unique(container, path, stats, "pass_rock_b", 812.0, 19.0, 1.0, 2.2, 4.4, "PassRockB_02", 0.35)
	_pass_unique(container, path, stats, "pass_rock_c", 785.0, 12.5, 1.0, 1.6, 2.9, "PassRockC_01", 0.25)
	_pass_unique(container, path, stats, "pass_rock_c", 806.0, 14.0, 1.0, 1.3, 0.2, "PassRockC_02", 0.2)

	# 起终点两侧的山丘 + 起跑线前的大松（原始场景的起点景观）
	_pass_unique(container, path, stats, "pass_hill_c", 268.0, 55.0, -1.0, 22.0, 0.4, "PassHillC", 2.0)
	_pass_unique(container, path, stats, "pass_hill_e", 287.0, 70.0, -1.0, 21.0, 2.8, "PassHillE", 2.0)
	_pass_unique(container, path, stats, "pass_hill_a", -59.0, 90.0, 1.0, 24.0, 0.3, "PassHillA", 3.0)
	_pass_unique(container, path, stats, "pass_hill_b", -102.0, 120.0, 1.0, 26.0, 2.1, "PassHillB", 3.0)
	_pass_unique(container, path, stats, "pass_hill_d", -35.0, 70.0, 1.0, 38.0, 4.0, "PassHillD", 5.0)
	_pass_unique(container, path, stats, "pass_pine_a", -73.0, 12.0, 1.0, 16.0, 5.1, "PassPineStart")

	# --- 远景：原场景的山体 / 山谷盆地 / 高压线 ------------------------------
	_pass_world_unique(container, stats, "pass_mountain_a", Vector3(300.0, 0.0, 760.0), 100.0, 0.4, "PassMountainA_01", 8.0)
	_pass_world_unique(container, stats, "pass_mountain_a", Vector3(600.0, 0.0, -1200.0), 96.0, 2.1, "PassMountainA_02", 8.0)
	_pass_world_unique(container, stats, "pass_mountain_b", Vector3(1400.0, 0.0, 1100.0), 260.0, 0.9, "PassMountainB", 14.0)
	_pass_world_unique(container, stats, "pass_mountain_c", Vector3(-1600.0, 0.0, 700.0), 420.0, 5.2, "PassMountainC", 18.0)
	_pass_world_unique(container, stats, "pass_terrain_basin", Vector3(-250.0, 0.0, 520.0), 25.0, 1.2, "PassBasin", 6.0)
	_pass_world_unique(container, stats, "pass_powerline_a", Vector3(980.0, 0.0, 500.0), 120.0, PI * 0.5, "PassPowerlineA", 2.0)
	_pass_world_unique(container, stats, "pass_powerline_b", Vector3(700.0, 0.0, 500.0), 120.0, PI * 0.5, "PassPowerlineB", 2.0)
	# 环道外侧的远景山：补满后半程地平线，都落在雾程之内、又远离赛道
	_pass_world_unique(container, stats, "pass_mountain_b", Vector3(2350.0, 0.0, -450.0), 300.0, 2.4, "PassMountainEast", 40.0)
	_pass_world_unique(container, stats, "pass_mountain_c", Vector3(1900.0, 0.0, -1650.0), 400.0, 1.0, "PassMountainSE", 40.0)
	_pass_world_unique(container, stats, "pass_mountain_b", Vector3(-100.0, 0.0, -1500.0), 280.0, 4.2, "PassMountainSouth", 40.0)
	_pass_world_unique(container, stats, "pass_mountain_c", Vector3(-1600.0, 0.0, -1150.0), 380.0, 5.6, "PassMountainSW", 40.0)
	_pass_world_unique(container, stats, "pass_mountain_a", Vector3(900.0, 0.0, -1400.0), 120.0, 3.0, "PassMountainLow", 20.0)

	# --- 后半程松林山谷：通用散布 ------------------------------------------
	_scatter(container, path, rng, "pass_pine_b", 150, 8.5, 30.0, 8.0, 15.0,
		"PassPines", 620.0, 5.0, 0, venue, 26.0, {}, 0.0, stats)
	_scatter(container, path, rng, "pass_pine_a", 40, 9.0, 32.0, 11.0, 18.0,
		"PassPineGiants", 700.0, 5.5, 0, venue, 26.0, {}, 0.0, stats)
	_scatter(container, path, rng, "pass_shrub_a", 90, 5.0, 24.0, 1.6, 2.6,
		"PassShrubs", 280.0, 4.0, 0, venue, 26.0, {}, 0.0, stats)
	_scatter(container, path, rng, "pass_shrub_b", 64, 5.0, 26.0, 2.0, 3.4,
		"PassShrubsTall", 300.0, 4.0, 0, venue, 26.0, {}, 0.0, stats)
	_scatter(container, path, rng, "pass_grass_a", 90, 3.2, 14.0, 0.7, 1.1,
		"PassGrass", 180.0, 3.0, 0, venue, 26.0, {}, 0.0, stats)
	_scatter(container, path, rng, "pass_rock_a", 16, 7.0, 28.0, 1.8, 4.5,
		"PassRocksA", 420.0, 4.5, 0, venue, 26.0, {}, 0.0, stats, 0.18)
	_scatter(container, path, rng, "pass_rock_b", 14, 4.5, 22.0, 1.0, 2.2,
		"PassRocksB", 360.0, 4.0, 0, venue, 26.0, {}, 0.0, stats, 0.15)
	_scatter(container, path, rng, "pass_rock_c", 12, 3.8, 18.0, 0.6, 1.2,
		"PassRocksC", 320.0, 3.5, 0, venue, 26.0, {}, 0.0, stats, 0.15)
	_scatter(container, path, rng, "pass_hill_a", 6, 32.0, 80.0, 18.0, 26.0,
		"PassHillsA", 900.0, 6.0, 0, venue, 28.0, {}, 0.0, stats, 0.24)
	_scatter(container, path, rng, "pass_hill_b", 5, 36.0, 85.0, 20.0, 30.0,
		"PassHillsB", 1000.0, 6.0, 0, venue, 28.0, {}, 0.0, stats, 0.24)
	_scatter(container, path, rng, "pass_hill_d", 4, 40.0, 88.0, 30.0, 44.0,
		"PassHillsD", 1100.0, 6.0, 0, venue, 28.0, {}, 0.0, stats, 0.28)
	_scatter(container, path, rng, "pass_lamp", 8, 6.2, 8.6, 5.6, 5.6,
		"PassLamps", 500.0, 4.0, 0, venue, 30.0, {}, 0.0, stats)

	_scatter_gravel(container, path, rng, 120, 2.6, 26.0, 0.25, 0.9,
		Color(0.62, 0.60, 0.50), Color(0.42, 0.44, 0.36), "PassGravel", venue, 24.0, stats)


# ===========================================================================
# 4) 海边 / 港湾（coast / harbor）
# ===========================================================================

static func _build_coast(container: Node3D, path: TrackPath, theme: Dictionary,
		rng: RandomNumberGenerator, stats: Dictionary, venue: Dictionary, track_id: String) -> void:
	var harbor := track_id == "harbor"
	var hero := SceneryKit._hero_spot(path)
	var half := path.half_width
	# --- 棕榈：陆侧一排 + 海滩顶一排（海就在它们后面） ---
	var palms_land: Array[Transform3D] = []
	var palms_beach: Array[Transform3D] = []
	var palm_assets: Array[String] = []
	if RealAssetKit.has("tree_palm_tall"):
		palm_assets.append("tree_palm_tall")
	if RealAssetKit.has("tree_palm_bent"):
		palm_assets.append("tree_palm_bent")
	var attempts := 260
	while palms_land.size() < 34 and attempts > 0:
		attempts -= 1
		var dist := rng.randf() * path.total_length
		if _near_venue(path, dist, venue, 22.0):
			continue
		var f := path.frame_at(dist)
		if f.is_empty() or palm_assets.is_empty():
			continue
		var p := _lat_pos(f, half, rng.randf_range(3.0, 30.0), -1.0)
		if not VenueKit.clear_of_track(path, p, 6.0):
			continue
		var asset := palm_assets[palms_land.size() % palm_assets.size()]
		var s := RealAssetKit.scale_for_height(asset, rng.randf_range(5.0, 8.5))
		palms_land.append(Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3.ONE * s), p))
	attempts = 160
	while palms_beach.size() < 18 and attempts > 0:
		attempts -= 1
		var dist := rng.randf() * path.total_length
		if _near_venue(path, dist, venue, 22.0):
			continue
		var f := path.frame_at(dist)
		if f.is_empty() or palm_assets.is_empty():
			continue
		var extra := rng.randf_range(14.0, 21.0) if not harbor else rng.randf_range(12.0, 18.0)
		var p := _lat_pos(f, half, extra, 1.0)
		if p.y < -1.1:
			continue
		var asset := palm_assets[palms_beach.size() % palm_assets.size()]
		var s := RealAssetKit.scale_for_height(asset, rng.randf_range(4.0, 7.0))
		palms_beach.append(Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3.ONE * s), p))
	if palm_assets.is_empty():
		pass
	else:
		var split: Array = []
		for _a in palm_assets:
			split.append([])
		for i in palms_land.size():
			(split[i % palm_assets.size()] as Array).append(palms_land[i])
		for ai in palm_assets.size():
			var typed: Array[Transform3D] = []
			for xf in (split[ai] as Array):
				typed.append(xf as Transform3D)
			RealAssetKit.place_chunked(container, palm_assets[ai], typed,
				"CoastPalms", 900.0, RealAssetKit._quality_index() >= 3, stats)
	# 海滩棕榈（每侧各一种，避免重叠）
	var beach_split: Array = []
	for _a in palm_assets:
		beach_split.append([])
	for i in palms_beach.size():
		(beach_split[i % palm_assets.size()] as Array).append(palms_beach[i])
	for ai in palm_assets.size():
		var typed: Array[Transform3D] = []
		for xf in (beach_split[ai] as Array):
			typed.append(xf as Transform3D)
		RealAssetKit.place_chunked(container, palm_assets[ai], typed,
			"BeachPalms", 700.0, RealAssetKit._quality_index() >= 3, stats)

	# --- 岸线礁石：贴在海滩/浅水里的真实岩块 ---
	var rock := "boulder02" if RealAssetKit.has("boulder02") else "coast_rocks"
	_scatter(container, path, rng, rock, 42, 24.0, 48.0, 1.2, 4.5,
		"ShoreRocks", 480.0, 3.0, 1, venue, 26.0, {}, 0.0, stats)
	# --- 陆侧灌木/草（海边沙丘植被，少量） ---
	if RealAssetKit.has("shrub_coastal"):
		_scatter(container, path, rng, "shrub_coastal", 40, 3.0, 24.0, 0.6, 1.6,
			"CoastShrubs", 300.0, 3.4, -1, venue, 22.0, {}, 0.0, stats)
	# --- 陆侧草坡补一排松树（只给翡翠海岸：草坡上该有树） ---
	if not harbor and RealAssetKit.has("realtree_pine"):
		_scatter(container, path, rng, "realtree_pine", 30, 7.0, 26.0, 5.0, 10.0,
			"CoastInlandPines", 560.0, 5.0, -1, venue, 26.0, {}, 0.0, stats)
	_scatter_gravel(container, path, rng, 70, 9.0, 20.0, 0.18, 0.55,
		Color(0.82, 0.72, 0.52), Color(0.55, 0.45, 0.32), "CoastPebbles", venue, 22.0, stats, 1)

	if harbor:
		_build_harbor(container, path, rng, stats, venue, hero)
	else:
		_build_coast_beach_props(container, path, rng, stats, venue, hero)
		_build_coast_pier(container, path, rng, stats, venue, hero)
		_build_coast_ship(container, path, rng, stats, venue)
		_build_coast_lifeguard(container, path, rng, stats, venue)


static func _build_coast_beach_props(container: Node3D, path: TrackPath,
		rng: RandomNumberGenerator, stats: Dictionary, venue: Dictionary, hero: Dictionary) -> void:
	# 沙滩伞 + 沙滩巾：一小片度假海滩（贴在海滩上，不压路）
	var palette := [Color(1.0, 0.28, 0.3), Color(0.25, 0.65, 1.0), Color(1.0, 0.85, 0.3),
		Color(0.3, 0.85, 0.55), Color(1.0, 0.55, 0.85)]
	var pole_mesh := CylinderMesh.new()
	pole_mesh.top_radius = 0.045
	pole_mesh.bottom_radius = 0.06
	pole_mesh.height = 2.3
	pole_mesh.radial_segments = 6
	pole_mesh.rings = 1
	var canopy_mesh := CylinderMesh.new()
	canopy_mesh.top_radius = 0.05
	canopy_mesh.bottom_radius = 1.65
	canopy_mesh.height = 0.75
	canopy_mesh.radial_segments = 12
	canopy_mesh.rings = 1
	var towel_mesh := BoxMesh.new()
	towel_mesh.size = Vector3(1.9, 0.03, 0.9)
	var pole_x: Array[Transform3D] = []
	var canopy_x: Array[Transform3D] = []
	var canopy_c: Array[Color] = []
	var towel_x: Array[Transform3D] = []
	var towel_c: Array[Color] = []
	var half := path.half_width
	for d in _even_distances(path, 420.0, 150.0):
		if _near_venue(path, d, venue, 40.0):
			continue
		var f := path.frame_at(d + rng.randf_range(-30.0, 30.0))
		if f.is_empty():
			continue
		for k in 6:
			var extra := rng.randf_range(14.0, 24.0)
			var p := _lat_pos(f, half, extra, 1.0)
			p += (f["tangent"] as Vector3) * rng.randf_range(-13.0, 13.0)
			if p.y < -0.9:
				continue
			var b := Basis(Vector3.UP, rng.randf() * TAU)
			pole_x.append(Transform3D(b, p + Vector3(0.0, 1.15, 0.0)))
			canopy_x.append(Transform3D(b, p + Vector3(0.0, 2.35, 0.0)))
			canopy_c.append(palette[rng.randi() % palette.size()])
			var tp := p + Vector3(rng.randf_range(-2.4, 2.4), 0.03, rng.randf_range(-2.4, 2.4))
			towel_x.append(Transform3D(b, tp))
			towel_c.append(palette[rng.randi() % palette.size()])
	if not pole_x.is_empty():
		SceneryKit._prop_mm(container, pole_mesh, PbrAssets.metal(Vector2(1.0, 1.0)),
			pole_x, [], "BeachUmbrellaPoles", stats, 560.0, false)
		var canopy_mat := StandardMaterial3D.new()
		canopy_mat.roughness = 0.72
		canopy_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		SceneryKit._prop_mm_tinted(container, canopy_mesh, canopy_mat, canopy_x, canopy_c,
			"BeachUmbrellas", stats, 560.0, false)
		var towel_mat := StandardMaterial3D.new()
		towel_mat.roughness = 0.9
		SceneryKit._prop_mm_tinted(container, towel_mesh, towel_mat, towel_x, towel_c,
			"BeachTowels", stats, 420.0, false)


## 海岸木栈桥：从沙滩伸进海里（真实 CC0 pier_real 模块，贴着路一侧）。
static func _build_coast_pier(container: Node3D, path: TrackPath, rng: RandomNumberGenerator,
		stats: Dictionary, venue: Dictionary, hero: Dictionary) -> void:
	if not RealAssetKit.has("pier_real"):
		return
	var chosen := path.total_length * 0.66
	if not hero.is_empty():
		chosen = float(hero["hero_dist"]) + 120.0
	var f := path.frame_at(chosen)
	if f.is_empty() or _near_venue(path, chosen, venue, 60.0):
		return
	var half := path.half_width
	var side: Vector3 = f["side"]
	var tangent: Vector3 = f["tangent"]
	var yaw := atan2(tangent.x, tangent.z)
	var start_extra := 18.0
	var pieces := 5
	for k in pieces:
		var extra := start_extra + float(k) * 9.0
		var p: Vector3 = (f["pos"] as Vector3) + side * (half + extra)
		p.y = -0.15 - float(k) * 0.3
		var b := Basis(Vector3.UP, yaw + (PI * 0.5) + rng.randf_range(-0.06, 0.06)).scaled(
			Vector3(1.25, 1.1, 1.4))
		SceneryKit._real_unique(container, "pier_real", Transform3D(b, p),
			"CoastPier_%d" % k, stats, 900.0, false)
	# 栈桥尽头的观景木台
	var deck_pos: Vector3 = (f["pos"] as Vector3) + side * (half + start_extra + float(pieces) * 9.0 + 4.0)
	deck_pos.y = -1.35
	var deck_b := Basis(Vector3.UP, yaw).scaled(Vector3(2.4, 0.5, 1.4))
	SceneryKit._real_unique(container, "pier_real", Transform3D(deck_b, deck_pos),
		"CoastPierDeck", stats, 900.0, false)


static func _build_coast_ship(container: Node3D, path: TrackPath,
		rng: RandomNumberGenerator, stats: Dictionary, venue: Dictionary) -> void:
	if not RealAssetKit.has("ship_real"):
		return
	var chosen := path.total_length * 0.7
	var f := path.frame_at(chosen)
	if f.is_empty():
		return
	var half := path.half_width
	var pos: Vector3 = (f["pos"] as Vector3) + (f["side"] as Vector3) * (half + 62.0)
	pos.y = -1.0
	var yaw := atan2((f["tangent"] as Vector3).x, (f["tangent"] as Vector3).z) + 0.35
	var s := RealAssetKit.scale_for_height("ship_real", 19.0)
	SceneryKit._real_unique(container, "ship_real",
		Transform3D(Basis(Vector3.UP, yaw).scaled(Vector3.ONE * s), pos),
		"CoastSailShip", stats, 1400.0, false)
	# 近岸浮标
	var buoy_x: Array[Transform3D] = []
	for k in 6:
		var d := chosen + float(k - 3) * 26.0
		var bf := path.frame_at(d)
		if bf.is_empty():
			continue
		var bp: Vector3 = (bf["pos"] as Vector3) + (bf["side"] as Vector3) * (half + 44.0 + float(k) * 5.0)
		bp.y = -1.15
		var bs := RealAssetKit.scale_for_height("buoy_real", 2.2)
		buoy_x.append(Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3.ONE * bs), bp))
	if not buoy_x.is_empty():
		RealAssetKit.place_chunked(container, "buoy_real", buoy_x, "CoastBuoys", 900.0, false, stats)


## 海滩救生塔（低模木构件，真实木板贴图）。
static func _build_coast_lifeguard(container: Node3D, path: TrackPath,
		rng: RandomNumberGenerator, stats: Dictionary, venue: Dictionary) -> void:
	var planks := PbrAssets.planks()
	var paint := StandardMaterial3D.new()
	paint.albedo_color = Color(0.92, 0.92, 0.9)
	paint.roughness = 0.7
	var red := StandardMaterial3D.new()
	red.albedo_color = Color(0.85, 0.16, 0.14)
	red.roughness = 0.75
	var half := path.half_width
	var leg_mesh := BoxMesh.new()
	leg_mesh.size = Vector3(0.22, 2.7, 0.22)
	var built := 0
	for d in _even_distances(path, 620.0, 240.0):
		if built >= 2 or _near_venue(path, d, venue, 40.0):
			continue
		var f := path.frame_at(d)
		if f.is_empty():
			continue
		var p := _lat_pos(f, half, rng.randf_range(14.0, 20.0), 1.0)
		if p.y < -0.9:
			continue
		p.y = 0.0
		var yaw := atan2((f["tangent"] as Vector3).x, (f["tangent"] as Vector3).z)
		var basis := Basis(Vector3.UP, yaw)
		var legs: Array[Transform3D] = []
		for sx: float in [-1.15, 1.15]:
			for sz: float in [-0.95, 0.95]:
				legs.append(Transform3D(basis, p + basis * Vector3(sx, 1.35, sz)))
		SceneryKit._prop_mm(container, leg_mesh, planks, legs, [], "LifeguardLegs", stats, 620.0, false)
		var deck := MeshInstance3D.new()
		var dm := BoxMesh.new()
		dm.size = Vector3(3.1, 0.18, 2.7)
		deck.mesh = dm
		deck.material_override = planks
		deck.transform = Transform3D(basis, p + basis * Vector3(0.0, 2.72, 0.0))
		container.add_child(deck)
		var cabin := MeshInstance3D.new()
		var cm := BoxMesh.new()
		cm.size = Vector3(2.9, 1.9, 2.4)
		cabin.mesh = cm
		cabin.material_override = paint
		cabin.transform = Transform3D(basis, p + basis * Vector3(0.0, 3.75, 0.0))
		container.add_child(cabin)
		var roof := MeshInstance3D.new()
		var rm := BoxMesh.new()
		rm.size = Vector3(3.4, 0.16, 2.9)
		roof.mesh = rm
		roof.material_override = red
		roof.transform = Transform3D(basis, p + basis * Vector3(0.0, 4.78, 0.0))
		container.add_child(roof)
		built += 1


## 港湾：货柜堆场 / 龙门吊 / 仓库 / 帆船 / 系缆桩，全部贴着赛道两侧。
static func _build_harbor(container: Node3D, path: TrackPath, rng: RandomNumberGenerator,
		stats: Dictionary, venue: Dictionary, hero: Dictionary) -> void:
	var half := path.half_width
	# --- 货柜堆场（陆侧 5~42m）：三排货柜，颜色按实例染色 ---
	# 尺寸 (2.5, 2.6, 6.1)：局部 Z 沿路 —— 长边顺路向首尾相接成排，
	# 之前 X/Z 颠倒导致 6.1m 横在路向上、排间距 4.2m 全排互插
	var box := BoxMesh.new()
	box.size = Vector3(2.5, 2.6, 6.1)
	var mat := PbrAssets.container_metal(Vector2(1.0, 1.0))
	mat.roughness = 0.68
	mat.metallic = 0.12
	var palette := [
		Color(0.95, 0.32, 0.28), Color(0.28, 0.55, 0.95), Color(0.35, 0.78, 0.45),
		Color(0.95, 0.78, 0.28), Color(0.75, 0.78, 0.8), Color(0.85, 0.45, 0.2),
		Color(0.45, 0.35, 0.65),
	]
	var xforms: Array[Transform3D] = []
	var colors: Array[Color] = []
	var dist := 40.0
	while dist < path.total_length:
		if _near_venue(path, dist, venue, 40.0):
			dist += 32.0
			continue
		var f := path.frame_at(dist)
		if not f.is_empty():
			var yaw := atan2((f["tangent"] as Vector3).x, (f["tangent"] as Vector3).z)
			var basis := Basis(Vector3.UP, yaw)
			for row in 3:
				var extra := 6.0 + float(row) * 4.2
				var p := _lat_pos(f, half, extra, -1.0)
				if not VenueKit.clear_of_track(path, p, 3.0):
					continue
				var stack := rng.randi_range(1, 3 if row < 2 else 2)
				var col: Color = palette[rng.randi() % palette.size()]
				for lvl in stack:
					var lp := p + Vector3(0.0, 1.32 + float(lvl) * 2.62, 0.0)
					xforms.append(Transform3D(basis, lp))
					colors.append(col.darkened(rng.randf_range(0.0, 0.22)))
				# 堆位登记为实体：VenueKit 广告牌/裁判位、油桶散点按它避让
				RealAssetKit.register_solid(p, 3.3)
		dist += 6.2
	if not xforms.is_empty():
		# 一个 MultiMesh + 逐实例顶点色（albedo 贴图 × 实例色），只有 1 个 draw call
		var cmat := (mat as StandardMaterial3D).duplicate() as StandardMaterial3D
		cmat.vertex_color_use_as_albedo = true
		SceneryKit._prop_mm(container, box, cmat, xforms, colors, "HarborContainers",
			stats, 900.0, true)
	# --- 龙门吊（海侧岸线，2 台，低模钢结构） ---
	_build_harbor_cranes(container, path, rng, stats, venue)
	# --- 仓库 / 厂房（陆侧 30~60m） ---
	_build_harbor_warehouses(container, path, rng, stats, venue)
	# --- 码头系缆桩 + 油桶 ---
	var bollard_mesh := CylinderMesh.new()
	bollard_mesh.top_radius = 0.26
	bollard_mesh.bottom_radius = 0.3
	bollard_mesh.height = 0.95
	bollard_mesh.radial_segments = 8
	bollard_mesh.rings = 1
	var bollards: Array[Transform3D] = []
	for d in _even_distances(path, 46.0, 20.0):
		if _near_venue(path, d, venue, 30.0):
			continue
		var f := path.frame_at(d)
		if f.is_empty():
			continue
		var p := _lat_pos(f, half, 18.0, 1.0)
		bollards.append(Transform3D(Basis(), p + Vector3(0.0, 0.48, 0.0)))
	if not bollards.is_empty():
		SceneryKit._prop_mm(container, bollard_mesh, PbrAssets.metal(Vector2(1.0, 1.0)),
			bollards, [], "HarborBollards", stats, 420.0, false)
	_scatter(container, path, rng, "barrel_real", 12, 3.5, 22.0, 0.9, 1.05,
		"HarborBarrels", 320.0, 3.0, 0, venue, 26.0, {}, 0.0, stats)
	_scatter(container, path, rng, "industrial_pipes", 4, 8.0, 30.0, 1.4, 2.0,
		"HarborPipes", 480.0, 5.0, 0, venue, 26.0, {}, 0.0, stats)
	# --- 停泊货轮（海侧 60~80m 水面） ---
	if RealAssetKit.has("ship_real"):
		var f := path.frame_at(path.total_length * 0.6)
		if not f.is_empty():
			var pos: Vector3 = (f["pos"] as Vector3) + (f["side"] as Vector3) * (half + 66.0)
			pos.y = -1.3
			var yaw := atan2((f["tangent"] as Vector3).x, (f["tangent"] as Vector3).z) + 0.2
			var s := RealAssetKit.scale_for_height("ship_real", 17.0)
			SceneryKit._real_unique(container, "ship_real",
				Transform3D(Basis(Vector3.UP, yaw).scaled(Vector3.ONE * s), pos),
				"HarborCargoShip", stats, 1400.0, false)
	# --- 码头灯（黄昏暖光） ---
	SceneryKit._build_real_lamps(container, path, rng, stats, 88.0, half + 4.2, true)


static func _build_harbor_cranes(container: Node3D, path: TrackPath,
		rng: RandomNumberGenerator, stats: Dictionary, venue: Dictionary) -> void:
	var half := path.half_width
	var metal := PbrAssets.metal(Vector2(5.0, 6.0))
	var leg_mesh := BoxMesh.new()
	leg_mesh.size = Vector3(1.15, 1.0, 1.15)
	var beam_mesh := BoxMesh.new()
	beam_mesh.size = Vector3(1.0, 1.0, 1.0)
	var accent_mat := SceneryKit._emissive_mat(Color(1.0, 0.22, 0.14), 1.6)
	var legs: Array[Transform3D] = []
	var beams: Array[Transform3D] = []
	var warn: Array[Transform3D] = []
	var placed := 0
	for d in _even_distances(path, 560.0, 180.0):
		if placed >= 2 or _near_venue(path, d, venue, 50.0):
			continue
		var f := path.frame_at(d)
		if f.is_empty():
			continue
		var side: Vector3 = f["side"]
		var yaw := atan2((f["tangent"] as Vector3).x, (f["tangent"] as Vector3).z)
		var basis := Basis(Vector3.UP, yaw)
		var base: Vector3 = (f["pos"] as Vector3) + side * (half + 40.0)
		base.y = 0.0
		for lx: float in [-5.0, 5.0]:
			for lz: float in [-8.0, 8.0]:
				var lp: Vector3 = base + basis * Vector3(lx, 10.5, lz)
				legs.append(Transform3D(basis.scaled(Vector3(1.0, 21.0, 1.0)), lp))
		beams.append(Transform3D(basis.scaled(Vector3(12.0, 1.2, 2.0)), base + Vector3(0.0, 21.0, 0.0)))
		beams.append(Transform3D(basis.scaled(Vector3(26.0, 0.9, 1.6)),
			base + basis * Vector3(14.0, 21.5, 0.0)))
		beams.append(Transform3D(basis.scaled(Vector3(3.4, 1.5, 3.4)),
			base + basis * Vector3(9.0, 20.6, 0.0)))
		warn.append(Transform3D(basis.scaled(Vector3(12.2, 0.26, 2.1)),
			base + Vector3(0.0, 21.75, 0.0)))
		placed += 1
	if legs.is_empty():
		return
	SceneryKit._prop_mm(container, leg_mesh, metal, legs, [], "GantryLegs", stats, 1200.0, true)
	SceneryKit._prop_mm(container, beam_mesh, metal, beams, [], "GantryBeams", stats, 1200.0, true)
	SceneryKit._prop_mm(container, beam_mesh, accent_mat, warn, [], "GantryWarn", stats, 1100.0, false)


static func _build_harbor_warehouses(container: Node3D, path: TrackPath,
		rng: RandomNumberGenerator, stats: Dictionary, venue: Dictionary) -> void:
	var body_mat := PbrAssets.corrugated()
	var roof_mat := PbrAssets.metal(Vector2(4.0, 3.0))
	var half := path.half_width
	var placed := 0
	for d in _even_distances(path, 340.0, 140.0):
		if placed >= 3 or _near_venue(path, d, venue, 50.0):
			continue
		var f := path.frame_at(d)
		if f.is_empty():
			continue
		var base := _lat_pos(f, half, rng.randf_range(30.0, 44.0), -1.0)
		if not VenueKit.clear_of_track(path, base, 14.0):
			continue
		var yaw := atan2((f["tangent"] as Vector3).x, (f["tangent"] as Vector3).z)
		var basis := Basis(Vector3.UP, yaw)
		var w := rng.randf_range(26.0, 36.0)
		var h := rng.randf_range(10.0, 15.0)
		var dp := rng.randf_range(16.0, 22.0)
		var body := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(w, h, dp)
		body.mesh = bm
		body.material_override = body_mat
		body.transform = Transform3D(basis, base + Vector3(0.0, h * 0.5, 0.0))
		body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		container.add_child(body)
		var roof := MeshInstance3D.new()
		var rm := BoxMesh.new()
		rm.size = Vector3(w + 1.0, 0.8, dp + 1.0)
		roof.mesh = rm
		roof.material_override = roof_mat
		roof.transform = Transform3D(basis, base + Vector3(0.0, h + 0.4, 0.0))
		container.add_child(roof)
		# --- 仓库立面细节：装卸门 / 高窗带 / 屋顶通风机 ---
		# local -X 朝向赛道（side = -X 方向），门窗都摆在这一面。
		var door_mat := PbrAssets.corrugated()
		door_mat.albedo_color = Color(0.40, 0.43, 0.45)
		door_mat.roughness = 0.66
		var door_count := 2 if w < 31.0 else 3
		for di in door_count:
			var dz := (float(di) - float(door_count - 1) * 0.5) * (dp * 0.52)
			var dm := MeshInstance3D.new()
			var dmesh := BoxMesh.new()
			dmesh.size = Vector3(0.16, 4.2, 4.0)
			dm.mesh = dmesh
			dm.material_override = door_mat
			dm.transform = Transform3D(basis,
				base + basis * Vector3(-w * 0.5 - 0.09, 2.1, dz))
			container.add_child(dm)
			var lintel := MeshInstance3D.new()
			var lmesh := BoxMesh.new()
			lmesh.size = Vector3(0.26, 0.28, 4.6)
			lintel.mesh = lmesh
			lintel.material_override = roof_mat
			lintel.transform = Transform3D(basis,
				base + basis * Vector3(-w * 0.5 - 0.14, 4.35, dz))
			container.add_child(lintel)
			stats["nodes"] = int(stats.get("nodes", 0)) + 2
		var window_mat := StandardMaterial3D.new()
		window_mat.albedo_color = Color(0.16, 0.21, 0.25)
		window_mat.metallic = 0.35
		window_mat.roughness = 0.14
		var win := MeshInstance3D.new()
		var wmesh := BoxMesh.new()
		wmesh.size = Vector3(0.12, 1.15, dp * 0.82)
		win.mesh = wmesh
		win.material_override = window_mat
		win.transform = Transform3D(basis, base + basis * Vector3(-w * 0.5 - 0.07, h - 2.1, 0.0))
		container.add_child(win)
		var vent_mat := PbrAssets.metal(Vector2(2.0, 2.0))
		vent_mat.albedo_color = Color(0.62, 0.65, 0.66)
		for vi in 3:
			var vent := MeshInstance3D.new()
			var vmesh := BoxMesh.new()
			vmesh.size = Vector3(1.4, 0.9, 1.4)
			vent.mesh = vmesh
			vent.material_override = vent_mat
			var vz := (float(vi) - 1.0) * (dp * 0.30)
			vent.transform = Transform3D(basis,
				base + basis * Vector3(w * 0.18, h + 1.25, vz))
			container.add_child(vent)
			stats["nodes"] = int(stats.get("nodes", 0)) + 1
		stats["nodes"] = int(stats.get("nodes", 0)) + 1
		placed += 1


# ===========================================================================
# 远景：低模雾化剪影山环
# ===========================================================================

static func _build_far_ring(container: Node3D, path: TrackPath, theme: Dictionary,
		family: String, rng: RandomNumberGenerator, stats: Dictionary, ridge: FastNoiseLite) -> void:
	if family == "city" and SceneryKit.is_night_theme(theme):
		return  # 夜景城市不需要远山，天空本身就是剪影
	var bounds := _bounds(path)
	var center: Vector2 = bounds["center"]
	var half_diag: float = (bounds["size"] as Vector2).length() * 0.5
	# 与环境雾同色系：即使没被雾盖住也已经是「雾化剪影」的颜色
	var fog := SceneryKit._color(String(theme.get("fogColor", "#c8e4ea")),
		Color(0.8, 0.86, 0.9)).darkened(0.34)
	var haze := SceneryKit._color(String(theme.get("fogColor", "#c8e4ea")),
		Color(0.8, 0.86, 0.9)).lightened(0.06)
	# 远景拆成「近层岩山 + 中景岛群 + 远层雾脊」三层：
	# 近层轮廓最实、颜色最暗，远层抬高并几乎融进雾色，形成空气透视的纵深。
	match family:
		"valley":
			_build_far_ridge(container, center, {
				"name": "FarRidgeAlpineNear",
				"radius": half_diag + 320.0, "height": 160.0,
				"color": Color(0.46, 0.52, 0.62), "haze": haze, "haze_strength": 0.55,
				"kind": "alpine", "snow": 0.95, "snow_line": 110.0, "seed": 11.0}, ridge, stats)
			_build_far_islands(container, center, half_diag, {
				"name": "FarIslandsAlpine",
				"count": 10, "radius": half_diag + 1050.0, "spread": 320.0,
				"height": 250.0, "width": 520.0, "flat": false,
				"color": Color(0.50, 0.57, 0.68), "haze": haze, "haze_strength": 0.80,
				"kind": "alpine", "snow": 0.85, "snow_line": 185.0, "seed": 27.0}, rng, stats, ridge)
			_build_far_ridge(container, center, {
				"name": "FarRidgeAlpineFar",
				"radius": half_diag + 1950.0, "height": 320.0,
				"color": Color(0.56, 0.62, 0.72), "haze": haze, "haze_strength": 1.05,
				"kind": "alpine", "snow": 0.90, "snow_line": 175.0, "seed": 41.0}, ridge, stats)
		"desert":
			_build_far_islands(container, center, half_diag, {
				"name": "FarIslandsMesa",
				"count": 16, "radius": half_diag + 620.0, "spread": 380.0,
				"height": 80.0, "width": 360.0, "flat": true,
				"color": fog.darkened(0.02), "haze": haze, "haze_strength": 0.55,
				"kind": "mesa", "snow": 0.0, "seed": 7.0}, rng, stats, ridge)
			_build_far_ridge(container, center, {
				"name": "FarRidgeMesaNear",
				"radius": half_diag + 420.0, "height": 62.0,
				"color": fog.darkened(0.06), "haze": haze, "haze_strength": 0.40,
				"kind": "mesa", "snow": 0.0, "seed": 29.0}, ridge, stats)
			_build_far_ridge(container, center, {
				"name": "FarRidgeMesaMid",
				"radius": half_diag + 1150.0, "height": 150.0,
				"color": fog.lightened(0.10), "haze": haze, "haze_strength": 0.85,
				"kind": "mesa", "snow": 0.0, "seed": 19.0}, ridge, stats)
			_build_far_ridge(container, center, {
				"name": "FarRidgeMesaFar",
				"radius": half_diag + 2050.0, "height": 280.0,
				"color": fog.lightened(0.20), "haze": haze, "haze_strength": 1.10,
				"kind": "mesa", "snow": 0.0, "seed": 47.0}, ridge, stats)
		"coast":
			# 海岛先按雾色预混一部分：600m 处雾函数几乎为 0，不预混就是一块
			# 死绿纸片；预混后才有一层层退进海雾的纵深。
			# 海岸不再加「环形山墙」：连续山脊在海面上会变成一条横贯画面的
			# 平直色带，只保留两圈独立海岛做地平线轮廓。
			_build_far_islands(container, center, half_diag, {
				"name": "FarIslandsCoastNear",
				"count": 12, "radius": half_diag + 620.0, "spread": 380.0,
				"height": 62.0, "width": 520.0, "flat": false,
				"color": Color(0.24, 0.36, 0.27).lerp(haze, 0.30),
				"haze": haze, "haze_strength": 0.80,
				"kind": "island", "snow": 0.0, "seed": 5.0}, rng, stats, ridge)
			_build_far_islands(container, center, half_diag, {
				"name": "FarIslandsCoastFar",
				"count": 10, "radius": half_diag + 1450.0, "spread": 500.0,
				"height": 110.0, "width": 820.0, "flat": false,
				"color": Color(0.28, 0.42, 0.33).lerp(haze, 0.50),
				"haze": haze, "haze_strength": 1.05,
				"kind": "island", "snow": 0.0, "seed": 13.0}, rng, stats, ridge)
		_:
			_build_far_ridge(container, center, {
				"name": "FarRidgeRockFar",
				"radius": half_diag + 900.0, "height": 120.0,
				"color": fog.lightened(0.10), "haze": haze, "haze_strength": 0.85,
				"kind": "rock", "snow": 0.0, "seed": 9.0}, ridge, stats)
			_build_far_ridge(container, center, {
				"name": "FarRidgeRockNear",
				"radius": half_diag + 420.0, "height": 72.0,
				"color": fog.darkened(0.05), "haze": haze, "haze_strength": 0.40,
				"kind": "rock", "snow": 0.0, "seed": 23.0}, ridge, stats)
			_build_far_ridge(container, center, {
				"name": "FarRidgeRockOuter",
				"radius": half_diag + 1750.0, "height": 270.0,
				"color": fog.lightened(0.16), "haze": haze, "haze_strength": 1.10,
				"kind": "rock", "snow": 0.0, "seed": 43.0}, ridge, stats)


## 连续的远山山脊（雪山/兜底）： subdivision 随画质档走——低档省面数，
## 超高档脊线更密，噪声细节不被粗采样吃掉，交给距离雾淡出。
static func _build_far_ridge(container: Node3D, center: Vector2, ring: Dictionary,
		ridge: FastNoiseLite, stats: Dictionary) -> void:
	var radius := float(ring["radius"])
	var base_h := float(ring["height"])
	var col: Color = ring["color"]
	var seed_off := float(ring["seed"])
	var segs: int = [128, 160, 288, 400][clampi(RealAssetKit._quality_index(), 0, 3)]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var prev_top := Vector3.ZERO
	var prev_base := Vector3.ZERO
	var first := true
	for i in segs + 1:
		var a := TAU * float(i % segs) / float(segs)
		var n := ridge.get_noise_2d(float(i) * 2.1 + seed_off * 9.0, seed_off) * 0.5 + 0.5
		var n2 := ridge.get_noise_2d(float(i) * 7.7 + seed_off, 50.0) * 0.5 + 0.5
		var n3 := ridge.get_noise_2d(float(i) * 19.0 + seed_off, 130.0) * 0.5 + 0.5
		# 山脊噪声取「尖峰」形态：1-|2n-1| 让脊线出现独立山峰与垭口，
		# 不再是圆滚滚的一条波浪线。
		var r1 := 1.0 - absf(n * 2.0 - 1.0)
		var r2 := 1.0 - absf(n2 * 2.0 - 1.0)
		var h := base_h * (0.26 + n * 0.38 + r1 * 0.30 + n3 * 0.16 + r2 * 0.14)
		var dir := Vector3(cos(a), 0.0, sin(a))
		var top := Vector3(center.x, h, center.y) + dir * radius
		var base := Vector3(center.x, -80.0, center.y) + dir * radius
		if not first:
			_st_silhouette_tri(st, col, prev_top, prev_base, base)
			_st_silhouette_tri(st, col, prev_top, base, top)
		prev_top = top
		prev_base = base
		first = false
	_finalize_silhouette(container, st, col, String(ring.get("name", "FarRidge")), stats, ring)


## 独立的远岛/远台地剪影：每个是一块 8 面体的低模「山包」，
## 相互之间断开，不会再形成一条连续灰墙。
static func _build_far_islands(container: Node3D, center: Vector2, half_diag: float,
		cfg: Dictionary, rng: RandomNumberGenerator, stats: Dictionary,
		ridge: FastNoiseLite) -> void:
	var count := int(cfg["count"])
	var radius := float(cfg["radius"])
	var spread := float(cfg["spread"])
	var base_h := float(cfg["height"])
	var width := float(cfg["width"])
	var flat := bool(cfg.get("flat", false))
	var col: Color = cfg["color"]
	var seed_off := float(cfg["seed"])
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for k in count:
		var angle := TAU * (float(k) + rng.randf_range(0.15, 0.85)) / float(count)
		if rng.randf() < 0.18:
			continue
		var r := radius + rng.randf_range(-spread, spread)
		var dir := Vector3(cos(angle), 0.0, sin(angle))
		var tang := Vector3(-dir.z, 0.0, dir.x)
		var mid := Vector3(center.x, 0.0, center.y) + dir * r
		var w := width * rng.randf_range(0.55, 1.5)
		var h := base_h * rng.randf_range(0.45, 1.45)
		var skirt := -80.0
		var b0 := mid - tang * (w * 0.5) + Vector3(0.0, skirt, 0.0)
		var b1 := mid + tang * (w * 0.5) + Vector3(0.0, skirt, 0.0)
		var b2 := mid + dir * (w * 0.45) + Vector3(0.0, skirt, 0.0)
		var b3 := mid - dir * (w * 0.45) + Vector3(0.0, skirt, 0.0)
		var t0: Vector3
		var t1: Vector3
		var t2: Vector3
		var t3: Vector3
		if flat:
			# 平顶台地：顶部内收，侧面近垂直
			var top_y := mid + Vector3(0.0, h, 0.0)
			t0 = top_y - tang * (w * 0.38) - dir * (w * 0.14)
			t1 = top_y + tang * (w * 0.38) - dir * (w * 0.14)
			t2 = top_y + tang * (w * 0.38) + dir * (w * 0.14)
			t3 = top_y - tang * (w * 0.38) + dir * (w * 0.14)
			_st_silhouette_quad(st, col, t0, t1, b1, b0)
			_st_silhouette_quad(st, col, t1, t2, b2, b1)
			_st_silhouette_quad(st, col, t2, t3, b3, b2)
			_st_silhouette_quad(st, col, t3, t0, b0, b3)
		else:
			var detail_cols := 0
			var qi := RealAssetKit._quality_index()
			if qi >= 2:
				detail_cols = 8 if qi == 2 else 12
			if detail_cols > 0:
				# 高/超高：一条多峰山脊取代单顶帐篷——轮廓像真实山群，
				# 前后两片坡面保留体积，侧面看不再是纸片。面数依旧只有几十。
				var depth := w * 0.30
				var pf := Vector3.ZERO
				var pb := Vector3.ZERO
				var pt := Vector3.ZERO
				for j in detail_cols + 1:
					var t := float(j) / float(detail_cols)
					var env := sin(t * PI)
					var nh := ridge.get_noise_2d(
						seed_off * 13.0 + float(k) * 7.3 + t * 11.0, seed_off + 31.0) * 0.5 + 0.5
					var hh := h * env * (0.40 + 0.80 * nh)
					var along := mid + tang * ((t - 0.5) * w)
					var top_j := along + Vector3(0.0, hh, 0.0)
					var fj := along + dir * depth + Vector3(0.0, skirt, 0.0)
					var bj := along - dir * depth + Vector3(0.0, skirt, 0.0)
					if j > 0:
						_st_silhouette_quad(st, col, pf, pt, top_j, fj)
						_st_silhouette_quad(st, col, pb, pt, top_j, bj)
					else:
						_st_silhouette_tri(st, col, fj, top_j, bj)
					pf = fj
					pb = bj
					pt = top_j
				_st_silhouette_tri(st, col, pf, pt, pb)
			else:
				# 尖顶海岛：一条山脊 + 两个坡面
				var apex_a := mid - tang * (w * 0.12) + Vector3(0.0, h, 0.0)
				var apex_b := mid + tang * (w * 0.16) + Vector3(0.0, h * rng.randf_range(0.65, 0.95), 0.0)
				_st_silhouette_quad(st, col, b0, apex_a, apex_b, b1)
				_st_silhouette_quad(st, col, b1, apex_b, b2, b2)
				_st_silhouette_quad(st, col, b1, apex_b, apex_a, b0)
	_finalize_silhouette(container, st, col, String(cfg.get("name", "FarIslands")), stats, cfg)


static func _st_silhouette_tri(st: SurfaceTool, col: Color, a: Vector3, b: Vector3, c: Vector3) -> void:
	st.set_color(col)
	st.add_vertex(a)
	st.set_color(col)
	st.add_vertex(b)
	st.set_color(col)
	st.add_vertex(c)


static func _st_silhouette_quad(st: SurfaceTool, col: Color, a: Vector3, b: Vector3,
		c: Vector3, d: Vector3) -> void:
	_st_silhouette_tri(st, col, a, b, c)
	_st_silhouette_tri(st, col, a, c, d)


static func _finalize_silhouette(container: Node3D, st: SurfaceTool, col: Color,
		node_name: String, stats: Dictionary, style: Dictionary = {}) -> void:
	var mesh := st.commit()
	if mesh.get_surface_count() == 0:
		return
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = mesh
	mi.material_override = _silhouette_material(col, style)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.visibility_range_end = 8000.0
	container.add_child(mi)
	stats["nodes"] = int(stats.get("nodes", 0)) + 1
	stats["meshes"] = int(stats.get("meshes", 0)) + 1


## 远景山体：不再是一块纯色纸片。用世界坐标噪声做岩层/植被斑驳，
## 假光照（按面法线）给出体积，峰顶积雪、海岛沙滩边、台地横纹，
## 最后按距离混入雾色，近看有细节、远看是空气透视。
static func _silhouette_material(col: Color, style: Dictionary) -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = """shader_type spatial;
render_mode unshaded, cull_disabled;

uniform vec3 base_color : source_color = vec3(0.35);
uniform vec3 haze_color : source_color = vec3(0.72, 0.80, 0.86);
uniform vec3 sun_dir = vec3(-0.38, 0.62, -0.68);
uniform float kind = 0.0;
uniform float snow_amount = 0.0;
uniform float snow_line = 200.0;
uniform float haze_strength = 1.0;
uniform float detail_amt = 1.0;

varying vec3 v_world;
varying vec3 v_nrm;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}
float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}
float fbm(vec2 p) {
	float s = 0.0;
	float a = 0.5;
	for (int i = 0; i < 4; i++) {
		s += vnoise(p) * a;
		p *= 2.03;
		a *= 0.5;
	}
	return s;
}

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_nrm = normalize(MODEL_NORMAL_MATRIX * NORMAL);
}

void fragment() {
	vec3 n = normalize(v_nrm);
	if (!FRONT_FACING) {
		n = -n;
	}
	float ndl = clamp(dot(n, normalize(-sun_dir)), 0.0, 1.0);
	float shade = 0.58 + 0.42 * ndl;
	float macro = fbm(v_world.xz * 0.0028 + v_world.y * 0.006);
	// 远山离赛道较近时只有一个大色块；加一层中频斑驳，近看像岩面/林斑。
	float detail = fbm(v_world.xz * 0.014 + v_world.y * 0.020);
	// 高频岩纹：陡坡上加强，山体边缘有碎岩块感而不是纯色剪影。
	float crag = fbm(v_world.xz * 0.052 + v_world.y * 0.046);
	float steep = 1.0 - smoothstep(0.35, 0.85, n.y);
	float strata = sin(v_world.y * 0.20 + macro * 6.2831) * 0.5 + 0.5;
	vec3 col = base_color * (0.78 + macro * 0.44);
	col *= 0.87 + 0.26 * detail;
	col *= 0.93 + 0.10 * strata;
	col *= 1.0 + (crag - 0.5) * (0.10 + 0.30 * steep) * detail_amt;
	if (kind > 0.5 && kind < 1.5) {
		// 海岛：沙岸 → 深绿植被；陡坡露岩、缓坡覆植被
		vec3 sand = vec3(0.60, 0.54, 0.40) * (0.90 + 0.20 * macro);
		vec3 veg = base_color * vec3(0.72, 1.05, 0.78);
		vec3 rock = base_color * vec3(0.94, 0.90, 0.84) * (0.86 + 0.24 * crag);
		col = mix(sand, veg, smoothstep(3.0, 18.0, v_world.y));
		col = mix(rock, col, smoothstep(0.30, 0.75, n.y));
		col = mix(col, veg * 1.25, smoothstep(0.55, 1.0, macro) * 0.35);
	} else if (kind > 1.5) {
		// 台地：水平岩层 + 顶部亮面 + 陡壁碎岩
		vec3 band = mix(base_color * 0.62, base_color * 1.16, strata);
		col = mix(band, base_color * 1.10, smoothstep(0.55, 1.0, macro) * 0.5);
		col *= 1.0 + (crag - 0.5) * 0.24 * steep * detail_amt;
	} else {
		// 岩石山：缓坡混入高山灌丛，陡坡保持裸岩色
		vec3 scree = base_color * vec3(0.90, 0.94, 0.88) * (0.88 + 0.22 * crag);
		col = mix(col, scree, smoothstep(0.18, 0.55, n.y) * 0.35);
	}
	float snow = smoothstep(snow_line, snow_line + 110.0, v_world.y) * snow_amount;
	snow *= 0.35 + 0.65 * smoothstep(0.10, 0.60, n.y);
	snow += smoothstep(0.80, 1.0, macro) * snow_amount * 0.30 * smoothstep(0.05, 0.40, n.y)
		* smoothstep(snow_line * 0.55, snow_line * 0.95, v_world.y);
	// 陡壁挂不住雪：雪线附近露出岩层，轮廓更有层次
	snow *= 1.0 - steep * 0.55;
	col = mix(col, vec3(0.90, 0.94, 1.00), clamp(snow, 0.0, 1.0));
	float cam_dist = length(v_world - CAMERA_POSITION_WORLD);
	// 山脉环离赛道只有几百米时，700m 才开始雾化会让它变成一堵纯色墙。
	float haze = smoothstep(320.0, 3800.0, cam_dist) * haze_strength;
	// 先乘假光照再混雾：反过来会把雾色也压暗 0.58 倍，
	// 几公里外的山脊就永远融不进海平线的亮雾里，变成一堵深绿墙。
	vec3 lit = col * shade;
	ALBEDO = mix(lit, haze_color, haze * 0.92);
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = sh
	mat.set_shader_parameter("base_color", col)
	mat.set_shader_parameter("haze_color", style.get("haze", Color(0.72, 0.80, 0.86)))
	var kind := String(style.get("kind", "rock"))
	mat.set_shader_parameter("kind", 1.0 if kind == "island" else (2.0 if kind == "mesa" else 0.0))
	mat.set_shader_parameter("snow_amount", float(style.get("snow", 0.0)))
	mat.set_shader_parameter("snow_line", float(style.get("snow_line", 200.0)))
	mat.set_shader_parameter("haze_strength", float(style.get("haze_strength", 1.0)))
	# 岩纹细节随画质档增加：低档只保留低边形轮廓，高档才开高频碎岩采样
	mat.set_shader_parameter("detail_amt",
		[0.35, 0.60, 0.85, 1.0][clampi(RealAssetKit._quality_index(), 0, 3)])
	return mat


static func _bounds(path: TrackPath) -> Dictionary:
	var mn := Vector2(INF, INF)
	var mx := Vector2(-INF, -INF)
	for p in path.samples:
		mn.x = minf(mn.x, p.x)
		mn.y = minf(mn.y, p.z)
		mx.x = maxf(mx.x, p.x)
		mx.y = maxf(mx.y, p.z)
	return {"center": (mn + mx) * 0.5, "size": mx - mn}


