class_name TrackBuilder
extends Node3D
## Builds the visible circuit around a TrackPath: ground, asphalt ribbon, lane
## markings, kerbs, guardrail and the start/finish checker band.
##
## Everything is generated procedurally from the legacy track JSON, exactly like
## the three.js original did. Art quality is intentionally "semi-realistic
## placeholder" for M0 — the environment art pass comes later.

const SEA_LEVEL := -1.6
const SEA_FLOOR := -4.4

var path: TrackPath
var theme: Dictionary = {}
var real_city := false


func build(def: Dictionary) -> TrackPath:
	theme = def.get("theme", {})
	real_city = bool(def.get("realCity", false))
	path = TrackPath.new()
	path.build_from_def(def, 2.0)
	if path.samples.size() < 8:
		push_error("TrackBuilder: track '%s' produced too few samples" % path.id)
		return path
	# 实景城市：路面/楼群全部来自城市模型，这里只补起跑线与发车格。
	if real_city:
		_build_start_line()
		_build_start_grid()
		return path
	# 开放漂移场地：一整块方形柏油 + 草地外延，不生成任何赛道部件。
	if path.open_field:
		_build_open_field()
		return path
	_build_ground()
	_build_road()
	_build_lane_markings()
	_build_kerbs()
	_build_guardrail()
	_build_start_line()
	_build_start_grid()
	# 这里曾经有一层「预铺胎胶」：沿弯道中线 ±1.6m 铺无贴图的黑 quad，
	# 玩家读成路面上凭空多出的黑方块/黑条带（阴影都比它自然），已整层删除。
	_build_puddles()
	_build_runoff()
	_build_real_barriers()
	return path


# ---------------------------------------------------------------------------
# pieces
# ---------------------------------------------------------------------------

static func configure_terrain(p: TrackPath) -> void:
	if p == null:
		return
	Terrain.reset()
	if p.open_field:
		return
	if String(p.id) == "coast":
		var venue := p.venue_span()
		Terrain.setup_coast(p, 20.0, 8.0, 44.0, SEA_FLOOR,
			float(venue["center_dist"]), float(venue["half_len"]))
		return
	if String(p.id) == "harbor":
		var venue := p.venue_span()
		Terrain.setup_coast(p, 12.0, 7.0, 36.0, SEA_FLOOR,
			float(venue["center_dist"]), float(venue["half_len"]))
		return
	var amp := 0.0
	match String(p.id):
		"alpine":
			amp = 44.0
		"glacier":
			amp = 30.0
		"canyon":
			amp = 34.0
		"magma":
			amp = 48.0
		"pass":
			amp = 26.0
		_:
			amp = 0.0
	if amp > 0.0:
		Terrain.setup(p, amp, 1000000.0)


## 漂移练习：field_half 见方的整块柏油。没有标线/路肩/护栏/起跑格，
## 只有 8m 物理平铺沥青 + 46m 大尺度细节层；
## 场地外一圈草地延伸到雾里，作为自然边界（越界按草地阻力处理）。
func _build_open_field() -> void:
	Terrain.reset()
	var half := path.field_half
	var size := half * 2.0
	var mat := PbrAssets.road()
	var tiles := size / PbrAssets.ROAD_TILE_METERS
	mat.uv1_scale = Vector3(tiles, tiles, 1.0)
	mat.albedo_color = _color(String(theme.get("roadTint", "#e8e6e0")), Color(0.91, 0.90, 0.88))
	mat.roughness = clampf(float(theme.get("roadRoughness", 0.9)), 0.5, 1.0)
	_apply_road_detail(mat)
	var field_mesh := PlaneMesh.new()
	field_mesh.size = Vector2(size, size)
	var field := _new_mesh_instance(field_mesh, mat, "Road")
	field.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	var apron_size := 8000.0
	var apron := PlaneMesh.new()
	apron.size = Vector2(apron_size, apron_size)
	var grass_mat := PbrAssets.grass_plane()
	var grass_tiles := apron_size / PbrAssets.WORLD_TILE_METERS
	grass_mat.uv1_scale = Vector3(grass_tiles, grass_tiles, 1.0)
	var ground: Dictionary = theme.get("ground", {})
	grass_mat.albedo_color = _color(String(ground.get("base", "#5d7c42")), Color(0.36, 0.49, 0.26))
	var apron_mi := _new_mesh_instance(apron, grass_mat, "Ground")
	apron_mi.position = Vector3(0.0, -0.06, 0.0)
	apron_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _build_ground() -> void:
	Terrain.reset()
	var ground: Dictionary = theme.get("ground", {})
	var grass_color := _color(String(ground.get("base", "#517d3e")), Color(0.32, 0.42, 0.22))
	var track_id := String(path.id)
	if track_id == "coast" or track_id == "harbor":
		_build_ocean_ground(grass_color, track_id == "harbor")
		return
	if track_id == "city" or track_id == "skyline" or track_id == "metro":
		_build_city_ground(track_id == "city")
		return
	if track_id == "canyon" or track_id == "magma":
		_build_desert_ground(grass_color, track_id == "magma")
		return
	if track_id == "pass":
		_build_pass_ground(grass_color)
		return
	_build_valley_ground(grass_color)


## 海岸 / 港湾：海面贴在赛道 +side 一侧，岸线平行于路。
## 地面本身是一张由 Terrain 高度场生成的网格：陆侧继续起伏成丘陵，
## 海侧在离路肩 10~48m 内沉到海床，于是海平面直接切到路边。
func _build_ocean_ground(grass_color: Color, harbor: bool) -> void:
	var venue := path.venue_span()
	var sea_start := 7.0 if harbor else 8.0
	var sea_end := 36.0 if harbor else 44.0
	var amp := 12.0 if harbor else 20.0
	Terrain.setup_coast(path, amp, sea_start, sea_end, SEA_FLOOR,
		float(venue["center_dist"]), float(venue["half_len"]))

	# --- 海面：一张巨大的水面，水平线与天空/雾融合 ---
	var sea := MeshInstance3D.new()
	var sea_mesh := PlaneMesh.new()
	sea_mesh.size = Vector2(26000.0, 26000.0)
	sea.mesh = sea_mesh
	sea.name = "Sea"
	sea.position = Vector3(0.0, SEA_LEVEL, 0.0)
	var water := ShaderMaterial.new()
	water.shader = load("res://shaders/water.gdshader")
	var fog_col := _color(String(theme.get("fogColor", "#c8e4ea")), Color(0.8, 0.86, 0.9))
	if harbor:
		# 落日港湾：暖调深水 + 金橙反光
		water.set_shader_parameter("deep_color", Color(0.035, 0.075, 0.12))
		water.set_shader_parameter("shallow_color", Color(0.16, 0.20, 0.24))
		water.set_shader_parameter("crest_color", Color(0.85, 0.62, 0.38))
		water.set_shader_parameter("wave_scale", 0.075)
		water.set_shader_parameter("wave_speed", 0.75)
		water.set_shader_parameter("wave_height", 0.28)
		water.set_shader_parameter("sky_reflect",
			Color(0.36, 0.25, 0.19).lerp(fog_col, 0.45))
	else:
		# 翡翠海岸：深海蓝绿，压低荧光感、加强浪高
		water.set_shader_parameter("deep_color", Color(0.010, 0.075, 0.135))
		water.set_shader_parameter("shallow_color", Color(0.05, 0.27, 0.34))
		water.set_shader_parameter("crest_color", Color(0.36, 0.52, 0.54))
		water.set_shader_parameter("wave_scale", 0.13)
		water.set_shader_parameter("wave_speed", 1.10)
		water.set_shader_parameter("wave_height", 0.34)
		water.set_shader_parameter("sky_reflect",
			Color(0.09, 0.26, 0.32).lerp(fog_col, 0.45))
	# 海天衔接：雾色与 main.gd 的 HDRI 环境雾保持同一个地平线色，
	# 远处水面直接融进天空，不再留下一条偏绿的平直色带。
	var haze_col := fog_col.darkened(0.34)
	if not harbor:
		haze_col = haze_col.lerp(Color(0.46, 0.53, 0.65), 0.62)
	if harbor:
		haze_col = fog_col.lightened(0.10)
	water.set_shader_parameter("haze_color", haze_col)
	if not harbor:
		water.set_shader_parameter("sky_reflect", haze_col.lightened(0.10))
	var sun_arr: Array = theme.get("sunDir", [0.42, 0.52, 0.2])
	water.set_shader_parameter("sun_dir",
		Vector3(float(sun_arr[0]), float(sun_arr[1]), float(sun_arr[2])).normalized())
	water.set_shader_parameter("sun_color",
		_color(String(theme.get("sunColor", "#fff2da")), Color(1.0, 0.95, 0.86)).lerp(
			Color(1.0, 0.82, 0.58), 0.35))
	water.set_shader_parameter("sun_energy",
		clampf(float(theme.get("sunIntensity", 1.0)) * 0.32, 0.25, 1.2))
	# 落日港湾的金色反光更强，白天海岸以泡沫和浪为主
	water.set_shader_parameter("glitter_amount", 1.35 if harbor else 0.85)
	water.set_shader_parameter("foam_amount", 0.85 if harbor else 1.0)
	sea.material_override = water
	sea.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(sea)

	# --- 陆地/海床网格：统一取 Terrain 高度，海侧自动没入水下 ---
	var ground_mat := PbrAssets.grass_world()
	ground_mat.albedo_color = Color(1.0, 1.0, 0.80) if not harbor else Color(0.92, 0.94, 0.74)
	ground_mat.roughness = 0.92
	ground_mat.vertex_color_use_as_albedo = true
	ground_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var terrain := _build_hill_mesh(1900.0, 140)
	terrain.material_override = ground_mat
	terrain.name = "Ground"
	terrain.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(terrain)

	# --- 沙滩 / 码头岸线：沿赛道紧跟海岸线的细条带（沙地 or 混凝土） ---
	_build_shore_band(sea_start - 12.0, sea_end + 8.0, harbor, venue)


## 沿赛道 +side 一侧铺一条贴地的岸线带（沙地/混凝土），压住地面网格的
## 低分辨率锯齿，让海岸线看起来是连续的沙滩而不是网格台阶。
func _build_shore_band(from_extra: float, to_extra: float, harbor: bool,
		venue: Dictionary = {}) -> void:
	var mat: StandardMaterial3D
	if harbor:
		mat = PbrAssets.concrete(Vector2.ONE)
		mat.uv1_scale = Vector3(0.22, 0.22, 1.0)
		mat.albedo_color = Color(0.62, 0.60, 0.56)
		mat.roughness = 0.9
	else:
		mat = PbrAssets.sand_world()
		mat.albedo_color = Color(1.05, 0.98, 0.80)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var lateral_steps := 7
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var m := path.samples.size()
	var prev: Array[Vector3] = []
	var inv_tile := 1.0 / 3.6
	for i in m + 1:
		var idx := i % m
		# 场馆区（起跑主直道）保持草地，沙滩/码头从场馆外才开始
		if not venue.is_empty():
			var center_d := float(venue.get("center_dist", 0.0))
			var half_len := float(venue.get("half_len", 0.0)) + 10.0
			var delta := wrapf(path.accumulated[idx] - center_d,
				-path.total_length * 0.5, path.total_length * 0.5)
			if absf(delta) <= half_len:
				prev = []
				continue
		var center := path.samples[idx]
		var side := path.sides[idx]
		var row: Array[Vector3] = []
		for j in lateral_steps + 1:
			var extra := lerpf(from_extra, to_extra, float(j) / float(lateral_steps))
			var p: Vector3 = center + side * (path.half_width + extra)
			p.y = Terrain.height_at(p) + 0.03
			row.append(p)
		if not prev.is_empty():
			for j in lateral_steps:
				var a: Vector3 = prev[j]
				var b: Vector3 = prev[j + 1]
				var c: Vector3 = row[j]
				var d: Vector3 = row[j + 1]
				st.set_normal(Vector3.UP)
				st.set_uv(Vector2(a.x, a.z) * inv_tile)
				st.add_vertex(a)
				st.set_normal(Vector3.UP)
				st.set_uv(Vector2(c.x, c.z) * inv_tile)
				st.add_vertex(c)
				st.set_normal(Vector3.UP)
				st.set_uv(Vector2(b.x, b.z) * inv_tile)
				st.add_vertex(b)
				st.set_normal(Vector3.UP)
				st.set_uv(Vector2(b.x, b.z) * inv_tile)
				st.add_vertex(b)
				st.set_normal(Vector3.UP)
				st.set_uv(Vector2(c.x, c.z) * inv_tile)
				st.add_vertex(c)
				st.set_normal(Vector3.UP)
				st.set_uv(Vector2(d.x, d.z) * inv_tile)
				st.add_vertex(d)
		prev = row
	var mi := _new_mesh_instance(st.commit(), mat, "ShoreBand" if not harbor else "QuayBand")
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


## 城市 / 天际线：夜间湿沥青广场 + 白天水泥地。
func _build_city_ground(night: bool) -> void:
	var plane := PlaneMesh.new()
	plane.size = Vector2(9000.0, 9000.0)
	var mat := PbrAssets.city_ground_plane(9000.0, night)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var mi := _new_mesh_instance(plane, mat, "Ground")
	mi.position = Vector3(0.0, -0.03, 0.0)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


## 戈壁 / 熔岩：沙砾地面 + 远处风蚀丘（颜色跟主题地面色）。
func _build_desert_ground(grass_color: Color, volcanic: bool) -> void:
	var amp := 48.0 if volcanic else 34.0
	Terrain.setup(path, amp, 1000000.0)
	var far_plane := PlaneMesh.new()
	far_plane.size = Vector2(9000.0, 9000.0)
	var far_mat := PbrAssets.sand_plane(9000.0, grass_color.darkened(0.22))
	var far_mi := _new_mesh_instance(far_plane, far_mat, "FarGround")
	far_mi.position = Vector3(0.0, -2.2, 0.0)
	far_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var hill_mat := PbrAssets.sand_world()
	hill_mat.albedo_color = grass_color.lightened(0.28) if not volcanic else grass_color.lightened(0.10)
	hill_mat.vertex_color_use_as_albedo = true
	hill_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var hills := _build_hill_mesh(2800.0, 130)
	hills.material_override = hill_mat
	hills.name = "Ground"
	hills.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(hills)


## 雪山 / 冰川山谷：雪面丘陵 + 远处雪原。
func _build_valley_ground(grass_color: Color) -> void:
	var amp := 44.0
	if String(path.id) == "glacier":
		amp = 30.0
	Terrain.setup(path, amp, 1000000.0)
	var far_plane := PlaneMesh.new()
	far_plane.size = Vector2(9000.0, 9000.0)
	var far_mat := PbrAssets.snow_plane(9000.0)
	var far_mi := _new_mesh_instance(far_plane, far_mat, "FarGround")
	far_mi.position = Vector3(0.0, -2.5, 0.0)
	far_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var hill_mat := PbrAssets.snow_world()
	hill_mat.albedo_color = Color(0.96, 0.98, 1.0) if String(path.id) == "glacier" else Color(1.0, 1.0, 1.0)
	hill_mat.vertex_color_use_as_albedo = true
	hill_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var hills := _build_hill_mesh(2800.0, 130)
	hills.material_override = hill_mat
	hills.name = "Ground"
	hills.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(hills)


## 雾岭山道：绿色山谷地面（非雪地）+ 山谷高度场，远景交给场景导入的山体。
func _build_pass_ground(grass_color: Color) -> void:
	Terrain.setup(path, 26.0, 1000000.0)
	var far_plane := PlaneMesh.new()
	far_plane.size = Vector2(9000.0, 9000.0)
	var far_mat := PbrAssets.grass_plane()
	far_mat.albedo_color = grass_color.darkened(0.12)
	var far_mi := _new_mesh_instance(far_plane, far_mat, "FarGround")
	far_mi.position = Vector3(0.0, -2.5, 0.0)
	far_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var hill_mat := PbrAssets.grass_world()
	hill_mat.albedo_color = Color(1.02, 1.04, 0.94)
	hill_mat.vertex_color_use_as_albedo = true
	hill_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var hills := _build_hill_mesh(4600.0, 160)
	hills.material_override = hill_mat
	hills.name = "Ground"
	hills.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(hills)


func _pass_road_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	# 原场景贴图整幅里烘了黄边线+白中线，铺到 17m 宽路面会变成横向条纹；
	# 这里只取两条标线之间的纯净沥青带，标线交给 _build_lane_markings。
	var diff := "res://maps/assets/venues/pass_road/pass_road_diff_clean.jpg"
	var nor := "res://maps/assets/venues/pass_road/pass_road_normal_clean.png"
	var rough := "res://maps/assets/venues/pass_road/pass_road_rough_clean.jpg"
	if ResourceLoader.exists(diff):
		mat.albedo_texture = load(diff)
	if ResourceLoader.exists(nor):
		mat.normal_enabled = true
		mat.normal_texture = load(nor)
		mat.normal_scale = 0.65
	if ResourceLoader.exists(rough):
		mat.roughness_texture = load(rough)
		mat.roughness = 1.0
	mat.albedo_color = _color(String(theme.get("roadTint", "#e6e6dd")), Color(0.9, 0.9, 0.87))
	mat.uv1_scale = Vector3(1.0, 2.58, 1.0)
	mat.metallic = float(theme.get("roadMetalness", 0.03))
	_apply_road_detail(mat)
	return mat


func _build_road() -> void:
	# 路面只用 PbrAssets 的固定模板：8m 物理平铺 + mipmap/各向异性过滤。
	# 不再程序生成随机噪点贴图，UV 密度也不随赛道或画质档变化。
	var mat := PbrAssets.road()
	if String(path.id) == "pass":
		mat = _pass_road_material()
	_apply_road_detail(mat)
	# 横向顶点色：中缝油渍、双轮磨痕、路缘积灰。让一条 17m 宽的路不再是一块
	# 均匀贴图，尤其高速镜头里近景路面有可读的「被用过」的层次。
	mat.vertex_color_use_as_albedo = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var road_rough := float(theme.get("roadRoughness", 0.85))
	var road_metal := float(theme.get("roadMetalness", 0.03))
	if road_rough < 0.5:
		mat.roughness = clampf(road_rough, 0.42, 0.5)
		mat.metallic = clampf(road_metal, 0.0, 0.08)
	else:
		# 干沥青必须压到接近真实 F0。BaseMaterial3D 默认 specular=0.5 让整片平坦路面去镜射
		# 天空与太阳：中远景掠射角被抬亮、正下方近景抬不动，实测近 81 / 远 146，形成一条
		# 永远跟着车走的横带。分界来自视角相关的高光——关掉阴影只把 64 阶降到 54 阶，
		# 压 specular 到 0.10 才降到 7 阶；雾色 #c8e4ea 偏蓝而亮带偏暖，方向也对不上。
		# 高光原本占路面近四成亮度，所以同步把漫反射补回来，否则整条路塌成暗灰。
		mat.metallic_specular = 0.10
		mat.albedo_color = mat.albedo_color * 1.85

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var m := path.samples.size()
	var uv_meters := PbrAssets.ROAD_V_METERS
	# 横向分 8 段：顶点色需要足够的横向分辨率才能画出轮迹渐变。
	var lanes := 8
	var macro_meters := 46.0
	for i in m:
		var j := (i + 1) % m
		var pi := path.samples[i]
		var pj := path.samples[j]
		var si := path.sides[i]
		var sj := path.sides[j]
		var half := path.half_width
		var va := path.accumulated[i] / uv_meters
		var vb := va + pi.distance_to(pj) / uv_meters
		for k in lanes:
			var t0 := -1.0 + 2.0 * float(k) / float(lanes)
			var t1 := -1.0 + 2.0 * float(k + 1) / float(lanes)
			var a := pi + si * (half * t0) + Vector3(0.0, 0.02, 0.0)
			var b := pi + si * (half * t1) + Vector3(0.0, 0.02, 0.0)
			var c := pj + sj * (half * t0) + Vector3(0.0, 0.02, 0.0)
			var d := pj + sj * (half * t1) + Vector3(0.0, 0.02, 0.0)
			var u0 := (t0 + 1.0) * 0.5
			var u1 := (t1 + 1.0) * 0.5
			_add_road_quad(st, a, b, c, d,
				Vector2(u0, va), Vector2(u1, va), Vector2(u0, vb), Vector2(u1, vb),
				macro_meters, t0, t1)
	# 法线贴图需要切线，否则路面高光会出现随机噪点
	st.generate_tangents()
	var road_mi := _new_mesh_instance(st.commit(), mat, "Road")
	# 路面是零厚度贴皮，既往往阴影贴图里写深度、自己又受光：低太阳角下近处整片被判成
	# 被自己遮住，实测比关掉投影时暗 12 个灰阶。它投给别的地面的影子只有
	# 0.02m/tan(太阳高度) ≈ 2~3cm 看不见，所以跟漂移场大地面（:103）一样不做投影体。
	road_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


## 路面横向磨损：中缝油渍 + 两条轮迹 + 路缘积灰。输入 -1..1 的横向坐标。
static func _road_wear(t: float) -> Color:
	var at := absf(t)
	var oil := exp(-pow(at / 0.20, 2.0)) * 0.13
	var tire := exp(-pow((at - 0.46) / 0.15, 2.0)) * 0.14
	tire += exp(-pow((at - 0.78) / 0.11, 2.0)) * 0.06
	var dust := smoothstep(0.82, 1.0, at) * 0.06
	var v := clampf(1.0 - oil - tire + dust, 0.70, 1.08)
	return Color(v, v, v, 1.0)


func _add_road_quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3,
		ua: Vector2, ub: Vector2, uc: Vector2, ud: Vector2,
		macro_meters: float, t0: float, t1: float) -> void:
	var ca := _road_wear(t0)
	var cb := _road_wear(t1)
	var ma := Vector2(a.x, a.z) / macro_meters
	var mb := Vector2(b.x, b.z) / macro_meters
	var mc := Vector2(c.x, c.z) / macro_meters
	var md := Vector2(d.x, d.z) / macro_meters
	var n := Vector3.UP
	st.set_normal(n)
	st.set_uv(ua)
	st.set_uv2(ma)
	st.set_color(ca)
	st.add_vertex(a)
	st.set_normal(n)
	st.set_uv(uc)
	st.set_uv2(mc)
	st.set_color(ca)
	st.add_vertex(c)
	st.set_normal(n)
	st.set_uv(ub)
	st.set_uv2(mb)
	st.set_color(cb)
	st.add_vertex(b)
	st.set_normal(n)
	st.set_uv(ub)
	st.set_uv2(mb)
	st.set_color(cb)
	st.add_vertex(b)
	st.set_normal(n)
	st.set_uv(uc)
	st.set_uv2(mc)
	st.set_color(ca)
	st.add_vertex(c)
	st.set_normal(n)
	st.set_uv(ud)
	st.set_uv2(md)
	st.set_color(cb)
	st.add_vertex(d)


## 大尺度细节层：UV2 世界坐标（46m 一张）叠一层低对比噪声，打散 8m 平铺的
## 重复感。噪声纹理只生成一次，走 mipmap + 三线性，不在运行时逐帧算。
static func _apply_road_detail(mat: StandardMaterial3D) -> void:
	var tex := _road_macro_texture()
	if tex == null:
		return
	mat.detail_enabled = true
	mat.detail_uv_layer = 1
	mat.detail_blend_mode = BaseMaterial3D.BLEND_MODE_MUL
	mat.detail_albedo = tex
	mat.uv2_scale = Vector3.ONE


static var _road_macro_tex: Texture2D = null


static func _road_macro_texture() -> Texture2D:
	if _road_macro_tex != null:
		return _road_macro_tex
	var noise := FastNoiseLite.new()
	noise.seed = 90210
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.018
	noise.fractal_octaves = 3
	noise.fractal_gain = 0.55
	var size := 256
	var img := Image.create(size, size, true, Image.FORMAT_RGB8)
	# 四向交叉淡化做无缝平铺，避免 46m 一格的接缝在高速镜头里成一条亮线。
	for y in size:
		for x in size:
			var u := float(x) / float(size)
			var v := float(y) / float(size)
			var n00 := noise.get_noise_2d(float(x), float(y))
			var n10 := noise.get_noise_2d(float(x - size), float(y))
			var n01 := noise.get_noise_2d(float(x), float(y - size))
			var n11 := noise.get_noise_2d(float(x - size), float(y - size))
			var nval := lerpf(lerpf(n00, n10, u), lerpf(n01, n11, u), v)
			var shade := lerpf(0.80, 1.0, smoothstep(0.22, 0.82, nval * 0.5 + 0.5))
			img.set_pixel(x, y, Color(shade, shade, shade))
	img.generate_mipmaps()
	_road_macro_tex = ImageTexture.create_from_image(img)
	return _road_macro_tex


func _build_lane_markings() -> void:
	var edge_color := _color(String(theme.get("lineColor", "#f2f0e4")), Color(0.95, 0.94, 0.88))
	var edge_inset := path.half_width - 0.55
	_build_flat_strip(-edge_inset, 0.14, edge_color, 0.0)
	_build_flat_strip(edge_inset, 0.14, edge_color, 0.0)
	_build_flat_strip(0.0, 0.15, edge_color, 11.0)
	# 夜间赛道：标线按主题色加一层加法混合光晕，雨夜城市的路面会反光
	var glow := _color(String(theme.get("lineEmissive", "#000000")), Color(0, 0, 0))
	if glow.r + glow.g + glow.b > 0.02:
		var energy := clampf(float(theme.get("lineEmissiveIntensity", 1.0)), 0.0, 3.0)
		var glow_col := Color(glow.r * energy, glow.g * energy, glow.b * energy, 0.55)
		_build_flat_strip(-edge_inset, 0.30, glow_col, 0.0, true)
		_build_flat_strip(edge_inset, 0.30, glow_col, 0.0, true)
		_build_flat_strip(0.0, 0.32, glow_col, 11.0, true)


func _build_kerbs() -> void:
	var curb: Array = theme.get("curb", ["#c03a33", "#e8e2d4"])
	var col_a := _color(String(curb[0]), Color(0.75, 0.23, 0.2))
	var col_b := _color(String(curb[1]), Color(0.91, 0.89, 0.83))
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 1.0
	var nor := PbrAssets.tex("textures/brushed_concrete/brushed_concrete_nor.jpg")
	if nor != null:
		mat.normal_enabled = true
		mat.normal_texture = nor
		mat.normal_scale = 0.45
	var rough := PbrAssets.tex("textures/brushed_concrete/brushed_concrete_rough.jpg")
	if rough != null:
		mat.roughness_texture = rough
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	var lateral := path.half_width + 0.30
	var strip_half := 0.30
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var m := path.samples.size()
	for sgn: float in [-1.0, 1.0]:
		for i in m:
			var j := (i + 1) % m
			var pi: Vector3 = path.samples[i]
			var pj: Vector3 = path.samples[j]
			var si := path.sides[i]
			var sj := path.sides[j]
			# 内侧（贴赛道）0.24m 加一条暗带模拟轮胎/刹车粉尘，外侧保留红白漆面。
			# 横向仍分两段，顶点色才有地方落；法线/粗糙度来自混凝土贴图。
			var off_in := sgn * (lateral - strip_half)
			var off_mid := sgn * (lateral - strip_half * 0.18)
			var off_out := sgn * (lateral + strip_half)
			var a: Vector3 = pi + si * off_in + Vector3(0.0, 0.06, 0.0)
			var b: Vector3 = pi + si * off_mid + Vector3(0.0, 0.06, 0.0)
			var c: Vector3 = pi + si * off_out + Vector3(0.0, 0.06, 0.0)
			var d: Vector3 = pj + sj * off_in + Vector3(0.0, 0.06, 0.0)
			var e: Vector3 = pj + sj * off_mid + Vector3(0.0, 0.06, 0.0)
			var f: Vector3 = pj + sj * off_out + Vector3(0.0, 0.06, 0.0)
			var bank := int(path.accumulated[i] / 4.0) % 2
			var col := col_a if bank == 0 else col_b
			var worn := col.darkened(0.28)
			var u := path.accumulated[i] / 2.4
			var v := path.accumulated[j] / 2.4
			_add_kerb_quad(st, a, b, d, e, Vector2(u, 0.0), Vector2(u, 0.5),
				Vector2(v, 0.0), Vector2(v, 0.5), worn, worn, Vector3.UP)
			_add_kerb_quad(st, b, c, e, f, Vector2(u, 0.5), Vector2(u, 1.0),
				Vector2(v, 0.5), Vector2(v, 1.0), col, col, Vector3.UP)
			# 侧立面：低角度看过去不再是零厚度薄片
			var drop := Vector3(0.0, -0.16, 0.0)
			var n_in: Vector3 = -si * sgn
			var n_out: Vector3 = si * sgn
			_add_kerb_quad(st, a, d, a + drop, d + drop,
				Vector2(u, 0.0), Vector2(v, 0.0), Vector2(u, 0.6), Vector2(v, 0.6),
				worn.darkened(0.12), worn.darkened(0.12), n_in)
			_add_kerb_quad(st, c, f, c + drop, f + drop,
				Vector2(u, 1.0), Vector2(v, 1.0), Vector2(u, 0.4), Vector2(v, 0.4),
				col.darkened(0.12), col.darkened(0.12), n_out)
	st.generate_tangents()
	_new_mesh_instance(st.commit(), mat, "Kerbs")


## 路肩四顶点工具：a/b 是当前采样点的内外两点，c/d 是下一采样点。
func _add_kerb_quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3,
		ua: Vector2, ub: Vector2, uc: Vector2, ud: Vector2,
		ca: Color, cb: Color, n: Vector3) -> void:
	st.set_normal(n)
	st.set_uv(ua)
	st.set_color(ca)
	st.add_vertex(a)
	st.set_normal(n)
	st.set_uv(uc)
	st.set_color(ca)
	st.add_vertex(c)
	st.set_normal(n)
	st.set_uv(ub)
	st.set_color(cb)
	st.add_vertex(b)
	st.set_normal(n)
	st.set_uv(ub)
	st.set_color(cb)
	st.add_vertex(b)
	st.set_normal(n)
	st.set_uv(uc)
	st.set_color(ca)
	st.add_vertex(c)
	st.set_normal(n)
	st.set_uv(ud)
	st.set_color(cb)
	st.add_vertex(d)


func _build_guardrail() -> void:
	var rail: Dictionary = theme.get("rail", {})
	# W 形波纹护栏：五段剖面比一张平板多出明暗变化，白天逆光和夜间车灯
	# 都能扫出高光。只取金属法线/粗糙度贴图，底色仍用主题护栏色，
	# 避免贴图本身的暗色把整条护栏压成黑褐色。
	var mat := StandardMaterial3D.new()
	mat.albedo_color = _color(String(rail.get("color", "#8e9aa2")), Color(0.56, 0.6, 0.64)).lightened(0.24)
	var rail_nor := PbrAssets.tex("textures/metal_plate/metal_plate_nor.jpg")
	if rail_nor != null:
		mat.normal_enabled = true
		mat.normal_texture = rail_nor
		mat.normal_scale = 0.80
	var rail_rough := PbrAssets.tex("textures/metal_plate/metal_plate_rough.jpg")
	if rail_rough != null:
		mat.roughness_texture = rail_rough
	# 护栏剖面几乎是竖直薄板（7cm 深 / 72cm 高），正面朝向 ±side。金属度高时
	# 漫反射项被压掉，朝向背光的那一面只剩镜面反射，实拍下整条护栏糊成一条
	# 跟着车走的深蓝灰带（近处实测 RGB 36/53/71，饱和度 12），玩家把它读成
	# 「车周围一圈阴影」。镀锌护栏本身是哑光亮面，靠漫反射就够，压低金属度、
	# 抬高粗糙度与底色，让任何朝向的面都保持浅灰。
	mat.metallic = 0.20
	mat.roughness = 0.66
	mat.metallic_specular = 0.28
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	var lateral := path.half_width + 1.55
	var profile := [
		Vector2(0.00, 0.22),
		Vector2(0.07, 0.36),
		Vector2(0.01, 0.56),
		Vector2(0.07, 0.78),
		Vector2(0.00, 0.94),
	]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var m := path.samples.size()
	for sgn: float in [-1.0, 1.0]:
		for i in m:
			var j := (i + 1) % m
			var pi: Vector3 = path.samples[i]
			var pj: Vector3 = path.samples[j]
			var si := path.sides[i]
			var sj := path.sides[j]
			var tan := (pj - pi).normalized()
			var u0 := path.accumulated[i] / 2.4
			var u1 := path.accumulated[j] / 2.4
			for k in profile.size() - 1:
				var p0: Vector2 = profile[k]
				var p1: Vector2 = profile[k + 1]
				var a: Vector3 = pi + si * (sgn * (lateral + p0.x)) + Vector3(0.0, p0.y, 0.0)
				var b: Vector3 = pi + si * (sgn * (lateral + p1.x)) + Vector3(0.0, p1.y, 0.0)
				var c: Vector3 = pj + sj * (sgn * (lateral + p0.x)) + Vector3(0.0, p0.y, 0.0)
				var d: Vector3 = pj + sj * (sgn * (lateral + p1.x)) + Vector3(0.0, p1.y, 0.0)
				var prof_dir := (si * (sgn * (p1.x - p0.x)) + Vector3(0.0, p1.y - p0.y, 0.0)).normalized()
				var n := (tan.cross(prof_dir) * sgn).normalized()
				var va := p0.y / 0.94
				var vb := p1.y / 0.94
				_add_rail_quad(st, a, b, c, d,
					Vector2(u0, va), Vector2(u0, vb), Vector2(u1, va), Vector2(u1, vb), n)
	st.generate_tangents()
	_new_mesh_instance(st.commit(), mat, "Guardrail")

	# Posts: one MultiMesh draw call for the whole circuit.
	var step := 9.0
	var per_side := int(path.total_length / step)
	if per_side < 1:
		return
	var box := BoxMesh.new()
	box.size = Vector3(0.14, 1.05, 0.14)
	var post_mat := StandardMaterial3D.new()
	post_mat.albedo_color = Color(0.22, 0.24, 0.26)
	var post_nor := PbrAssets.tex("textures/metal_plate/metal_plate_nor.jpg")
	if post_nor != null:
		post_mat.normal_enabled = true
		post_mat.normal_texture = post_nor
		post_mat.normal_scale = 0.6
	post_mat.metallic = 0.65
	post_mat.roughness = 0.55
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = box
	mm.instance_count = per_side * 2
	var k := 0
	for sgn: float in [-1.0, 1.0]:
		for n in per_side:
			var f := path.frame_at(float(n) * step)
			if f.is_empty():
				continue
			var p: Vector3 = f["pos"] + (f["side"] as Vector3) * (sgn * lateral)
			mm.set_instance_transform(k, Transform3D(Basis(), p + Vector3(0.0, 0.52, 0.0)))
			k += 1
	mm.instance_count = k
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "GuardrailPosts"
	mmi.multimesh = mm
	mmi.material_override = post_mat
	add_child(mmi)

	# 护栏反光片：每 14m 一颗，面向赛道。夜里沿弯道能看到一条连续的反光点，
	# 只增加 1 个 MultiMesh draw call。
	var reflector_col := _color(String(rail.get("reflector", "#ff8a2a")), Color(1.0, 0.55, 0.12))
	if reflector_col.r + reflector_col.g + reflector_col.b < 0.08:
		reflector_col = Color(1.0, 0.55, 0.12)
	var ref_mesh := BoxMesh.new()
	ref_mesh.size = Vector3(0.15, 0.10, 0.045)
	var ref_mat := StandardMaterial3D.new()
	ref_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ref_mat.albedo_color = Color(
		reflector_col.r * 2.2, reflector_col.g * 2.2, reflector_col.b * 2.2, 1.0)
	ref_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var ref_step := 14.0
	var ref_per_side := int(path.total_length / ref_step)
	if ref_per_side > 0:
		var ref_mm := MultiMesh.new()
		ref_mm.transform_format = MultiMesh.TRANSFORM_3D
		ref_mm.mesh = ref_mesh
		ref_mm.instance_count = ref_per_side * 2
		var rk := 0
		for sgn: float in [-1.0, 1.0]:
			for n in ref_per_side:
				var f := path.frame_at(float(n) * ref_step + 7.0)
				if f.is_empty():
					continue
				var side: Vector3 = f["side"]
				var p: Vector3 = (f["pos"] as Vector3) + side * (sgn * lateral) \
					- side * (sgn * 0.035) + Vector3(0.0, 0.78, 0.0)
				var basis := Basis.looking_at(-side * sgn, Vector3.UP)
				ref_mm.set_instance_transform(rk, Transform3D(basis, p))
				rk += 1
		ref_mm.instance_count = rk
		var rmmi := MultiMeshInstance3D.new()
		rmmi.name = "GuardrailReflectors"
		rmmi.multimesh = ref_mm
		rmmi.material_override = ref_mat
		add_child(rmmi)


func _add_rail_quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3,
		ua: Vector2, ub: Vector2, uc: Vector2, ud: Vector2, n: Vector3) -> void:
	st.set_normal(n)
	st.set_uv(ua)
	st.add_vertex(a)
	st.set_normal(n)
	st.set_uv(uc)
	st.add_vertex(c)
	st.set_normal(n)
	st.set_uv(ub)
	st.add_vertex(b)
	st.set_normal(n)
	st.set_uv(ub)
	st.add_vertex(b)
	st.set_normal(n)
	st.set_uv(uc)
	st.add_vertex(c)
	st.set_normal(n)
	st.set_uv(ud)
	st.add_vertex(d)


## 急弯外侧用 Poly Haven CC0 真实混凝土护栏替换纯色平板护栏的观感：
## 只在高曲率路段摆几段，避免全赛道数千实例把 GPU 打满；连续金属护栏
## 本身仍是程序化带状网格（这是赛车游戏的标准做法，不是低模占位）。
func _build_real_barriers() -> void:
	var asset := "barrier_real"
	if not RealAssetKit.has(asset):
		return
	var dims := RealAssetKit.size(asset)
	var seg_len := maxf(dims.x, 0.01)
	var step := seg_len * 0.94
	var xforms: Array[Transform3D] = []
	var dist := 0.0
	while dist < path.total_length:
		var f := path.frame_at(dist)
		if not f.is_empty():
			var curv := float(f.get("curvature", 0.0))
			if absf(curv) > 0.006:
				var side := 1.0 if curv > 0.0 else -1.0
				for k in 5:
					var ff := path.frame_at(dist + float(k) * step)
					if ff.is_empty():
						continue
					var side_vec: Vector3 = ff["side"]
					var pos: Vector3 = (ff["pos"] as Vector3) + side_vec * (side * (path.half_width + 1.6))
					if Terrain.active:
						pos.y = Terrain.height_at(pos) + 0.02
					else:
						pos.y += 0.02
					# barrier 长轴沿本地 X；让 -Z 朝向赛道横向即可得到切线对齐
					var basis := Basis.looking_at(side_vec * side, Vector3.UP)
					xforms.append(Transform3D(basis, pos))
		dist += 34.0
	RealAssetKit.place_chunked(self, asset, xforms, "RealBarrier", 420.0, true, {})


func _build_start_line() -> void:
	var f0 := path.frame_at(0.0)
	var f1 := path.frame_at(2.4)
	if f0.is_empty() or f1.is_empty():
		return
	var inset := path.half_width_at_dist(0.0) - 0.25
	var p0: Vector3 = f0["pos"]
	var p1: Vector3 = f1["pos"]
	var s0: Vector3 = f0["side"]
	var s1: Vector3 = f1["side"]
	var y := Vector3(0.0, 0.045, 0.0)
	var a := p0 - s0 * inset + y
	var b := p0 + s0 * inset + y
	var c := p1 - s1 * inset + y
	var d := p1 + s1 * inset + y
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_add_quad(st, a, b, c, d, Vector2(0, 0), Vector2(1, 0), Vector2(0, 1), Vector2(1, 1))
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = _checker_texture()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_new_mesh_instance(st.commit(), mat, "StartLine")


static var _terrain_tint_noise_cache: FastNoiseLite = null


static func _terrain_tint_noise() -> FastNoiseLite:
	if _terrain_tint_noise_cache == null:
		_terrain_tint_noise_cache = FastNoiseLite.new()
		_terrain_tint_noise_cache.seed = 7331
		_terrain_tint_noise_cache.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		_terrain_tint_noise_cache.frequency = 0.0055
		_terrain_tint_noise_cache.fractal_octaves = 3
		_terrain_tint_noise_cache.fractal_gain = 0.55
	return _terrain_tint_noise_cache


func _build_hill_mesh(size: float, subdivisions: int) -> MeshInstance3D:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_uv(Vector2(0.0, 0.0))
	var step := size / float(subdivisions)
	var half := size * 0.5
	var verts: Array[Vector3] = []
	for iz in subdivisions + 1:
		for ix in subdivisions + 1:
			var x := -half + float(ix) * step
			var z := -half + float(iz) * step
			var y := Terrain.height_at(Vector3(x, 0.0, z))
			verts.append(Vector3(x, y, z))
	# 按高度场求真实法线：以前全写死 UP，坡面拿不到明暗，远山是平的色块。
	var normals: Array[Vector3] = []
	for iz in subdivisions + 1:
		for ix in subdivisions + 1:
			var i: int = iz * (subdivisions + 1) + ix
			var xl: int = maxi(ix - 1, 0)
			var xr: int = mini(ix + 1, subdivisions)
			var zd: int = maxi(iz - 1, 0)
			var zu: int = mini(iz + 1, subdivisions)
			var vl: Vector3 = verts[iz * (subdivisions + 1) + xl]
			var vr: Vector3 = verts[iz * (subdivisions + 1) + xr]
			var vd: Vector3 = verts[zd * (subdivisions + 1) + ix]
			var vu: Vector3 = verts[zu * (subdivisions + 1) + ix]
			var dl: float = vr.x - vl.x
			var du: float = vu.z - vd.z
			var tx := Vector3(dl, vr.y - vl.y, 0.0)
			var tz := Vector3(0.0, vu.y - vd.y, du)
			var n := tz.cross(tx).normalized()
			if n.y < 0.0:
				n = -n
			normals.append(n)
	# 顶点色：低频噪声 + 坡度，让远山/丘陵不再是一整块平色。
	# 草坡偏暖、陡坎压暗；雪面保持冷白，只做轻微明暗起伏。
	var tint_noise := _terrain_tint_noise()
	var colors: Array[Color] = []
	colors.resize(verts.size())
	for vi in verts.size():
		var v := verts[vi]
		var nn := tint_noise.get_noise_2d(v.x, v.z) * 0.5 + 0.5
		var slope := clampf(1.0 - normals[vi].y, 0.0, 1.0)
		var shade := lerpf(0.86, 1.04, nn) * (1.0 - slope * 0.20)
		var warm := clampf(nn * 0.65 + slope * 0.35, 0.0, 1.0)
		colors[vi] = Color(
			shade * lerpf(0.96, 1.04, warm),
			shade,
			shade * lerpf(1.04, 0.96, warm),
			1.0)
	for iz in subdivisions:
		for ix in subdivisions:
			var a: int = iz * (subdivisions + 1) + ix
			var b: int = a + 1
			var c: int = a + (subdivisions + 1)
			var d: int = c + 1
			var va: Vector3 = verts[a]
			var vb: Vector3 = verts[b]
			var vc: Vector3 = verts[c]
			var vd: Vector3 = verts[d]
			var inv_tile := 1.0 / 3.6
			st.set_color(colors[a])
			st.set_normal(normals[a])
			st.set_uv(Vector2(va.x, va.z) * inv_tile)
			st.add_vertex(va)
			st.set_color(colors[c])
			st.set_normal(normals[c])
			st.set_uv(Vector2(vc.x, vc.z) * inv_tile)
			st.add_vertex(vc)
			st.set_color(colors[d])
			st.set_normal(normals[d])
			st.set_uv(Vector2(vd.x, vd.z) * inv_tile)
			st.add_vertex(vd)
			st.set_color(colors[a])
			st.set_normal(normals[a])
			st.set_uv(Vector2(va.x, va.z) * inv_tile)
			st.add_vertex(va)
			st.set_color(colors[d])
			st.set_normal(normals[d])
			st.set_uv(Vector2(vd.x, vd.z) * inv_tile)
			st.add_vertex(vd)
			st.set_color(colors[b])
			st.set_normal(normals[b])
			st.set_uv(Vector2(vb.x, vb.z) * inv_tile)
			st.add_vertex(vb)
	var mesh := st.commit()
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	return mi


func _build_start_grid() -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.94, 0.94, 0.92)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for row in 4:
		for col in 2:
			var dist := -9.0 - row * 8.0
			var lateral := -2.6 if col == 0 else 2.6
			var f := path.frame_at(dist)
			if f.is_empty():
				continue
			var pos: Vector3 = f["pos"] + (f["side"] as Vector3) * lateral
			var tangent: Vector3 = f["tangent"]
			var side: Vector3 = f["side"]
			var half := 1.5
			var back := 1.1
			var a := pos - side * half + Vector3(0.0, 0.045, 0.0)
			var b := pos + side * half + Vector3(0.0, 0.045, 0.0)
			var c := pos - side * half - tangent * back + Vector3(0.0, 0.045, 0.0)
			var d := pos + side * half - tangent * back + Vector3(0.0, 0.045, 0.0)
			_add_quad(st, a, b, c, d, Vector2(0, 0), Vector2(1, 0), Vector2(0, 1), Vector2(1, 1))
			var e2 := pos + tangent * 5.2
			var a2 := e2 - side * half + Vector3(0.0, 0.045, 0.0)
			var b2 := e2 + side * half + Vector3(0.0, 0.045, 0.0)
			var c2 := e2 - side * half + tangent * 0.16 + Vector3(0.0, 0.045, 0.0)
			var d2 := e2 + side * half + tangent * 0.16 + Vector3(0.0, 0.045, 0.0)
			_add_quad(st, a2, b2, c2, d2, Vector2(0, 0), Vector2(1, 0), Vector2(0, 1), Vector2(1, 1))
	_new_mesh_instance(st.commit(), mat, "StartGrid")


## 湿路积水：只在高/超高画质铺，沿路面随机摆放 Decal。积分水膜用低粗糙度
## ORM + 细法线，直接吃引擎 SSR，把霓虹/车灯/路灯拖成一条条湿反光。
func _build_puddles() -> void:
	var wet := String(theme.get("weather", "")) == "rain" \
		or String(path.id) in ["city", "skyline", "metro"] \
		or float(theme.get("roadRoughness", 1.0)) < 0.45
	if not wet:
		return
	if Settings.index < 2:
		return
	var textures := _puddle_textures()
	if textures.is_empty():
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(String(path.id)) + 7717
	var dist := 16.0
	var placed := 0
	while dist < path.total_length and placed < 38:
		var f := path.frame_at(dist)
		if not f.is_empty():
			var side: Vector3 = f["side"]
			var tangent: Vector3 = f["tangent"]
			var lateral := rng.randf_range(-path.half_width + 1.4, path.half_width - 1.4)
			var pos: Vector3 = (f["pos"] as Vector3) + side * lateral
			var puddle := Decal.new()
			puddle.name = "Puddle"
			puddle.texture_albedo = textures["albedo"]
			puddle.texture_normal = textures["normal"]
			puddle.texture_orm = textures["orm"]
			puddle.size = Vector3(rng.randf_range(2.2, 5.6), 0.24, rng.randf_range(3.0, 10.0))
			puddle.position = pos + Vector3(0.0, 0.14, 0.0)
			puddle.rotation.y = atan2(tangent.x, tangent.z) + rng.randf_range(-0.14, 0.14)
			puddle.albedo_mix = 0.88
			puddle.normal_fade = 0.75
			puddle.upper_fade = 0.30
			puddle.lower_fade = 0.30
			puddle.distance_fade_enabled = true
			puddle.distance_fade_begin = 160.0
			puddle.distance_fade_length = 70.0
			puddle.cull_mask = 1
			add_child(puddle)
			placed += 1
		dist += rng.randf_range(14.0, 34.0)


static var _puddle_tex: Dictionary = {}


static func _puddle_textures() -> Dictionary:
	if not _puddle_tex.is_empty():
		return _puddle_tex
	var size := 128
	var noise := FastNoiseLite.new()
	noise.seed = 4242
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.045
	noise.fractal_octaves = 3
	noise.fractal_gain = 0.5
	var albedo := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var orm := Image.create(size, size, false, Image.FORMAT_RGB8)
	var normal := Image.create(size, size, false, Image.FORMAT_RGB8)
	var heights := PackedFloat32Array()
	heights.resize(size * size)
	for y in size:
		for x in size:
			var u := (float(x) + 0.5) / float(size)
			var v := (float(y) + 0.5) / float(size)
			var r := Vector2(u - 0.5, v - 0.5).length() * 2.0
			var n := noise.get_noise_2d(float(x), float(y)) * 0.5 + 0.5
			heights[y * size + x] = n
			# 不规则水边，避免每滩都是完美圆形
			var edge := smoothstep(1.02, 0.42, r + (n - 0.5) * 0.36)
			var alpha := clampf(edge, 0.0, 1.0) * 0.82
			albedo.set_pixel(x, y, Color(0.018, 0.024, 0.032, alpha))
			# ORM: R=AO 1.0，G=粗糙度（水膜 0.03~0.16），B=金属度 0.72
			var rough := lerpf(0.03, 0.16, n)
			orm.set_pixel(x, y, Color(1.0, rough, 0.72))
	for y in size:
		for x in size:
			var xl := heights[y * size + posmod(x - 1, size)]
			var xr := heights[y * size + posmod(x + 1, size)]
			var yu := heights[posmod(y - 1, size) * size + x]
			var yd := heights[posmod(y + 1, size) * size + x]
			var nvec := Vector3(-(xr - xl) * 1.8, (yd - yu) * 1.8, 1.0).normalized()
			normal.set_pixel(x, y, Color(
				nvec.x * 0.5 + 0.5, nvec.y * 0.5 + 0.5, nvec.z * 0.5 + 0.5))
	albedo.generate_mipmaps()
	orm.generate_mipmaps()
	normal.generate_mipmaps()
	_puddle_tex = {
		"albedo": ImageTexture.create_from_image(albedo),
		"orm": ImageTexture.create_from_image(orm),
		"normal": ImageTexture.create_from_image(normal),
	}
	return _puddle_tex


func _build_runoff() -> void:
	# 弯道外侧缓冲带：真实沙砾 PBR + 逐顶点贴地，山路上不再悬空。
	var ground: Dictionary = theme.get("ground", {})
	var edge_col := _color(String(ground.get("edge", "#8a7a5c")), Color(0.66, 0.58, 0.44))
	var mat := PbrAssets.material(
		"textures/dry_ground_rocks/dry_ground_rocks_diff.jpg",
		"textures/dry_ground_rocks/dry_ground_rocks_nor.jpg",
		"textures/dry_ground_rocks/dry_ground_rocks_rough.jpg")
	mat.albedo_color = edge_col
	mat.roughness = 0.98
	mat.normal_scale = 0.5
	mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var count := path.samples.size()
	var inv_tile := 1.0 / 3.6
	var steps := 3
	for side_sign: float in [-1.0, 1.0]:
		var prev_row: Array[Vector3] = []
		for i in count + 1:
			var idx := i % count
			if absf(path.curvatures[idx]) < 0.008:
				prev_row = []
				continue
			var center := path.samples[idx]
			var side := path.sides[idx]
			var row: Array[Vector3] = []
			for k in steps + 1:
				var off := lerpf(path.half_width + 0.55, path.half_width + 11.0,
					float(k) / float(steps))
				var p: Vector3 = center + side * off * side_sign
				p.y = Terrain.height_at(p) + 0.012
				row.append(p)
			if not prev_row.is_empty():
				for k in steps:
					var a: Vector3 = prev_row[k]
					var b: Vector3 = prev_row[k + 1]
					var c: Vector3 = row[k]
					var d: Vector3 = row[k + 1]
					_add_quad(st, a, b, c, d,
						Vector2(a.x, a.z) * inv_tile, Vector2(b.x, b.z) * inv_tile,
						Vector2(c.x, c.z) * inv_tile, Vector2(d.x, d.z) * inv_tile)
			prev_row = row
	_new_mesh_instance(st.commit(), mat, "Runoff")


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

func _build_flat_strip(lateral: float, strip_width: float, color: Color, dash_period: float,
		additive: bool = false) -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var y_off := 0.035
	if additive:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
		mat.no_depth_test = false
		# 光晕压在标线下方 4mm，避免和实体标线 z-fighting
		y_off = 0.031
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var half := strip_width * 0.5
	var m := path.samples.size()
	for i in m:
		if dash_period > 0.0:
			var phase := fposmod(path.accumulated[i], dash_period)
			if phase > dash_period * 0.55:
				continue
		var j := (i + 1) % m
		var pi := path.samples[i] + path.sides[i] * lateral
		var pj := path.samples[j] + path.sides[j] * lateral
		var si := path.sides[i]
		var sj := path.sides[j]
		var a := pi - si * half + Vector3(0.0, y_off, 0.0)
		var b := pi + si * half + Vector3(0.0, y_off, 0.0)
		var c := pj - sj * half + Vector3(0.0, y_off, 0.0)
		var d := pj + sj * half + Vector3(0.0, y_off, 0.0)
		_add_quad(st, a, b, c, d, Vector2(0, 0), Vector2(1, 0), Vector2(0, 1), Vector2(1, 1))
	_new_mesh_instance(st.commit(), mat, "LaneGlow" if additive else "LaneMarking")


func _add_quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3,
		ua: Vector2, ub: Vector2, uc: Vector2, ud: Vector2) -> void:
	var n := Vector3.UP
	st.set_normal(n)
	st.set_uv(ua)
	st.add_vertex(a)
	st.set_normal(n)
	st.set_uv(uc)
	st.add_vertex(c)
	st.set_normal(n)
	st.set_uv(ub)
	st.add_vertex(b)
	st.set_normal(n)
	st.set_uv(ub)
	st.add_vertex(b)
	st.set_normal(n)
	st.set_uv(uc)
	st.add_vertex(c)
	st.set_normal(n)
	st.set_uv(ud)
	st.add_vertex(d)


func _new_mesh_instance(mesh: Mesh, material: Material, node_name: String) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = mesh
	mi.material_override = material
	add_child(mi)
	return mi


func _checker_texture() -> ImageTexture:
	# 固定 256×32 棋盘格 + mipmap：远处起跑线不再闪成噪点
	var img := Image.create(256, 32, false, Image.FORMAT_RGB8)
	for y in 32:
		for x in 256:
			var on := (int(x / 32.0) + int(y / 16.0)) % 2 == 0
			img.set_pixel(x, y, Color(0.93, 0.93, 0.9) if on else Color(0.05, 0.05, 0.06))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


func _color(hex: String, fallback: Color) -> Color:
	if hex.is_empty():
		return fallback
	var c := Color.from_string(hex, fallback)
	return c
