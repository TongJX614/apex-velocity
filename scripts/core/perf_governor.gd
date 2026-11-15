class_name PerfGovernor
extends RefCounted
## 动态分辨率守门员：比赛帧时间持续超预算就降一档 3D 渲染比例。
## 只降不升（换档本身会卡一下），按赛道记住上次稳定档位。
## 从 main.gd 拆出：状态与决策全部在这里，宿主只提供 viewport / 比赛状态 / 后期同步。

const STATE_PATH := "user://perf_state.json"

var scale := 1.0
var cap := 1.0

var _timer := 0.0
var _samples: Array[float] = []
var _warmup := 0.0
var _last_good := 0.0
var _key := ""
var _saved_scale := 0.0
var _saved_key := ""
var _saved_tracks: Dictionary = {}
var _saved_headroom := false
var _save_ms := 0
var _tracks: Dictionary = {}
var _headroom := false
var _fast_streak := 0
var _slow_streak := 0

var _main: Node3D


func setup(main: Node3D) -> void:
	_main = main
	_load_state()


func state_key() -> String:
	return "%d|%s|%dx%d|%.2f" % [Settings.index, Settings.window_mode,
		Settings.window_width, Settings.window_height, Settings.render_scale]


## 入场只有 3 秒调速窗口，跨会话记住上次稳定比例，下一场直接从正确预算起跑。
## tracks 按赛道各自收敛：重赛道降下来的档位不会连累轻赛道。
func _load_state() -> void:
	if not FileAccess.file_exists(STATE_PATH):
		return
	var f := FileAccess.open(STATE_PATH, FileAccess.READ)
	if f == null:
		return
	var data: Variant = JSON.parse_string(f.get_as_text())
	if data is Dictionary:
		_key = String(data.get("key", ""))
		_last_good = clampf(float(data.get("scale", 0.0)), 0.0, 1.0)
		_headroom = bool(data.get("headroom", false))
		var tracks: Variant = data.get("tracks", {})
		if tracks is Dictionary:
			for k in tracks:
				_tracks[String(k)] = clampf(float(tracks[k]), 0.0, 1.0)


func _save_state() -> void:
	var now := Time.get_ticks_msec()
	if now - _save_ms < 4000:
		return
	if absf(_last_good - _saved_scale) < 0.005 and _key == _saved_key \
			and _tracks == _saved_tracks and _headroom == _saved_headroom:
		return
	_save_ms = now
	_saved_scale = _last_good
	_saved_key = _key
	_saved_tracks = _tracks.duplicate()
	_saved_headroom = _headroom
	var f := FileAccess.open(STATE_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({
			"key": _saved_key,
			"scale": _saved_scale,
			"tracks": _saved_tracks,
			"headroom": _saved_headroom,
		}))


## 进赛时恢复这条赛道上次的稳定档位；调用点在加载遮罩内，
## 换档引起的管线重建卡顿藏在遮罩后面看不到。
## allow_raise：上一场全程宽裕时，借遮罩把档位升一小格自动纠偏。
func apply_saved_scale(allow_raise := false) -> void:
	if _main._perf_mode or cap <= 0.0:
		return
	if _key != state_key():
		return
	var saved := _last_good
	if _tracks.has(_main.current_track_id):
		saved = float(_tracks[_main.current_track_id])
	if saved <= 0.0:
		return
	if allow_raise and _headroom:
		saved = minf(saved * 1.12, cap)
	scale = clampf(saved, 0.32, cap)
	var vp := _main.get_viewport()
	if vp != null:
		vp.scaling_3d_scale = scale
	_timer = 0.0
	_samples.clear()
	_warmup = 0.75
	_fast_streak = 0
	_slow_streak = 0
	_main._sync_post_params()


## 画质切换：重置预算上限；画质/显示配置变了就作废旧预算，
## 别拿旧配置的档位套新配置。
func reset_for_quality(new_cap: float, vp: Viewport) -> void:
	cap = new_cap
	scale = new_cap
	if _key != state_key():
		_key = state_key()
		_last_good = 0.0
		_tracks.clear()
	vp.scaling_3d_scale = scale
	_timer = 0.0
	_samples.clear()
	_warmup = 0.75
	_fast_streak = 0
	_slow_streak = 0


func tick(dt: float) -> void:
	if OS.get_environment("APEX_GOV_LOCK") == "1":
		return
	if _main.state != _main.AppState.RACE or _main.race == null or _main.car == null:
		return
	if _main.race.state == RaceManager.State.RESULTS:
		return
	if _main.get_tree().paused or _main.loading_screen != null:
		return
	if _warmup > 0.0:
		_warmup = maxf(_warmup - dt, 0.0)
		return
	if dt <= 0.0 or dt > 0.25:
		return
	_timer += dt
	_samples.append(dt)
	if _timer < 1.0:
		return
	var samples := _samples.duplicate()
	_samples.clear()
	_timer = 0.0
	samples.sort()
	# 去掉最慢的 10%：一次性着色器编译 / 资源上传的长帧不该把整场分辨率压低。
	var cut := maxi(int(samples.size() * 0.9), 1)
	var frame := 0.0
	for i in cut:
		frame += float(samples[i])
	frame /= float(cut)
	var slow := 0
	for s in samples:
		if s > 0.025:
			slow += 1
	var slow_ratio := float(slow) / float(maxi(samples.size(), 1))
	var vp := _main.get_viewport()
	if vp == null:
		return
	if OS.get_environment("APEX_GOV_LOG") == "1" or OS.get_environment("APEX_PERF_OVERRIDE") == "1":
		print("[GOV] frame %.1f ms  slow %.0f%%  scale %.2f/%.2f" % [
			frame * 1000.0, slow_ratio * 100.0, scale, cap])
	# 只降不升：改 scaling_3d_scale 会让 Metal 重建升频/后期管线，实测每次
	# 调整后约 300ms 必出现一对 40~70ms 长帧，比稍软的画面更伤手感。
	# 60fps 的正常波动（16~17ms）不算掉帧；必须连续两个窗口都超预算才降，
	# 避免一次编译/流加载长帧把分辨率误降。轻微超预算用小步，别一次砍太多。
	var over := frame > 0.0185 or slow_ratio > 0.12
	if over:
		_slow_streak += 1
	else:
		_slow_streak = 0
	if over and _slow_streak >= 2:
		var factor := 0.92
		if frame > 0.026:
			factor = 0.78
		elif frame > 0.021:
			factor = 0.85
		var next := maxf(scale * factor, 0.32)
		if next < scale - 0.012:
			scale = next
			vp.scaling_3d_scale = scale
			_warmup = 2.0
			_main._sync_post_params()
			_fast_streak = 0
			_headroom = false
			_slow_streak = 0
			print("[GOV] frame %.1f ms → scale %.2f" % [frame * 1000.0, scale])
		return
	# 连续 3 个窗口 <13ms：这台机器在这条赛道上还有一大截余量，
	# 记录给下一场进场时在遮罩后面自动升档。
	if frame < 0.013:
		_fast_streak += 1
	else:
		_fast_streak = 0
	_headroom = _fast_streak >= 3
	_last_good = maxf(_last_good, scale)
	_tracks[_main.current_track_id] = scale
	_key = state_key()
	_save_state()