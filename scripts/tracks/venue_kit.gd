class_name VenueKit
extends RefCounted
## Places the Blender-authored circuit venue kit (grandstand, pit building,
## gantry, floodlights, ad boards, tyre walls, catch fencing, marshal posts,
## big screen, detailed trees) along the procedurally generated circuit.
##
## Assets live in assets/venues/*.glb and were built by tools/blender/*.py.
## Repeated props are converted to MultiMesh (one draw call per material mesh)
## so a full circuit venue stays cheap.

const ROOT := "res://assets/venues/"

static var _templates: Dictionary = {}
static var rejected_placements := 0
static var min_tree_clearance := 1.0e9
## 递增序号：不同批次的同一资产要拿到不同的 decor_group，
## 否则编辑器里改一棵树会连带改到另一批（key 撞车）。
static var _rep_seq := 0


static func clear_cache() -> void:
	for key in _templates.keys():
		var node = _templates[key]
		if node != null and is_instance_valid(node):
			node.free()
	_templates.clear()


## 坡地道具落位：取足迹边缘的最低地面。腿脚稍微埋进上坡侧没关系，
## 下坡侧悬空才是视觉硬伤；平地上等价于中心高度。
static func _seated(pos: Vector3, r: float) -> Vector3:
	if not Terrain.active:
		return pos
	var mn := Terrain.height_at(pos)
	for off in [Vector3(r, 0, 0), Vector3(-r, 0, 0), Vector3(0, 0, r), Vector3(0, 0, -r),
			Vector3(r, 0, r), Vector3(-r, 0, r), Vector3(r, 0, -r), Vector3(-r, 0, -r)]:
		mn = minf(mn, Terrain.height_at(pos + off))
	return Vector3(pos.x, mn, pos.z)


static func build(parent: Node3D, path: TrackPath, def: Dictionary, theme: Dictionary) -> Dictionary:
	var stats := {"meshes": 0, "instances": 0, "assets": 0}
	var root := Node3D.new()
	root.name = "Venue"
	parent.add_child(root)

	var accent := Color.from_string(String(theme.get("accent", "#4fe9ff")), Color(0.3, 0.85, 0.95))
	var seat := accent.darkened(0.3).lerp(Color(0.12, 0.13, 0.17), 0.42)
	var track_id := String(def.get("id", "coast"))
	var half := path.half_width
	var straight := path.main_straight()
	# 场馆保护区（主直道含余量）内不摆路边道具：看台/维修区/大屏自带布景，
	# 广告牌/灯塔/裁判位会插进建筑（灯塔 lateral 25m 正好扎进看台前端）
	var span := path.venue_span(30.0)
	var _in_venue := func(d: float) -> bool:
		return absf(wrapf(d - float(span["center_dist"]),
			-path.total_length * 0.5, path.total_length * 0.5)) <= float(span["half_len"])

	# --- start line: gantry across the track -------------------------------
	var start_frame := path.frame_at(0.0)
	if not start_frame.is_empty():
		_place_unique(root, "gantry",
			Basis.looking_at(-(start_frame["tangent"] as Vector3), Vector3.UP),
			start_frame["pos"] as Vector3, stats, accent, seat)

	# --- main straight: grandstand one side, pit building the other --------
	var mid_frame := path.frame_at(straight["center_dist"])
	if not mid_frame.is_empty():
		var left_pos: Vector3 = (mid_frame["pos"] as Vector3) + (mid_frame["side"] as Vector3) * (half + 27.0)
		var right_pos: Vector3 = (mid_frame["pos"] as Vector3) - (mid_frame["side"] as Vector3) * (half + 27.0)
		var grand_basis := _along_basis(mid_frame, 1.0)
		_place_unique(root, "grandstand", grand_basis, left_pos, stats, accent, seat)
		_place_unique(root, "pit_building", _along_basis(mid_frame, -1.0), right_pos, stats, accent, seat)

		# pit wall hugs the track on the pit side near the start line
		for offset in [-22.0, 4.0]:
			var pf := path.frame_at(straight["center_dist"] + offset)
			if pf.is_empty():
				continue
			var ppos: Vector3 = (pf["pos"] as Vector3) - (pf["side"] as Vector3) * (half + 2.3)
			_place_unique(root, "pit_wall", _along_basis(pf, -1.0), ppos, stats, accent, seat)

	# --- big screen：主直道末端外侧。原先固定摆在 26m 处，正好扎进看台
	# （看台以主直道中心为锚、长轴沿赛道），往直道尽头外挪开 -------------------
	var screen_d := float(straight["center_dist"]) + float(straight["length"]) * 0.5 + 26.0
	var screen_frame := path.frame_at(screen_d)
	if not screen_frame.is_empty():
		var spos: Vector3 = (screen_frame["pos"] as Vector3) + (screen_frame["side"] as Vector3) * (half + 24.0)
		spos = _seated(spos, 3.0)
		_place_unique(root, "big_screen", _along_basis(screen_frame, 1.0), spos, stats, accent, seat)

	# --- 主直道围栏：停用 ------------------------------------------------
	# Poly Haven 的 modular_chainlink_fence 声明 alphaMode=BLEND，但它的
	# 漫反射贴图是**没有 alpha 通道的 JPEG**，导入 Godot 后整片铁丝网会退化成
	# 一块不透光的深色板，在主直道上就是一面 260m 的黑墙；即使强制改成
	# 不透明，细密铁丝在远处也会高频闪烁（就是之前路面那种噪点感）。
	# 直道两侧现在由 track_builder 的真实混凝土护栏 + 广告牌 + 裁判位承担，
	# 观感与性能都更好，所以这里不再叠一层铁丝网。

	# --- ad boards / floodlights / marshal posts along the whole lap --------
	var boards: Array[Transform3D] = []
	var lights: Array[Transform3D] = []
	var marshals: Array[Transform3D] = []
	var tyres: Array[Transform3D] = []
	var dist := 0.0
	var side := 1.0
	var step := 44.0
	while dist < path.total_length:
		if _in_venue.call(dist):
			dist += step
			side = -side
			continue
		var bf := path.frame_at(dist)
		if not bf.is_empty():
			var bpos: Vector3 = (bf["pos"] as Vector3) + (bf["side"] as Vector3) * (half + 7.4) * side
			# 海岸/港湾的 +side 是下坡海滩：直接坐落点地形，别叠加路面 y
			bpos = _seated(bpos, 2.4)
			# 净空 3.4 = 牌板半宽 3.1 + 余量：城市楼体/裙楼（裙楼比实体圆大 1.4m）
			# 和贴路岩石都能挡住；1.8 只够护住中心，牌柱照样扎进楼体
			if RealAssetKit.solid_clear(bpos, 3.4):
				boards.append(Transform3D(_along_basis(bf, side), bpos))
		dist += step
		side = -side
	dist = 21.0
	side = 1.0
	while dist < path.total_length:
		if _in_venue.call(dist):
			dist += 82.0
			side = -side
			continue
		var lf := path.frame_at(dist)
		if not lf.is_empty():
			var lpos: Vector3 = (lf["pos"] as Vector3) + (lf["side"] as Vector3) * (half + 15.0) * side
			lpos = _seated(lpos, 1.5)
			# 灯塔底座 3.6m 宽：净空 2.5 盖住底座对角
			if RealAssetKit.solid_clear(lpos, 2.5):
				lights.append(Transform3D(_along_basis(lf, side), lpos))
		dist += 82.0
		side = -side
	dist = 90.0
	side = 1.0
	while dist < path.total_length:
		if _in_venue.call(dist):
			dist += 172.0
			side = -side
			continue
		var mf := path.frame_at(dist)
		if not mf.is_empty():
			var mpos: Vector3 = (mf["pos"] as Vector3) + (mf["side"] as Vector3) * (half + 10.5) * side
			mpos = _seated(mpos, 0.9)
			# 裁判亭 4.4×3.6，半对角 2.8：裙楼外扩 1.4m 时小净空会被咬住
			if RealAssetKit.solid_clear(mpos, 3.0):
				marshals.append(Transform3D(_along_basis(mf, side), mpos))
		dist += 172.0
		side = -side
	# tyre walls on the outside of the sharper corners
	dist = 0.0
	var placed := 0
	while dist < path.total_length and placed < 14:
		var f := path.frame_at(dist)
		if not f.is_empty():
			var curv := float(f.get("curvature", 0.0))
			if absf(curv) > 0.011:
				var side_sign := -signf(curv)
				var tpos: Vector3 = (f["pos"] as Vector3) + (f["side"] as Vector3) * (half + 1.9) * side_sign
				tpos = _seated(tpos, 1.2)
				if RealAssetKit.solid_clear(tpos, 1.6):
					tyres.append(Transform3D(_along_basis(f, side_sign), tpos))
				placed += 1
				dist += 55.0
				continue
		dist += 22.0

	_place_repeated(root, "ad_board", boards, stats, accent, seat)
	_place_repeated(root, "light_tower", lights, stats, accent, seat)
	_place_repeated(root, "marshal_post", marshals, stats, accent, seat)
	_place_tyre_wall(root, tyres, stats)

	# 植被/远景/主题道具全部由 ThemeScenery 按主题家族统一摆放：
	# 城市不出树、戈壁不出草、雪地只有松/雪/岩、海边只有棕榈/礁石/沙滩。
	# VenueKit 这里只保留场馆与赛道设施（看台/维修区/广告牌/灯塔/裁判位/轮胎墙）。

	_apply_visibility_ranges(root)
	stats["assets"] = int(stats["meshes"])
	return stats


# ---------------------------------------------------------------------------
# placement helpers
# ---------------------------------------------------------------------------

static func distance_to_track(path: TrackPath, pos: Vector3) -> float:
	# 精确点到线段距离（整环逐段）。旧实现隔样本取最近点（step=2 → 4m 采样），
	# 最大误差 ~2m，会让边缘摆放「擦线」漏进路面；且赛道折返段彼此贴近时，
	# 必须取全环最小值才能发现压到另一段路的情况。
	var best := 1.0e9
	var samples := path.samples
	var m := samples.size()
	if m < 2:
		return best
	var px := pos.x
	var pz := pos.z
	for i in m:
		var a := samples[i]
		var abx: float = samples[(i + 1) % m].x - a.x
		var abz: float = samples[(i + 1) % m].z - a.z
		var apx := px - a.x
		var apz := pz - a.z
		var ab2 := abx * abx + abz * abz
		var t := 0.0
		if ab2 > 0.000001:
			t = clampf((apx * abx + apz * abz) / ab2, 0.0, 1.0)
		var dx := apx - abx * t
		var dz := apz - abz * t
		var d2 := dx * dx + dz * dz
		if d2 < best:
			best = d2
	return sqrt(best)


static func clear_of_track(path: TrackPath, pos: Vector3, extra: float) -> bool:
	var dist := distance_to_track(path, pos)
	if dist < path.half_width + extra:
		rejected_placements += 1
		return false
	if extra >= 7.0 and dist < min_tree_clearance:
		min_tree_clearance = dist
	return true


static func _find_main_straight(path: TrackPath) -> Dictionary:
	var m := path.samples.size()
	var best_i := 0
	var best_score := 0
	for i in range(0, m, 3):
		var t0 := path.tangents[i]
		var ok := 0
		for k in range(1, 90):
			var idx := (i + k) % m
			if t0.dot(path.tangents[idx]) < 0.982:
				break
			ok = k
		if ok > best_score:
			best_score = ok
			best_i = i
	var sample_len := path.total_length / float(maxi(m, 1))
	var center_index := (best_i + best_score / 2) % m
	return {
		"start_dist": path.accumulated[best_i],
		"center_dist": path.accumulated[center_index],
		"length": float(best_score) * sample_len,
	}


static func _along_basis(frame: Dictionary, side_sign: float) -> Basis:
	var tangent: Vector3 = frame["tangent"]
	var side: Vector3 = frame["side"]
	if side_sign >= 0.0:
		return Basis(tangent, Vector3.UP, side)
	return Basis(-tangent, Vector3.UP, -side)


static func _add_crowd(root: Node3D, basis: Basis, origin: Vector3, stats: Dictionary) -> void:
	# A condensed crowd on the grandstand: two MultiMeshes (bodies + heads).
	var body_mesh := BoxMesh.new()
	body_mesh.size = Vector3(0.42, 0.72, 0.34)
	var head_mesh := SphereMesh.new()
	head_mesh.radius = 0.14
	head_mesh.height = 0.28
	head_mesh.radial_segments = 8
	head_mesh.rings = 4

	var body_xforms: Array[Transform3D] = []
	var body_colors: Array[Color] = []
	var head_xforms: Array[Transform3D] = []
	var palette := [
		Color(0.75, 0.15, 0.15), Color(0.15, 0.3, 0.6), Color(0.85, 0.8, 0.3),
		Color(0.2, 0.5, 0.3), Color(0.9, 0.9, 0.9), Color(0.35, 0.2, 0.45),
		Color(0.95, 0.5, 0.15), Color(0.15, 0.15, 0.18),
	]
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261103
	for row in 6:
		for s in 27:
			if rng.randf() < 0.22:
				continue
			var bx := -29.0 + s * 2.28 + rng.randf_range(-0.25, 0.25)
			var by := 8.0 - 1.5 * row + 0.15
			var bz := 0.55 + 0.62 * row + 0.62
			var local := Vector3(bx, bz + 0.42, -by)
			var yaw := Basis(Vector3.UP, rng.randf_range(-0.4, 0.4))
			body_xforms.append(Transform3D(basis * yaw, origin + basis * local))
			body_colors.append(palette[rng.randi() % palette.size()])
			head_xforms.append(Transform3D(basis * yaw, origin + basis * (local + Vector3(0.0, 0.5, 0.0))))
	var body_mm := MultiMesh.new()
	body_mm.transform_format = MultiMesh.TRANSFORM_3D
	body_mm.use_colors = true
	body_mm.mesh = body_mesh
	body_mm.instance_count = body_xforms.size()
	for i in body_xforms.size():
		body_mm.set_instance_transform(i, body_xforms[i])
		body_mm.set_instance_color(i, body_colors[i])
	var body_mi := MultiMeshInstance3D.new()
	body_mi.name = "CrowdBodies"
	body_mi.multimesh = body_mm
	var body_mat := StandardMaterial3D.new()
	body_mat.vertex_color_use_as_albedo = true
	body_mat.roughness = 0.9
	body_mi.material_override = body_mat
	root.add_child(body_mi)

	var head_mm := MultiMesh.new()
	head_mm.transform_format = MultiMesh.TRANSFORM_3D
	head_mm.mesh = head_mesh
	head_mm.instance_count = head_xforms.size()
	for i in head_xforms.size():
		head_mm.set_instance_transform(i, head_xforms[i])
	var head_mi := MultiMeshInstance3D.new()
	head_mi.name = "CrowdHeads"
	head_mi.multimesh = head_mm
	var head_mat := StandardMaterial3D.new()
	head_mat.albedo_color = Color(0.78, 0.62, 0.5)
	head_mat.roughness = 0.8
	head_mi.material_override = head_mat
	root.add_child(head_mi)
	stats["meshes"] = int(stats["meshes"]) + 2
	stats["instances"] = int(stats["instances"]) + body_xforms.size() * 2


## 每条赛道的真实树组合。这里填的是「目标高度（米）」而不是缩放倍率：
## CC0 资产里 jacaranda 是 19m 大树、island_tree_03 只有 2.6m，用统一倍率
## 会把小树拉成巨物、大树缩成灌木，所以一律用高度反推缩放。
static func _real_tree_plan(track_id: String) -> Array:
	match track_id:
		"alpine", "glacier":
			return [
				{"asset": "realtree_01", "hmin": 6.0, "hmax": 10.0},
				{"asset": "realtree_pine", "hmin": 2.8, "hmax": 4.8},
			]
		"canyon", "magma":
			return [
				{"asset": "realtree_pine", "hmin": 2.4, "hmax": 4.2},
				{"asset": "realtree_dead", "hmin": 1.0, "hmax": 1.6},
			]
		"city", "skyline":
			return [
				{"asset": "realtree_01", "hmin": 5.0, "hmax": 8.5},
			]
		"harbor":
			return [
				{"asset": "realtree_01", "hmin": 4.5, "hmax": 7.0},
			]
		_:
			return [
				{"asset": "realtree_01", "hmin": 5.0, "hmax": 8.0},
			]


static func _template(asset: String) -> Node3D:
	if _templates.has(asset):
		return _templates[asset]
	var packed := load(ROOT + asset + ".glb") as PackedScene
	if packed == null:
		push_warning("VenueKit: cannot load %s" % (ROOT + asset + ".glb"))
		_templates[asset] = null
		return null
	var node := packed.instantiate() as Node3D
	_templates[asset] = node
	return node


static func _place_unique(root: Node3D, asset: String, basis: Basis, pos: Vector3,
		stats: Dictionary, accent: Color, seat: Color) -> void:
	var template := _template(asset)
	if template == null:
		return
	var node := template.duplicate() as Node3D
	if node == null:
		return
	_tint_tree(node, accent, seat)
	node.transform = Transform3D(basis, pos)
	root.add_child(node)
	stats["instances"] = int(stats["instances"]) + 1
	stats["meshes"] = int(stats["meshes"]) + _count_mesh_nodes(node)


## 弯道外侧的轮胎墙：用 Poly Haven CC0 的真实旧轮胎 flat 排列成 4 连排，
## 替换原来的混凝土 pit_wall（不是轮胎）。没有新资产时回退旧行为。
static func _place_tyre_wall(root: Node3D, transforms: Array[Transform3D], stats: Dictionary) -> void:
	if transforms.is_empty():
		return
	if ResourceLoader.exists(ROOT + "tyre_real.glb"):
		var expanded: Array[Transform3D] = []
		var rng := RandomNumberGenerator.new()
		rng.seed = 7117
		for xf in transforms:
			var tangent := xf.basis.x.normalized()
			for k in 4:
				var shift := tangent * (float(k) - 1.5) * 1.12
				var jitter := Basis(Vector3.UP, rng.randf_range(-0.22, 0.22))
				expanded.append(Transform3D(xf.basis * jitter,
					xf.origin + shift + Vector3(0.0, 0.3, 0.0)))
		_place_repeated(root, "tyre_real", expanded, stats, Color.WHITE, Color.WHITE, false)
	else:
		_place_repeated(root, "pit_wall", transforms, stats, Color.WHITE, Color.WHITE, false)


static func _apply_visibility_ranges(root: Node3D) -> void:
	# 与 scenery_kit 同一套倍率：高档把远处建筑/树木保留得更远，
	# 视野中心再由扇区调度器额外加权，正前方远景更完整
	var mul: float = 0.75 + float(Settings.index) * 0.25
	for node in root.find_children("*", "MultiMeshInstance3D", true, false):
		var mmi := node as MultiMeshInstance3D
		var node_name := String(mmi.name)
		if node_name.begins_with("lowtree_"):
			mmi.visibility_range_end = 950.0 * mul
			mmi.visibility_range_end_margin = 120.0
		elif node_name.begins_with("tree_"):
			mmi.visibility_range_end = 430.0 * mul
			mmi.visibility_range_end_margin = 70.0
		elif node_name.begins_with("shrub_"):
			mmi.visibility_range_end = 240.0 * mul
		elif node_name.begins_with("grass_"):
			mmi.visibility_range_end = 140.0 * mul
		elif node_name.begins_with("ad_"):
			mmi.visibility_range_end = 520.0 * mul
		elif node_name.begins_with("marshal_"):
			mmi.visibility_range_end = 600.0 * mul


static func _place_repeated_chunked(root: Node3D, asset: String, transforms: Array[Transform3D],
		stats: Dictionary, accent: Color, seat: Color, tint := true, chunk_count: int = 16) -> void:
	if transforms.is_empty():
		return
	var groups: Array = []
	for i in chunk_count:
		groups.append([])
	for xform in transforms:
		var origin := xform.origin
		var gx := clampi(int((origin.x + 900.0) / 180.0), 0, 3)
		var gz := clampi(int((origin.z + 900.0) / 180.0), 0, 3)
		(groups[gx * 4 + gz] as Array).append(xform)
	for group in groups:
		var typed: Array[Transform3D] = []
		for xform in group:
			typed.append(xform as Transform3D)
		if not typed.is_empty():
			_place_repeated(root, asset, typed, stats, accent, seat, tint)


static func _place_repeated(root: Node3D, asset: String, transforms: Array[Transform3D],
		stats: Dictionary, accent: Color, seat: Color, tint := true) -> void:
	if transforms.is_empty():
		return
	var template := _template(asset)
	if template == null:
		return
	# 每次调用给一个递增序号，保证不同批次摆出来的同一资产 group 不撞车
	# （生成顺序是确定的，所以每次运行序号一致，override 的 key 才能对得上）。
	_rep_seq += 1
	var gid := _rep_seq
	var entries: Array = []
	_collect_mesh_nodes(template, template, entries)
	# 一次调用 = 一批同位摆放（同一组 transforms，索引一一对应）。
	# 所以这批里拆出来的所有 surface / 所有 model 节点共享一个 group：
	# 编辑器里挪动一只广告牌，牌面、边框、支腿要一起走，不能被拆成四个各自独立的物体。
	var grp := "%s_%d" % [asset, gid]
	var allocated := 0
	for entry in entries:
		var mi := entry["node"] as MeshInstance3D
		var rel: Transform3D = entry["rel"]
		if mi == null or mi.mesh == null:
			continue
		var surface_count := mi.mesh.get_surface_count()
		if surface_count <= 0:
			continue
		# 一个 MultiMesh 只能有一个 material_override，多材质模型（树皮+树叶、
		# 厂房墙板+窗框）必须逐 surface 拆成单材质网格，否则会退化成灰白模型。
		for surf in surface_count:
			var material: Material = null
			if surface_count == 1:
				material = _mesh_material(mi)
			else:
				material = mi.get_active_material(surf)
				if material == null:
					material = mi.mesh.surface_get_material(surf)
			if tint and material != null:
				material = _tint_material(material, accent, seat)
			if material == null:
				material = mi.mesh.surface_get_material(surf)
			if material == null:
				var fallback := StandardMaterial3D.new()
				fallback.albedo_color = Color(0.6, 0.6, 0.58)
				material = fallback
			var draw_mesh: Mesh = mi.mesh
			if surface_count > 1:
				var arrays: Array = mi.mesh.surface_get_arrays(surf)
				if arrays.is_empty() or arrays[0] == null:
					continue
				var submesh := ArrayMesh.new()
				submesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
				draw_mesh = submesh
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.mesh = draw_mesh
			mm.instance_count = transforms.size()
			for i in transforms.size():
				mm.set_instance_transform(i, transforms[i] * rel)
			var mmi := MultiMeshInstance3D.new()
			mmi.multimesh = mm
			mmi.material_override = material
			mmi.name = grp + ("" if surface_count == 1 else "_s%d" % surf)
			# 可编辑标记：场景装饰编辑器全靠这三个 meta 认出「这是一棵能搬的树」。
			# 早期只给 RealAssetKit 摆的资产打了标记，VenueKit 这批（树、广告牌、
			# 灯柱、旗杆）漏了，导致画面上明明有树却点不中。
			mmi.set_meta("decor_asset", asset)
			mmi.set_meta("decor_group", grp)
			mmi.set_meta("decor_chunk", 0)
			if asset.begins_with("tree_") or asset.begins_with("lowtree_") or asset.begins_with("shrub_") or asset.begins_with("grass_"):
				mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			root.add_child(mmi)
			allocated += 1
	stats["meshes"] = int(stats["meshes"]) + allocated
	stats["instances"] = int(stats["instances"]) + allocated * transforms.size()


static func _collect_mesh_nodes(node: Node, root: Node3D, out: Array) -> void:
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		out.append({"node": node, "rel": _rel_transform(node as Node3D, root)})
	for child in node.get_children():
		_collect_mesh_nodes(child, root, out)


static func _rel_transform(node: Node3D, root: Node3D) -> Transform3D:
	var transform := Transform3D.IDENTITY
	var current: Node = node
	while current != null and current != root:
		if current is Node3D:
			transform = (current as Node3D).transform * transform
		current = current.get_parent()
	return transform


static func _mesh_material(mi: MeshInstance3D) -> Material:
	if mi.material_override != null:
		return mi.material_override
	if mi.mesh != null and mi.mesh.get_surface_count() > 0:
		return mi.mesh.surface_get_material(0)
	return null


static func _tint_material(material: Material, accent: Color, seat: Color) -> Material:
	if material is StandardMaterial3D:
		var mat := (material as StandardMaterial3D).duplicate() as StandardMaterial3D
		var name := mat.resource_name.to_lower()
		if name.contains("accent"):
			mat.albedo_color = accent
		elif name.contains("seat"):
			mat.albedo_color = seat
		elif name.contains("emissive"):
			mat.emission_enabled = true
			mat.emission = accent.lightened(0.25)
			# 能量 2.0 + accent.lightened(0.4) 会让灯塔灯头/大屏在辉光下
			# 糊成一团白斑（雪山/港湾尤甚），压回可读范围
			mat.emission_energy_multiplier = minf(maxf(mat.emission_energy_multiplier, 1.0), 1.15)
			mat.albedo_color = accent.lightened(0.1)
		elif name.contains("concrete"):
			var cm := PbrAssets.concrete(Vector2(2.0, 2.0))
			mat.albedo_texture = cm.albedo_texture
			mat.normal_enabled = cm.normal_enabled
			mat.normal_texture = cm.normal_texture
			mat.roughness_texture = cm.roughness_texture
			mat.uv1_scale = cm.uv1_scale
		elif name.contains("metal"):
			var mm := PbrAssets.metal(Vector2(2.0, 2.0))
			mat.albedo_texture = mm.albedo_texture
			mat.normal_enabled = mm.normal_enabled
			mat.normal_texture = mm.normal_texture
			mat.roughness_texture = mm.roughness_texture
			mat.uv1_scale = mm.uv1_scale
		elif name.contains("panel"):
			mat.albedo_color = Color(0.92, 0.92, 0.9)
		elif name.contains("leaf"):
			mat.albedo_color = mat.albedo_color.darkened(0.05)
		return mat
	return material


static func _tint_tree(node: Node3D, accent: Color, seat: Color) -> void:
	for child in node.find_children("*", "MeshInstance3D", true, false):
		var mi := child as MeshInstance3D
		var mat := _mesh_material(mi)
		if mat != null:
			mi.material_override = _tint_material(mat, accent, seat)


static func _count_mesh_nodes(node: Node) -> int:
	var count := 0
	for child in node.find_children("*", "MeshInstance3D", true, false):
		if (child as MeshInstance3D).mesh != null:
			count += 1
	return count
