class_name SceneryKit
extends RefCounted
## Procedural environment dressing around the circuit, driven by the legacy
## track themes. Goal: make the tracks read as places instead of empty ribbons
## while staying cheap (MultiMesh everywhere, a few dozen draw calls).
##
## Per circuit: hills, vegetation, rocks, buildings / containers / streetlights /
## billboards, plus a start gantry over the line.

const PALM_TRUNK_H := 3.4
const PALM_CANOPY_Y := 3.4
const PINE_TRUNK_H := 1.6
const PINE_CANOPY_Y := 2.6
const LEAF_TRUNK_H := 2.2
const LEAF_CANOPY_Y := 3.0


static func build(parent: Node3D, path: TrackPath, def: Dictionary) -> Dictionary:
	var theme: Dictionary = def.get("theme", {})
	var track_id := String(def.get("id", ""))
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(track_id)
	var stats := {"meshes": 0, "instances": 0, "scenery": 0}
	var container := Node3D.new()
	container.name = "Scenery"
	parent.add_child(container)

	# 赛道禁入区：所有摆放入口（place_chunked/place_unique/_mk_multimesh/
	# _box_multimesh）按「落点+物体半径」过滤，杜绝建筑/树/道具压进赛道。
	RealAssetKit.set_keepout(path)

	# 全部布景交给 4 类主题装配器（戈壁 / 城市 / 山谷 / 海边）：
	# 只在赛道左右两侧 90m 内摆细节，远山用低模剪影 + 环境雾。
	ThemeScenery.build(container, path, def, theme, rng, stats)
	_set_scenery_ranges(container)
	return stats


static func _set_scenery_ranges(container: Node3D) -> void:
	# 画质档越高，视野里保留的远景越远；背后分块由扇区剔除关掉，净开销可控
	var mul: float = 0.75 + float(Settings.index) * 0.25
	for node in container.find_children("*", "MultiMeshInstance3D", true, false):
		var mmi := node as MultiMeshInstance3D
		match String(mmi.name):
			"GrassTufts":
				mmi.visibility_range_end = 130.0 * mul
			"CoastBoulders":
				mmi.visibility_range_end = 420.0 * mul
			"ShoreRocks":
				mmi.visibility_range_end = 800.0 * mul


# ---------------------------------------------------------------------------
# terrain
# ---------------------------------------------------------------------------

static func _bounds(path: TrackPath) -> Dictionary:
	var mn := Vector2(INF, INF)
	var mx := Vector2(-INF, -INF)
	for p in path.samples:
		mn.x = minf(mn.x, p.x)
		mn.y = minf(mn.y, p.z)
		mx.x = maxf(mx.x, p.x)
		mx.y = maxf(mx.y, p.z)
	return {"center": (mn + mx) * 0.5, "size": mx - mn}


## 远景山体：以前是 24 段球体拉出来的低模土包，改成 Poly Haven CC0
## 摄影测量山坡（mountainside）。用独立节点摆放，交给 Godot 视锥剔除，
## 不进扇区分块，避免超远距离模型被误判成同一个 chunk。
static func _build_hills(container: Node3D, path: TrackPath, theme: Dictionary,
		rng: RandomNumberGenerator, stats: Dictionary) -> void:
	var asset := "mountain_real"
	if not RealAssetKit.has(asset):
		return
	var bounds := _bounds(path)
	var center: Vector2 = bounds["center"]
	var size: Vector2 = bounds["size"]
	var half_diag := size.length() * 0.5
	var dims := RealAssetKit.size(asset)
	var reference := maxf(dims.y, 0.01)
	for i in 10:
		var angle := rng.randf() * TAU
		var radius := half_diag * rng.randf_range(1.3, 2.3) + 180.0
		var pos := Vector3(center.x + cos(angle) * radius, 0.0, center.y + sin(angle) * radius)
		var height := rng.randf_range(55.0, 130.0)
		var s := height / reference
		var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(
			Vector3(s * rng.randf_range(0.85, 1.25), s, s * rng.randf_range(0.85, 1.25)))
		pos.y = Terrain.height_at(pos) - height * 0.18
		RealAssetKit.place_unique(container, asset, Transform3D(basis, pos),
			"RealMountain_%d" % i, stats)


## 路边岩石：以前是 8 段 4 环的 SphereMesh 低模球，换成 Poly Haven CC0
## 真实岩块；按模型实际尺寸归一化到 2–7m，避免 59m 的礁石地形被放大成巨物。
static func _build_rocks(container: Node3D, path: TrackPath, rng: RandomNumberGenerator,
		stats: Dictionary, count: int, asset: String) -> void:
	if not RealAssetKit.has(asset):
		return
	var dims := RealAssetKit.size(asset)
	# 按最长边归一化：以前只按 x/z 归一化，遇到「又扁又宽」的礁石地形
	# （coast_rocks 59m 宽 / 3.2m 高）会算出巨大的缩放，路边会出现漂浮巨石。
	var reference := maxf(maxf(dims.x, dims.z), maxf(dims.y, 0.3))
	var xforms: Array[Transform3D] = []
	var placed := 0
	var attempts := count * 3
	while xforms.size() < count and placed < attempts:
		placed += 1
		var f := path.frame_at(rng.randf() * path.total_length)
		if f.is_empty():
			continue
		var side: Vector3 = f["side"]
		var lateral := rng.randf_range(16.0, 58.0) * (1.0 if rng.randf() < 0.5 else -1.0)
		var pos: Vector3 = (f["pos"] as Vector3) + side * lateral
		pos.y = Terrain.height_at(pos) - 0.12
		if not VenueKit.clear_of_track(path, pos, 4.0):
			continue
		var s := rng.randf_range(1.6, 6.0) / reference
		var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(
			Vector3(s, s * rng.randf_range(0.72, 1.2), s))
		xforms.append(Transform3D(basis, pos))
	RealAssetKit.place_chunked(container, asset, xforms, "RealRocks", 700.0, true, stats)


# ---------------------------------------------------------------------------
# vegetation
# ---------------------------------------------------------------------------

static func _build_trees(container: Node3D, path: TrackPath, rng: RandomNumberGenerator,
		stats: Dictionary, kind: String, count: int, leaf_color: Color) -> void:
	var trunk_xforms: Array[Transform3D] = []
	var canopy_xforms: Array[Transform3D] = []
	var canopy_colors: Array[Color] = []
	for i in count:
		var f := path.frame_at(rng.randf() * path.total_length)
		if f.is_empty():
			continue
		var side: Vector3 = f["side"]
		var base: Vector3 = f["pos"]
		var lateral := rng.randf_range(12.0, 58.0) * (1.0 if rng.randf() < 0.5 else -1.0)
		var pos := base + side * lateral
		var s := rng.randf_range(0.75, 1.6)
		var yaw := rng.randf() * TAU
		var trunk_h := PALM_TRUNK_H
		var canopy_y := PALM_CANOPY_Y
		var trunk_radius := 0.18
		var canopy_scale := Vector3(2.1, 1.2, 2.1)
		match kind:
			"pine":
				trunk_h = PINE_TRUNK_H
				canopy_y = PINE_CANOPY_Y
				trunk_radius = 0.22
				canopy_scale = Vector3(1.7, 3.0, 1.7)
			"leaf":
				trunk_h = LEAF_TRUNK_H
				canopy_y = LEAF_CANOPY_Y
				trunk_radius = 0.2
				canopy_scale = Vector3(2.3, 1.9, 2.3)
			"shrub":
				trunk_h = 0.0
				canopy_y = 0.55
				trunk_radius = 0.05
				canopy_scale = Vector3(1.0, 0.75, 1.0)
		var basis := Basis(Vector3.UP, yaw)
		if trunk_h > 0.0:
			var trunk_basis := basis.scaled(Vector3(s, s, s))
			trunk_xforms.append(Transform3D(trunk_basis, pos + Vector3(0.0, trunk_h * s * 0.5, 0.0)))
		var canopy_basis := basis.scaled(Vector3(s * canopy_scale.x, s * canopy_scale.y, s * canopy_scale.z))
		canopy_xforms.append(Transform3D(canopy_basis, pos + Vector3(0.0, canopy_y * s, 0.0)))
		canopy_colors.append(leaf_color.darkened(rng.randf_range(0.0, 0.3)).lightened(rng.randf_range(0.0, 0.18)))

	if not trunk_xforms.is_empty():
		var trunk := CylinderMesh.new()
		trunk.top_radius = 0.16
		trunk.bottom_radius = 0.24
		trunk.height = 1.0
		trunk.radial_segments = 6
		trunk.rings = 1
		_mk_multimesh(container, trunk, _mat(Color(0.3, 0.21, 0.14)), trunk_xforms, [], "TreeTrunks", stats)
	var canopy: Mesh
	if kind == "pine":
		var cone := CylinderMesh.new()
		cone.top_radius = 0.0
		cone.bottom_radius = 1.0
		cone.height = 1.0
		cone.radial_segments = 8
		cone.rings = 1
		canopy = cone
	else:
		var sphere := SphereMesh.new()
		sphere.radius = 1.0
		sphere.height = 2.0
		sphere.radial_segments = 10
		sphere.rings = 6
		canopy = sphere
	_mk_multimesh(container, canopy, _mat_vertex_color(), canopy_xforms, canopy_colors, "TreeCanopies", stats)


## A neat row of palms hugging the coast circuit's outer edge.
static func _build_palms_row(container: Node3D, path: TrackPath, rng: RandomNumberGenerator,
		stats: Dictionary) -> void:
	var trunk_xforms: Array[Transform3D] = []
	var canopy_xforms: Array[Transform3D] = []
	var canopy_colors: Array[Color] = []
	var step := 42.0
	var dist := 0.0
	while dist < path.total_length:
		for side_sign: float in [-1.0, 1.0]:
			if rng.randf() < 0.45:
				continue
			var f := path.frame_at(dist + rng.randf_range(-8.0, 8.0))
			if f.is_empty():
				continue
			var side: Vector3 = f["side"]
			var pos: Vector3 = f["pos"] + side * (path.half_width + rng.randf_range(2.6, 6.0)) * side_sign
			var s := rng.randf_range(0.9, 1.5)
			var yaw := rng.randf() * TAU
			var basis := Basis(Vector3.UP, yaw)
			trunk_xforms.append(Transform3D(basis.scaled(Vector3(s, s, s)), pos + Vector3(0.0, 1.7 * s, 0.0)))
			canopy_xforms.append(Transform3D(basis.scaled(Vector3(1.5 * s, 0.42 * s, 1.5 * s)), pos + Vector3(0.0, 3.4 * s, 0.0)))
			canopy_colors.append(Color(0.24, 0.52, 0.24).lightened(rng.randf_range(0.0, 0.2)))
		dist += step
	if trunk_xforms.is_empty():
		return
	var trunk := CylinderMesh.new()
	trunk.top_radius = 0.12
	trunk.bottom_radius = 0.2
	trunk.height = 3.4
	trunk.radial_segments = 6
	trunk.rings = 1
	_mk_multimesh(container, trunk, _mat(Color(0.34, 0.26, 0.18)), trunk_xforms, [], "PalmTrunks", stats)
	var canopy := CylinderMesh.new()
	canopy.top_radius = 0.12
	canopy.bottom_radius = 1.0
	canopy.height = 0.34
	canopy.radial_segments = 9
	canopy.rings = 1
	_mk_multimesh(container, canopy, _mat_vertex_color(), canopy_xforms, canopy_colors, "PalmCanopies", stats)


# ---------------------------------------------------------------------------
# buildings
# ---------------------------------------------------------------------------

static func _build_buildings(container: Node3D, path: TrackPath, theme: Dictionary,
		rng: RandomNumberGenerator, stats: Dictionary, count: int) -> void:
	var night := 1.0 if _is_night(theme) else 0.0
	var accent := _color(String(theme.get("accent", "#4fe9ff")), Color(0.3, 0.85, 0.95))
	var facade := ShaderMaterial.new()
	facade.shader = load("res://shaders/building_facade.gdshader")
	facade.set_shader_parameter("night", night)
	facade.set_shader_parameter("window_light_warm", Color(1.0, 0.78, 0.45))
	facade.set_shader_parameter("window_light_cool", Color(0.62, 0.78, 0.98))
	facade.set_shader_parameter("wall_tint", Color(1.0, 1.0, 1.0))

	var tiers: Array[Transform3D] = []
	var tier_colors: Array[Color] = []
	var tier_custom: Array[Color] = []
	var roofs: Array[Transform3D] = []
	var roof_colors: Array[Color] = []
	var accents: Array[Transform3D] = []
	var accent_colors: Array[Color] = []
	var palette := [
		Color(0.32, 0.34, 0.38), Color(0.42, 0.4, 0.37), Color(0.26, 0.3, 0.36),
		Color(0.5, 0.47, 0.43), Color(0.36, 0.42, 0.46), Color(0.28, 0.26, 0.3),
	]
	for i in count:
		var f := path.frame_at(rng.randf() * path.total_length)
		if f.is_empty():
			continue
		var side: Vector3 = f["side"]
		var base: Vector3 = f["pos"]
		var lateral := rng.randf_range(36.0, 165.0) * (1.0 if rng.randf() < 0.5 else -1.0)
		var origin: Vector3 = base + side * lateral
		var yaw := rng.randf_range(-0.3, 0.3) + (0.0 if side.x > 0.0 else PI)
		var basis := Basis(Vector3.UP, yaw)
		var w := rng.randf_range(12.0, 32.0)
		var d := rng.randf_range(12.0, 28.0)
		var total_h := rng.randf_range(16.0, 96.0)
		var seed_v := rng.randf()
		var wall: Color = palette[rng.randi() % palette.size()]
		if _is_night(theme):
			wall = wall.darkened(rng.randf_range(0.22, 0.5))
		else:
			wall = wall.lightened(rng.randf_range(0.0, 0.2))

		# stacked setback tiers give a believable skyline silhouette
		var tier_frac: Array[float] = [0.62]
		if total_h > 24.0:
			tier_frac.append(0.23)
		if total_h > 52.0:
			tier_frac.append(0.1)
		if total_h > 76.0:
			tier_frac.append(0.05)
		var y := 0.0
		for t in tier_frac.size():
			var th: float = total_h * tier_frac[t]
			tiers.append(Transform3D(basis.scaled(Vector3(w, th, d)), origin + Vector3(0.0, y + th * 0.5, 0.0)))
			tier_colors.append(wall)
			tier_custom.append(Color(w / 100.0, th / 100.0, d / 100.0, fposmod(seed_v + float(t) * 0.17, 1.0)))
			y += th
			w *= 0.78
			d *= 0.78

		# rooftop clutter (AC units, parapet blocks, antenna on tall towers)
		var roof_count := rng.randi_range(2, 5)
		for r in roof_count:
			var rw := rng.randf_range(1.2, 4.5)
			var rh := rng.randf_range(0.8, 2.6)
			var rd := rng.randf_range(1.2, 4.5)
			var rx := rng.randf_range(-0.28, 0.28) * w
			var rz := rng.randf_range(-0.28, 0.28) * d
			roofs.append(Transform3D(basis.scaled(Vector3(rw, rh, rd)), origin + Vector3(rx, y + rh * 0.5, rz)))
			roof_colors.append(wall.darkened(rng.randf_range(0.15, 0.4)))
		if total_h > 55.0:
			var ah := rng.randf_range(4.0, 11.0)
			accents.append(Transform3D(basis.scaled(Vector3(0.22, ah, 0.22)), origin + Vector3(0.0, y + ah * 0.5, 0.0)))
			accent_colors.append(Color(0.12, 0.13, 0.15))
			var beacon := Transform3D(basis.scaled(Vector3(0.5, 0.5, 0.5)), origin + Vector3(0.0, y + ah + 0.4, 0.0))
			accents.append(beacon)
			accent_colors.append(Color(1.0, 0.15, 0.1))

	var body_mesh := BoxMesh.new()
	body_mesh.size = Vector3(1.0, 1.0, 1.0)
	_mk_multimesh_custom(container, body_mesh, facade, tiers, tier_colors, tier_custom, "Buildings", stats)
	_mk_multimesh(container, body_mesh, _mat_vertex_color(), roofs, roof_colors, "RoofProps", stats)
	if not accents.is_empty():
		var accent_mat := StandardMaterial3D.new()
		accent_mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
		accent_mat.vertex_color_use_as_albedo = true
		accent_mat.emission_enabled = true
		accent_mat.emission = Color(1.0, 0.2, 0.12)
		accent_mat.emission_energy_multiplier = 2.2
		_mk_multimesh(container, body_mesh, accent_mat, accents, accent_colors, "RoofBeacons", stats)


static func _build_containers(container: Node3D, path: TrackPath, rng: RandomNumberGenerator,
		stats: Dictionary) -> void:
	var palette := [
		Color(0.55, 0.13, 0.12), Color(0.1, 0.24, 0.45),
		Color(0.45, 0.35, 0.1), Color(0.12, 0.33, 0.2), Color(0.5, 0.5, 0.52),
	]
	var xforms: Array[Transform3D] = []
	var colors: Array[Color] = []
	for i in 34:
		var f := path.frame_at(rng.randf() * path.total_length)
		if f.is_empty():
			continue
		var side: Vector3 = f["side"]
		var base: Vector3 = f["pos"]
		var lateral := rng.randf_range(30.0, 90.0) * (1.0 if rng.randf() < 0.5 else -1.0)
		var yaw := rng.randf() * TAU
		var basis := Basis(Vector3.UP, yaw).scaled(Vector3(6.1, 2.6, 2.5))
		xforms.append(Transform3D(basis, base + side * lateral + Vector3(0.0, 1.3, 0.0)))
		var col: Color = palette[rng.randi() % palette.size()]
		colors.append(col)
	var mesh := BoxMesh.new()
	mesh.size = Vector3(1.0, 1.0, 1.0)
	_mk_multimesh(container, mesh, _mat_vertex_color(), xforms, colors, "Containers", stats)


static func _build_streetlights(container: Node3D, path: TrackPath, theme: Dictionary,
		rng: RandomNumberGenerator, stats: Dictionary, real: bool = false) -> void:
	if real:
		# 霓虹都市 / 天际环城：换成 Poly Haven CC0 真实铸铁路灯（带发光灯罩）。
		_build_real_lamps(container, path, rng, stats, 76.0, path.half_width + 3.4, true)
		return
	var pole_xforms: Array[Transform3D] = []
	var lamp_xforms: Array[Transform3D] = []
	var step := 38.0
	var dist := rng.randf_range(0.0, step)
	while dist < path.total_length:
		var f := path.frame_at(dist)
		if not f.is_empty():
			var side: Vector3 = f["side"]
			var base: Vector3 = f["pos"]
			for side_sign: float in [-1.0, 1.0]:
				var pos := base + side * (path.half_width + 2.6) * side_sign
				pole_xforms.append(Transform3D(Basis(), pos + Vector3(0.0, 3.4, 0.0)))
				lamp_xforms.append(Transform3D(Basis(), pos + Vector3(0.0, 6.9, 0.0)))
		dist += step
	var pole := CylinderMesh.new()
	pole.top_radius = 0.09
	pole.bottom_radius = 0.13
	pole.height = 6.8
	pole.radial_segments = 6
	pole.rings = 1
	_mk_multimesh(container, pole, _mat(Color(0.22, 0.24, 0.27)), pole_xforms, [], "LightPoles", stats)
	var lamp := BoxMesh.new()
	lamp.size = Vector3(0.55, 0.22, 0.55)
	var lamp_mat := StandardMaterial3D.new()
	lamp_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	lamp_mat.albedo_color = Color(1.0, 0.88, 0.6)
	lamp_mat.emission_enabled = true
	lamp_mat.emission = Color(1.0, 0.85, 0.55)
	lamp_mat.emission_energy_multiplier = 3.0
	_mk_multimesh(container, lamp, lamp_mat, lamp_xforms, [], "LightLamps", stats)


# ---------------------------------------------------------------------------
# landmarks
# ---------------------------------------------------------------------------

static func _build_start_gantry(container: Node3D, path: TrackPath, theme: Dictionary) -> void:
	var f := path.frame_at(0.0)
	if f.is_empty():
		return
	var pos: Vector3 = f["pos"]
	var side: Vector3 = f["side"]
	var tangent: Vector3 = f["tangent"]
	var base_rot := Basis(Vector3.UP, atan2(tangent.x, tangent.z))
	var span := path.width + 3.4
	var post_mat := _mat(Color(0.14, 0.16, 0.19))
	var span_mat := _mat(Color(0.2, 0.22, 0.26))
	for sign_v: float in [-1.0, 1.0]:
		var post := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(0.55, 6.6, 0.55)
		post.mesh = box
		post.material_override = post_mat
		post.transform = Transform3D(base_rot, pos + side * (span * 0.5) * sign_v + Vector3(0.0, 3.3, 0.0))
		container.add_child(post)
	var beam := MeshInstance3D.new()
	var beam_box := BoxMesh.new()
	beam_box.size = Vector3(span + 1.8, 1.4, 1.1)
	beam.mesh = beam_box
	beam.material_override = span_mat
	beam.transform = Transform3D(base_rot, pos + Vector3(0.0, 6.7, 0.0))
	container.add_child(beam)

	var banner := MeshInstance3D.new()
	var banner_box := BoxMesh.new()
	banner_box.size = Vector3(span * 0.72, 1.1, 0.16)
	banner.mesh = banner_box
	var banner_mat := StandardMaterial3D.new()
	banner_mat.albedo_texture = _checker_texture()
	banner_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	banner.material_override = banner_mat
	banner.transform = Transform3D(base_rot, pos + side * 0.0 + Vector3(0.0, 6.7, 0.0) + tangent * 0.62)
	container.add_child(banner)

	var light_mat := StandardMaterial3D.new()
	light_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	light_mat.albedo_color = Color(0.9, 0.12, 0.12)
	light_mat.emission_enabled = true
	light_mat.emission = Color(1.0, 0.15, 0.12)
	light_mat.emission_energy_multiplier = 2.5
	var light_mesh := SphereMesh.new()
	light_mesh.radius = 0.28
	light_mesh.height = 0.56
	light_mesh.radial_segments = 10
	light_mesh.rings = 5
	for i in 5:
		var lamp := MeshInstance3D.new()
		lamp.mesh = light_mesh
		lamp.material_override = light_mat
		var offset := (float(i) - 2.0) * 0.9
		lamp.transform = Transform3D(base_rot, pos + side * offset + Vector3(0.0, 5.8, 0.0) + tangent * 0.2)
		container.add_child(lamp)


static func _build_billboards(container: Node3D, path: TrackPath, theme: Dictionary,
		rng: RandomNumberGenerator, stats: Dictionary, count: int = 3,
		text: String = "APEX / VELOCITY") -> void:
	var accent := _color(String(theme.get("accent", "#4fe9ff")), Color(0.3, 0.85, 0.95))
	# 场馆段（看台占 half+12~half+42）不摆，广告牌会插进看台
	var span := path.venue_span(30.0)
	for i in count:
		for attempt in 8:
			var dist := rng.randf() * path.total_length
			var delta := wrapf(dist - float(span["center_dist"]),
				-path.total_length * 0.5, path.total_length * 0.5)
			if absf(delta) <= float(span["half_len"]) + 46.0:
				continue
			var f := path.frame_at(dist)
			if f.is_empty():
				continue
			var side: Vector3 = f["side"]
			var base: Vector3 = f["pos"]
			var side_sign := 1.0 if rng.randf() < 0.5 else -1.0
			var pos := base + side * (path.half_width + 11.0) * side_sign
			# 城市楼群/岩石登记为实体：牌板半宽 5.5 + 柱距 4，净空 7 才挡得住扎楼
			if not RealAssetKit.solid_clear(pos, 7.0):
				continue
			if Terrain.active:
				pos.y = Terrain.height_at(pos)
			var yaw := atan2(side.x, side.z) + (0.0 if side_sign > 0.0 else PI)
			var basis := Basis(Vector3.UP, yaw)
			# 牌板/立柱/灯带归进同一个命名容器：审计按「上溯具名祖先」合并，
			# 不归组的话柱子和牌板会互相报穿模，悬空判定也会失灵
			var bb := Node3D.new()
			bb.name = "Billboard_%d" % i
			container.add_child(bb)
			var panel := MeshInstance3D.new()
			var box := BoxMesh.new()
			box.size = Vector3(11.0, 4.2, 0.22)
			panel.mesh = box
			var mat := StandardMaterial3D.new()
			mat.albedo_color = accent.darkened(0.55)
			mat.emission_enabled = true
			mat.emission = accent
			mat.emission_energy_multiplier = 0.6
			panel.material_override = mat
			panel.transform = Transform3D(basis, pos + Vector3(0.0, 7.4, 0.0))
			panel.set_meta("audit_cat", "sign")
			bb.add_child(panel)

			var label := Label3D.new()
			label.text = text
			label.font_size = 96
			label.pixel_size = 0.012
			label.modulate = Color(1.0, 1.0, 1.0)
			label.outline_size = 12
			label.outline_modulate = Color(0.0, 0.0, 0.0, 0.8)
			label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			label.no_depth_test = true
			label.position = pos + Vector3(0.0, 7.4, 0.0)
			bb.add_child(label)

			for sign_v: float in [-1.0, 1.0]:
				var post := MeshInstance3D.new()
				var post_box := BoxMesh.new()
				post_box.size = Vector3(0.3, 5.6, 0.3)
				post.mesh = post_box
				post.material_override = _mat(Color(0.16, 0.17, 0.2))
				post.transform = Transform3D(basis, pos + (basis.x * 4.0 * sign_v) + Vector3(0.0, 2.8, 0.0))
				post.set_meta("audit_cat", "sign")
				bb.add_child(post)
			stats["scenery"] = int(stats["scenery"]) + 1
			break


# ---------------------------------------------------------------------------
# Real CC0 building kit (Poly Haven facade modules + ToxSam landmark tower)
# ---------------------------------------------------------------------------

static func _brighten_building(node: Node3D, factor: float) -> void:
	for child in node.find_children("*", "MeshInstance3D", true, false):
		var mi := child as MeshInstance3D
		var mat := mi.material_override
		if mat == null and mi.mesh != null and mi.mesh.get_surface_count() > 0:
			mat = mi.mesh.surface_get_material(0)
		if mat is StandardMaterial3D:
			var std := (mat as StandardMaterial3D).duplicate() as StandardMaterial3D
			std.albedo_color = Color(factor, factor, factor, 1.0)
			mi.material_override = std


static func _combined_aabb(root: Node) -> AABB:
	var box := AABB()
	var first := true
	for child in root.find_children("*", "MeshInstance3D", true, false):
		var mi := child as MeshInstance3D
		if mi.mesh == null:
			continue
		var rel := Transform3D.IDENTITY
		var cur: Node = mi
		while cur != null and cur != root:
			if cur is Node3D:
				rel = (cur as Node3D).transform * rel
			cur = cur.get_parent()
		var aabb: AABB = rel * mi.mesh.get_aabb()
		if first:
			box = aabb
			first = false
		else:
			box = box.merge(aabb)
	return box


## 远处楼体的窗格贴图：比旧版更细的窗格 + 楼板竖线，避免远景像发光白板。
## 夜景用两张独立贴图：albedo 全暗（墙+暗玻璃），emission 只含亮窗（纯黑底）。
## 之前 albedo/emission 共用一张图，亮窗像素把整面墙的 mip 平均抬成奶油白「白膜」。
static func _city_window_material(night: bool, seed_value: int = 4242) -> StandardMaterial3D:
	var size := Vector2i(160, 256)
	var img := Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
	var emis_img := Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var wall := Color(0.028, 0.032, 0.045) if night else Color(0.10, 0.11, 0.14)
	img.fill(wall)
	emis_img.fill(Color(0, 0, 0, 1))
	var cols := 10
	var rows := 20
	var cw := float(size.x) / float(cols)
	var ch := float(size.y) / float(rows)
	# 先画横向楼板线，让远景高楼有层高节奏
	for gy in rows:
		var y0 := int(gy * ch)
		for x in size.x:
			img.set_pixel(x, y0, wall.lightened(0.18))
	for gy in rows:
		for gx in cols:
			if rng.randf() < 0.14:
				continue
			# 夜间亮窗比例压低：比例过高时整栋楼的自发光在辉光下
			# 会糊成一整片「白膜」，楼体轮廓全部消失。
			# 真实夜景是「大多数窗户熄灯，零星几户亮」——比例控制在 ~12%。
			var lit := rng.randf() < (0.16 if night else 0.22)
			var col := Color(1.0, 0.78, 0.44) if lit else Color(0.035, 0.045, 0.06)
			if lit and rng.randf() < 0.3:
				col = Color(0.5, 0.78, 1.0)
			var inset_x := maxi(2, int(cw * 0.22))
			var x0 := int(gx * cw) + inset_x
			var x1 := int((gx + 1) * cw) - inset_x
			var y0 := int(gy * ch) + maxi(2, int(ch * 0.24))
			var y1 := int((gy + 1) * ch) - maxi(2, int(ch * 0.2))
			for y in range(y0, maxi(y0 + 1, y1)):
				for x in range(x0, maxi(x0 + 1, x1)):
					# 夜里亮窗的漫反射保持暗色（发光交给 emission 贴图），
					# 否则暖色窗格在车灯/环境光下仍会把墙面抬亮
					var albedo_col := col
					if night and lit:
						albedo_col = Color(0.05, 0.06, 0.08)
					img.set_pixel(x, y, albedo_col)
					if lit:
						emis_img.set_pixel(x, y, col)
	img.generate_mipmaps()
	emis_img.generate_mipmaps()
	var tex := ImageTexture.create_from_image(img)
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = tex
	# 墙面提亮：夜景纯黑墙 + 高自发光是「白楼/黑楼并存」的根因，
	# 墙体有底色后窗格与墙面对比回落到可读范围
	mat.albedo_color = Color(0.22, 0.24, 0.30) if night else Color(0.46, 0.49, 0.55)
	mat.roughness = 0.78
	mat.metallic = 0.05
	mat.metallic_specular = 0.32
	mat.texture_repeat = true
	# 世界坐标三平面映射：每栋楼窗格大小一致，不会被 BoxMesh 拉成白色大墙
	mat.uv1_triplanar = true
	mat.uv1_scale = Vector3(0.085, 0.11, 0.085)
	if night:
		mat.emission_enabled = true
		mat.emission_texture = ImageTexture.create_from_image(emis_img)
		# 关键：emission_operator 默认是 OP_ADD——会把 emission 颜色整面墙均匀叠加，
		# 贴图再黑也没用，这就是「夜景白膜楼」的真正根因。必须改成 MULTIPLY，
		# 让 emission = 颜色 × 贴图，纯黑背景的亮窗贴图才只点亮窗格。
		mat.emission_operator = BaseMaterial3D.EMISSION_OP_MULTIPLY
		mat.emission = Color(1.0, 1.0, 1.0)
		mat.emission_energy_multiplier = 2.2
	return mat


## 真实 CC0 公寓立面照片（Poly Haven modular_urban_apartments_facade）做的楼体材质。
## 三种 UV 密度共享 3 个材质，避免每栋楼一个材质把 draw call 打爆。
static func _facade_photo(uv_scale: Vector2, night: bool) -> StandardMaterial3D:
	var mat := PbrAssets.building_tile(uv_scale, night)
	mat.albedo_color = Color(0.38, 0.42, 0.52) if night else Color(1.0, 1.0, 1.0)
	if night:
		mat.emission = Color(1.0, 0.86, 0.62)
		# 照片立面整面挂自发光就是「整楼发光」的元凶——只留极微弱的窗光
		# 暗示，亮窗交给零星的程序窗格楼和路灯灯池
		mat.emission_energy_multiplier = 0.14
	return mat


static func _box_multimesh(parent: Node3D, name: String, mat: Material,
		transforms: Array) -> void:
	if transforms.is_empty():
		return
	# 赛道禁入区过滤：城市楼群量块按单位盒半径过滤（穿模修复）
	var kept: Array = []
	for xf_v in transforms:
		var xf := xf_v as Transform3D
		var sc: float = maxf(xf.basis.get_scale().x, xf.basis.get_scale().z)
		if RealAssetKit.keepout_clear(xf.origin, sc * 0.9):
			kept.append(xf_v)
	if kept.is_empty():
		return
	transforms = kept
	var bm := BoxMesh.new()
	bm.size = Vector3.ONE
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = bm
	mm.instance_count = transforms.size()
	for i in transforms.size():
		mm.set_instance_transform(i, transforms[i] as Transform3D)
	var mmi := MultiMeshInstance3D.new()
	mmi.name = name
	mmi.multimesh = mm
	mmi.material_override = mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mmi)


static func _build_real_city(container: Node3D, path: TrackPath, rng: RandomNumberGenerator,
		stats: Dictionary, count: int, accent: Color, landmark: bool, night: bool = false,
		attach_facades: bool = false, venue: Dictionary = {}, near_count: int = 0) -> void:
	# 「城市峡谷」：两排楼紧贴赛道两侧。
	# 近排（gap 6~13m）形成夹道高楼，后一排（30~62m）补天际线，全部 ≤ 90m。
	# 所有楼体量块 + 真实窗格贴图；细节（裙楼/退台/角柱/线脚/霓虹）按材质分组 MultiMesh。
	var root := Node3D.new()
	root.name = "CityBlocks"
	container.add_child(root)
	var facades: Array[StandardMaterial3D] = []
	facades.append(_city_window_material(night, 4242))
	facades.append(_city_window_material(night, 9117))
	facades.append(_city_window_material(night, 2087))
	facades.append(_city_window_material(night, 7321))
	var roof_mat := PbrAssets.metal(Vector2(2.0, 2.0))
	var ac_mesh := BoxMesh.new()
	ac_mesh.size = Vector3(1.9, 1.1, 1.6)
	var ctx := {
		"root": root,
		"facades": facades,
		"roof_mat": roof_mat,
		"ac_mesh": ac_mesh,
		"accent": accent,
		"night": night,
		"landmark": landmark,
		"attach_facades": attach_facades,
		"venue": venue,
		"podium_groups": [[], [], [], []],
		"tier_groups": [[], [], [], []],
		"fin_xforms": [],
		"ledge_xforms": [],
		"neon_xforms": [],
		"spire_xforms": [],
		"ac_xforms": [],
		"neon_mats": {},
		"model_groups": {},
		"model_pool_near": CITY_MODEL_POOL_NEAR,
		"model_pool_back": CITY_MODEL_POOL_BACK,
		"model_ratio": CITY_MODEL_RATIO,
	}
	if near_count <= 0:
		near_count = int(float(count) * 0.58)
	var back_count := maxi(count - near_count, 0)
	var near_step := path.total_length / float(maxi(near_count, 1))
	var back_step := path.total_length / float(maxi(back_count, 1))
	var hero := _hero_tower_slots(path, rng, venue, landmark)
	# 英雄塔顶替楼位：细塔替换一个近排楼位（贴路、天然可见），宽幅体量的
	# 替换一个后排楼位（顶点半径太大，贴路会探进路面）。楼位是腾出来的，
	# 塔楼与量块楼群不会穿插。
	for i in near_count:
		var dist := (float(i) + rng.randf_range(0.12, 0.88)) * near_step
		var side_plus := i % 2 == 0
		if _try_hero_slot(path, rng, hero, dist, side_plus, near_step, true):
			continue
		if _try_city_model(path, rng, ctx, dist, side_plus, 0):
			continue
		_city_block(path, rng, ctx, dist, side_plus, 0)
	for i in back_count:
		var dist := (float(i) + rng.randf_range(0.10, 0.90)) * back_step
		var side_plus := rng.randf() < 0.5
		if _try_hero_slot(path, rng, hero, dist, side_plus, back_step, false):
			continue
		if _try_city_model(path, rng, ctx, dist, side_plus, 1):
			continue
		_city_block(path, rng, ctx, dist, side_plus, 1)
	_city_flush(ctx, stats)
	_city_models_flush(root, ctx, night, stats)
	_hero_tower_flush(root, hero, stats)


## 开源城市楼模型（Quaternius，CC0）：大厦三档 + 公寓/住宅楼。
## 按「想摆多高」归一化到城市尺度，按比例顶替量块楼位——
## 模型楼有真立面窗格和形体变化，负责近景可读性。
const CITY_MODEL_POOL_NEAR := {
	"downtown_small": 30.0,
	"downtown_medium": 46.0,
	"qt_apt4_a": 20.0,
	"qt_apt4_b": 22.0,
	"qt_apt6": 26.0,
	"qt_block1_large": 40.0,
	"qt_block4": 28.0,
}
const CITY_MODEL_POOL_BACK := {
	"downtown_large": 82.0,
	"downtown_medium": 64.0,
	"qt_block1_large": 56.0,
	"qt_block2_large": 48.0,
	"qt_apt6": 38.0,
}
const CITY_MODEL_RATIO := 0.42


static func _try_city_model(path: TrackPath, rng: RandomNumberGenerator, ctx: Dictionary,
		dist: float, side_plus: bool, row: int) -> bool:
	var pool: Dictionary = ctx["model_pool_near"] if row == 0 else ctx["model_pool_back"]
	if pool.is_empty() or rng.randf() > float(ctx["model_ratio"]):
		return false
	var keys := pool.keys()
	var asset := str(keys[rng.randi() % keys.size()])
	if not RealAssetKit.has(asset):
		return false
	var target: float = float(pool[asset])
	if bool(ctx["landmark"]):
		target *= rng.randf_range(1.0, 1.3)
	var sc := RealAssetKit.scale_for_height(asset, target)
	var radius := RealAssetKit.true_radius(asset) * sc
	if radius > 62.0:
		return false
	var frame := path.frame_at(dist)
	if frame.is_empty():
		return false
	var gap := rng.randf_range(5.0, 12.0) if row == 0 else rng.randf_range(26.0, 50.0)
	var lateral := path.half_width + radius + gap
	if lateral + radius > path.half_width + 88.0:
		return false
	var side_sign := 1.0 if side_plus else -1.0
	var pos: Vector3 = (frame["pos"] as Vector3) \
		+ (frame["side"] as Vector3) * lateral * side_sign
	if Terrain.active:
		pos.y = Terrain.height_at(pos)
	# 混凝土护栏在弯道摆到 half+1.6，留 1m 余量别让楼体压上护栏
	if VenueKit.distance_to_track(path, pos) < radius + path.half_width + 2.6:
		return false
	# 登记为实体：路边的看台道具/裁判位/灯塔避开楼体，别插进楼里
	RealAssetKit.register_solid(pos, radius)
	# 楼面半径=渲染半径：霓虹招牌按楼面避让，不然招牌半截埋进楼身
	RealAssetKit.register_face(pos, radius)
	var yaw := atan2((frame["tangent"] as Vector3).x, (frame["tangent"] as Vector3).z) \
		+ rng.randf_range(-0.16, 0.16)
	var groups: Dictionary = ctx["model_groups"]
	if not groups.has(asset):
		groups[asset] = [] as Array[Transform3D]
	(groups[asset] as Array[Transform3D]).append(
		Transform3D(Basis(Vector3.UP, yaw).scaled(Vector3.ONE * sc), pos))
	return true


static func _city_models_flush(root: Node3D, ctx: Dictionary, night: bool,
		stats: Dictionary) -> void:
	var groups: Dictionary = ctx["model_groups"]
	for asset in groups:
		var xf: Array[Transform3D] = groups[asset] as Array[Transform3D]
		if xf.is_empty():
			continue
		for part in RealAssetKit.surfaces(asset):
			var m := part["material"] as StandardMaterial3D
			if m == null:
				continue
			# 夜景压暗 + 微弱自发光：贴图是白天扫描的亮色，夜里直接用会发白；
			# 完全不发光又会变成纯黑剪影。MULTIPLY 自发光让贴图亮部（窗格/檐口）
			# 隐约可见，墙身仍是暗色。材质跨赛道缓存，底色存 meta 保证幂等。
			if not m.has_meta("base_albedo"):
				m.set_meta("base_albedo", m.albedo_color)
			m.albedo_color = (m.get_meta("base_albedo") as Color) \
				* (Color(0.70, 0.72, 0.80) if night else Color.WHITE)
			if night and m.albedo_texture != null and not m.emission_enabled:
				m.emission_enabled = true
				m.emission_operator = BaseMaterial3D.EMISSION_OP_MULTIPLY
				m.emission_texture = m.albedo_texture
				m.emission = Color(1.0, 1.0, 1.0)
				m.emission_energy_multiplier = 0.55
		RealAssetKit.place_chunked(root, asset, xf, "CityModel", 560.0, false, stats, false)


## 英雄塔：assets/buildings/ 里的真实高模建筑（完整 PBR + 自发光材质），
## 有真正的形体设计——贴图量块楼群负责远近天际线，这几栋负责「近看像真楼」。
## 每栋资产独立 place_chunked（按 surface 拆 MultiMesh，材质不串），
## 数量控制在个位数实例，按目标高度反推缩放。
const HERO_TOWER_ASSETS := ["colony_tower", "memefactory_tower", "station_tower",
	"blockchain_tower", "lovedeath_tower", "launch_building"]
# 资产原始高度差异大（11m~91m），按「想摆多高」归一化到城市尺度。
const HERO_TOWER_HEIGHT := {
	"colony_tower": 92.0,
	"memefactory_tower": 56.0,
	"station_tower": 72.0,
	"blockchain_tower": 42.0,
	"lovedeath_tower": 44.0,
	"launch_building": 15.0,
}


## albedo 贴图平均亮度（0~1）。压缩纹理先解压；抽样 ~400 像素足够。
static func _texture_luminance(tex: Texture2D) -> float:
	var img := tex.get_image()
	if img == null:
		return 1.0
	if img.is_compressed():
		img = img.duplicate()
		img.decompress()
	var w := img.get_width()
	var h := img.get_height()
	if w <= 0 or h <= 0:
		return 1.0
	var total := w * h
	var stride := maxi(1, total / 400)
	var acc := 0.0
	var cnt := 0
	for k in range(0, total, stride):
		var px := img.get_pixel(k % w, k / w)
		acc += (px.r + px.g + px.b) / 3.0
		cnt += 1
	return acc / maxf(cnt, 1)


## 预生成英雄塔楼位清单：每栋资产按环形均分抢 2~3 个距离点（landmark 加量），
## 场馆段跳过。候选楼位在这里定，是否成放在 _try_hero_slot 里对全环查净空。
static func _hero_tower_slots(path: TrackPath, rng: RandomNumberGenerator,
		venue: Dictionary, landmark: bool) -> Array[Dictionary]:
	var slots: Array[Dictionary] = []
	var assets: Array[String] = []
	for asset in HERO_TOWER_ASSETS:
		if RealAssetKit.has(asset):
			assets.append(asset)
	if assets.is_empty():
		return slots
	var per_asset := 3 if landmark else 2
	var venue_center := float(venue.get("center_dist", 0.0))
	var venue_half := float(venue.get("half_len", 0.0)) + 40.0
	var idx := 0
	for asset in assets:
		var target: float = float(HERO_TOWER_HEIGHT.get(asset, 60.0))
		if landmark:
			target *= 1.25
		var sc: float = RealAssetKit.scale_for_height(asset, target)
		var radius: float = RealAssetKit.true_radius(asset) * sc
		for i in per_asset:
			var dist := wrapf(
				(float(idx) + rng.randf_range(0.25, 0.75))
				* path.total_length / float(assets.size() * per_asset),
				0.0, path.total_length)
			idx += 1
			var delta := wrapf(dist - venue_center, -path.total_length * 0.5, path.total_length * 0.5)
			if not venue.is_empty() and absf(delta) <= venue_half:
				continue
			slots.append({
				"asset": asset, "sc": sc, "radius": radius,
				"dist": dist, "taken": false, "xform": Transform3D(),
			})
	return slots


## 尝试用一栋英雄塔顶替当前楼位。want_slim=true 只认细塔（顶点半径 <26m，
## 可以贴路摆出存在感），false 只认宽幅体量（退后排当天际线）。
static func _try_hero_slot(path: TrackPath, rng: RandomNumberGenerator,
		hero: Array[Dictionary], dist: float, side_plus: bool, step: float,
		want_slim: bool) -> bool:
	for slot in hero:
		if slot["taken"]:
			continue
		var radius := float(slot["radius"])
		if (radius < 26.0) != want_slim:
			continue
		var delta := wrapf(dist - float(slot["dist"]),
			-path.total_length * 0.5, path.total_length * 0.5)
		if absf(delta) >= step * 0.55:
			continue
		var frame := path.frame_at(dist)
		if frame.is_empty():
			return false
		var side_sign := 1.0 if side_plus else -1.0
		var gap := rng.randf_range(6.0, 16.0) if want_slim else rng.randf_range(12.0, 36.0)
		var lateral: float = path.half_width + radius + gap
		var pos: Vector3 = (frame["pos"] as Vector3) \
			+ (frame["side"] as Vector3) * lateral * side_sign
		if Terrain.active:
			pos.y = Terrain.height_at(pos)
		# 闭环赛道会折返贴近自己：塔楼体量大，必须对全环查净空，
		# 否则会横跨压到另一段路面。不成放就老老实实摆量块楼。
		if VenueKit.distance_to_track(path, pos) < radius + path.half_width + 0.8:
			return false
		RealAssetKit.register_solid(pos, radius)
		RealAssetKit.register_face(pos, radius)
		var yaw := atan2((frame["tangent"] as Vector3).x, (frame["tangent"] as Vector3).z) \
			+ rng.randf_range(-0.5, 0.5)
		slot["xform"] = Transform3D(Basis(Vector3.UP, yaw).scaled(Vector3.ONE * float(slot["sc"])), pos)
		slot["taken"] = true
		return true
	return false


## 收尾：按资产分组 place_chunked，并做夜城照明分流——贴图楼群靠窗格自发光
## 贴图撑夜景，真实塔楼的材质是白天扫描的 PBR，夜里只剩黑影。按贴图亮度分
## 流：暗色立面（窗格、金属格栅）挂低能量自发光模拟「楼内灯光」；亮色石材/
## 白天照片墙面不发光——整面发光就是白墙，夜里让它退成剪影。名字带
## emissive 的灯牌件用高能量，形成招牌亮点。
static func _hero_tower_flush(root: Node3D, hero: Array[Dictionary], stats: Dictionary) -> void:
	var by_asset := {}
	for slot in hero:
		if not slot["taken"]:
			continue
		var asset := str(slot["asset"])
		if not by_asset.has(asset):
			by_asset[asset] = [] as Array[Transform3D]
		(by_asset[asset] as Array[Transform3D]).append(slot["xform"] as Transform3D)
	for asset in by_asset:
		# 夜景塔楼照明：真实塔楼只保留模型自带的发光灯牌/灯罩（emission_enabled
		# 的材质）。暗色立面整面挂自发光会变成「整楼发光」，已移除——
		# 塔楼夜里以深色剪影示人，靠窗格细节和路灯灯池衬出形体。
		for part in RealAssetKit.surfaces(asset):
			var m := part["material"] as StandardMaterial3D
			if m == null:
				continue
			if m.emission_enabled:
				m.emission_operator = BaseMaterial3D.EMISSION_OP_MULTIPLY
				m.emission_energy_multiplier = maxf(m.emission_energy_multiplier, 2.0)
		RealAssetKit.place_chunked(root, asset, by_asset[asset], "HeroTower", 520.0, false, stats, false)


## 一栋城市楼：row 0 = 近排（贴路），row 1 = 后排（天际线）。
static func _city_block(path: TrackPath, rng: RandomNumberGenerator, ctx: Dictionary,
		dist: float, side_plus: bool, row: int) -> void:
	var venue: Dictionary = ctx["venue"] as Dictionary
	if not venue.is_empty():
		var center := float(venue.get("center_dist", 0.0))
		var half_len := float(venue.get("half_len", 0.0)) + 24.0
		var delta := wrapf(dist - center, -path.total_length * 0.5, path.total_length * 0.5)
		if absf(delta) <= half_len:
			return
	var frame := path.frame_at(dist)
	if frame.is_empty():
		return
	var landmark := bool(ctx["landmark"])
	var night := bool(ctx["night"])
	var accent: Color = ctx["accent"] as Color
	var facades: Array = ctx["facades"] as Array
	var root: Node3D = ctx["root"] as Node3D
	var half := path.half_width
	var side_sign := 1.0 if side_plus else -1.0
	var w := rng.randf_range(14.0, 28.0)
	var d := rng.randf_range(12.0, 24.0)
	var h := 0.0
	var gap := 0.0
	if row == 0:
		# 近排同侧间距 ~20m（near_step×2）：w 上限 20 保证相邻楼体不打架，
		# 楼顶 AC 机组也不会埋进邻楼墙里
		w = rng.randf_range(13.0, 20.0)
		d = rng.randf_range(10.0, 18.0)
		h = rng.randf_range(24.0, 62.0)
		if landmark and rng.randf() < 0.35:
			h *= 1.35
		gap = rng.randf_range(6.0, 13.0)
	else:
		# 后排同侧间距 ~26m：w 上限 24；后排 h 上限 96 负责天际线
		w = rng.randf_range(18.0, 24.0)
		d = rng.randf_range(16.0, 26.0)
		h = rng.randf_range(38.0, 96.0)
		if landmark:
			h *= rng.randf_range(1.0, 1.7)
		gap = rng.randf_range(30.0, 62.0)
	# 楼体 yaw 对齐赛道切线：局部 Z(=d) 沿路、局部 X(=w) 横跨路，
	# 因此横向半宽是 w*0.5 而不是 d*0.5——否则大 w 小 d 时楼体侧面压进路面。
	var lateral := half + w * 0.5 + gap
	if lateral + w * 0.5 > half + 88.0:
		return
	var pos: Vector3 = (frame["pos"] as Vector3) + (frame["side"] as Vector3) * lateral * side_sign
	if Terrain.active:
		pos.y = Terrain.height_at(pos)
	# 跨折返段净空：赛道是闭环，会折返贴近自己——楼体相对本段合法，
	# 但裙楼/楼体的最大半对角线可能探进附近另一段路。取全环最小距离，
	# 要求「任何地面顶点」都保持在路面边界 +0.5m 之外（与穿模审计同标准）。
	var pod_diag := 0.5 * sqrt((w + 2.8) * (w + 2.8) + (d + 2.8) * (d + 2.8))
	if VenueKit.distance_to_track(path, pos) < pod_diag + half + 0.6:
		return
	if not VenueKit.clear_of_track(path, pos, 3.5):
		return
	# 建筑基座要落在平地/缓坡上：离路 12m 内仍属赛道平台
	if absf(Terrain.height_at(pos)) > 6.0 and Terrain.active and row == 0:
		return
	# 与已登记实体互斥：发卡弯内侧会把同侧楼压到 5m 间距，楼体互插后
	# 楼顶 AC/压顶全部埋进邻楼；先查后登记（顺序摆放 → 楼群零重叠）。
	# 楼间用楼面矩形 SAT：对角圆会把 18-20m 合法间距的邻楼链式误杀。
	var own_rad := 0.5 * sqrt(w * w + d * d) + 1.4
	var yaw := atan2((frame["tangent"] as Vector3).x, (frame["tangent"] as Vector3).z) + rng.randf_range(-0.16, 0.16)
	var basis := Basis(Vector3.UP, yaw)
	var has_podium := rng.randf() < 0.72
	var poke := 1.4 if has_podium else 0.33
	if not RealAssetKit.rect_rect_clear(pos, w * 0.5 + poke, d * 0.5 + poke, yaw):
		return
	# 量块楼也登记为实体：VenueKit 广告牌/灯塔/裁判位、岩石散点靠这个躲楼
	# （真实模型楼在 _try_city_model 登记，量块楼此前漏了，广告牌扎进楼体）
	RealAssetKit.register_solid(pos, own_rad)
	# 楼面矩形单独登记（含裙楼 1.4 / 角柱翅 0.33 的外扩）：霓虹招牌按矩形
	# 判贴墙——互斥圆用对角半径会把楼前空地整个判成「楼里」
	RealAssetKit.register_face_rect(pos, w * 0.5 + poke, d * 0.5 + poke, yaw)
	var mat_idx := rng.randi() % facades.size()
	var mat: StandardMaterial3D = facades[mat_idx]
	var body := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(w, h, d)
	body.mesh = bm
	body.material_override = mat
	body.transform = Transform3D(basis, pos + Vector3(0.0, h * 0.5, 0.0))
	body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF if (h > 64.0 or row == 1) \
		else GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	body.set_meta("audit_cat", "building")
	root.add_child(body)
	var roof := MeshInstance3D.new()
	var rm := BoxMesh.new()
	rm.size = Vector3(w + 0.8, 1.0, d + 0.8)
	roof.mesh = rm
	roof.material_override = ctx["roof_mat"] as Material
	roof.transform = Transform3D(basis, pos + Vector3(0.0, h + 0.5, 0.0))
	roof.set_meta("audit_cat", "building")
	root.add_child(roof)
	# --- 楼体细节：裙楼 / 退台先算好（屋顶构件要锚在退台顶上），再挂细节 ---
	var podium_groups: Array = ctx["podium_groups"] as Array
	var tier_groups: Array = ctx["tier_groups"] as Array
	var b := basis
	# 退台堆叠顶面：高层楼（h>34）有退台，屋顶 AC/压顶/尖塔如果还锚在
	# 主体楼顶 h，会整只埋进退台体里（审计 XSEC pen=顶点全数 = 完全不可见）
	var stack_top := h
	if has_podium:
		var pod_h := rng.randf_range(5.5, 9.0)
		(podium_groups[mat_idx] as Array).append(Transform3D(
			b * Basis.from_scale(Vector3(w + 2.8, pod_h, d + 2.8)),
			pos + Vector3(0.0, pod_h * 0.5, 0.0)))
	if h > 34.0:
		var t1h := h * rng.randf_range(0.10, 0.18)
		(tier_groups[mat_idx] as Array).append(Transform3D(
			b * Basis.from_scale(Vector3(w * 0.80, t1h, d * 0.80)),
			pos + Vector3(0.0, h + t1h * 0.5, 0.0)))
		stack_top = h + t1h
		if h > 64.0:
			var t2h := h * rng.randf_range(0.05, 0.10)
			(tier_groups[mat_idx] as Array).append(Transform3D(
				b * Basis.from_scale(Vector3(w * 0.56, t2h, d * 0.56)),
				pos + Vector3(0.0, h + t1h + t2h * 0.5, 0.0)))
			stack_top += t2h
	var ac_xforms: Array = ctx["ac_xforms"] as Array
	var ac_y := h + 1.5 if stack_top <= h else stack_top + 0.55
	# 偏移收到 ±0.18：近排楼同侧间距只有 ~20m，±0.3w 的机组会探进邻楼墙体。
	# h>72 的楼顶正中有尖塔（0.55 宽）：偏移可为 0 的机组会骑进塔身，
	# 有塔时横向偏移强制 ≥2.2m 绕开塔柱。
	for k in rng.randi_range(1, 3):
		var ox := rng.randf_range(-w * 0.18, w * 0.18)
		if h > 72.0:
			ox = (2.2 + rng.randf_range(0.0, maxf(w * 0.18 - 2.2, 0.0))) \
				* (1.0 if rng.randf() < 0.5 else -1.0)
		var off := basis * Vector3(ox, ac_y, rng.randf_range(-d * 0.18, d * 0.18))
		ac_xforms.append(Transform3D(basis, pos + off))
	# 高楼屋顶霓虹压顶 + 航空障碍灯
	var neon_mats: Dictionary = ctx["neon_mats"] as Dictionary
	if (landmark and h > 70.0) or (row == 0 and rng.randf() < 0.4):
		var neon_color := accent if rng.randf() < 0.5 else accent.lerp(Color(0.5, 0.8, 1.0), rng.randf_range(0.3, 0.9))
		var key := neon_color.to_html()
		if not neon_mats.has(key):
			neon_mats[key] = _emissive_mat(neon_color, 2.2)
		# 霓虹压顶必须是空心环：实心箱会把坐在退台顶的 AC 机组整个封进去
		var crown_y := h + 0.2 if stack_top <= h else stack_top + 0.45
		var ct := 0.34
		# 退台楼的最顶台比主体窄，环还按主体宽做会悬在窄台外圈半空
		# （审计 36 处 FLOAT 的根因），环宽跟随最顶台
		var ring_x := w + 1.2
		var ring_z := d + 1.2
		if stack_top > h:
			var ts := 0.56 if h > 64.0 else 0.80
			ring_x = w * ts + 1.2
			ring_z = d * ts + 1.2
		for seg in [
			[Vector3(ring_x, 0.7, ct), Vector3(0.0, 0.0, (ring_z - ct) * 0.5)],
			[Vector3(ring_x, 0.7, ct), Vector3(0.0, 0.0, -(ring_z - ct) * 0.5)],
			[Vector3(ct, 0.7, ring_z - ct * 2.0), Vector3((ring_x - ct) * 0.5, 0.0, 0.0)],
			[Vector3(ct, 0.7, ring_z - ct * 2.0), Vector3(-(ring_x - ct) * 0.5, 0.0, 0.0)],
		]:
			var crown := MeshInstance3D.new()
			var crown_mesh := BoxMesh.new()
			crown_mesh.size = seg[0] as Vector3
			crown.mesh = crown_mesh
			crown.material_override = neon_mats[key]
			crown.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			crown.transform = Transform3D(basis, pos + (basis * (seg[1] as Vector3))
				+ Vector3(0.0, crown_y, 0.0))
			crown.set_meta("audit_cat", "building")
			root.add_child(crown)
	var fin_xforms: Array = ctx["fin_xforms"] as Array
	for cx: float in [-0.5, 0.5]:
		for cz: float in [-0.5, 0.5]:
			var corner := b * Vector3(cx * w, h * 0.46, cz * d)
			fin_xforms.append(Transform3D(
				b * Basis.from_scale(Vector3(0.65, h * 0.92, 0.65)),
				pos + corner))
	if row == 0:
		var ledge_xforms: Array = ctx["ledge_xforms"] as Array
		var floors := int(clampf(floor(h / 12.0), 1.0, 6.0))
		for fl in floors:
			var fy := 7.0 + float(fl) * 12.0
			if fy > h - 2.0:
				break
			ledge_xforms.append(Transform3D(
				b * Basis.from_scale(Vector3(w + 0.7, 0.28, d + 0.7)),
				pos + Vector3(0.0, fy, 0.0)))
	var neon_xforms: Array = ctx["neon_xforms"] as Array
	if rng.randf() < 0.55 or landmark:
		neon_xforms.append(Transform3D(
			b * Basis.from_scale(Vector3(w + 2.9, 0.28, d + 2.9)),
			pos + Vector3(0.0, 7.2, 0.0)))
	if h > 72.0:
		var sh := rng.randf_range(4.0, 12.0)
		var spire_xforms: Array = ctx["spire_xforms"] as Array
		spire_xforms.append(Transform3D(
			b * Basis.from_scale(Vector3(0.55, sh, 0.55)),
			pos + Vector3(0.0, stack_top - 0.1 + sh * 0.5, 0.0)))
	if bool(ctx["attach_facades"]) and row == 0 and RealAssetKit.has("facade_real") and rng.randf() < 0.35:
		var fd := RealAssetKit.size("facade_real")
		var fw := minf(w * 1.02, 36.0)
		var fh := clampf(h * 0.72, 8.0, 30.0)
		var toward := -(frame["side"] as Vector3) * side_sign
		var sx := fw / maxf(fd.x, 0.01)
		var sy := fh / maxf(fd.y, 0.01)
		var fb := Basis(Vector3.UP, atan2(toward.x, toward.z)).scaled(Vector3(sx, sy, 1.0))
		# 裙楼比楼体宽 1.4m：立面贴片只出楼面 0.9m 会被埋进裙楼里
		var fp: Vector3 = pos + toward * (d * 0.5 + (2.3 if has_podium else 0.9))
		fp.y = pos.y + fh * 0.5
		var facade_node := RealAssetKit.place_unique(root, "facade_real",
			Transform3D(fb, fp), "CityFacade_%d" % rng.randi(), {})
		if facade_node != null and night:
			# 夜里只压暗保留真实立面细节；make_emissive 会把整张白天照片
			# （亮墙面）当自发光贴出来，一整面「发光白墙」就是这么来的
			RealAssetKit.darken_albedo(facade_node, 0.42)
	ctx["nodes_placed"] = int(ctx.get("nodes_placed", 0)) + 2


static func _city_flush(ctx: Dictionary, stats: Dictionary) -> void:
	var root: Node3D = ctx["root"] as Node3D
	var facades: Array = ctx["facades"] as Array
	var roof_mat: Material = ctx["roof_mat"] as Material
	var accent: Color = ctx["accent"] as Color
	var podium_groups: Array = ctx["podium_groups"] as Array
	var tier_groups: Array = ctx["tier_groups"] as Array
	for gi in 4:
		_box_multimesh(root, "CityPodium_%d" % gi, facades[gi], podium_groups[gi])
		_box_multimesh(root, "CityTier_%d" % gi, facades[gi], tier_groups[gi])
	_box_multimesh(root, "CityCornerFins", roof_mat, ctx["fin_xforms"] as Array)
	_box_multimesh(root, "CityLedges", roof_mat, ctx["ledge_xforms"] as Array)
	_box_multimesh(root, "CityEntranceNeon",
		_emissive_mat(accent.lerp(Color(0.4, 0.8, 1.0), 0.35), 1.8), ctx["neon_xforms"] as Array)
	_box_multimesh(root, "CitySpires", roof_mat, ctx["spire_xforms"] as Array)
	var ac_xforms: Array = ctx["ac_xforms"] as Array
	if not ac_xforms.is_empty():
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = ctx["ac_mesh"] as Mesh
		mm.instance_count = ac_xforms.size()
		for i in ac_xforms.size():
			mm.set_instance_transform(i, ac_xforms[i] as Transform3D)
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "CityRooftopUnits"
		mmi.multimesh = mm
		mmi.material_override = PbrAssets.metal(Vector2(1.5, 1.5))
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(mmi)
	stats["nodes"] = int(stats.get("nodes", 0)) + 2
	stats["instances"] = int(stats.get("instances", 0)) + 2
	stats["scenery"] = int(stats.get("scenery", 0)) + int(ctx.get("nodes_placed", 0))


static func _build_snow_peaks(container: Node3D, path: TrackPath, rng: RandomNumberGenerator,
		stats: Dictionary) -> void:
	# 近景雪峰：用正常受光材质 + 雪顶，不再用无光照白色圆锥（会变成遮住天空的白色三角形）
	var rock_mat := StandardMaterial3D.new()
	rock_mat.albedo_color = Color(0.26, 0.30, 0.38)
	rock_mat.roughness = 0.92
	rock_mat.metallic = 0.0
	var snow_mat := StandardMaterial3D.new()
	snow_mat.albedo_color = Color(0.86, 0.91, 0.96)
	snow_mat.roughness = 0.55
	snow_mat.metallic = 0.0
	var rock_mesh := CylinderMesh.new()
	rock_mesh.top_radius = 0.0
	rock_mesh.bottom_radius = 1.0
	rock_mesh.height = 1.0
	rock_mesh.radial_segments = 7
	rock_mesh.rings = 1
	var snow_mesh := CylinderMesh.new()
	snow_mesh.top_radius = 0.0
	snow_mesh.bottom_radius = 0.55
	snow_mesh.height = 0.42
	snow_mesh.radial_segments = 7
	snow_mesh.rings = 1
	var peaks: Array[Transform3D] = []
	var snow_caps: Array[Transform3D] = []
	for i in 24:
		var frame := path.frame_at(rng.randf() * path.total_length)
		if frame.is_empty():
			continue
		var base_pos: Vector3 = frame["pos"]
		var side: Vector3 = frame["side"]
		var tangent: Vector3 = frame["tangent"]
		var sign := 1.0 if rng.randf() < 0.5 else -1.0
		var lateral := rng.randf_range(220.0, 560.0)
		var pos := base_pos + side * lateral * sign + tangent * rng.randf_range(-80.0, 80.0)
		var ground := 0.0
		if Terrain.active:
			ground = Terrain.height_at(pos)
		var h := rng.randf_range(80.0, 180.0)
		var base := h * rng.randf_range(0.55, 0.90)
		var yaw := rng.randf() * TAU
		var basis := Basis(Vector3.UP, yaw).scaled(Vector3(base, h, base))
		peaks.append(Transform3D(basis, Vector3(pos.x, ground + h * 0.5 - 4.0, pos.z)))
		var snow_basis := Basis(Vector3.UP, yaw).scaled(Vector3(base * 0.56, h * 0.46, base * 0.56))
		snow_caps.append(Transform3D(snow_basis, Vector3(pos.x, ground + h * 0.80, pos.z)))
	_prop_mm(container, rock_mesh, rock_mat, peaks, [], "SnowPeakRock", stats, 3000.0, false)
	_prop_mm(container, snow_mesh, snow_mat, snow_caps, [], "SnowPeakCap", stats, 3000.0, false)


static func _build_cc0_boulders(container: Node3D, path: TrackPath, rng: RandomNumberGenerator,
		stats: Dictionary) -> void:
	var packed := load("res://assets/thirdparty/polyhaven/models/boulder_01/boulder_01_lod.glb") as PackedScene
	if packed == null:
		return
	var template := packed.instantiate() as Node3D
	if template == null:
		return
	var entries: Array = []
	_collect_cc0_meshes(template, template, entries)
	var transforms: Array[Transform3D] = []
	for i in 7:
		var frame := path.frame_at(rng.randf() * path.total_length)
		if frame.is_empty():
			continue
		var side_sign := 1.0 if rng.randf() < 0.62 else -1.0
		var lateral := rng.randf_range(17.0, 62.0) * side_sign
		var pos: Vector3 = (frame["pos"] as Vector3) + (frame["side"] as Vector3) * lateral
		pos.y = Terrain.height_at(pos) - 0.08
		if not VenueKit.clear_of_track(path, pos, 4.0):
			continue
		var scale_value := rng.randf_range(0.9, 2.8)
		var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3.ONE * scale_value)
		transforms.append(Transform3D(basis, pos))
	for entry in entries:
		var mi: MeshInstance3D = entry["node"]
		if mi.mesh == null:
			continue
		var mat: Material = null
		if mi.mesh.get_surface_count() > 0:
			mat = mi.mesh.surface_get_material(0)
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = mi.mesh
		mm.instance_count = transforms.size()
		for i in transforms.size():
			mm.set_instance_transform(i, transforms[i] * (entry["rel"] as Transform3D))
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.material_override = mat
		mmi.name = "CoastBoulders"
		container.add_child(mmi)
		stats["nodes"] = int(stats.get("nodes", 0)) + 1
		stats["instances"] = int(stats.get("instances", 0)) + transforms.size()
	template.free()


static func _build_real_flora(container: Node3D, path: TrackPath, rng: RandomNumberGenerator,
		stats: Dictionary, asset: String, count: int, lateral_min: float, lateral_max: float,
		height_min: float, height_max: float, extra_clear: float, vis_end: float = 500.0) -> void:
	var transforms: Array[Transform3D] = []
	var placed := 0
	var attempts := count * 3
	while transforms.size() < count and placed < attempts:
		placed += 1
		var frame := path.frame_at(rng.randf() * path.total_length)
		if frame.is_empty():
			continue
		var side_sign := 1.0 if rng.randf() < 0.5 else -1.0
		var lateral := rng.randf_range(lateral_min, lateral_max) * side_sign
		var pos: Vector3 = (frame["pos"] as Vector3) + (frame["side"] as Vector3) * lateral
		pos.y = Terrain.height_at(pos) if Terrain.active else 0.0
		if not VenueKit.clear_of_track(path, pos, extra_clear):
			continue
		var target_h := rng.randf_range(height_min, height_max)
		var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(
			Vector3.ONE * RealAssetKit.scale_for_height(asset, target_h))
		transforms.append(Transform3D(basis, pos))
	VenueKit._place_repeated_chunked(container, asset, transforms, stats, Color.WHITE, Color.WHITE, false)
	for node in container.find_children("*", "MultiMeshInstance3D", true, false):
		var mmi := node as MultiMeshInstance3D
		if String(mmi.name).begins_with(asset):
			mmi.visibility_range_end = vis_end * (0.75 + float(Settings.index) * 0.25)
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


static func _build_real_grass(container: Node3D, path: TrackPath, rng: RandomNumberGenerator,
		stats: Dictionary) -> void:
	var packed := load("res://assets/venues/grass_real.glb") as PackedScene
	if packed == null:
		return
	var template := packed.instantiate() as Node3D
	var entries: Array = []
	_collect_cc0_meshes(template, template, entries)
	var transforms: Array[Transform3D] = []
	var count := int(round(110.0 * clampf(Settings.content_scale(), 0.3, 1.5)))
	for i in count:
		var frame := path.frame_at(rng.randf() * path.total_length)
		if frame.is_empty():
			continue
		var side_sign := 1.0 if rng.randf() < 0.5 else -1.0
		var lateral := rng.randf_range(7.5, 30.0) * side_sign
		var pos: Vector3 = (frame["pos"] as Vector3) + (frame["side"] as Vector3) * lateral
		pos.y = Terrain.height_at(pos) + 0.02
		if not VenueKit.clear_of_track(path, pos, 1.2):
			continue
		var sbasis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3.ONE * rng.randf_range(0.22, 0.42))
		transforms.append(Transform3D(sbasis, pos))
	var groups: Array = []
	for g in 16:
		groups.append([])
	for xform in transforms:
		var origin := xform.origin
		var gx := clampi(int((origin.x + 900.0) / 180.0), 0, 3)
		var gz := clampi(int((origin.z + 900.0) / 180.0), 0, 3)
		(groups[gx * 4 + gz] as Array).append(xform)
	for entry in entries:
		var mi: MeshInstance3D = entry["node"]
		if mi.mesh == null:
			continue
		for group in groups:
			if (group as Array).is_empty():
				continue
			var typed: Array[Transform3D] = []
			for xform in group:
				typed.append(xform as Transform3D)
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.mesh = mi.mesh
			mm.instance_count = typed.size()
			for i in typed.size():
				mm.set_instance_transform(i, typed[i] * (entry["rel"] as Transform3D))
			var mmi := MultiMeshInstance3D.new()
			mmi.multimesh = mm
			mmi.name = "RealGrass"
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mmi.visibility_range_end = 120.0
			container.add_child(mmi)
			stats["nodes"] = int(stats.get("nodes", 0)) + 1
			stats["instances"] = int(stats.get("instances", 0)) + typed.size()
	template.free()


static func _build_shore_rocks(container: Node3D, path: TrackPath, rng: RandomNumberGenerator,
		stats: Dictionary) -> void:
	var packed := load("res://assets/thirdparty/polyhaven/models/boulder_01/boulder_01_lod.glb") as PackedScene
	if packed == null:
		return
	var template := packed.instantiate() as Node3D
	var entries: Array = []
	_collect_cc0_meshes(template, template, entries)
	var transforms: Array[Transform3D] = []
	var count := int(round(16.0 * clampf(Settings.content_scale(), 0.3, 1.5)))
	for i in count:
		var angle := rng.randf() * TAU
		var radius := rng.randf_range(530.0, 660.0)
		var pos := Vector3(cos(angle) * radius, -0.6, sin(angle) * radius)
		pos.y = Terrain.height_at(pos) - 0.6
		if not VenueKit.clear_of_track(path, pos, 15.0):
			continue
		var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3.ONE * rng.randf_range(2.0, 6.0))
		transforms.append(Transform3D(basis, pos))
	for entry in entries:
		var mi: MeshInstance3D = entry["node"]
		if mi.mesh == null:
			continue
		var mat: Material = null
		if mi.mesh.get_surface_count() > 0:
			mat = mi.mesh.surface_get_material(0)
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = mi.mesh
		mm.instance_count = transforms.size()
		for i in transforms.size():
			mm.set_instance_transform(i, transforms[i] * (entry["rel"] as Transform3D))
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.material_override = mat
		mmi.name = "ShoreRocks"
		container.add_child(mmi)
		stats["nodes"] = int(stats.get("nodes", 0)) + 1
		stats["instances"] = int(stats.get("instances", 0)) + transforms.size()
	template.free()


## 全部地表植被只用 Poly Haven CC0 真实摄影测量资产。
## 原来 780 簇手建低模 grass_clump.glb（11KB 胶囊草）已彻底停用。
##
## 两个关键点（之前踩过的坑）：
##   1. 密度必须按「沿赛道每米多少丛」定义。按「整条赛道共 N 个」定义时，
##      3km 环线摊下来十几米才有一丛草，视觉上等于没有。
##   2. 缩放必须按「目标高度」反推。这批 CC0 资产大多是局部扫描（草簇
##      41cm、苔藓 4cm），按包围盒宽度归一化会越缩越小。
static func _build_real_ground_cover(container: Node3D, path: TrackPath,
		rng: RandomNumberGenerator, stats: Dictionary) -> void:
	var content := clampf(Settings.content_scale(), 0.3, 1.5)
	var half := path.half_width
	# 铺满整片草坪的真实 3D 草簇（减面版，近高远矮、分布均匀）
	_scatter_lawn_band(container, path, rng, stats, "grass_medium02_lod", "RealGrassEdge",
		1.8, 10.0, int(round(1600.0 * content)), 0.85, 1.45, 170.0, false)
	_scatter_lawn_band(container, path, rng, stats, "grass_medium02_lod", "RealGrassNear",
		10.0, 42.0, int(round(9200.0 * content)), 0.85, 1.55, 360.0, false)
	_scatter_lawn_band(container, path, rng, stats, "grass_medium02_lod", "RealGrassMid",
		42.0, 100.0, int(round(6200.0 * content)), 0.60, 1.05, 560.0, false)
	_scatter_lawn_band(container, path, rng, stats, "grass_bermuda_lod", "RealGrassFar",
		100.0, 240.0, int(round(3200.0 * content)), 0.38, 0.72, 780.0, true)


static func _scatter_lawn_band(container: Node3D, path: TrackPath, rng: RandomNumberGenerator,
		stats: Dictionary, asset: String, prefix: String, from_lat: float, to_lat: float,
		count: int, hmin: float, hmax: float, vis_end: float, align: bool) -> void:
	if not RealAssetKit.has(asset) or count <= 0:
		return
	var xforms: Array[Transform3D] = []
	var half := path.half_width
	var attempts := count * 4
	while xforms.size() < count and attempts > 0:
		attempts -= 1
		var frame := path.frame_at(rng.randf() * path.total_length)
		if frame.is_empty():
			continue
		var side_sign := 1.0 if rng.randf() < 0.5 else -1.0
		var lateral := half + rng.randf_range(from_lat, to_lat)
		var pos: Vector3 = (frame["pos"] as Vector3) + (frame["side"] as Vector3) * lateral * side_sign
		pos += (frame["tangent"] as Vector3) * rng.randf_range(-14.0, 14.0)
		pos.y = Terrain.height_at(pos) - 0.02
		# 草只在护栏之外：赛道上、路肩上都不长草
		if not VenueKit.clear_of_track(path, pos, 3.0):
			continue
		# 海岸赛道不要让草长到沙滩/海里
		if path.id == "coast" and Vector2(pos.x, pos.z).length() > 520.0:
			continue
		var fade := clampf((lateral - half - from_lat) / maxf(to_lat - from_lat, 0.001), 0.0, 1.0)
		var target_h := rng.randf_range(hmin, hmax) * (1.0 - fade * 0.35)
		var sc := RealAssetKit.scale_for_height(asset, maxf(target_h, 0.15))
		var yaw := rng.randf() * TAU
		if align:
			var tangent: Vector3 = frame["tangent"]
			yaw = atan2(tangent.x, tangent.z) + PI * 0.5
		var basis := Basis(Vector3.UP, yaw).scaled(Vector3.ONE * sc)
		xforms.append(Transform3D(basis, pos))
	RealAssetKit.place_chunked(container, asset, xforms, prefix, vis_end, false, stats)
	# 草在暗调光照下容易变成黑块，统一提亮一点让草坪看起来是草
	for node in container.find_children("*", "MultiMeshInstance3D", true, false):
		var mmi := node as MultiMeshInstance3D
		if not String(mmi.name).begins_with(prefix):
			continue
		var src := mmi.material_override
		if src is StandardMaterial3D:
			var mat := (src as StandardMaterial3D).duplicate() as StandardMaterial3D
			mat.albedo_color = Color(1.25, 1.42, 1.05)
			mat.roughness = 0.95
			mmi.material_override = mat


static func _collect_cc0_meshes(node: Node, root: Node3D, out: Array) -> void:
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		var t := Transform3D.IDENTITY
		var cur: Node = node
		while cur != null and cur != root:
			if cur is Node3D:
				t = (cur as Node3D).transform * t
			cur = cur.get_parent()
		out.append({"node": node, "rel": t})
	for child in node.get_children():
		_collect_cc0_meshes(child, root, out)


# ===========================================================================
# 第三阶段：真实 CC0 地标与路边道具
# ===========================================================================
# 新增素材全部来自 Poly Haven（CC0 1.0），由
#   tools/fetch_cc0_models_batch.py  下载源模型
#   tools/blender/decimate_hq_scenery.py  减面导出 assets/venues/*.glb
# 清单（asset id -> venues 文件）：
#   modular_wooden_pier            -> pier_real          海滨栈桥 / 观景木台
#   dutch_ship_large_01            -> ship_real          帆船地标（海岸/港湾/冰川）
#   fir_tree_01                    -> realtree_fir_full / realtree_fir_lod  冷杉
#   street_lamp_01                 -> street_lamp_01_real  铸铁路灯
#   fire_hydrant                   -> hydrant_real       消防栓
#   utility_box_02                 -> utility_box_real   配电箱
#   covered_car                    -> car_wreck_real     蒙布废弃车
#   old_tyre                       -> tyre_real          轮胎墙
#   ocean_buoy                     -> buoy_real          航标浮标
#   lateral_sea_marker             -> sea_marker_real    航道标
#   modular_industrial_pipes_01    -> industrial_pipes   工业管道
#   barrel_03                      -> barrel_real        油桶
# 木屋/龙门吊/高架/冰柱/炼油塔没有现成 CC0 单个模型：用 PbrAssets 的真实
# CC0 PBR 材质做低模组合件（都是基础设施/地貌，不是「主要建筑」）；
# 主要建筑（城市高楼/厂房/仓库）只用真实 CC0 立面与材质。

static func _emissive_mat(color: Color, energy: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = energy
	mat.disable_receive_shadows = true
	return mat


## 与 main.gd 菜单机位完全一致的「特色弯」：曲率最大处前 6 个采样点。
## 所有地标都优先围绕这个点布置，保证菜单截图和实机都能看到。
static func _hero_spot(path: TrackPath) -> Dictionary:
	var m := path.samples.size()
	if m < 60:
		return {}
	var hero_i := 0
	var hero_c := 0.0
	for i in range(20, m - 20):
		var c := absf(path.curvatures[i])
		if c > hero_c:
			hero_c = c
			hero_i = i
	var spot_i := maxi(hero_i - 6, 8)
	var f := path.frame_at(path.accumulated[spot_i])
	if f.is_empty():
		return {}
	var curv := path.curvatures[spot_i]
	var out_side: Vector3 = (f["side"] as Vector3) * (1.0 if curv >= 0.0 else -1.0)
	f["hero_dist"] = path.accumulated[spot_i]
	f["outside"] = out_side
	f["inside"] = -out_side
	return f


static func _pos_of(frame: Dictionary, lateral: float, ahead: float = 0.0) -> Vector3:
	return (frame["pos"] as Vector3) + (frame["side"] as Vector3) * lateral \
		+ (frame["tangent"] as Vector3) * ahead


## 复刻 main.gd 的菜单机位：相机在特色弯外侧、车后 6m，再用「把车压到画面
## 左 32%」的 5 次 look 修正转向。菜单截图用的就是这台相机，地标放进它的
## 视锥才看得见（只看赛道切线方向会偏 30° 以上，之前地标全落在画面外）。
static func _menu_camera(path: TrackPath, hero: Dictionary) -> Dictionary:
	var half := path.half_width
	var car_pos: Vector3 = (hero["pos"] as Vector3) + (hero["side"] as Vector3) * (-half * 0.28)
	var cam_pos: Vector3 = car_pos + (hero["outside"] as Vector3) * 7.5 \
		- (hero["tangent"] as Vector3) * 6.0 + Vector3(0.0, 2.05, 0.0)
	var look: Vector3 = car_pos + (hero["tangent"] as Vector3) * 5.5 + Vector3(0.0, 0.85, 0.0)
	var car_pt := car_pos + Vector3(0.0, 0.85, 0.0)
	var aspect := 1280.0 / 720.0
	var fov := 46.0
	for it in 5:
		var basis := _look_basis(cam_pos, look)
		var local := basis.transposed() * (car_pt - cam_pos)
		var depth := -local.z
		var ndc := 0.0
		if depth > 0.01:
			ndc = local.x / (tan(deg_to_rad(fov * 0.5)) * depth * aspect)
		var diff := ndc - (-0.36)
		if absf(diff) < 0.015:
			break
		var cam_right := basis.x.normalized()
		var dist := cam_pos.distance_to(car_pos)
		var half_w := tan(deg_to_rad(fov * 0.5)) * dist * aspect
		look += cam_right * (diff * half_w * 0.45)
	var final_basis := _look_basis(cam_pos, look)
	return {
		"pos": cam_pos,
		"view": -final_basis.z.normalized(),
		"right": final_basis.x.normalized(),
		"basis": final_basis,
	}


static func _look_basis(eye: Vector3, target: Vector3) -> Basis:
	var z := (eye - target).normalized()
	var x := Vector3.UP.cross(z)
	if x.length_squared() < 0.000001:
		x = Vector3.RIGHT
	x = x.normalized()
	var y := z.cross(x).normalized()
	return Basis(x, y, z)


## 菜单相机正前方 ahead 米、画面右侧 lateral 米处的世界坐标。
## ahead:lateral 建议在 2:1 以内（74° 水平视角），远端 3:1 也可以。
static func _menu_stage(path: TrackPath, hero: Dictionary, ahead: float, lateral: float) -> Vector3:
	var cam := _menu_camera(path, hero)
	return (cam["pos"] as Vector3) + (cam["view"] as Vector3) * ahead \
		+ (cam["right"] as Vector3) * lateral


## 菜单相机视野内的一段赛道（用于山地/冰川等起伏地形的近景地标：
## 直接按相机前方取点会落到抬高的山坡上，地标会跑到画面外/埋进山坡，
## 贴回赛道平坦走廊才稳定可见）。
static func _in_view_track_anchor(path: TrackPath, hero: Dictionary,
		ahead_min: float = 34.0, ahead_max: float = 130.0) -> Dictionary:
	var cam := _menu_camera(path, hero)
	var f := _track_point_in_view(path, hero, cam, ahead_min, ahead_max)
	if f.is_empty():
		f = path.frame_at(float(hero["hero_dist"]) + 46.0)
	return f


## 找一个「菜单相机看得见」的赛道点（用于必须横跨赛道的门架/天桥）。
static func _track_point_in_view(path: TrackPath, hero: Dictionary, cam: Dictionary,
		ahead_min: float, ahead_max: float) -> Dictionary:
	var view: Vector3 = cam["view"]
	var right: Vector3 = cam["right"]
	var cam_pos: Vector3 = cam["pos"]
	var best := {}
	var best_score := -1.0e9
	for dist_off in range(int(ahead_min), int(ahead_max) + 1, 6):
		var f := path.frame_at(float(hero["hero_dist"]) + float(dist_off))
		if f.is_empty():
			continue
		var rel: Vector3 = (f["pos"] as Vector3) - cam_pos
		var along := rel.dot(view)
		if along < 6.0:
			continue
		var ang := rad_to_deg(atan2(rel.dot(right), along))
		# 不硬性排除超过阈值的点：优先取「靠正中、距离适中」的赛道点，
		# 只把角度当罚分。否则弯道靠左/右时可能一个点都选不出来。
		var score := along - absf(ang) * 2.4
		if absf(ang) < 34.0:
			score += 40.0
		if score > best_score:
			best_score = score
			best = f
	return best


static func _ground_at(pos: Vector3, offset: float = 0.0) -> Vector3:
	var out := pos
	out.y = (Terrain.height_at(pos) if Terrain.active else 0.0) + offset
	return out


static func _mesh_lists(node: Node) -> Array:
	var out: Array = []
	if node is MeshInstance3D:
		out.append(node)
	for child in node.find_children("*", "MeshInstance3D", true, false):
		out.append(child)
	return out


static func _real_unique(container: Node3D, asset: String, xform: Transform3D,
		node_name: String, stats: Dictionary, vis_end: float = 1400.0,
		shadow: bool = true) -> Node3D:
	if not RealAssetKit.has(asset):
		return null
	var node := RealAssetKit.place_unique(container, asset, xform, node_name, stats)
	if node == null:
		return null
	var mul: float = 0.75 + float(Settings.index) * 0.25
	for item in _mesh_lists(node):
		var mi := item as MeshInstance3D
		mi.visibility_range_end = vis_end * mul
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadow \
			else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return node


## 按目标高度缩放摆放一个真实 CC0 资产。extra_scale 用来非等比拉伸。
static func _real_scaled(container: Node3D, asset: String, pos: Vector3, yaw: float,
		target_h: float, node_name: String, stats: Dictionary,
		extra_scale: Vector3 = Vector3.ONE, vis_end: float = 1400.0,
		shadow: bool = true) -> Node3D:
	if not RealAssetKit.has(asset):
		return null
	var s := RealAssetKit.scale_for_height(asset, maxf(target_h, 0.4))
	var basis := Basis(Vector3.UP, yaw).scaled(
		Vector3(s * extra_scale.x, s * extra_scale.y, s * extra_scale.z))
	return _real_unique(container, asset, Transform3D(basis, pos), node_name, stats, vis_end, shadow)


## 沿整条赛道随机撒真实 CC0 资产（MultiMesh + 分块视锥剔除）。
static func _scatter_real(container: Node3D, path: TrackPath, rng: RandomNumberGenerator,
		asset: String, count: int, lat_min: float, lat_max: float,
		hmin: float, hmax: float, prefix: String, vis_end: float,
		extra_clear: float = 5.0, y_off: float = 0.0, shadow: bool = false,
		stats: Dictionary = {}) -> void:
	if not RealAssetKit.has(asset) or count <= 0:
		return
	var xforms: Array[Transform3D] = []
	var attempts := count * 4
	while xforms.size() < count and attempts > 0:
		attempts -= 1
		var frame := path.frame_at(rng.randf() * path.total_length)
		if frame.is_empty():
			continue
		var lateral := rng.randf_range(lat_min, lat_max) * (1.0 if rng.randf() < 0.5 else -1.0)
		var pos := _ground_at(_pos_of(frame, lateral), y_off)
		if not VenueKit.clear_of_track(path, pos, extra_clear):
			continue
		var s := RealAssetKit.scale_for_height(asset, rng.randf_range(hmin, hmax))
		xforms.append(Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3.ONE * s), pos))
	RealAssetKit.place_chunked(container, asset, xforms, prefix, vis_end, shadow, stats)


## 围绕一个中心点（通常就是特色弯）撒资产。
static func _scatter_real_near(container: Node3D, path: TrackPath, rng: RandomNumberGenerator,
		asset: String, center: Vector3, count: int, r_min: float, r_max: float,
		hmin: float, hmax: float, prefix: String, vis_end: float,
		extra_clear: float = 6.0, y_off: float = 0.0, shadow: bool = false,
		stats: Dictionary = {}) -> void:
	if not RealAssetKit.has(asset) or count <= 0:
		return
	var xforms: Array[Transform3D] = []
	var attempts := count * 4
	while xforms.size() < count and attempts > 0:
		attempts -= 1
		var angle := rng.randf() * TAU
		var radius := rng.randf_range(r_min, r_max)
		var pos := center + Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
		pos = _ground_at(pos, y_off)
		if not VenueKit.clear_of_track(path, pos, extra_clear):
			continue
		var s := RealAssetKit.scale_for_height(asset, rng.randf_range(hmin, hmax))
		xforms.append(Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3.ONE * s), pos))
	RealAssetKit.place_chunked(container, asset, xforms, prefix, vis_end, shadow, stats)


## 用真实 CC0 几何 + 统一色调重染（黑岩柱 / 冷杉暗部等）。
static func _place_tinted(container: Node3D, asset: String, xforms: Array[Transform3D],
		prefix: String, tint: Color, vis_end: float, stats: Dictionary,
		cast_shadow: bool = false) -> void:
	if not RealAssetKit.has(asset) or xforms.is_empty():
		return
	var parts := RealAssetKit.surfaces(asset)
	var mul: float = 0.75 + float(Settings.index) * 0.25
	for pi in parts.size():
		var part: Dictionary = parts[pi]
		var mesh: Mesh = part["mesh"]
		var rel: Transform3D = part["rel"]
		var src: Material = part["material"]
		var mat := StandardMaterial3D.new()
		if src is StandardMaterial3D:
			mat = (src as StandardMaterial3D).duplicate() as StandardMaterial3D
		mat.albedo_color = tint
		var kept: Array[Transform3D] = []
		for xf in xforms:
			# rel 只含表面偏移，禁入区按主变换原点判断
			if RealAssetKit.keepout_clear(xf.origin, RealAssetKit.mesh_radius(mesh)):
				kept.append(xf)
		if kept.is_empty():
			continue
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = mesh
		mm.instance_count = kept.size()
		for i in kept.size():
			mm.set_instance_transform(i, kept[i] * rel)
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "%s_%d" % [prefix, pi]
		mmi.multimesh = mm
		mmi.material_override = mat
		mmi.visibility_range_end = vis_end * mul
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if cast_shadow \
			else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		container.add_child(mmi)
		stats["meshes"] = int(stats.get("meshes", 0)) + 1
		stats["instances"] = int(stats.get("instances", 0)) + kept.size()


## 程序化组合件（路灯底座/雪堆/旗杆/龙门吊等）统一入口：MultiMesh + 可见距离。
static func _prop_mm(container: Node3D, mesh: Mesh, material: Material,
		xforms: Array[Transform3D], colors: Array, node_name: String,
		stats: Dictionary, vis_end: float, shadow: bool = false) -> MultiMeshInstance3D:
	var mmi := _mk_multimesh(container, mesh, material, xforms, colors, node_name, stats)
	mmi.visibility_range_end = vis_end * (0.75 + float(Settings.index) * 0.25)
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadow \
		else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_tag_prop(mmi, node_name)
	return mmi


## 手搓 MultiMesh 道具（海滩伞、护栏柱、集装箱、龙门架…）不属于任何 glb 资产，
## 但用户同样希望在编辑器里能选中、搬走。用节点名当资产名 ——
## RealAssetKit.category_of 对认不出的名字一律返回 "prop"，正好能进可编辑集合。
static func _tag_prop(mmi: MultiMeshInstance3D, key: String) -> void:
	if mmi == null:
		return
	mmi.set_meta("decor_asset", key)
	mmi.set_meta("decor_group", "Prop_" + key)
	mmi.set_meta("decor_chunk", 0)


## 把某前缀的 MultiMesh 材质改成「漫反射贴图 → 自发光」（路灯/霓虹/熔岩）。
static func _glow_prefix(container: Node3D, prefix: String, energy: float,
		tint: Color = Color(1.0, 0.85, 0.55)) -> void:
	for node in container.find_children("*", "MultiMeshInstance3D", true, false):
		var mmi := node as MultiMeshInstance3D
		if not String(mmi.name).begins_with(prefix):
			continue
		var src := mmi.material_override
		if src is StandardMaterial3D:
			var mat := (src as StandardMaterial3D).duplicate() as StandardMaterial3D
			if mat.albedo_texture != null:
				mat.emission_enabled = true
				# 同 _city_window_material：默认 OP_ADD 会把贴图整体叠加发光，必须 MULTIPLY
				mat.emission_operator = BaseMaterial3D.EMISSION_OP_MULTIPLY
				mat.emission_texture = mat.albedo_texture
				mat.emission = tint
				mat.emission_energy_multiplier = energy
				mmi.material_override = mat


static func _water_patch(container: Node3D, center: Vector3, size: Vector2, yaw: float,
		deep: Color, shallow: Color, node_name: String) -> MeshInstance3D:
	var water := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = size
	water.mesh = plane
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/water.gdshader")
	mat.set_shader_parameter("deep_color", deep)
	mat.set_shader_parameter("shallow_color", shallow)
	mat.set_shader_parameter("crest_color", shallow.lightened(0.3))
	mat.set_shader_parameter("wave_scale", 0.12)
	mat.set_shader_parameter("wave_speed", 0.55)
	mat.set_shader_parameter("wave_height", 0.2)
	water.material_override = mat
	water.name = node_name
	water.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	water.transform = Transform3D(Basis(Vector3.UP, yaw), center)
	container.add_child(water)
	return water


static func _rect_clear(path: TrackPath, center: Vector3, tangent: Vector3, side: Vector3,
		half_t: float, half_s: float, extra: float) -> bool:
	for it in 3:
		for is_ in 3:
			var p: Vector3 = center + tangent * ((float(it) - 1.0) * half_t) \
				+ side * ((float(is_) - 1.0) * half_s)
			if not VenueKit.clear_of_track(path, p, extra):
				return false
	return true


static func _beam_xform(a: Vector3, b: Vector3, radius: float) -> Transform3D:
	var dir := b - a
	var length := maxf(dir.length(), 0.01)
	var up := dir / length
	var axis := Vector3.UP.cross(up)
	var basis: Basis
	if axis.length_squared() < 0.0001:
		basis = Basis(Vector3.UP, 0.0)
	else:
		basis = Basis(axis.normalized(), Vector3.UP.angle_to(up))
	return Transform3D(basis.scaled(Vector3(radius, length, radius)), (a + b) * 0.5)


## 霓虹灯带/招牌的自发光材质。颜色走 MultiMesh 的 instance custom data
## （INSTANCE_CUSTOM）——比顶点色可靠：StandardMaterial3D 的实例色受
## 材质/网格设置影响，custom data 在 spatial shader 里一定拿得到。
static func _neon_vertex_material() -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = """shader_type spatial;
render_mode unshaded, cull_disabled, fog_disabled;
varying vec4 neon_tint;
void vertex() {
	neon_tint = INSTANCE_CUSTOM;
}
void fragment() {
	ALBEDO = neon_tint.rgb;
	EMISSION = neon_tint.rgb * 2.6;
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = sh
	return mat


## 顶点色自发光材质（普通 MultiMesh 顶点色用，不依赖 instance custom data）。
static func _neon_color_material() -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = """shader_type spatial;
render_mode unshaded, cull_disabled, fog_disabled;
void fragment() {
	ALBEDO = COLOR.rgb;
	EMISSION = COLOR.rgb * 2.6;
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = sh
	return mat


## 带自定义数据（每实例颜色）的 MultiMesh。
static func _prop_mm_custom(container: Node3D, mesh: Mesh, material: Material,
		xforms: Array[Transform3D], colors: Array[Color], node_name: String,
		stats: Dictionary, vis_end: float, shadow: bool = false) -> MultiMeshInstance3D:
	var keep_idx := _keepout_keep_idx(mesh, xforms)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = mesh
	mm.instance_count = keep_idx.size()
	for i in keep_idx.size():
		var src: int = keep_idx[i]
		mm.set_instance_transform(i, xforms[src])
		mm.set_instance_custom_data(i, colors[src] if src < colors.size() else Color.WHITE)
	var mmi := MultiMeshInstance3D.new()
	mmi.name = node_name
	mmi.multimesh = mm
	mmi.material_override = material
	mmi.visibility_range_end = vis_end * (0.75 + float(Settings.index) * 0.25)
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadow \
		else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	container.add_child(mmi)
	_tag_prop(mmi, node_name)
	stats["meshes"] = int(stats["meshes"]) + 1
	stats["instances"] = int(stats["instances"]) + keep_idx.size()
	return mmi


## 按颜色分组用材质 albedo 染色（StandardMaterial3D 的可靠实例染色方案）。
## 禁入区过滤由下游 _mk_multimesh 统一执行。
static func _prop_mm_tinted(container: Node3D, mesh: Mesh, material: Material,
		xforms: Array[Transform3D], colors: Array[Color], node_name: String,
		stats: Dictionary, vis_end: float, shadow: bool = false) -> void:
	if xforms.is_empty():
		return
	var groups: Dictionary = {}
	for i in xforms.size():
		var c: Color = colors[i] if i < colors.size() else Color.WHITE
		var key := c.to_html(false)
		if not groups.has(key):
			groups[key] = {"color": c, "x": []}
		(groups[key]["x"] as Array).append(xforms[i])
	var idx := 0
	for key in groups:
		var group: Dictionary = groups[key]
		var typed: Array[Transform3D] = []
		for xf in (group["x"] as Array):
			typed.append(xf as Transform3D)
		var mat := material
		if material is StandardMaterial3D:
			mat = (material as StandardMaterial3D).duplicate() as StandardMaterial3D
			(mat as StandardMaterial3D).albedo_color = group["color"] as Color
		_prop_mm(container, mesh, mat, typed, [], "%s_%d" % [node_name, idx], stats, vis_end, shadow)
		idx += 1


static func _neon_label(container: Node3D, text: String, pos: Vector3, yaw: float,
		color: Color, size: float = 1.0) -> void:
	var label := Label3D.new()
	label.text = text
	label.font_size = 96
	label.pixel_size = 0.011 * size
	label.modulate = color
	label.outline_size = 14
	label.outline_modulate = Color(0.02, 0.02, 0.04, 0.9)
	label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	label.no_depth_test = false
	label.transform = Transform3D(Basis(Vector3.UP, yaw), pos)
	container.add_child(label)


static func _build_real_lamps(container: Node3D, path: TrackPath, rng: RandomNumberGenerator,
		stats: Dictionary, step: float, lateral: float, glow: bool) -> void:
	var asset := "street_lamp_01_real"
	if not RealAssetKit.has(asset):
		return
	var xforms: Array[Transform3D] = []
	var light_pos: Array[Vector3] = []
	var dist := rng.randf_range(0.0, step)
	var side := 1.0
	var yaw_scale := 1.85
	while dist < path.total_length:
		var f := path.frame_at(dist)
		if not f.is_empty():
			var pos := _ground_at(_pos_of(f, lateral * side))
			var yaw := atan2((f["tangent"] as Vector3).x, (f["tangent"] as Vector3).z)
			xforms.append(Transform3D(Basis(Vector3.UP, yaw).scaled(Vector3.ONE * yaw_scale), pos))
			# 光源挂灯头、往路面偏一点，光斑落在行车道上
			light_pos.append(pos + Vector3.UP * (RealAssetKit.size(asset).y * yaw_scale * 0.9)
				- (f["side"] as Vector3) * (side * 1.6))
		dist += step
		side = -side
	RealAssetKit.place_chunked(container, asset, xforms, "RealStreetLamps", 460.0, false, stats)
	if glow:
		_glow_prefix(container, "RealStreetLamps", 1.3, Color(1.0, 0.8, 0.5))
		# 夜里路面黑：灯罩自发光只是「看得见的灯」。灯头挂一个暖色 Omni——
		# 灯泡高悬路面 6m+, 照地自然形成大圆形光圈；也顺带照亮灯杆和邻街立面。
		# 注意 Compatibility 渲染器单个网格有实时光源数上限，灯的数量
		# 要控制在几十盏以内，密度由调用方的 step 决定。
		for p in light_pos:
			var head := OmniLight3D.new()
			head.light_color = Color(1.0, 0.84, 0.62)
			head.light_energy = 9.0
			head.omni_range = 40.0
			head.omni_attenuation = 1.2
			head.shadow_enabled = false
			head.position = p
			container.add_child(head)


# ---------------------------------------------------------------------------
# 海岸：木栈桥 / 帆船 / 防波堤 / 浮标 / 沙滩伞 / 观景平台
# ---------------------------------------------------------------------------

static func _build_coast_landmarks(container: Node3D, path: TrackPath,
		rng: RandomNumberGenerator, stats: Dictionary) -> void:
	var hero := _hero_spot(path)
	# --- 1) 找到赛道离海岸最远的采样点（半径最大），作为栈桥/船的位置 ---
	var rim_i := 0
	var rim_r := -1.0
	for i in range(0, path.samples.size(), 2):
		var s: Vector3 = path.samples[i]
		var r := Vector2(s.x, s.z).length()
		if r > rim_r:
			rim_r = r
			rim_i = i
	var rim_pos: Vector3 = path.samples[rim_i]
	var sea_dir := Vector3(rim_pos.x, 0.0, rim_pos.z).normalized()
	var along_shore := Vector3(-sea_dir.z, 0.0, sea_dir.x)
	var shore_yaw := atan2(sea_dir.x, sea_dir.z)
	# --- 2) 真实 CC0 模块化木栈桥：3 段从沙滩伸进海里 ---
	for k in 5:
		var radius := 552.0 + float(k) * 18.0
		var lateral_off := float(k - 3) * 26.0 + rng.randf_range(-4.0, 4.0)
		var p := sea_dir * radius + along_shore * lateral_off
		p.y = 0.35 - float(k) * 0.03
		var yaw := shore_yaw + rng.randf_range(-0.18, 0.18) + (PI if k % 2 == 1 else 0.0)
		var b := Basis(Vector3.UP, yaw).scaled(Vector3(1.2, 1.1, 1.35))
		_real_unique(container, "pier_real", Transform3D(b, p), "CoastPier_%d" % k, stats, 2000.0, true)
	# --- 3) 帆船：停在栈桥外侧海面 ---
	var ship_b := Basis(Vector3.UP, shore_yaw + PI * 0.5).scaled(Vector3.ONE * 1.12)
	var ship_pos := sea_dir * 692.0 + along_shore * 46.0
	ship_pos.y = -0.8
	_real_unique(container, "ship_real", Transform3D(ship_b, ship_pos), "CoastTallShip", stats, 2600.0, true)
	# 多停几艘帆船在栈桥两侧
	for k in 2:
		var ang := shore_yaw + rng.randf_range(-1.2, 1.2) + (PI if k % 2 == 1 else 0.0)
		var sp := sea_dir * (640.0 + float(k) * 23.0) + along_shore * rng.randf_range(-90.0, 90.0)
		sp.y = -0.9
		var sb := Basis(Vector3.UP, ang).scaled(Vector3.ONE * rng.randf_range(0.55, 0.85))
		_real_unique(container, "ship_real", Transform3D(sb, sp), "CoastBoat_%d" % k, stats, 2400.0, true)
	# --- 4) 防波堤：一排真实礁石从沙滩伸向海里 ---
	var break_xforms: Array[Transform3D] = []
	var rock_asset := "boulder02" if RealAssetKit.has("boulder02") else "coast_rocks"
	if RealAssetKit.has(rock_asset):
		var rdims := RealAssetKit.size(rock_asset)
		var rref := maxf(maxf(rdims.x, rdims.z), rdims.y)
		for k in 0:
			var t := float(k) / 17.0
			var p := sea_dir * (585.0 + t * 74.0) + along_shore * sin(t * PI) * 26.0
			p.y = -1.0 + t * 0.25
			var s := rng.randf_range(2.4, 5.2) / maxf(rref, 0.01)
			var b := Basis(Vector3.UP, rng.randf() * TAU).scaled(
				Vector3(s, s * rng.randf_range(0.7, 1.1), s))
			break_xforms.append(Transform3D(b, p))
		RealAssetKit.place_chunked(container, rock_asset, break_xforms, "CoastBreakwater", 1500.0, false, stats)
	# --- 5) 航标浮标 + 航道标 ---
	var buoy_xforms: Array[Transform3D] = []
	for k in 12:
		var ang := rng.randf() * TAU
		var rad := rng.randf_range(625.0, 880.0)
		var p := Vector3(cos(ang) * rad, -1.0, sin(ang) * rad)
		var s := rng.randf_range(2.4, 3.6) / maxf(RealAssetKit.size("buoy_real").y, 0.2)
		buoy_xforms.append(Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3.ONE * s), p))
	RealAssetKit.place_chunked(container, "buoy_real", buoy_xforms, "CoastBuoys", 2200.0, false, stats)
	var marker_xforms: Array[Transform3D] = []
	for k in 4:
		var p := sea_dir * (600.0 + float(k) * 20.0) + along_shore * rng.randf_range(14.0, 34.0)
		p.y = -0.9
		marker_xforms.append(Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3.ONE * 1.1), p))
	RealAssetKit.place_chunked(container, "sea_marker_real", marker_xforms, "CoastSeaMarkers", 1600.0, false, stats)
	# --- 6) 沙滩伞 + 沙滩巾：栈桥旁边的沙滩 ---
	var umb_pole: Array[Transform3D] = []
	var umb_top: Array[Transform3D] = []
	var umb_colors: Array[Color] = []
	var towel_xforms: Array[Transform3D] = []
	var towel_colors: Array[Color] = []
	var palette := [Color(1.0, 0.28, 0.3), Color(0.25, 0.65, 1.0), Color(1.0, 0.85, 0.3),
		Color(0.3, 0.85, 0.55), Color(1.0, 0.55, 0.85)]
	for k in 16:
		var t := rng.randf_range(-1.0, 1.0)
		var p := sea_dir * rng.randf_range(520.0, 565.0) + along_shore * t * 110.0
		p.y = maxf(Terrain.height_at(p), -0.05)
		if not VenueKit.clear_of_track(path, p, 8.0):
			continue
		var b := Basis(Vector3.UP, rng.randf() * TAU)
		umb_pole.append(Transform3D(b.scaled(Vector3.ONE), p + Vector3(0.0, 1.15, 0.0)))
		umb_top.append(Transform3D(b.scaled(Vector3.ONE), p + Vector3(0.0, 2.35, 0.0)))
		umb_colors.append(palette[rng.randi() % palette.size()])
		var tp := p + Vector3(rng.randf_range(-2.4, 2.4), 0.03, rng.randf_range(-2.4, 2.4))
		towel_xforms.append(Transform3D(b.scaled(Vector3.ONE), tp))
		towel_colors.append(palette[rng.randi() % palette.size()])
	# 伞杆（细圆柱）与伞面（圆锥）分开两个 MultiMesh
	var pole_mesh := CylinderMesh.new()
	pole_mesh.top_radius = 0.045
	pole_mesh.bottom_radius = 0.06
	pole_mesh.height = 2.3
	pole_mesh.radial_segments = 6
	pole_mesh.rings = 1
	_prop_mm(container, pole_mesh, PbrAssets.metal(Vector2(1.0, 1.0)), umb_pole, [], "BeachUmbrellaPoles", stats, 640.0)
	var canopy_mesh := CylinderMesh.new()
	canopy_mesh.top_radius = 0.05
	canopy_mesh.bottom_radius = 1.65
	canopy_mesh.height = 0.75
	canopy_mesh.radial_segments = 12
	canopy_mesh.rings = 1
	var canopy_mat := StandardMaterial3D.new()
	canopy_mat.roughness = 0.72
	canopy_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_prop_mm_tinted(container, canopy_mesh, canopy_mat, umb_top, umb_colors, "BeachUmbrellas", stats, 640.0)
	var towel_mesh := BoxMesh.new()
	towel_mesh.size = Vector3(1.9, 0.03, 0.9)
	var towel_mat := StandardMaterial3D.new()
	towel_mat.roughness = 0.9
	_prop_mm_tinted(container, towel_mesh, towel_mat, towel_xforms, towel_colors, "BeachTowels", stats, 420.0)
	# --- 7) 远景海岛已移除：用户反馈孤立巨岛"只有一段有"很怪；海岸改为干净海平线 + 栈桥/船。
	# --- 8) 海边棕榈：项目自带 Blender 棕榈（Poly Haven 没有 CC0 棕榈） ---
	var palm_xforms: Array[Transform3D] = []
	var palm_assets: Array[String] = []
	if RealAssetKit.has("tree_palm_tall"):
		palm_assets.append("tree_palm_tall")
	if RealAssetKit.has("tree_palm_bent"):
		palm_assets.append("tree_palm_bent")
	for k in 14:
		if palm_assets.is_empty():
			break
		var along := rng.randf_range(-150.0, 150.0)
		var radius := rng.randf_range(536.0, 578.0)
		var p := sea_dir * radius + along_shore * along
		p = _ground_at(p, 0.0)
		if not VenueKit.clear_of_track(path, p, 6.0):
			continue
		var asset := palm_assets[k % palm_assets.size()]
		var sc := RealAssetKit.scale_for_height(asset, rng.randf_range(5.0, 8.0))
		palm_xforms.append(Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3.ONE * sc), p))
	for a in palm_assets:
		var typed: Array[Transform3D] = []
		for xf in palm_xforms:
			typed.append(xf as Transform3D)
		RealAssetKit.place_chunked(container, a, typed, "CoastPalms", 1100.0, true, stats)
	# --- 9) 救生塔：海滩制高点 ---
	_build_lifeguard_tower(container, path, rng, stats, sea_dir, along_shore, 566.0, 26.0)
	_build_lifeguard_tower(container, path, rng, stats, sea_dir, along_shore, 552.0, -34.0)
	# --- 10) 特色弯：真实木栈道观景台 + 海岛树 + 沙滩伞 ---
	if not hero.is_empty():
		var deck_base := _ground_at(_menu_stage(path, hero, 96.0, 24.0), 0.05)
		var yaw_t := atan2((hero["tangent"] as Vector3).x, (hero["tangent"] as Vector3).z)
		if VenueKit.clear_of_track(path, deck_base, 10.0):
			# 真实模块化木栈桥压扁成景观木台（低栏杆 + 木桩），不是手搓盒子
			var deck_b := Basis(Vector3.UP, yaw_t).scaled(Vector3(2.1, 0.5, 1.25))
			_real_unique(container, "pier_real", Transform3D(deck_b, deck_base), "CoastLookoutDeck", stats, 900.0, true)
		var hero_center := _menu_stage(path, hero, 102.0, 32.0)
		_scatter_real_near(container, path, rng, "realtree_02", _ground_at(hero_center), 7,
			9.0, 30.0, 5.0, 9.0, "CoastLookoutTrees", 900.0, 8.0)
		var hero_umb: Array[Transform3D] = []
		var hero_umb_col: Array[Color] = []
		for k in 5:
			var p := _ground_at(hero_center + Vector3(rng.randf_range(-14.0, 14.0), 0.0, rng.randf_range(-14.0, 14.0)))
			if not VenueKit.clear_of_track(path, p, 7.0):
				continue
			var b := Basis(Vector3.UP, rng.randf() * TAU)
			hero_umb.append(Transform3D(b, p + Vector3(0.0, 2.35, 0.0)))
			hero_umb_col.append(palette[rng.randi() % palette.size()])
		_prop_mm_tinted(container, canopy_mesh, canopy_mat, hero_umb, hero_umb_col,
			"CoastLookoutUmbrellas", stats, 500.0)


# ---------------------------------------------------------------------------
# 霓虹都市 / 天际环城：真实路灯 / 消防栓 / 配电箱 / 霓虹招牌 / 天桥 / 大屏
# ---------------------------------------------------------------------------

static func _build_city_landmarks(container: Node3D, path: TrackPath, theme: Dictionary,
		rng: RandomNumberGenerator, stats: Dictionary, night: bool) -> void:
	var hero := _hero_spot(path)
	var accent := _color(String(theme.get("accent", "#ff4d8d")), Color(1.0, 0.3, 0.55))
	_build_real_lamps(container, path, rng, stats, 76.0, path.half_width + 3.6, night)
	_scatter_real(container, path, rng, "hydrant_real", 14, 3.4, 7.5, 0.85, 1.05,
		"CityHydrants", 240.0, 2.0)
	_scatter_real(container, path, rng, "utility_box_real", 10, 3.6, 8.0, 1.0, 1.3,
		"CityUtilityBoxes", 260.0, 2.0)
	_scatter_real(container, path, rng, "manhole", 12, 3.0, 9.5, 0.95, 1.05,
		"CityManholes", 200.0, 2.0, 0.02)
	_build_neon_street(container, path, rng, stats, accent)
	_build_billboards(container, path, theme, rng, stats, 5, "NEO CITY  /  APEX")
	if not hero.is_empty():
		var cam := _menu_camera(path, hero)
		var f1 := _track_point_in_view(path, hero, cam, 26.0, 110.0)
		var f2 := _track_point_in_view(path, hero, cam, 130.0, 300.0)
		if not f1.is_empty():
			_build_sky_bridge(container, path, rng, stats, accent, float(f1["dist"]))
		if not f2.is_empty():
			_build_sky_bridge(container, path, rng, stats, accent, float(f2["dist"]))
		_build_neon_gate(container, path, hero, accent, stats)
		_build_landmark_towers(container, path, hero, rng, stats, accent, night)
	_build_ad_screens(container, path, rng, stats, 2)


## 招牌落点查重：矩形楼面（量块楼）+ 渲染半径（模型楼/英雄塔）双重判。
static func _neon_spot_ok(pos: Vector3) -> bool:
	return RealAssetKit.face_rect_clear(pos, 0.9) and RealAssetKit.face_clear(pos, 1.1)


## 路边竖向霓虹招牌（顶点色自发光 MultiMesh）。每 6 块放一个 Label3D 文字。
static func _build_neon_street(container: Node3D, path: TrackPath,
		rng: RandomNumberGenerator, stats: Dictionary, accent: Color) -> void:
	var panel_mesh := BoxMesh.new()
	panel_mesh.size = Vector3(1.0, 1.0, 0.16)
	var words := ["NEO", "APEX", "RACE", "24H", "DRIFT", "OPEN", "SPEED", "BAR"]
	var palette := [accent, Color(0.2, 0.9, 1.0), Color(1.0, 0.55, 0.15),
		Color(0.65, 0.25, 1.0), Color(0.25, 1.0, 0.6)]
	var xforms: Array[Transform3D] = []
	var colors: Array[Color] = []
	var labels: Array = []
	var dist := rng.randf_range(20.0, 60.0)
	var side := 1.0
	var idx := 0
	while dist < path.total_length:
		var f := path.frame_at(dist + rng.randf_range(-9.0, 9.0))
		if not f.is_empty() and rng.randf() < 0.8:
			# lateral 收在 5~11.5：楼面从 half+gap 起（含偏转摆动最近 half+4.5），
			# 外段会被楼面盖住——贴墙判断不过就往里收进护栏与路灯之间的窄带，
			# 连窄带都被占（缝隙楼）就放弃这块招牌。量块楼按矩形楼面判，
			# 模型楼/英雄塔按圆判（外形不规则，渲染半径兜底）
			var lateral := path.half_width + rng.randf_range(5.0, 11.5) * side
			var toward := -(f["side"] as Vector3) * side
			var yaw := atan2(toward.x, toward.z)
			var h := rng.randf_range(2.6, 9.0)
			var pos := _ground_at(_pos_of(f, lateral), h * 0.5 + rng.randf_range(2.5, 9.0))
			if not _neon_spot_ok(pos):
				var in_pos := _ground_at(
					_pos_of(f, path.half_width + rng.randf_range(2.4, 3.0) * side),
					h * 0.5 + rng.randf_range(2.5, 9.0))
				if _neon_spot_ok(in_pos):
					pos = in_pos
			if _neon_spot_ok(pos):
				var b := Basis(Vector3.UP, yaw).scaled(Vector3(rng.randf_range(0.9, 1.5), h, 1.0))
				xforms.append(Transform3D(b, pos))
				var col: Color = palette[idx % palette.size()]
				colors.append(col if rng.randf() < 0.6 else palette[rng.randi() % palette.size()])
				if idx % 6 == 2:
					labels.append({"text": words[idx % words.size()], "pos": pos, "yaw": yaw, "color": col})
				idx += 1
		dist += 66.0
		side = -side
	if xforms.is_empty():
		return
	_prop_mm_custom(container, panel_mesh, _neon_vertex_material(), xforms, colors,
		"CityNeonPanels", stats, 520.0)
	for item in labels:
		var p: Vector3 = item["pos"]
		_neon_label(container, String(item["text"]), p,
			float(item["yaw"]), item["color"] as Color, 1.2)
	# 招牌下面再挂一条暖黄灯带，夜里更像商业街
	var strip_mesh := BoxMesh.new()
	strip_mesh.size = Vector3(1.0, 0.22, 0.3)
	var strip_xforms: Array[Transform3D] = []
	var strip_colors: Array[Color] = []
	for i in xforms.size():
		var xf := xforms[i]
		strip_xforms.append(Transform3D(xf.basis.scaled(Vector3(1.1, 0.22, 1.2)), xf.origin - Vector3(0.0, xf.basis.get_scale().y * 0.5 - 0.2, 0.0)))
		strip_colors.append(Color(1.0, 0.72, 0.3))
	_prop_mm_custom(container, strip_mesh, _neon_vertex_material(), strip_xforms, strip_colors,
		"CityNeonStrips", stats, 480.0)


## 跨路天桥（混凝土桥面 + 霓虹灯带 + 玻璃侧墙）。
static func _build_sky_bridge(container: Node3D, path: TrackPath, rng: RandomNumberGenerator,
		stats: Dictionary, accent: Color, dist: float) -> void:
	var f := path.frame_at(dist)
	if f.is_empty():
		return
	var tangent: Vector3 = f["tangent"]
	var side: Vector3 = f["side"]
	var yaw := atan2(tangent.x, tangent.z)
	var base: Vector3 = (f["pos"] as Vector3)
	base.y = _ground_at(base).y
	var half := path.half_width
	# 桥面只探出路肩 4m：近排楼面最近 half+4.5（gap6-偏转摆动），更宽的
	# 桥头会插进楼身；桥墩收在 half+3（护栏外沿 1.9 与楼面 4.5 之间的走廊）
	var span := half * 2.0 + 8.0
	var deck_mat := PbrAssets.concrete(Vector2(4.0, 2.0))
	var metal_mat := PbrAssets.metal(Vector2(3.0, 3.0))
	# 桥体所有部件归进同一个命名容器（≤8 个 mesh，审计会合并成一整个物件）：
	# 分散摆放的话玻璃墙/灯带/桥面互相贴接会被报成穿模，桥面也会被误报悬空
	var bridge := Node3D.new()
	bridge.name = "SkyBridge_%d" % int(dist)
	container.add_child(bridge)
	var deck := MeshInstance3D.new()
	var deck_mesh := BoxMesh.new()
	deck_mesh.size = Vector3(span, 1.5, 6.0)
	deck.mesh = deck_mesh
	deck.material_override = deck_mat
	deck.transform = Transform3D(Basis(Vector3.UP, yaw), base + Vector3(0.0, 8.6, 0.0))
	deck.set_meta("audit_cat", "bridge")
	bridge.add_child(deck)
	# 支撑柱：护栏与楼面之间的路肩走廊，宽 1.6 别蹭到两侧
	for sgn: float in [-1.0, 1.0]:
		var pillar := MeshInstance3D.new()
		var pm := BoxMesh.new()
		pm.size = Vector3(1.6, 8.6, 3.2)
		pillar.mesh = pm
		pillar.material_override = deck_mat
		pillar.transform = Transform3D(Basis(Vector3.UP, yaw),
			base + side * (half + 3.0) * sgn + Vector3(0.0, 4.3, 0.0))
		pillar.set_meta("audit_cat", "bridge")
		bridge.add_child(pillar)
	# 玻璃侧墙 + 霓虹灯带
	for zsign: float in [-1.0, 1.0]:
		var glass := MeshInstance3D.new()
		var gm := BoxMesh.new()
		gm.size = Vector3(span, 1.7, 0.14)
		glass.mesh = gm
		var gmat := StandardMaterial3D.new()
		gmat.albedo_color = Color(0.28, 0.55, 0.75, 0.55)
		gmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		gmat.emission_enabled = true
		gmat.emission = accent * 0.35
		gmat.emission_energy_multiplier = 0.8
		glass.material_override = gmat
		glass.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		glass.transform = Transform3D(Basis(Vector3.UP, yaw),
			base + basis_z(basis_for(yaw), 3.0 * zsign) + Vector3(0.0, 9.8, 0.0))
		glass.set_meta("audit_cat", "bridge")
		bridge.add_child(glass)
	var strip := MeshInstance3D.new()
	var sm := BoxMesh.new()
	sm.size = Vector3(span, 0.28, 0.2)
	strip.mesh = sm
	strip.material_override = _emissive_mat(accent, 2.6)
	strip.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	strip.transform = Transform3D(Basis(Vector3.UP, yaw),
		base + basis_z(basis_for(yaw), 3.06) + Vector3(0.0, 7.85, 0.0))
	strip.set_meta("audit_cat", "bridge")
	bridge.add_child(strip)
	stats["nodes"] = int(stats.get("nodes", 0)) + 6


static func basis_for(yaw: float) -> Basis:
	return Basis(Vector3.UP, yaw)


static func basis_z(b: Basis, z: float) -> Vector3:
	return b.z * z


## 跨路霓虹门：两根发光门柱 + 横梁，一个非常醒目的赛道地标。
static func _build_neon_gate(container: Node3D, path: TrackPath, hero: Dictionary,
		accent: Color, stats: Dictionary) -> void:
	var cam := _menu_camera(path, hero)
	var f := _track_point_in_view(path, hero, cam, 24.0, 96.0)
	if f.is_empty():
		f = path.frame_at(float(hero["hero_dist"]) + 40.0)
	if f.is_empty():
		return
	var tangent: Vector3 = f["tangent"]
	var side: Vector3 = f["side"]
	var yaw := atan2(tangent.x, tangent.z)
	var base: Vector3 = _ground_at(f["pos"] as Vector3)
	var span := path.half_width * 2.0 + 9.0
	var metal := PbrAssets.metal(Vector2(3.0, 4.0))
	for sgn: float in [-1.0, 1.0]:
		var post := MeshInstance3D.new()
		var pm := BoxMesh.new()
		pm.size = Vector3(1.4, 10.5, 1.8)
		post.mesh = pm
		post.material_override = metal
		post.transform = Transform3D(Basis(Vector3.UP, yaw),
			base + side * span * 0.5 * sgn + Vector3(0.0, 5.25, 0.0))
		container.add_child(post)
		var stripe := MeshInstance3D.new()
		var stm := BoxMesh.new()
		stm.size = Vector3(1.55, 5.6, 0.16)
		stripe.mesh = stm
		stripe.material_override = _emissive_mat(accent if sgn > 0.0 else Color(0.2, 0.9, 1.0), 3.0)
		stripe.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		stripe.transform = Transform3D(Basis(Vector3.UP, yaw),
			base + side * span * 0.5 * sgn + tangent * 0.95 + Vector3(0.0, 5.4, 0.0))
		container.add_child(stripe)
	var beam := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.0, 0.0, 0.0)
	bm.size = Vector3(span + 2.4, 2.2, 2.0)
	beam.mesh = bm
	beam.material_override = metal
	beam.transform = Transform3D(Basis(Vector3.UP, yaw), base + Vector3(0.0, 10.8, 0.0))
	container.add_child(beam)
	var glow := MeshInstance3D.new()
	var gm := BoxMesh.new()
	gm.size = Vector3(span + 1.0, 0.75, 2.15)
	glow.mesh = gm
	glow.material_override = _emissive_mat(accent, 2.4)
	glow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	glow.transform = Transform3D(Basis(Vector3.UP, yaw), base + Vector3(0.0, 9.4, 0.0))
	container.add_child(glow)
	_neon_label(container, "N E O N   C I T Y",
		base + tangent * 1.1 + Vector3(0.0, 10.8, 0.0), yaw + PI, Color(1.0, 0.95, 1.0), 1.6)
	stats["nodes"] = int(stats.get("nodes", 0)) + 6


## 广告大屏：复用场馆套件的 big_screen 模型，靠路边摆放。
static func _build_ad_screens(container: Node3D, path: TrackPath, rng: RandomNumberGenerator,
		stats: Dictionary, count: int) -> void:
	if not RealAssetKit.has("big_screen"):
		return
	for i in count:
		var f := path.frame_at(rng.randf() * path.total_length)
		if f.is_empty():
			continue
		var side_sign := 1.0 if rng.randf() < 0.5 else -1.0
		var p := _ground_at(_pos_of(f, path.half_width + rng.randf_range(22.0, 40.0) * side_sign))
		var toward := -(f["side"] as Vector3) * side_sign
		var yaw := atan2(toward.x, toward.z)
		_real_scaled(container, "big_screen", p, yaw, 13.0, "CityAdScreen_%d" % i, stats,
			Vector3.ONE, 1200.0, false)


## 特色弯附近的超高地标塔：真实 CC0 立面 + 屋顶霓虹 + 天线。
static func _build_landmark_towers(container: Node3D, path: TrackPath, hero: Dictionary,
		rng: RandomNumberGenerator, stats: Dictionary, accent: Color, night: bool) -> void:
	if hero.is_empty():
		return
	# 地标塔也用窗格贴图，避免白天公寓照片在夜景里变成一整面米白墙
	var facade := _city_window_material(night, 5150)
	facade.albedo_color = Color(0.10, 0.12, 0.16)
	facade.emission_energy_multiplier = 0.25
	var tower_metal := PbrAssets.metal(Vector2(2.5, 2.5))
	var body_mat := PbrAssets.concrete(Vector2(5.0, 5.0))
	body_mat.albedo_color = Color(0.35, 0.37, 0.44) if night else Color(0.55, 0.52, 0.48)
	var half := path.half_width
	for k in 4:
		var p := _ground_at(_menu_stage(path, hero, 96.0 + float(k) * 74.0,
			-54.0 + float(k) * 32.0))
		var info := path.nearest(p)
		if info.is_empty():
			continue
		var f := path.frame_at(float(info["dist"]))
		if f.is_empty():
			continue
		var side_sign := 1.0 if k % 2 == 0 else -1.0
		if absf((f["side"] as Vector3).dot(p - (f["pos"] as Vector3))) > 0.01:
			side_sign = signf((f["side"] as Vector3).dot(p - (f["pos"] as Vector3)))
		var h := rng.randf_range(46.0, 82.0)
		var w := rng.randf_range(16.0, 24.0)
		var d := rng.randf_range(14.0, 22.0)
		var yaw := atan2((f["tangent"] as Vector3).x, (f["tangent"] as Vector3).z)
		var basis := Basis(Vector3.UP, yaw)
		var body := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(w, h, d)
		body.mesh = bm
		body.material_override = facade
		body.transform = Transform3D(basis, p + Vector3(0.0, h * 0.5, 0.0))
		body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		container.add_child(body)
		# 地标塔细节：裙楼 + 顶部退台 + 四角金属柱 + 层间线脚
		var podium := MeshInstance3D.new()
		var pm := BoxMesh.new(); pm.size = Vector3(w + 3.2, 9.0, d + 3.2)
		podium.mesh = pm; podium.material_override = facade
		podium.transform = Transform3D(basis, p + Vector3(0.0, 4.5, 0.0))
		container.add_child(podium)
		var tier := MeshInstance3D.new()
		var tm := BoxMesh.new(); tm.size = Vector3(w * 0.76, h * 0.12, d * 0.76)
		tier.mesh = tm; tier.material_override = facade
		tier.transform = Transform3D(basis, p + Vector3(0.0, h + h * 0.06, 0.0))
		container.add_child(tier)
		for cx: float in [-0.5, 0.5]:
			for cz: float in [-0.5, 0.5]:
				var fin := MeshInstance3D.new()
				var fm := BoxMesh.new(); fm.size = Vector3(0.7, h * 0.92, 0.7)
				fin.mesh = fm; fin.material_override = tower_metal
				fin.transform = Transform3D(basis, p + basis * Vector3(cx * w, h * 0.46, cz * d))
				container.add_child(fin)
		for fy in [10.0, 24.0, 38.0, 52.0]:
			if fy >= h - 4.0: break
			var ledge := MeshInstance3D.new()
			var lm := BoxMesh.new(); lm.size = Vector3(w + 0.9, 0.3, d + 0.9)
			ledge.mesh = lm; ledge.material_override = tower_metal
			ledge.transform = Transform3D(basis, p + Vector3(0.0, fy, 0.0))
			container.add_child(ledge)
		# 真实公寓照片在大楼表面会变成整面米白墙，地标塔只用程序窗格贴图
		if false and RealAssetKit.has("facade_real"):
			var fd := RealAssetKit.size("facade_real")
			var toward := -(f["side"] as Vector3) * side_sign
			var sx := minf(w * 1.04, 34.0) / maxf(fd.x, 0.01)
			var sy := minf(h * 0.9, 32.0) / maxf(fd.y, 0.01)
			var fb := Basis(Vector3.UP, atan2(toward.x, toward.z)).scaled(Vector3(sx, sy, 1.0))
			var fp: Vector3 = p + toward * (d * 0.5 + 1.0)
			fp.y = p.y + minf(h * 0.9, 32.0) * 0.5
			var lf := _real_unique(container, "facade_real", Transform3D(fb, fp),
				"LandmarkFacade_%d" % k, stats, 2200.0, false)
			if lf != null:
				if night:
					RealAssetKit.darken_albedo(lf, 0.3)
					RealAssetKit.make_emissive(lf, 0.5)
				else:
					RealAssetKit.darken_albedo(lf, 0.82)
		# 屋顶霓虹冠 + 天线
		var crown := MeshInstance3D.new()
		var cm := BoxMesh.new()
		cm.size = Vector3(w + 1.4, 0.9, d + 1.4)
		crown.mesh = cm
		crown.material_override = _emissive_mat(accent.lerp(Color(0.3, 0.85, 1.0), rng.randf()), 2.8)
		crown.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		crown.transform = Transform3D(basis, p + Vector3(0.0, h + 0.4, 0.0))
		container.add_child(crown)
		var antenna := MeshInstance3D.new()
		var am := CylinderMesh.new()
		am.top_radius = 0.08
		am.bottom_radius = 0.18
		am.height = 9.0
		am.radial_segments = 5
		am.rings = 1
		antenna.mesh = am
		antenna.material_override = PbrAssets.metal(Vector2(1.0, 2.0))
		antenna.transform = Transform3D(basis, p + Vector3(0.0, h + 5.0, 0.0))
		container.add_child(antenna)
		var beacon := MeshInstance3D.new()
		var bem := SphereMesh.new()
		bem.radius = 0.55
		bem.height = 1.1
		bem.radial_segments = 8
		bem.rings = 4
		beacon.mesh = bem
		beacon.material_override = _emissive_mat(Color(1.0, 0.15, 0.1), 3.2)
		beacon.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		beacon.transform = Transform3D(basis, p + Vector3(0.0, h + 9.8, 0.0))
		container.add_child(beacon)
		stats["nodes"] = int(stats.get("nodes", 0)) + 5


# ---------------------------------------------------------------------------
# 雪山 / 冰川：真实冷杉林 / 缆车 / 木屋 / 雪堆 / 冰柱
# ---------------------------------------------------------------------------

static func _build_mountain_landmarks(container: Node3D, path: TrackPath, theme: Dictionary,
		rng: RandomNumberGenerator, stats: Dictionary) -> void:
	var hero := _hero_spot(path)
	if hero.is_empty():
		return
	# --- 1) 真实 CC0 冷杉（fir_tree_01）：LOD 铺全赛道 + 高模压特色弯 ---
	var content := clampf(Settings.content_scale(), 0.3, 1.5)
	_scatter_real(container, path, rng, "realtree_fir_lod", int(round(36.0 * content)),
		12.0, 82.0, 9.0, 16.0, "AlpineFirFar", 1150.0, 6.0)
	_scatter_real_near(container, path, rng, "realtree_fir_full",
		_ground_at(_menu_stage(path, hero, 108.0, 24.0)), int(round(6.0 * content)),
		12.0, 48.0, 10.0, 17.0, "AlpineFirHero", 1100.0, 8.0)
	_scatter_real_near(container, path, rng, "realtree_fir_full",
		_ground_at(_menu_stage(path, hero, 74.0, -18.0)), int(round(4.0 * content)),
		10.0, 34.0, 12.0, 18.0, "AlpineFirNear", 900.0, 8.0)
	_scatter_real_near(container, path, rng, "realtree_pine",
		_ground_at(_menu_stage(path, hero, 78.0, 20.0)), int(round(10.0 * content)),
		8.0, 42.0, 4.0, 7.0, "AlpinePineHero", 700.0, 7.0)
	# --- 2) 缆车塔 + 缆绳（低模组合件 + 金属 PBR） ---
	_build_cable_car(container, path, hero, rng, stats)
	# --- 3) 山间木屋（A 形屋顶，真实风化木 PBR 贴图） ---
	_build_alpine_hut(container, path, hero, rng, stats)
	# --- 4) 雪堆 + 路边旗杆 ---
	_build_snow_banks(container, path, rng, stats)
	_build_marker_flags(container, path, rng, stats, Color(1.0, 0.42, 0.16))


static func _build_cable_car(container: Node3D, path: TrackPath, hero: Dictionary,
		rng: RandomNumberGenerator, stats: Dictionary) -> void:
	var metal := PbrAssets.metal(Vector2(3.0, 5.0))
	var leg_mesh := BoxMesh.new()
	leg_mesh.size = Vector3(0.34, 1.0, 0.34)
	var brace_mesh := BoxMesh.new()
	brace_mesh.size = Vector3(3.4, 0.24, 0.24)
	var legs: Array[Transform3D] = []
	var braces: Array[Transform3D] = []
	var tops: Array[Vector3] = []
	var anchor := _in_view_track_anchor(path, hero, 36.0, 130.0)
	for k in 4:
		var f := path.frame_at(float(anchor["dist"]) + 46.0 + float(k) * 96.0)
		if f.is_empty():
			continue
		var side_sign := 1.0 if k % 2 == 0 else -1.0
		var base := _ground_at(_pos_of(f, rng.randf_range(30.0, 44.0) * side_sign), 0.0)
		var h := 15.0 + float(k) * 1.2
		var yaw := atan2((f["tangent"] as Vector3).x, (f["tangent"] as Vector3).z)
		var basis := Basis(Vector3.UP, yaw)
		var top := base + Vector3(0.0, h, 0.0)
		tops.append(top)
		for lx: float in [-1.5, 1.5]:
			for lz: float in [-1.1, 1.1]:
				var lp: Vector3 = base + basis.y * 0.0 + basis * Vector3(lz, h * 0.5, lx)
				legs.append(Transform3D(basis.scaled(Vector3.ONE).scaled(Vector3(1.0, h, 1.0)), lp))
		for by: float in [3.0, 6.4, 9.8, h - 1.2]:
			braces.append(Transform3D(basis, base + Vector3(0.0, by, 0.0)))
		braces.append(Transform3D(basis * Basis(Vector3.FORWARD, 0.6).scaled(Vector3(1.0, 1.0, 1.0)),
			base + Vector3(0.0, h * 0.52, 0.0)))
		stats["scenery"] = int(stats["scenery"]) + 1
	_prop_mm(container, leg_mesh, metal, legs, [], "CableCarLegs", stats, 1500.0)
	_prop_mm(container, brace_mesh, metal, braces, [], "CableCarBraces", stats, 1500.0)
	# 缆绳：塔顶之间用细圆柱连起来（含下垂感的三段折线）
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
			for lane: float in [-1.6, 1.6]:
				var off := (Basis(Vector3.UP, 0.0) * Vector3.ZERO)
				var aa := a + Vector3(lane, 0.0, 0.0)
				var bb := b + Vector3(lane, 0.0, 0.0)
				var mid := (aa + bb) * 0.5 - Vector3(0.0, 2.2, 0.0)
				cables.append(_beam_xform(aa, mid, 0.055))
				cables.append(_beam_xform(mid, bb, 0.055))
		_prop_mm(container, cable_mesh, PbrAssets.metal(Vector2(1.0, 1.0)), cables, [], "CableCarLines", stats, 1600.0)


static func _build_alpine_hut(container: Node3D, path: TrackPath, hero: Dictionary,
		rng: RandomNumberGenerator, stats: Dictionary) -> void:
	var planks := PbrAssets.weathered_planks()
	var roof_mat := PbrAssets.metal(Vector2(4.0, 2.0))
	roof_mat.albedo_color = Color(0.42, 0.2, 0.16)
	var anchor := _in_view_track_anchor(path, hero, 36.0, 130.0)
	var center: Vector3 = (anchor["pos"] as Vector3) + (anchor["side"] as Vector3) * 26.0
	if not VenueKit.clear_of_track(path, center, 12.0):
		center = (anchor["pos"] as Vector3) - (anchor["side"] as Vector3) * 26.0
		if not VenueKit.clear_of_track(path, center, 12.0):
			return
	var base := _ground_at(center)
	var yaw := atan2((hero["tangent"] as Vector3).x, (hero["tangent"] as Vector3).z)
	var basis := Basis(Vector3.UP, yaw)
	# 墙身
	var body := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(6.2, 2.9, 4.6)
	body.mesh = bm
	body.material_override = planks
	body.transform = Transform3D(basis, base + Vector3(0.0, 1.45, 0.0))
	container.add_child(body)
	# 两个斜面屋顶（不是盒子建筑：坡屋顶 + 出檐 + 烟囱 + 雪层）
	for sgn: float in [-1.0, 1.0]:
		var roof := MeshInstance3D.new()
		var rm := BoxMesh.new()
		rm.size = Vector3(3.9, 0.22, 5.4)
		roof.mesh = rm
		roof.material_override = roof_mat
		var tilt := Basis(Vector3.FORWARD, 0.62 * sgn)
		roof.transform = Transform3D(basis * tilt,
			base + basis * Vector3(1.55 * sgn, 3.5, 0.0))
		roof.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		container.add_child(roof)
		var snow := MeshInstance3D.new()
		var sm := BoxMesh.new()
		sm.size = Vector3(3.7, 0.1, 5.2)
		snow.mesh = sm
		snow.material_override = PbrAssets.snow_ground(Vector2(2.0, 2.0))
		snow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		snow.transform = Transform3D(basis * Basis(Vector3.FORWARD, 0.62 * sgn),
			base + basis * Vector3(1.55 * sgn, 3.66, 0.0))
		container.add_child(snow)
	var chimney := MeshInstance3D.new()
	var cm := BoxMesh.new()
	cm.size = Vector3(0.7, 2.2, 0.7)
	chimney.mesh = cm
	chimney.material_override = PbrAssets.concrete(Vector2(1.0, 1.0))
	chimney.transform = Transform3D(basis, base + basis * Vector3(-1.4, 4.6, -1.0))
	container.add_child(chimney)
	var door := MeshInstance3D.new()
	var dm := BoxMesh.new()
	dm.size = Vector3(1.1, 2.1, 0.16)
	door.mesh = dm
	var door_mat := StandardMaterial3D.new()
	door_mat.albedo_color = Color(0.2, 0.13, 0.09)
	door_mat.roughness = 0.85
	door.material_override = door_mat
	door.transform = Transform3D(basis, base + basis * Vector3(0.0, 1.05, 2.32))
	container.add_child(door)
	# 柴垛 + 围栏
	var log_mesh := CylinderMesh.new()
	log_mesh.top_radius = 0.13
	log_mesh.bottom_radius = 0.15
	log_mesh.height = 1.4
	log_mesh.radial_segments = 6
	log_mesh.rings = 1
	var logs: Array[Transform3D] = []
	for k in 9:
		var row := k / 3
		var col := k % 3
		var lp: Vector3 = base + basis * Vector3(3.9 + float(col) * 0.32, 0.15 + float(row) * 0.27, -1.4 + 0.0)
		logs.append(Transform3D(basis * Basis(Vector3.FORWARD, 1.5708), lp))
	_prop_mm(container, log_mesh, PbrAssets.planks(), logs, [], "AlpineFirewood", stats, 600.0)
	stats["scenery"] = int(stats["scenery"]) + 1


static func _build_snow_banks(container: Node3D, path: TrackPath, rng: RandomNumberGenerator,
		stats: Dictionary) -> void:
	var bank_mesh := CylinderMesh.new()
	bank_mesh.top_radius = 0.5
	bank_mesh.bottom_radius = 1.0
	bank_mesh.height = 1.0
	bank_mesh.radial_segments = 7
	bank_mesh.rings = 1
	var banks: Array[Transform3D] = []
	var count := int(round(54.0 * clampf(Settings.content_scale(), 0.3, 1.5)))
	var dist := 0.0
	while banks.size() < count and dist < path.total_length:
		dist += 44.0
		var f := path.frame_at(dist + rng.randf_range(-14.0, 14.0))
		if f.is_empty():
			continue
		var side_sign := 1.0 if rng.randf() < 0.5 else -1.0
		var p := _ground_at(_pos_of(f, path.half_width + rng.randf_range(2.6, 12.0) * side_sign), -0.15)
		var b := Basis(Vector3.UP, rng.randf() * TAU).scaled(
			Vector3(rng.randf_range(1.6, 4.2), rng.randf_range(0.7, 1.7), rng.randf_range(1.2, 3.0)))
		banks.append(Transform3D(b, p))
	_prop_mm(container, bank_mesh, PbrAssets.snow_ground(Vector2(2.0, 2.0)), banks, [], "SnowBanks", stats, 520.0)


## 路边旗杆（雪地/冰原标记旗）：MultiMesh 两根，杆 + 三角旗。
static func _build_marker_flags(container: Node3D, path: TrackPath, rng: RandomNumberGenerator,
		stats: Dictionary, flag_color: Color) -> void:
	var pole_mesh := CylinderMesh.new()
	pole_mesh.top_radius = 0.03
	pole_mesh.bottom_radius = 0.05
	pole_mesh.height = 2.8
	pole_mesh.radial_segments = 5
	pole_mesh.rings = 1
	var flag_mesh := PrismMesh.new()
	flag_mesh.size = Vector3(1.1, 0.75, 0.05)
	var poles: Array[Transform3D] = []
	var flags: Array[Transform3D] = []
	var colors: Array[Color] = []
	var count := 40
	var dist := 20.0
	while dist < path.total_length:
		var f := path.frame_at(dist + rng.randf_range(-8.0, 8.0))
		if not f.is_empty():
			var side_sign := 1.0 if rng.randf() < 0.5 else -1.0
			var p := _ground_at(_pos_of(f, path.half_width + rng.randf_range(2.2, 4.4) * side_sign))
			var yaw := atan2((f["tangent"] as Vector3).x, (f["tangent"] as Vector3).z)
			var b := Basis(Vector3.UP, yaw)
			poles.append(Transform3D(b, p + Vector3(0.0, 1.4, 0.0)))
			flags.append(Transform3D(b, p + Vector3(0.0, 2.45, 0.0)))
			colors.append(flag_color if rng.randf() < 0.7 else Color(1.0, 0.85, 0.25))
		dist += 46.0
	if poles.is_empty():
		return
	_prop_mm(container, pole_mesh, PbrAssets.metal(Vector2(1.0, 1.0)), poles, [], "MarkerPoles", stats, 620.0)
	var flag_mat := StandardMaterial3D.new()
	flag_mat.roughness = 0.85
	flag_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	flag_mat.emission_enabled = true
	flag_mat.emission = flag_color * 0.4
	flag_mat.emission_energy_multiplier = 0.5
	_prop_mm_tinted(container, flag_mesh, flag_mat, flags, colors, "MarkerFlags", stats, 620.0)


# ---------------------------------------------------------------------------
# 赤岩峡谷：岩柱群 / 荒漠灌木 / 废弃车 / 轮胎墙 / 木棚 / 电线杆
# ---------------------------------------------------------------------------

static func _build_desert_landmarks(container: Node3D, path: TrackPath, theme: Dictionary,
		rng: RandomNumberGenerator, stats: Dictionary) -> void:
	var hero := _hero_spot(path)
	var content := clampf(Settings.content_scale(), 0.3, 1.5)
	_build_rock_pillars(container, path, rng, stats, hero)
	# 真实 CC0 荒漠灌木（Poly Haven shrub / weed 摄影测量，减面后）
	_scatter_real(container, path, rng, "shrub_real02", int(round(42.0 * content)),
		5.0, 32.0, 1.4, 3.2, "CanyonShrubs", 460.0, 3.5)
	_scatter_real(container, path, rng, "shrub_real04", int(round(90.0 * content)),
		4.0, 24.0, 0.5, 1.2, "CanyonScrub", 320.0, 3.0)
	_scatter_real(container, path, rng, "weed_real", int(round(80.0 * content)),
		4.0, 20.0, 0.35, 0.8, "CanyonWeed", 240.0, 2.5)
	# 废弃车辆（真实 covered_car）
	_scatter_real(container, path, rng, "car_wreck_real", 7, 17.0, 46.0, 1.35, 1.55,
		"CanyonWrecks", 760.0, 6.0, 0.0, true)
	# 轮胎墙 + 木棚 + 油桶 + 电线杆
	_build_tyre_walls(container, path, rng, stats, hero, 8)
	if not hero.is_empty():
		for k in 3:
			var p := _ground_at(_menu_stage(path, hero, 74.0 + float(k) * 15.0, 20.0 + float(k) * 9.0), 0.0)
			if VenueKit.clear_of_track(path, p, 7.0):
				_real_scaled(container, "car_wreck_real", p, rng.randf() * TAU, 1.5,
					"CanyonHeroWreck_%d" % k, stats, Vector3.ONE, 800.0, true)
	_build_canyon_shack(container, path, hero, rng, stats)
	_scatter_real(container, path, rng, "barrel_real", 12, 6.0, 22.0, 0.9, 1.05,
		"CanyonBarrels", 400.0, 3.0)
	_build_power_line(container, path, rng, stats, 128.0, path.half_width + 24.0)


static func _build_rock_pillars(container: Node3D, path: TrackPath,
		rng: RandomNumberGenerator, stats: Dictionary, hero: Dictionary) -> void:
	var asset := "rock_face"
	if not RealAssetKit.has(asset):
		return
	var dims := RealAssetKit.size(asset)
	var ref_h := maxf(dims.y, 0.5)
	var ref_w := maxf(maxf(dims.x, dims.z), 0.5)
	var xforms: Array[Transform3D] = []
	# 特色弯附近的岩柱阵（12 根，全部用真实 CC0 岩壁几何竖向拉伸）
	if not hero.is_empty():
		var anchor := _in_view_track_anchor(path, hero, 30.0, 110.0)
		var center: Vector3 = (anchor["pos"] as Vector3) + (anchor["side"] as Vector3) * \
			(18.0 if rng.randf() < 0.5 else -18.0)
		for k in 12:
			var angle := TAU * float(k) / 12.0 + rng.randf_range(-0.35, 0.35)
			var radius := rng.randf_range(8.0, 30.0)
			var p := center + Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
			p = _ground_at(p, -0.6)
			if not VenueKit.clear_of_track(path, p, 9.0):
				continue
			var h := rng.randf_range(11.0, 26.0)
			var w := rng.randf_range(0.7, 1.35) * rng.randf_range(2.6, 4.6) / ref_w
			var b := Basis(Vector3.UP, rng.randf() * TAU).scaled(
				Vector3(w, h / ref_h, w * rng.randf_range(0.8, 1.2)))
			b = b * Basis(Vector3.RIGHT, rng.randf_range(-0.08, 0.08))
			xforms.append(Transform3D(b, p))
	# 全赛道散布的中小型岩柱
	var attempts := 60
	while xforms.size() < 44 and attempts > 0:
		attempts -= 1
		var f := path.frame_at(rng.randf() * path.total_length)
		if f.is_empty():
			continue
		var p := _ground_at(_pos_of(f, rng.randf_range(18.0, 70.0) * (1.0 if rng.randf() < 0.5 else -1.0)), -0.4)
		if not VenueKit.clear_of_track(path, p, 6.0):
			continue
		var h := rng.randf_range(5.0, 16.0)
		var w := rng.randf_range(2.0, 4.4) / ref_w
		var b := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(w, h / ref_h, w))
		xforms.append(Transform3D(b, p))
	_place_tinted(container, asset, xforms, "CanyonPillars", Color(0.92, 0.72, 0.6), 900.0, stats, false)


static func _build_tyre_walls(container: Node3D, path: TrackPath, rng: RandomNumberGenerator,
		stats: Dictionary, hero: Dictionary, corners: int) -> void:
	if not RealAssetKit.has("tyre_real"):
		return
	var xforms: Array[Transform3D] = []
	# 特色弯外侧：双层轮胎墙
	if not hero.is_empty():
		var out_sign := 1.0 if (hero["outside"] as Vector3).dot(hero["side"] as Vector3) > 0.0 else -1.0
		for row in 2:
			for k in 12:
				var f := path.frame_at(float(hero["hero_dist"]) + float(k) * 1.6 - 8.0)
				if f.is_empty():
					continue
				var p := _ground_at(_pos_of(f, (path.half_width + 2.2 + float(row) * 0.7) * out_sign))
				p.y += row * 0.58
				var yaw := atan2((f["tangent"] as Vector3).x, (f["tangent"] as Vector3).z)
				xforms.append(Transform3D(Basis(Vector3.UP, yaw), p + Vector3(0.0, 0.3, 0.0)))
	# 其它弯道
	var placed := 0
	var dist := 0.0
	while dist < path.total_length and placed < corners:
		var f := path.frame_at(dist)
		if not f.is_empty():
			var curv := float(f.get("curvature", 0.0))
			if absf(curv) > 0.011:
				var out_sign := -signf(curv)
				for k in 8:
					var p := _ground_at(_pos_of(f, (path.half_width + 2.0) * out_sign,
						float(k) * 1.5 - 5.0))
					var yaw := atan2((f["tangent"] as Vector3).x, (f["tangent"] as Vector3).z)
					xforms.append(Transform3D(Basis(Vector3.UP, yaw), p + Vector3(0.0, 0.3, 0.0)))
				placed += 1
				dist += 80.0
				continue
		dist += 24.0
	RealAssetKit.place_chunked(container, "tyre_real", xforms, "TyreWalls", 500.0, false, stats)


static func _build_canyon_shack(container: Node3D, path: TrackPath, hero: Dictionary,
		rng: RandomNumberGenerator, stats: Dictionary) -> void:
	if hero.is_empty():
		return
	var center := _menu_stage(path, hero, 124.0, 34.0)
	if not VenueKit.clear_of_track(path, center, 12.0):
		center = _menu_stage(path, hero, 138.0, -34.0)
		if not VenueKit.clear_of_track(path, center, 12.0):
			return
	var base := _ground_at(center, -0.05)
	var yaw := atan2((hero["tangent"] as Vector3).x, (hero["tangent"] as Vector3).z)
	var basis := Basis(Vector3.UP, yaw)
	var planks := PbrAssets.weathered_planks()
	# 四根立柱 + 单坡屋顶 + 半截木板墙（小道具，不是主要建筑）
	var posts: Array[Transform3D] = []
	for sx: float in [-2.4, 2.4]:
		for sz: float in [-1.8, 1.8]:
			posts.append(Transform3D(basis, base + basis * Vector3(sx, 1.5, sz)))
	var post_mesh := BoxMesh.new()
	post_mesh.size = Vector3(0.22, 3.0, 0.22)
	_prop_mm(container, post_mesh, planks, posts, [], "CanyonShackPosts", stats, 620.0)
	var back_wall := MeshInstance3D.new()
	var bw := BoxMesh.new()
	bw.size = Vector3(5.0, 2.4, 0.16)
	back_wall.mesh = bw
	back_wall.material_override = planks
	back_wall.transform = Transform3D(basis, base + basis * Vector3(0.0, 1.2, -1.8))
	container.add_child(back_wall)
	var side_wall := MeshInstance3D.new()
	var sw := BoxMesh.new()
	sw.size = Vector3(0.16, 2.2, 3.4)
	side_wall.mesh = sw
	side_wall.material_override = planks
	side_wall.transform = Transform3D(basis, base + basis * Vector3(2.4, 1.1, 0.0))
	container.add_child(side_wall)
	var roof := MeshInstance3D.new()
	var rm := BoxMesh.new()
	rm.size = Vector3(5.8, 0.18, 4.6)
	roof.mesh = rm
	var roof_mat := PbrAssets.rusty_corrugated()
	roof.material_override = roof_mat
	roof.transform = Transform3D(basis * Basis(Vector3.RIGHT, 0.16), base + basis * Vector3(0.0, 3.15, 0.2))
	container.add_child(roof)
	# 旁边的木箱 + 油桶
	var crate := MeshInstance3D.new()
	var cm := BoxMesh.new()
	cm.size = Vector3(1.0, 0.9, 0.9)
	crate.mesh = cm
	crate.material_override = PbrAssets.planks()
	crate.transform = Transform3D(basis, base + basis * Vector3(3.3, 0.45, 1.4))
	container.add_child(crate)
	for k in 3:
		_real_scaled(container, "barrel_real",
			_ground_at(base + basis * Vector3(3.6 + float(k) * 0.85, 0.0, 2.4)),
			rng.randf() * TAU, 0.95, "CanyonShackBarrel_%d" % k, stats, Vector3.ONE, 420.0, false)
	stats["scenery"] = int(stats["scenery"]) + 1


## 电线杆 + 电缆（Poly Haven modular_electricity_poles 真实模型）。
static func _build_power_line(container: Node3D, path: TrackPath, rng: RandomNumberGenerator,
		stats: Dictionary, step: float, lateral: float) -> void:
	if not RealAssetKit.has("power_pole"):
		return
	var xforms: Array[Transform3D] = []
	var tops: Array[Vector3] = []
	var dist := 30.0
	var side := 1.0
	while dist < path.total_length:
		var f := path.frame_at(dist)
		if not f.is_empty():
			var p := _ground_at(_pos_of(f, lateral * side))
			if VenueKit.clear_of_track(path, p, 6.0):
				var yaw := atan2((f["side"] as Vector3).x, (f["side"] as Vector3).z)
				xforms.append(Transform3D(Basis(Vector3.UP, yaw), p))
				tops.append(p + Vector3(0.0, 7.0, 0.0))
		dist += step
		side = -side
	var made := RealAssetKit.place_chunked(container, "power_pole", xforms, "PowerLinePoles", 1000.0, false, stats)
	if made <= 0 or tops.size() < 2:
		return
	var cable_mesh := CylinderMesh.new()
	cable_mesh.top_radius = 1.0
	cable_mesh.bottom_radius = 1.0
	cable_mesh.height = 1.0
	cable_mesh.radial_segments = 4
	cable_mesh.rings = 1
	var cables: Array[Transform3D] = []
	for k in tops.size() - 1:
		var a: Vector3 = tops[k]
		var b: Vector3 = tops[k + 1]
		var mid := (a + b) * 0.5 - Vector3(0.0, 1.8, 0.0)
		var mid2 := mid - Vector3(0.0, 1.2, 0.0)
		cables.append(_beam_xform(a, mid, 0.045))
		cables.append(_beam_xform(mid, mid2, 0.045))
		cables.append(_beam_xform(mid2, b, 0.045))
	_prop_mm(container, cable_mesh, PbrAssets.metal(Vector2(1.0, 1.0)), cables, [], "PowerLineCables", stats, 900.0)


# ---------------------------------------------------------------------------
# 港湾：港池 / 货柜堆场 / 龙门吊 / 仓库 / 帆船 / 系缆桩
# ---------------------------------------------------------------------------

static func _build_harbor_landmarks(container: Node3D, path: TrackPath, theme: Dictionary,
		rng: RandomNumberGenerator, stats: Dictionary) -> void:
	var hero := _hero_spot(path)
	if hero.is_empty():
		return
	var basin := _find_harbor_basin(container, path, hero, rng, stats)
	_build_container_yard(container, path, hero, rng, stats, basin)
	if bool(basin.get("ok", false)):
		_build_gantry_cranes(container, basin, rng, stats)
		_build_harbor_ship(container, basin, rng, stats)
	_build_harbor_warehouses(container, path, hero, rng, stats, basin)
	_build_quay_props(container, path, hero, rng, stats, basin)
	# 港湾也放一排真实铸铁路灯（黄昏氛围）
	_build_real_lamps(container, path, rng, stats, 92.0, path.half_width + 4.2, true)


static func _find_harbor_basin(container: Node3D, path: TrackPath, hero: Dictionary,
		rng: RandomNumberGenerator, stats: Dictionary) -> Dictionary:
	var tangent: Vector3 = hero["tangent"]
	var side: Vector3 = hero["side"]
	var inside_sign := 1.0 if (hero["inside"] as Vector3).dot(side) > 0.0 else -1.0
	var size := Vector2(180.0, 112.0)
	# 港池必须落在菜单相机视锥内（复刻相机朝向，而不是沿赛道切线）
	var inside_sign2 := inside_sign
	for ahead in [118.0, 156.0, 196.0, 88.0, 236.0]:
		for lateral in [0.0, 46.0, -46.0, 92.0, -92.0]:
			var center: Vector3 = _menu_stage(path, hero, ahead, lateral * inside_sign2)
			center.y = 0.0
			if not _rect_clear(path, center, tangent, side, size.x * 0.5, size.y * 0.5, 14.0):
				continue
			var yaw := atan2(tangent.x, tangent.z)
			var water := _water_patch(container, center + Vector3(0.0, 0.07, 0.0), size, yaw,
				Color(0.02, 0.055, 0.1), Color(0.05, 0.14, 0.18), "HarborBasin")
			water.visibility_range_end = 1800.0
			# 混凝土岸壁（低模，真实 PBR 贴图）四段围合
			var quay_mat := PbrAssets.concrete(Vector2(8.0, 2.0))
			var basis := Basis(Vector3.UP, yaw)
			for sgn: float in [-1.0, 1.0]:
				var wall_a := MeshInstance3D.new()
				var wam := BoxMesh.new()
				wam.size = Vector3(size.x + 4.0, 1.5, 2.0)
				wall_a.mesh = wam
				wall_a.material_override = quay_mat
				wall_a.transform = Transform3D(basis,
					center + side * (size.y * 0.5 + 1.0) * sgn + Vector3(0.0, 0.75, 0.0))
				container.add_child(wall_a)
				var wall_b := MeshInstance3D.new()
				var wbm := BoxMesh.new()
				wbm.size = Vector3(2.0, 1.5, size.y + 4.0)
				wall_b.mesh = wbm
				wall_b.material_override = quay_mat
				wall_b.transform = Transform3D(basis,
					center + side * 0.0 + basis.x * (size.x * 0.5 + 1.0) * sgn + Vector3(0.0, 0.75, 0.0))
				container.add_child(wall_b)
			stats["nodes"] = int(stats.get("nodes", 0)) + 5
			return {"ok": true, "center": center, "tangent": tangent, "side": side, "size": size}
	# 没有合适的港池就退化成「干船坞」：货柜/吊机照样摆，只是没有水面
	return {"ok": false, "center": _ground_at(_pos_of(hero, 60.0, 70.0)),
		"tangent": tangent, "side": side, "size": Vector2.ZERO}


static func _build_container_yard(container: Node3D, path: TrackPath, hero: Dictionary,
		rng: RandomNumberGenerator, stats: Dictionary, basin: Dictionary) -> void:
	var has_quay := bool(basin.get("ok", false))
	var center: Vector3 = (basin["center"] as Vector3) if has_quay \
		else _ground_at(_pos_of(hero, 44.0, 60.0))
	var tangent: Vector3 = basin["tangent"] as Vector3
	var side: Vector3 = basin["side"] as Vector3
	var yaw := atan2(tangent.x, tangent.z)
	var basis := Basis(Vector3.UP, yaw)
	var box := BoxMesh.new()
	# 尺寸 (2.5, 2.6, 6.1)：局部 Z 沿路/沿切线，长边顺排向首尾相接
	box.size = Vector3(2.5, 2.6, 6.1)
	var mat := PbrAssets.container_metal(Vector2(1.0, 1.0))
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.68
	mat.metallic = 0.12
	var palette := [
		Color(0.95, 0.32, 0.28), Color(0.28, 0.55, 0.95), Color(0.35, 0.78, 0.45),
		Color(0.95, 0.78, 0.28), Color(0.75, 0.78, 0.8), Color(0.85, 0.45, 0.2),
		Color(0.45, 0.35, 0.65),
	]
	var xforms: Array[Transform3D] = []
	var colors: Array[Color] = []
	var anchor := center + (side * 68.0 if has_quay else side * 22.0)
	for row in 3:
		for col in 10:
			var p: Vector3
			if has_quay:
				p = anchor + tangent * (-58.0 + float(col) * 7.0) + side * (float(row) * 3.2)
			else:
				p = anchor + basis * Vector3(float(row) * 3.2, 0.0, -52.0 + float(col) * 7.0)
			p = _ground_at(p, 0.0)
			if not VenueKit.clear_of_track(path, p, 10.0):
				continue
			var stack := rng.randi_range(1, 3 if row < 2 else 2)
			var col_base: Color = palette[rng.randi() % palette.size()]
			for lvl in stack:
				var b := Basis(Vector3.UP, yaw + rng.randf_range(-0.05, 0.05))
				var lp := p + Vector3(0.0, 1.32 + float(lvl) * 2.62, 0.0)
				xforms.append(Transform3D(b, lp))
				colors.append(col_base.darkened(rng.randf_range(0.0, 0.22)))
			# 堆位登记为实体：VenueKit 道具、后摆散石按它避让
			RealAssetKit.register_solid(p, 3.3)
	if mat is StandardMaterial3D:
		(mat as StandardMaterial3D).vertex_color_use_as_albedo = false
	_prop_mm_tinted(container, box, mat, xforms, colors, "HarborContainers", stats, 1100.0, true)


static func _build_gantry_cranes(container: Node3D, basin: Dictionary,
		rng: RandomNumberGenerator, stats: Dictionary) -> void:
	var center: Vector3 = basin["center"]
	var tangent: Vector3 = basin["tangent"]
	var side: Vector3 = basin["side"]
	var half_s := float((basin["size"] as Vector2).y) * 0.5
	var yaw := atan2(tangent.x, tangent.z)
	var basis := Basis(Vector3.UP, yaw)
	var quay := center + side * (half_s + 2.0)
	quay.y = 1.5
	var metal := PbrAssets.metal(Vector2(5.0, 6.0))
	var legs: Array[Transform3D] = []
	var beams: Array[Transform3D] = []
	var braces: Array[Transform3D] = []
	var leg_mesh := BoxMesh.new()
	leg_mesh.size = Vector3(1.15, 1.0, 1.15)
	var beam_mesh := BoxMesh.new()
	beam_mesh.size = Vector3(1.0, 1.0, 1.0)
	var accent_mat := _emissive_mat(Color(1.0, 0.22, 0.14), 1.6)
	for k in 2:
		var base := quay + tangent * (-34.0 + float(k) * 66.0)
		for lx: float in [-6.0, 6.0]:
			for lz: float in [-9.0, 9.0]:
				var lp: Vector3 = base + basis * Vector3(lx, 13.0, lz)
				legs.append(Transform3D(basis.scaled(Vector3(1.0, 26.0, 1.0)), lp))
		# 顶部横梁（跨轨距方向）+ 伸向水面的悬臂
		beams.append(Transform3D(basis.scaled(Vector3(13.5, 1.4, 2.2)), base + Vector3(0.0, 26.0, 0.0)))
		beams.append(Transform3D(basis.scaled(Vector3(38.0, 1.1, 1.8)), base + basis * Vector3(21.0, 26.6, 0.0)))
		beams.append(Transform3D(basis.scaled(Vector3(4.0, 1.6, 4.0)), base + basis * Vector3(15.0, 25.6, 0.0)))
		# 斜撑
		for lz: float in [-9.0, 9.0]:
			braces.append(Transform3D(basis * Basis(Vector3.FORWARD, 0.52).scaled(Vector3(1.0, 1.0, 1.0)),
				base + basis * Vector3(0.0, 14.0, lz)))
		# 塔吊吊钩钢缆
		var cable := MeshInstance3D.new()
		var cm := BoxMesh.new()
		cm.size = Vector3(0.14, 13.0, 0.14)
		cable.mesh = cm
		cable.material_override = PbrAssets.metal(Vector2(1.0, 1.0))
		cable.transform = Transform3D(basis, base + basis * Vector3(31.0, 19.5, 0.0))
		container.add_child(cable)
		# 红色航空警示灯带
		var warn := MeshInstance3D.new()
		var wm := BoxMesh.new()
		wm.size = Vector3(13.6, 0.28, 2.3)
		warn.mesh = wm
		warn.material_override = accent_mat
		warn.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		warn.transform = Transform3D(basis, base + Vector3(0.0, 26.85, 0.0))
		container.add_child(warn)
		stats["nodes"] = int(stats.get("nodes", 0)) + 2
	_prop_mm(container, leg_mesh, metal, legs, [], "GantryLegs", stats, 1600.0, true)
	_prop_mm(container, beam_mesh, metal, beams, [], "GantryBeams", stats, 1600.0, true)
	_prop_mm(container, beam_mesh, metal, braces, [], "GantryBraces", stats, 1600.0, true)


static func _build_harbor_ship(container: Node3D, basin: Dictionary,
		rng: RandomNumberGenerator, stats: Dictionary) -> void:
	var center: Vector3 = basin["center"]
	var tangent: Vector3 = basin["tangent"]
	var side: Vector3 = basin["side"]
	var yaw := atan2(tangent.x, tangent.z)
	var pos := center + side * (-14.0) + tangent * (-8.0)
	pos.y = 0.4
	var basis := Basis(Vector3.UP, yaw + 0.22)
	var target_h := 26.0
	var s := RealAssetKit.scale_for_height("ship_real", target_h)
	_real_unique(container, "ship_real", Transform3D(basis.scaled(Vector3.ONE * s), pos),
		"HarborTallShip", stats, 2200.0, true)
	# 港池里的航标浮标
	var buoys: Array[Transform3D] = []
	for k in 4:
		var p := center + tangent * rng.randf_range(-40.0, 40.0) + side * rng.randf_range(-16.0, -2.0)
		p.y = -0.55
		buoys.append(Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3.ONE * 1.15), p))
	RealAssetKit.place_chunked(container, "buoy_real", buoys, "HarborBuoys", 900.0, false, stats)


static func _build_harbor_warehouses(container: Node3D, path: TrackPath, hero: Dictionary,
		rng: RandomNumberGenerator, stats: Dictionary, basin: Dictionary) -> void:
	if not RealAssetKit.has("factory_facade"):
		return
	var anchor: Vector3
	var tangent: Vector3
	var side: Vector3
	if bool(basin.get("ok", false)):
		anchor = (basin["center"] as Vector3) + (basin["side"] as Vector3) * 96.0
		tangent = basin["tangent"] as Vector3
		side = basin["side"] as Vector3
	else:
		anchor = _ground_at(_pos_of(hero, 74.0, 86.0))
		tangent = hero["tangent"] as Vector3
		side = hero["side"] as Vector3
	var yaw := atan2(tangent.x, tangent.z)
	var basis := Basis(Vector3.UP, yaw)
	var body_mat := PbrAssets.corrugated()
	var fdims := RealAssetKit.size("factory_facade")
	var roof_mat := PbrAssets.metal(Vector2(4.0, 3.0))
	for k in 3:
		var base: Vector3 = anchor + tangent * (-52.0 + float(k) * 56.0) + side * rng.randf_range(-6.0, 6.0)
		base = _ground_at(base)
		if not VenueKit.clear_of_track(path, base, 14.0):
			continue
		var w := rng.randf_range(34.0, 44.0)
		var h := rng.randf_range(12.0, 18.0)
		var d := rng.randf_range(20.0, 28.0)
		var body := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(w, h, d)
		body.mesh = bm
		body.material_override = body_mat
		body.transform = Transform3D(basis, base + Vector3(0.0, h * 0.5, 0.0))
		body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		container.add_child(body)
		var roof := MeshInstance3D.new()
		var rm := BoxMesh.new()
		rm.size = Vector3(w + 1.0, 0.8, d + 1.0)
		roof.mesh = rm
		roof.material_override = roof_mat
		roof.transform = Transform3D(basis, base + Vector3(0.0, h + 0.4, 0.0))
		container.add_child(roof)
		# 真实 CC0 厂房立面贴到朝向赛道的一面
		var toward := -side
		var sx := minf(w * 1.02, 48.0) / maxf(fdims.x, 0.01)
		var sy := h / maxf(fdims.y, 0.01)
		var fb := Basis(Vector3.UP, atan2(toward.x, toward.z)).scaled(Vector3(sx, sy, 1.0))
		var fp: Vector3 = base + toward * (d * 0.5 + 0.8)
		fp.y = base.y + h * 0.5
		var wf := _real_unique(container, "factory_facade", Transform3D(fb, fp),
			"HarborWarehouseFacade_%d" % k, stats, 1800.0, true)
		if wf != null:
			RealAssetKit.darken_albedo(wf, 0.78)
		# 卷帘门（真实 CC0）
		if RealAssetKit.has("rollershutter"):
			for dn in 2:
				var dp := base + toward * (d * 0.5 + 1.0) + tangent * (w * 0.22 * (1.0 if dn == 0 else -1.0))
				dp.y = base.y + 1.2
				_real_scaled(container, "rollershutter", dp, atan2(toward.x, toward.z), 2.4,
					"HarborDoor_%d_%d" % [k, dn], stats, Vector3.ONE, 900.0, false)
		stats["nodes"] = int(stats.get("nodes", 0)) + 2


static func _build_quay_props(container: Node3D, path: TrackPath, hero: Dictionary,
		rng: RandomNumberGenerator, stats: Dictionary, basin: Dictionary) -> void:
	# 油桶
	_scatter_real(container, path, rng, "barrel_real", 14, 6.0, 24.0, 0.9, 1.05,
		"HarborBarrels", 480.0, 4.0)
	# 系缆桩：真实金属 PBR 的低模圆柱，沿码头边等距
	var bollard_mesh := CylinderMesh.new()
	bollard_mesh.top_radius = 0.26
	bollard_mesh.bottom_radius = 0.3
	bollard_mesh.height = 0.95
	bollard_mesh.radial_segments = 8
	bollard_mesh.rings = 1
	var xforms: Array[Transform3D] = []
	if bool(basin.get("ok", false)):
		var center: Vector3 = basin["center"]
		var tangent: Vector3 = basin["tangent"]
		var side: Vector3 = basin["side"]
		var half_s := float((basin["size"] as Vector2).y) * 0.5
		for k in 18:
			var p := center + tangent * (-80.0 + float(k) * 9.5) + side * (half_s + 2.4)
			p.y = 1.5
			xforms.append(Transform3D(Basis(), p + Vector3(0.0, 0.48, 0.0)))
	else:
		for k in 12:
			var f := path.frame_at(rng.randf() * path.total_length)
			if f.is_empty():
				continue
			var p := _ground_at(_pos_of(f, path.half_width + rng.randf_range(5.0, 14.0)))
			xforms.append(Transform3D(Basis(), p + Vector3(0.0, 0.48, 0.0)))
	if not xforms.is_empty():
		_prop_mm(container, bollard_mesh, PbrAssets.metal(Vector2(1.0, 1.0)), xforms, [],
			"HarborBollards", stats, 520.0)


# ---------------------------------------------------------------------------
# 天际环城：高架快速路 / 广告牌 / 绿化带
# ---------------------------------------------------------------------------

static func _build_skyline_landmarks(container: Node3D, path: TrackPath, theme: Dictionary,
		rng: RandomNumberGenerator, stats: Dictionary) -> void:
	var hero := _hero_spot(path)
	if hero.is_empty():
		return
	var accent := _color(String(theme.get("accent", "#ffb547")), Color(1.0, 0.7, 0.3))
	_build_elevated_expressway(container, path, hero, rng, stats, accent)
	_build_green_belt(container, path, rng, stats)
	_build_billboards(container, path, theme, rng, stats, 7, "SKYLINE  CIRCUIT")
	_build_ad_screens(container, path, rng, stats, 3)
	_build_landmark_towers(container, path, hero, rng, stats, accent, false)


static func _build_elevated_expressway(container: Node3D, path: TrackPath, hero: Dictionary,
		rng: RandomNumberGenerator, stats: Dictionary, accent: Color) -> void:
	var tangent: Vector3 = hero["tangent"]
	var side: Vector3 = hero["side"]
	var out_sign := 1.0 if (hero["outside"] as Vector3).dot(side) > 0.0 else -1.0
	var deck_mesh := BoxMesh.new()
	deck_mesh.size = Vector3(14.0, 1.2, 1.0)
	var pier_mesh := CylinderMesh.new()
	pier_mesh.top_radius = 0.9
	pier_mesh.bottom_radius = 1.3
	pier_mesh.height = 1.0
	pier_mesh.radial_segments = 8
	pier_mesh.rings = 1
	var rail_mesh := BoxMesh.new()
	rail_mesh.size = Vector3(0.35, 1.1, 1.0)
	var strip_mesh := BoxMesh.new()
	strip_mesh.size = Vector3(0.28, 0.3, 1.0)
	var deck_x: Array[Transform3D] = []
	var pier_x: Array[Transform3D] = []
	var rail_x: Array[Transform3D] = []
	var strip_x: Array[Transform3D] = []
	var total := 470.0
	var step := 24.0
	var start := float(hero["hero_dist"]) - 200.0
	var count := int(total / step)
	var lamp_x: Array[Transform3D] = []
	for i in count:
		var f := path.frame_at(start + float(i) * step)
		if f.is_empty():
			continue
		var lateral := path.half_width + 86.0
		var p: Vector3 = (f["pos"] as Vector3) + (f["side"] as Vector3) * lateral * out_sign
		p.y = 0.0
		var yaw := atan2((f["tangent"] as Vector3).x, (f["tangent"] as Vector3).z)
		var basis := Basis(Vector3.UP, yaw)
		deck_x.append(Transform3D(basis.scaled(Vector3(13.0, 1.1, step + 1.2)), p + Vector3(0.0, 11.6, 0.0)))
		rail_x.append(Transform3D(basis.scaled(Vector3(0.7, 0.7, step + 1.2)), p + basis * Vector3(6.1, 12.35, 0.0)))
		rail_x.append(Transform3D(basis.scaled(Vector3(0.7, 0.7, step + 1.2)), p + basis * Vector3(-6.1, 12.35, 0.0)))
		strip_x.append(Transform3D(basis.scaled(Vector3(0.55, 0.42, step + 1.2)), p + basis * Vector3(6.35, 10.95, 0.0)))
		if i % 2 == 0:
			pier_x.append(Transform3D(basis.scaled(Vector3(1.0, 11.6, 1.0)), p + Vector3(0.0, 5.8, 0.0)))
			lamp_x.append(Transform3D(Basis().scaled(Vector3.ONE * 1.35), p + basis * Vector3(5.2, 12.7, 0.0)))
	var concrete := PbrAssets.concrete(Vector2(6.0, 2.0))
	_prop_mm(container, deck_mesh, concrete, deck_x, [], "SkylineExpresswayDeck", stats, 1600.0, true)
	_prop_mm(container, pier_mesh, concrete, pier_x, [], "SkylineExpresswayPiers", stats, 1600.0)
	_prop_mm(container, rail_mesh, PbrAssets.metal(Vector2(2.0, 2.0)), rail_x, [], "SkylineExpresswayRails", stats, 1600.0)
	_prop_mm(container, strip_mesh, _emissive_mat(accent.darkened(0.15), 1.5), strip_x, [], "SkylineExpresswayNeon", stats, 1600.0)
	if RealAssetKit.has("street_lamp_01_real") and not lamp_x.is_empty():
		RealAssetKit.place_chunked(container, "street_lamp_01_real", lamp_x,
			"SkylineExpresswayLamps", 1400.0, false, stats)
		_glow_prefix(container, "SkylineExpresswayLamps", 2.0, Color(1.0, 0.8, 0.5))


static func _build_green_belt(container: Node3D, path: TrackPath, rng: RandomNumberGenerator,
		stats: Dictionary) -> void:
	var content := clampf(Settings.content_scale(), 0.3, 1.5)
	_scatter_real(container, path, rng, "shrub_real01", int(round(60.0 * content)),
		3.0, 16.0, 0.8, 1.8, "SkylineBeltShrubs", 380.0, 2.4)
	_scatter_real(container, path, rng, "realtree_01", int(round(26.0 * content)),
		10.0, 28.0, 5.0, 8.5, "SkylineBeltTrees", 620.0, 4.0)
	# 绿化带草坪：真实 3D 草簇，沿路肩内侧铺一条窄带
	_scatter_real(container, path, rng, "grass_medium02_lod", int(round(260.0 * content)),
		2.0, 9.0, 0.7, 1.1, "SkylineBeltGrass", 190.0, 1.6)


## 冰材质：菲涅尔边缘发蓝的冰面/冰柱（纯 shader，无贴图，开销极低）。
static func _ice_material() -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = """shader_type spatial;
render_mode blend_mix, cull_back, depth_draw_opaque;
uniform vec4 ice_deep : source_color = vec4(0.12, 0.32, 0.55, 1.0);
uniform vec4 ice_tip : source_color = vec4(0.72, 0.92, 1.0, 1.0);
void fragment() {
	float fres = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 2.1);
	vec3 col = mix(ice_deep.rgb, ice_tip.rgb, fres);
	ALBEDO = col;
	ROUGHNESS = mix(0.06, 0.34, fres);
	METALLIC = 0.12;
	SPECULAR = 0.9;
	EMISSION = ice_tip.rgb * 0.14;
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = sh
	return mat


## 熔岩材质：发光裂缝（unshaded + 脉动），不参与光照，性价比最高的发光面片。
static func _lava_material() -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = """shader_type spatial;
render_mode unshaded, cull_disabled, fog_disabled;
void fragment() {
	float band = 1.0 - abs(UV.y * 2.0 - 1.0);
	float pulse = 0.82 + 0.18 * sin(TIME * 1.6 + UV.x * 14.0);
	float core = smoothstep(0.0, 0.72, band);
	vec3 col = mix(vec3(0.85, 0.16, 0.02), vec3(1.0, 0.86, 0.32), core);
	ALBEDO = col * pulse;
	EMISSION = col * (1.5 + core * 1.8);
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = sh
	return mat


static func _lava_ribbon_mesh(length: float, width: float, segs: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var prev_a := Vector3.ZERO
	var prev_b := Vector3.ZERO
	for i in segs:
		var t := float(i) / float(maxi(segs - 1, 1))
		var x := (t - 0.5) * length
		var center_z := sin(t * 6.5 + 0.7) * width * 0.5
		var half_w := width * (0.22 + 0.2 * absf(sin(t * 9.0 + 1.6)))
		var a := Vector3(x, 0.0, center_z - half_w)
		var b := Vector3(x, 0.0, center_z + half_w)
		if i > 0:
			st.set_normal(Vector3.UP)
			st.set_uv(Vector2(t - 1.0 / float(segs), 0.0))
			st.add_vertex(prev_a)
			st.set_normal(Vector3.UP)
			st.set_uv(Vector2(t - 1.0 / float(segs), 1.0))
			st.add_vertex(prev_b)
			st.set_normal(Vector3.UP)
			st.set_uv(Vector2(t, 0.0))
			st.add_vertex(a)
			st.set_normal(Vector3.UP)
			st.set_uv(Vector2(t - 1.0 / float(segs), 1.0))
			st.add_vertex(prev_b)
			st.set_normal(Vector3.UP)
			st.set_uv(Vector2(t, 1.0))
			st.add_vertex(b)
			st.set_normal(Vector3.UP)
			st.set_uv(Vector2(t, 0.0))
			st.add_vertex(a)
		prev_a = a
		prev_b = b
	return st.commit()


# ---------------------------------------------------------------------------
# 冰川：冰柱群 / 蓝色冰面 / 雪堤 / 极地旗 / 雪地车残骸 / 冻结帆船
# ---------------------------------------------------------------------------

static func _build_ice_landmarks(container: Node3D, path: TrackPath, theme: Dictionary,
		rng: RandomNumberGenerator, stats: Dictionary) -> void:
	var hero := _hero_spot(path)
	if hero.is_empty():
		return
	var ice := _ice_material()
	var anchor := _in_view_track_anchor(path, hero, 12.0, 62.0)
	var center: Vector3 = (anchor["pos"] as Vector3) + (anchor["side"] as Vector3) * \
		(14.0 if rng.randf() < 0.5 else -14.0)
	var shard_mesh := CylinderMesh.new()
	shard_mesh.top_radius = 0.06
	shard_mesh.bottom_radius = 1.0
	shard_mesh.height = 1.0
	shard_mesh.radial_segments = 6
	shard_mesh.rings = 1
	var shards: Array[Transform3D] = []
	# 特色弯：高冰柱阵（菜单镜头正对）
	for k in 16:
		var angle := TAU * float(k) / 16.0 + rng.randf_range(-0.3, 0.3)
		var radius := rng.randf_range(6.0, 26.0)
		var p := center + Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)
		p = _ground_at(p, -0.2)
		if not VenueKit.clear_of_track(path, p, 4.0):
			continue
		var h := rng.randf_range(9.0, 26.0)
		var w := rng.randf_range(1.4, 4.0)
		var b := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(w, h, w))
		b = b * Basis(Vector3.RIGHT, rng.randf_range(-0.1, 0.1))
		shards.append(Transform3D(b, p))
	# 远处大冰墙（天际线地标）
	for k in 7:
		var f := path.frame_at(float(anchor["dist"]) + 70.0 + float(k) * 38.0)
		if f.is_empty():
			continue
		var p := _ground_at(_pos_of(f, rng.randf_range(30.0, 56.0) * (1.0 if k % 2 == 0 else -1.0)), -0.5)
		if not VenueKit.clear_of_track(path, p, 6.0):
			continue
		var h := rng.randf_range(16.0, 34.0)
		var w := rng.randf_range(3.0, 7.0)
		shards.append(Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(w, h, w)), p))
	# 全赛道散布
	var attempts := 60
	while shards.size() < 48 and attempts > 0:
		attempts -= 1
		var f := path.frame_at(rng.randf() * path.total_length)
		if f.is_empty():
			continue
		var p := _ground_at(_pos_of(f, rng.randf_range(13.0, 58.0) * (1.0 if rng.randf() < 0.5 else -1.0)), -0.2)
		if not VenueKit.clear_of_track(path, p, 5.0):
			continue
		var h := rng.randf_range(2.5, 11.0)
		var w := rng.randf_range(0.6, 2.2)
		shards.append(Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(w, h, w)), p))
	_prop_mm(container, shard_mesh, ice, shards, [], "GlacierIceShards", stats, 1000.0, false)
	# 蓝色冰面（贴地发光冰湖）
	var pool_mesh := CylinderMesh.new()
	pool_mesh.top_radius = 1.0
	pool_mesh.bottom_radius = 1.0
	pool_mesh.height = 0.12
	pool_mesh.radial_segments = 14
	pool_mesh.rings = 1
	var pools: Array[Transform3D] = []
	for k in 14:
		var p: Vector3
		if k < 5:
			p = _ground_at(center + Vector3(rng.randf_range(-26.0, 26.0), 0.05, rng.randf_range(-26.0, 26.0)), 0.05)
		else:
			var f := path.frame_at(rng.randf() * path.total_length)
			if f.is_empty():
				continue
			p = _ground_at(_pos_of(f, rng.randf_range(8.0, 34.0) * (1.0 if rng.randf() < 0.5 else -1.0)), 0.05)
		if not VenueKit.clear_of_track(path, p, 4.0):
			continue
		var r := rng.randf_range(3.0, 11.0)
		pools.append(Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(r, 1.0, r * rng.randf_range(0.6, 1.2))), p))
	_prop_mm(container, pool_mesh, ice, pools, [], "GlacierIcePools", stats, 700.0, false)
	# 雪堤 + 极地旗
	_build_snow_banks(container, path, rng, stats)
	_build_marker_flags(container, path, rng, stats, Color(0.3, 0.68, 1.0))
	# 雪地车残骸（真实 covered_car 半埋进雪里）
	if RealAssetKit.has("car_wreck_real"):
		var wrecks: Array[Transform3D] = []
		for k in 6:
			var f := path.frame_at(rng.randf() * path.total_length)
			if f.is_empty():
				continue
			var p := _ground_at(_pos_of(f, rng.randf_range(16.0, 40.0) * (1.0 if rng.randf() < 0.5 else -1.0)), -0.32)
			if not VenueKit.clear_of_track(path, p, 6.0):
				continue
			var b := Basis(Vector3.UP, rng.randf() * TAU)
			b = b * Basis(Vector3.RIGHT, rng.randf_range(-0.12, 0.12))
			wrecks.append(Transform3D(b, p))
		RealAssetKit.place_chunked(container, "car_wreck_real", wrecks, "GlacierWrecks", 620.0, false, stats)
	# 冻结在冰原上的帆船：地图远景地标
	_build_frozen_ship(container, path, hero, rng, stats)


static func _build_frozen_ship(container: Node3D, path: TrackPath, hero: Dictionary,
		rng: RandomNumberGenerator, stats: Dictionary) -> void:
	if not RealAssetKit.has("ship_real"):
		return
	var anchor := _in_view_track_anchor(path, hero, 30.0, 108.0)
	var f := path.frame_at(float(anchor["dist"]) + 96.0)
	if f.is_empty():
		return
	var side_sign := 1.0 if rng.randf() < 0.5 else -1.0
	var pos := _ground_at(_pos_of(f, rng.randf_range(34.0, 58.0) * side_sign), -0.4)
	var yaw := atan2((f["tangent"] as Vector3).x, (f["tangent"] as Vector3).z) + rng.randf_range(-0.5, 0.5)
	var s := RealAssetKit.scale_for_height("ship_real", 20.0)
	var b := Basis(Vector3.UP, yaw)
	b = b * Basis(Vector3.RIGHT, 0.05)
	_real_unique(container, "ship_real", Transform3D(b.scaled(Vector3.ONE * s), pos),
		"GlacierFrozenShip", stats, 2000.0, true)
	# 船周围一圈冰原
	var ice := _ice_material()
	var disc_mesh := CylinderMesh.new()
	disc_mesh.top_radius = 1.0
	disc_mesh.bottom_radius = 1.0
	disc_mesh.height = 0.1
	disc_mesh.radial_segments = 16
	disc_mesh.rings = 1
	var disc := MeshInstance3D.new()
	disc.mesh = disc_mesh
	disc.material_override = ice
	disc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	disc.transform = Transform3D(Basis(Vector3.UP, yaw).scaled(Vector3(62.0, 1.0, 46.0)),
		pos + Vector3(0.0, -2.6, 0.0))
	disc.visibility_range_end = 2000.0
	container.add_child(disc)


# ---------------------------------------------------------------------------
# 熔岩：黑岩柱 / 熔岩裂缝与熔岩池 / 废弃工厂与管道 / 烟囱
# ---------------------------------------------------------------------------

static func _build_volcanic_landmarks(container: Node3D, path: TrackPath, theme: Dictionary,
		rng: RandomNumberGenerator, stats: Dictionary) -> void:
	var hero := _hero_spot(path)
	if hero.is_empty():
		return
	# --- 1) 黑玄武岩柱（真实 CC0 岩壁几何拉伸 + 深色重染） ---
	var asset := "rock_face"
	if RealAssetKit.has(asset):
		var dims := RealAssetKit.size(asset)
		var ref_h := maxf(dims.y, 0.5)
		var ref_w := maxf(maxf(dims.x, dims.z), 0.5)
		var pillars: Array[Transform3D] = []
		var anchor := _in_view_track_anchor(path, hero, 30.0, 110.0)
		var center: Vector3 = (anchor["pos"] as Vector3) + (anchor["side"] as Vector3) * \
			(18.0 if rng.randf() < 0.5 else -18.0)
		for k in 12:
			var angle := TAU * float(k) / 12.0 + rng.randf_range(-0.3, 0.3)
			var radius := rng.randf_range(8.0, 30.0)
			var p := _ground_at(center + Vector3(cos(angle) * radius, 0.0, sin(angle) * radius), -0.5)
			var h := rng.randf_range(10.0, 28.0)
			var w := rng.randf_range(1.6, 3.8) / ref_w
			var b := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(w, h / ref_h, w))
			pillars.append(Transform3D(b, p))
		var attempts := 50
		while pillars.size() < 34 and attempts > 0:
			attempts -= 1
			var f := path.frame_at(rng.randf() * path.total_length)
			if f.is_empty():
				continue
			var p := _ground_at(_pos_of(f, rng.randf_range(16.0, 62.0) * (1.0 if rng.randf() < 0.5 else -1.0)), -0.4)
			if not VenueKit.clear_of_track(path, p, 5.0):
				continue
			var h := rng.randf_range(4.0, 14.0)
			var w := rng.randf_range(1.0, 2.6) / ref_w
			pillars.append(Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(w, h / ref_h, w)), p))
		_place_tinted(container, asset, pillars, "MagmaBasalt", Color(0.34, 0.29, 0.3), 820.0, stats, false)
	# --- 2) 熔岩裂缝 + 熔岩池 ---
	_build_lava_fields(container, path, rng, stats, hero)
	# --- 3) 废弃炼油厂（烟囱/储罐/管道，全部真实 PBR 材质） ---
	_build_refinery(container, path, hero, rng, stats)
	# --- 4) 路边油桶 / 工业管道废料 ---
	_scatter_real(container, path, rng, "barrel_real", 14, 5.0, 22.0, 0.9, 1.05,
		"MagmaBarrels", 420.0, 3.0)
	_scatter_real(container, path, rng, "industrial_pipes", 8, 8.0, 28.0, 1.5, 2.3,
		"MagmaPipeScrap", 700.0, 5.0, -0.4, true)


static func _build_lava_fields(container: Node3D, path: TrackPath, rng: RandomNumberGenerator,
		stats: Dictionary, hero: Dictionary) -> void:
	var lava := _lava_material()
	var meshes: Array[ArrayMesh] = []
	for k in 3:
		meshes.append(_lava_ribbon_mesh(24.0 + float(k) * 14.0, 2.2 + float(k) * 0.9, 22))
	var all_ribbons: Array = [[], [], []]
	# 特色弯：三条大地裂缝环绕（菜单镜头可见）
	for k in 3:
		var p := _ground_at(_menu_stage(path, hero, 58.0 + float(k) * 32.0,
			-28.0 + float(k) * 24.0), 0.07)
		if not VenueKit.clear_of_track(path, p, 4.0):
			continue
		(all_ribbons[k] as Array).append(Transform3D(
			Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(1.4, 1.0, 1.4)), p))
	# 全赛道随机裂缝
	for k in 20:
		var f := path.frame_at(rng.randf() * path.total_length)
		if f.is_empty():
			continue
		var p := _ground_at(_pos_of(f, rng.randf_range(9.0, 42.0) * (1.0 if rng.randf() < 0.5 else -1.0)), 0.07)
		if not VenueKit.clear_of_track(path, p, 3.0):
			continue
		var idx := k % 3
		(all_ribbons[idx] as Array).append(Transform3D(
			Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(rng.randf_range(0.8, 1.6), 1.0, rng.randf_range(0.8, 1.6))), p))
	for idx in 3:
		var typed: Array[Transform3D] = []
		for xf in (all_ribbons[idx] as Array):
			typed.append(xf as Transform3D)
		_prop_mm(container, meshes[idx], lava, typed, [], "MagmaLavaCracks_%d" % idx, stats, 800.0)
	# 熔岩池（发光的圆盘）
	var pool_mesh := CylinderMesh.new()
	pool_mesh.top_radius = 1.0
	pool_mesh.bottom_radius = 1.0
	pool_mesh.height = 0.14
	pool_mesh.radial_segments = 12
	pool_mesh.rings = 1
	var pools: Array[Transform3D] = []
	for k in 10:
		var f := path.frame_at(rng.randf() * path.total_length)
		if f.is_empty():
			continue
		var p := _ground_at(_pos_of(f, rng.randf_range(12.0, 38.0) * (1.0 if rng.randf() < 0.5 else -1.0)), 0.06)
		if not VenueKit.clear_of_track(path, p, 4.0):
			continue
		var r := rng.randf_range(2.0, 6.5)
		pools.append(Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(r, 1.0, r * rng.randf_range(0.7, 1.2))), p))
	_prop_mm(container, pool_mesh, lava, pools, [], "MagmaLavaPools", stats, 760.0)


static func _build_refinery(container: Node3D, path: TrackPath, hero: Dictionary,
		rng: RandomNumberGenerator, stats: Dictionary) -> void:
	var anchor := _in_view_track_anchor(path, hero, 40.0, 140.0)
	var center: Vector3 = (anchor["pos"] as Vector3) + (anchor["side"] as Vector3) * 34.0
	if not VenueKit.clear_of_track(path, center, 20.0):
		center = (anchor["pos"] as Vector3) - (anchor["side"] as Vector3) * 34.0
		if not VenueKit.clear_of_track(path, center, 20.0):
			return
	var base := _ground_at(center)
	var yaw := atan2((hero["tangent"] as Vector3).x, (hero["tangent"] as Vector3).z)
	var basis := Basis(Vector3.UP, yaw)
	var rusty := PbrAssets.rusty_corrugated()
	var metal := PbrAssets.metal(Vector2(4.0, 6.0))
	var lava := _lava_material()
	# 烟囱（两根）
	var chim_mesh := CylinderMesh.new()
	chim_mesh.top_radius = 0.85
	chim_mesh.bottom_radius = 1.7
	chim_mesh.height = 1.0
	chim_mesh.radial_segments = 10
	chim_mesh.rings = 1
	var chims: Array[Transform3D] = []
	for k in 2:
		var p := base + basis * Vector3(-13.0 + float(k) * 24.0, 0.0, 0.0)
		chims.append(Transform3D(basis.scaled(Vector3(1.0, 27.0, 1.0)), p + Vector3(0.0, 13.5, 0.0)))
	_prop_mm(container, chim_mesh, rusty, chims, [], "MagmaChimneys", stats, 1400.0, true)
	# 烟囱顶的熔岩口
	var glow_mesh := CylinderMesh.new()
	glow_mesh.top_radius = 1.0
	glow_mesh.bottom_radius = 1.0
	glow_mesh.height = 0.4
	glow_mesh.radial_segments = 10
	glow_mesh.rings = 1
	var glows: Array[Transform3D] = []
	for k in 2:
		var p := base + basis * Vector3(-13.0 + float(k) * 24.0, 27.2, 0.0)
		glows.append(Transform3D(basis.scaled(Vector3(1.35, 1.0, 1.35)), p))
	_prop_mm(container, glow_mesh, lava, glows, [], "MagmaChimneyGlow", stats, 1300.0)
	# 储罐（两个大圆柱）
	var tank_mesh := CylinderMesh.new()
	tank_mesh.top_radius = 1.0
	tank_mesh.bottom_radius = 1.0
	tank_mesh.height = 1.0
	tank_mesh.radial_segments = 12
	tank_mesh.rings = 1
	var tanks: Array[Transform3D] = []
	for k in 2:
		var p := base + basis * Vector3(-6.0 + float(k) * 14.0, 0.0, -14.0)
		tanks.append(Transform3D(basis.scaled(Vector3(5.2, 9.0, 5.2)), p + Vector3(0.0, 4.5, 0.0)))
	_prop_mm(container, tank_mesh, metal, tanks, [], "MagmaStorageTanks", stats, 1300.0, true)
	# 水平管道：储罐 → 烟囱（真实金属 PBR 的细圆柱）
	var pipe_mesh := CylinderMesh.new()
	pipe_mesh.top_radius = 1.0
	pipe_mesh.bottom_radius = 1.0
	pipe_mesh.height = 1.0
	pipe_mesh.radial_segments = 6
	pipe_mesh.rings = 1
	var pipes: Array[Transform3D] = []
	for k in 2:
		var a: Vector3 = base + basis * Vector3(-6.0 + float(k) * 14.0, 4.2, -14.0)
		var b: Vector3 = base + basis * Vector3(-13.0 + float(k) * 24.0, 7.0 + float(k) * 2.0, -1.0)
		var mid := (a + b) * 0.5 + Vector3(0.0, 2.2, 0.0)
		pipes.append(_beam_xform(a, mid, 0.32))
		pipes.append(_beam_xform(mid, b, 0.32))
	_prop_mm(container, pipe_mesh, metal, pipes, [], "MagmaRefineryPipes", stats, 1200.0)
	# 真实 CC0 工业管道堆 + 走道
	for k in 3:
		var p := base + basis * Vector3(-20.0 + float(k) * 9.0, 0.0, 12.0)
		_real_scaled(container, "industrial_pipes", _ground_at(p), rng.randf() * TAU, 2.2,
			"MagmaPipeRack_%d" % k, stats, Vector3.ONE, 1000.0, true)
	var platform := MeshInstance3D.new()
	var pm := BoxMesh.new()
	pm.size = Vector3(26.0, 0.5, 3.2)
	platform.mesh = pm
	platform.material_override = metal
	platform.transform = Transform3D(basis, base + basis * Vector3(0.0, 8.6, -6.0))
	container.add_child(platform)
	stats["scenery"] = int(stats["scenery"]) + 1


## 海滩救生塔：项目内 Blender 木构件 + 真实木板 PBR 贴图的小型地标。
static func _build_lifeguard_tower(container: Node3D, path: TrackPath,
		rng: RandomNumberGenerator, stats: Dictionary, sea_dir: Vector3,
		along_shore: Vector3, radius: float, along: float) -> void:
	var pos := sea_dir * radius + along_shore * along
	pos = _ground_at(pos, 0.0)
	if not VenueKit.clear_of_track(path, pos, 8.0):
		return
	var planks := PbrAssets.planks()
	var paint := StandardMaterial3D.new()
	paint.albedo_color = Color(0.92, 0.92, 0.9)
	paint.roughness = 0.7
	var red := StandardMaterial3D.new()
	red.albedo_color = Color(0.85, 0.16, 0.14)
	red.roughness = 0.75
	var basis := Basis(Vector3.UP, atan2(sea_dir.x, sea_dir.z))
	# 四根腿
	var legs: Array[Transform3D] = []
	for sx: float in [-1.15, 1.15]:
		for sz: float in [-0.95, 0.95]:
			legs.append(Transform3D(basis, pos + basis * Vector3(sx, 1.35, sz)))
	var leg_mesh := BoxMesh.new()
	leg_mesh.size = Vector3(0.22, 2.7, 0.22)
	_prop_mm(container, leg_mesh, planks, legs, [], "LifeguardLegs", stats, 700.0)
	# 平台
	var deck := MeshInstance3D.new()
	var dm := BoxMesh.new()
	dm.size = Vector3(3.1, 0.18, 2.7)
	deck.mesh = dm
	deck.material_override = planks
	deck.transform = Transform3D(basis, pos + basis * Vector3(0.0, 2.72, 0.0))
	container.add_child(deck)
	# 小屋（背板 + 两侧 + 顶盖 + 窗）
	var cabin := MeshInstance3D.new()
	var cm := BoxMesh.new()
	cm.size = Vector3(2.9, 1.9, 2.4)
	cabin.mesh = cm
	cabin.material_override = paint
	cabin.transform = Transform3D(basis, pos + basis * Vector3(0.0, 3.75, 0.0))
	cabin.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	container.add_child(cabin)
	var roof := MeshInstance3D.new()
	var rm := BoxMesh.new()
	rm.size = Vector3(3.4, 0.16, 2.9)
	roof.mesh = rm
	roof.material_override = red
	roof.transform = Transform3D(basis, pos + basis * Vector3(0.0, 4.78, 0.0))
	container.add_child(roof)
	var window := MeshInstance3D.new()
	var wm := BoxMesh.new()
	wm.size = Vector3(1.5, 0.75, 0.12)
	window.mesh = wm
	var glass := StandardMaterial3D.new()
	glass.albedo_color = Color(0.1, 0.2, 0.26)
	glass.roughness = 0.15
	glass.metallic = 0.4
	window.material_override = glass
	window.transform = Transform3D(basis, pos + basis * Vector3(0.0, 3.95, 1.22))
	container.add_child(window)
	# 旗杆 + 红旗（离岸流警示旗）
	var pole := MeshInstance3D.new()
	var pm := CylinderMesh.new()
	pm.top_radius = 0.03
	pm.bottom_radius = 0.05
	pm.height = 2.4
	pm.radial_segments = 5
	pm.rings = 1
	pole.mesh = pm
	pole.material_override = PbrAssets.metal(Vector2(1.0, 1.0))
	pole.transform = Transform3D(basis, pos + basis * Vector3(1.2, 5.6, -0.8))
	container.add_child(pole)
	var flag := MeshInstance3D.new()
	var fm := BoxMesh.new()
	fm.size = Vector3(0.9, 0.55, 0.04)
	flag.mesh = fm
	flag.material_override = _emissive_mat(Color(1.0, 0.15, 0.1), 0.8)
	flag.transform = Transform3D(basis, pos + basis * Vector3(1.7, 6.35, -0.8))
	container.add_child(flag)
	stats["nodes"] = int(stats.get("nodes", 0)) + 6
	stats["scenery"] = int(stats["scenery"]) + 1


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------


## 赛道禁入区过滤：几何（mesh AABB 半径 × 实例缩放）压进路面的摆放丢弃。
## 返回保留的索引，便于颜色/自定义数据等平行数组同步过滤。
static func _keepout_keep_idx(mesh: Mesh, xforms: Array[Transform3D]) -> Array[int]:
	var idxs: Array[int] = []
	if RealAssetKit.keepout_pts.is_empty():
		idxs.resize(xforms.size())
		for i in idxs.size():
			idxs[i] = i
		return idxs
	var radius := RealAssetKit.mesh_radius(mesh)
	for i in xforms.size():
		var xf := xforms[i]
		var sc: float = maxf(xf.basis.get_scale().x, xf.basis.get_scale().z)
		if RealAssetKit.keepout_clear(xf.origin, radius * maxf(sc, 0.01)):
			idxs.append(i)
	return idxs


static func _keepout_filter(mesh: Mesh, xforms: Array[Transform3D]) -> Array[Transform3D]:
	var kept: Array[Transform3D] = []
	for i in _keepout_keep_idx(mesh, xforms):
		kept.append(xforms[i])
	return kept


static func _mk_multimesh(container: Node3D, mesh: Mesh, material: Material,
		xforms: Array[Transform3D], colors: Array, node_name: String, stats: Dictionary) -> MultiMeshInstance3D:
	var keep_idx := _keepout_keep_idx(mesh, xforms)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.use_colors = not colors.is_empty()
	mm.instance_count = keep_idx.size()
	for i in keep_idx.size():
		var src: int = keep_idx[i]
		mm.set_instance_transform(i, xforms[src])
		if mm.use_colors:
			mm.set_instance_color(i, colors[src])
	var mmi := MultiMeshInstance3D.new()
	mmi.name = node_name
	mmi.multimesh = mm
	mmi.material_override = material
	container.add_child(mmi)
	stats["meshes"] = int(stats["meshes"]) + 1
	stats["instances"] = int(stats["instances"]) + keep_idx.size()
	return mmi


static func _mk_multimesh_custom(container: Node3D, mesh: Mesh, material: Material,
		xforms: Array[Transform3D], colors: Array, custom: Array, node_name: String, stats: Dictionary) -> MultiMeshInstance3D:
	var keep_idx := _keepout_keep_idx(mesh, xforms)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = mesh
	mm.instance_count = keep_idx.size()
	for i in keep_idx.size():
		var src: int = keep_idx[i]
		mm.set_instance_transform(i, xforms[src])
		mm.set_instance_color(i, colors[src])
		mm.set_instance_custom_data(i, custom[src])
	var mmi := MultiMeshInstance3D.new()
	mmi.name = node_name
	mmi.multimesh = mm
	mmi.material_override = material
	container.add_child(mmi)
	stats["meshes"] = int(stats["meshes"]) + 1
	stats["instances"] = int(stats["instances"]) + keep_idx.size()
	return mmi


static func _mat(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.9
	return mat


static func _mat_vertex_color() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.92
	return mat


static func _color(hex: String, fallback: Color) -> Color:
	if hex.is_empty():
		return fallback
	return Color.from_string(hex, fallback)


static func is_night_theme(theme: Dictionary) -> bool:
	return _is_night(theme)


static func _is_night(theme: Dictionary) -> bool:
	if float(theme.get("stars", 0.0)) >= 0.4:
		return true
	var sky := _color(String(theme.get("skyTop", "#1c62b4")), Color(0.1, 0.35, 0.7))
	return sky.get_luminance() < 0.14


static func _window_texture(theme: Dictionary) -> ImageTexture:
	var size := 64
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var night := _is_night(theme)
	var accent := _color(String(theme.get("accent", "#4fe9ff")), Color(0.3, 0.85, 0.95))
	var wall := Color(0.045, 0.05, 0.06) if night else Color(0.14, 0.15, 0.17)
	var lit := accent.darkened(0.25) if night else Color(0.3, 0.32, 0.36)
	for y in size:
		for x in size:
			var cell_x := x / 10
			var cell_y := y / 10
			var hash_v := (cell_x * 7 + cell_y * 13 + (x / 10) * 3) % 13
			var is_window := (x % 10) >= 3 and (x % 10) <= 6 and (y % 10) >= 3 and (y % 10) <= 6
			if is_window and hash_v > 6:
				var flicker := 0.45 + float(hash_v % 4) * 0.08
				img.set_pixel(x, y, lit * flicker)
			else:
				img.set_pixel(x, y, wall)
	return ImageTexture.create_from_image(img)


static func _checker_texture() -> ImageTexture:
	var img := Image.create(128, 16, false, Image.FORMAT_RGB8)
	for y in 16:
		for x in 128:
			var on := (int(x / 16.0) + int(y / 8.0)) % 2 == 0
			img.set_pixel(x, y, Color(0.92, 0.92, 0.9) if on else Color(0.06, 0.06, 0.07))
	return ImageTexture.create_from_image(img)
