extends Node
## 诊断：不启动整场比赛，只验证「ACE68 桥 → UDP → 游戏 AnalogInput」这条链路。
## 用法（先运行桥，再运行本场景；或反过来由脚本同时启动）：
##   Godot --headless --path . res://tools/analog_input/analog_probe.tscn -- --port=48255 --seconds=6
## 退出码 0 = 收到包且 active；2 = 没收到。

var port := 48255
var seconds := 6.0
var elapsed := 0.0
var last_log := -1
var packets := 0
var active := false
var ever_active := false


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--port="):
			port = int(arg.substr(7))
		elif arg.begins_with("--seconds="):
			seconds = float(arg.substr(10))
	print("[ANALOG-PROBE] 监听 UDP %d，时长 %.1fs" % [port, seconds])


func _process(dt: float) -> void:
	elapsed += dt
	var st := AnalogInput.poll(port, true)
	packets = int(st.get("packets", 0))
	active = bool(st.get("active", false))
	if active and packets > 0:
		ever_active = true
	var slot := int(elapsed * 2.0)
	if slot != last_log:
		last_log = slot
		print("[ANALOG-PROBE] t=%.1f active=%s packets=%d steer=%.3f throttle=%.3f" % [
			elapsed, str(active), packets,
			AnalogInput.map_steer(float(st.get("steer", 0.0)), 0.0, 1.0),
			AnalogInput.map_throttle(float(st.get("throttle", 0.0)), 1.0)])
	if elapsed >= seconds:
		print("[ANALOG-PROBE] DONE ever_active=%s packets=%d" % [str(ever_active), packets])
		get_tree().quit(0 if ever_active else 2)
