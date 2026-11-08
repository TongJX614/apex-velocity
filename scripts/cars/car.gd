class_name Car
extends Node3D
## 街机向玩家车物理（Godot 版）。
##
## 性能数据来自 data/cars.json 的真车参数（fuelType/powerHp/torqueNm/weightKg/
## drivetrain/engineProfile/redline/gears/topKph/zeroTo100），加速系数在 setup()
## 里按「自动挡 0-100 = 真车 0-100」离线标定，因此每台车的手感与真车同级。
##
## 传动系统：
##   · 自动挡（默认）：按红区自动升降挡，换挡有动力切断。
##   · 手动挡（T 切换）：6 速（EV 单速），E/Q 或 RB/LB 升降挡；
##     进入黄区提示升档、红区不升档 = 断油 limiter；降档有转速保护；
##     手动模式扭矩 +12% 且换挡切断更短 → 比自动挡更快。
## 氮气：漂移/横向滑移积攒 nitro_charge，按住 nitro 键消耗并增推 + 提升极速上限。
## 声音 / HUD / 手柄震动都直接读取本类的公开字段。

# --- 基础常量 ---------------------------------------------------------------
const RPM_IDLE := 0.112            # 归一化怠速（1.0 = 8000rpm 表底）
const COAST_ROLL := 0.9
const COAST_ENGINE := 1.3
# 手刹只负责「锁后轮」，不是刹车：旧版 7.0 会在漂移中把车硬生生拽停。
const HANDBRAKE_DRAG := 1.15
const OFFROAD_DRAG := 3.0
const REVERSE_MAX := 12.0
# 正常横向抓地（1/s）：7.0×7.0 太高，车像轨道车且松手刹瞬间吸附；
# 3.2 保留清晰的路感与可控滑移，配合动态抓地做漂移。
const GRIP_BITE := 3.2
const DRIVE_EFF := 0.82            # 传动效率：功率段推力 = P·η/(m·v)
const FUEL_CUT_DRAG := 2.6         # 断油时的发动机制动 m/s²

# --- 传动系 -----------------------------------------------------------------
const GEAR_TOPS := [0.16, 0.30, 0.45, 0.61, 0.79, 1.0]  # 各挡红线对应的极速占比
const SHIFT_CUT_AUTO := 0.13
const SHIFT_CUT_MANUAL := 0.055
const AUTO_UPSHIFT := 0.985        # 自动升档上限（红线比例，约 7450rpm）
const AUTO_SHIFT_RPM := 0.625      # 自动挡常规升档点：5000rpm（1.0 = 8000rpm）
const AUTO_DOWNSHIFT := 0.26       # 自动降档阈值（约 2080rpm，留足滞回）
const MANUAL_TORQUE := 1.12        # 手动挡动力增益
const SHIFT_LOCK := 0.11

# --- 氮气 -------------------------------------------------------------------
const NITRO_ACCEL := 1.50          # 氮气推力倍率
const NITRO_CAP := 0.12            # 氮气极速上限提升
const NITRO_START := 0.30
const NITRO_DRIFT_GAIN := 0.19     # 漂移充能速度（满槽/秒）：约 5.3s 连续漂移攒满
const NITRO_IDLE_GAIN := 0.004     # 高速巡航的微弱回充

const WHEELSPIN_PENALTY := {"RWD": 0.22, "FWD": 0.28, "AWD": 0.10}

# --- 漂移 -------------------------------------------------------------------
const DRIFT_HOLD_SPEED := 6.0      # 低于此速度不再保持漂移（自动收油回抓地）
const DRIFT_GRIP := 1.05           # 漂移中的横向抓地（1/s），越小越滑
const DRIFT_ENTER := 9.0           # 进入漂移的抓地衰减速度
const DRIFT_RECOVER := 3.1         # 松手刹后的抓地恢复速度


# --- 状态 -------------------------------------------------------------------
var car_id := ""
var spec: Dictionary = {}
var track: TrackPath

var pos := Vector3.ZERO
var heading := 0.0
var vel := Vector3.ZERO
var steer := 0.0
var throttle := 0.0
var handbrake := false
var speed_forward := 0.0
var speed_kph := 0.0
var gear := 1
var auto_gear := 1
var rpm := RPM_IDLE
var offroad := false
var track_index := 0
var progress_dist := 0.0
var wheel_spin := 0.0
var shift_cut := 0.0
var wheelspin := 0.0
var lat_slip := 0.0

var max_speed := 60.0
var accel_power := 10.0
var brake_power := 30.0
var grip_power := 7.0
var drive_drag := 0.12
var _power_ref := 20.0             # 功率段起点（m/s）：v 超过后推力按 P/(m·v) 衰减
var _aero_drag := 0.0004           # 标定风阻（m/s² 每 (m/s)²）：全油门平衡点 ≈ max_speed

# --- 真车参数 / 传动 --------------------------------------------------------
var fuel_type := "ice"             # ev / ice / hybrid
var engine_profile := "i6"
var aspiration := "na"
var drivetrain := "RWD"
var redline := 0.94                # 归一化红线（0.92~1.0）
var gear_count := 6
var real_zero_to_100 := 5.0
var weight_kg := 1500.0
var power_hp := 300.0
var torque_nm := 400.0

# --- 手动挡 / 换挡提示 ------------------------------------------------------
static var _pref_manual := false
var manual := false
var shift_hint := ""               # "" / "UP" / "REDLINE" / "DOWN" / "DENY" / "MAX"
var shift_hint_timer := 0.0
var shift_flash := 0.0
var limiter_active := false
var shift_lock := 0.0
var launch := false
var braking := false

# --- 护栏接触 / 车身姿态 -----------------------------------------------------
var wall_contact := false
var wall_impact := 0.0             # 本帧撞墙的法向速度（m/s），供 main 触发反馈
var wall_side := 0.0               # 撞的是哪一侧（±1）
var wall_hit_point := Vector3.ZERO

# --- 漂移连击评分 -----------------------------------------------------------
var drift_chain_score := 0.0       # 本次连击累计分
var drift_combo := 1               # 连击倍率 ×1..×8
var drift_chain_time := 0.0
var drift_grace := 0.0             # 漂移中断宽限，宽限内续漂保连击
var drift_bank := 0                # 本场已入账总分
var drift_max_combo := 1
var drift_lost_timer := 0.0
var drift_bank_flash := 0.0
var drift_bank_last := 0

var prev_speed_fwd := 0.0
var accel_vis := 0.0
var pitch_vis := 0.0
var roll_vis := 0.0
var bob_vis := 0.0

# --- 氮气 -------------------------------------------------------------------
var nitro_charge := NITRO_START
var nitro_capacity := 3.7
var nitro_active := false
var nitro_gaining := false
var drift_active := false
# 漂移状态：0 = 满抓地，1 = 完全滑移；进出都平滑过渡，松手刹不会瞬间吸附。
var drift_grip := 0.0
var drift_timer := 0.0
var drift_angle := 0.0

var model: Node3D
var model_base_pos := Vector3.ZERO
var spin_wheels: Array[Node3D] = []
var steer_wheels: Array[Node3D] = []
var wheel_radius := 0.34
var wheel_nodes_found := 0
var race_dist := 0.0
var lap := 0
var player_finished := false
var finish_time := -1.0
var paint_color := Color.TRANSPARENT
var cockpit_offset := Vector3(0.0, 1.05, -0.1)

# --- 开放世界（自由漫游）----------------------------------------------------
var free_roam := false              # 开放世界模式：没有赛道护栏，靠地形高度场支撑
var world: Node = null              # OpenWorld 实例（鸭子类型，不强依赖具体类）
var world_surface := "road"         # 当前脚下材质：road/sand/grass/rock/snow/ice/lava/water
var world_normal := Vector3.UP      # 地面法线
var world_grade := 0.0              # 沿车头方向的坡度（正 = 上坡）
var world_depth := 0.0              # 水深 / 熔岩深度
var world_zone := ""               # 当前所在区域 id

# --- 城市实景（都会环线）-----------------------------------------------------
## 城市模式：赛道只用来计时和 AI，不再有走廊护栏；车被建筑碰撞场约束，
## 所有街道都能开。city 为 CityWorld（鸭子类型）。
var city: Node = null
## 离开主环后全局重寻最近点的节流计时。
var _city_seek_cd := 0.0


func setup(car_spec: Dictionary, track_path: TrackPath, start_dist: float = 10.0, lateral: float = 0.0, paint: Color = Color.TRANSPARENT, look_config: Dictionary = {}) -> void:
	spec = car_spec
	car_id = String(spec.get("id", ""))
	track = track_path
	free_roam = false
	world = null
	city = null
	max_speed = float(spec.get("maxSpeed", 60.0))
	brake_power = float(spec.get("brake", 30.0))
	grip_power = float(spec.get("grip", 7.0))
	drive_drag = float(spec.get("driveDrag", 0.12))
	fuel_type = String(spec.get("fuelType", "ice")).to_lower()
	engine_profile = String(spec.get("engineProfile", "i6")).to_lower()
	aspiration = String(spec.get("aspiration", "na")).to_lower()
	drivetrain = String(spec.get("drivetrain", "RWD")).to_upper()
	redline = clampf(float(spec.get("redline", 0.94)), 0.80, 1.0)
	gear_count = clampi(int(spec.get("gears", 6)), 1, 6)
	real_zero_to_100 = float(spec.get("realZeroTo100", spec.get("zeroTo100", 5.0)))
	weight_kg = float(spec.get("weightKg", 1500.0))
	power_hp = float(spec.get("powerHp", 300.0))
	torque_nm = float(spec.get("torqueNm", 400.0))
	if fuel_type == "ev":
		gear_count = 1
	nitro_capacity = maxf(1.2, float(spec.get("nitroTime", 3.7)))
	nitro_charge = NITRO_START
	var tune: Dictionary = spec.get("tune", {})
	var engine_level := clampi(int(tune.get("engine", 0)), 0, 10)
	var gearbox_level := clampi(int(tune.get("gearbox", 0)), 0, 10)
	var weight_level := clampi(int(tune.get("weight", 0)), 0, 10)
	# 0-100 标定：解出推力系数，使自动挡模型跑出的 0-100 与真车一致
	var base_power := _calibrate_accel(real_zero_to_100)
	accel_power = base_power * (1.0 + float(engine_level) * 0.0375 \
		+ float(gearbox_level) * 0.018 + float(weight_level) * 0.012)
	_recompute_drive_model(base_power)
	paint_color = paint
	cockpit_offset = CarVisual.cockpit_offset_for(car_id)
	_load_visual()
	if not look_config.is_empty() and model != null:
		GarageLook.apply(model, car_id, look_config)
	reset(start_dist, lateral)


## 开放世界初始化：没有赛道，改由高度场提供地面高度与地表材质。
func setup_open_world(car_spec: Dictionary, world_node: Node, spawn: Dictionary,
		paint: Color = Color.TRANSPARENT, look_config: Dictionary = {}) -> void:
	spec = car_spec
	car_id = String(spec.get("id", ""))
	track = null
	free_roam = true
	world = world_node
	city = null
	max_speed = float(spec.get("maxSpeed", 60.0))
	brake_power = float(spec.get("brake", 30.0))
	grip_power = float(spec.get("grip", 7.0))
	drive_drag = float(spec.get("driveDrag", 0.12))
	fuel_type = String(spec.get("fuelType", "ice")).to_lower()
	engine_profile = String(spec.get("engineProfile", "i6")).to_lower()
	aspiration = String(spec.get("aspiration", "na")).to_lower()
	drivetrain = String(spec.get("drivetrain", "RWD")).to_upper()
	redline = clampf(float(spec.get("redline", 0.94)), 0.80, 1.0)
	gear_count = clampi(int(spec.get("gears", 6)), 1, 6)
	real_zero_to_100 = float(spec.get("realZeroTo100", spec.get("zeroTo100", 5.0)))
	weight_kg = float(spec.get("weightKg", 1500.0))
	power_hp = float(spec.get("powerHp", 300.0))
	torque_nm = float(spec.get("torqueNm", 400.0))
	if fuel_type == "ev":
		gear_count = 1
	nitro_capacity = maxf(1.2, float(spec.get("nitroTime", 3.7)))
	nitro_charge = NITRO_START
	var tune: Dictionary = spec.get("tune", {})
	var engine_level := clampi(int(tune.get("engine", 0)), 0, 10)
	var gearbox_level := clampi(int(tune.get("gearbox", 0)), 0, 10)
	var weight_level := clampi(int(tune.get("weight", 0)), 0, 10)
	var base_power := _calibrate_accel(real_zero_to_100)
	accel_power = base_power * (1.0 + float(engine_level) * 0.0375 \
		+ float(gearbox_level) * 0.018 + float(weight_level) * 0.012)
	_recompute_drive_model(base_power)
	paint_color = paint
	cockpit_offset = CarVisual.cockpit_offset_for(car_id)
	_load_visual()
	if not look_config.is_empty() and model != null:
		GarageLook.apply(model, car_id, look_config)
	# 复位到出生点
	var sp: Vector3 = spawn.get("pos", Vector3.ZERO)
	pos = sp
	heading = float(spawn.get("heading", 0.0))
	vel = Vector3.ZERO
	steer = 0.0
	throttle = 0.0
	speed_forward = 0.0
	speed_kph = 0.0
	gear = 1
	auto_gear = 1
	shift_cut = 0.0
	wheelspin = 0.0
	lat_slip = 0.0
	rpm = RPM_IDLE
	offroad = false
	manual = _pref_manual
	shift_hint = ""
	shift_hint_timer = 0.0
	shift_flash = 0.0
	limiter_active = false
	_sync_visual(1.0 / 60.0)


func _load_visual() -> void:
	var paint := Color.TRANSPARENT
	if paint_color.a > 0.001:
		paint = paint_color
	var result := CarVisual.build(spec, self, paint)
	model = result["model"] as Node3D
	if model != null:
		model_base_pos = model.position
	spin_wheels = []
	for node in result["spin_wheels"]:
		spin_wheels.append(node as Node3D)
	steer_wheels = []
	for node in result["steer_wheels"]:
		steer_wheels.append(node as Node3D)
	wheel_radius = float(result["wheel_radius"])
	wheel_nodes_found = int(result["wheels_found"])


func reset(start_dist: float = 10.0, lateral: float = 0.0) -> void:
	var f := track.frame_at(start_dist)
	if f.is_empty():
		return
	pos = (f["pos"] as Vector3) + (f["side"] as Vector3) * lateral
	heading = atan2((f["tangent"] as Vector3).x, (f["tangent"] as Vector3).z)
	vel = Vector3.ZERO
	steer = 0.0
	throttle = 0.0
	speed_forward = 0.0
	speed_kph = 0.0
	gear = 1
	auto_gear = 1
	shift_cut = 0.0
	wheelspin = 0.0
	lat_slip = 0.0
	rpm = RPM_IDLE
	offroad = false
	manual = _pref_manual
	shift_hint = ""
	shift_hint_timer = 0.0
	shift_flash = 0.0
	limiter_active = false
	shift_lock = 0.0
	nitro_charge = NITRO_START
	nitro_active = false
	nitro_gaining = false
	drift_active = false
	drift_grip = 0.0
	drift_timer = 0.0
	drift_angle = 0.0
	braking = false
	launch = false
	wall_contact = false
	wall_impact = 0.0
	wall_side = 0.0
	wall_hit_point = Vector3.ZERO
	drift_chain_score = 0.0
	drift_combo = 1
	drift_chain_time = 0.0
	drift_grace = 0.0
	drift_bank = 0
	drift_max_combo = 1
	drift_lost_timer = 0.0
	drift_bank_flash = 0.0
	drift_bank_last = 0
	prev_speed_fwd = 0.0
	accel_vis = 0.0
	pitch_vis = 0.0
	roll_vis = 0.0
	bob_vis = 0.0
	progress_dist = start_dist
	race_dist = start_dist
	lap = 0
	player_finished = false
	finish_time = -1.0
	track_index = int(f.get("index", 0))
	_city_seek_cd = 0.0
	_sync_visual(0.0)


func add_headlights(color: Color = Color(1.0, 0.94, 0.82), energy: float = 7.0) -> void:
	if model == null:
		return
	if model.find_child("Headlight_R", true, false) != null:
		return
	var cars_doc: Dictionary = GameData.car_manifest.get("cars", {})
	var entry: Dictionary = cars_doc.get(car_id, {})
	var lights: Dictionary = entry.get("lights", {})
	var head: Array = lights.get("headlight", [0.0, 0.6, 2.1])
	var target: Array = lights.get("target", [0.0, -0.2, 38.0])
	var head_pos := Vector3(float(head[0]), float(head[1]), float(head[2]))
	var target_pos := Vector3(float(target[0]), float(target[1]), float(target[2]))
	for sign_v: float in [-1.0, 1.0]:
		var spot := SpotLight3D.new()
		spot.name = "Headlight_" + ("R" if sign_v > 0.0 else "L")
		var offset := Vector3(0.62 * sign_v, 0.02, 0.0)
		var from := head_pos + offset
		var direction := target_pos - from
		spot.transform = Transform3D(Basis.looking_at(direction, Vector3.UP), from)
		# 光斑收敛：射程 75m/60° 锥角会把两侧楼面整片打白（夜景「白楼」根因）
		spot.spot_range = 42.0
		spot.spot_angle = 14.0
		spot.light_energy = energy
		spot.light_color = color
		spot.shadow_enabled = false
		model.add_child(spot)


## 关闭车灯（开放世界里从夜景域开进白天域时用）。
func remove_headlights() -> void:
	if model == null:
		return
	for n in ["Headlight_R", "Headlight_L"]:
		var node := model.find_child(n, true, false)
		if node != null:
			node.queue_free()


func forward() -> Vector3:
	return Vector3(sin(heading), 0.0, cos(heading))


func right() -> Vector3:
	return Vector3(-cos(heading), 0.0, sin(heading))


func update_car(dt: float, input: Dictionary) -> void:
	var steer_in := clampf(float(input.get("steer", 0.0)), -1.0, 1.0)
	var throttle_in := clampf(float(input.get("throttle", 0.0)), -1.0, 1.0)
	var hb := bool(input.get("handbrake", false))
	var nitro_in := bool(input.get("nitro", false))
	if bool(input.get("manual_toggle", false)):
		_toggle_manual()
	handbrake = hb
	throttle = throttle_in
	steer = _damp(steer, steer_in, 10.0, dt)
	shift_cut = maxf(0.0, shift_cut - dt)
	shift_flash = maxf(0.0, shift_flash - dt)
	shift_hint_timer = maxf(0.0, shift_hint_timer - dt)

	var fwd := forward()
	var side := right()
	var v_f := vel.dot(fwd)
	var v_l := vel.dot(side)
	var speed_abs := absf(v_f)

	# 倒车：刹车键按住且车不再明显前冲就进倒挡。旧版 0.6 m/s 的门槛
	# 会在倒车刚动起来的下一帧断力，表现就是「几乎挂不上 R」。
	var reversing := throttle_in < -0.01 and v_f <= 0.3
	braking = throttle_in < -0.01 and not reversing
	launch = throttle_in > 0.5 and speed_abs < 12.0

	_update_drift_state(dt, speed_abs, hb)
	_update_gearbox(dt, input, speed_abs, reversing)
	_update_nitro(dt, nitro_in, throttle_in, speed_abs)
	# 断油（limiter）：手动挡红区不升档 / 顶挡超转时切断动力并发动机制动
	#
	# 触发阈值是 redline × 0.998，不是 × 1.002。
	#
	# 为什么必须落在红线以内：顶挡的极速占比 GEAR_TOPS 末位 = 1.0，也就是
	# "车跑到极速时正好是红线"，而车速被 _speed_cap() 硬钳在 max_speed，
	# 所以 rpm > redline × 1.002 在自动挡下**永远不成立**——默认是自动挡，
	# 于是断油声一次都听不到（用户明确要求"断油之后是什么声音"）。
	# 真实的断油限速器就是在红线处切断点火，所以阈值必须 ≤ 红线。
	# 0.998 与升挡阈值 0.985 之间留出的滞回带，让车在极速附近"顶着限速器弹跳"，
	# 这正是真车的听感：断油顿挫声一下一下地响。
	var fuel_cut := false
	if limiter_active and rpm < redline * 0.985:
		limiter_active = false
	if limiter_active:
		fuel_cut = true
	elif not nitro_active and not reversing and throttle_in > 0.02 and rpm > redline * 0.998:
		limiter_active = true
		fuel_cut = true
	_update_shift_hint(dt, speed_abs)

	var accel := 0.0
	var power := accel_power * (MANUAL_TORQUE if manual else 1.0)
	if nitro_active:
		power *= NITRO_ACCEL
	if reversing:
		var rev_ratio := clampf(-v_f / REVERSE_MAX, 0.0, 1.0)
		accel = -power * 0.42 * (1.0 - rev_ratio * rev_ratio * 0.85)
		if hb:
			accel *= 0.7
	elif throttle_in > 0.01:
		var torque := _torque_curve(rpm)
		# 两段物理曲线：
		#   · 低速（v < _power_ref）：按标定推力恒加速（牵引力限制段）；
		#   · 高速：推力 = P·η/(m·v)，随速度双曲线衰减 —— 速度越高加速越慢，
		#     100-200 明显慢于 0-100，符合真车「功率封顶」的特性。
		var power_factor := minf(1.0, _power_ref / maxf(v_f, _power_ref))
		accel = power * throttle_in * torque * power_factor
		if shift_cut > 0.0:
			accel *= 0.18
		# 起步牵引力上限：低速大油门会打滑（四驱损失最小）
		var spin_target := 1.0 if (speed_abs < 10.0 and throttle_in > 0.65) else 0.0
		wheelspin = lerpf(wheelspin, spin_target, 1.0 - exp(-8.0 * dt))
		accel *= 1.0 - wheelspin * _wheelspin_penalty()
		if hb:
			# 漂移中保留大部分动力：旧版 ×0.3 叠加手刹阻力会把车拽停，
			# 玩家看到的就是「漂到一半莫名其妙停住」。
			accel *= 0.45 + 0.27 * drift_grip
		# 风阻 + 滚阻给油时同样生效：功率段推力靠它和极速达到平衡，
		# 否则平衡点会远超 max_speed（一直顶到硬钳制才停）。
		accel -= COAST_ROLL + _aero_drag * speed_abs * speed_abs
		if fuel_cut:
			accel *= 0.04

	# Steering authority: 低速转向灵活，高速明显变「重」
	var spd_norm := clampf(speed_abs / 14.0, 0.0, 1.0)
	var speed01 := clampf(speed_abs / maxf(max_speed, 1.0), 0.0, 1.0)
	var steer_authority := 1.12 - 0.72 * pow(speed01, 0.85)
	# 倒车时偏航方向相反（和真车一样），否则按「左」车头会往反方向甩。
	var yaw_dir := -1.0 if v_f < -0.3 else 1.0
	var yaw_rate := steer * 2.35 * spd_norm * steer_authority * (1.0 + 0.32 * drift_grip) * yaw_dir
	# 滑移角过大时收一点偏航，避免一直甩到原地打转。
	if drift_angle > 0.85:
		yaw_rate *= lerpf(1.0, 0.55, clampf((drift_angle - 0.85) / 0.5, 0.0, 1.0))
	heading -= yaw_rate * dt

	fwd = forward()
	side = right()
	var new_vf := vel.dot(fwd) + accel * dt
	var new_vl := vel.dot(side)
	lat_slip = absf(new_vl)
	if braking:
		new_vf = _toward_zero(new_vf, brake_power * absf(throttle_in) * dt)
	if fuel_cut:
		new_vf = _toward_zero(new_vf, (FUEL_CUT_DRAG + speed_abs * 0.015) * dt)

	# 横向抓地：正常过弯快速咬地；漂移时抓地平滑降到 DRIFT_GRIP，
	# 松手刹后再平滑恢复（不再像旧版那样从 1.05 瞬间跳回 49 = 吸附）。
	var grip_normal := grip_power * GRIP_BITE * (0.58 if offroad else 1.0)
	var grip := lerpf(grip_normal, DRIFT_GRIP, drift_grip)
	var lateral_before := new_vl
	new_vl *= exp(-grip * dt)
	# 漂移回收：被轮胎重新咬住的横向动量有一部分转回前进方向，
	# 让出弯保持速度，而不是「横向速度凭空蒸发 → 车像被钉在地上」。
	if drift_grip > 0.05 and absf(new_vf) > 2.0:
		var reclaimed := absf(lateral_before - new_vl) * 0.42
		new_vf += reclaimed * signf(new_vf)

	var speed_now := absf(new_vf)
	var base_drag := COAST_ROLL + _aero_drag * speed_now * speed_now
	if hb:
		new_vf = _toward_zero(new_vf, (base_drag + HANDBRAKE_DRAG + drift_grip * 0.5) * dt)
	elif throttle_in <= 0.01:
		if throttle_in < -0.01 and not braking:
			new_vf = _toward_zero(new_vf, base_drag * dt)
		elif not braking:
			new_vf = _toward_zero(new_vf, (base_drag + COAST_ENGINE) * dt)
	if offroad:
		new_vf = _toward_zero(new_vf, OFFROAD_DRAG * dt)
	var speed_cap := _speed_cap()
	if reversing:
		new_vf = clampf(new_vf, -REVERSE_MAX, speed_cap)
	else:
		new_vf = maxf(new_vf, -14.0)
		# 氮气结束后极速上限回落：平滑泄速，避免瞬间掉速顿挫
		if new_vf > speed_cap:
			new_vf = maxf(speed_cap, new_vf - 5.5 * dt)

	vel = fwd * new_vf + side * new_vl
	# 抓地恢复阶段：车头轻轻回正到实际行进方向，漂移有明确的「收束感」。
	if drift_grip < 0.75 and speed_abs > 3.0:
		var travel_h := atan2(vel.x, vel.z)
		var align := wrapf(travel_h - heading, -PI, PI)
		if absf(align) < 1.2:
			heading += align * clampf((1.0 - drift_grip) * 2.4 * dt, 0.0, 0.32)
	pos += vel * dt
	speed_forward = new_vf
	speed_kph = absf(new_vf) * 3.6

	if free_roam:
		_update_open_world_contact(dt)
		# 静态实体碰撞必须在位置积分之后做：先把车推出墙 / 楼 / 树，
		# 再让这一帧的速度生效，否则高速时一步就能跨过一面墙。
		_resolve_static_collisions()
	elif city != null:
		_update_city_contact(dt)
		_resolve_static_collisions()
	else:
		_update_track_contact(dt)
	_update_drift_score(dt)
	_update_rpm(dt)
	_sync_visual(dt)


# --- 手动 / 自动变速箱 -------------------------------------------------------

func _toggle_manual() -> void:
	if gear_count <= 1:
		return
	manual = not manual
	_pref_manual = manual
	shift_cut = 0.05
	shift_lock = 0.08
	shift_flash = 0.15
	shift_hint = "MANUAL" if manual else "AUTO"
	shift_hint_timer = 1.0


func _update_gearbox(dt: float, input: Dictionary, speed_abs: float, reversing: bool) -> void:
	shift_lock = maxf(0.0, shift_lock - dt)
	if reversing:
		gear = 1
		auto_gear = 1
		return
	if gear_count <= 1:
		gear = 1
		auto_gear = 1
		return
	if manual:
		if shift_lock <= 0.0 and bool(input.get("shift_up", false)):
			if gear < gear_count:
				gear += 1
				shift_cut = SHIFT_CUT_MANUAL
				shift_lock = SHIFT_LOCK
				shift_flash = 0.2
			else:
				shift_hint = "MAX"
				shift_hint_timer = 0.5
		elif shift_lock <= 0.0 and bool(input.get("shift_down", false)):
			if gear > 1:
				var rpm_new := _rpm_for_gear(speed_abs, gear - 1)
				if rpm_new <= redline * 1.005:
					gear -= 1
					shift_cut = SHIFT_CUT_MANUAL * 0.8
					shift_lock = SHIFT_LOCK
					shift_flash = 0.16
				else:
					shift_hint = "DENY"
					shift_hint_timer = 0.55
		auto_gear = gear
		return
	# ---- 自动挡 ----
	# 常规升档点 5000rpm（AUTO_SHIFT_RPM）；红线特别高的车也不会超过 5000。
	var up_at := minf(redline * AUTO_UPSHIFT, AUTO_SHIFT_RPM)
	if shift_lock <= 0.0 and rpm >= up_at and gear < gear_count:
		gear += 1
		shift_cut = SHIFT_CUT_AUTO
		shift_lock = SHIFT_LOCK
		shift_flash = 0.14
	elif shift_lock <= 0.0 and gear > 1 and rpm < AUTO_DOWNSHIFT:
		var rpm_new := _rpm_for_gear(speed_abs, gear - 1)
		if rpm_new <= minf(redline * 0.92, 0.62):
			gear -= 1
			shift_cut = SHIFT_CUT_AUTO * 0.85
			shift_lock = SHIFT_LOCK
			shift_flash = 0.12
	auto_gear = gear


func _update_shift_hint(_dt: float, speed_abs: float) -> void:
	if gear_count <= 1:
		shift_hint = ""
		return
	if shift_hint_timer > 0.0 and (shift_hint == "DENY" or shift_hint == "MAX" \
			or shift_hint == "MANUAL" or shift_hint == "AUTO"):
		return
	if manual:
		if rpm > redline * 0.99:
			shift_hint = "REDLINE"
		elif rpm >= redline * 0.90:
			shift_hint = "UP"
		elif gear == gear_count and rpm >= redline * 0.965:
			shift_hint = "MAX"
		elif gear > 1 and rpm < 0.30 and speed_abs > 3.0:
			shift_hint = "DOWN"
		else:
			shift_hint = ""
	else:
		shift_hint = ""


func _rpm_for_gear(speed_abs: float, use_gear: int) -> float:
	var span := redline - RPM_IDLE
	if gear_count <= 1:
		var ratio := speed_abs / maxf(max_speed, 1.0)
		return clampf(RPM_IDLE + ratio * span, 0.0, 1.15)
	var g := clampi(use_gear, 1, gear_count)
	var top := float(GEAR_TOPS[g - 1]) * max_speed
	var ratio2 := speed_abs / maxf(top, 0.5)
	return clampf(RPM_IDLE + ratio2 * span, 0.0, 1.15)


func _update_rpm(dt: float) -> void:
	var target := _rpm_for_gear(absf(speed_forward), gear)
	if speed_forward < -0.5:
		target = RPM_IDLE + clampf(absf(speed_forward) / REVERSE_MAX, 0.0, 1.0) * 0.22
	var lambda := 18.0 if limiter_active else 12.0
	rpm = _damp(rpm, target, lambda, dt)


# --- 扭矩曲线 / 加速标定 -----------------------------------------------------

func _torque_curve(rpm_n: float) -> float:
	var r := clampf(rpm_n, 0.0, 1.12)
	match engine_profile:
		"ev":
			# 电机全程恒扭矩；恒功率特性由功率段的 1/v 衰减统一提供，
			# 这里再衰减一次会双重计费。
			return 1.0
		"v8":
			return clampf(1.30 - 1.55 * pow(r - 0.52, 2.0), 0.66, 1.32)
		"v10", "v12":
			return clampf(1.22 - 1.28 * pow(r - 0.62, 2.0), 0.62, 1.26)
		"i6":
			return clampf(1.28 - 1.95 * pow(r - 0.56, 2.0), 0.58, 1.30)
		"i5":
			return clampf(1.24 - 1.8 * pow(r - 0.54, 2.0), 0.56, 1.26)
		"i4":
			if r < 0.28:
				return 0.72 + 1.7 * r
			return clampf(1.25 - 2.0 * pow(r - 0.55, 2.0), 0.52, 1.27)
		"i3":
			if r < 0.30:
				return 0.66 + 1.5 * r
			return clampf(1.15 - 1.7 * pow(r - 0.58, 2.0), 0.48, 1.18)
		"flat6":
			return clampf(1.25 - 1.55 * pow(r - 0.60, 2.0), 0.60, 1.28)
		"flat4":
			return clampf(1.23 - 1.75 * pow(r - 0.55, 2.0), 0.55, 1.26)
		"rotary":
			return clampf(0.84 + 0.72 * r - 0.52 * r * r, 0.62, 1.14)
		_:
			return clampf(1.25 - 1.9 * pow(r - 0.55, 2.0), 0.55, 1.28)


func _wheelspin_penalty() -> float:
	var base := float(WHEELSPIN_PENALTY.get(drivetrain, 0.22))
	if fuel_type == "ev":
		base *= 0.65
	# 按扭矩/车重比分化学车：大扭矩轻车（性能车/超跑）起步更容易打滑，
	# 小扭矩重车（家用车/SUV）几乎不打滑。0-100 标定仍然生效，所以
	# 分化只改变「起步性格」，不改变整体加速成绩。
	var torque_load := (torque_nm * 9.55) / maxf(weight_kg, 800.0)
	base *= clampf(0.72 + torque_load * 0.10, 0.72, 1.42)
	return base


func _speed_cap() -> float:
	if nitro_active:
		return max_speed * (1.0 + NITRO_CAP)
	return max_speed


## 离线标定：二分求解推力系数，使自动挡模型 0-100 等于目标时间。
func _calibrate_accel(target_time: float) -> float:
	if target_time <= 0.1:
		return 10.0
	var lo := 1.2
	var hi := 42.0
	for i in 24:
		var mid := (lo + hi) * 0.5
		if _model_zero_to_100(mid) > target_time:
			lo = mid
		else:
			hi = mid
	return (lo + hi) * 0.5


## 由真车功率反推两个物理量（base_accel = 未吃升级系数的标定推力）：
##   · _aero_drag：计入顶挡红线扭矩后，全油门平衡点（推力 = 滚阻 + 风阻）
##     正好落在 max_speed，极速不再依赖硬钳制；
##   · _power_ref：标定推力 × ref = P·η/m。v 超过后进入功率限制段，
##     推力 = accel_power·ref/v —— 升级 / 手动挡 / 氮气按比例放大真车功率。
func _recompute_drive_model(base_accel: float) -> void:
	var p_eff := power_hp * 735.5 * DRIVE_EFF
	var m := maxf(weight_kg, 800.0)
	var vmax := maxf(max_speed, 30.0)
	var torque_top := _torque_curve(redline)
	_aero_drag = maxf((torque_top * p_eff / (m * vmax) - COAST_ROLL) / (vmax * vmax), 0.00004)
	_power_ref = clampf(p_eff / (m * maxf(base_accel, 0.5)), 10.0, 45.0)


## 标定模型：与 update() 的驱动公式逐步对应。
## start_v / target_v 可选，用于验证 100-200 / 200-300 等区段。
func _model_zero_to_100(power: float, start_v: float = 0.0, target_v: float = 100.0 / 3.6) -> float:
	var dt := 1.0 / 240.0
	var v := start_v
	var g := gear_count
	for gi in range(gear_count):
		if v <= float(GEAR_TOPS[gi]) * max_speed:
			g = gi + 1
			break
	var cut := 0.0
	var ws := 0.0
	var t := 0.0
	var penalty := _wheelspin_penalty()
	var p_eff := power_hp * 735.5 * DRIVE_EFF
	var m := maxf(weight_kg, 800.0)
	var vmax := maxf(max_speed, 30.0)
	var aero := maxf((_torque_curve(redline) * p_eff / (m * vmax) - COAST_ROLL) / (vmax * vmax), 0.00004)
	var ref := clampf(p_eff / (m * maxf(power, 0.5)), 10.0, 45.0)
	while v < target_v and t < 30.0:
		var torque := _torque_curve(_rpm_for_gear(v, g))
		var acc := power * torque * minf(1.0, ref / maxf(v, ref))
		acc -= COAST_ROLL + aero * v * v
		if v < 10.0:
			ws = lerpf(ws, 1.0, 1.0 - exp(-8.0 * dt))
			acc *= 1.0 - ws * penalty
		if cut > 0.0:
			acc *= 0.18
		v += acc * dt
		if g < gear_count and cut <= 0.0 and _rpm_for_gear(v, g) >= minf(redline * AUTO_UPSHIFT, AUTO_SHIFT_RPM):
			g += 1
			cut = SHIFT_CUT_AUTO
		cut = maxf(0.0, cut - dt)
		t += dt
	return t


# --- 氮气 -------------------------------------------------------------------

## 漂移状态机：手刹/大转向 + 已经有横向滑移才进入；
## 进入和退出都用 drift_grip 平滑过渡，低速时自动收漂。
func _update_drift_state(dt: float, speed_abs: float, hb: bool) -> void:
	var slip_speed := absf(vel.dot(right()))
	var sliding := slip_speed > 3.4 and absf(steer) > 0.25
	var want := speed_abs > DRIFT_HOLD_SPEED and ((hb and absf(steer) > 0.10) or sliding)
	if want:
		drift_grip = minf(1.0, drift_grip + dt * (DRIFT_ENTER if hb else DRIFT_ENTER * 0.55))
		drift_timer += dt
	else:
		drift_grip = maxf(0.0, drift_grip - dt * DRIFT_RECOVER)
		if drift_grip <= 0.001:
			drift_timer = 0.0
	drift_angle = atan2(slip_speed, maxf(speed_abs, 1.0))
	drift_active = drift_grip > 0.2 and speed_abs > DRIFT_HOLD_SPEED


func _update_nitro(dt: float, nitro_in: bool, throttle_in: float, speed_abs: float) -> void:
	# 漂移充能：横向滑移 + 手刹/大转向 + 速度
	var gain := 0.0
	if drift_active:
		var slip01 := clampf((absf(lat_slip) - 1.8) / 5.0, 0.0, 1.0)
		var spd01 := clampf(speed_abs / 22.0, 0.25, 1.0)
		gain = NITRO_DRIFT_GAIN * (0.35 + 0.65 * slip01) * spd01
	else:
		gain = NITRO_IDLE_GAIN * clampf(speed_abs / 60.0, 0.0, 1.0)
	nitro_charge = clampf(nitro_charge + gain * dt, 0.0, 1.0)
	nitro_gaining = gain > 0.02

	var want := nitro_in and nitro_charge > 0.004 and throttle_in > 0.05 and not handbrake
	nitro_active = want
	if nitro_active:
		nitro_charge = maxf(nitro_charge - dt / maxf(nitro_capacity, 0.5), 0.0)


# --- 赛道接触 ---------------------------------------------------------------

func _update_track_contact(dt: float) -> void:
	wall_impact = 0.0
	var info := track.nearest(pos, track_index)
	if info.is_empty():
		wall_contact = false
		return
	track_index = int(info.get("index", track_index))
	progress_dist = float(info.get("dist", progress_dist))
	var lateral := float(info.get("lateral", 0.0))
	var side: Vector3 = info.get("side", Vector3.RIGHT)
	var tangent: Vector3 = info.get("tangent", Vector3.FORWARD)
	var hw := float(info.get("half_width", track.half_width))
	# 白线外即路肩：路缘石上有轻微抓地损失
	offroad = absf(lateral) > hw + track.offroad_margin

	var wall := hw + track.wall_margin
	if absf(lateral) <= wall:
		wall_contact = false
		speed_forward = vel.dot(forward())
		speed_kph = absf(speed_forward) * 3.6
		return

	# ---- 护栏接触：和车车碰撞同一套手感 ----
	# 旧版只有很小的持续刮擦，车会贴着护栏滑出去很远。现在：
	#   1) 法向速度立即吸收（3% 回弹）
	#   2) 撞击瞬间按入射角扣掉一口气的切向速度（正撞几乎钉住，斜擦保留滚动）
	#   3) 持续贴墙再叠加角度相关的刮擦阻力
	wall_contact = true
	var sgn := signf(lateral)
	if sgn == 0.0:
		sgn = 1.0
	wall_side = sgn
	pos += side * (sgn * wall - lateral)
	wall_hit_point = pos + side * (sgn * 0.85) + Vector3(0.0, 0.55, 0.0)
	var fwd := forward()
	var v_side := vel.dot(side)
	var into := v_side * sgn
	var outward := fwd.dot(side) * sgn
	if into > 0.0:
		wall_impact = into
		vel -= side * v_side * 1.03
		var tan_speed := vel.dot(tangent)
		var hit_loss := clampf(0.10 + into * 0.030 + absf(outward) * 0.52, 0.10, 0.85)
		vel -= tangent * tan_speed * hit_loss
		# 往里推一点，避免下一帧仍在墙外反复触发冲击
		pos -= side * sgn * 0.06
	var t_speed := vel.dot(tangent)
	if absf(t_speed) > 0.05:
		# 刮擦减速度：平行贴墙约 1.8 m/s²，车头斜顶护栏可到 ~19 m/s²。
		var scrub := (1.8 + absf(outward) * 17.0) * clampf(dt, 0.0, 0.05)
		vel -= tangent * signf(t_speed) * minf(absf(t_speed), scrub)
	var along := vel.dot(tangent)
	if outward > 0.02 and absf(along) > 5.0:
		# 浅角度高速蹭墙：护栏把车头轻轻拨回赛道方向（不吸附、不抢方向）
		var dir := signf(along)
		var target_heading := atan2(tangent.x * dir, tangent.z * dir)
		var diff := wrapf(target_heading - heading, -PI, PI)
		heading += diff * clampf(outward * 0.55, 0.0, 0.22) * clampf(dt * 7.0, 0.0, 0.30)
	elif outward > 0.02 and absf(throttle) > 0.05:
		# 车头顶死护栏且几乎静止：此时转向不产生偏航（yaw 与车速成正比），
		# 车会永久卡在墙里。由护栏给一个缓慢的车头拨正，恢复沿墙牵引。
		var dir_low := signf(fwd.dot(tangent))
		if absf(fwd.dot(tangent)) < 0.02:
			dir_low = signf(along) if absf(along) > 0.2 else 1.0
		var target_low := atan2(tangent.x * dir_low, tangent.z * dir_low)
		var diff_low := wrapf(target_low - heading, -PI, PI)
		heading += diff_low * clampf(dt * 6.0, 0.0, 0.5)
	speed_forward = vel.dot(forward())
	speed_kph = absf(speed_forward) * 3.6


# --- 城市实景接触 ------------------------------------------------------------

## 都会环线：主环只用于赛程和 AI，玩家可以开进任何街道。
##   · 不做侧向夹紧——不存在隐形护栏
##   · 建筑由 CityWorld.push_out 推出
##   · 离开主环走廊时冻结赛程进度，回来时由 RaceManager 重新锚定，防止跳圈
func _update_city_contact(dt: float) -> void:
	wall_impact = 0.0
	wall_contact = false
	pos.y = lerpf(pos.y, 0.0, 1.0 - exp(-20.0 * dt))
	if track != null:
		var info := track.nearest(pos, track_index)
		if not info.is_empty():
			track_index = int(info.get("index", track_index))
			var lateral := float(info.get("lateral", 0.0))
			var hw := float(info.get("half_width", track.half_width))
			if absf(lateral) <= hw + 1.0:
				progress_dist = float(info.get("dist", progress_dist))
				_city_seek_cd = 0.0
			else:
				_city_seek_cd -= dt
				if _city_seek_cd <= 0.0:
					# 远离主环后小窗口会失效：定期做一次全局最近点，
					# 保证回到环上时 track_index 已经对准当前位置。
					_city_seek_cd = 0.5
					track_index = int(track.nearest(pos, -1).get("index", track_index))
	var surf := String(city.call("surface_at", pos.x, pos.z))
	world_surface = surf
	offroad = surf != "road"
	speed_forward = vel.dot(forward())
	speed_kph = absf(speed_forward) * 3.6


# --- 开放世界接触 ------------------------------------------------------------

## 自由漫游：没有赛道护栏，地面由高度场提供。
##   · 高度跟随：车体贴着高度场平滑升降，坡道不抖
##   · 坡度物理：沿坡向的重力分量加到速度上（上坡掉速、下坡加速）
##   · 地表材质：决定抓地与额外阻力（沙地打滑、冰雪失控、涉水变慢、熔岩极慢）
func _update_open_world_contact(dt: float) -> void:
	wall_impact = 0.0
	wall_contact = false
	if world == null:
		return
	var h := float(world.call("height_at", pos.x, pos.z))
	var surf := String(world.call("surface_at", pos.x, pos.z))
	world_surface = surf
	world_depth = float(world.call("depth_at", pos.x, pos.z))
	var zone: Dictionary = world.call("zone_at", pos.x, pos.z)
	world_zone = String(zone.get("id", ""))

	# 贴地
	pos.y = lerpf(pos.y, h, 1.0 - exp(-20.0 * dt))
	var n: Vector3 = world.call("normal_at", pos.x, pos.z)
	world_normal = n

	var fwd := forward()
	var side := right()
	var g := Vector3(0.0, -9.81, 0.0)
	var tangent_g := g - n * g.dot(n)
	world_grade = tangent_g.dot(fwd)

	var vf := vel.dot(fwd)
	var vl := vel.dot(side)
	# 坡向重力：上坡（grade > 0）减速，下坡加速
	vf += world_grade * dt * 0.9
	vl += tangent_g.dot(side) * dt * 0.55

	# 地表 → 抓地系数
	var grip := 1.0
	match surf:
		"road":
			grip = 1.0
			offroad = false
		"grass":
			grip = 0.80
			offroad = true
		"sand":
			grip = 0.66
			offroad = true
		"rock":
			grip = 0.88
			offroad = true
		"snow":
			grip = 0.58
			offroad = true
		"ice":
			grip = 0.46
			offroad = true
		"lava":
			grip = 0.34
			offroad = true
		"water":
			grip = 0.30
			offroad = true
		_:
			grip = 0.80
			offroad = true
	# 低抓地 → 横向速度额外衰减（打滑）
	vl *= exp(-(1.0 - grip) * 7.0 * dt)

	# 涉水：越深阻力越大，深水直接拖停
	if world_depth > 0.25:
		var drag := clampf(world_depth * 1.6, 0.0, 14.0)
		vf = _toward_zero(vf, drag * dt)
		vl = _toward_zero(vl, drag * dt * 1.4)
	if surf == "lava":
		vf = _toward_zero(vf, 18.0 * dt)

	vel = fwd * vf + side * vl
	speed_forward = vf
	speed_kph = absf(vf) * 3.6


## 静态实体碰撞：把车推出建筑物 / 树 / 码头墙 / 护栏。
## 开放世界的车辆物理是自写的运动学（不走 Godot 物理引擎），
## 所以这里自己做一次「圆 vs 有向盒」的推出：车永远撞不进实心结构里。
## 几何实现放在 OpenWorld.push_out 里（全世界只有一份，不会两处代码走样）。
func _resolve_static_collisions() -> void:
	var w: Node = city if city != null else world
	if w == null:
		return
	if not w.has_method("push_out"):
		return
	var r := 1.45                      # 车体外接半径（半宽 ~0.95 + 余量）
	var res: Dictionary = w.call("push_out", pos.x, pos.z, r, pos.y)
	if not bool(res.get("hit", false)):
		return
	var np: Vector2 = res["pos"]
	pos.x = np.x
	pos.z = np.y
	# 速度沿法线分量清掉：撞墙不穿墙，也不弹飞
	var n: Vector2 = res["normal"]
	if n.length_squared() > 0.0001:
		wall_hit_point = pos + Vector3(n.x, 0.0, n.y) * 0.9 + Vector3(0.0, 0.55, 0.0)
		var vn := vel.x * n.x + vel.z * n.y
		if vn < 0.0:
			vel.x -= n.x * vn
			vel.z -= n.y * vn
			wall_impact = maxf(wall_impact, absf(vn))
			wall_contact = true

func _update_drift_score(dt: float) -> void:
	drift_lost_timer = maxf(0.0, drift_lost_timer - dt)
	drift_bank_flash = maxf(0.0, drift_bank_flash - dt)
	# 撞墙打断连击（已入账的分数保留）
	if wall_impact > 2.2 and (drift_chain_score > 1.0 or drift_grace > 0.0):
		drift_chain_score = 0.0
		drift_chain_time = 0.0
		drift_combo = 1
		drift_grace = 0.0
		drift_lost_timer = 1.5
		return
	if drift_active and speed_kph > 22.0:
		drift_chain_time += dt
		drift_grace = 1.1
		drift_combo = clampi(1 + int(drift_chain_time / 2.2), 1, 8)
		drift_max_combo = maxi(drift_max_combo, drift_combo)
		var slip01 := clampf((absf(lat_slip) - 1.8) / 5.0, 0.0, 1.0)
		var rate := speed_kph * (0.90 + slip01 * 2.20)
		drift_chain_score += rate * float(drift_combo) * dt
	elif drift_grace > 0.0:
		drift_grace = maxf(0.0, drift_grace - dt)
		if drift_grace <= 0.0:
			_bank_drift()
	elif drift_chain_score > 0.0:
		_bank_drift()


func _bank_drift() -> void:
	var value := int(round(drift_chain_score))
	drift_chain_score = 0.0
	drift_chain_time = 0.0
	drift_combo = 1
	drift_grace = 0.0
	if value >= 10:
		drift_bank += value
		drift_bank_last = value
		drift_bank_flash = 1.4


func _sync_visual(dt: float) -> void:
	position = pos + Vector3(0.0, 0.02, 0.0)
	rotation = Vector3(0.0, heading, 0.0)
	if model == null:
		return
	var speed01 := clampf(speed_kph / 190.0, 0.0, 1.0)
	var roll_target := clampf(-steer * (0.030 + 0.062 * speed01), -0.095, 0.095)
	roll_vis = _damp(roll_vis, roll_target, 7.5, dt)
	# 纵向加速度 → 刹车点头 / 加速抬头，并带一点悬挂压缩
	if dt > 0.0001:
		var a := (speed_forward - prev_speed_fwd) / dt
		accel_vis = _damp(accel_vis, clampf(a, -24.0, 20.0), 10.0, dt)
	prev_speed_fwd = speed_forward
	var pitch_target := clampf(-accel_vis * 0.0034, -0.048, 0.052)
	pitch_vis = _damp(pitch_vis, pitch_target, 9.0, dt)
	bob_vis = _damp(bob_vis, -clampf(absf(accel_vis) * 0.00035, 0.0, 0.009), 11.0, dt)
	# 开放世界：车身贴合地形坡度
	if free_roam and world != null:
		var n := world_normal
		var f3 := Vector3(sin(heading), 0.0, cos(heading))
		var r3 := Vector3(-cos(heading), 0.0, sin(heading))
		var slope_pitch := -asin(clampf(n.dot(f3), -1.0, 1.0))
		var slope_roll := asin(clampf(n.dot(r3), -1.0, 1.0))
		pitch_vis = lerpf(pitch_vis, slope_pitch * 0.85, 1.0 - exp(-8.0 * dt))
		roll_vis = lerpf(roll_vis, slope_roll * 0.85, 1.0 - exp(-8.0 * dt))
	model.rotation.x = pitch_vis
	model.rotation.z = roll_vis
	model.position = model_base_pos + Vector3(0.0, bob_vis, 0.0)
	wheel_spin = fposmod(wheel_spin + speed_forward / maxf(wheel_radius, 0.05) * dt, TAU)
	for w in spin_wheels:
		w.rotation.x = wheel_spin
	var steer_angle := -steer * 0.40
	for w in steer_wheels:
		w.rotation.y = steer_angle


# --- 对外显示 ---------------------------------------------------------------

func gear_label() -> String:
	if speed_forward < -0.5:
		return "R"
	if gear_count <= 1:
		return "D"
	if manual:
		return "M%d" % gear
	return "D%d" % gear


func is_manual() -> bool:
	return manual


func is_ev() -> bool:
	return fuel_type == "ev"


func speed01() -> float:
	return clampf(speed_kph / maxf(max_speed * 3.6, 1.0), 0.0, 1.0)


# --- helpers ----------------------------------------------------------------

static func _damp(current: float, target: float, lambda: float, dt: float) -> float:
	return lerpf(current, target, 1.0 - exp(-lambda * dt))


static func _toward_zero(value: float, amount: float) -> float:
	if value > 0.0:
		return maxf(0.0, value - amount)
	return minf(0.0, value + amount)
