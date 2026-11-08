class_name GrassScatter
extends RefCounted
## Dense, cheap grass coverage for the lawn: alpha-cut cross cards scattered over
## the whole grass area (nearer = taller, farther = shorter), plus terrain height
## and track clearance. A few thousand real 3D clumps are kept for close-up parallax.

static var _mesh: ArrayMesh
static var _tex: Texture2D


static func _blade_texture() -> Texture2D:
	if _tex != null:
		return _tex
	var size := 128
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.0, 0.0, 0.0, 0.0))
	var rng := RandomNumberGenerator.new()
	rng.seed = 1337
	for i in 90:
		var x0 := rng.randi_range(8, size - 8)
		var blades := rng.randi_range(40, 112)
		var width := rng.randi_range(2, 5)
		var lean := rng.randf_range(-16.0, 16.0)
		for y in blades:
			var t := float(y) / float(blades)
			var x := x0 + int(lean * t * t)
			var ww := maxi(1, int(round(float(width) * (1.0 - t * 0.8))))
			var color := Color(0.16 + 0.10 * t, 0.38 + 0.16 * t, 0.10 + 0.05 * t, 1.0)
			for dx in range(-ww, ww + 1):
				var px := x + dx
				var py := size - 1 - y
				if px >= 0 and px < size and py >= 0 and py < size:
					img.set_pixel(px, py, color)
	img.generate_mipmaps()
	_tex = ImageTexture.create_from_image(img)
	return _tex


static func _cross_mesh() -> ArrayMesh:
	if _mesh != null:
		return _mesh
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var quads := [0.0, PI * 0.5]
	for angle in quads:
		var rx := Vector3(cos(angle), 0.0, sin(angle))
		var p0 := -rx * 0.5
		var p1 := rx * 0.5
		var up := Vector3(0.0, 1.0, 0.0)
		# triangle 1
		st.set_normal(up)
		st.set_uv(Vector2(0.0, 1.0))
		st.add_vertex(p0)
		st.set_uv(Vector2(1.0, 1.0))
		st.add_vertex(p1)
		st.set_uv(Vector2(0.0, 0.0))
		st.add_vertex(p0 + up)
		# triangle 2
		st.set_uv(Vector2(1.0, 1.0))
		st.add_vertex(p1)
		st.set_uv(Vector2(1.0, 0.0))
		st.add_vertex(p1 + up)
		st.set_uv(Vector2(0.0, 0.0))
		st.add_vertex(p0 + up)
	_tex = _blade_texture()
	st.set_material(_card_material())
	_mesh = st.commit()
	return _mesh


static func _card_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = _blade_texture()
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	mat.alpha_scissor_threshold = 0.45
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	mat.roughness = 0.95
	mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	mat.disable_receive_shadows = true
	return mat


static func scatter(container: Node3D, path: TrackPath, rng: RandomNumberGenerator,
		stats: Dictionary) -> void:
	var mesh := _cross_mesh()
	var bands := [
		# from, to, count, height_min, height_max, width_scale, vis, color base
		[1.8, 10.0, 6000, 0.75, 1.15, 0.95, 140.0],
		[10.0, 42.0, 11000, 0.60, 1.05, 1.15, 330.0],
		[42.0, 100.0, 9000, 0.45, 0.80, 1.5, 480.0],
		[100.0, 240.0, 7000, 0.30, 0.55, 2.2, 680.0],
	]
	var content := clampf(Settings.content_scale(), 0.3, 1.5)
	for band in bands:
		var from_lat: float = float(band[0])
		var to_lat: float = float(band[1])
		var count := int(float(band[2]) * content)
		var hmin: float = float(band[3])
		var hmax: float = float(band[4])
		var width_mul: float = float(band[5])
		var vis: float = float(band[6])
		var xforms: Array[Transform3D] = []
		var colors: Array[Color] = []
		var attempts := count * 4
		var half := path.half_width
		while xforms.size() < count and attempts > 0:
			attempts -= 1
			var frame := path.frame_at(rng.randf() * path.total_length)
			if frame.is_empty():
				continue
			var side_sign := 1.0 if rng.randf() < 0.5 else -1.0
			var lateral := half + rng.randf_range(from_lat, to_lat)
			var pos: Vector3 = (frame["pos"] as Vector3) + (frame["side"] as Vector3) * lateral * side_sign
			pos += (frame["tangent"] as Vector3) * rng.randf_range(-16.0, 16.0)
			pos.y = Terrain.height_at(pos) - 0.02
			if not VenueKit.clear_of_track(path, pos, 2.6):
				continue
			if path.id == "coast" and Vector2(pos.x, pos.z).length() > 520.0:
				continue
			var fade := clampf((lateral - half - from_lat) / maxf(to_lat - from_lat, 0.001), 0.0, 1.0)
			var h := rng.randf_range(hmin, hmax) * (1.0 - fade * 0.25)
			var w := h * width_mul * rng.randf_range(0.85, 1.15)
			var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(w, h, w))
			xforms.append(Transform3D(basis, pos))
			var tint := rng.randf_range(0.72, 1.05)
			colors.append(Color(tint * 0.34, tint * 0.52, tint * 0.24))
		if xforms.is_empty():
			continue
		# split into chunks so the frustum / streamer can cull them
		for c in 12:
			var lo := xforms.size() * c / 12
			var hi := xforms.size() * (c + 1) / 12
			if hi <= lo:
				continue
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.use_colors = true
			mm.mesh = mesh
			mm.instance_count = hi - lo
			for i in hi - lo:
				mm.set_instance_transform(i, xforms[lo + i])
				mm.set_instance_color(i, colors[lo + i])
			var mi := MultiMeshInstance3D.new()
			mi.multimesh = mm
			mi.name = "GrassCards_%d_%d" % [int(from_lat), c]
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mi.visibility_range_end = vis
			mi.visibility_range_end_margin = vis * 0.15
			container.add_child(mi)
			stats["nodes"] = int(stats.get("nodes", 0)) + 1
			stats["instances"] = int(stats.get("instances", 0)) + (hi - lo)
