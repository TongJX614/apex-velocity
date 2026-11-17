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
# 刹停后还要继续按住刹车这么久才挂倒挡：先定住，再倒车。
const REVERSE_HOLD := 0.5
# 刹车标定值（30~38 m/s² ≈ 3~3.9g）远超轮胎抓地极限，按真实约 1.5g 缩放。
const BRAKE_SCALE := 0.45
# 正常横向抓地（1/s）：7.0×7.0 太高，车像轨道车且松手刹瞬间吸附；
# 3.2 保留清晰的路感与可控滑移，配合动态抓地做漂移。
const GRIP_BITE := 3.2
const DRIVE_EFF := 0.82            # 传动效率：功率段推力 = P·η/(m·v)
const FUEL_CUT_DRAG := 2.6         # 断油时的发动机制动 m/s²

# --- 传动系 -----------------------------------------------------------------
## 6 挡基准曲线：各挡红线对应的极速占比。真车挡位数不是统一的 6（本车池里有
## 6/7/8/9 挡），所以这张表只是**基准形状**，实际用 `_build_gear_tops()` 按每台车
## 的真实挡位数在归一化位置上重采样得到 `gear_tops`。重采样在 N=6 时采样点与基准
## 逐位重合，因此 6 挡车的齿比行为与改前完全一致。
const GEAR_TOPS_REF := [0.16, 0.30, 0.45, 0.61, 0.79, 1.0]
## 支持的最大挡位数（车池里最高的 9AT）。超出按上限取，避免齿比表越界。
const MAX_GEARS := 9
const SHIFT_CUT_AUTO := 0.13
const SHIFT_CUT_MANUAL := 0.055
const AUTO_UPSHIFT := 0.985        # 自动升档上限（红线比例，约 7450rpm）
const AUTO_SHIFT_RPM := 0.75       # 自动挡升档点：6000rpm（1.0 = 8000rpm）
const AUTO_DOWNSHIFT := 0.625      # 自动降档阈值：5000rpm
const AUTO_SHIFT_HYST := 0.8       # 换挡车速滞回带（m/s）：必须大于换挡断油期间的掉速
const AUTO_UPSHIFT_WAIT := 0.45    # 到升挡转速却被滞回带挡住多久后强制升挡（s）
const MANUAL_TORQUE := 1.12        # 手动挡动力增益
const SHIFT_LOCK := 0.11

# --- 氮气 -------------------------------------------------------------------
const NITRO_ACCEL := 1.50          # 氮气推力倍率
const NITRO_CAP := 0.12            # 氮气极速上限提升
const NITRO_START := 0.30
const NITRO_DRIFT_GAIN := 0.19     # 漂移充能速度（满槽/秒）：约 5.3s 连续漂移攒满
const NITRO_IDLE_GAIN := 0.004     # 高速巡航的微弱回充

# --- 尾流（Slipstream）------------------------------------------------------
# 紧跟前车时进入低压区：风阻下降 + 额外推力 + 极速上限小幅提升。
# main 每物理帧写入 draft_target（0~1），Car 内部平滑，松油/变线自然衰减。
const DRAFT_ACCEL := 1.9           # 尾流最大额外推力（m/s²）
const DRAFT_CAP := 0.05            # 尾流极速上限提升
const DRAFT_DRAG_CUT := 0.35       # 风阻最多削减比例
const DRAFT_RISE := 2.6            # 进入尾流的速度（1/s）
const DRAFT_FALL := 3.4            # 脱离尾流的衰减速度（1/s）

# --- 完美起步 ---------------------------------------------------------------
# 倒计时结束前把油门踩到底：起步瞬间获得短促额外推力（配合 HUD 提示）。
const START_BOOST := 4.2           # m/s²
const START_BOOST_TIME := 0.9

const WHEELSPIN_PENALTY := {"RWD": 0.22, "FWD": 0.28, "AWD": 0.10}

# --- 漂移 -------------------------------------------------------------------
const DRIFT_HOLD_SPEED := 6.0      # 低于此速度不再保持漂移（自动收油回抓地）
const DRIFT_GRIP := 0.75           # 低速漂移中的横向抓地（1/s），越小越滑
const DRIFT_GRIP_SPEED := 0.35     # 车速每 40m/s 追加的漂移抓地：高速漂得更收敛
const DRIFT_ENTER := 9.0           # 进入漂移的抓地衰减速度
const DRIFT_RECOVER := 3.1         # 松手刹后的抓地恢复速度
# 滑移角上限（弧度）。超过就开始「救车」：抓地回收 + 偏航衰减，车头自己拉回
# 行进方向。这才是防止甩飞的正确做法——限制的是打转，不是漂移本身。
# 低速能甩到 ~69°，高速收到 ~49°（高速打转必然失控，而且视觉上照样是大漂）。
const DRIFT_SLIP_LOW := 1.20
const DRIFT_SLIP_MIN := 0.55       # 小舵量/收油时允许的角度下限（约 31°）
const DRIFT_SLIP_HIGH := 0.85
const DRIFT_SLIP_RAMP := 0.75      # 从上限到完全救车的滑移角余量（弧度）
const DRIFT_POWER_OVER := 0.45     # 漂移中全油门追加的偏航：油门控制角度
const DRIFT_RECLAIM := 0.85        # 横向滑移动能回灌成前进速度的比例


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
## 真实挡位数（1 = 电车单速）。写入时立刻重采样齿比表，这样外部工具
## （tools/accel_check.gd）只赋一个数字就能拿到正确齿比，不必各自复制上限与建表逻辑。
var gear_count := 6:
	set(value):
		gear_count = clampi(value, 1, MAX_GEARS)
		_build_gear_tops()
## 各挡红线对应的极速占比，由 gear_count 重采样 GEAR_TOPS_REF 得到，末位恒为 1.0。
var gear_tops: PackedFloat32Array = PackedFloat32Array(GEAR_TOPS_REF)
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
var _shift_speed := 0.0            # 上次换挡时的车速：自动挡升降档的方向滞回基准
var _up_wait := 0.0                # 自动挡已到升挡转速、却被滞回带挡住的累计时间
var launch := false
var braking := false
var reverse_hold := 0.0            # 刹停后持续按住刹车的时长

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
var draft := 0.0                    # 当前尾流强度 0~1（HUD / 物理共用）
var draft_target := 0.0             # 由 main 每帧写入
var start_boost_timer := 0.0        # >0 时起步推力加成
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

# 当前脚下材质（都会环线 / 遥测共用）
var world_surface := "road"

# --- 城市实景（都会环线）-----------------------------------------------------
## 城市模式：赛道只用来计时和 AI，不再有走廊护栏；车被建筑碰撞场约束，
## 所有街道都能开。city 为 CityWorld（鸭子类型）。
var city: Node = null
## 离开主环后全局重寻最近点的节流计时。
var _city_seek_cd := 0.0


func setup(car_spec: Dictionary, track_path: TrackPath, start_dist: float = 10.0, lateral: float = 0.0, paint: Color = Color.TRANSPARENT, look_config: Dictionary = {}, build_visual: bool = true) -> void:
	spec = car_spec
	car_id = String(spec.get("id", ""))
	track = track_path
	city = null
	max_speed = float(spec.get("maxSpeed", 60.0))
	brake_power = float(spec.get("brake", 30.0)) * BRAKE_SCALE
	grip_power = float(spec.get("grip", 7.0))
	drive_drag = float(spec.get("driveDrag", 0.12))
	fuel_type = String(spec.get("fuelType", "ice")).to_lower()
	engine_profile = String(spec.get("engineProfile", "i6")).to_lower()
	aspiration = String(spec.get("aspiration", "na")).to_lower()
	drivetrain = String(spec.get("drivetrain", "RWD")).to_upper()
	redline = clampf(float(spec.get("redline", 0.94)), 0.80, 1.0)
	# 真实挡位数直接取自档案；上限与齿比表由 gear_count 的 setter 统一处理。
	gear_count = int(spec.get("gears", 6))
	real_zero_to_100 = float(spec.get("realZeroTo100", spec.get("zeroTo100", 5.0)))
	weight_kg = float(spec.get("weightKg", 1500.0))
	power_hp = float(spec.get("powerHp", 300.0))
	torque_nm = float(spec.get("torqueNm", 400.0))
	if fuel_type == "ev":
		gear_count = 1
	nitro_capacity = maxf(1.2, float(spec.get("nitroTime", 3.7)))
	nitro_charge = NITRO_START
	draft = 0.0
	draft_target = 0.0
	start_boost_timer = 0.0
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
	if build_visual:
		_load_visual()
		if not look_config.is_empty() and model != null:
			GarageLook.apply(model, car_id, look_config)
	reset(start_dist, lateral)


func _load_visual() -> void:
	var paint := Color.TRANSPARENT
	if paint_color.a > 0.001:
		paint = paint_color
	var result := CarVisual.build(spec, self, paint)
	model = result["model"] as Node3D
	if model != null:
		model_base_pos = model.position
		CarVisual.apply_race_optimizations(model, false)
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
	if track.open_field:
		# 开放场地：出生在正中心，车头朝 +Z，前方 500m 全是柏油。
		pos = Vector3.ZERO
		heading = 0.0
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
	_shift_speed = 0.0
	_up_wait = 0.0
	reverse_hold = 0.0
	nitro_charge = NITRO_START
	draft = 0.0
	draft_target = 0.0
	start_boost_timer = 0.0
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


func add_headlights(energy_scale: float = 1.0) -> void:
	if model == null:
		return
	CarVisual.add_headlights(model, spec, energy_scale)


## 关闭车灯。
func remove_headlights() -> void:
	CarVisual.remove_headlights(model)


## 夜间车身的冷色轮廓补光（只给玩家车，勾车顶/尾翼/后肩）。
func add_night_rim(color: Color = Color(0.62, 0.78, 1.0)) -> void:
	if model == null:
		return
	CarVisual.add_night_rim(model, color)


func remove_night_rim() -> void:
	if model == null:
		return
	CarVisual.remove_night_rim(model)


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
	var draft_in := clampf(draft_target, 0.0, 1.0)
	draft = move_toward(draft, draft_in, dt * (DRAFT_RISE if draft_in > draft else DRAFT_FALL))
	# 低速时尾流没有意义：25m/s 以下线性淡出，避免起步阶段凭空多推力。
	var draft_eff := draft * clampf((speed_abs - 12.0) / 18.0, 0.0, 1.0)

	# 倒车：先刹停定住，继续按住刹车 REVERSE_HOLD 秒才挂倒挡。
	# 挂上后 v_f 变负仍满足门槛，松开刹车即退出并清零。
	if throttle_in < -0.01 and v_f <= 0.2:
		reverse_hold += dt
	else:
		reverse_hold = 0.0
	var reversing := reverse_hold >= REVERSE_HOLD
	braking = throttle_in < -0.01 and not reversing
	launch = throttle_in > 0.5 and speed_abs < 12.0

	_update_drift_state(dt, speed_abs, hb)
	_update_gearbox(dt, input, speed_abs, reversing)
	_update_nitro(dt, nitro_in, throttle_in, speed_abs)
	# 断油（limiter）：手动挡红区不升档 / 顶挡超转时切断动力并发动机制动
	#
	# 触发阈值是 redline × 0.998，不是 × 1.002。
	#
	# 为什么必须落在红线以内：顶挡的极速占比 gear_tops 末位 = 1.0，也就是
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
		# 0.55 而不是 0.42：撞护栏后车停在白线外的路肩带（offroad），
		# 0.42 的倒挡推力几乎正好被 offroad 阻力吃掉，倒车会「原地蠕动」。
		accel = -power * 0.55 * (1.0 - rev_ratio * rev_ratio * 0.85)
		if hb:
			accel *= 0.7
	elif throttle_in > 0.01:
		var torque := _torque_curve(rpm)
		# 两段物理曲线：
		#   · 低速（v < _power_ref）：按标定推力恒加速（牵引力限制段）；
		#   · 高速：推力 = P·η/(m·v)，随速度双曲线衰减 —— 速度越高加速越慢，
		#     100-200 明显慢于 0-100，符合真车「功率封顶」的特性。
		var power_factor := minf(1.0, _power_ref / maxf(v_f, _power_ref))
		accel = power * throttle_in * torque * power_factor * _gear_lug(speed_abs)
		# 尾流：前车破风后本车风阻下降，同时获得一点额外推力。
		accel += DRAFT_ACCEL * draft_eff
		# 完美起步：短促的牵引力加成，速度上来后自然结束。
		if start_boost_timer > 0.0:
			accel += START_BOOST * clampf(start_boost_timer / START_BOOST_TIME, 0.0, 1.0)
		if shift_cut > 0.0:
			accel *= 0.18
		# 起步牵引力上限：低速大油门会打滑（四驱损失最小）
		var spin_target := 1.0 if (speed_abs < 10.0 and throttle_in > 0.65) else 0.0
		wheelspin = lerpf(wheelspin, spin_target, 1.0 - exp(-8.0 * dt))
		accel *= 1.0 - wheelspin * _wheelspin_penalty()
		if hb:
			# 漂移中保留大部分动力：旧版 ×0.3 叠加手刹阻力会把车拽停，
			# 玩家看到的就是「漂到一半莫名其妙停住」。
			# 0.45 起点同样太狠：全漂移状态只剩 72% 动力，实测漂移 2s 就掉掉三成速，
			# 大范围横扫退化成原地慢转圈，这就是「手感差一点意思」的物理来源。
			accel *= 0.60 + 0.33 * drift_grip
		# 风阻 + 滚阻给油时同样生效：功率段推力靠它和极速达到平衡，
		# 否则平衡点会远超 max_speed（一直顶到硬钳制才停）。
		accel -= COAST_ROLL + _aero_drag * (1.0 - DRAFT_DRAG_CUT * draft_eff) \
			* speed_abs * speed_abs
		if fuel_cut:
			accel *= 0.04

	# Steering authority: 低速转向灵活，高速明显变「重」
	var spd_norm := clampf(speed_abs / 14.0, 0.0, 1.0)
	var speed01 := clampf(speed_abs / maxf(max_speed, 1.0), 0.0, 1.0)
	var steer_authority := 1.12 - 0.72 * pow(speed01, 0.85)
	# 倒车时偏航方向相反（和真车一样），否则按「左」车头会往反方向甩。
	var yaw_dir := -1.0 if v_f < -0.3 else 1.0
	# 漂移时偏航要**加强**而不是削弱：正常过弯轮胎咬死、半径已经很小，
	# 只有让漂移到偏航角速度更高，才能做到「车身角度更大 + 拐弯半径更小」。
	# 油门那一乘项是动力转向：全油门车尾继续外抛、收油角度自动收紧。
	var drift_yaw := lerpf(1.50, 1.15, clampf(speed_abs / 45.0, 0.0, 1.0)) \
		* (1.0 + DRIFT_POWER_OVER * clampf(throttle_in, 0.0, 1.0))
	var yaw_rate := steer * 2.35 * spd_norm * steer_authority \
		* lerpf(1.0, drift_yaw, drift_grip) * yaw_dir
	# 甩过头才救车：偏航大幅衰减、车头被拉回行进方向，限制的是原地打转不是漂移。
	# 上限随驾驶意图（舵量 × 油门）抬升：固定上限会把所有输入钳在同一个角度上
	# ——实测满舵/半舵、全油/收油的角度只差 3°，玩家既收不回也放不出去。
	var slip_limit := lerpf(DRIFT_SLIP_LOW, DRIFT_SLIP_HIGH, clampf(speed_abs / 45.0, 0.0, 1.0))
	var demand := clampf(absf(steer), 0.0, 1.0) * lerpf(0.50, 1.0, clampf(throttle_in, 0.0, 1.0))
	var slip_max := lerpf(DRIFT_SLIP_MIN, slip_limit, demand)
	var slip_over := clampf((drift_angle - slip_max) / DRIFT_SLIP_RAMP, 0.0, 1.0)
	if slip_over > 0.0:
		yaw_rate *= lerpf(1.0, 0.22, slip_over)
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
	# 漂移抓地随车速上升：低速甩得出大角度，高速收得住，不会整车横着飞出去。
	# 用合速度而不是前向分量——漂移中前向速度掉得很快，否则抓地会跟着塌掉。
	var grip_drift := DRIFT_GRIP + DRIFT_GRIP_SPEED * clampf(vel.length() / 40.0, 0.0, 1.5)
	var grip := lerpf(grip_normal, grip_drift, drift_grip)
	# 甩过头时把抓地咬回去：横向动量被轮胎吸收，车收正而不是继续横着飞出去。
	if slip_over > 0.0:
		grip = lerpf(grip, grip_normal, slip_over * 0.80)
	var lateral_before := new_vl
	new_vl *= exp(-grip * dt)
	# 漂移保速：轮胎咬住横向滑移时，那部分动能不是消失而是转回前进方向。
	# 缺了这一步，车身每转一度就把前向速度搬进「横向」桶里再抹掉——
	# 结果打方向越猛掉速越快、角度反而越小，漂移退化成原地慢转圈。
	# 按动能守恒回灌（vf² += R·(vl₀²−vl²)），速度只受真实阻力支配。
	if drift_grip > 0.05 and absf(new_vf) > 2.0:
		var freed := lateral_before * lateral_before - new_vl * new_vl
		if freed > 0.0:
			new_vf += signf(new_vf) * (sqrt(new_vf * new_vf + DRIFT_RECLAIM * freed) - absf(new_vf))

	var speed_now := absf(new_vf)
	var base_drag := COAST_ROLL + _aero_drag * (1.0 - DRAFT_DRAG_CUT * draft_eff) \
		* speed_now * speed_now
	if hb:
		# 手刹的额外阻力只该在「起漂」那一下起作用；按住不放时还按 drift_grip
		# 全额扣速，等于一边漂移一边踩死刹车，是漂移掉速的主要来源。
		new_vf = _toward_zero(new_vf, (base_drag + HANDBRAKE_DRAG + drift_grip * 0.18) * dt)
	elif throttle_in <= 0.01:
		if throttle_in < -0.01 and not braking:
			new_vf = _toward_zero(new_vf, base_drag * dt)
		elif not braking:
			new_vf = _toward_zero(new_vf, (base_drag + COAST_ENGINE) * dt)
	if offroad:
		# 已撞在护栏边时 lateral 一定超过路肩线，全量 offroad 阻力会把倒挡按死；
		# 倒车只取 45% 阻力，保证 S/↓ 能从护栏/路肩倒出来。
		new_vf = _toward_zero(new_vf, OFFROAD_DRAG * (0.45 if reversing else 1.0) * dt)
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

	if city != null:
		_update_city_contact(dt)
		_resolve_static_collisions()
	elif track != null and track.open_field:
		_update_open_field_contact(dt)
	else:
		_update_track_contact(dt)
	_update_drift_score(dt)
	_update_rpm(dt)
	start_boost_timer = maxf(0.0, start_boost_timer - dt)
	_sync_visual(dt)
	# 尾流是「别人给的状态」：每帧由 main 重新写入，本帧用完即清零，
	# 这样菜单/无 AI 场景里 draft 会自然衰减而不是永久粘住。
	draft_target = 0.0


## 超车奖励等一次性充能入口（HUD 不直接改玩法状态）。
func add_nitro(amount: float) -> void:
	nitro_charge = clampf(nitro_charge + maxf(amount, 0.0), 0.0, 1.0)


## 完美起步：由 main 在 GO 瞬间调用。
func grant_start_boost() -> void:
	start_boost_timer = START_BOOST_TIME


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
		_shift_speed = 0.0
		_up_wait = 0.0
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
		# 手动期间持续跟随车速，切回自动挡时滞回基准才不会是陈旧值。
		_shift_speed = speed_abs
		_up_wait = 0.0
		auto_gear = gear
		return
	# ---- 自动挡 ----
	# 升档 6000rpm、降档 5000rpm。两点只差 1000rpm，而升档后转速会落到
	# 3600~4900（已经低于降档点），所以必须加车速滞回带：升档后车速要再涨
	# HYST 才允许下一次升档、再掉 HYST 才允许降档。
	# 只判方向不够——功率弱的车升档后推力刚好抵不过阻力，车速会掉一点点，
	# 于是立刻降档、再加速、再升档，每 0.25s 一轮，换挡断油一直挂着，车反而走不动。
	var up_at := minf(redline * AUTO_UPSHIFT, AUTO_SHIFT_RPM)
	# 转速到了升挡点却被滞回带挡住时累计计时：滞回带本身可能变成永远满足
	# 不了的条件（降进低挡后已经顶在该挡红线上、车速再也涨不起来），
	# 计时到点就无视滞回带强制升挡，保证自动挡不可能卡死在某个挡。
	var rpm_up_ok := gear < gear_count and rpm >= up_at
	_up_wait = _up_wait + dt if rpm_up_ok else 0.0
	if shift_lock <= 0.0 and rpm_up_ok \
			and (speed_abs > _shift_speed + AUTO_SHIFT_HYST or _up_wait >= AUTO_UPSHIFT_WAIT):
		gear += 1
		shift_cut = SHIFT_CUT_AUTO
		shift_lock = SHIFT_LOCK
		shift_flash = 0.14
		_shift_speed = speed_abs
		_up_wait = 0.0
	elif shift_lock <= 0.0 and gear > 1 and rpm < AUTO_DOWNSHIFT \
			and speed_abs < _shift_speed - AUTO_SHIFT_HYST:
		var rpm_new := _rpm_for_gear(speed_abs, gear - 1)
		# 低挡转速必须落在升挡点以下才允许降：否则会一降完就顶红线、
		# 立刻又该升回来，等于白降一次挡（真实自动挡也不会在高速时降到 1 挡）。
		if rpm_new <= redline * 0.99 and rpm_new < up_at:
			gear -= 1
			shift_cut = SHIFT_CUT_AUTO * 0.85
			shift_lock = SHIFT_LOCK
			shift_flash = 0.12
			_shift_speed = speed_abs
			_up_wait = 0.0
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


## 按真实挡位数重采样齿比表：在归一化位置 i/(N-1) 上对 6 挡基准做线性插值。
## N=6 时采样点正好落在基准节点上，结果逐位等于 GEAR_TOPS_REF，6 挡车行为不变；
## N=7/8/9 时阶梯更密（每挡覆盖的极速区间更窄），N=5 时更疏。
func _build_gear_tops() -> void:
	gear_tops.resize(gear_count)
	if gear_count <= 1:
		gear_tops[0] = 1.0
		return
	var last := GEAR_TOPS_REF.size() - 1
	for i in gear_count:
		var pos := float(i) / float(gear_count - 1) * float(last)
		var k := int(pos)
		if k >= last:
			gear_tops[i] = float(GEAR_TOPS_REF[last])
		else:
			gear_tops[i] = lerpf(float(GEAR_TOPS_REF[k]), float(GEAR_TOPS_REF[k + 1]), pos - float(k))


## 取某挡的极速占比。挡位是运行时状态，换车（spec 挡位更少）时可能比表还大，故钳制。
func _gear_top(g: int) -> float:
	return gear_tops[clampi(g, 1, gear_tops.size()) - 1]


func _rpm_for_gear(speed_abs: float, use_gear: int) -> float:
	var span := redline - RPM_IDLE
	if gear_count <= 1:
		var ratio := speed_abs / maxf(max_speed, 1.0)
		return clampf(RPM_IDLE + ratio * span, 0.0, 1.15)
	var top := _gear_top(use_gear) * max_speed
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


## 高挡低速「拖挡」衰减：齿比越小轮上扭矩越低，顶挡起步只能慢慢蠕动。
## 1 挡豁免（起步离合全联动）；车速进入该挡合理区间后恢复满推力。
## 自动挡升档点 6000rpm 保证换挡后转速仍高于此区间，所以不影响 0-100 标定。
func _gear_lug(speed_abs: float) -> float:
	if gear <= 1:
		return 1.0
	var engage := _gear_top(gear) * max_speed * 0.35
	# 下限保证还能蠕动：低于滚阻就彻底动不了，玩家会以为车坏了。
	var floor_v := clampf(0.7 / float(gear), 0.22, 0.5)
	return clampf(floor_v + (1.0 - floor_v) * speed_abs / maxf(engage, 1.0), floor_v, 1.0)


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
	return max_speed * (1.0 + DRAFT_CAP * draft)


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
		if v <= gear_tops[gi] * max_speed:
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
	var sgn := signf(lateral)
	if sgn == 0.0:
		sgn = 1.0
	var fwd := forward()
	var outward := fwd.dot(side) * sgn
	# 车头顶死护栏后，碰撞钳制会把车推回墙内 6cm，下一帧就不再算 wall_contact，
	# 旧逻辑因此几乎从不触发「低速拨正」；结果是车头永远斜插在护栏里，倒车/前进
	# 都走不动。这里在「贴近护栏 + 车头朝墙 + 几乎静止」时也持续拨正车头。
	if absf(lateral) > wall - 0.35 and absf(throttle) > 0.05 \
			and absf(vel.dot(tangent)) < 2.5 and outward > 0.02:
		_nudge_heading_along_wall(tangent, fwd, vel.dot(tangent), dt)
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
	wall_side = sgn
	pos += side * (sgn * wall - lateral)
	wall_hit_point = pos + side * (sgn * 0.85) + Vector3(0.0, 0.55, 0.0)
	var v_side := vel.dot(side)
	var into := v_side * sgn
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
		_nudge_heading_along_wall(tangent, fwd, along, dt)
	speed_forward = vel.dot(forward())
	speed_kph = absf(speed_forward) * 3.6


## 贴墙脱困：把车头朝赛道切线方向拨，让前进/倒车都能沿护栏滑出去。
func _nudge_heading_along_wall(tangent: Vector3, fwd: Vector3, along: float, dt: float) -> void:
	var dir_low := signf(fwd.dot(tangent))
	if absf(fwd.dot(tangent)) < 0.02:
		dir_low = signf(along) if absf(along) > 0.2 else 1.0
	var target_low := atan2(tangent.x * dir_low, tangent.z * dir_low)
	var diff_low := wrapf(target_low - heading, -PI, PI)
	heading += diff_low * clampf(dt * 8.0, 0.0, 0.6)


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


## 漂移练习：场内没有墙，方形边界外是草地（offroad 阻力 + 抓地损失）。
## 参考环只用于小地图定位：远离环时冻结进度、定期全局重锚，与城市同一套。
func _update_open_field_contact(dt: float) -> void:
	wall_impact = 0.0
	wall_contact = false
	pos.y = lerpf(pos.y, 0.0, 1.0 - exp(-20.0 * dt))
	var half := track.field_half
	var inside := absf(pos.x) <= half and absf(pos.z) <= half
	world_surface = "road" if inside else "grass"
	offroad = not inside
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
				_city_seek_cd = 0.5
				track_index = int(track.nearest(pos, -1).get("index", track_index))
	speed_forward = vel.dot(forward())
	speed_kph = absf(speed_forward) * 3.6


## 静态实体碰撞：把车推出城市建筑。
## 都会环线的车辆物理是自写的运动学（不走 Godot 物理引擎），
## 所以这里自己做一次「圆 vs 有向盒」的推出：车永远撞不进实心结构里。
## 几何实现放在 CityWorld.push_out 里。
func _resolve_static_collisions() -> void:
	var w: Node = city
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
	model.rotation.x = pitch_vis
	model.rotation.z = roll_vis
	model.position = model_base_pos + Vector3(0.0, bob_vis, 0.0)
	wheel_spin = fposmod(wheel_spin + speed_forward / maxf(wheel_radius, 0.05) * dt, TAU)
	for w in spin_wheels:
		w.rotation.x = wheel_spin
	var steer_angle := -steer * 0.40
	for w in steer_wheels:
		w.rotation.y = steer_angle
	CarVisual.set_brake_lights(model, braking or handbrake)


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
