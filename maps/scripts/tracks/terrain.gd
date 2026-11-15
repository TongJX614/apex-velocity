class_name Terrain
extends RefCounted
## Rolling-hill height field for the circuits. The corridor next to the racing
## surface stays flat (so barriers/venue sit correctly); further out the ground
## undulates into hills.
##
## 海岸 / 港湾模式（setup_coast）：
##   赛道内圈（-side 方向，所有赛道都是这个方向）保持陆地 + 丘陵；
##   赛道外圈（+side 方向）在离赛道 10~50m 处一路下坡沉到海平面以下，
##   于是海面直接贴着赛道一侧，沙滩平行于路，远处交给雾 + 剪影。
##   起跑主直道（场馆区）两侧保持陆地，看台/维修区不会泡在海里。
##
## The same height function is used for the terrain mesh and for placing trees,
## grass and rocks, so nothing floats.

static var active := false
static var _noise: FastNoiseLite
static var _samples: PackedVector3Array = PackedVector3Array()
static var _sides: PackedVector3Array = PackedVector3Array()
static var _along: PackedFloat32Array = PackedFloat32Array()
static var _half := 0.0
static var _flat_radius := 0.0
static var _full_radius := 0.0
static var _amplitude := 0.0
static var _island_edge := 590.0

# --- 海岸模式 ---
static var _coast := false
static var _sea_start := 13.0
static var _sea_end := 46.0
static var _sea_floor := -4.2
static var _venue_mid := 0.0
static var _venue_half := 0.0
static var _total_length := 0.0


static func reset() -> void:
	active = false
	_coast = false
	_samples = PackedVector3Array()
	_sides = PackedVector3Array()
	_along = PackedFloat32Array()


static func setup(path: TrackPath, amplitude: float = 26.0, island_edge: float = 590.0) -> void:
	_coast = false
	_setup_common(path, amplitude)
	_island_edge = island_edge


## 海岸 / 港湾：+side 方向是海，-side 方向是陆地；主直道两侧都保持陆地。
## sea_start / sea_end 是「从路肩算起的横向米数」。
static func setup_coast(path: TrackPath, amplitude: float, sea_start: float, sea_end: float,
		sea_floor: float, venue_center_dist: float, venue_half_len: float) -> void:
	_coast = true
	_setup_common(path, amplitude)
	_sea_start = sea_start
	_sea_end = maxf(sea_end, sea_start + 8.0)
	_sea_floor = sea_floor
	_venue_mid = venue_center_dist
	_venue_half = maxf(venue_half_len, 30.0)
	_island_edge = 0.0


static func _setup_common(path: TrackPath, amplitude: float) -> void:
	active = true
	_amplitude = amplitude
	_half = path.half_width
	_flat_radius = path.half_width + 28.0
	_full_radius = _flat_radius + 150.0
	_total_length = path.total_length
	_noise = FastNoiseLite.new()
	_noise.seed = hash(String(path.id)) + 991
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_noise.frequency = 0.005
	_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	_noise.fractal_octaves = 4
	_noise.fractal_gain = 0.5
	_noise.fractal_lacunarity = 2.0
	_samples = PackedVector3Array()
	_sides = PackedVector3Array()
	_along = PackedFloat32Array()
	var step := 6
	var i := 0
	while i < path.samples.size():
		_samples.append(path.samples[i])
		_sides.append(path.sides[i])
		_along.append(path.accumulated[i])
		i += step


static func distance_to_path(pos: Vector3) -> float:
	var best := 1.0e9
	for p in _samples:
		var dx := p.x - pos.x
		var dz := p.z - pos.z
		var d := dx * dx + dz * dz
		if d < best:
			best = d
	return sqrt(best)


## 最近中心线采样点的索引（供需要判断内/外圈、横向距离的代码用）。
static func nearest_index(pos: Vector3) -> int:
	var best_i := 0
	var best := 1.0e9
	for i in _samples.size():
		var p := _samples[i]
		var dx := p.x - pos.x
		var dz := p.z - pos.z
		var d := dx * dx + dz * dz
		if d < best:
			best = d
			best_i = i
	return best_i


## 点到赛道中线的横向有符号距离（+ = 海侧 / 外圈，- = 陆侧 / 内圈）。
static func lateral_of(pos: Vector3) -> float:
	if _samples.is_empty():
		return 0.0
	var i := nearest_index(pos)
	var p := _samples[i]
	return ((pos.x - p.x) * _sides[i].x) + ((pos.z - p.z) * _sides[i].z)


## 该点是否在场馆（起跑主直道）保护区内：保护区内两侧都是陆地。
static func in_venue_zone(pos: Vector3) -> bool:
	if _samples.is_empty() or _total_length <= 0.0 or _venue_half <= 0.0:
		return false
	var i := nearest_index(pos)
	var d := _along[i]
	var delta := wrapf(d - _venue_mid, -_total_length * 0.5, _total_length * 0.5)
	return absf(delta) <= _venue_half


static func height_at(pos: Vector3) -> float:
	if not active or _noise == null:
		return 0.0
	if _coast:
		return _coast_height(pos)
	var radius := Vector2(pos.x, pos.z).length()
	if radius > _island_edge + 60.0:
		return 0.0
	var n := _noise.get_noise_2d(pos.x, pos.z)
	var base := n * _amplitude
	var dist := distance_to_path(pos)
	# flat near the track, ramping up into hills further away
	var corridor := smoothstep(_flat_radius, _full_radius, dist)
	# keep the shoreline low so the beach stays flat
	var shore := 1.0 - smoothstep(_island_edge - 70.0, _island_edge + 40.0, radius)
	return base * corridor * shore


static func _coast_height(pos: Vector3) -> float:
	if _samples.is_empty():
		return 0.0
	var i := nearest_index(pos)
	var p := _samples[i]
	var dx := pos.x - p.x
	var dz := pos.z - p.z
	var dist := sqrt(dx * dx + dz * dz)
	var lateral := (dx * _sides[i].x) + (dz * _sides[i].z)
	var land_side := lateral < 0.0
	# 场馆保护区：两侧都当地处理
	if in_venue_zone(pos):
		land_side = true
	var n := _noise.get_noise_2d(pos.x, pos.z)
	if land_side:
		# 陆侧：近处平，远处起伏成丘陵（细节只做到 90m，更远交给雾/剪影）
		var corridor := smoothstep(_flat_radius, _flat_radius + 130.0, dist)
		return n * _amplitude * corridor
	# 海侧：路肩外 sea_start 开始缓坡，sea_end 之前沉到海床
	if dist <= _sea_start:
		return n * 0.12 * smoothstep(_flat_radius * 0.5, _sea_start, dist)
	var t := smoothstep(_sea_start, _sea_end, dist)
	var dune := n * 0.35 * (1.0 - t) * clampf((dist - _sea_start) * 0.25, 0.0, 1.0)
	return _sea_floor * t + dune


static func height_flat(pos: Vector3) -> float:
	# venue buildings / barriers sit on the flat corridor next to the track
	if distance_to_path(pos) <= _flat_radius:
		return 0.0
	return height_at(pos)


## 海床高度（海岸模式下海面 y 参考）：供 track_builder 摆水面用。
static func sea_floor() -> float:
	return _sea_floor
