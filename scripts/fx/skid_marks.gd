class_name SkidMarks
extends Node3D
## 车轮橡胶印。每条车轮一条独立环形缓冲 + 一张独立贴图。
##
## 落段按「这条车轮实际走过的距离」，段长 = 这次间距 × 重叠系数，
## 所以任何速度下都是连续的线。旧版是时间限流 + 固定段长（0.035s / 0.34m），
## 110km/h 时两次落印之间已经走出 1.07m，段长只有 0.34m，必然断成一截截方块。
## 打滑越重 → 印子越宽、重叠越深，透明度自然叠深，不需要逐帧改实例颜色。

const MARKS_PER_LANE := 300
const STEP := 0.42
const MIN_LEN := 0.34
const MAX_LEN := 2.60
const BASE_WIDTH := 0.28
const MAX_WIDTH := 0.50
const LIFT := 0.018
const TEX_VARIANTS := 4
const REAR_Z := -1.42
const FRONT_Z := 1.42
const HALF_TRACK := 0.76
const FRONT_WEIGHT := 0.72

var _lanes: Array = []
var _lane_owner := ""
var _texs: Array[Texture2D] = []


## 贴图在第一次用到时生成，赛道加载的遮罩期内完成。
func setup() -> void:
	for v in TEX_VARIANTS:
		_mark_texture(v)


## 主循环每帧调用；真正的限流在每条车轮里按行驶距离判定。
func emit_from_car(car: Car) -> void:
	if car == null:
		return
	var intensity := _slip_intensity(car)
	if intensity <= 0.03:
		return
	_ensure_lanes(car)
	for lane: Dictionary in _lanes:
		_push_lane(lane, car, intensity * float(lane["weight"]))

func _push_lane(lane: Dictionary, car: Car, intensity: float) -> void:
	var node := lane["node"] as Node3D
	var world := node.global_position if node != null and is_instance_valid(node) \
		else car.to_global(lane["fallback"] as Vector3)
	if not bool(lane["has_last"]):
		lane["last"] = world
		lane["has_last"] = true
		return
	var last := lane["last"] as Vector3
	var dx := world.x - last.x
	var dz := world.z - last.z
	var dist := sqrt(dx * dx + dz * dz)
	if dist < STEP:
		return
	# 车被重置或穿墙回位时不要拖出一条横穿球场的假印。
	if dist > 8.0:
		lane["last"] = world
		return
	var mmi := lane["mm"] as MultiMeshInstance3D
	var mm := mmi.multimesh
	var mid := Vector3((last.x + world.x) * 0.5, 0.0, (last.z + world.z) * 0.5)
	mid.y = maxf(car.global_position.y, Terrain.height_at(mid)) + LIFT
	var along := Vector3(dx, 0.0, dz).normalized()
	# 环位伪随机：同一圈里每段宽窄略有差别，整条才不像一根压平的管子。
	var jitter := _hash(float(int(lane["ring"])))
	var seg_len := clampf(dist * (1.34 + 0.34 * intensity), MIN_LEN, MAX_LEN) \
		* lerpf(0.92, 1.10, jitter)
	var width := lerpf(BASE_WIDTH, MAX_WIDTH, clampf(intensity, 0.0, 1.0)) \
		* lerpf(0.88, 1.06, _hash(float(int(lane["ring"])) + 17.0))
	# 直接按「侧向 × 纵向 × 法线」搭基，不能用 Basis.scaled()：
	# 它缩放的是矩阵的列，会把面片剪切成斜的、法线也不再朝上。
	var side := Vector3(along.z, 0.0, -along.x)
	var basis := Basis(side * width, along * seg_len, Vector3.UP)
	mm.set_instance_transform(int(lane["ring"]), Transform3D(basis, mid))
	lane["ring"] = (int(lane["ring"]) + 1) % MARKS_PER_LANE
	lane["last"] = world



## 稳定的 0~1 伪随机，用来给同一环位一个不变的宽窄/长短偏置。
func _hash(x: float) -> float:
	var s := sin(x * 12.9898) * 43758.5453
	return s - floor(s)


## 打滑强度：横向滑移和轮上功率是连续量，手刹/重刹是开关量。
func _slip_intensity(car: Car) -> float:
	var slip := clampf(absf(car.lat_slip) / 5.5, 0.0, 1.0)
	var spin := clampf(car.wheelspin / 0.55, 0.0, 1.0)
	var hb := 0.72 if car.handbrake else 0.0
	var brk := 0.45 if car.braking else 0.0
	return clampf(maxf(maxf(slip, spin), maxf(hb, brk)), 0.0, 1.0)


func _ensure_lanes(car: Car) -> void:
	if not _lanes.is_empty() and _lane_owner == String(car.car_id) \
		and _lanes.size() == (4 if _is_awd(car) else 2):
		return
	for child in get_children():
		if child is MultiMeshInstance3D:
			remove_child(child)
			child.free()
	_lanes.clear()
	_lane_owner = String(car.car_id)
	var specs: Array = [
		["RL", Vector3(HALF_TRACK, 0.0, REAR_Z), 1.0],
		["RR", Vector3(-HALF_TRACK, 0.0, REAR_Z), 1.0],
	]
	if _is_awd(car):
		specs.append(["FL", Vector3(HALF_TRACK, 0.0, FRONT_Z), FRONT_WEIGHT])
		specs.append(["FR", Vector3(-HALF_TRACK, 0.0, FRONT_Z), FRONT_WEIGHT])
	for idx in specs.size():
		var spec: Array = specs[idx]
		_lanes.append({
			"node": _find_wheel(car, String(spec[0])),
			"fallback": spec[1] as Vector3,
			"weight": float(spec[2]),
			"mm": _make_lane_mesh(idx),
			"ring": 0,
			"last": Vector3.ZERO,
			"has_last": false,
		})


func _is_awd(car: Car) -> bool:
	return String(car.drivetrain).to_upper() == "AWD"


func _find_wheel(car: Car, suffix: String) -> Node3D:
	var wheel := car.find_child("Spin_Wheel_" + suffix, true, false) as Node3D
	if wheel == null:
		wheel = car.find_child("Wheel_" + suffix, true, false) as Node3D
	return wheel


func _make_lane_mesh(variant: int) -> MultiMeshInstance3D:
	var quad := QuadMesh.new()
	# 基准 1×1m：宽和段长都靠实例缩放，两者才能各自独立调。
	quad.size = Vector2(1.0, 1.0)
	quad.material = _material(variant)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = quad
	mm.instance_count = MARKS_PER_LANE
	var hidden := Transform3D(Basis().scaled(Vector3.ZERO), Vector3.ZERO)
	for i in MARKS_PER_LANE:
		mm.set_instance_transform(i, hidden)
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "SkidLane%d" % variant
	mmi.multimesh = mm
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)
	return mmi


func _material(variant: int) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_texture = _mark_texture(variant % TEX_VARIANTS)
	mat.albedo_color = Color(0.05, 0.046, 0.042, 0.56)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	mat.disable_receive_shadows = true
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	return mat


## 48×160 的橡胶印：横向铺满大部分面片 + 纵向浓淡起伏 + 边缘被噪声啃缺。
## 两端只收到 0.36 而不是全透明：相邻段交叠处因此永远有底，接不上也不会露缝。
## 噪声频率必须够高：面片只有 0.5m 宽，特征尺寸超过 10cm 就会被放大成华夫格。
func _mark_texture(variant: int) -> Texture2D:
	while _texs.size() <= variant:
		var w := 48
		var h := 160
		var idx := _texs.size()
		var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
		var blob := FastNoiseLite.new()
		blob.seed = 907 + idx * 211
		blob.frequency = 0.11
		var streak := FastNoiseLite.new()
		streak.seed = 5101 + idx * 733
		streak.frequency = 0.16
		streak.fractal_octaves = 2
		var patch := FastNoiseLite.new()
		patch.seed = 6113 + idx * 149
		patch.frequency = 0.085
		var grain := FastNoiseLite.new()
		grain.seed = 2203 + idx * 397
		grain.frequency = 0.42
		for y in h:
			var t := float(y) / float(h - 1)
			var vend := 0.36 + 0.64 * (smoothstep(0.0, 0.20, t) \
				* (1.0 - smoothstep(0.80, 1.0, t)))
			var pt := (patch.get_noise_2d(11.0, float(y) * 2.6) + 1.0) * 0.5
			for x in w:
				var dx := absf(float(x) - float(w - 1) * 0.5) / (float(w - 1) * 0.5)
				var n := (blob.get_noise_2d(float(x), float(y) * 0.9) + 1.0) * 0.5
				var edge := 1.0 - smoothstep(0.58, 1.04, dx + (n - 0.5) * 0.30)
				var st := (streak.get_noise_2d(float(x) * 3.0, float(y) * 0.10) + 1.0) * 0.5
				var gr := (grain.get_noise_2d(float(x), float(y)) + 1.0) * 0.5
				var core := 1.0 - 0.18 * smoothstep(0.04, 0.55, dx)
				var a := clampf(edge * vend * core * (0.52 + 0.48 * st) \
					* (0.72 + 0.28 * pt) * (0.74 + 0.26 * gr), 0.0, 1.0)
				img.set_pixel(x, y, Color(1.0, 1.0, 1.0, a))
		img.generate_mipmaps()
		_texs.append(ImageTexture.create_from_image(img))
	return _texs[variant]
