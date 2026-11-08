class_name Haptics
extends Node
## 手柄细腻震动（无手柄时安全空操作）。
##
## 设计原则：只有「该震」的时候才震，静止/匀速巡航完全停震。
## 强度分 6 档，左右马达分开给，靠强弱比例区分「加速推背」和「刹车/漂移撕扯」：
##   L0 静止 / 匀速巡航            → 0（完全不震）
##   L1 轻加速 / 轻点刹车          → 极轻
##   L2 中等加速 / 中等刹车        → 轻
##   L3 全油门起步 0~100 / 重加速  → 中等偏上（推背，强马达为主）
##   L4 刹车踩到底                 → 剧烈（ABS 高频脉冲）
##   L5 漂移 / 手刹甩尾            → 最剧烈（横向撕扯）
## 另外：手动挡换挡 → 「噔噔噔」机械顿挫（自动挡不震）；撞墙 → 最大震动。
##
## 由 main.gd 接入：
##   · _ready:  haptics.setup()
##   · 每帧:    haptics.update_state(dt, car, race.state)
##   · 换挡:    haptics.on_shift(true / false, car.manual)
##   · 碰撞:    haptics.on_impact(...)   · 刮擦: haptics.on_scrape(...)
##   · 退出:    haptics.stop()

const TICK := 0.03            # 30Hz 重发，PULSE 0.10s 保证重叠不断震
const PULSE := 0.10
const SHIFT_BURST_TIME := 0.30
const IMPACT_TIME := 0.35
const SCRAPE_TIME := 0.10

## 6 档强度（weak 高频 / strong 低频）。索引即档位。
const LEVEL_WEAK := [0.0, 0.06, 0.14, 0.32, 0.55, 0.68]
const LEVEL_STRONG := [0.0, 0.03, 0.10, 0.46, 0.80, 0.92]
const LEVEL_NAMES := ["OFF", "TRACE", "LIGHT", "DRIVE", "BRAKE", "DRIFT"]

var device := -1
var enabled := true
var intensity := 1.35
## 当前档位（0..5），供调试/设置页观察。
var level := 0

var _tick := 0.0
var _refresh := 0.0
var _phase := 0.0
var _shift_burst := 0.0
var _shift_up := true
var _impact_t := 0.0
var _impact_amp := 0.0
var _impact_dur := IMPACT_TIME
var _scrape_t := 0.0
var _scrape_amp := 0.0
var _brake_entry := 0.0
var _drift_entry := 0.0
var _last_brake := false
var _last_drift := false
var _last_weak := 0.0
var _last_strong := 0.0
var _amp_weak := 0.0
var _amp_strong := 0.0
var _vibrating := false
var _last_speed_fwd := 0.0
var _accel_smooth := 0.0
var _gate_w := 1.0
var _gate_s := 1.0


func setup() -> void:
	enabled = true
	if Settings != null and Settings.has_method("get"):
		var flag = Settings.get("haptics_enabled")
		if flag != null:
			enabled = bool(flag)
		var strength = Settings.get("haptics_intensity")
		if strength != null:
			intensity = clampf(float(strength), 0.6, 2.0)
	_refresh_device()


func _refresh_device() -> void:
	device = -1
	var pads := Input.get_connected_joypads()
	if pads.size() > 0:
		device = int(pads[0])
	if device < 0 or not enabled:
		_stop_vibration()


func can_vibrate() -> bool:
	return enabled and device >= 0


## 换挡顿挫：只在手动挡触发（自动挡由 main 传入 manual=false）。
## 0.3s 内叠 3~4 下短脉冲，模拟「噔噔噔」的机械结合感。
func on_shift(up: bool = true, manual: bool = false) -> void:
	if not manual:
		return
	_shift_up = up
	_shift_burst = SHIFT_BURST_TIME


## 碰撞：strength 0..1，最大震动。
func on_impact(strength: float) -> void:
	var s := clampf(strength, 0.05, 1.0)
	_impact_amp = maxf(_impact_amp, s)
	_impact_dur = 0.32 + s * 0.55
	_impact_t = _impact_dur


## 贴墙刮擦：短促高频金属摩擦。
func on_scrape(strength: float) -> void:
	_scrape_amp = maxf(_scrape_amp, clampf(strength, 0.04, 0.8))
	_scrape_t = SCRAPE_TIME


func update_state(dt: float, car, race_state: int) -> void:
	_refresh += dt
	if _refresh > 2.0:
		_refresh = 0.0
		enabled = bool(Settings.haptics_enabled)
		intensity = clampf(float(Settings.haptics_intensity), 0.6, 2.0)
		if device < 0 or not Input.get_connected_joypads().has(device):
			_refresh_device()
	_phase += dt
	_shift_burst = maxf(0.0, _shift_burst - dt)
	_impact_t = maxf(0.0, _impact_t - dt)
	_scrape_t = maxf(0.0, _scrape_t - dt)
	_brake_entry = maxf(0.0, _brake_entry - dt)
	_drift_entry = maxf(0.0, _drift_entry - dt)

	var target_level := 0
	if can_vibrate() and car != null and is_instance_valid(car) \
			and race_state == 1:
		target_level = _drive_level(dt, car)

	var weak := 0.0
	var strong := 0.0
	_gate_w = 1.0
	_gate_s = 1.0
	if target_level > 0:
		weak = float(LEVEL_WEAK[target_level])
		strong = float(LEVEL_STRONG[target_level])
		# 很多手柄（Switch 布局等）马达只有「开/关」，振幅大小根本感觉不出来：
		# 改用节奏密度表达档位——轻 accel 稀疏点、重 accel 密 beat、ABS 急点刹、
		# 漂移持续撕扯。节奏门在输出级乘（不被包络平滑滤掉），开关马达也能分辨。
		match target_level:
			1:
				_gate_w = _square(3.3, 0.22)
				_gate_s = _gate_w
			2:
				_gate_w = _square(4.5, 0.45)
				_gate_s = _gate_w
			3:
				_gate_w = _square(6.7, 0.62)
				_gate_s = _gate_w
			4:
				_gate_w = _square(11.0, 0.55)
				_gate_s = _gate_w
			5:
				_gate_w = 0.70 + 0.30 * _square(7.0, 0.5)
				_gate_s = 1.0
		# 0~100 起步：持续低频重冲击，比巡航推背更「重」，到 28km/h 截止
		if target_level == 3 and absf(car.speed_kph) < 28.0 and float(car.throttle) > 0.55:
			_gate_w = 1.0
			_gate_s = 1.0
			weak += 0.10
			strong += 0.22
		# 越野/路肩：额外细碎颠簸（但巡航在平整路面不震）
		if car.offroad and absf(car.speed_kph) > 8.0:
			var dirt := clampf(absf(car.speed_kph) / 130.0, 0.2, 1.0)
			var rnd := 0.5 + 0.5 * sin(_phase * 57.0 + sin(_phase * 19.0) * 3.0)
			weak += 0.10 * dirt * rnd
			strong += 0.06 * dirt * (1.0 - rnd)
		# 断油 limiter：高频抖动
		if car.limiter_active:
			var jolt := 0.5 + 0.5 * sin(_phase * 101.0)
			weak += 0.12 * jolt
			strong += 0.05 * jolt
		# 刹车入弯的瞬间补一下
		if _brake_entry > 0.0:
			var e := _brake_entry / 0.12
			weak += 0.18 * e
			strong += 0.22 * e
		# 入漂瞬间补一记重脉冲
		if _drift_entry > 0.0:
			var d := _drift_entry / 0.16
			weak += 0.20 * d
			strong += 0.26 * d

	# 手动挡换挡顿挫：3~4 下短脉冲
	if _shift_burst > 0.0:
		var e := _shift_burst / SHIFT_BURST_TIME
		var pulse := pow(maxf(sin(_phase * 2.0 * PI * 13.0), 0.0), 2.0)
		var amp := 1.0 if _shift_up else 1.25
		weak += 0.34 * amp * e * pulse
		strong += 0.46 * amp * e * pulse

	# 贴墙刮擦
	if _scrape_t > 0.0:
		var e := _scrape_t / SCRAPE_TIME
		var buzz := 0.55 + 0.45 * sin(_phase * 140.0)
		weak += _scrape_amp * e * buzz * 0.85
		strong += _scrape_amp * e * 0.30

	# 碰撞：最大震动、长衰减
	if _impact_t > 0.0:
		var e := clampf(_impact_t / maxf(_impact_dur, 0.01), 0.0, 1.0)
		var decay := e * e
		weak += 1.00 * _impact_amp * decay
		strong += 1.00 * _impact_amp * decay

	# 松手即停：没有任何驾驶动作/事件时包络直接清零，不留「松手还震一秒」的尾巴。
	if target_level == 0 and _shift_burst <= 0.0 and _impact_t <= 0.0 and _scrape_t <= 0.0:
		_amp_weak = 0.0
		_amp_strong = 0.0
	else:
		# 档位跳变平滑（升档快、回落稍慢）。只平滑包络，节奏门留到输出级乘。
		var rise := 18.0
		var fall := 5.5
		var k_w := 1.0 - exp(-(rise if weak > _amp_weak else fall) * dt)
		var k_s := 1.0 - exp(-(rise if strong > _amp_strong else fall) * dt)
		_amp_weak = lerpf(_amp_weak, clampf(weak * intensity, 0.0, 1.0), k_w)
		_amp_strong = lerpf(_amp_strong, clampf(strong * intensity, 0.0, 1.0), k_s)
	level = target_level
	_apply(dt)


## 节奏门：占空比方波（0/1）。hz=每秒几次，duty=每次震多久比例。
func _square(hz: float, duty: float) -> float:
	return 1.0 if fposmod(_phase * hz, 1.0) < duty else 0.0


## 判定当前该处于哪一档。完全按「驾驶动作」分档，不看绝对速度。
func _drive_level(dt: float, car) -> int:
	var speed := absf(car.speed_kph)
	var speed_fwd := float(car.speed_forward)
	var throttle := clampf(float(car.throttle), -1.0, 1.0)
	var accel_now := 0.0
	if dt > 0.0001:
		accel_now = (speed_fwd - _last_speed_fwd) / dt
	_last_speed_fwd = speed_fwd
	# 纵向加速度平滑：加速为正、刹车为负
	_accel_smooth = lerpf(_accel_smooth, accel_now, 1.0 - exp(-11.0 * dt))

	var stationary: bool = speed < 1.0 and absf(throttle) < 0.04 and not bool(car.handbrake)
	if stationary:
		_last_brake = false
		_last_drift = false
		return 0

	# ---- 漂移 / 手刹甩尾：最明显 ----
	var slip01 := clampf(absf(car.lat_slip) / 9.0, 0.0, 1.0)
	var drift_now: bool = (bool(car.drift_active) or bool(car.handbrake) or slip01 > 0.26) \
		and speed > 12.0
	if drift_now and not _last_drift:
		_drift_entry = 0.16
	_last_drift = drift_now
	if drift_now:
		_last_brake = true
		return 5

	# ---- 刹车：看踏板深度分「轻点」和「踩死」 ----
	var brake_cmd := maxf(0.0, -throttle)
	var braking_now: bool = bool(car.braking) and speed > 3.0
	# 倒车时负油门是油门，不算刹车
	if speed_fwd < -1.0 and throttle < 0.0:
		braking_now = false
	if braking_now:
		if not _last_brake:
			_brake_entry = 0.12
		_last_brake = true
		if brake_cmd >= 0.62 or _accel_smooth < -8.0:
			return 4
		if brake_cmd >= 0.30:
			return 2
		return 1
	_last_brake = false

	# ---- 加速：全油门起步最强，随加速衰减而变小 ----
	if throttle > 0.04 and speed_fwd > -0.5:
		var pull := maxf(_accel_smooth, 0.0)
		# 起步 0~100：全油门直接给 DRIVE；轻油门按踏板深度降档
		if speed < 28.0 and throttle > 0.55:
			return 3
		# 满油门保持中等偏上（即使已经到巡航速度）；松到一半逐渐变小
		if throttle >= 0.85:
			return 3
		if pull > 4.0:
			return 3
		if throttle >= 0.45 or pull > 1.6:
			return 2
		if pull > 0.35 or throttle >= 0.20:
			return 1
		return 0

	# ---- 倒车给一点轻震 ----
	if speed_fwd < -1.0 and throttle < -0.04:
		return 2

	# ---- 匀速巡航 / 收油滑行：完全停震 ----
	return 0


func _apply(dt: float) -> void:
	_tick += dt
	if _tick < TICK:
		return
	_tick = 0.0
	# 输出级乘节奏门：包络已被平滑，这里保留方波的开/关沿，
	# 开关式马达靠「震几下/停几下」分辨力度。
	var out_w := _amp_weak * _gate_w
	var out_s := _amp_strong * _gate_s
	if out_w <= 0.02 and out_s <= 0.02:
		if _vibrating:
			_vibrating = false
			if device >= 0:
				Input.stop_joy_vibration(device)
		return
	_vibrating = true
	# 每 TICK 重发一次：start_joy_vibration 的 PULSE 会到期，
	# 不重发的话恒定强度震动会在 0.1s 后自己停掉。
	Input.start_joy_vibration(device, out_w, out_s, PULSE)


func _stop_vibration() -> void:
	_vibrating = false
	_last_weak = 0.0
	_last_strong = 0.0
	_amp_weak = 0.0
	_amp_strong = 0.0
	if device >= 0:
		Input.stop_joy_vibration(device)


func stop() -> void:
	_shift_burst = 0.0
	_impact_t = 0.0
	_scrape_t = 0.0
	_brake_entry = 0.0
	_drift_entry = 0.0
	_last_brake = false
	_last_drift = false
	_last_speed_fwd = 0.0
	_accel_smooth = 0.0
	level = 0
	_stop_vibration()
