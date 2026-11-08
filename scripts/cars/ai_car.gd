class_name AICar
extends Node3D
## Kinematic rival: a faithful port of the legacy three.js AICar.
##
## The original rivals do not simulate a physics body — they follow the track
## spline at a target speed driven by upcoming curvature, rubber-band slightly
## against the player's pace, pick a lane to avoid traffic and capture a small
## draft bonus. Keeping the same model means the grid behaves exactly like the
## WebGL build instead of turning into a demolition derby.

var track: TrackPath
var spec: Dictionary
var display_name := ""
var number := 0
var car_color := Color.WHITE
var base_speed := 70.0
var pace_bias := 0.0
var variant_id := ""
## 车手风格分化：弯道自信度（决定弯里减速多少）与直线爆发（决定能贴到多快）。
## 同一场里三台 AI 用不同组合，彻底避免「三车等速火车队」。
var corner_conf := 1.0        # <1 弯里更怂，>1 弯里更凶
var top_push := 1.0           # 直线段在 pace_ref 上的放大系数
var lane_pref := 0.0          # 常用车线（-1 内线 .. +1 外线），不同车手走不同线
var aggression := 0.0         # 追近前车时的加力倾向
# 走线/节奏个性：按车号确定性生成，保证同一场里三台 AI 各走各的线、快慢起伏不同。
var corner_line := 0.0        # 弯道走线倾向（-1 一直走外线 .. +1 一直切内线）
var line_phase := 0.0         # 摆动线相位
var wob_amp := 0.0            # 沿途摆动幅度（米）
var wob_freq := 0.008         # 沿途摆动频率（rad/m）
var tempo := 1.0              # 配速微调（每车手不同，制造速度差）
var band_gain := 0.0007       # 橡皮筋强度（对玩家差距的敏感度）
var bump_lat := 0.0           # 碰撞弹开的横向冲量（米，随时间衰减）
var bump_timer := 0.0         # 弹开避让剩余时间（秒）
var avoid_dir := 0.0          # 锁存的避让方向，防止每帧左右抖动
var avoid_timer := 0.0        # 避让方向锁存剩余时间（秒）
# ---- 玩家走线回放（AI 路线库）----
# main 从 RecordsStore 抽一条历史走线塞进来，AI 就按玩家真实开过的线跑；
# 每台 AI 再叠一个固定的小偏移/摆动，保证同一条线也不会三车完全重合。
var route_lat := PackedFloat32Array()
var route_spd := PackedFloat32Array()
var route_step := 0.0
var use_route := false
var route_shift := 0.0
var route_id := ""

var dist := 0.0
var race_dist := 0.0
var offset := 0.0
var speed := 0.0
var heading := 0.0
var pos := Vector3.ZERO
var lap := 0
var finished := false
var finish_time := -1.0
var elapsed := 0.0
var lap_start := 0.0
var last_lap_time := -1.0
var best_lap := -1.0
var new_lap_time := -1.0
var target_speed := 0.0

var model: Node3D
var spin_wheels: Array[Node3D] = []
var steer_wheels: Array[Node3D] = []
var wheel_radius := 0.34
var wheel_spin := 0.0
var _frame: Dictionary = {}


func setup(track_path: TrackPath, car_spec: Dictionary, start_dist: float, lateral: float,
		speed_base: float, ai_color: Color, ai_name: String = "", ai_number: int = 0) -> void:
	track = track_path
	spec = car_spec
	variant_id = String(car_spec.get("id", ""))
	display_name = ai_name if not ai_name.is_empty() else String(car_spec.get("name", variant_id))
	number = ai_number if ai_number > 0 else int(car_spec.get("number", 0))
	# AI 天花板速度 = 它自己驾驶的那台车的真实极速 × 90% × 车手系数。
	# ai.json 的 baseSpeed 现在表示车手能力（76.5 为基准车手，值越大越快），
	# 这样 45 台车的真实性能表换掉之后，AI 不需要逐台重新配速。
	base_speed = speed_base
	var skill := clampf(speed_base / 76.5, 0.90, 1.08)
	var spec_top := float(car_spec.get("maxSpeed", 0.0))
	if spec_top > 10.0:
		base_speed = spec_top * 0.90 * skill
	# 车手风格分化：按车手能力系数推导，保证快车手全程真的更快、慢车手全程更慢，
	# 不再靠贴身跟随玩家来凑成绩。
	var skill01 := inverse_lerp(0.90, 1.08, skill)
	pace_bias = lerpf(-0.045, 0.045, skill01)
	corner_conf = lerpf(0.86, 1.16, skill01)
	top_push = lerpf(0.94, 1.08, skill01)
	aggression = lerpf(0.25, 0.85, skill01)
	lane_pref = lerpf(-0.5, 0.5, skill01)
	# 走线/节奏个性：由车号确定性生成（重开比赛同一车手风格不变），
	# 和能力系数解耦——快车手也可以偏外线慢漂，慢车手也可以爱切内线。
	var rng := RandomNumberGenerator.new()
	rng.seed = (ai_number if ai_number > 0 else int(car_spec.get("number", 7))) * 7919 + 104729
	lane_pref = lerpf(-0.85, 0.85, rng.randf())
	corner_line = lerpf(-1.0, 1.0, rng.randf())
	wob_amp = lerpf(0.5, 1.4, rng.randf())
	wob_freq = lerpf(0.005, 0.012, rng.randf())
	line_phase = rng.randf() * TAU
	tempo = lerpf(0.97, 1.045, rng.randf())
	band_gain = lerpf(0.00016, 0.00030, rng.randf())
	bump_lat = 0.0
	bump_timer = 0.0
	avoid_dir = 0.0
	avoid_timer = 0.0
	route_shift = lerpf(-0.75, 0.75, rng.randf())
	car_color = ai_color
	dist = start_dist
	race_dist = start_dist
	offset = lateral
	speed = 0.0
	elapsed = 0.0
	lap_start = 0.0
	lap = 0
	finished = false
	finish_time = -1.0
	last_lap_time = -1.0
	best_lap = -1.0
	new_lap_time = -1.0
	_frame = track.frame_at(dist)
	pos = (_frame["pos"] as Vector3) + (_frame["side"] as Vector3) * offset
	heading = atan2((_frame["tangent"] as Vector3).x, (_frame["tangent"] as Vector3).z)
	_build_visual(ai_color)
	_sync_visual(0.0)


## 塞入一条玩家历史走线：{"step": 米, "lat": [...], "spd": [...]}。
func set_route(line: Dictionary, id: String = "") -> void:
	route_lat = PackedFloat32Array()
	route_spd = PackedFloat32Array()
	route_step = 0.0
	use_route = false
	route_id = id
	var lat = line.get("lat", [])
	if typeof(lat) != TYPE_ARRAY or (lat as Array).size() < 24:
		return
	for v in (lat as Array):
		route_lat.append(float(v))
	var spd = line.get("spd", [])
	if typeof(spd) == TYPE_ARRAY:
		for v in (spd as Array):
			route_spd.append(float(v))
	route_step = maxf(4.0, float(line.get("step", 0.0)))
	use_route = route_step > 0.1


func has_route() -> bool:
	return use_route and route_lat.size() >= 24


func _build_visual(paint: Color) -> void:
	var result := CarVisual.build(spec, self, paint)
	model = result["model"] as Node3D
	for node in result["spin_wheels"]:
		spin_wheels.append(node as Node3D)
	for node in result["steer_wheels"]:
		steer_wheels.append(node as Node3D)
	wheel_radius = float(result["wheel_radius"])
	apply_quality_shadows()


## 低画质档：AI 车不投实时阴影，改用已有的接触阴影（换档时 main 会再同步一次）。
func apply_quality_shadows() -> void:
	CarVisual.set_shadow_casting(model, Settings.index > 0)


func update_ai(dt: float, player_car: Car, race_laps: int, rivals: Array, pace: float) -> void:
	elapsed += dt
	var look_meters := 26.0 + speed * 1.9
	var curvature := track.max_curvature_ahead(dist, look_meters, 12.0)

	# 配速以「自己这台车 + 自己的车手性格」为基准，玩家 pace 只做温和校准。
	# 三台车不再共用同一个跟随速度；固定节奏差会随着圈数自然拉开。
	var own_cruise := base_speed * 0.90 * top_push * tempo
	var pace_ref := own_cruise
	var gap := player_car.race_dist - race_dist
	if pace > 0.0:
		var player_target := pace * (1.0 + pace_bias) * tempo
		var follow := clampf(1.0 - absf(gap) / 140.0, 0.30, 0.85) * (0.50 + 0.35 * aggression)
		pace_ref = lerpf(own_cruise, player_target, follow)
		pace_ref = minf(pace_ref, pace * (1.10 + 0.20 * aggression) + 1.0)
		pace_ref = maxf(pace_ref, base_speed * 0.52)
	# 弯道减速按车手自信度分化：怂的车手弯里明显更慢，凶的车手几乎不减速。
	var target := pace_ref * clampf(1.0 - curvature * 38.0 * corner_conf, 0.52, 1.0)
	# 只保留很弱的远距离橡皮筋：防止某一台车掉出视野后永远追不回来，
	# 但不再把三台车强行绑成同一速度（旧版 ±14% 的带宽是火车队的根源）。
	target *= clampf(1.0 + gap * band_gain, 0.965, 1.035)
	# 慢节奏起伏：每车手不同相位的速度波动，长直道上也能看到前后互换。
	target *= 1.0 + 0.035 * sin(elapsed * 0.33 + line_phase)
	avoid_timer = maxf(avoid_timer - dt, 0.0)
	if not player_car.player_finished and finished:
		target *= 0.86

	# ---- 常用车线：base（车道偏好）+ 摆动线 + 弯道内外线，三台车各走各的 ----
	# 窄路（城市真实路面）按当前位置的动态半宽收窄：lane_limit=0 时 AI 走正中。
	var hw_local := track.half_width_at_dist(dist)
	var lane_limit := maxf(hw_local - 2.2, 0.0)
	var dodge_shift := minf(2.6, lane_limit * 0.8)
	var lane_base := lane_pref * lane_limit
	var lane_target := lane_base + sin(dist * wob_freq + line_phase) * wob_amp * clampf(lane_limit / 4.0, 0.0, 1.0)
	# 弯道走线：corner_line >0 爱切内线，<0 习惯走外线待机出弯。
	# 内侧方向 = side * sign(曲率)（曲率 >0 = 向右转，弯心在右侧）。
	var corner_frame := track.frame_at(dist + 14.0)
	if not corner_frame.is_empty():
		var curv_ahead := float(corner_frame.get("curvature", 0.0))
		var inside := signf(curv_ahead) * clampf(absf(curv_ahead) * 200.0, 0.0, 1.0)
		lane_target += inside * corner_line * lane_limit * 0.55
	# 有玩家历史走线时，用真实走线替换「车道偏好 + 摆动 + 弯道倾向」，
	# 只保留一点点车手自身摆动，避免三台 AI 走成完全相同的轨迹。
	if has_route():
		var span := route_step * float(route_lat.size())
		var u := fposmod(dist, span) / route_step
		var i0 := int(floor(u)) % route_lat.size()
		var i1 := (i0 + 1) % route_lat.size()
		var frac := u - floorf(u)
		var recorded := lerpf(route_lat[i0], route_lat[i1], frac) + route_shift
		lane_target = recorded + sin(dist * wob_freq + line_phase) * wob_amp * 0.28
		# 回放线里的速度只作为「这里该收油」的软提示，不直接锁 AI 速度，
		# 否则一条跑崩的成绩会把整场 AI 一起拖慢。
		if route_spd.size() == route_lat.size():
			var rec_kph := lerpf(route_spd[i0], route_spd[i1], frac)
			if rec_kph > 20.0:
				target = minf(target, rec_kph / 3.6 * (1.14 + 0.10 * corner_conf))
	var f := _frame
	if f.is_empty():
		f = track.frame_at(dist)
	var tan: Vector3 = f["tangent"]
	var side: Vector3 = f["side"]

	# 避让玩家：只处理真正在正前方、挡在同一条线上的情况（以前连身后的
	# 玩家也躲，方向还写反，三台车会主动往彼此身上挤）。障碍在右→向左让。
	var pdx := player_car.pos.x - pos.x
	var pdz := player_car.pos.z - pos.z
	if pdx * pdx + pdz * pdz < 196.0:
		var ahead := pdx * tan.x + pdz * tan.z
		var lateral := pdx * side.x + pdz * side.z
		if ahead > 0.3 and ahead < 10.0 and absf(lateral) < minf(3.4, lane_limit + 1.0):
			if avoid_timer <= 0.0:
				avoid_dir = _choose_dodge(lateral)
				avoid_timer = 0.9
			lane_target += avoid_dir * dodge_shift
			if ahead < 6.0:
				target *= 0.95
		elif ahead > 6.0 and ahead < 20.0 and absf(lateral) < minf(3.0, lane_limit):
			target *= 1.03

	# 纵向间隔：前车太近就收油、被后车贴住就轻微提速，
	# 让三台车在直道上自然拉开成 15~25m 的间距，而不是贴成一列。
	var spacing_mult := 1.0
	for other in rivals:
		if other == self:
			continue
		var sdx: float = other.pos.x - pos.x
		var sdz: float = other.pos.z - pos.z
		if sdx * sdx + sdz * sdz > 2025.0:
			continue
		var s_ahead := sdx * tan.x + sdz * tan.z
		var s_lat := absf(sdx * side.x + sdz * side.z)
		if s_lat > 3.8:
			continue
		if s_ahead > 0.0 and s_ahead < 26.0:
			spacing_mult -= lerpf(0.090, 0.012, s_ahead / 26.0) * (0.55 + 0.45 * aggression)
		elif s_ahead <= 0.0 and s_ahead > -22.0:
			spacing_mult += lerpf(0.032, 0.006, -s_ahead / 22.0) * (0.60 + 0.40 * aggression)
	target *= clampf(spacing_mult, 0.90, 1.038)

	# 避让对手 + 尾流：只躲前方车，并排时按号码固定让线（不再双向躲避），
	# 这样每台车都能稳定地走自己的线，而不是三车互相别来别去粘成一团。
	var draft_targets := 0
	for other in rivals:
		if other == self:
			continue
		var dx: float = other.pos.x - pos.x
		var dz: float = other.pos.z - pos.z
		var d2 := dx * dx + dz * dz
		if d2 > 256.0 or d2 < 0.0001:
			continue
		var ahead := dx * tan.x + dz * tan.z
		var lateral := dx * side.x + dz * side.z
		if ahead > 0.5 and ahead < 10.0 and absf(lateral) < minf(3.3, lane_limit + 1.0):
			if avoid_timer <= 0.0:
				avoid_dir = _choose_dodge(lateral)
				avoid_timer = 1.2
			lane_target += avoid_dir * dodge_shift
			if ahead < 6.5 and target_speed < float(other.target_speed) + 0.8:
				target *= 0.97
		elif ahead > 7.0 and ahead < 15.0 and absf(lateral) < minf(2.6, lane_limit):
			draft_targets += 1
		elif absf(ahead) <= 5.0 and absf(lateral) < minf(2.8, lane_limit):
			# 并排：号码大的车（车队一号）先冲出去，另一台稳定收油并让线。
			if number > other.number:
				target *= 1.015
			else:
				target *= 0.99
				var yield_shift := minf(1.8, lane_limit)
				lane_target += (yield_shift if lateral >= 0.0 else -yield_shift)
	if draft_targets > 0:
		target *= 1.0 + minf(draft_targets, 1) * (0.008 + 0.010 * aggression)

	# 碰撞弹开：被撞后的横向冲量在 0.9s 内线性衰减，期间轻微收油，
	# 让 AI 撞完先弹开减速，再慢慢回到自己的走线（而不是立刻贴回来）。
	if bump_timer > 0.0:
		bump_timer = maxf(bump_timer - dt, 0.0)
		var bump_k := bump_timer / 0.9
		lane_target += bump_lat * bump_k
		target *= 1.0 - 0.10 * bump_k

	lane_target = clampf(lane_target, -lane_limit, lane_limit)
	target_speed = target
	# 起步不能瞬间 200km/h：用有上限的加速度（和玩家车接近），车手差异 ±10%
	if target > speed:
		var accel_rate := 12.0 * top_push * (1.0 - 0.42 * clampf(speed / maxf(base_speed, 1.0), 0.0, 1.0))
		speed = minf(speed + accel_rate * dt, target)
	else:
		speed = _damp(speed, target, 2.3, dt)
	dist += speed * dt
	race_dist = dist
	offset = _damp(offset, lane_target, 1.1 + 2.5 * clampf(bump_timer / 0.9, 0.0, 1.0), dt)

	_frame = track.frame_at(dist)
	pos = (_frame["pos"] as Vector3) + (_frame["side"] as Vector3) * offset
	heading = atan2((_frame["tangent"] as Vector3).x, (_frame["tangent"] as Vector3).z)

	var prev_lap := lap
	lap = int(floor(dist / maxf(track.total_length, 0.001)))
	if lap > prev_lap:
		var lap_time := elapsed - lap_start
		lap_start = elapsed
		if prev_lap < race_laps and lap_time > 5.0:
			last_lap_time = lap_time
			new_lap_time = lap_time
			if best_lap < 0.0 or lap_time < best_lap:
				best_lap = lap_time
	if not finished and lap >= race_laps:
		finished = true
	_sync_visual(dt)


func consume_new_lap_time() -> float:
	var value := new_lap_time
	new_lap_time = -1.0
	return value


func _sync_visual(dt: float) -> void:
	position = pos
	rotation = Vector3(0.0, heading, 0.0)
	if model == null:
		return
	var curvature := 0.0
	if not _frame.is_empty():
		curvature = float(_frame.get("curvature", 0.0))
	var lean := clampf(-curvature * speed * 0.9, -0.06, 0.06)
	model.rotation.z = _damp(model.rotation.z, lean, 5.0, dt)
	wheel_spin = fposmod(wheel_spin + speed / maxf(wheel_radius, 0.05) * dt, TAU)
	for w in spin_wheels:
		w.rotation.x = wheel_spin
	var steer_angle := 0.0
	if not _frame.is_empty():
		steer_angle = clampf(-curvature * 12.0, -0.35, 0.35)
	for w in steer_wheels:
		w.rotation.y = steer_angle


## 选一个固定的避让方向：障碍在右→向左，在左→向右；正前方→朝空间更大的一侧。
func _choose_dodge(lateral: float) -> float:
	if absf(lateral) > 0.35:
		return -signf(lateral)
	var lane_limit := maxf(track.half_width_at_dist(dist) - 2.2, 0.0)
	var room_right := lane_limit - offset
	var room_left := lane_limit + offset
	return 1.0 if room_right >= room_left else -1.0


static func _damp(current: float, target: float, lambda: float, dt: float) -> float:
	return lerpf(current, target, 1.0 - exp(-lambda * dt))
