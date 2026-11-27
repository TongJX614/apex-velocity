class_name AICar
extends Node3D
## Kinematic rival: a faithful port of the legacy three.js AICar.
##
## The original rivals do not simulate a physics body — they follow the track
## spline at a target speed driven by upcoming curvature, pick a lane to avoid
## traffic and capture a small draft bonus. The pace reference is the player's
## own speed (see update_ai), not the car's spec sheet, so a rival in an SUV
## still keeps up with a hypercar. Rivals run slightly quicker than the player
## and yield once they have broken away, so there is always a car to chase.
## Keeping the spline model means the grid behaves like the WebGL build
## instead of a demolition derby.

const KPH := 3.6                    # km/h -> m/s
const PACE_LEAD_KPH := 24.0         # 领跑时比玩家快出的量：电脑先跑，玩家去追
const PACE_CHASE_KPH := 5.0         # 刚被超掉时只贴不反超，留出超车的成就感
const ATTACK_KPH := 30.0            # 进攻段可以比玩家快的量
const CATCH_EXTRA_KPH := 25.0       # 深出回追带宽时额外加的回追额度
const LEAD_EASE_M := 30.0           # 领先超过该距离开始收油，等玩家追上来
const LEAD_RELEASE_M := 120.0       # 领先到该距离反而比玩家慢，把战斗拉回视野
const LEAD_YIELD_KPH := 10.0        # 领先太远时让出的速度

var track: TrackPath
var spec: Dictionary
var display_name := ""
var number := 0
var car_color := Color.WHITE
var base_speed := 70.0
var variant_id := ""
## 车手风格分化：弯道自信度（决定弯里减速多少）与直线爆发（决定能贴到多快）。
## 同一场里三台 AI 用不同组合，彻底避免「三车等速火车队」。
var corner_conf := 1.0        # <1 弯里更怂，>1 弯里更凶
var top_push := 1.0           # 起步加速与自身能力配速上的放大系数
var lane_pref := 0.0          # 常用车线（-1 内线 .. +1 外线），不同车手走不同线
var aggression := 0.0         # 追近前车时的加力倾向
# 走线/节奏个性：按车号确定性生成，保证同一场里三台 AI 各走各的线、快慢起伏不同。
var corner_line := 0.0        # 弯道走线倾向（-1 一直走外线 .. +1 一直切内线）
var line_phase := 0.0         # 摆动线相位
var wob_amp := 0.0            # 沿途摆动幅度（米）
var wob_freq := 0.008         # 沿途摆动频率（rad/m）
var tempo := 1.0              # 配速微调（每车手不同，制造速度差）
var pace_trim := 0.0          # 相对玩家节奏的固定偏移（m/s），拉开车手快慢
var lag_limit_m := 500.0      # 允许落后玩家多少米；超出就强制回追
var bump_lat := 0.0           # 碰撞弹开的横向冲量（米，随时间衰减）
var bump_timer := 0.0         # 弹开避让剩余时间（秒）
var avoid_dir := 0.0          # 锁存的避让方向，防止每帧左右抖动
var avoid_timer := 0.0        # 避让方向锁存剩余时间（秒）
# ---- 玩家走线回放（AI 路线库）----
# main 从 RecordsStore 抽一条历史走线塞进来，AI 就按玩家真实开过的线跑；
# 每台 AI 再叠一个固定的小偏移/摆动，保证同一条线也不会三车完全重合。
var route_lat := PackedFloat32Array()
var route_spd := PackedFloat32Array()
var route_pace := 0.0         # 回放线的平均速度（m/s），用于缩放记录速度
var route_step := 0.0
var use_route := false
var route_shift := 0.0
var route_id := ""

# ---- 失误层 ---------------------------------------------------------------
# 纯确定性配速的 AI 每圈完全一样，玩家跑两圈就能背下来。这里按车手能力
# 给低概率失误：锁死/刹车过早/走大弯，制造真实超车窗口；高能力车手更少犯错。
# 随机数在 setup 里按车号播种，同一场比赛重开时行为可复现。
var driver_skill := 0.5
var mistake_cd := 8.0
var mistake_timer := 0.0
var mistake_kind := ""
var mistake_side := 1.0
# ---- 进攻层 ---------------------------------------------------------------
# 被玩家超掉后只靠常态差距追得太慢，这里随机开一段「进攻窗口」：窗口内上限
# 放到玩家 +30 km/h，让电脑车真的能追近扑回来；已经领先时不开窗口，防止跑没影。
# 与失误层共用按车号播种的 rng，同一场重开时进攻时机可复现。
var attack_cd := 10.0
var attack_timer := 0.0
var _rng := RandomNumberGenerator.new()

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
# 决策 60Hz、渲染按物理帧插值：记录上一步位姿，main 每帧调 interpolate_visual。
var _interp_from_pos := Vector3.ZERO
var _interp_from_heading := 0.0
var _interp_step := 1.0 / 60.0


func setup(track_path: TrackPath, car_spec: Dictionary, start_dist: float, lateral: float,
		speed_base: float, ai_color: Color, ai_name: String = "", ai_number: int = 0) -> void:
	track = track_path
	spec = car_spec
	variant_id = String(car_spec.get("id", ""))
	display_name = ai_name if not ai_name.is_empty() else String(car_spec.get("name", variant_id))
	number = ai_number if ai_number > 0 else int(car_spec.get("number", 0))
	# base_speed 只作兜底基准：玩家停车或已完赛时的自身能力配速、以及全场上限地板。
	# 巡航快慢改由玩家节奏决定（见 update_ai），ai.json 的 baseSpeed 表示车手能力。
	base_speed = speed_base
	var skill := clampf(speed_base / 76.5, 0.90, 1.08)
	var spec_top := float(car_spec.get("maxSpeed", 0.0))
	if spec_top > 10.0:
		base_speed = spec_top * 0.90 * skill
	# 车手风格分化：按车手能力系数推导，保证快车手贴玩家更紧、慢车手多让一点，
	# 弯里快慢和进攻欲望也各不相同。
	var skill01 := inverse_lerp(0.90, 1.08, skill)
	driver_skill = clampf(skill01, 0.0, 1.0)
	pace_trim = lerpf(-5.0, 5.0, skill01) / KPH
	corner_conf = lerpf(0.86, 1.16, skill01)
	top_push = lerpf(0.94, 1.08, skill01)
	aggression = lerpf(0.25, 0.85, skill01)
	lane_pref = lerpf(-0.5, 0.5, skill01)
	# 走线/节奏个性：由车号确定性生成（重开比赛同一车手风格不变），
	# 和能力系数解耦——快车手也可以偏外线慢漂，慢车手也可以爱切内线。
	_rng.seed = (ai_number if ai_number > 0 else int(car_spec.get("number", 7))) * 7919 + 104729
	lane_pref = lerpf(-0.85, 0.85, _rng.randf())
	corner_line = lerpf(-1.0, 1.0, _rng.randf())
	wob_amp = lerpf(0.5, 1.4, _rng.randf())
	wob_freq = lerpf(0.005, 0.012, _rng.randf())
	line_phase = _rng.randf() * TAU
	tempo = lerpf(0.97, 1.045, _rng.randf())
	mistake_cd = lerpf(7.0, 15.0, driver_skill) + _rng.randf_range(0.0, 5.0)
	mistake_timer = 0.0
	mistake_kind = ""
	attack_cd = _rng.randf_range(5.0, 14.0)
	attack_timer = 0.0
	bump_lat = 0.0
	bump_timer = 0.0
	avoid_dir = 0.0
	avoid_timer = 0.0
	route_shift = lerpf(-0.75, 0.75, _rng.randf())
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
	_interp_from_pos = pos
	_interp_from_heading = heading
	_build_visual(ai_color)
	_sync_visual(0.0)


## 塞入一条玩家历史走线：{"step": 米, "lat": [...], "spd": [...]}。
func set_route(line: Dictionary, id: String = "") -> void:
	route_lat = PackedFloat32Array()
	route_spd = PackedFloat32Array()
	route_pace = 0.0
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
		var spd_sum := 0.0
		for v in route_spd:
			spd_sum += v
		if route_spd.size() > 0:
			route_pace = spd_sum / float(route_spd.size()) / KPH
	route_step = maxf(4.0, float(line.get("step", 0.0)))
	use_route = route_step > 0.1


func has_route() -> bool:
	return use_route and route_lat.size() >= 24


func _build_visual(paint: Color) -> void:
	var result := CarVisual.build(spec, self, paint, true)
	model = result["model"] as Node3D
	for node in result["spin_wheels"]:
		spin_wheels.append(node as Node3D)
	for node in result["steer_wheels"]:
		steer_wheels.append(node as Node3D)
	wheel_radius = float(result["wheel_radius"])
	CarVisual.apply_race_optimizations(model, true)
	apply_quality_shadows()


## 低画质档：AI 车不投实时阴影，改用已有的接触阴影（换档时 main 会再同步一次）。
func apply_quality_shadows() -> void:
	CarVisual.set_shadow_casting(model, Settings.index > 0)


## 夜景赛道：和玩家车用同一套前照灯，电脑车也会照亮自己前方的路。
func add_headlights(energy_scale: float = 1.0) -> void:
	CarVisual.add_headlights(model, spec, energy_scale)


func remove_headlights() -> void:
	CarVisual.remove_headlights(model)


## 失误调度：高能力车手 7~15s 才掷一次骰子且命中率低，慢车手更频繁。
## 只在开赛 8s 后、未完赛时触发，避免发车第一弯就集体打滑。
func _update_mistakes(dt: float) -> void:
	if finished or elapsed < 8.0:
		return
	if mistake_timer > 0.0:
		mistake_timer = maxf(0.0, mistake_timer - dt)
		if mistake_timer <= 0.0:
			mistake_kind = ""
			mistake_cd = lerpf(9.0, 19.0, driver_skill) + _rng.randf_range(0.0, 7.0)
		return
	mistake_cd -= dt
	if mistake_cd > 0.0:
		return
	# 命中率：慢车手 ~22%，快车手 ~6%；未命中 2 秒后再掷。
	var chance := lerpf(0.22, 0.06, driver_skill)
	if _rng.randf() > chance:
		mistake_cd = 2.0
		return
	var roll := _rng.randf()
	if roll < 0.46:
		mistake_kind = "brake"
		mistake_timer = 0.7 + _rng.randf() * 0.8
	elif roll < 0.78:
		mistake_kind = "wide"
		mistake_timer = 1.0 + _rng.randf() * 1.0
		mistake_side = -1.0 if _rng.randf() < 0.5 else 1.0
	else:
		mistake_kind = "twitch"
		mistake_timer = 0.8 + _rng.randf() * 0.6


## 进攻调度：被玩家超掉后随机开一段 5~12 s 的窗口，窗口内放到玩家 +30 km/h，
## 追近、反扑、再回到常态节奏。已经掉出回追带宽时冷却提前到期，保证落后太深
## 的车优先拿到进攻机会；已经领先一大截时不进攻，免得一台车直接跑没影。
func _update_attack(dt: float, gap: float) -> void:
	if finished or elapsed < 6.0:
		return
	if gap < -LEAD_EASE_M:
		attack_timer = 0.0
		return
	if attack_timer > 0.0:
		attack_timer = maxf(attack_timer - dt, 0.0)
		return
	if mistake_timer > 0.0:
		return
	attack_cd -= dt + (1.5 if gap > lag_limit_m else 0.0)
	if attack_cd > 0.0:
		return
	if _rng.randf() > lerpf(0.30, 0.60, driver_skill) + (0.18 if gap < 200.0 else 0.0):
		# 没骰中就 3~7 s 后再掷；靠近玩家时骰子更偏进攻，看得见才值得发力。
		attack_cd = _rng.randf_range(3.0, 7.0)
		return
	attack_timer = _rng.randf_range(5.0, 12.0)
	attack_cd = _rng.randf_range(14.0, 28.0) * (1.0 - 0.35 * driver_skill)


func update_ai(dt: float, player_car: Car, race_laps: int, rivals: Array, pace: float) -> void:
	var prev_pos := pos
	var prev_heading := heading
	elapsed += dt
	var look_meters := 26.0 + speed * 1.9
	var curvature := track.max_curvature_ahead(dist, look_meters, 12.0)

	# 配速主控量是玩家节奏，但常态比玩家快一截（PACE_LEAD_KPH）：电脑先跑出去，
	# 玩家必须主动踩油门去超。领先太多又自动收油回落到玩家节奏以下，始终把
	# 对手留在能超车的距离里；被玩家超掉后靠进攻窗口反扑。
	# 自己那台车的极速只在没有可跟的节奏时兜底，不再决定巡航快慢。
	var own_cruise := base_speed * 0.90 * top_push * tempo
	var gap := player_car.race_dist - race_dist
	var over := maxf(gap - lag_limit_m, 0.0)
	_update_attack(dt, gap)
	# pace≈0 = 发车前或玩家把车停在赛道上；玩家已完赛后按自身能力跑。
	var ref := pace
	var ceiling := ref + PACE_LEAD_KPH / KPH + pace_trim
	if pace <= 5.0 or player_car.player_finished:
		ref = own_cruise
		ceiling = own_cruise
	else:
		var lead := -gap
		if lead > LEAD_EASE_M:
			var ease := clampf(1.0 - (lead - LEAD_EASE_M) / (LEAD_RELEASE_M - LEAD_EASE_M), 0.0, 1.0)
			ceiling = ref + lerpf(-LEAD_YIELD_KPH, PACE_LEAD_KPH, ease) / KPH + pace_trim * ease
		elif gap > 0.0:
			# 玩家刚超过去：先只比玩家快一点贴住，不立刻反超；落后越远追得越狠，
			# 由进攻窗口负责真正反扑，超车成功后的身位能保住一段时间。
			var chase := clampf(gap / 250.0, 0.0, 1.0)
			ceiling = ref + lerpf(PACE_CHASE_KPH, PACE_LEAD_KPH, chase) / KPH + pace_trim
	if attack_timer > 0.0:
		ceiling = ref + ATTACK_KPH / KPH
	# 发车时不能瞬间 200 km/h，但也不能跟着停着的玩家一起钉在原地。
	ceiling = maxf(ceiling, base_speed * 0.45)
	# 弯道减速按车手自信度分化：怂的车手弯里明显更慢，凶的车手几乎不减速。
	# 系数比按车型极速配速时代温和：玩家节奏本身已经含了弯道减速，这里再乘
	# 一次重惩罚会让 AI 全程净慢于玩家（实测 -6%），永远追不上。
	var target := ceiling * clampf(1.0 - curvature * 20.0 * corner_conf, 0.66, 1.0) * tempo
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
	# 发车格在起跑线后方（dist<0），回放线取模会绕到上一圈末尾，起步阶段不用它。
	if has_route() and dist >= 0.0:
		var span := route_step * float(route_lat.size())
		var u := fposmod(dist, span) / route_step
		var i0 := int(floor(u)) % route_lat.size()
		var i1 := (i0 + 1) % route_lat.size()
		var frac := u - floorf(u)
		var recorded := lerpf(route_lat[i0], route_lat[i1], frac) + route_shift
		lane_target = recorded + sin(dist * wob_freq + line_phase) * wob_amp * 0.28
		# 回放线里的速度只描述「哪里该收油」的形状：先按这条线自己的平均速度归一，
		# 再乘到当前节奏上。直接拿绝对值封顶会把整场 AI 钉在一条旧成绩上。
		if route_spd.size() == route_lat.size() and route_pace > 3.0:
			var rec_kph := lerpf(route_spd[i0], route_spd[i1], frac)
			if rec_kph > 20.0:
				var shape := clampf(rec_kph / 3.6 / route_pace, 0.45, 1.0)
				target = minf(target, ref * shape * (1.14 + 0.10 * corner_conf))
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

	# 失误层：在弯前/直道末尾制造一次短暂异常，给玩家真实的超车窗口。
	_update_mistakes(dt)
	if mistake_timer > 0.0:
		match mistake_kind:
			"brake":
				# 刹车过早 / 锁死：明显收油，车尾会轻微摆动
				target *= 0.74
				lane_target += sin(elapsed * 11.0) * 0.22
			"wide":
				# 走大弯：外抛一点，但不出白线
				lane_target += mistake_side * minf(2.2, lane_limit * 0.85)
				target *= 0.96
			"twitch":
				# 被后车挤压后的修正过度：左右小幅摇摆 + 轻收油
				lane_target += sin(elapsed * 8.5) * 0.85
				target *= 0.91

	# 碰撞弹开：被撞后的横向冲量在 0.9s 内线性衰减，期间轻微收油，
	# 让 AI 撞完先弹开减速，再慢慢回到自己的走线（而不是立刻贴回来）。
	if bump_timer > 0.0:
		bump_timer = maxf(bump_timer - dt, 0.0)
		var bump_k := bump_timer / 0.9
		lane_target += bump_lat * bump_k
		target *= 1.0 - 0.10 * bump_k

	lane_target = clampf(lane_target, -lane_limit, lane_limit)
	# 回追带宽是位置硬约束，兜底必须放在所有减速项（弯道、车间距、失误、碰撞）之后：
	# 否则掉出带宽的电脑车会一直被这些系数压住，永远补不回来。超出越多追得越凶
	# （0.5 km/h 每米，封顶再 +25 km/h）。
	if over > 0.0:
		target = maxf(target, ref + (ATTACK_KPH + minf(over * 0.5, CATCH_EXTRA_KPH)) / KPH)
	target_speed = target
	# 起步不能瞬间 200km/h：用有上限的加速度（和玩家车接近），车手差异 ±10%。
	# 加速 taper 的分母跟着目标节奏走，否则玩家快过这台车能力时 AI 永远补不上速度。
	if target > speed:
		var accel_ref := maxf(base_speed, maxf(ref, 1.0))
		var accel_rate := 12.0 * top_push * (1.0 - 0.42 * clampf(speed / accel_ref, 0.0, 1.0))
		speed = minf(speed + accel_rate * dt, target)
	else:
		speed = _damp(speed, target, 2.3, dt)
	dist += speed * dt
	race_dist = dist
	# 横向并线随速度解锁：低速时锁住当前车位，速度起来才允许并向目标线，并限制
	# 最大横向速度。否则发车头一两秒会整体平移滑向目标线，看起来像漂移起步。
	var lat_speed := clampf(speed / 26.0, 0.0, 1.0)
	var lat_gate := clampf((speed - 2.0) / 12.0, 0.0, 1.0)
	var lat_rate := 1.1 * lat_gate + 2.5 * clampf(bump_timer / 0.9, 0.0, 1.0)
	var lat_step := (lane_target - offset) * (1.0 - exp(-lat_rate * dt))
	var lat_cap := (0.5 + 2.0 * lat_speed) * dt
	offset += clampf(lat_step, -lat_cap, lat_cap)

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
	_interp_from_pos = prev_pos
	_interp_from_heading = prev_heading
	_interp_step = maxf(dt, 0.001)
	_sync_visual(dt)


## 物理帧间插值渲染位姿（逻辑 pos/heading 仍是 60Hz 的最新值，碰撞不受影响）。
func interpolate_visual(t: float) -> void:
	var a := clampf(t / _interp_step, 0.0, 1.0)
	position = _interp_from_pos.lerp(pos, a)
	rotation = Vector3(0.0, _interp_from_heading + wrapf(heading - _interp_from_heading, -PI, PI) * a, 0.0)


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
	# 目标速度明显低于当前速度 = 正在收油/刹车（弯前减速、失误锁死都算）。
	var braking := speed > target_speed + 1.2 or (mistake_timer > 0.0 and mistake_kind == "brake")
	CarVisual.set_brake_lights(model, braking)


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
