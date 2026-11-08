class_name AnalogInput
extends RefCounted
## 模拟输入源（磁轴键盘 / 厂商模拟手柄软件 / 自定义 HID 桥接）：
##   · 普通键盘：正常数字输入，不受影响；
##   · 模拟设备：外部程序按固定协议把「按键深度/模拟量」通过本机 UDP 发给游戏，
##     游戏把 depth 映射成转向角与油门开度（0..1 连续量），实现「按多深给多少」。
##
## UDP 协议（默认 127.0.0.1:48255，可在 Settings 改端口）：
##   每个包一行/一个 JSON，任选其一：
##     "0.42,0.86"                       → steer, throttle（-1..1 / 0..1）
##     "s=0.42;t=0.86"
##     {"steer":0.42,"throttle":0.86}
##   频率建议 ≥120Hz；超过 STALE_MS 没收到就回退到键盘/手柄数字输入。
##
## 桥接参考实现：tools/analog_input/analog_bridge.py（含 --test 模拟器）。

const DEFAULT_PORT := 48255
const STALE_MS := 380

static var _udp: PacketPeerUDP = null
static var _udp_error := ""
static var _last_packet_ms := -1
static var _raw_steer := 0.0
static var _raw_throttle := 0.0
static var _raw_brake := 0.0
static var _packets := 0
static var _debug_steer := INF
static var _debug_throttle := INF
static var _last_poll_ms := 0

static var _smooth_steer := 0.0
static var _smooth_throttle := 0.0


static func _ensure_socket(port: int) -> void:
	if _udp != null:
		if _udp.get_local_port() == port:
			return
		_udp.close()
		_udp = null
	_udp = PacketPeerUDP.new()
	var err := _udp.bind(port, "127.0.0.1")
	if err != OK:
		_udp_error = "UDP bind %d failed (%d)" % [port, err]
		_udp = null
		return
	_udp.set_dest_address("127.0.0.1", port)
	_udp_error = ""


## 测试/调试：直接注入模拟量（INF = 关闭注入）
static func set_debug_values(steer: float, throttle: float) -> void:
	_debug_steer = steer
	_debug_throttle = throttle


static func clear_debug_values() -> void:
	_debug_steer = INF
	_debug_throttle = INF


static func _now_ms() -> int:
	return int(Time.get_ticks_msec())


static func _parse_packet(text: String) -> void:
	var t := text.strip_edges()
	if t.is_empty():
		return
	if t.begins_with("{"):
		var parsed: Variant = JSON.parse_string(t)
		if parsed is Dictionary:
			var d: Dictionary = parsed
			_raw_steer = clampf(_as_float(d.get("steer", _raw_steer)), -1.0, 1.0)
			_raw_throttle = clampf(_as_float(d.get("throttle", _raw_throttle)), 0.0, 1.0)
			_raw_brake = clampf(_as_float(d.get("brake", _raw_brake)), 0.0, 1.0)
			_last_packet_ms = _now_ms()
			_packets += 1
		return
	var steer := _raw_steer
	var throttle := _raw_throttle
	var brake := _raw_brake
	var got := false
	var segments := t.replace(";", ",").split(",", false)
	# 形式 A："0.4,0.8" / "0.4,0.8,0.0"（steer,throttle[,brake]）
	# 形式 B："s=0.4;t=0.8" / "steer=0.4;throttle=0.8"
	var has_kv := false
	for seg in segments:
		if seg.contains("="):
			has_kv = true
			break
	if has_kv:
		for seg in segments:
			var kv := seg.split("=", false)
			if kv.size() != 2:
				continue
			var name := kv[0].strip_edges().to_lower()
			var value := _as_float(kv[1].strip_edges())
			if name.begins_with("b"):
				brake = value
				got = true
			elif name.begins_with("s"):
				steer = value
				got = true
			elif name.begins_with("t"):
				throttle = value
				got = true
	elif segments.size() >= 2:
		steer = _as_float(segments[0].strip_edges())
		throttle = _as_float(segments[1].strip_edges())
		if segments.size() >= 3:
			brake = _as_float(segments[2].strip_edges())
		got = true
	if got:
		_raw_steer = clampf(steer, -1.0, 1.0)
		_raw_throttle = clampf(throttle, 0.0, 1.0)
		_raw_brake = clampf(brake, 0.0, 1.0)
		_last_packet_ms = _now_ms()
		_packets += 1
		_last_packet_ms = _now_ms()
		_packets += 1


static func _as_float(v: Variant) -> float:
	if v == null:
		return 0.0
	if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
		return float(v)
	return float(String(v))


## 每帧调用：收包 + 平滑。返回 {active, steer, throttle, packets, error}
static func poll(port: int, enabled: bool) -> Dictionary:
	var now := _now_ms()
	var dt := clampf(float(now - _last_poll_ms) / 1000.0, 0.001, 0.10) if _last_poll_ms > 0 else 0.016
	_last_poll_ms = now
	if not enabled:
		_smooth_steer = 0.0
		_smooth_throttle = 0.0
		return {"active": false, "steer": 0.0, "throttle": 0.0, "packets": _packets, "error": ""}
	var debug := _debug_steer != INF
	if debug:
		_raw_steer = clampf(_debug_steer, -1.0, 1.0)
		_raw_throttle = clampf(_debug_throttle, 0.0, 1.0)
		_last_packet_ms = now
	else:
		_ensure_socket(port)
		if _udp != null:
			while _udp.get_available_packet_count() > 0:
				var pkt := _udp.get_packet()
				if pkt.size() > 0 and pkt.size() < 512:
					_parse_packet(pkt.get_string_from_utf8())
	var active := _udp_error.is_empty() and _last_packet_ms >= 0 and (now - _last_packet_ms) <= STALE_MS
	if not active:
		_smooth_steer = 0.0
		_smooth_throttle = 0.0
		return {"active": false, "steer": 0.0, "throttle": 0.0, "packets": _packets, "error": _udp_error}
	# 轻微平滑，避免 HID 抖动直接传到方向盘（约 25ms 时间常数）
	var k := 1.0 - exp(-dt * 40.0)
	_smooth_steer = lerpf(_smooth_steer, _raw_steer, k)
	_smooth_throttle = lerpf(_smooth_throttle, _raw_throttle, k)
	return {
		"active": true,
		"steer": _smooth_steer,
		"throttle": clampf(_smooth_throttle - _raw_brake, -1.0, 1.0),
		"packets": _packets,
		"error": _udp_error,
	}


## 按键深度 → 转向角：死区 + 幂曲线（|raw|<=dz 归零，其余归一化后按 curve 弯曲）
static func map_steer(raw: float, deadzone: float, curve: float) -> float:
	var v := clampf(raw, -1.0, 1.0)
	var mag := absf(v)
	if mag <= deadzone:
		return 0.0
	mag = (mag - deadzone) / maxf(1.0 - deadzone, 0.001)
	return signf(v) * pow(clampf(mag, 0.0, 1.0), clampf(curve, 0.6, 3.0))


## 按键深度 → 油门开度：0..1 幂曲线（负值视为刹车）
static func map_throttle(raw: float, curve: float) -> float:
	var v := clampf(raw, -1.0, 1.0)
	if absf(v) < 0.001:
		return 0.0
	return signf(v) * pow(absf(v), clampf(curve, 0.6, 3.0))


## 自检（给 --verify / 调试用）：解析、映射、调试注入三条路径
static func self_test() -> String:
	# 1) 解析 "s=0.4;t=0.8" 与 JSON
	_raw_steer = 0.0
	_raw_throttle = 0.0
	_raw_brake = 0.0
	_parse_packet("s=0.4;t=0.8")
	if absf(_raw_steer - 0.4) > 0.01 or absf(_raw_throttle - 0.8) > 0.01:
		return "parse text failed (%.2f, %.2f)" % [_raw_steer, _raw_throttle]
	_parse_packet("{\"steer\":-0.6,\"throttle\":0.25,\"brake\":0.1}")
	if absf(_raw_steer + 0.6) > 0.01 or absf(_raw_throttle - 0.25) > 0.01:
		return "parse json failed (%.2f, %.2f)" % [_raw_steer, _raw_throttle]
	# 2) 映射曲线
	if absf(map_steer(0.5, 0.0, 1.0) - 0.5) > 0.001:
		return "map_steer linear failed"
	if absf(map_steer(0.1, 0.2, 1.0)) > 0.001:
		return "map_steer deadzone failed"
	if absf(map_steer(0.5, 0.0, 1.35) - 0.3922) > 0.01:
		return "map_steer curve failed (%.3f)" % map_steer(0.5, 0.0, 1.35)
	if absf(map_throttle(0.75, 1.15) - 0.7176) > 0.01:
		return "map_throttle curve failed (%.3f)" % map_throttle(0.75, 1.15)
	# 3) 调试注入 → active
	set_debug_values(0.5, 0.75)
	var st := poll(DEFAULT_PORT, true)
	clear_debug_values()
	if not bool(st.get("active", false)):
		return "debug injection not active"
	status_text(DEFAULT_PORT)
	clear_debug_values()
	return ""


static func status_text(port: int) -> String:
	if not _udp_error.is_empty():
		return "模拟输入: 不可用（%s）" % _udp_error
	var age := _now_ms() - _last_packet_ms
	if age <= STALE_MS:
		return "模拟输入: 已连接（%d 包）" % _packets
	return "模拟输入: 等待设备（UDP %d）" % port
