class_name InputSetup
extends RefCounted
## 运行时注册驾驶输入映射（项目不把 InputMap 写进 project.godot）。
## 键盘 + 手柄：左摇杆转向、LT/RT 刹车/油门、肩键升降挡、
## A 漂移（手刹）、X 氮气、B 切相机、Y 手动/自动挡、START 暂停/返回。
## 十字键（D-pad）不绑定任何功能。菜单：左摇杆导航，A 确认，START 返回。
## 所有驾驶动作都由 main.gd 的 read_drive_input() 汇总成车辆输入字典。

const KEY_ACTIONS := {
	"throttle": [KEY_W, KEY_UP],
	"brake": [KEY_S, KEY_DOWN],
	"steer_left": [KEY_A, KEY_LEFT],
	"steer_right": [KEY_D, KEY_RIGHT],
	"handbrake": [KEY_SPACE],
	"nitro": [KEY_SHIFT],
	"shift_up": [KEY_E],
	"shift_down": [KEY_Q],
	"manual_toggle": [KEY_T],
	"reset_car": [KEY_R],
	"camera_mode": [KEY_C],
}

const JOY_BUTTON_ACTIONS := {
	"handbrake": [JOY_BUTTON_A],          # A = 漂移/手刹
	"nitro": [JOY_BUTTON_X],              # X = 氮气
	"shift_up": [JOY_BUTTON_RIGHT_SHOULDER],
	"shift_down": [JOY_BUTTON_LEFT_SHOULDER],
	"manual_toggle": [JOY_BUTTON_Y],
	"camera_mode": [JOY_BUTTON_B],
	"reset_car": [JOY_BUTTON_BACK],       # Back/Select（Switch 的 - 键）= 复位
}

const STICK_DEADZONE := 0.14
const TRIGGER_DEADZONE := 0.06

# 数字扳机整形：多数手柄（含组装柄）的 RT/LT 只有 0/1 两档，直接读会
# 「油门永远全开/全关」。这里把数字扳机爬升成 ~0.2s 的斜坡当模拟量用；
# 真模拟量扳机（连续中间值）与磁轴键盘覆盖不受影响。
const TRIG_THROTTLE := 0
const TRIG_BRAKE := 1
const TRIG_DIGITAL_EPS := 0.02
const TRIG_RISE := 5.0             # 0→1 约 0.2s
const TRIG_FALL := 10.0            # 松开约 0.1s
static var _trig_ramp: Array[float] = [0.0, 0.0]
static var _trig_last_ms := 0


static func _trig_frame_dt() -> float:
	var now := Time.get_ticks_msec()
	var dt := clampf(float(now - _trig_last_ms) / 1000.0, 0.001, 0.1)
	_trig_last_ms = now
	return dt


static func _shape_trigger(idx: int, raw: float, dt: float) -> float:
	if raw <= TRIG_DIGITAL_EPS or raw >= 1.0 - TRIG_DIGITAL_EPS:
		var target := 1.0 if raw >= 0.5 else 0.0
		var rate := TRIG_RISE if target > _trig_ramp[idx] else TRIG_FALL
		_trig_ramp[idx] = move_toward(_trig_ramp[idx], target, rate * dt)
	else:
		_trig_ramp[idx] = raw
	return _trig_ramp[idx]

## 最近一次输入来自哪个设备：界面提示据此显示手柄按键或键盘键位。
static var last_input_was_joy := false


static func note_input(event: InputEvent) -> void:
	if event is InputEventJoypadButton or event is InputEventJoypadMotion:
		last_input_was_joy = true
	elif event is InputEventKey or event is InputEventMouseButton:
		last_input_was_joy = false

static var _actions_ready := false


static func ensure_actions() -> void:
	if _actions_ready:
		return
	_actions_ready = true
	for action in KEY_ACTIONS:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		for key in KEY_ACTIONS[action]:
			var ev := InputEventKey.new()
			ev.physical_keycode = key
			if not _has_key_event(action, key):
				InputMap.action_add_event(action, ev)
	for action in JOY_BUTTON_ACTIONS:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		for button in JOY_BUTTON_ACTIONS[action]:
			_add_joy_button(action, button)
	ensure_ui_actions()


## 菜单/界面导航：左摇杆，A 确认，START（菜单键）返回。
## 十字键不参与导航，B 不再返回（B 在驾驶中切相机）。
## Godot 内置 ui_* 默认带手柄按键，这里先清掉再按新方案注册。
static var _ui_ready := false

static func ensure_ui_actions() -> void:
	if _ui_ready:
		return
	_ui_ready = true
	var dpad := [JOY_BUTTON_DPAD_UP, JOY_BUTTON_DPAD_DOWN, JOY_BUTTON_DPAD_LEFT, JOY_BUTTON_DPAD_RIGHT]
	for action in ["ui_up", "ui_down", "ui_left", "ui_right", "ui_accept", "ui_cancel"]:
		_remove_joy_button(action, JOY_BUTTON_B)
		for button in dpad:
			_remove_joy_button(action, button)
	_add_joy_button("ui_accept", JOY_BUTTON_A)
	_add_joy_button("ui_cancel", JOY_BUTTON_START)
	_add_joy_axis("ui_up", JOY_AXIS_LEFT_Y, -1.0)
	_add_joy_axis("ui_down", JOY_AXIS_LEFT_Y, 1.0)
	_add_joy_axis("ui_left", JOY_AXIS_LEFT_X, -1.0)
	_add_joy_axis("ui_right", JOY_AXIS_LEFT_X, 1.0)


static func _remove_joy_button(action: String, button: JoyButton) -> void:
	if not InputMap.has_action(action):
		return
	for ev in InputMap.action_get_events(action):
		if ev is InputEventJoypadButton and (ev as InputEventJoypadButton).button_index == button:
			InputMap.action_erase_event(action, ev)


static func _add_joy_button(action: String, button: JoyButton) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	if _has_joy_button(action, button):
		return
	var ev := InputEventJoypadButton.new()
	ev.button_index = button
	InputMap.action_add_event(action, ev)


static func _add_joy_axis(action: String, axis: JoyAxis, value: float) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	for ev in InputMap.action_get_events(action):
		if ev is InputEventJoypadMotion:
			var motion := ev as InputEventJoypadMotion
			if motion.axis == axis and signf(motion.axis_value) == signf(value):
				return
	var ev := InputEventJoypadMotion.new()
	ev.axis = axis
	ev.axis_value = value
	InputMap.action_add_event(action, ev)


static func _has_key_event(action: String, key: Key) -> bool:
	for ev in InputMap.action_get_events(action):
		if ev is InputEventKey and (ev as InputEventKey).physical_keycode == key:
			return true
	return false


static func _has_joy_button(action: String, button: JoyButton) -> bool:
	for ev in InputMap.action_get_events(action):
		if ev is InputEventJoypadButton and (ev as InputEventJoypadButton).button_index == button:
			return true
	return false



const DUEL_KEYS := {
	"p1_steer_left": [KEY_LEFT], "p1_steer_right": [KEY_RIGHT],
	"p1_throttle": [KEY_UP], "p1_brake": [KEY_DOWN],
	"p1_handbrake": [KEY_SPACE], "p1_nitro": [KEY_SHIFT],
	"p1_shift_up": [KEY_E], "p1_shift_down": [KEY_Q], "p1_manual": [KEY_T],
	"p2_steer_left": [KEY_A], "p2_steer_right": [KEY_D],
	"p2_throttle": [KEY_W], "p2_brake": [KEY_S],
	"p2_handbrake": [KEY_K], "p2_nitro": [KEY_L],
	"p2_shift_up": [KEY_O], "p2_shift_down": [KEY_P], "p2_manual": [KEY_I],
}

static var _duel_ready := false


static func ensure_duel_actions() -> void:
	if _duel_ready:
		return
	_duel_ready = true
	for action in DUEL_KEYS:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		for key in DUEL_KEYS[action]:
			var ev := InputEventKey.new()
			ev.physical_keycode = key
			InputMap.action_add_event(action, ev)


## 本地双人输入：player 0 = P1（方向键 + 空格/Shift），player 1 = P2（WASD + K/L）。
static func read_duel_input(player: int) -> Dictionary:
	ensure_duel_actions()
	var p := "p1_" if player == 0 else "p2_"
	var steer := 0.0
	if Input.is_action_pressed(p + "steer_left"):
		steer -= 1.0
	if Input.is_action_pressed(p + "steer_right"):
		steer += 1.0
	var throttle := 0.0
	if Input.is_action_pressed(p + "throttle"):
		throttle += 1.0
	if Input.is_action_pressed(p + "brake"):
		throttle -= 1.0
	return {
		"steer": steer,
		"throttle": throttle,
		"handbrake": Input.is_action_pressed(p + "handbrake"),
		"nitro": Input.is_action_pressed(p + "nitro"),
		"shift_up": Input.is_action_just_pressed(p + "shift_up"),
		"shift_down": Input.is_action_just_pressed(p + "shift_down"),
		"manual_toggle": Input.is_action_just_pressed(p + "manual"),
		"reverse_pressed": Input.is_action_just_pressed(p + "brake"),
	}

static func _primary_joypad() -> int:
	var pads := Input.get_connected_joypads()
	return int(pads[0]) if pads.size() > 0 else -1


## 汇总一帧的驾驶输入：
##   · 键盘：0/1 数字量（普通薄膜键盘，一切照旧）；
##   · 手柄：左摇杆/扳机模拟量；
##   · 模拟键盘（磁轴 HID 桥接）：按 Settings.analog_* 曲线把「按键深度」映射成
##     转向角/油门开度；没接设备或超时未收到数据时自动回退数字输入。
static func read_drive_input() -> Dictionary:
	var steer := 0.0
	if Input.is_action_pressed("steer_left"):
		steer -= 1.0
	if Input.is_action_pressed("steer_right"):
		steer += 1.0
	var throttle := 0.0
	if Input.is_action_pressed("throttle"):
		throttle += 1.0
	if Input.is_action_pressed("brake"):
		throttle -= 1.0
	var hb := Input.is_action_pressed("handbrake")
	var nitro := Input.is_action_pressed("nitro")
	var device := _primary_joypad()
	var tdt := _trig_frame_dt()
	if device >= 0:
		var stick := Input.get_joy_axis(device, JOY_AXIS_LEFT_X)
		if absf(stick) > STICK_DEADZONE:
			steer = clampf(steer + stick, -1.0, 1.0)
		var rt := _shape_trigger(TRIG_THROTTLE, Input.get_joy_axis(device, JOY_AXIS_TRIGGER_RIGHT), tdt)
		var lt := _shape_trigger(TRIG_BRAKE, Input.get_joy_axis(device, JOY_AXIS_TRIGGER_LEFT), tdt)
		if rt > TRIGGER_DEADZONE:
			throttle = clampf(throttle + rt, -1.0, 1.0)
		if lt > TRIGGER_DEADZONE:
			throttle = clampf(throttle - lt, -1.0, 1.0)
	# 模拟键盘/桥接深度：活跃时覆盖数字量（含死区 + 曲线）
	var analog_on: bool = bool(Settings.analog_input_enabled) if Settings != null else true
	var analog_port: int = int(Settings.analog_udp_port) if Settings != null else AnalogInput.DEFAULT_PORT
	# 不能因为接了手柄就关掉模拟键盘：磁轴键盘经常和手柄同时在线，
	# 旧逻辑 `analog_on and device < 0` 会把手柄玩家（包括测试机）的模拟输入整条掐掉。
	var st: Dictionary = AnalogInput.poll(analog_port, analog_on)
	if bool(st.get("active", false)):
		var dz: float = clampf(float(Settings.analog_deadzone), 0.0, 0.6) if Settings != null else 0.03
		var curve_s: float = clampf(float(Settings.analog_curve_steer), 0.6, 3.0) if Settings != null else 1.35
		var curve_t: float = clampf(float(Settings.analog_curve_throttle), 0.6, 3.0) if Settings != null else 1.15
		steer = AnalogInput.map_steer(float(st.get("steer", 0.0)), dz, curve_s)
		throttle = AnalogInput.map_throttle(float(st.get("throttle", 0.0)), curve_t)
	if device >= 0:
		_joy_debug_log(device, steer, throttle, bool(st.get("active", false)))
	return {
		"steer": steer,
		"throttle": throttle,
		"handbrake": hb,
		"nitro": nitro,
		"shift_up": Input.is_action_just_pressed("shift_up"),
		"shift_down": Input.is_action_just_pressed("shift_down"),
		"manual_toggle": Input.is_action_just_pressed("manual_toggle"),
		"reverse_pressed": Input.is_action_just_pressed("brake"),
	}


## 临时诊断：/tmp/apex_joy_debug.on 存在时，每 0.4s 记录手柄原始轴/按键，
## 用于定位「摇杆/扳机无反应」到底是映射问题还是覆盖问题。排查完删除标记文件即停。
static var _joy_dbg_last_ms := 0

static func _joy_debug_log(device: int, steer: float, throttle: float, analog_active: bool) -> void:
	if not FileAccess.file_exists("/tmp/apex_joy_debug.on"):
		return
	var now := Time.get_ticks_msec()
	if now - _joy_dbg_last_ms < 400:
		return
	_joy_dbg_last_ms = now
	var btns: Array[int] = []
	for b in range(21):
		if Input.is_joy_button_pressed(device, b):
			btns.append(b)
	var axes: Array[float] = []
	for a in range(6):
		axes.append(Input.get_joy_axis(device, a))
	var line := "[%s] %s axes=%s btns=%s analogOverride=%s => steer=%.3f throttle=%.3f\n" % [
		Time.get_time_string_from_system(), Input.get_joy_name(device),
		str(axes), str(btns), str(analog_active), steer, throttle]
	var f := FileAccess.open("/tmp/apex_joy_debug.log", FileAccess.READ_WRITE)
	if f == null:
		f = FileAccess.open("/tmp/apex_joy_debug.log", FileAccess.WRITE)
	if f != null:
		f.seek_end()
		f.store_string(line)
		f.close()
