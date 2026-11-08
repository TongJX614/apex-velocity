extends Node3D
## APEX VELOCITY · 极速巅峰 — Godot remake entry point.
##
## M1: menu (8 circuits / 45 cars / GP + time trial), race manager with 3 AI
## rivals, lap timing, medals, records, minimap, three cameras.
## Verification modes:
##   --verify                    headless smoke + full-race simulation
##   --shot=<png> [--shot-scene=menu|race|results] [--track=..] [--car=..]
##                               render a frame to PNG and quit

enum AppState { MENU, RACE, GARAGE }

const DEFAULT_TRACK := "coast"
const DEFAULT_CAR := "bmw_m3_e46_gtr"
const COUNTDOWN_INPUT := {
	"steer": 0.0, "throttle": 0.0, "handbrake": true, "nitro": false, "reverse_pressed": false,
}

const FrustumStreamer := preload("res://scripts/core/frustum_streamer.gd")
const PlatformProfile := preload("res://scripts/core/platform_profile.gd")
const GhostStore := preload("res://scripts/core/ghost_store.gd")

var state := AppState.MENU

var menu: Menu
var race_root: Node3D
var track_path: TrackPath
var track_def: Dictionary = {}
var current_track_id := DEFAULT_TRACK
var current_car_id := DEFAULT_CAR
var current_mode := "gp"

var car: Car
var ais: Array[AICar] = []
var cam: ChaseCamera
var hud: RaceHUD
var race: RaceManager
var audio: AudioManager
var garage_world: GarageWorld
var weather: WeatherFX
var _venue_stats: Dictionary = {}
var _env: Environment
var _sun: DirectionalLight3D
var _volumetric_allowed := false
var settings_screen: SettingsScreen
var streamer
var _last_blur_amount := 0.0
var _base_fog_density := 0.0008
var _base_vol_density := 0.0016
var _base_fog_color := Color(0.7, 0.78, 0.85)
var menu_world: Node3D
var menu_stage_viewport: SubViewport
var menu_decor_lights: Array[Node3D] = []
var menu_env_backup: Dictionary = {}
var intro_cam: Camera3D
var intro_t := 0.0
var intro_from_pos := Vector3.ZERO
var intro_from_look := Vector3.ZERO
var intro_to_pos := Vector3.ZERO
var intro_to_look := Vector3.ZERO
var last_hit_pos := Vector3.ZERO
var last_hit_active := false
var wheel_smoke: CPUParticles3D
var haptics: Node
var game_feel: Node
var split_screen: Node
var split_layer: CanvasLayer
# 本地双人同屏（duel）
var duel_p2: Car
var duel_p2_laps := 0
var duel_p2_prev_progress := 0.0
var duel_p2_lap_start := 0.0
var duel_p2_best_lap := -1.0
var duel_p2_finish_time := -1.0
var duel_winner := ""
var duel_total_laps := 3
var _nitro_use_count := 0
var _drift_time := 0.0
var _top_speed_kph := 0.0
var _was_nitro := false
var _last_gear_seen := 1
var _wall_hit_cd := 0.0
# 走线采样：把本场玩家真实跑过的横向偏移 / 速度压缩成 AI 路线库
var _line_samples: Array = []
var _line_acc := 0.0
var _run_recorded := false
# 最佳圈幽灵车
var ghost_root: Node3D
var _ghost_data: Dictionary = {}
var _ghost_samples: Array = []
var _ghost_record_acc := 0.0
var _ghost_lap_start := 0.0
var _ghost_prev_laps := 0
var _ghost_was_started := false
var _ghost_delta_index := 0
var _ghost_visual_car := ""
## 幽灵车起步领跑量（秒）：让最快虚拟车一开始就稍微在前方带节奏。
const GHOST_LEAD_TIME := 0.6
var boot_screen: BootScreen
var _menu_scene_cache: Dictionary = {}
var _menu_cache_order: Array[String] = []
var _pending_menu_track := ""
var _pending_menu_car := ""
var _pending_menu_token := 0
var _menu_build_token := 0
var _bake_menu_active := false
var _menu_preload_started: Dictionary = {}
var loading_screen: LoadingScreen
var pause_screen: PauseScreen
var menu_car_pivot: Node3D
var menu_car_model: Node3D
var menu_cam: Camera3D
var menu_time := 0.0
var menu_car_angle := 0.0
var menu_dragging := false
var menu_track_id := ""
var menu_car_id := ""
var motion_blur_rect: ColorRect
var motion_blur_mat: ShaderMaterial
var garage_screen: GarageScreen
var _tune_demo := false
var _perf_mode := false
var _analog_test_mode := false
var _drift_test_mode := false
var _ace68_pid := 0
var _ace68_reused := false
const ACE68_PIDFILE := "/tmp/apex_ace68_bridge.pid"
var _perf_time := 0.0
var _perf_samples: Array[float] = []
var _perf_drawcalls: Array[float] = []
var _perf_triangles: Array[float] = []
var _perf_proc_us: Array[float] = []
var _perf_phys_us: Array[float] = []
var _perf_sample_timer := 0.0
var _results_shown := false

var verify_mode := false
var shot_mode := false
var shot_path := ""
var shot_scene := "race"
var _shot_frames := 0
var _backdrop_cam: Camera3D
var _shot_dist := 0.0
var _shot_delay := 0.0
var _movie_frames := 0
var _pano_dist := 0.0
# 宣传片拍摄通道：仅当 --movie-dir / --trailer-shot 指定时生效，正常游戏零影响
var _movie_dir := ""
var _movie_skip := 0
var _movie_busy := false
var _trailer_shot := ""
var _trailer_hud := -1
var _trailer_nogrid := false
var _arg_track := ""
var _arg_car := ""
var _arg_mode := ""
var _arg_quality := ""
var _arg_camera := -1
var _arg_shot_speed := 0.0
var _openworld_test_mode := false
var _ai_probe := {"n": 0, "gap_sum": 0.0, "gap_min": 9999.0, "close": 0, "cluster": 0,
	"spread_sum": 0.0, "along_sum": 0.0, "along_close": 0}
var _ai_probe_t := 0.0

# --- 开放世界（无界大陆）----------------------------------------------------
var open_world: OpenWorld = null
var open_world_active := false
var _open_world_sky_mat: ShaderMaterial = null
var _open_world_zone_theme := ""
var _open_world_rescue_cd := 0.0
## 主题过渡刷新节流：每帧重新混一次域主题会产生大量临时字典，
## 12Hz 刷新足够顺滑（人眼看不出 80ms 内的渐变差别），GC 压力却小一个量级。
var _open_world_theme_cd := 0.0

# --- 城市实景（都会环线）-----------------------------------------------------
## 真实城市模型没有引擎碰撞体：建筑掩体由离线烘焙的 SDF 提供，
## 车可以开进任意街道，只有房屋是实体。
var _city_world: Node = null
const CityWorldScript := preload("res://scripts/openworld/city_world.gd")
const CityFacadesScript := preload("res://scripts/openworld/city_facades.gd")


func _ready() -> void:
	streamer = FrustumStreamer.new()
	streamer.name = "FrustumStreamer"
	add_child(streamer)
	Settings.changed.connect(_apply_quality)
	settings_screen = SettingsScreen.new()
	settings_screen.name = "SettingsScreen"
	settings_screen.main_ref = self
	settings_screen.closed.connect(_on_settings_closed)
	add_child(settings_screen)
	var motion_layer := CanvasLayer.new()
	motion_layer.name = "MotionBlur"
	motion_layer.layer = 6
	add_child(motion_layer)
	motion_blur_rect = ColorRect.new()
	motion_blur_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	motion_blur_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	motion_blur_mat = ShaderMaterial.new()
	motion_blur_mat.shader = load("res://shaders/motion_blur.gdshader")
	motion_blur_rect.material = motion_blur_mat
	motion_blur_rect.visible = false
	motion_layer.add_child(motion_blur_rect)
	get_viewport().size_changed.connect(_sync_post_params)
	_sync_post_params()
	_parse_args()
	# 测试参数：临时覆盖画质档（不写存档，不影响玩家自己的设置）
	if not _arg_quality.is_empty():
		for i in Settings.PRESETS.size():
			if String(Settings.PRESETS[i]["id"]) == _arg_quality:
				Settings.index = i
				Settings.sync_details_from_preset()
				break
	# 逐帧拍片时锁 30fps：渲染帧间隔 ≈ 帧序列播放间隔，车辆运动不会变成快进
	if not _movie_dir.is_empty():
		DirAccess.make_dir_recursive_absolute(_movie_dir)
		Engine.max_fps = 30
	InputSetup.ensure_actions()
	_maybe_start_ace68_bridge()
	var ace68_watchdog := Timer.new()
	ace68_watchdog.wait_time = 5.0
	ace68_watchdog.autostart = true
	ace68_watchdog.timeout.connect(_ace68_watchdog_tick)
	add_child(ace68_watchdog)
	if _perf_mode:
		# 性能测量基线：固定 1600×900 窗口化、关垂直同步、不限帧。
		# 以前日志写着 vsync_off 但没真关，帧率会被显示器刷新率钳住，测不出真实性能。
		Engine.max_fps = 0
		if DisplayServer.get_name() != "headless":
			DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
			var win := get_window()
			win.mode = Window.MODE_WINDOWED
			win.borderless = false
			win.size = Vector2i(1600, 900)
		_apply_quality()
	elif not shot_mode:
		if Settings.has_method("apply_display"):
			Settings.apply_display()
		_apply_quality()
	if _analog_test_mode:
		_run_analog_test()
		return
	if verify_mode:
		_run_verification()
		return
	if "--bake-menu" in OS.get_cmdline_user_args():
		_run_bake_menu()
		return
	if "--scenery-debug" in OS.get_cmdline_user_args():
		_run_scenery_debug()
		return
	if "--scenery-audit" in OS.get_cmdline_user_args():
		_run_scenery_audit()
		return
	if "--bake-decor" in OS.get_cmdline_user_args():
		_run_bake_decor()
		return
	if "--audio-test" in OS.get_cmdline_user_args():
		_run_audio_test()
		return
	if not shot_mode:
		audio = AudioManager.new()
		audio.name = "Audio"
		add_child(audio)
		if ResourceLoader.exists("res://scripts/core/haptics.gd"):
			haptics = load("res://scripts/core/haptics.gd").new()
			haptics.name = "Haptics"
			add_child(haptics)
			if haptics.has_method("setup"):
				haptics.setup()
	if _tune_demo:
		_apply_demo_tune(_car_or_default())
	if _perf_mode:
		_start_race(_track_or_default(), _car_or_default(), _mode_or_default())
		return
	if "--autostart" in OS.get_cmdline_user_args():
		_start_race(_track_or_default(), _car_or_default(), _mode_or_default())
		return
	if _openworld_test_mode:
		_run_open_world_test()
		return
	if shot_mode:
		if shot_scene == "backdrop":
			_start_race(_track_or_default(), _car_or_default(), _mode_or_default())
			_enter_backdrop_mode()
		elif shot_scene == "boot":
			_show_boot()
		elif shot_scene == "loading":
			_show_menu()
			_begin_loading("正在切换赛道  天际环城")
		elif shot_scene == "menu":
			_show_menu()
		elif shot_scene == "garage" or shot_scene == "garage-grid":
			_open_garage(_car_or_default())
		elif shot_scene == "settings" or shot_scene == "settings-controls":
			_show_menu()
			_open_settings()
		elif shot_scene == "achievements":
			_show_menu()
		elif shot_scene == "archive" or shot_scene == "archive-detail":
			_show_menu()
		elif shot_scene == "venue":
			_start_race(_track_or_default(), _car_or_default(), _mode_or_default())
		elif shot_scene == "panorama":
			_start_race(_track_or_default(), _car_or_default(), _mode_or_default())
		elif shot_scene == "blur":
			_start_race(_track_or_default(), _car_or_default(), _mode_or_default())
		elif shot_scene == "rt":
			_start_race(_track_or_default(), _car_or_default(), _mode_or_default())
		else:
			_start_race(_track_or_default(), _car_or_default(), _mode_or_default())
			if _shot_dist > 0.0 and car != null:
				car.reset(_shot_dist)
			if shot_scene == "results":
				_simulate_until_results()
				if hud != null and race != null:
					hud.show_results(race)
		# 拍片：跳过 3-2-1 倒数，第一帧即处于行驶状态（仅拍片参数触发）
		if _trailer_nogrid and race != null:
			race.countdown = 0.0
			race.state = RaceManager.State.RACING
			race.race_time = 0.0
		return
	if shot_mode:
		return
	_show_boot()
	if "--switch-test" in OS.get_cmdline_user_args():
		_run_switch_test()
	if "--race-test" in OS.get_cmdline_user_args():
		_run_race_test()
	if _drift_test_mode:
		_run_drift_test()
	if "--menu-nav-test" in OS.get_cmdline_user_args():
		_run_menu_nav_test()


## ACE68 磁轴键盘桥：游戏启动时自动拉起（macOS 且 exe 存在时），退出时杀掉并还原键盘开关。
## 关掉「设置→操作→模拟输入」即不会再自动启动；也可以手动跑
## tools/analog_input/ace68/ace68_macos --stream 后游戏会复用。
func _maybe_start_ace68_bridge() -> void:
	if OS.get_name() != "macOS":
		return
	if verify_mode or shot_mode or _perf_mode:
		return
	for flag in ["--bake-menu", "--scenery-debug", "--bake-decor", "--audio-test"]:
		if flag in OS.get_cmdline_user_args():
			return
	if Settings.get("analog_input_enabled") != null and not bool(Settings.get("analog_input_enabled")):
		print("[ACE68] 模拟输入已关闭，不启动磁轴桥")
		return
	var exe := ProjectSettings.globalize_path("res://tools/analog_input/ace68/ace68_macos")
	if not FileAccess.file_exists(exe):
		return
	var port := int(Settings.get("analog_udp_port")) if Settings.get("analog_udp_port") != null else AnalogInput.DEFAULT_PORT
	if OS.get_environment("APEX_ANALOG_PORT").is_valid_int():
		port = int(OS.get_environment("APEX_ANALOG_PORT"))
	var existing := _read_ace68_pidfile()
	if existing > 0 and _ace68_process_alive(existing):
		_ace68_pid = existing
		_ace68_reused = true
		print("[ACE68] 复用已运行的磁轴桥 pid=%d" % existing)
		return
	if existing > 0:
		DirAccess.remove_absolute(ACE68_PIDFILE)  # 上次异常退出的残留
	var child := OS.create_process(exe, ["--stream", "--udp-port", str(port),
		"--parent-pid", str(OS.get_process_id()), "--log-file", "/tmp/apex_ace68_bridge.log"])
	if child <= 0:
		print("[ACE68] 磁轴桥启动失败（不影响普通键盘游玩）")
		return
	_ace68_pid = child
	_ace68_reused = false
	print("[ACE68] 磁轴桥已启动 pid=%d（W/S/A/D 深度 → 线性油门/刹车/转向）" % child)
	var timer := get_tree().create_timer(1.0)
	timer.timeout.connect(func() -> void:
		if _ace68_pid > 0 and not _ace68_process_alive(_ace68_pid):
			print("[ACE68] 磁轴桥进程退出了：确认键盘为有线模式且已插好、M HUB 网页/驱动未占用配置接口")
			_ace68_pid = 0)


func _read_ace68_pidfile() -> int:
	var f := FileAccess.open(ACE68_PIDFILE, FileAccess.READ)
	if f == null:
		return 0
	var text := f.get_as_text().strip_edges()
	f.close()
	return int(text) if text.is_valid_int() else 0


## kill(pid,0) 对僵尸进程也返回成功；用 ps 排除 Z 状态，避免把已死的桥当活的
func _ace68_process_alive(pid: int) -> bool:
	if pid <= 0 or not OS.is_process_running(pid):
		return false
	var out: Array = []
	OS.execute("/bin/ps", ["-o", "stat=", "-p", str(pid)], out, true)
	var stat := String(out[0]).strip_edges() if not out.is_empty() else ""
	return not stat.begins_with("Z")


## 看门狗：键盘拔插/桥崩溃后自动重拉磁轴桥（桥自身也会在找不到设备时等待插入）
func _ace68_watchdog_tick() -> void:
	if OS.get_name() != "macOS" or verify_mode or shot_mode or _perf_mode:
		return
	if Settings.get("analog_input_enabled") != null and not bool(Settings.get("analog_input_enabled")):
		return
	var pid := _read_ace68_pidfile()
	if pid > 0 and _ace68_process_alive(pid):
		return
	_maybe_start_ace68_bridge()


func _stop_ace68_bridge() -> void:
	# 复用的常驻桥（无 --parent-pid）不属于本进程，退出时不能杀，否则每次关游戏
	# 都会把桥带走并还原键盘开关。
	if _ace68_pid <= 0 or _ace68_reused:
		return
	if OS.is_process_running(_ace68_pid):
		# 必须发 SIGTERM（不是 SIGKILL），桥接收到后会把键盘模拟量开关还原再退出。
		OS.execute("/bin/kill", ["-TERM", str(_ace68_pid)], [], false)
		print("[ACE68] 已通知磁轴桥退出并还原键盘开关")
	_ace68_pid = 0


func _ace68_effective_port() -> int:
	var port := int(Settings.get("analog_udp_port")) if Settings.get("analog_udp_port") != null else AnalogInput.DEFAULT_PORT
	if OS.get_environment("APEX_ANALOG_PORT").is_valid_int():
		port = int(OS.get_environment("APEX_ANALOG_PORT"))
	return port


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		_stop_ace68_bridge()


func _exit_tree() -> void:
	_stop_ace68_bridge()


func _show_boot() -> void:
	if boot_screen != null:
		return
	_start_menu_preload(_preferred_menu_track())
	# 自动化测试不等开场影片（无窗口焦点时视频会暂停，测试会一直吊住）
	if _drift_test_mode or "--menu-nav-test" in OS.get_cmdline_user_args() \
			or "--race-test" in OS.get_cmdline_user_args():
		_show_menu()
		return
	boot_screen = BootScreen.new()
	boot_screen.name = "BootScreen"
	add_child(boot_screen)
	boot_screen.finished.connect(_on_boot_finished)


func _run_race_test() -> void:
	while menu == null:
		await get_tree().process_frame
	await get_tree().create_timer(1.5).timeout
	print("[RACE-TEST] start race from menu")
	var t0 := Time.get_ticks_msec()
	_start_race(menu.selected_track_id(), menu.selected_car_id(), "gp")
	while race == null:
		await get_tree().process_frame
	print("[RACE-TEST] race ready in ", Time.get_ticks_msec() - t0, " ms, state=", race.state)
	await get_tree().create_timer(0.9).timeout
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	if img != null:
		img.save_png("/tmp/race_intro.png")
		print("[RACE-TEST] intro screenshot saved")
	await get_tree().create_timer(3.4).timeout
	print("[RACE-TEST] after countdown state=", race.state, " intro_cam=", intro_cam)
	get_tree().quit()


## 漂移回归：加速 → 手刹漂移 → 松手恢复，全程采样车速。
## 旧版手刹阻力 × 动力切断会让车在漂移后半段被硬拽停；这里断言松手后
## 车速不发生骤停（这是用户点名的「漂完不知道为什么停那」）。
func _run_drift_test() -> void:
	while menu == null:
		await get_tree().process_frame
	await get_tree().create_timer(1.2).timeout
	_start_race("coast", _car_or_default(), "ta")
	while race == null or car == null:
		await get_tree().process_frame
	for i in 300:
		await get_tree().process_frame
		if race.state == RaceManager.State.COUNTDOWN:
			break
	race.countdown = 0.0
	race.state = RaceManager.State.RACING
	race.race_time = 0.0
	var release_speed := -1.0
	var min_after := 1e9
	var final_speed := 0.0
	var next_sample := 0.0
	while race != null and car != null and race.race_time < 6.0:
		await get_tree().physics_frame
		var t := race.race_time
		if t >= next_sample:
			next_sample = t + 0.5
			print("[DRIFT-TEST] t=%.2f speed=%.1f kph grip=%.2f drift=%s slip=%.2f wall=%s imp=%.2f off=%s" % [
				t, car.speed_kph, car.drift_grip, str(car.drift_active),
				car.lat_slip, str(car.wall_contact), car.wall_impact, str(car.offroad)])
		if release_speed < 0.0 and t >= 4.2:
			release_speed = car.speed_kph
		elif release_speed >= 0.0:
			min_after = minf(min_after, car.speed_kph)
		final_speed = car.speed_kph
	var ok := release_speed > 45.0 and min_after > 20.0 and final_speed > 20.0
	print("[DRIFT-TEST] release=%.1f kph  min_after=%.1f kph  final=%.1f kph  -> %s" % [
		release_speed, min_after, final_speed, "PASS" if ok else "FAIL"])
	get_tree().quit(0 if ok else 1)


func _drift_test_input() -> Dictionary:
	var input := _autopilot_input()
	var t: float = race.race_time if race != null else 0.0
	if t < 3.0:
		input["throttle"] = 1.0
		input["handbrake"] = false
	elif t < 4.2:
		input["throttle"] = maxf(float(input.get("throttle", 0.5)), 0.85)
		input["steer"] = clampf(float(input.get("steer", 0.0)) + 0.55, -1.0, 1.0)
		input["handbrake"] = true
	else:
		input["throttle"] = maxf(float(input.get("throttle", 0.5)), 0.8)
		input["handbrake"] = false
	input["nitro"] = false
	return input


## 主菜单焦点导航自检：默认聚焦发车按钮，依次推方向，打印每次焦点落点。
func _run_menu_nav_test() -> void:
	while menu == null:
		await get_tree().process_frame
	for i in 8:
		await get_tree().process_frame
	print("[NAV-TEST] start focus = ", _focus_desc(get_viewport().gui_get_focus_owner()))
	for action in ["ui_up", "ui_up", "ui_up", "ui_left", "ui_left", "ui_left", "ui_left",
			"ui_left", "ui_left", "ui_left", "ui_left", "ui_up", "ui_up", "ui_up", "ui_down"]:
		Input.action_press(action)
		await get_tree().create_timer(0.10).timeout
		Input.action_release(action)
		await get_tree().create_timer(0.30).timeout
		print("[NAV-TEST] %-8s -> %s" % [action,
			_focus_desc(get_viewport().gui_get_focus_owner())])
	get_tree().quit()


func _focus_desc(ctrl: Control) -> String:
	if ctrl == null:
		return "<none>"
	var txt := ""
	if ctrl is Button:
		txt = String((ctrl as Button).text).replace("\n", " ")
	return "%s '%s' @%s" % [ctrl.get_class(), txt, str(ctrl.global_position.round())]


## 开放世界验收：进大陆 → 逐区截图 → 打印各地形高程 / 地表 / 道路距离。
func _run_open_world_test() -> void:
	# 无界大陆自检：世界生成 / 八域地形 / 逐区截图 / 自由驾驶物理。
	var car_id := _arg_car if not _arg_car.is_empty() else DEFAULT_CAR
	var t0 := Time.get_ticks_msec()
	_start_race("open_world", car_id, "gp")
	while open_world == null:
		await get_tree().process_frame
	# 跳过发车倒数和入场电影机位：否则拍到的是倒计时画面 / 过场镜头，
	# 追尾相机根本没接管，看起来就是「画面黑着 / 车不见了」。
	# 必须等 _start_race 这个协程把状态设成 COUNTDOWN 之后再跳——
	# 早一步设置会被它后面的赋值覆盖掉，倒数照常走，入场机位也一直占着画面。
	for i in 180:
		await get_tree().process_frame
		if race != null and race.state == RaceManager.State.COUNTDOWN:
			break
	if race != null:
		race.countdown = 0.0
		race.state = RaceManager.State.RACING
		race.race_time = 0.0
	var t_build := Time.get_ticks_msec() - t0
	print("[OW-TEST] world built in %d ms" % t_build)
	# --ow-zones=neon,coast 只跑指定域：整轮 16 张图一次跑完会被系统
	# 判定为内存压力过大而 SIGTERM，分批跑稳得多。
	var only := ""
	for a in OS.get_cmdline_user_args():
		if String(a).begins_with("--ow-zones="):
			only = String(a).substr(11)
	var zone_list: Array = OpenWorld.ZONES
	if only != "":
		zone_list = []
		for z in OpenWorld.ZONES:
			if String(z["id"]) in only.split(","):
				zone_list.append(z)
		print("[OW-TEST] zone filter = ", only)
	if open_world != null:
		print("[OW-TEST] roads=%d  grid=%d" % [open_world.roads.size(), OpenWorld.GRID])
		# 路面贴合：地形网格是三角面，路面画在双线性高度上，
		# 两者不等时地形会从路下戳出来，把路切成锯齿。这里量一下戳出多深。
		var fit: Dictionary = open_world.probe_road_fit(0.025)
		print("[OW-TEST] road fit: poke=%.3f m (地形高出路面)  tri-vs-bilinear=%.3f m  samples=%d" % [
			float(fit.get("poke", 0.0)), float(fit.get("tri", 0.0)), int(fit.get("samples", 0))])
		var ov: Array = fit.get("over", [])
		print("[OW-TEST]   戳穿分布 >0.05/0.2/0.5/1.0/3.0 m : %s" % str(ov))
		print("[OW-TEST]   worst at %s" % str(fit.get("at", Vector3.ZERO)))
		for zone in zone_list:
			var c: Vector2 = zone["center"]
			print("[OW-TEST]   %-10s %-8s h=%7.1f  surface=%-6s road=%6.1f" % [
				String(zone["id"]), String(zone["cn"]),
				open_world.height_at(c.x, c.y),
				open_world.surface_at(c.x, c.y),
				open_world.road_distance_at(c.x, c.y)])
	# 逐区截图（无头模式没有渲染帧，跳过）
	var can_render := DisplayServer.get_name() != "headless"
	if can_render:
		var shot_dir := "/tmp/ow_shots"
		DirAccess.make_dir_recursive_absolute(shot_dir)
		# 窗口被其他窗口遮挡时 macOS 会停止 present，get_image() 会一直拿到同一帧。
		# 置顶保证合成器继续合成，另外用「帧哈希变化」判定真的换了帧再存图。
		get_window().always_on_top = true
		for zone in zone_list:
			if car == null or open_world == null:
				break
			var c2: Vector2 = zone["center"]
			# 取景朝向不能随机：每域都要对准它最有代表性的景物，
			# 否则海岸域拍出来是一片滩涂、雪山域拍出来是一块白板。
			var look_at_pt := _ow_shot_target(zone)
			var look_dir: Vector2 = (look_at_pt - c2)
			if look_dir.length() < 1.0:
				look_dir = Vector2(0.0, 1.0)
			look_dir = look_dir.normalized()
			# 站位：站在域中心朝目标方向走一段，卡在最近的路面上。
			# 系数取 0.85 是为了让站位尽量贴近目标（海），
			# 否则站在域中心往海看，中间隔着几百米陆地，画面里只有地平线。
			var stand: Vector2 = c2 + look_dir * minf(float(zone["radius"]) * 0.62,
				(look_at_pt - c2).length() * 0.85)
			# 用道路切线定朝向：原来直接朝域中心，车会横着扎出路肩滑进野地，
			# 拍出来的「区域截图」根本不在路上。
			var rf: Dictionary = open_world.nearest_road_frame(stand.x, stand.y)
			var sp: Vector3 = rf["pos"]
			var rdir: Vector3 = rf["dir"]
			# 切线背对目标时倒过来，保证画面里看的是目标方向
			if rdir.x * look_dir.x + rdir.z * look_dir.y < 0.0:
				rdir = -rdir
			car.pos = sp + rdir * 30.0 + Vector3(0.0, 1.2, 0.0)
			car.vel = Vector3.ZERO
			car.heading = atan2(rdir.x, rdir.z)
			car.speed_kph = 0.0
			# 布景是流式生成的：传送后同步把周围的单元建出来，截图才有内容。
			OpenWorldScenery.ensure_units_at(open_world, Vector2(car.pos.x, car.pos.z), 3200.0)
			# 车是瞬移过去的，但节点变换要等下一次物理同步才更新——
			# 直接 snap() 会用上一帧的旧坐标，相机就得从两公里外插值追过来，
			# 30 帧追不上，拍出来的图里车小得像甲虫。先空转几帧让变换同步，再对位。
			for i in 6:
				await get_tree().process_frame
			if cam != null:
				cam.snap()
			for i in 12:
				await get_tree().process_frame
			var camdist := cam.global_position.distance_to(car.global_position) if cam != null else -1.0
			print("[OW-TEST] zone=%-9s car=%s ground=%.1f depth=%.2f surface=%s camdist=%.1f" % [
				String(zone["id"]), str(car.pos.snapped(Vector3(0.1, 0.1, 0.1))),
				open_world.height_at(car.pos.x, car.pos.z),
				open_world.depth_at(car.pos.x, car.pos.z),
				car.world_surface, camdist])
			if camdist > 9.0:
				print("[OW-TEST] !! camera not settled in zone ", String(zone["id"]))
			# 相机停稳后再空转 20 帧把画面缓冲冲掉，然后直接取当前帧。
			# 不能等「画面稳定」：海面和云是动态的，永远稳定不下来；
			# 也不能只等哈希变化，那样会抓到相机还在过渡的中间帧。
			for i in 20:
				await get_tree().process_frame
				await RenderingServer.frame_post_draw
			var img := get_viewport().get_texture().get_image()
			if img != null:
				var path := "%s/%s.png" % [shot_dir, String(zone["id"])]
				img.save_png(path)
				print("[OW-TEST] shot ", path)
			# 俯瞰图：拉高相机看整片域的布局与布景密度
			# 坑：macOS 窗口被遮挡时渲染器会停止 present，get_image() 会一直拿到旧帧。
			# 必须先把相机挪到位、空转若干帧把追尾旧帧冲掉，再取当前帧，
			# 否则存下来的八张全是第一帧（看起来每域都长一个样）。
			if cam != null:
				var keep := cam.target
				cam.target = null
				var g0 := open_world.height_at(c2.x, c2.y)
				# 航拍机位摆在目标方向的后方高处：画面里同时有域中心与目标（海 / 山 / 火山）
				# 俯角必须小于 fov 的一半，否则视野全落在地面上，
				# 海岸域和港湾域就永远拍不到海（只能拍到一地沥青）。
				# 海域域反过来：相机放到海那一侧朝陆地拍，海在前景、港口在后景，
				# 构图才对；朝陆地拍的话海在相机身后，怎么都拍不到。
				var is_sea := String(zone["id"]) in ["harbor", "coast"]
				var off := Vector3(-look_dir.x * 950.0, 420.0, -look_dir.y * 950.0)
				var aim := Vector3(c2.x, g0, c2.y).lerp(Vector3(look_at_pt.x, g0, look_at_pt.y), 0.62)
				if is_sea:
					off = Vector3(look_dir.x * 820.0, 300.0, look_dir.y * 820.0)
					aim = Vector3(c2.x, g0, c2.y)
				cam.global_position = Vector3(c2.x, g0, c2.y) + off
				cam.look_at(aim, Vector3.UP)
				cam.fov = 58.0
				for i in 24:
					await get_tree().process_frame
					await RenderingServer.frame_post_draw
				var aimg := get_viewport().get_texture().get_image()
				if aimg != null:
					aimg.save_png("%s/%s_air.png" % [shot_dir, String(zone["id"])])
					print("[OW-TEST] shot %s/%s_air.png cam=%s" % [shot_dir, String(zone["id"]),
						str(cam.global_position.snapped(Vector3(1.0, 1.0, 1.0)))])
				else:
					print("[OW-TEST] AIR SHOT MISSED ", String(zone["id"]))
				cam.target = keep
				cam.fov = 58.5
		# 域间过渡带验收：站在两条域的中点往一边看。
		# 这一段是本轮的重点：域与域之间不应该是硬边，
		# 颜色要渐变、植被也要跟着换，否则九公里的大陆就是八块拼贴板。
		for pair in [[0, 1], [2, 3], [6, 7]]:
			if car == null or open_world == null:
				break
			var za: Dictionary = OpenWorld.ZONES[int(pair[0])]
			var zb: Dictionary = OpenWorld.ZONES[int(pair[1])]
			var mid := (Vector2(za["center"]) + Vector2(zb["center"])) * 0.5
			var rf2: Dictionary = open_world.nearest_road_frame(mid.x, mid.y)
			var sp2: Vector3 = rf2["pos"]
			var rdir2: Vector3 = rf2["dir"]
			var toward := (Vector2(za["center"]) - mid)
			if toward.length() < 0.01:
				toward = Vector2(1.0, 0.0)
			toward = toward.normalized()
			if rdir2.x * toward.x + rdir2.z * toward.y < 0.0:
				rdir2 = -rdir2
			car.pos = sp2 + rdir2 * 30.0 + Vector3(0.0, 1.2, 0.0)
			car.vel = Vector3.ZERO
			car.heading = atan2(rdir2.x, rdir2.z)
			OpenWorldScenery.ensure_units_at(open_world, Vector2(car.pos.x, car.pos.z), 3200.0)
			for i in 6:
				await get_tree().process_frame
			if cam != null:
				cam.snap()
			for i in 12:
				await get_tree().process_frame
			for i in 20:
				await get_tree().process_frame
				await RenderingServer.frame_post_draw
			var timg := get_viewport().get_texture().get_image()
			if timg != null:
				var tpath := "%s/transition_%s_%s.png" % [shot_dir, String(za["id"]),
					String(zb["id"])]
				timg.save_png(tpath)
				print("[OW-TEST] transition shot ", tpath)
	# 开一段路，验证驾驶物理（地面跟随 / 坡度 / 速度累积）
	if car != null:
		var sp2: Dictionary = open_world.spawn()
		car.pos = sp2["pos"]
		car.vel = Vector3.ZERO
		car.heading = float(sp2.get("heading", 0.0))
		var ground_h := open_world.height_at(car.pos.x, car.pos.z)
		var min_gap := 99.0
		var max_gap := -99.0
		for i in 300:
			car.update_car(1.0 / 60.0, {"steer": 0.02, "throttle": 1.0,
				"handbrake": false, "nitro": false})
			var gap := car.pos.y - open_world.height_at(car.pos.x, car.pos.z)
			min_gap = minf(min_gap, gap)
			max_gap = maxf(max_gap, gap)
		print("[OW-TEST] drive 5s: pos=%s speed=%.1f kph surface=%s zone=%s" % [
			str(car.pos.snapped(Vector3(0.1, 0.1, 0.1))), car.speed_kph,
			car.world_surface, car.world_zone])
		print("[OW-TEST] ground follow gap: %.3f .. %.3f  (spawn h=%.2f)" % [
			min_gap, max_gap, ground_h])
		# 越野：驶离公路后地表应变为非 road
		car.pos = open_world.spawn()["pos"] + Vector3(0.0, 0.0, -180.0)
		car.update_car(1.0 / 60.0, {"steer": 0.0, "throttle": 0.6,
			"handbrake": false, "nitro": false})
		print("[OW-TEST] offroad surface=%s road_dist=%.1f" % [
			car.world_surface, open_world.road_distance_at(car.pos.x, car.pos.z)])
		_ow_test_collisions()
	get_tree().quit()


## 静态实体碰撞自检：
##   1) 登记了多少碰撞体（树 / 楼 / 墙 / 岩石都必须是实体）
##   2) 把车直接塞进一栋楼里，看它会不会被推出来
##   3) 车高速撞向一面墙，看会不会穿过去
func _ow_test_collisions() -> void:
	if open_world == null or car == null:
		return
	print("[OW-TEST] colliders registered = %d" % open_world.collider_count())
	# 找一个「足够大的」碰撞体当测试对象：楼比树大
	var best: Dictionary = {}
	var best_area := 0.0
	for ox in range(-14, 15):
		for oz in range(-14, 15):
			var qx := 2450.0 + float(ox) * 120.0
			var qz := float(oz) * 120.0
			for c in open_world.query_colliders(qx, qz, 130.0):
				var half: Vector2 = c["half"]
				var area := half.x * half.y
				if area > best_area:
					best_area = area
					best = c
	if best.is_empty():
		print("[OW-TEST] !! no collider found to test with")
		return
	var cp: Vector2 = best["pos"]
	var half2: Vector2 = best["half"]
	var brot: float = float(best["rot"])
	print("[OW-TEST] test target at %s half=%s rot=%.2f area=%.1f" % [
		str(cp), str(half2), brot, best_area])
	# 1) 塞进楼心：推出后车心到楼体最近边界的距离应 ≥ 车身半径，
	#    也就是车身完全在楼外，而不是「还差几厘米」。
	var car_r := 1.45
	car.pos = Vector3(cp.x, open_world.height_at(cp.x, cp.y), cp.y)
	car.vel = Vector3.ZERO
	car.update_car(1.0 / 60.0, {"steer": 0.0, "throttle": 0.0,
		"handbrake": false, "nitro": false})
	var cs := cos(brot)
	var sn := sin(brot)
	var lx := (car.pos.x - cp.x) * cs - (car.pos.z - cp.y) * sn
	var lz := (car.pos.x - cp.x) * sn + (car.pos.z - cp.y) * cs
	var qx := clampf(lx, -half2.x, half2.x)
	var qz := clampf(lz, -half2.y, half2.y)
	var edge_dist := Vector2(lx - qx, lz - qz).length()
	print("[OW-TEST] embedded in building -> edge gap %.2f m (must be >= %.2f)" % [
		edge_dist, car_r])
	if edge_dist < car_r - 0.05:
		print("[OW-TEST] !! FAIL 车身仍在建筑内部（穿模）")
	else:
		print("[OW-TEST] OK  车身已被推出建筑体")
	# 2) 高速撞向建筑：一步最多 0.6m，不可能跨过一面墙
	var toward := (Vector3(cp.x, 0.0, cp.y) - Vector3(car.pos.x, 0.0, car.pos.z))
	if toward.length() < 0.01:
		toward = Vector3(1.0, 0.0, 0.0)
	toward = toward.normalized()
	# 车头必须真的朝着墙：update_car 会按 heading 重新算速度，
	# 光设 vel 不改朝向的话，车其实朝别的方向开，这个测试等于没测。
	car.heading = atan2(toward.x, toward.z)
	var before := car.pos.distance_to(Vector3(cp.x, car.pos.y, cp.y))
	car.vel = toward * 40.0
	for i in 30:
		car.update_car(1.0 / 60.0, {"steer": 0.0, "throttle": 1.0,
			"handbrake": false, "nitro": false})
	var after := car.pos.distance_to(Vector3(cp.x, car.pos.y, cp.y))
	print("[OW-TEST] ram building: dist %.2f -> %.2f  speed=%.1f  wall_contact=%s" % [
		before, after, car.speed_kph, str(car.wall_contact)])
	# 撞完必须还在楼外：距离不能比撞之前更靠近楼心太多
	if after < before - 2.0:
		print("[OW-TEST] !! FAIL 高速撞墙后穿进了建筑（距离 %.2f -> %.2f）" % [before, after])
	else:
		print("[OW-TEST] OK  高速撞墙后仍被挡在建筑外（%.2f -> %.2f）" % [before, after])


## 每个域的取景目标点：城市看核心，海域看海，野外看最高处。
## 之前所有域都用同一个「站在域中心附近随便找条路」逻辑，
## 结果海岸域拍不到海、雪山域拍不到山，看起来八个域都长一个样。
func _ow_shot_target(zone: Dictionary) -> Vector2:
	if open_world == null:
		return Vector2.ZERO
	var c: Vector2 = zone["center"]
	var rad := float(zone["radius"])
	match String(zone["id"]):
		"neon", "skyline":
			return c
		"harbor", "coast":
			# 这两域的看点就是海：找域内离中心最近的水面点
			var best := c
			var best_d := 1.0e20
			var st := rad / 12.0
			for j in range(-12, 13):
				for i in range(-12, 13):
					var p := c + Vector2(float(i) * st, float(j) * st)
					if p.distance_to(c) > rad:
						continue
					if open_world.height_at(p.x, p.y) < 0.0:
						var d := p.distance_to(c)
						if d < best_d:
							best_d = d
							best = p
			if best_d < 1.0e19:
				return best
			return c
		"glacier":
			return OpenWorld.LAKE_CENTER
		_:
			# 野外域看最高处：雪山山脊 / 峡谷台地 / 火山口
			var top := c
			var top_h := -1.0e20
			var st2 := rad / 9.0
			for j in range(-9, 10):
				for i in range(-9, 10):
					var p := c + Vector2(float(i) * st2, float(j) * st2)
					if p.distance_to(c) > rad:
						continue
					var h := open_world.height_at(p.x, p.y)
					if h > top_h:
						top_h = h
						top = p
			return top



func _run_switch_test() -> void:
	while menu == null:
		await get_tree().process_frame
	await get_tree().create_timer(2.0).timeout
	if menu != null:
		print("[SWITCH-TEST] switching to next track")
		menu._step_track(1)
	await get_tree().create_timer(6.0).timeout
	print("[SWITCH-TEST] done, track=", menu_track_id)
	get_tree().quit()


func _on_boot_finished() -> void:
	boot_screen = null
	print("[BOOT] finished -> menu")
	_show_menu()


func _begin_loading(title: String) -> void:
	if loading_screen != null:
		return
	loading_screen = LoadingScreen.new()
	loading_screen.name = "LoadingScreen"
	add_child(loading_screen)
	loading_screen.show_loading(title)


func _end_loading() -> void:
	if loading_screen == null:
		return
	var screen := loading_screen
	loading_screen = null
	screen.finish_and_free()


func _poll_menu_preload() -> void:
	if _pending_menu_track.is_empty():
		return
	var path := _menu_scene_path(_pending_menu_track)
	var status := ResourceLoader.load_threaded_get_status(path)
	if status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		return
	if status != ResourceLoader.THREAD_LOAD_LOADED:
		_pending_menu_track = ""
		_end_loading()
		return
	var packed := ResourceLoader.load_threaded_get(path) as PackedScene
	var track_id := _pending_menu_track
	var car_id := _pending_menu_car
	var token := _pending_menu_token
	_pending_menu_track = ""
	_pending_menu_car = ""
	_menu_scene_cache[track_id] = packed
	_menu_cache_order.append(track_id)
	_trim_menu_cache(menu_track_id)
	if token != _menu_build_token:
		return
	_end_loading()
	_free_menu_world()
	_instantiate_menu_scene(packed, track_id, car_id)


## 菜单场景缓存上限：超过 4 个时淘汰最旧的非当前项。
## city/skyline 每个连依赖约数百 MB 常驻，8 张全留着会顶进内存交换。
func _trim_menu_cache(keep_id: String) -> void:
	while _menu_cache_order.size() > 4:
		var drop := ""
		for id in _menu_cache_order:
			if id != keep_id and id != menu_track_id:
				drop = id
				break
		if drop.is_empty():
			return
		_menu_cache_order.erase(drop)
		_menu_scene_cache.erase(drop)
		_menu_preload_started.erase(drop)


func _process(dt: float) -> void:
	_poll_menu_preload()
	if intro_cam != null and race != null:
		intro_t += dt
		var k := clampf(intro_t / 3.0, 0.0, 1.0)
		var e := k * k * (3.0 - 2.0 * k)
		intro_cam.global_position = intro_from_pos.lerp(intro_to_pos, e)
		intro_cam.look_at(intro_from_look.lerp(intro_to_look, e), Vector3.UP)
		if k >= 1.0 or race.state != RaceManager.State.COUNTDOWN:
			intro_cam.queue_free()
			intro_cam = null
			if cam != null:
				cam.current = true
				cam.snap()
	if state == AppState.MENU and menu_world != null:
		menu_time += dt
		_animate_menu_showroom()
	if _perf_mode:
		_perf_tick(dt)
		return
	if not shot_mode:
		return
	_shot_frames += 1
	# 逐帧输出：跳过前置帧后，把每个真实渲染帧写成 JPEG 序列
	if not _movie_dir.is_empty() and _shot_frames > _movie_skip and not _movie_busy:
		_movie_busy = true
		_capture_movie_frame(_shot_frames - _movie_skip)
	# 宣传片拍摄：--write-movie + --movie-frames=N，到帧数直接退出（不抓 PNG）
	if _movie_frames > 0 and _shot_frames >= _movie_frames + (2 if not _movie_dir.is_empty() else 0):
		get_tree().quit(0)
		return
	# 调试用：--shot-speed=<kph> 把拍摄时的车固定在指定速度，方便对比高速机位
	if _arg_shot_speed > 0.0 and car != null and race != null and race.state != RaceManager.State.COUNTDOWN:
		car.vel = car.forward() * (_arg_shot_speed / 3.6)
	var ready := false
	match shot_scene:
		"menu", "results", "settings":
			ready = _shot_frames >= 45
		"garage":
			if _shot_frames == 26 and garage_screen != null:
				for a in OS.get_cmdline_user_args():
					if String(a).begins_with("--garage-cat="):
						garage_screen._select_category(int(String(a).substr(13)))
			# shot-delay 同时充当「等缩略图补拍完」的开关（烘焙工具用）
			ready = _shot_frames >= 45 and (garage_screen == null or _shot_delay <= 0.0
				or garage_screen.thumbs_ready())
		"boot":
			ready = _shot_frames >= 200
		"loading":
			ready = _shot_frames >= 20
		"backdrop":
			ready = _shot_frames >= 12
		"grid":
			ready = race != null and race.state == RaceManager.State.COUNTDOWN and race.countdown <= 2.3
		"blur":
			ready = _shot_frames >= 45
		"rt":
			if _shot_frames == 30 and cam != null:
				cam.global_position = Vector3(-422.0 + 18.0, 9.0, 56.0 + 18.0)
				cam.look_at(Vector3(-422.0, 5.0, 56.0), Vector3.UP)
			ready = _shot_frames >= 42
		"panorama":
			if cam != null and track_path != null:
				var pd := _shot_dist if _shot_dist > 0.0 else 620.0
				if _movie_frames > 0:
					# 电影模式：贴地低机位沿赛道匀速前推（12m/s）
					if _shot_frames == 30:
						_pano_dist = pd
					_pano_dist += 0.4
					var pf := track_path.frame_at(_pano_dist)
					if not pf.is_empty():
						var ppos: Vector3 = (pf["pos"] as Vector3) + (pf["side"] as Vector3) * 9.0
						cam.global_position = ppos + Vector3(0.0, 3.5, 0.0)
						var look := track_path.frame_at(_pano_dist + 70.0)
						if not look.is_empty():
							cam.look_at((look["pos"] as Vector3) + Vector3(0.0, 1.6, 0.0), Vector3.UP)
				elif _shot_frames == 30:
					var pf2 := track_path.frame_at(pd)
					if not pf2.is_empty():
						var ppos2: Vector3 = (pf2["pos"] as Vector3) + (pf2["side"] as Vector3) * 6.0
						cam.global_position = ppos2 - (pf2["tangent"] as Vector3) * 170.0 + Vector3(0.0, 90.0, 0.0)
						cam.look_at(ppos2 + (pf2["tangent"] as Vector3) * 240.0 + Vector3(0.0, 30.0, 0.0), Vector3.UP)
			ready = _shot_frames >= 42
		"settings":
			if _shot_frames == 24:
				_open_settings()
			ready = _shot_frames >= 40
		"garage-grid":
			if _shot_frames == 26 and garage_screen != null:
				garage_screen._open_car_grid()
			ready = _shot_frames >= 45
		"settings-controls":
			if _shot_frames == 30 and settings_screen != null:
				settings_screen._select_tab(2)
			ready = _shot_frames >= 45
		"archive-detail":
			if _shot_frames == 24:
				_open_circuit_archive()
			elif _shot_frames == 30:
				var arc := get_node_or_null("CircuitArchive")
				if arc != null and arc.has_method("_open_detail"):
					arc._open_detail("coast")
			ready = _shot_frames >= 48
		"achievements":
			if _shot_frames == 24:
				_open_achievements()
			ready = _shot_frames >= 45
		"daily":
			if _shot_frames == 24:
				_open_daily()
			ready = _shot_frames >= 45
		"archive":
			if _shot_frames == 24:
				_open_circuit_archive()
			ready = _shot_frames >= 45
		"start":
			ready = race != null and car != null and race.state != RaceManager.State.COUNTDOWN \
				and car.speed_kph > 18.0
		"nitro":
			if car != null and race != null and race.state != RaceManager.State.COUNTDOWN:
				car.nitro_charge = 1.0
			ready = race != null and race.state != RaceManager.State.COUNTDOWN \
				and race.race_time >= maxf(1.8, _shot_delay)
		"drift":
			ready = race != null and race.state != RaceManager.State.COUNTDOWN \
				and race.race_started and race.race_time >= maxf(1.0, _shot_delay)
		"pack":
			if cam != null and race != null and race.state != RaceManager.State.COUNTDOWN \
					and ais.size() >= 2 and track_path != null:
				var center := Vector3.ZERO
				for ai in ais:
					center += ai.pos
				center /= float(ais.size())
				var pf := track_path.frame_at(ais[0].dist + 4.0)
				if not pf.is_empty():
					var pside: Vector3 = pf["side"]
					var ptan: Vector3 = pf["tangent"]
					cam.global_position = center + pside * 19.0 - ptan * 15.0 + Vector3(0.0, 7.5, 0.0)
					cam.look_at(center + Vector3(0.0, 1.0, 0.0), Vector3.UP)
			ready = race != null and race.state != RaceManager.State.COUNTDOWN and race.race_time >= 9.0
		"venue":
			if _shot_frames == 30 and cam != null and track_path != null:
				var f0 := track_path.frame_at(-46.0)
				var f1 := track_path.frame_at(28.0)
				if not f0.is_empty() and not f1.is_empty():
					cam.global_position = (f0["pos"] as Vector3) + Vector3(0.0, 10.0, 0.0) - (f0["tangent"] as Vector3) * 12.0
					cam.look_at((f1["pos"] as Vector3) + Vector3(0.0, 4.5, 0.0), Vector3.UP)
			ready = _shot_frames >= 42
		_:
			var need_time := 4.0
			if _arg_shot_speed > 0.0:
				need_time = 1.6
			need_time = maxf(need_time, _shot_delay)
			ready = race != null and race.state != RaceManager.State.COUNTDOWN and race.race_time >= need_time
	# 自定义电影机位在内建机位之后接管，保证每帧都按分镜摆位
	if not _trailer_shot.is_empty():
		_update_trailer_camera()
	# 电影模式只按帧数退出，绝不触发静帧截图退出
	if _movie_frames > 0:
		return
	if not ready:
		return
	shot_mode = false
	_grab_screenshot()


func _physics_process(dt: float) -> void:
	if state != AppState.RACE or car == null:
		return
	if open_world_active:
		_physics_process_open_world(dt)
		return
	if race == null:
		return
	var input: Dictionary
	if race.state == RaceManager.State.COUNTDOWN:
		input = COUNTDOWN_INPUT
	elif shot_mode:
		if shot_scene == "drift":
			input = _autopilot_input()
			input["throttle"] = maxf(float(input.get("throttle", 0.0)), 0.7)
			if race != null and race.race_started and race.race_time < 1.25:
				input["steer"] = clampf(float(input.get("steer", 0.0)) + 0.55, -1.0, 1.0)
				input["handbrake"] = true
			else:
				input["handbrake"] = false
		else:
			input = _autopilot_input()
			if shot_scene == "nitro":
				# 自动驾驶会在弯前收油，踏力不足时氮气按真实规则自动断开；拍摄时保持油门。
				input["throttle"] = maxf(float(input.get("throttle", 0.0)), 0.85)
				input["nitro"] = true
	elif verify_mode:
		input = _autopilot_input()
	elif _drift_test_mode:
		input = _drift_test_input()
	elif race.state == RaceManager.State.COUNTDOWN:
		input = COUNTDOWN_INPUT
	elif race.player_finished or race.state == RaceManager.State.FINISHED or race.state == RaceManager.State.RESULTS:
		input = {"steer": car.steer * 0.4, "throttle": -0.25, "handbrake": false, "nitro": false, "reverse_pressed": false}
	elif current_mode == "duel" and duel_p2 != null:
		input = InputSetup.read_duel_input(0)
		if Settings.get("steer_sensitivity") != null:
			var sens_d := float(Settings.get("steer_sensitivity"))
			input["steer"] = clampf(float(input.get("steer", 0.0)) * sens_d, -1.0, 1.0)
	else:
		input = InputSetup.read_drive_input()
		if Settings.get("steer_sensitivity") != null:
			var sens := float(Settings.get("steer_sensitivity"))
			input["steer"] = clampf(float(input.get("steer", 0.0)) * sens, -1.0, 1.0)
	car.update_car(dt, input)
	_top_speed_kph = maxf(_top_speed_kph, car.speed_kph)
	if car.nitro_active and not _was_nitro:
		_nitro_use_count += 1
	_was_nitro = car.nitro_active
	if absf(car.lat_slip) > 2.2 and car.speed_kph > 25.0:
		_drift_time += dt
	if race.state == RaceManager.State.RACING and not race.player_finished and track_path != null:
		_line_acc += dt
		if _line_acc >= 0.12:
			_line_acc = 0.0
			var info := track_path.nearest(car.pos, car.track_index)
			if not info.is_empty():
				_line_samples.append([
					float(info.get("dist", 0.0)),
					float(info.get("lateral", 0.0)),
					car.speed_kph,
				])
	if current_mode == "duel" and duel_p2 != null:
		var input2: Dictionary
		if race.state == RaceManager.State.COUNTDOWN:
			input2 = COUNTDOWN_INPUT
		elif race.state == RaceManager.State.RESULTS:
			input2 = {"steer": 0.0, "throttle": -0.4, "handbrake": true, "nitro": false, "reverse_pressed": false}
		else:
			input2 = InputSetup.read_duel_input(1)
		duel_p2.update_car(dt, input2)
		_update_duel(dt)
		# 双人车之间简单防穿模
		if duel_p2 != null and car != null:
			var delta := duel_p2.pos - car.pos
			delta.y = 0.0
			var dist := delta.length()
			if dist < 3.6 and dist > 0.01:
				var push := delta / dist * (3.6 - dist) * 0.5
				car.pos -= push
				duel_p2.pos += push
		if split_screen != null and is_instance_valid(split_screen):
			split_screen.set_duel_laps(race.player_laps, duel_p2_laps)
			split_screen.set_race_info(race.player_laps, race.race_laps, race.race_time,
				int(race.state), race.countdown)
			split_screen.update_visuals()
	if car.gear != _last_gear_seen:
		var upshift := car.gear > _last_gear_seen
		_last_gear_seen = car.gear
		if haptics != null and haptics.has_method("on_shift"):
			haptics.on_shift(upshift, car.manual)
		if game_feel != null and game_feel.has_method("on_shift"):
			game_feel.on_shift()
	_update_player_pace(dt)
	if race.state != RaceManager.State.COUNTDOWN:
		for ai in ais:
			ai.update_ai(dt, car, race.race_laps, ais, race.player_pace)
	var impact := _resolve_car_contacts()
	if impact > 0.8:
		if audio != null:
			audio.play_impact(clampf(impact / 30.0, 0.08, 1.0))
		if haptics != null and haptics.has_method("on_impact"):
			haptics.on_impact(clampf(impact / 16.0, 0.25, 1.0))
		if last_hit_active:
			if game_feel != null and game_feel.has_method("on_impact"):
				game_feel.on_impact(clampf(impact / 30.0, 0.08, 1.0), last_hit_pos)
			last_hit_active = false
	# 护栏冲击：法向速度越大，掉速 / 震动 / 火花越强
	_wall_hit_cd = maxf(0.0, _wall_hit_cd - dt)
	if car.wall_contact and car.wall_impact > 2.6 and _wall_hit_cd <= 0.0 \
			and race.state == RaceManager.State.RACING:
		var ws := clampf((car.wall_impact - 2.6) / 18.0, 0.0, 1.0)
		if audio != null:
			audio.play_impact(clampf(0.12 + ws * 0.78, 0.12, 0.90))
		if haptics != null and haptics.has_method("on_impact"):
			haptics.on_impact(clampf(0.20 + ws * 0.80, 0.20, 1.0))
		if game_feel != null and game_feel.has_method("on_impact"):
			game_feel.on_impact(clampf(0.05 + ws * 0.70, 0.05, 0.78), car.wall_hit_point)
		_wall_hit_cd = lerpf(0.45, 0.20, ws)
	elif car.wall_contact and race.state == RaceManager.State.RACING \
			and absf(car.speed_forward) > 12.0 and game_feel != null \
			and game_feel.has_method("on_scrape"):
		# 贴墙持续磨蹭：速度越快火花越密（GameFeel 内部 90ms 冷却）。
		var scrape := clampf(absf(car.speed_forward) / 120.0, 0.06, 0.5)
		game_feel.on_scrape(scrape, car.wall_hit_point)
		if haptics != null and haptics.has_method("on_scrape"):
			haptics.on_scrape(scrape)
	if audio != null:
		var slip01 := clampf(car.lat_slip / 9.0, 0.0, 1.0)
		audio.update_ambience(clampf(car.speed_kph / 300.0, 0.0, 1.0), slip01, car.offroad, dt)
	if haptics != null and haptics.has_method("update_state"):
		haptics.update_state(dt, car, race.state)
	race.update(dt)
	_update_ghost(dt)
	if audio != null:
		audio.update_engine(car.rpm, car.throttle, clampf(car.speed_kph / 300.0, 0.0, 1.0), car.gear, (1 if car.limiter_active else 0))
	if game_feel != null and game_feel.has_method("update_state"):
		game_feel.update_state(dt, car, race.state)
	if cam != null and intro_cam == null and shot_scene != "venue" and shot_scene != "panorama" \
			and shot_scene != "rt" and shot_scene != "pack":
		cam.follow_update(dt)
	if hud != null:
		hud.refresh(race, car, track_path)
	if motion_blur_rect != null and car != null:
		var speed_frac := clampf(car.speed_kph / 270.0, 0.0, 1.0)
		# 加速时额外加一层拉丝：静止起步/出弯给油、氮气推进都能明显感到速度涌上来；
		# 松油门滑行只保留随速度的基础量，不会糊成一片。
		var accel01 := clampf(car.accel_vis / 12.0, 0.0, 1.0)
		var preset_id := String(Settings.preset()["id"])
		var amount := (pow(speed_frac, 0.92) * 0.98 + accel01 * 0.30) * Settings.motion_blur
		amount = minf(amount, 1.0)
		if preset_id != "high" and preset_id != "ultra" and not verify_mode:
			amount *= 0.55
		if shot_scene == "blur":
			amount = 0.85
		elif shot_scene != "":
			amount = 0.0
		_sync_post_amount(amount)
	if current_mode == "duel" and hud != null:
		hud.update_duel(race.player_laps if race != null else 0, duel_p2_laps,
			duel_p2.speed_kph if duel_p2 != null else 0.0, duel_winner)
	if race.state == RaceManager.State.RESULTS and not _results_shown:
		_results_shown = true
		if current_mode == "duel":
			if duel_winner == "":
				duel_winner = "P1"
			if hud != null:
				hud.visible = true
				hud.show_results(race)
				hud.show_duel_result(duel_winner, race.player_finish_time, duel_p2_finish_time)
		elif hud != null:
			hud.show_results(race)
		if hud != null:
			var targets := {}
			if ResourceLoader.exists("res://scripts/core/profile_store.gd") and race != null and race.track != null:
				var ps := load("res://scripts/core/profile_store.gd")
				if ps.has_method("medal_targets"):
					targets = ps.medal_targets(race.track, race.race_laps, race.mode, int(race.track_def.get("difficulty", 2)))
				var summary: Dictionary = ps.submit_race(race, car, {
					"nitro_uses": _nitro_use_count,
					"drift_time": _drift_time,
					"top_speed": _top_speed_kph,
					"drift_score": car.drift_bank if car != null else 0,
					"drift_combo": car.drift_max_combo if car != null else 1,
				})
				if hud.has_method("show_profile_progress"):
					hud.show_profile_progress(summary)
			if hud.has_method("append_result_line") and car != null and car.drift_bank > 0:
				hud.append_result_line("漂移得分  %d     最高连击  ×%d" % [
					car.drift_bank, car.drift_max_combo])
			if not targets.is_empty() and hud.has_method("append_result_line"):
				hud.append_result_line("奖牌目标  金 %s / 银 %s / 铜 %s" % [
					RaceManager.format_time(float(targets.get("gold", 0.0))),
					RaceManager.format_time(float(targets.get("silver", 0.0))),
					RaceManager.format_time(float(targets.get("bronze", 0.0)))])
			# 最近 10 次成绩 + 本场走线（AI 路线库）：只写一次，避免重开重复入库。
			if not _run_recorded:
				_run_recorded = true
				var run_total := race.player_finish_time
				if run_total <= 0.0:
					run_total = race.race_time
				var length := track_path.total_length if track_path != null else 0.0
				var line := RecordsStore.compress_line(_line_samples, length)
				RecordsStore.record_run(current_track_id, current_mode, current_car_id,
					run_total, race.best_lap_time, race.medal, line)
				if hud.has_method("append_result_line"):
					var runs := RecordsStore.history(current_track_id).size()
					var line_count := RecordsStore.line_candidates(current_track_id, 6).size()
					hud.append_result_line("赛道记录  %d / 10 次      AI 路线库  %d 条" % [runs, line_count])


## 开放世界的驾驶循环：没有圈数 / AI / 名次，只有车 + 世界 + 反馈。
func _physics_process_open_world(dt: float) -> void:
	var input: Dictionary = InputSetup.read_drive_input()
	if Settings.get("steer_sensitivity") != null:
		var sens := float(Settings.get("steer_sensitivity"))
		input["steer"] = clampf(float(input.get("steer", 0.0)) * sens, -1.0, 1.0)
	car.update_car(dt, input)
	_top_speed_kph = maxf(_top_speed_kph, car.speed_kph)
	if car.nitro_active and not _was_nitro:
		_nitro_use_count += 1
	_was_nitro = car.nitro_active
	if absf(car.lat_slip) > 2.2 and car.speed_kph > 25.0:
		_drift_time += dt
	if car.gear != _last_gear_seen:
		var upshift := car.gear > _last_gear_seen
		_last_gear_seen = car.gear
		if haptics != null and haptics.has_method("on_shift"):
			haptics.on_shift(upshift, car.manual)
		if game_feel != null and game_feel.has_method("on_shift"):
			game_feel.on_shift()
	if audio != null:
		var slip01 := clampf(car.lat_slip / 9.0, 0.0, 1.0)
		audio.update_ambience(clampf(car.speed_kph / 300.0, 0.0, 1.0), slip01, car.offroad, dt)
	if audio != null:
		audio.update_engine(car.rpm, car.throttle, clampf(car.speed_kph / 300.0, 0.0, 1.0), car.gear, (1 if car.limiter_active else 0))
	if game_feel != null and game_feel.has_method("update_state"):
		game_feel.update_state(dt, car, -1)
	_update_open_world(dt)


## 把车放回最近的公路（开放世界里的 R 键 / 深水自救）。
func _respawn_open_world() -> void:
	if open_world == null or car == null:
		return
	var p := open_world.nearest_road_point(car.pos.x, car.pos.z)
	car.pos = p + Vector3(0.0, 0.5, 0.0)
	car.vel = Vector3.ZERO
	car.speed_forward = 0.0
	car.speed_kph = 0.0
	if audio != null:
		audio.play_impact(0.35)


func _input(event: InputEvent) -> void:
	InputSetup.note_input(event)


func _unhandled_input(event: InputEvent) -> void:
	if state == AppState.MENU:
		if event is InputEventMouseMotion and (event.button_mask & MOUSE_BUTTON_MASK_LEFT):
			menu_car_angle += event.relative.x * 0.012
			menu_dragging = true
			if menu_car_pivot != null:
				menu_car_pivot.rotation.y = menu_car_angle
			return
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			menu_dragging = event.pressed
			return
	if state != AppState.RACE:
		return
	if event.is_action_pressed("reset_car"):
		if open_world_active:
			_respawn_open_world()
		else:
			_start_race(current_track_id, current_car_id, current_mode)
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("camera_mode") and cam != null and not open_world_active:
		var cam_label := cam.cycle_mode()
		if hud != null and hud.has_method("set_camera_name"):
			hud.set_camera_name(cam_label)
		get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F2:
		_open_settings()
		return
	# 结算界面手柄 shortcuts：A/START 确定返回菜单，X 重新比赛，Y 下一场。
	# （暂停菜单在 RESULTS 状态不可用，不接住这些键手柄玩家会卡在结算页。）
	if race != null and race.state == RaceManager.State.RESULTS \
			and event is InputEventJoypadButton and (event as InputEventJoypadButton).pressed:
		var btn := (event as InputEventJoypadButton).button_index
		if btn == JOY_BUTTON_A or btn == JOY_BUTTON_START:
			_show_menu()
			get_viewport().set_input_as_handled()
			return
		if btn == JOY_BUTTON_X:
			_start_race(current_track_id, current_car_id, current_mode)
			get_viewport().set_input_as_handled()
			return
		if btn == JOY_BUTTON_Y:
			_start_race(_next_track_id(current_track_id), current_car_id, current_mode)
			get_viewport().set_input_as_handled()
			return
	# 手柄 START / Esc：暂停（菜单里 START 由各界面自己处理）
	if event.is_action_pressed("ui_cancel") and not open_world_active:
		_open_pause()
		get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and event.pressed and not event.echo:
		var key := (event as InputEventKey).keycode
		if key == KEY_ESCAPE:
			_open_pause()
			get_viewport().set_input_as_handled()
		elif key == KEY_M:
			_show_menu()
			get_viewport().set_input_as_handled()
		elif key == KEY_ENTER and race != null and race.state == RaceManager.State.RESULTS:
			var next_track := _next_track_id(current_track_id)
			_start_race(next_track, current_car_id, current_mode)
			get_viewport().set_input_as_handled()


# ---------------------------------------------------------------------------
# menu / race lifecycle
# ---------------------------------------------------------------------------

func _show_menu() -> void:
	_clear_race()
	_sync_post_amount(0.0)
	state = AppState.MENU
	if not _arg_car.is_empty():
		# 截图/拍片时 --car 强制展厅展示指定座驾
		Settings.last_car = _arg_car
	menu = Menu.new()
	menu.name = "Menu"
	add_child(menu)
	menu.start_requested.connect(_on_menu_start)
	menu.garage_requested.connect(_on_menu_garage)
	menu.settings_requested.connect(_open_settings)
	menu.achievements_requested.connect(_open_achievements)
	menu.daily_requested.connect(_open_daily)
	menu.archive_requested.connect(_open_circuit_archive)
	menu.selection_changed.connect(_on_menu_selection)
	menu.track_changed.connect(_on_menu_track_changed)
	_build_menu_showroom(menu.selected_track_id(), menu.selected_car_id())
	if not _arg_track.is_empty():
		# 截图/调试时用 --track 强制指定菜单预览的赛道
		for i in GameData.tracks.size():
			if String(GameData.tracks[i].get("id", "")) == _arg_track:
				menu.track_index = i
				menu.refresh()
				break
	if audio != null:
		audio.play_menu_bgm()


func _on_menu_selection(car_id: String) -> void:
	if menu_world != null and car_id != menu_car_id:
		_menu_build_car(car_id)


func _on_menu_track_changed(track_id: String) -> void:
	if track_id == menu_track_id:
		return
	_build_menu_showroom(track_id, menu.selected_car_id() if menu != null else "")


func _menu_scene_path(track_id: String) -> String:
	return "res://assets/menu_scenes/%s.scn" % track_id


func _start_menu_preload(track_id: String) -> void:
	if track_id.is_empty() or _menu_scene_cache.has(track_id):
		return
	var path := _menu_scene_path(track_id)
	if not ResourceLoader.exists(path) or _menu_preload_started.has(track_id):
		return
	_menu_preload_started[track_id] = true
	ResourceLoader.load_threaded_request(path, "PackedScene", true)


func _try_cache_preloaded(track_id: String) -> void:
	if _menu_scene_cache.has(track_id) or track_id.is_empty():
		return
	var path := _menu_scene_path(track_id)
	if not ResourceLoader.exists(path):
		return
	if ResourceLoader.load_threaded_get_status(path) == ResourceLoader.THREAD_LOAD_LOADED:
		_menu_scene_cache[track_id] = ResourceLoader.load_threaded_get(path) as PackedScene
		_menu_cache_order.append(track_id)


func _preferred_menu_track() -> String:
	var wanted := Settings.last_track
	if not wanted.is_empty():
		for def in GameData.tracks:
			if String(def.get("id", "")) == wanted:
				return wanted
	if GameData.tracks.is_empty():
		return ""
	return String(GameData.tracks[0].get("id", ""))


func _instantiate_menu_scene(packed: PackedScene, track_id: String, car_id: String) -> bool:
	if packed == null:
		return false
	menu_world = packed.instantiate() as Node3D
	if menu_world == null:
		return false
	menu_world.name = "MenuShowroom"
	add_child(menu_world)
	menu_track_id = track_id
	print("[MENU] scene ready: ", track_id)
	if bool(GameData.track(track_id).get("realCity", false)):
		CityFacadesScript.apply(menu_world)
	menu_car_pivot = menu_world.get_node_or_null("MenuCarPivot") as Node3D
	menu_cam = menu_world.get_node_or_null("MenuCamera") as Camera3D
	if menu_cam != null:
		menu_cam.current = true
	if menu_car_pivot != null:
		menu_car_angle = menu_car_pivot.rotation.y
	_menu_build_car(car_id)
	_decorate_menu_scene()
	return true


func _decorate_menu_scene() -> void:
	if menu_world == null:
		return
	var def := GameData.track(menu_track_id)
	var theme: Dictionary = def.get("theme", {})
	var night := SceneryKit.is_night_theme(theme)
	var dark_menu := night or menu_track_id in ["glacier", "magma", "canyon"]
	var accent := Color.from_string(String(theme.get("accent", "#4fe9ff")), Color(0.3, 0.85, 0.95))
	if menu_track_id in ["glacier", "alpine", "pass", "canyon", "magma", "harbor", "city", "skyline"]:
		for node in menu_world.find_children("*", "Node3D", true, false):
			var nname := String(node.name).to_lower()
			if nname.contains("big_screen") and (node is MeshInstance3D or node.get_child_count() > 0):
				if node is Node3D:
					(node as Node3D).visible = false
	for child in menu_world.find_children("*", "WorldEnvironment", true, false):
		var we := child as WorldEnvironment
		if we == null or we.environment == null:
			continue
		var env := we.environment
		if menu_env_backup.is_empty():
			menu_env_backup = {
				"world": we,
				"exposure": env.tonemap_exposure, "ambient": env.ambient_light_energy,
				"ssr": env.ssr_enabled, "ssil": env.ssil_enabled,
				"ssao": env.ssao_intensity, "brightness": env.adjustment_brightness,
				"fog_color": env.fog_light_color, "fog_density": env.fog_density,
				"glow_intensity": env.glow_intensity, "glow_bloom": env.glow_bloom,
				"glow_hdr": env.glow_hdr_threshold,
			}
		var expo_mul := 1.75 if dark_menu else 1.10
		if menu_track_id == "alpine":
			expo_mul = 0.88
		env.tonemap_exposure = minf(env.tonemap_exposure * expo_mul, 2.1)
		env.ssr_enabled = false
		env.ssil_enabled = false
		env.ssao_intensity = minf(env.ssao_intensity, 2.2)
		env.adjustment_brightness = maxf(env.adjustment_brightness, 1.06 if not dark_menu else 1.16)
		# 展台车漆高光收紧：白车/亮色车不再糊成一团发光，暗部保留。
		env.glow_hdr_threshold = maxf(env.glow_hdr_threshold, 1.42)
		env.glow_intensity *= 0.78
		env.glow_bloom = minf(env.glow_bloom, 0.04)
		if dark_menu:
			env.ambient_light_energy = minf(env.ambient_light_energy + 0.34, 0.95)
			env.fog_light_color = env.fog_light_color.lightened(0.14)
			env.fog_density *= 0.72
		if menu_track_id == "alpine":
			env.fog_density *= 0.42
			env.fog_light_color = Color(0.72, 0.80, 0.88)
		elif menu_track_id == "pass":
			# 雾岭的雾是主题的一部分，但菜单机位要看清算路，压薄一档
			env.fog_density *= 0.58
			env.fog_light_color = env.fog_light_color.lightened(0.10)
	if menu_car_pivot == null:
		return
	# 稳定的展示补光：车在暗色赛道里也能看清；关掉会造成闪动的屏幕空间反射
	var car_pos := menu_car_pivot.global_position
	var key := SpotLight3D.new()
	key.position = car_pos + Vector3(4.5, 7.5, 4.5)
	key.light_color = Color(1.0, 0.94, 0.85)
	key.light_energy = 11.5 if dark_menu else 5.8
	key.spot_range = 32.0
	key.spot_angle = 46.0
	key.shadow_enabled = false
	menu_world.add_child(key)
	key.look_at(car_pos + Vector3(0.0, 0.8, 0.0), Vector3.UP)
	menu_decor_lights.append(key)
	var rim := SpotLight3D.new()
	rim.position = car_pos + Vector3(-6.0, 3.2, -6.0)
	rim.light_color = Color(0.55, 0.82, 1.0)
	rim.light_energy = 6.0 if dark_menu else 3.1
	rim.spot_range = 26.0
	rim.spot_angle = 42.0
	rim.shadow_enabled = false
	menu_world.add_child(rim)
	rim.look_at(car_pos + Vector3(0.0, 0.9, 0.0), Vector3.UP)
	menu_decor_lights.append(rim)
	var probe := ReflectionProbe.new()
	probe.position = car_pos + Vector3(0.0, 2.5, 0.0)
	probe.size = Vector3(14.0, 8.0, 14.0)
	probe.box_projection = true
	probe.interior = true
	probe.update_mode = ReflectionProbe.UPDATE_ONCE
	probe.max_distance = 40.0
	menu_world.add_child(probe)
	menu_decor_lights.append(probe)
	var fill := SpotLight3D.new()
	fill.position = car_pos + Vector3(-5.0, 4.5, -4.5)
	fill.light_color = accent
	fill.light_energy = 5.2 if dark_menu else 2.6
	fill.spot_range = 26.0
	fill.spot_angle = 50.0
	fill.shadow_enabled = false
	menu_world.add_child(fill)
	fill.look_at(car_pos + Vector3(0.0, 0.8, 0.0), Vector3.UP)
	menu_decor_lights.append(fill)
	# 菜单里关掉 TAA，避免静态场景地面高光像素闪烁
	get_viewport().use_taa = false


func _undecorate_menu_world() -> void:
	for n in menu_decor_lights:
		if is_instance_valid(n):
			n.queue_free()
	menu_decor_lights.clear()
	if not menu_env_backup.is_empty():
		# 菜单世界在 _start_race 里可能已随场景释放，直接 `as WorldEnvironment`
		# 会报 "Trying to cast a freed object"，所以先验有效性再转型。
		var stored: Variant = menu_env_backup.get("world", null)
		if is_instance_valid(stored) and stored is WorldEnvironment:
			var we: WorldEnvironment = stored
			if we.environment != null:
				var env := we.environment
				env.tonemap_exposure = float(menu_env_backup["exposure"])
				env.ambient_light_energy = float(menu_env_backup["ambient"])
				env.ssr_enabled = bool(menu_env_backup["ssr"])
				env.ssil_enabled = bool(menu_env_backup["ssil"])
				env.ssao_intensity = float(menu_env_backup["ssao"])
				env.adjustment_brightness = float(menu_env_backup["brightness"])
				env.fog_light_color = menu_env_backup["fog_color"]
				env.fog_density = float(menu_env_backup["fog_density"])
				env.glow_intensity = float(menu_env_backup["glow_intensity"])
				env.glow_bloom = float(menu_env_backup["glow_bloom"])
				env.glow_hdr_threshold = float(menu_env_backup["glow_hdr"])
	menu_env_backup.clear()


func _bake_menu_scenes() -> void:
	_bake_menu_active = true
	var dir := "res://assets/menu_scenes"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	for def in GameData.tracks:
		var id := String(def.get("id", ""))
		if id.is_empty():
			continue
		var t0 := Time.get_ticks_msec()
		_build_menu_showroom(id, "", true)
		if menu_world == null:
			continue
		var err := _pack_owned_scene(menu_world, "%s/%s.scn" % [dir, id])
		print("[BAKE] %s err=%s took=%dms" % [id, err, Time.get_ticks_msec() - t0])
		_free_menu_world()
	_bake_menu_active = false


func _run_bake_menu() -> void:
	_bake_menu_scenes()
	get_tree().quit()


func _assign_scene_owners(node: Node, root: Node) -> void:
	for child in node.get_children():
		child.owner = root
		if child.scene_file_path.is_empty():
			_assign_scene_owners(child, root)


func _convert_multimeshes(node: Node) -> void:
	for child in node.get_children():
		if child is MultiMeshInstance3D:
			var mi := child as MultiMeshInstance3D
			if mi.multimesh != null and mi.multimesh.instance_count > 0:
				var mm := mi.multimesh
				var xforms: Array[Transform3D] = []
				for i in mm.instance_count:
					xforms.append(mm.get_instance_transform(i))
				var colors: Array[Color] = []
				if mm.use_colors:
					for i in mm.instance_count:
						colors.append(mm.get_instance_color(i))
				mi.set_script(load("res://scripts/tracks/baked_multimesh.gd"))
				mi.set("baked_mesh", mm.mesh)
				mi.set("baked_material", mi.material_override)
				mi.set("baked_transforms", xforms)
				mi.set("baked_colors", colors)
				mi.multimesh = null
		_convert_multimeshes(child)


func _pack_owned_scene(root: Node, path: String) -> int:
	_convert_multimeshes(root)
	_assign_scene_owners(root, root)
	var ps := PackedScene.new()
	var err := ps.pack(root)
	if err != OK:
		return err
	return ResourceSaver.save(ps, path)


func _build_menu_showroom(track_id: String, car_id: String, bake_only: bool = false) -> void:
	# 参考旧网页版：每条赛道把车真实停在赛道上的一个特色点，
	# 用该站专属机位取景，车只是场景里的一部分（不放大、不贴图）。
	_free_menu_world()
	var def := GameData.track(track_id)
	if def.is_empty():
		return
	menu_track_id = track_id
	# 开放世界没有赛道可预览，改用「大陆沙盘」：圆盘 + 八区微缩建筑 + 环形主干道
	if bool(def.get("openWorld", false)):
		_build_open_world_showroom(car_id, bake_only)
		return
	# 预烘焙场景：运行时直接实例化，换图不用再现场建世界（3.7s 景物 + 1.3s 场馆）
	var baked_path := _menu_scene_path(track_id)
	if not bake_only:
		_try_cache_preloaded(track_id)
	if not bake_only and ResourceLoader.exists(baked_path):
		if not _menu_scene_cache.has(track_id) and (shot_mode or verify_mode or _perf_mode):
			_menu_scene_cache[track_id] = load(baked_path) as PackedScene
			_menu_cache_order.append(track_id)
		if _menu_scene_cache.has(track_id):
			if _instantiate_menu_scene(_menu_scene_cache[track_id] as PackedScene, track_id, car_id):
				_trim_menu_cache(track_id)
				return
		# 没缓存：后台线程读场景，转场动画继续动，读完瞬间实例化
		_menu_build_token += 1
		_pending_menu_token = _menu_build_token
		_pending_menu_track = track_id
		_pending_menu_car = car_id
		_start_menu_preload(track_id)
		_begin_loading("正在准备  %s" % String(def.get("name", track_id)))
		return
	menu_world = Node3D.new()
	menu_world.name = "MenuShowroom"
	add_child(menu_world)
	_setup_environment(menu_world, def)

	if bool(def.get("realCity", false)):
		_build_city_showroom(car_id, bake_only)
		return

	var builder := TrackBuilder.new()
	builder.name = "MenuTrack"
	menu_world.add_child(builder)
	var path := builder.build(def)
	SceneryKit.build(menu_world, path, def)
	VenueKit.build(menu_world, path, def, def.get("theme", {}))
	# 应用场景装饰编辑器保存的改动（菜单预览也要一致）
	DecorOverrides.apply(menu_world, String(def.get("id", "")))

	# ① 特色点：曲率最大的弯（该赛道最有代表性的位置），车停在弯前一点
	var hero_index := 0
	if track_id in ["city", "skyline"]:
		# 城市两张：选靠中段的直道（曲率最小）当展示点——楼夹道沿路收束的透视更好看，
		# 也不会像弯道最大处那样把相机怼到某栋楼的背面/大招牌上。
		var best_c := 1e9
		hero_index = int(path.samples.size() * 0.35)
		var span_start := int(path.samples.size() * 0.18)
		var span_end := int(path.samples.size() * 0.82)
		for i in range(span_start, span_end):
			var c := absf(path.curvatures[i])
			if c < best_c:
				best_c = c
				hero_index = i
	else:
		var hero_curv := 0.0
		for i in range(20, path.samples.size() - 20):
			var c := absf(path.curvatures[i])
			if c > hero_curv:
				hero_curv = c
				hero_index = i
	var spot_index := maxi(hero_index - 6, 8)
	var spot_dist := path.accumulated[spot_index]
	var frame := path.frame_at(spot_dist)
	if frame.is_empty():
		_free_menu_world()
		return
	var tangent: Vector3 = frame["tangent"]
	var side: Vector3 = frame["side"]
	var half := path.half_width
	var curvature := float(path.curvatures[spot_index])
	var outside := side * (signf(curvature) if absf(curvature) > 0.0001 else 1.0)

	# ② 车真实的停位：略偏赛道一侧，车身斜着摆（展示角度）
	var car_pos: Vector3 = (frame["pos"] as Vector3) + side * (-half * 0.28)
	var car_yaw := atan2(tangent.x, tangent.z) + 0.42
	menu_car_pivot = Node3D.new()
	menu_car_pivot.name = "MenuCarPivot"
	menu_car_pivot.position = car_pos + Vector3(0.0, 0.03, 0.0)
	menu_car_pivot.rotation.y = car_yaw
	menu_world.add_child(menu_car_pivot)
	menu_car_angle = car_yaw
	if not bake_only:
		_menu_build_car(car_id)

	# ③ 车前的柔和补光（让车在场景里亮起来，但不夸张）
	var key := SpotLight3D.new()
	key.position = car_pos + outside * 5.0 - tangent * 4.0 + Vector3(0.0, 7.0, 0.0)
	key.light_color = Color(1.0, 0.93, 0.82)
	key.light_energy = 7.0
	key.spot_range = 26.0
	key.spot_angle = 40.0
	key.shadow_enabled = false
	menu_world.add_child(key)
	key.look_at(car_pos + Vector3(0.0, 0.7, 0.0), Vector3.UP)

	# ④ 该站专属机位：弯道外侧、贴近地面，从车侧前方看，赛道向远处延伸
	# 城市图两侧楼贴得很近（临街面距路肩 6~13m），旧「外侧机位」会正对楼背面/山壁，
	# 所以城市两张改成从弯内看过去——车在前景、背景是外侧楼群的临街立面。
	var cam_side := outside
	if track_id == "skyline":
		cam_side = -outside
	var cam_pos := car_pos + cam_side * 7.5 - tangent * 6.0 + Vector3(0.0, 2.05, 0.0)
	var look := car_pos + tangent * 5.5 + Vector3(0.0, 0.85, 0.0)
	if track_id == "city":
		# 城市峡谷：站路中车后上方沿直道看，两排楼临街面在画面两侧收束，
		# 不会被楼背面/大招牌堵住背景；车保持左前 3/4 展示角度。
		cam_pos = car_pos - tangent * 6.8 + side * 0.8 + Vector3(0.0, 1.9, 0.0)
		look = car_pos + tangent * 16.0 + Vector3(0.0, 1.1, 0.0)
	menu_cam = Camera3D.new()
	menu_cam.name = "MenuCamera"
	menu_cam.fov = 46.0
	menu_world.add_child(menu_cam)
	menu_cam.current = true
	menu_cam.global_position = cam_pos
	# 自适应构图：把车稳定放到画面左侧约 32% 处，保证任何弯道都完整入镜
	var vp_size := get_viewport().get_visible_rect().size
	for it in 5:
		menu_cam.look_at(look, Vector3.UP)
		var car_screen := menu_cam.unproject_position(car_pos + Vector3(0.0, 0.85, 0.0))
		var ndc_x := (car_screen.x / maxf(vp_size.x, 1.0)) * 2.0 - 1.0
		var diff := ndc_x - (-0.36)
		if absf(diff) < 0.015:
			break
		var cam_right := menu_cam.global_transform.basis.x.normalized()
		var dist := menu_cam.global_position.distance_to(car_pos)
		var half_w := tan(deg_to_rad(menu_cam.fov * 0.5)) * dist * (vp_size.x / maxf(vp_size.y, 1.0))
		look += cam_right * (diff * half_w * 0.45)
	menu_cam.look_at(look, Vector3.UP)
	if not _bake_menu_active:
		_decorate_menu_scene()
	if streamer != null:
		streamer.enabled = not (shot_mode and shot_scene in ["panorama", "rt", "venue"])
		streamer.setup(menu_cam, menu_world)


## 实景城市展台：直接实例化 Blender 导出的都会模型，车停在环线起跑直道上，
## 相机沿长街看出去。模型路面中位高度 z=-0.15m，整体上抬 0.15 → 路面正好 y=0，
## 和 TrackPath 的平面完全对齐。
const CITY_RING_SCENE := "res://assets/thirdparty/city_ring/city_ring.glb"
const CITY_RING_RAISE := 0.15


func add_city_model(parent: Node3D) -> Node3D:
	if not ResourceLoader.exists(CITY_RING_SCENE):
		push_error("Main: missing city model %s" % CITY_RING_SCENE)
		return null
	var packed := load(CITY_RING_SCENE) as PackedScene
	if packed == null:
		return null
	var inst := packed.instantiate() as Node3D
	if inst == null:
		return null
	inst.name = "CityRing"
	inst.position = Vector3(0.0, CITY_RING_RAISE, 0.0)
	parent.add_child(inst)
	CityFacadesScript.apply(inst)
	return inst


func _build_city_showroom(car_id: String, bake_only: bool = false) -> void:
	add_city_model(menu_world)
	var path := TrackPath.new()
	path.build_from_def(GameData.track(menu_track_id), 2.0)
	# 展示点放在起跑直道中段：两侧是都会主街的高楼，透视最像宣传片。
	var spot_dist := path.total_length * 0.015
	var frame := path.frame_at(spot_dist)
	if frame.is_empty():
		return
	var tangent: Vector3 = frame["tangent"]
	var side: Vector3 = frame["side"]
	var hw := float(frame.get("half_width", path.half_width))
	var car_pos: Vector3 = (frame["pos"] as Vector3) + side * (-hw * 0.42)
	var car_yaw := atan2(tangent.x, tangent.z) + 0.16
	menu_car_pivot = Node3D.new()
	menu_car_pivot.name = "MenuCarPivot"
	menu_car_pivot.position = car_pos + Vector3(0.0, 0.03, 0.0)
	menu_car_pivot.rotation.y = car_yaw
	menu_world.add_child(menu_car_pivot)
	menu_car_angle = car_yaw
	if not bake_only:
		_menu_build_car(car_id)

	var key := SpotLight3D.new()
	key.position = car_pos + side * 6.0 - tangent * 5.0 + Vector3(0.0, 8.0, 0.0)
	key.light_color = Color(1.0, 0.93, 0.82)
	key.light_energy = 7.0
	key.spot_range = 28.0
	key.spot_angle = 44.0
	key.shadow_enabled = false
	menu_world.add_child(key)
	key.look_at(car_pos + Vector3(0.0, 0.7, 0.0), Vector3.UP)

	# 机位压在车后 8m、离地 2m 沿街看出去：车在左前景，街道消失点在画面中右。
	var cam_pos := car_pos - tangent * 8.0 + side * 1.2 + Vector3(0.0, 2.0, 0.0)
	var look := car_pos + tangent * 22.0 + Vector3(0.0, 1.15, 0.0)
	menu_cam = Camera3D.new()
	menu_cam.name = "MenuCamera"
	menu_cam.fov = 48.0
	menu_world.add_child(menu_cam)
	menu_cam.current = true
	menu_cam.global_position = cam_pos
	var vp_size := get_viewport().get_visible_rect().size
	for it in 5:
		menu_cam.look_at(look, Vector3.UP)
		var car_screen := menu_cam.unproject_position(car_pos + Vector3(0.0, 0.85, 0.0))
		var ndc_x := (car_screen.x / maxf(vp_size.x, 1.0)) * 2.0 - 1.0
		var diff := ndc_x - (-0.36)
		if absf(diff) < 0.015:
			break
		var cam_right := menu_cam.global_transform.basis.x.normalized()
		var dist := menu_cam.global_position.distance_to(car_pos)
		var half_w := tan(deg_to_rad(menu_cam.fov * 0.5)) * dist * (vp_size.x / maxf(vp_size.y, 1.0))
		look += cam_right * (diff * half_w * 0.45)
	menu_cam.look_at(look, Vector3.UP)
	if not _bake_menu_active:
		_decorate_menu_scene()
	if streamer != null:
		streamer.enabled = not (shot_mode and shot_scene in ["panorama", "rt", "venue"])
		streamer.setup(menu_cam, menu_world)


## 开放世界菜单预览：一座「大陆沙盘」——圆盘代表整片大陆，八簇微缩建筑
## 按真实方位摆放在环上，中央是枢纽塔与主干道，车停在环道上。
func _build_open_world_showroom(car_id: String, bake_only: bool = false) -> void:
	menu_world = Node3D.new()
	menu_world.name = "MenuShowroom"
	add_child(menu_world)
	var def := GameData.track(menu_track_id)
	_setup_environment(menu_world, def)

	var accent := Color.from_string(String(def.get("theme", {}).get("accent", "#7fd8ff")), Color(0.4, 0.85, 0.95))
	var cjk: Font = UIStyle.system_cjk_font()

	# 沙盘机位离模型近 900 米，赛道主题的雾会把整块大陆洗成一片橙。
	# 压掉雾 / 体积雾，八区的配色和轮廓才读得出来。
	if _env != null:
		_env.fog_density = 0.00005
		_env.volumetric_fog_enabled = false
		_env.fog_aerial_perspective = 0.0
	# 主光改成高位侧前方：主题默认太阳压得很低，沙盘上全是长影子看不出体积
	var sun := menu_world.get_node_or_null("Sun") as DirectionalLight3D
	if sun != null:
		var sd := Vector3(-0.19, 0.73, -0.65).normalized()
		sun.transform = Transform3D(Basis.looking_at(-sd, Vector3.UP), Vector3.ZERO)

	# ── 海：沙盘外圈一大片深青，把画面四边压住
	var sea_mi := MeshInstance3D.new()
	sea_mi.mesh = _annulus_mesh(294.0, 1500.0, 128)
	var sea_mat := StandardMaterial3D.new()
	sea_mat.albedo_color = Color(0.035, 0.092, 0.132)
	sea_mat.roughness = 0.26
	sea_mat.metallic = 0.42
	sea_mat.metallic_specular = 0.62
	sea_mi.material_override = sea_mat
	sea_mi.position = Vector3(0.0, -1.6, 0.0)
	menu_world.add_child(sea_mi)

	# 海岸浪花带（别太宽，不然整块沙盘像只瓷盘）
	var foam_mi := MeshInstance3D.new()
	foam_mi.mesh = _annulus_mesh(294.0, 309.0, 128)
	var foam_mat := StandardMaterial3D.new()
	foam_mat.albedo_color = Color(0.33, 0.55, 0.59)
	foam_mat.roughness = 0.78
	foam_mat.emission_enabled = true
	foam_mat.emission = Color(0.20, 0.42, 0.50)
	foam_mat.emission_energy_multiplier = 0.42
	foam_mi.material_override = foam_mat
	foam_mi.position = Vector3(0.0, -0.9, 0.0)
	menu_world.add_child(foam_mi)

	# ── 大陆圆盘
	var disc := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 300.0
	cyl.bottom_radius = 300.0
	cyl.height = 7.0
	cyl.radial_segments = 72
	disc.mesh = cyl
	var disc_mat := StandardMaterial3D.new()
	disc_mat.albedo_color = Color(0.055, 0.082, 0.098)
	disc_mat.roughness = 0.94
	disc_mat.albedo_texture = UIStyle.grid_texture(Color(0.35, 0.70, 0.85, 0.22), 26)
	disc_mat.uv1_scale = Vector3(7.0, 7.0, 1.0)
	disc.material_override = disc_mat
	disc.position = Vector3(0.0, -3.5, 0.0)
	menu_world.add_child(disc)

	# 海岸棱线：大陆边缘一圈暖色轮廓
	var rim_mi := MeshInstance3D.new()
	rim_mi.mesh = _annulus_mesh(292.0, 300.0, 128)
	var rim_mat := StandardMaterial3D.new()
	rim_mat.albedo_color = Color(0.80, 0.68, 0.46)
	rim_mat.roughness = 0.85
	rim_mat.emission_enabled = true
	rim_mat.emission = Color(0.92, 0.66, 0.38)
	rim_mat.emission_energy_multiplier = 0.55
	rim_mi.material_override = rim_mat
	rim_mi.position = Vector3(0.0, 0.05, 0.0)
	menu_world.add_child(rim_mi)

	# ── 路网：环形主干道 + 八条辐射支线
	var road_mat := PbrAssets.road()
	road_mat.albedo_color = Color(0.60, 0.61, 0.63)
	road_mat.uv1_scale = Vector3(16.0, 5.0, 1.0)
	var ring := MeshInstance3D.new()
	ring.mesh = _annulus_mesh(238.0, 256.0, 128)
	ring.material_override = road_mat
	ring.position = Vector3(0.0, 0.10, 0.0)
	menu_world.add_child(ring)

	# 环道两侧的引导线（发光）：一眼就能认出「主干道」
	var edge_mat := StandardMaterial3D.new()
	edge_mat.albedo_color = Color(0.92, 0.95, 1.0)
	edge_mat.emission_enabled = true
	edge_mat.emission = accent
	edge_mat.emission_energy_multiplier = 1.50
	edge_mat.roughness = 0.45
	for rr in [238.0, 254.0]:
		var edge := MeshInstance3D.new()
		edge.mesh = _annulus_mesh(float(rr), float(rr) + 2.0, 128)
		edge.material_override = edge_mat
		edge.position = Vector3(0.0, 0.16, 0.0)
		menu_world.add_child(edge)

	# 辐射支线：把中心枢纽和八座区域城串起来
	var spoke_mat := StandardMaterial3D.new()
	spoke_mat.albedo_color = Color(0.21, 0.235, 0.26)
	spoke_mat.roughness = 0.90
	for i in 8:
		var a := TAU * float(i) / 8.0
		var d := Vector2(cos(a), sin(a))
		var bar := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(200.0, 0.7, 13.0)
		bar.mesh = bm
		bar.material_override = spoke_mat
		bar.position = Vector3(d.x * 136.0, 0.05, d.y * 136.0)
		bar.rotation.y = -a
		menu_world.add_child(bar)

	# ── 八座区域城：地台 + 楼群 + 地标塔 + 中英文标牌
	var rng := RandomNumberGenerator.new()
	rng.seed = 424242
	for zone in OpenWorld.ZONES:
		var zc: Vector2 = zone["center"]
		var dir := Vector2(zc.x, zc.y).normalized()
		var zc2 := Color.from_string(String(zone["accent"]), accent)
		var spoke_ang := dir.angle()
		var perp := Vector2(-dir.y, dir.x)
		var base_pos := dir * 206.0

		# 区域地台
		var pad := MeshInstance3D.new()
		var pm := CylinderMesh.new()
		pm.top_radius = 40.0
		pm.bottom_radius = 40.0
		pm.height = 1.4
		pm.radial_segments = 40
		pad.mesh = pm
		var pad_mat := StandardMaterial3D.new()
		pad_mat.albedo_color = zc2.darkened(0.74)
		pad_mat.roughness = 0.85
		pad_mat.emission_enabled = true
		pad_mat.emission = zc2
		pad_mat.emission_energy_multiplier = 0.30
		pad.material_override = pad_mat
		pad.position = Vector3(base_pos.x, 0.7, base_pos.y)
		menu_world.add_child(pad)

		# 楼群：围着地台排一圈，落在辐条方向 ±22° 内的空着给路让位
		for i in 14:
			var ang := TAU * float(i) / 14.0 + rng.randf_range(-0.10, 0.10)
			if absf(angle_difference(ang, spoke_ang)) < 0.38:
				continue
			var rad := rng.randf_range(11.0, 31.0)
			var p := base_pos + Vector2(cos(ang), sin(ang)) * rad
			var hgt := rng.randf_range(6.0, 30.0)
			var box := MeshInstance3D.new()
			var bm2 := BoxMesh.new()
			bm2.size = Vector3(rng.randf_range(6.5, 12.0), hgt, rng.randf_range(6.5, 12.0))
			box.mesh = bm2
			var m := StandardMaterial3D.new()
			m.albedo_color = zc2.darkened(0.58).lerp(Color(0.10, 0.11, 0.13), 0.35)
			m.roughness = 0.70
			m.emission_enabled = true
			m.emission = zc2
			m.emission_energy_multiplier = 0.16
			box.material_override = m
			box.position = Vector3(p.x, 1.4 + hgt * 0.5, p.y)
			box.rotation.y = rng.randf() * TAU
			menu_world.add_child(box)

		# 地标塔：每区一根发光尖塔，标出「八区域」
		var beacon_pos := base_pos + perp * 24.0
		var tower := MeshInstance3D.new()
		var tm := CylinderMesh.new()
		tm.top_radius = 1.4
		tm.bottom_radius = 4.6
		tm.height = 50.0
		tm.radial_segments = 8
		tower.mesh = tm
		var tm_mat := StandardMaterial3D.new()
		tm_mat.albedo_color = zc2.darkened(0.42)
		tm_mat.roughness = 0.45
		tm_mat.emission_enabled = true
		tm_mat.emission = zc2
		tm_mat.emission_energy_multiplier = 0.70
		tower.material_override = tm_mat
		tower.position = Vector3(beacon_pos.x, 1.4 + 25.0, beacon_pos.y)
		menu_world.add_child(tower)

		# 标牌：中文区名 + 英文区名。
		# 两行要拉到楼群（最高 30）和光柱（50）之上，且两行间距不能小于字高，
		# 否则英文行会被中文行压住、或者整体压在楼顶上看不清。
		var cn := _ow_label(String(zone["cn"]), Vector3(beacon_pos.x, 84.0, beacon_pos.y), zc2, 20.0, cjk)
		menu_world.add_child(cn)
		var en := _ow_label(String(zone["en"]), Vector3(beacon_pos.x, 70.0, beacon_pos.y), zc2.lightened(0.25), 10.0, cjk)
		menu_world.add_child(en)

	# ── 中央枢纽：塔 + 基座光环 + 四座卫星塔
	var hub := MeshInstance3D.new()
	var hub_mesh := CylinderMesh.new()
	hub_mesh.top_radius = 4.0
	hub_mesh.bottom_radius = 14.0
	hub_mesh.height = 78.0
	hub_mesh.radial_segments = 8
	hub.mesh = hub_mesh
	var hub_mat := StandardMaterial3D.new()
	# 枢纽塔用银白而不是饱和青蓝：沙盘里八座城是暖色为主，
	# 一根高饱和蓝塔杵在正中间太扎眼，像没配好色。
	hub_mat.albedo_color = Color(0.82, 0.84, 0.88)
	hub_mat.emission_enabled = true
	hub_mat.emission = Color(0.42, 0.70, 0.76)
	hub_mat.emission_energy_multiplier = 0.30
	hub_mat.roughness = 0.32
	hub.material_override = hub_mat
	hub.position = Vector3(0.0, 39.0, 0.0)
	menu_world.add_child(hub)

	# 枢纽基座光环
	var hub_ring := MeshInstance3D.new()
	hub_ring.mesh = _annulus_mesh(17.0, 31.0, 64)
	var hub_ring_mat := StandardMaterial3D.new()
	hub_ring_mat.albedo_color = accent.darkened(0.35)
	hub_ring_mat.emission_enabled = true
	hub_ring_mat.emission = accent
	hub_ring_mat.emission_energy_multiplier = 0.85
	hub_ring_mat.roughness = 0.4
	hub_ring.material_override = hub_ring_mat
	hub_ring.position = Vector3(0.0, 0.14, 0.0)
	menu_world.add_child(hub_ring)

	# 四座卫星塔
	for i in 4:
		var sa := TAU * float(i) / 4.0 + 0.4
		var sat := MeshInstance3D.new()
		var sm := CylinderMesh.new()
		sm.top_radius = 1.6
		sm.bottom_radius = 4.0
		sm.height = 34.0
		sm.radial_segments = 6
		sat.mesh = sm
		var sat_mat := StandardMaterial3D.new()
		sat_mat.albedo_color = accent.darkened(0.62)
		sat_mat.emission_enabled = true
		sat_mat.emission = accent
		sat_mat.emission_energy_multiplier = 0.32
		sat_mat.roughness = 0.5
		sat.material_override = sat_mat
		sat.position = Vector3(cos(sa) * 44.0, 17.0, sin(sa) * 44.0)
		menu_world.add_child(sat)

	# 枢纽标牌（浮在塔顶上方，避开对面区域的标牌）
	# 抬到 100/116：塔高 78，标牌压在 86 那一行会正好糊在塔尖上。
	var hub_cn := _ow_label("无界大陆", Vector3(0.0, 116.0, 0.0), accent, 22.0, cjk)
	menu_world.add_child(hub_cn)
	var hub_en := _ow_label("OPEN CONTINENT", Vector3(0.0, 100.0, 0.0), accent.lightened(0.30), 11.0, cjk)
	menu_world.add_child(hub_en)

	# ── 玩家车：停在环道上（离机位最近的一段），底下垫一圈高亮
	var car_ang := TAU * 0.3125
	var car_pos := Vector3(cos(car_ang) * 247.0, 0.0, sin(car_ang) * 247.0)
	var car_mark := MeshInstance3D.new()
	car_mark.mesh = _annulus_mesh(7.0, 15.0, 32)
	var mark_mat := StandardMaterial3D.new()
	mark_mat.albedo_color = Color(1.0, 0.95, 0.80)
	mark_mat.emission_enabled = true
	mark_mat.emission = Color(1.0, 0.86, 0.55)
	mark_mat.emission_energy_multiplier = 2.20
	mark_mat.roughness = 0.4
	car_mark.material_override = mark_mat
	car_mark.position = Vector3(car_pos.x, 0.20, car_pos.z)
	menu_world.add_child(car_mark)

	menu_car_pivot = Node3D.new()
	menu_car_pivot.name = "MenuCarPivot"
	menu_car_pivot.position = car_pos + Vector3(0.0, 0.1, 0.0)
	menu_car_pivot.rotation.y = -car_ang
	menu_world.add_child(menu_car_pivot)
	menu_car_angle = -car_ang
	if not bake_only:
		_menu_build_car(car_id)

	var key := SpotLight3D.new()
	key.position = car_pos + Vector3(5.0, 12.0, 9.0)
	key.light_color = Color(1.0, 0.93, 0.82)
	key.light_energy = 9.0
	key.spot_range = 44.0
	key.spot_angle = 40.0
	key.shadow_enabled = false
	menu_world.add_child(key)
	key.look_at(car_pos + Vector3(0.0, 0.7, 0.0), Vector3.UP)

	# 机位：高机位俯拍整块沙盘；右侧被数据面板压住，所以整体往左偏。
	menu_cam = Camera3D.new()
	menu_cam.name = "MenuCamera"
	menu_cam.fov = 40.0
	menu_world.add_child(menu_cam)
	menu_cam.current = true
	menu_cam.global_position = Vector3(-400.0, 480.0, 700.0)
	menu_cam.look_at(Vector3(166.0, 24.0, 95.0), Vector3.UP)
	if not _bake_menu_active:
		_decorate_menu_scene()
	if streamer != null:
		streamer.enabled = false
		streamer.setup(menu_cam, menu_world)


## 沙盘标牌：世界空间的中英文标签，永远正对相机。
func _ow_label(text: String, pos: Vector3, color: Color, height: float, font: Font) -> Label3D:
	var l := Label3D.new()
	l.text = text
	l.font = font
	l.font_size = 160
	l.pixel_size = height / 160.0
	l.modulate = color
	l.outline_size = 20
	l.outline_modulate = Color(0.02, 0.03, 0.05, 0.92)
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.shaded = false
	l.double_sided = true
	l.no_depth_test = true
	l.render_priority = 2
	l.position = pos
	return l



## 平环带网格（沙盘上的环形主干道）。
func _annulus_mesh(inner: float, outer: float, segs: int) -> ArrayMesh:
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idxs := PackedInt32Array()
	for i in segs:
		var a := TAU * float(i) / float(segs)
		verts.append(Vector3(cos(a) * inner, 0.0, sin(a) * inner))
		verts.append(Vector3(cos(a) * outer, 0.0, sin(a) * outer))
		norms.append(Vector3.UP)
		norms.append(Vector3.UP)
		uvs.append(Vector2(float(i) / float(segs) * 12.0, 0.0))
		uvs.append(Vector2(float(i) / float(segs) * 12.0, 1.0))
	for i in segs:
		var a0 := i * 2
		var a1 := ((i + 1) % segs) * 2
		# 顺时针绕序才是正面（Godot 正面判定），否则整圈会被背面剔除
		idxs.append(a0)
		idxs.append(a0 + 1)
		idxs.append(a1)
		idxs.append(a1)
		idxs.append(a0 + 1)
		idxs.append(a1 + 1)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idxs
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _contact_shadow_texture() -> Texture2D:
	var size := 128
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.0, 0.0, 0.0, 0.0))
	for y in size:
		for x in size:
			var dx := (float(x) - size * 0.5) / (size * 0.5)
			var dy := (float(y) - size * 0.5) / (size * 0.5)
			var d := sqrt(dx * dx + dy * dy)
			var a := clampf(1.0 - d, 0.0, 1.0)
			a = a * a * 0.9
			img.set_pixel(x, y, Color(0.0, 0.0, 0.0, a))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


func _menu_build_car(car_id: String) -> void:
	menu_car_id = car_id
	if menu_car_pivot == null or car_id.is_empty():
		return
	if menu_car_model != null:
		menu_car_model.queue_free()
		menu_car_model = null
	var spec := Garage.effective_spec(car_id)
	if spec.is_empty():
		spec = GameData.car(String(GameData.cars_specs[0].get("id", "")))
	var result := CarVisual.build(spec, menu_car_pivot)
	menu_car_model = result.get("model") as Node3D
	if menu_car_model != null:
		GarageLook.apply(menu_car_model, car_id, Garage.config(car_id))


func _animate_menu_showroom() -> void:
	if menu_car_pivot != null:
		if not menu_dragging:
			menu_car_angle += 0.18 * 0.016
		menu_car_pivot.rotation.y = menu_car_angle
	# 相机保持完全静止，避免细微抖动造成地面高光闪烁


func _on_menu_start(track_id: String, car_id: String, mode: String) -> void:
	_start_race(track_id, car_id, mode)


func _on_menu_garage(car_id: String) -> void:
	_open_garage(car_id)


func _free_menu_world() -> void:
	if streamer != null:
		streamer.clear()
	if menu_stage_viewport != null:
		menu_stage_viewport.queue_free()
		menu_stage_viewport = null
	elif menu_world != null:
		# 同样要立刻摘出场景树：切换赛道时旧沙盘会跟新沙盘叠一帧。
		if menu_world.get_parent() != null:
			menu_world.get_parent().remove_child(menu_world)
		menu_world.queue_free()
	menu_world = null
	menu_car_pivot = null
	menu_car_model = null
	menu_cam = null
	menu_car_id = ""
	menu_track_id = ""


func _open_garage(initial_car: String) -> void:
	_apply_quality()
	_free_menu_world()
	_clear_race()
	state = AppState.GARAGE
	garage_world = GarageWorld.new()
	garage_world.name = "GarageWorld"
	add_child(garage_world)
	garage_screen = GarageScreen.new()
	garage_screen.name = "GarageScreen"
	garage_screen.world = garage_world
	garage_screen.initial_car = initial_car
	garage_screen.closed.connect(_on_garage_closed)
	garage_screen.race_requested.connect(_on_garage_race)
	add_child(garage_screen)


func _on_garage_closed() -> void:
	_show_menu()


func _on_garage_race(car_id: String) -> void:
	_start_race(current_track_id, car_id, current_mode)


func _apply_demo_tune(car_id: String) -> void:
	var cfg := Garage.config(car_id)
	cfg["paint"] = 2
	cfg["wheel"] = 1
	cfg["tire"] = 1
	cfg["wing"] = 1
	cfg["caliper"] = 2
	for key in Garage.UPGRADE_KEYS:
		cfg[key] = 5
	Garage.save_to_disk()
	print("[TUNE] demo config applied to %s" % car_id)


func _start_race(track_id: String, car_id: String, mode: String) -> void:
	var prev_track := current_track_id
	var prev_state := state
	_apply_quality()
	_results_shown = false
	current_track_id = track_id
	current_car_id = car_id
	current_mode = mode
	track_def = GameData.track(track_id)
	if track_def.is_empty():
		track_def = GameData.track(DEFAULT_TRACK)
		current_track_id = DEFAULT_TRACK
	# 开放世界：九域合一的自由漫游地图，走完全独立的构建流程
	if bool(track_def.get("openWorld", false)):
		# 菜单里的沙盘世界（300m 圆盘 + 8 条辐射支线）必须先拆掉，
		# 否则它和菜单相机一起留在场景树里，玩家进场看到的就是俯视沙盘。
		_free_menu_world()
		_start_open_world(current_track_id, current_car_id, mode)
		return

	# 优先复用菜单里已经显示的那套真实 3D 世界 → 开赛几乎瞬间，不再现场建 5 秒
	var world: Node3D = null
	var loading_shown := false
	var loading_start := 0
	# 开赛 / 切赛道一律先给一段 1~2 秒的加载动画（重开同一张图除外）。
	# 旧版只有「没缓存、没菜单世界」时才显示，所以大多数时候一闪而过。
	var restarting := prev_state == AppState.RACE and prev_track == track_id
	if not shot_mode and not _perf_mode and not verify_mode and not restarting:
		_begin_loading("正在加载  %s" % String(track_def.get("name", track_id)))
		loading_shown = true
		loading_start = Time.get_ticks_msec()
		await get_tree().process_frame
	if menu_world != null and menu_track_id == track_id:
		_undecorate_menu_world()
		if menu_car_model != null:
			menu_car_model.queue_free()
		if menu_car_pivot != null:
			menu_car_pivot.queue_free()
		menu_car_model = null
		menu_car_pivot = null
		world = menu_world
		menu_world = null
		menu_cam = null
		menu_track_id = ""
		if world.get_parent() != null:
			world.get_parent().remove_child(world)
	elif _menu_scene_cache.has(track_id):
		world = (_menu_scene_cache[track_id] as PackedScene).instantiate() as Node3D
	elif ResourceLoader.exists(_menu_scene_path(track_id)) and not shot_mode and not _perf_mode and not verify_mode:
		var packed := load(_menu_scene_path(track_id)) as PackedScene
		if packed != null:
			world = packed.instantiate() as Node3D

	_free_menu_world()
	# 进比赛后菜单场景缓存只留当前图：其余的连同依赖贴图/网格常驻内存，
	# 8 张全留会触发系统内存交换，表现为进游戏后整体卡顿。
	for k in _menu_scene_cache.keys():
		if String(k) != current_track_id:
			_menu_scene_cache.erase(k)
			_menu_preload_started.erase(String(k))
	_menu_cache_order.clear()
	if _menu_scene_cache.has(current_track_id):
		_menu_cache_order.append(current_track_id)
	_clear_race()
	state = AppState.RACE

	race_root = Node3D.new()
	race_root.name = "RaceWorld"
	add_child(race_root)

	if world != null:
		world.name = "TrackWorld"
		for n in world.find_children("*", "Camera3D", true, false):
			if String(n.name) == "MenuCamera":
				n.queue_free()
		var marker := world.get_node_or_null("MenuCarPivot")
		if marker != null:
			marker.queue_free()
		race_root.add_child(world)
		track_path = TrackPath.new()
		track_path.build_from_def(track_def, 2.0)
		TrackBuilder.configure_terrain(track_path)
		# 菜单缓存里已经有整座城市模型，但碰撞体没有烘进场景，这里补上；
		# 缺了它车会退回主线走廊，中心城区全部变隐形墙。
		if bool(track_def.get("realCity", false)):
			_city_world = CityWorldScript.new()
			_city_world.name = "CityWorld"
			race_root.add_child(_city_world)
			_city_world.load_collision()
	else:
		_setup_environment(race_root, track_def)
		var builder := TrackBuilder.new()
		builder.name = "TrackBuilder"
		race_root.add_child(builder)
		if bool(track_def.get("realCity", false)):
			add_city_model(race_root)
			_city_world = CityWorldScript.new()
			_city_world.name = "CityWorld"
			race_root.add_child(_city_world)
			_city_world.load_collision()
			track_path = builder.build(track_def)
		else:
			track_path = builder.build(track_def)
			SceneryKit.build(race_root, track_path, track_def)
			_venue_stats = VenueKit.build(race_root, track_path, track_def, track_def.get("theme", {}))
			# 应用场景装饰编辑器保存的改动
			var _decor_applied := DecorOverrides.apply(race_root, current_track_id)
			if _decor_applied > 0:
				print("[DECOR] applied %d override(s) for %s" % [_decor_applied, current_track_id])
	if bool(track_def.get("realCity", false)):
		CityFacadesScript.apply(race_root)
	if track_path == null or track_path.samples.is_empty():
		push_error("Main: track build failed for %s" % current_track_id)
		if loading_shown:
			_end_loading()
		return

	_spawn_player()
	if car != null and _city_world != null:
		car.city = _city_world
	_spawn_duel_second()
	_nitro_use_count = 0
	_drift_time = 0.0
	_top_speed_kph = 0.0
	_was_nitro = false
	_last_gear_seen = 1
	_wall_hit_cd = 0.0
	_line_samples.clear()
	_line_acc = 0.0
	_run_recorded = false
	if car != null and SceneryKit.is_night_theme(track_def.get("theme", {})):
		car.add_headlights()
	_spawn_ai()

	weather = WeatherFX.new()
	weather.name = "Weather"
	add_child(weather)
	weather.setup(String(track_def.get("theme", {}).get("weather", "none")), track_def.get("theme", {}), car)

	cam = ChaseCamera.new()
	cam.name = "ChaseCamera"
	add_child(cam)
	cam.follow(car, track_path)
	if _city_world != null:
		# 城市实景没有走廊护栏：相机不能再用主环侧向夹紧。
		cam.world = _city_world
	if _arg_camera >= 0 and _arg_camera < 3:
		cam.mode = _arg_camera as ChaseCamera.Mode

	hud = RaceHUD.new()
	hud.name = "RaceHUD"
	add_child(hud)
	# 全景电影镜头不要赛车 HUD
	hud.visible = not (shot_mode and shot_scene == "panorama")
	hud.set_camera_name(cam.mode_label())
	if loading_shown:
		# 保证加载动画完整播 1.25s：即使场景已缓存/瞬间建好也不闪一下就没。
		var elapsed := float(Time.get_ticks_msec() - loading_start) / 1000.0
		if elapsed < 1.25:
			await get_tree().create_timer(1.25 - elapsed).timeout
		_end_loading()

	race = RaceManager.new()
	var laps := int(track_def.get("laps", 3))
	var laps_override = Settings.get("laps_override")
	if laps_override != null and int(laps_override) > 0:
		laps = int(laps_override)
	var race_mode := "ta" if current_mode == "duel" else current_mode
	race.setup(track_path, track_def, laps, race_mode, car, ais)
	duel_total_laps = laps
	hud.bind_race(race, car, track_path)
	if current_mode == "duel" and duel_p2 != null:
		hud.bind_duel(duel_p2)
		_setup_split_screen()
	_setup_ghost()
	if ResourceLoader.exists("res://scripts/fx/game_feel.gd"):
		game_feel = load("res://scripts/fx/game_feel.gd").new()
		game_feel.name = "GameFeel"
		add_child(game_feel)
		if game_feel.has_method("setup"):
			game_feel.setup(self)
	if audio != null:
		audio.play_race_bgm(current_track_id)
		audio.start_engine()
		if audio.has_method("set_engine_profile") and car != null:
			audio.set_engine_profile(car.spec)
	if streamer != null:
		streamer.enabled = not (shot_mode and shot_scene in ["panorama", "rt", "venue"])
		streamer.setup(cam, race_root)
	if not shot_mode and not _perf_mode and not verify_mode and current_mode != "duel":
		_setup_race_intro_camera()


# ---------------------------------------------------------------------------
# 开放世界（无界大陆）
# ---------------------------------------------------------------------------

## 构建 9km×9km 的连续大地图：八张赛道的地貌缝在一起，没有赛道护栏，
## 也没有隐形边界——开出海岸线就是海，能开回来就行。
func _start_open_world(track_id: String, car_id: String, mode: String) -> void:
	_clear_race()
	state = AppState.RACE
	open_world_active = true
	_open_world_zone_theme = ""
	_open_world_rescue_cd = 0.0

	race_root = Node3D.new()
	race_root.name = "OpenWorldRoot"
	add_child(race_root)

	_begin_loading("正在生成无界大陆   9 × 9 km")
	await get_tree().process_frame

	open_world = OpenWorld.new()
	open_world.name = "OpenWorld"
	race_root.add_child(open_world)
	var tw := Time.get_ticks_msec()
	await open_world.build_stepped()
	var tw1 := Time.get_ticks_msec()
	# 布景流式生成：开局只建出生点周围，其余单元开车逼近才建、远离整体隐藏。
	# 全量常驻（17.7k 实例 / 7781 个分块）在 M1 Pro 上每帧 3500 万面、实测 5fps。
	var ow_stats: Dictionary = OpenWorldScenery.build_initial(open_world, race_root)
	var tw2 := Time.get_ticks_msec()
	print("[OW] world=%d ms  scenery(initial)=%d ms  instances=%d nodes=%d" % [
		tw1 - tw, tw2 - tw1, int(ow_stats.get("instances", 0)), int(ow_stats.get("nodes", 0))])

	_setup_environment(race_root, track_def)
	_open_world_sky_mat = _env.sky.sky_material as ShaderMaterial
	# 大平面在掠射角下会整片反射天空，看起来像水面（不是地形没了）。
	# 开放世界里地面就是大平面，关掉 SSR 才不会整片发亮。
	if _env != null:
		_env.ssr_enabled = false
		_env.ssil_enabled = false

	_spawn_player_open_world()
	_nitro_use_count = 0
	_drift_time = 0.0
	_top_speed_kph = 0.0
	_was_nitro = false
	_last_gear_seen = 1

	weather = WeatherFX.new()
	weather.name = "Weather"
	add_child(weather)
	weather.setup("none", track_def.get("theme", {}), car)

	cam = ChaseCamera.new()
	cam.name = "ChaseCamera"
	add_child(cam)
	cam.follow(car, null)
	cam.world = open_world
	# 相机接管必须显式指定：Godot 里后加入场景树的 Camera3D 不会自动成为
	# current，只有旧相机被释放后才会自动提升。菜单相机已经释放，这里手动接管。
	cam.current = true

	# 开放世界也是一条赛道：HUD 直接用 RaceHUD，和前八条赛道同一套控件，
	# 唯一多出来的是右上角的「无界大陆」全域图。
	hud = RaceHUD.new()
	hud.name = "RaceHUD"
	add_child(hud)
	hud.set_camera_name(cam.mode_label())
	hud.bind_open_world(open_world, car)

	if audio != null:
		audio.play_race_bgm(current_track_id)
		audio.start_engine()
		if audio.has_method("set_engine_profile") and car != null:
			audio.set_engine_profile(car.spec)
	if streamer != null:
		streamer.enabled = true
		# 开放世界视距收紧：布景可见距离已按树 / 楼 / 地标分类收过一轮，
		# 分块级远距再压一道；扇区余量也收紧（城市图分块大、余量大等于不剔）。
		streamer.max_distance = 1600.0
		streamer.tight_sector = true
		streamer.setup(cam, race_root)
	_end_loading()


## 开放世界玩家车：直接落在出生路口，没有赛道参照系。
func _spawn_player_open_world() -> void:
	var spec := Garage.effective_spec(current_car_id)
	if spec.is_empty():
		spec = GameData.car(current_car_id)
	if spec.is_empty():
		spec = GameData.car(DEFAULT_CAR)
	car = Car.new()
	car.name = "PlayerCar"
	add_child(car)
	var spawn: Dictionary = open_world.spawn()
	car.setup_open_world(spec, open_world, spawn, Color.TRANSPARENT, Garage.config(current_car_id))


## 区域切换时同步天空 / 雾 / 阳光，八个区域各有各的天气。
func _update_open_world_zone_theme() -> void:
	if open_world == null or car == null:
		return
	if _open_world_theme_cd > 0.0:
		return
	_open_world_theme_cd = 0.08
	var themes: Dictionary = track_def.get("zoneThemes", {})
	var base_theme: Dictionary = track_def.get("theme", {})
	# 域权重：过渡带里同时挂着两个域，按权重把两套主题混起来。
	# 这样「白天 → 黑天城市」是太阳一点点沉下去、星星一点点冒出来，
	# 「白天 → 熔岩盆地」是天空一点点烧红、雾一点点变成铁锈色，
	# 而不是在域边界上「啪」地一下把整个环境换掉。
	var ws: Array = open_world.zone_weights_at(car.pos.x, car.pos.z)
	if ws.is_empty():
		# 出了所有域（海上 / 荒野）：退回赛道主主题，别把上一域的夜色挂着不放。
		_blend_and_apply([], themes, base_theme)
		return
	_blend_and_apply(ws, themes, base_theme)


func _blend_and_apply(ws: Array, themes: Dictionary, base_theme: Dictionary) -> void:
	if ws.is_empty():
		var t := base_theme.duplicate(true)
		t["night01"] = clampf(float(t.get("stars", 0.0)), 0.0, 1.0)
		_apply_open_world_theme(t)
		return
	_apply_open_world_theme(_blend_zone_themes(ws, themes, base_theme))


## 域 id → zoneThemes 里的键。中央枢纽没有专属主题，用赛道主主题。
func _zone_theme_id(id: int) -> String:
	if id >= 0 and id < OpenWorld.ZONES.size():
		return String(OpenWorld.ZONES[id]["id"])
	return "hub"


## 把多个域的主题按权重混成一套。
## 颜色逐通道插值，数值取加权平均，数组（如 sunDir）取权重最大的那个。
## 额外算出一个 0..1 的 night01：它是「白天→黑夜」这条过渡线上的位置，
## 用来连续地调太阳亮度、星空和车灯，而不是用布尔值一刀切。
func _blend_zone_themes(ws: Array, themes: Dictionary, base_theme: Dictionary) -> Dictionary:
	var items: Array = []
	var keys: Dictionary = {}
	var night_acc := 0.0
	for e in ws:
		var id := int(e["id"])
		var zid := _zone_theme_id(id)
		var t: Dictionary = themes.get(zid, {})
		if t.is_empty():
			t = base_theme
		var w := float(e["w"])
		items.append({"theme": t, "w": w})
		# 夜量直接取 stars：它是每个域"有多黑"的作者意图。
		# neon 1.0 = 深夜，magma 0.3 = 火山黄昏，coast 0.0 = 正午。
		# 用它做连续量，白天→黑夜城市（0→1）和白天→火山（0→0.3）
		# 就是一条平滑的插值线。
		night_acc += clampf(float(t.get("stars", 0.0)), 0.0, 1.0) * w
		for k in t.keys():
			keys[k] = true
	var out: Dictionary = {}
	for k in keys.keys():
		var vals: Array = []
		var total := 0.0
		for item in items:
			var t: Dictionary = item["theme"]
			if not t.has(k):
				continue
			var w2 := float(item["w"])
			vals.append({"v": t[k], "w": w2})
			total += w2
		if vals.is_empty() or total <= 0.0001:
			continue
		var first = vals[0]["v"]
		if first is String and String(first).begins_with("#"):
			var acc := Color(0.0, 0.0, 0.0)
			for it in vals:
				acc += _c(it["v"], Color(0.0, 0.0, 0.0)) * (float(it["w"]) / total)
			out[k] = acc.to_html(false)
		elif first is Color:
			var acc2 := Color(0.0, 0.0, 0.0)
			for it in vals:
				acc2 += (it["v"] as Color) * (float(it["w"]) / total)
			out[k] = acc2
		elif first is float or first is int:
			var accf := 0.0
			for it in vals:
				accf += float(it["v"]) * (float(it["w"]) / total)
			out[k] = accf
		else:
			var best: Dictionary = vals[0]
			for it in vals:
				if float(it["w"]) > float(best["w"]):
					best = it
			out[k] = best["v"]
	out["night01"] = clampf(night_acc, 0.0, 1.0)
	return out


## 应用混合后的主题。night01 是连续昼夜量：
##   0.0 = 正午   0.5 = 黄昏/破晓   1.0 = 深夜
## 太阳亮度、颜色、星空、车灯全部跟着它连续变化。
func _apply_open_world_theme(theme: Dictionary) -> void:
	var night01 := clampf(float(theme.get("night01", 0.0)), 0.0, 1.0)
	var is_night := night01 > 0.5
	if _open_world_sky_mat != null:
		_open_world_sky_mat.set_shader_parameter("top_color",
			_c(theme.get("skyTop", "#1c62b4"), Color(0.11, 0.38, 0.71)))
		_open_world_sky_mat.set_shader_parameter("horizon_color",
			_c(theme.get("skyHorizon", "#d9eef2"), Color(0.85, 0.93, 0.95)))
		_open_world_sky_mat.set_shader_parameter("ground_color",
			_c(theme.get("skyBottom", "#8fc8d2"), Color(0.56, 0.78, 0.82)))
		_open_world_sky_mat.set_shader_parameter("cloud_light",
			_c(theme.get("cloudColor", "#ffffff"), Color(1.0, 1.0, 1.0)))
		_open_world_sky_mat.set_shader_parameter("night", night01)
		_open_world_sky_mat.set_shader_parameter("stars_amount",
			clampf(float(theme.get("stars", 0.0)) * night01, 0.0, 1.0))
	if _env != null:
		var amb := _c(theme.get("hemiSky", "#b4d8f8"), Color(0.70, 0.82, 0.95))
		# 环境光跟着昼夜连续走：白天是天空色，入夜逐渐转成冷蓝月光。
		amb = amb.lerp(Color(0.34, 0.42, 0.66), night01)
		_env.ambient_light_color = amb
		_env.ambient_light_energy = clampf(
			float(theme.get("ambientEnergy", 0.85 if is_night else 0.62)), 0.2, 1.2)
		_env.tonemap_exposure = clampf(float(theme.get("exposure", 1.05)) * 0.63, 0.54, 1.02)
		_base_fog_color = _c(theme.get("fogColor", "#c8e4ea"), Color(0.78, 0.89, 0.92)).darkened(0.34)
		_env.fog_light_color = _base_fog_color
		var fog_far := maxf(float(theme.get("fogFar", 3600.0)), 900.0)
		_base_fog_density = clampf(0.72 / fog_far, 0.00010, 0.00065)
		_env.fog_density = _base_fog_density
		_env.glow_intensity = clampf(float(theme.get("glowOpacity", 0.4)) * 1.1, 0.25, 1.4)
	if _sun != null:
		var sun_dir: Array = theme.get("sunDir", [0.42, 0.52, 0.2])
		var dir := Vector3(float(sun_dir[0]), float(sun_dir[1]), float(sun_dir[2])).normalized()
		if night01 < 0.5:
			# 太阳压得太低（<20°）时，几十米高的楼会把整片城区地面盖进阴影里，
			# 地面只剩冷色天光，看起来像结了一层蓝冰。这里保留下 1/3 但抬到 ~48°。
			dir = Vector3(dir.x, clampf(dir.y * 1.05, 0.28, 0.78), dir.z).normalized()
		_sun.transform = Transform3D(Basis.looking_at(-dir, Vector3.UP), Vector3.ZERO)
		# 太阳亮度在昼夜之间连续插值：黄昏时太阳沉到半亮、车灯还没开，
		# 这段正是「白天进入黑夜」最有质感的一段。
		var power := float(theme.get("sunPower", 5.0))
		var e_day := clampf(power * 0.46, 1.9, 3.2)
		var e_night := clampf(power * 0.30, 0.9, 2.0)
		_sun.light_energy = lerpf(e_day, e_night, night01)
		var c_day := _c(theme.get("sunColor", "#fff2da"), Color(1.0, 0.95, 0.86)).lerp(
			Color(1.0, 0.82, 0.58), 0.45)
		var c_night := _c(theme.get("sunColor", "#cdd8ff"), Color(0.8, 0.85, 1.0))
		_sun.light_color = c_day.lerp(c_night, night01)
	if car != null:
		if is_night:
			car.add_headlights()
		else:
			car.remove_headlights()


## 开放世界每帧更新：没有圈数、没有 AI、没有名次，只有车 + 世界。
func _update_open_world(dt: float) -> void:
	if car == null:
		return
	_open_world_theme_cd = maxf(0.0, _open_world_theme_cd - dt)
	_update_open_world_zone_theme()
	# 布景流式生成：逼近才建、远离隐藏；建了新单元就刷新扇区剔除器，
	# 让新分块立刻参与视野剔除而不是常开。
	if open_world != null and OpenWorldScenery.stream_tick(
			open_world, Vector2(car.pos.x, car.pos.z), dt):
		if streamer != null:
			streamer.collect()
	# 深水自救：开到海里泡太久就送回最近的道路
	_open_world_rescue_cd = maxf(0.0, _open_world_rescue_cd - dt)
	if car.world_depth > 2.4 and car.speed_kph < 6.0:
		_open_world_rescue_cd += dt
		if _open_world_rescue_cd > 4.0:
			_open_world_rescue_cd = 0.0
			var p := open_world.nearest_road_point(car.pos.x, car.pos.z)
			car.pos = p + Vector3(0.0, 0.4, 0.0)
			car.vel = Vector3.ZERO
			if audio != null:
				audio.play_impact(0.4)
	# 熔岩灼烧：持续减速
	if car.world_surface == "lava" and car.speed_kph > 20.0:
		if audio != null and fmod(_top_speed_kph, 1.0) < 0.02:
			pass
	# 相机跟随
	if cam != null:
		cam.follow_update(dt)
	# HUD：和赛道同一套控件，开放世界走 refresh_open_world 分支
	if hud != null:
		hud.refresh_open_world(open_world, car, dt)


func _setup_split_screen() -> void:
	if duel_p2 == null or car == null or cam == null or track_path == null:
		return
	if not ResourceLoader.exists("res://scripts/core/split_screen.gd"):
		return
	var scene_path := _menu_scene_path(current_track_id)
	split_screen = load("res://scripts/core/split_screen.gd").new()
	split_screen.name = "SplitScreen"
	split_layer = CanvasLayer.new()
	split_layer.name = "SplitLayer"
	split_layer.layer = 0
	add_child(split_layer)
	split_layer.add_child(split_screen)
	(split_screen as SplitScreen).setup(self, scene_path, car, duel_p2, cam, track_path)
	if hud != null:
		hud.visible = false


func _setup_player_effects() -> void:
	if car == null:
		return
	if wheel_smoke != null and is_instance_valid(wheel_smoke):
		wheel_smoke.queue_free()
	wheel_smoke = CPUParticles3D.new()
	wheel_smoke.name = "WheelSmoke"
	wheel_smoke.amount = 22
	wheel_smoke.lifetime = 0.8
	wheel_smoke.local_coords = true
	wheel_smoke.emitting = false
	wheel_smoke.direction = Vector3(0.0, 0.6, -0.4)
	wheel_smoke.spread = 38.0
	wheel_smoke.gravity = Vector3(0.0, 1.2, 0.0)
	wheel_smoke.initial_velocity_min = 0.7
	wheel_smoke.initial_velocity_max = 2.2
	wheel_smoke.scale_amount_min = 0.6
	wheel_smoke.scale_amount_max = 1.5
	var quad := QuadMesh.new()
	quad.size = Vector2(0.75, 0.75)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.72, 0.72, 0.74, 0.26)
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.disable_receive_shadows = true
	quad.material = mat
	wheel_smoke.mesh = quad
	wheel_smoke.position = Vector3(0.0, 0.32, -1.55)
	car.add_child(wheel_smoke)


func _spawn_impact_sparks(pos: Vector3, strength: float) -> void:
	if race_root == null:
		return
	var fx := CPUParticles3D.new()
	fx.name = "ImpactSparks"
	fx.amount = int(clampf(8.0 + strength * 0.9, 8.0, 36.0))
	fx.lifetime = 0.45
	fx.one_shot = true
	fx.explosiveness = 1.0
	fx.direction = Vector3.UP
	fx.spread = 70.0
	fx.gravity = Vector3(0.0, -9.8, 0.0)
	fx.initial_velocity_min = 3.5 + strength * 0.15
	fx.initial_velocity_max = 8.0 + strength * 0.3
	fx.scale_amount_min = 0.5
	fx.scale_amount_max = 1.3
	var spark_mesh := BoxMesh.new()
	spark_mesh.size = Vector3(0.09, 0.09, 0.22)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.62, 0.18)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.55, 0.12)
	mat.emission_energy_multiplier = 2.5
	spark_mesh.material = mat
	fx.mesh = spark_mesh
	fx.position = pos
	race_root.add_child(fx)
	fx.emitting = true
	get_tree().create_timer(0.9).timeout.connect(func() -> void:
		if is_instance_valid(fx):
			fx.queue_free())


func _setup_race_intro_camera() -> void:
	if track_path == null or car == null or cam == null:
		return
	var frame := track_path.frame_at(0.0)
	if frame.is_empty():
		return
	if intro_cam != null:
		intro_cam.queue_free()
		intro_cam = null
	cam.current = false
	var line_pos: Vector3 = frame["pos"]
	var side: Vector3 = frame["side"]
	var tangent: Vector3 = frame["tangent"]
	# 机位从起点线右侧高一点开始，越过前方车群看向最后一位的玩家车
	intro_from_pos = line_pos + side * (track_path.half_width + 16.0) - tangent * 6.0 + Vector3(0.0, 6.2, 0.0)
	intro_from_look = car.global_position + Vector3(0.0, 1.0, 0.0)
	var fwd := car.forward()
	intro_to_pos = car.global_position - fwd * 5.2 + Vector3(0.0, 1.55, 0.0)
	intro_to_look = car.global_position + fwd * 6.0 + Vector3(0.0, 0.85, 0.0)
	intro_t = 0.0
	intro_cam = Camera3D.new()
	intro_cam.name = "RaceIntroCamera"
	intro_cam.fov = 50.0
	add_child(intro_cam)
	intro_cam.global_position = intro_from_pos
	intro_cam.look_at(intro_from_look, Vector3.UP)
	intro_cam.current = true


# ---------------------------------------------------------------------------
# 幽灵车（计时赛最佳圈回放 + 时间差）
# ---------------------------------------------------------------------------

func _setup_ghost() -> void:
	_dispose_ghost()
	_ghost_samples.clear()
	_ghost_record_acc = 0.0
	_ghost_lap_start = 0.0
	_ghost_prev_laps = 0
	_ghost_was_started = false
	_ghost_delta_index = 0
	_ghost_data = {}
	if race == null or car == null or track_path == null:
		return
	if current_mode != "ta" or race.mode != "ta":
		return
	# 刷圈模式导入「本赛道最快幽灵」：无论当前开哪台车，都由最快那圈领跑。
	_ghost_data = GhostStore.load_best(track_path.id)
	if _ghost_data.is_empty():
		_ghost_data = GhostStore.load_for(track_path.id, car.car_id)
	_ensure_ghost_visual()
	_ghost_prev_laps = race.player_laps


func _dispose_ghost() -> void:
	if ghost_root != null and is_instance_valid(ghost_root):
		ghost_root.queue_free()
	ghost_root = null


func _ensure_ghost_visual() -> void:
	if race_root == null or car == null:
		return
	var ghost_car_id := String(_ghost_data.get("car", ""))
	var spec := GameData.car(ghost_car_id)
	if spec.is_empty():
		ghost_car_id = car.car_id
		spec = car.spec
	if ghost_root != null and is_instance_valid(ghost_root) and _ghost_visual_car == ghost_car_id:
		return
	if ghost_root != null and is_instance_valid(ghost_root):
		ghost_root.queue_free()
	ghost_root = Node3D.new()
	ghost_root.name = "GhostCar"
	ghost_root.visible = false
	race_root.add_child(ghost_root)
	var result := CarVisual.build(spec, ghost_root)
	_ghost_visual_car = ghost_car_id
	var model := result["model"] as Node3D
	if model == null:
		return
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.42, 0.90, 1.0, 0.30)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.no_depth_test = false
	for node in model.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null or String(mi.name).to_lower().contains("blobshadow"):
			continue
		for s in mi.mesh.get_surface_count():
			mi.set_surface_override_material(s, mat)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _update_ghost(dt: float) -> void:
	if race == null or car == null or track_path == null:
		return
	if race.mode == "ta" and race.state == RaceManager.State.RACING:
		if race.race_started and not _ghost_was_started:
			_ghost_was_started = true
			_ghost_samples.clear()
			_ghost_lap_start = race.race_time
			_ghost_record_acc = 1.0
		if race.race_started and not race.player_finished:
			_ghost_record_acc += dt
			if _ghost_record_acc >= 0.05:
				_ghost_record_acc = 0.0
				_ghost_samples.append([
					race.race_time, car.pos.x, car.pos.y, car.pos.z,
					car.heading, car.progress_dist,
				])
		if race.player_laps != _ghost_prev_laps:
			_ghost_prev_laps = race.player_laps
			_finish_ghost_lap()

	if ghost_root == null or _ghost_data.is_empty():
		_set_ghost_delta(NAN)
		return
	var show := race.state == RaceManager.State.RACING or race.state == RaceManager.State.FINISHED
	ghost_root.visible = show
	if not show:
		_set_ghost_delta(NAN)
		return
	var samples: Array = _ghost_data.get("samples", [])
	if samples.size() < 2:
		ghost_root.visible = false
		_set_ghost_delta(NAN)
		return
	var lap_len := float(_ghost_data.get("lap_time", 0.0))
	var gt := maxf(0.0, race.race_time - race.lap_start_time) + GHOST_LEAD_TIME
	if lap_len > 0.5:
		gt = fmod(gt, lap_len)
	var pose := _ghost_pose_at(samples, gt)
	ghost_root.global_position = Vector3(pose.x, pose.y + 0.02, pose.z)
	ghost_root.rotation = Vector3(0.0, pose.w, 0.0)
	_set_ghost_delta(_ghost_delta_for(samples, lap_len))


func _finish_ghost_lap() -> void:
	var lap_time := race.last_lap_time
	var lap_samples: Array = []
	for s in _ghost_samples:
		if typeof(s) != TYPE_ARRAY or s.size() < 6:
			continue
		if float(s[0]) >= _ghost_lap_start - 0.0001:
			lap_samples.append([
				float(s[0]) - _ghost_lap_start, float(s[1]), float(s[2]),
				float(s[3]), float(s[4]), float(s[5]),
			])
	_ghost_samples.clear()
	_ghost_lap_start = race.race_time
	_ghost_record_acc = 0.0
	if lap_time <= 3.0 or lap_samples.size() < 16:
		return
	# 个人最佳（按车）与赛道最佳（不分车）各存一份；
	# 刷圈进场时导入赛道最佳，换任何车都能被最快那圈领跑。
	var personal := GhostStore.load_for(track_path.id, car.car_id)
	var personal_best := float(personal.get("lap_time", 0.0))
	if personal_best <= 0.0 or lap_time < personal_best - 0.001:
		GhostStore.save_for(track_path.id, car.car_id, lap_time, lap_samples)
	GhostStore.save_best_if_faster(track_path.id, car.car_id, lap_time, lap_samples)
	_ghost_data = GhostStore.load_best(track_path.id)
	if _ghost_data.is_empty():
		_ghost_data = GhostStore.load_for(track_path.id, car.car_id)
	_ghost_delta_index = 0
	_ensure_ghost_visual()


func _ghost_pose_at(samples: Array, t: float) -> Vector4:
	var n := samples.size()
	var lo := 0
	var hi := n - 1
	while lo < hi:
		var mid := (lo + hi + 1) / 2
		if float(samples[mid][0]) <= t:
			lo = mid
		else:
			hi = mid - 1
	var a: Array = samples[lo]
	if lo >= n - 1:
		return Vector4(float(a[1]), float(a[2]), float(a[3]), float(a[4]))
	var b: Array = samples[lo + 1]
	var ta := float(a[0])
	var tb := float(b[0])
	var f := 0.0 if tb <= ta else clampf((t - ta) / (tb - ta), 0.0, 1.0)
	var h0 := float(a[4])
	var dh := wrapf(float(b[4]) - h0, -PI, PI)
	return Vector4(
		lerpf(float(a[1]), float(b[1]), f),
		lerpf(float(a[2]), float(b[2]), f),
		lerpf(float(a[3]), float(b[3]), f),
		h0 + dh * f)


## 用「同一赛道进度」对齐玩家与幽灵的用时：正数 = 落后。
func _ghost_delta_for(samples: Array, lap_len: float) -> float:
	var length := maxf(track_path.total_length, 1.0)
	var p := fposmod(car.progress_dist, length)
	var n := samples.size()
	var best_i := 0
	var best_d := INF
	var step := maxi(1, int(n / 240.0))
	for i in range(0, n, step):
		var gp := fposmod(float(samples[i][5]), length)
		var d := absf(fposmod(gp - p + length * 0.5, length) - length * 0.5)
		if d < best_d:
			best_d = d
			best_i = i
	_ghost_delta_index = best_i
	if best_d > 30.0:
		return NAN
	var elapsed := maxf(0.0, race.race_time - race.lap_start_time)
	var ghost_t := float(samples[best_i][0])
	if lap_len > 0.5:
		ghost_t = fmod(ghost_t, lap_len)
	return elapsed - ghost_t


func _set_ghost_delta(value: float) -> void:
	if hud != null and hud.has_method("set_ghost_delta"):
		hud.set_ghost_delta(value)


func _clear_race() -> void:
	ghost_root = null
	_ghost_data = {}
	_ghost_samples.clear()
	_ghost_visual_car = ""
	_line_samples.clear()
	_line_acc = 0.0
	_run_recorded = false
	open_world = null
	open_world_active = false
	_city_world = null
	_open_world_sky_mat = null
	_open_world_zone_theme = ""
	if streamer != null:
		streamer.clear()
	if audio != null:
		audio.stop_engine()
	if garage_screen != null:
		garage_screen.queue_free()
		garage_screen = null
	if garage_world != null:
		garage_world.queue_free()
		garage_world = null
	if weather != null:
		weather.queue_free()
		weather = null
	VenueKit.clear_cache()
	if game_feel != null:
		if game_feel.has_method("clear"):
			game_feel.clear()
		game_feel.queue_free()
		game_feel = null
	if race_root != null:
		# 立刻从场景树摘掉再 queue_free。
		# queue_free 要到帧末才真正删除，这一帧里 race_root 还会照常渲染：
		# 从开放世界返回菜单时，同一帧已经建好了菜单沙盘，
		# 于是画面上会同时出现「近处的沙盘标牌」和「2450m 外的真实雪山/熔岩」，
		# 看起来像两个世界叠在一起。摘出场景树可让这一帧干净。
		if race_root.get_parent() != null:
			race_root.get_parent().remove_child(race_root)
		race_root.queue_free()
		race_root = null
	if intro_cam != null:
		intro_cam.queue_free()
		intro_cam = null
	if cam != null:
		cam.queue_free()
		cam = null
	if hud != null:
		hud.queue_free()
		hud = null
	if menu != null:
		menu.queue_free()
		menu = null
	if duel_p2 != null:
		duel_p2.queue_free()
		duel_p2 = null
	if car != null:
		car.queue_free()
		car = null
	for ai in ais:
		if is_instance_valid(ai):
			ai.queue_free()
	ais.clear()
	if split_screen != null:
		if is_instance_valid(split_screen):
			split_screen.queue_free()
		split_screen = null
	if split_layer != null:
		if is_instance_valid(split_layer):
			split_layer.queue_free()
		split_layer = null
	race = null
	track_path = null
	_results_shown = false
	duel_p2 = null
	duel_p2_laps = 0
	duel_winner = ""
	duel_p2_finish_time = -1.0
	duel_p2_best_lap = -1.0


func _spawn_player() -> void:
	var spec := Garage.effective_spec(current_car_id)
	if spec.is_empty():
		spec = GameData.car(current_car_id)
	if spec.is_empty():
		spec = GameData.car(DEFAULT_CAR)
	car = Car.new()
	car.name = "PlayerCar"
	add_child(car)
	car.setup(spec, track_path, -33.0, -2.6, Color.TRANSPARENT, Garage.config(current_car_id))


func _spawn_duel_second() -> void:
	duel_p2 = null
	if current_mode != "duel":
		return
	var spec := Garage.effective_spec(current_car_id)
	if spec.is_empty():
		spec = GameData.car(current_car_id)
	if spec.is_empty():
		return
	duel_p2 = Car.new()
	duel_p2.name = "Player2Car"
	add_child(duel_p2)
	duel_p2.setup(spec, track_path, -33.0, 2.6, Color(0.95, 0.24, 0.18), Garage.config(current_car_id))
	if _city_world != null:
		duel_p2.city = _city_world
	duel_p2_laps = 0
	duel_p2_prev_progress = fposmod(duel_p2.progress_dist, maxf(track_path.total_length, 1.0))
	duel_p2_lap_start = 0.0
	duel_p2_best_lap = -1.0
	duel_p2_finish_time = -1.0
	duel_winner = ""


func _spawn_ai() -> void:
	ais.clear()
	if current_mode != "gp":
		return
	var defs: Array = GameData.ai.get("defs", [])
	var offsets: Array = GameData.ai.get("rival_offsets", [1, 3, 5])
	if defs.is_empty() or GameData.cars_specs.is_empty():
		return
	var player_index := _car_index(current_car_id)
	var routes := _pick_ai_routes(defs.size())
	for i in defs.size():
		var ai_def: Dictionary = defs[i]
		var variant_id := current_car_id
		if not offsets.is_empty():
			var idx := posmod(player_index + int(offsets[i % offsets.size()]), GameData.cars_specs.size())
			variant_id = String(GameData.cars_specs[idx].get("id", variant_id))
		var ai_spec := GameData.car(variant_id)
		if ai_spec.is_empty():
			ai_spec = GameData.car(DEFAULT_CAR)
		var ai := AICar.new()
		ai.name = "Rival%d" % (i + 1)
		add_child(ai)
		var color := Color.from_string(String(ai_def.get("color", "#cccccc")), Color(0.8, 0.8, 0.8))
		ai.setup(track_path, ai_spec, -9.0 - i * 8.0, 2.6 if i % 2 == 0 else -2.6,
			float(ai_def.get("baseSpeed", 72.0)), color,
			String(ai_def.get("name", "")), int(ai_def.get("number", 0)))
		if i < routes.size():
			var entry: Dictionary = routes[i]
			ai.set_route(entry.get("line", {}), "%s %.2f" % [
				String(entry.get("car", "")), float(entry.get("lap", 0.0))])
		ais.append(ai)


## 每场随机抽一批玩家历史走线，三台 AI 各走一条；抽完再循环但顺序已洗牌，
## 不会出现「每场都一模一样」的固定路线。
func _pick_ai_routes(count: int) -> Array:
	var out: Array = []
	if count <= 0 or current_track_id.is_empty():
		return out
	var candidates := RecordsStore.line_candidates(current_track_id, 6)
	if candidates.is_empty():
		return out
	var order: Array = []
	for i in candidates.size():
		order.append(i)
	order.shuffle()
	for i in count:
		out.append(candidates[int(order[i % order.size()])])
	return out


func _car_index(car_id: String) -> int:
	for i in GameData.cars_specs.size():
		if String(GameData.cars_specs[i].get("id", "")) == car_id:
			return i
	return 0


func _next_track_id(track_id: String) -> String:
	if GameData.tracks.is_empty():
		return DEFAULT_TRACK
	for i in GameData.tracks.size():
		if String(GameData.tracks[i].get("id", "")) == track_id:
			return String(GameData.tracks[(i + 1) % GameData.tracks.size()].get("id", DEFAULT_TRACK))
	return DEFAULT_TRACK


# ---------------------------------------------------------------------------
# driving helpers
# ---------------------------------------------------------------------------

func _update_duel(dt: float) -> void:
	if duel_p2 == null or track_path == null or race == null:
		return
	if race.state == RaceManager.State.COUNTDOWN:
		return
	var length := maxf(track_path.total_length, 1.0)
	var cur := fposmod(duel_p2.progress_dist, length)
	if cur < duel_p2_prev_progress - length * 0.5:
		duel_p2_laps += 1
		var lap_t := race.race_time - duel_p2_lap_start
		if lap_t > 0.0 and (duel_p2_best_lap < 0.0 or lap_t < duel_p2_best_lap):
			duel_p2_best_lap = lap_t
		duel_p2_lap_start = race.race_time
		if duel_p2_laps >= duel_total_laps and duel_p2_finish_time < 0.0:
			duel_p2_finish_time = race.race_time
			if race.player_finish_time < 0.0:
				duel_winner = "P2"
	duel_p2_prev_progress = cur
	if race.player_finished and duel_winner == "":
		duel_winner = "P1"
	if race.player_finished and duel_p2_finish_time >= 0.0 and race.player_finish_time >= 0.0 \
			and duel_p2_finish_time < race.player_finish_time:
		duel_winner = "P2"


func _update_player_pace(dt: float) -> void:
	if race == null or car == null:
		return
	var raw := minf(absf(car.speed_forward), car.max_speed * 1.12)
	var lambda := 1.5 if raw > race.player_pace else 0.55
	race.player_pace = lerpf(race.player_pace, raw, 1.0 - exp(-lambda * dt))


func _autopilot_input() -> Dictionary:
	return _autopilot_for(car, track_path)


## 穿模审计：SceneryKit 把世界坐标烘进合并网格顶点（实例变换为单位阵），
## 因此对每个 MultiMesh 的网格顶点抽样（每网格 ≤~120 个样本/面），对整条赛道
## 样条（每隔约 8m 重采样）求最小水平距离。几何顶点压进路面
## （dist < half_width + 0.5m）判定为穿模；树冠类悬挑放宽至 +1.5m。草地/草坪/标线类豁免。
func _audit_track_clipping(path: TrackPath, root: Node3D, track_id: String) -> Dictionary:
	var road_pts: PackedVector3Array = PackedVector3Array()
	var step := maxf(path.total_length / 320.0, 8.0)
	var d := 0.0
	while d < path.total_length:
		var f := path.frame_at(d)
		if not f.is_empty():
			road_pts.append(f["pos"] as Vector3)
		d += step
	var limit := path.half_width + 0.5
	# 树冠/棕榈类悬挑放宽：顶点悬在路面上空不算压路。
	var canopy_limit := path.half_width + 1.5
	var objects := 0
	var violations := 0
	var min_dist := 9999.0
	var offender := ""
	var name_counts: Dictionary = {}
	var vert_cache: Dictionary = {}
	# 护栏区报告（只报告不判 FAIL）：路缘外 2.4m 内的低矮物体会和护栏视觉穿插
	var near_counts: Dictionary = {}
	var near_limit: float = path.half_width + 2.4
	# 故意贴边摆放的路侧道具不算
	var near_skip := ["reflector", "tyre", "tire", "cone", "bollard", "marshal",
		"wall", "barrier", "kerb", "curb", "snowbank"]
	for node in root.find_children("*", "MultiMeshInstance3D", true, false):
		var mmi := node as MultiMeshInstance3D
		var nm := String(mmi.name).to_lower()
		if nm.contains("grass") or nm.contains("lawn") or nm.contains("mark"):
			continue
		var mm := mmi.multimesh
		if mm == null or mm.mesh == null:
			continue
		var verts: PackedVector3Array = _mesh_sample_verts(mm.mesh, vert_cache)
		if verts.is_empty():
			continue
		objects += 1
		var obj_limit := canopy_limit \
			if (nm.contains("pine") or nm.contains("palm") or nm.contains("canopy")) \
			else limit
		var nm_report := true
		for skip in near_skip:
			if nm.contains(skip):
				nm_report = false
				break
		for i in mm.instance_count:
			var inst_x: Transform3D = mmi.global_transform * mm.get_instance_transform(i)
			for v in verts:
				var wp: Vector3 = inst_x * v
				var dr := _flat_dist_and_road_y(wp, road_pts)
				var dist := dr.x
				min_dist = minf(min_dist, dist)
				# 只统计「地面走廊侵入」：顶点低于路面 +1.0m 才算压路。
				# 高空跨越（天桥/高架）、楼体高空悬挑、树冠均不算。
				if dist < obj_limit and wp.y < dr.y + 1.0:
					violations += 1
					var key := "%s/%s" % [mmi.get_parent().name, mmi.name]
					name_counts[key] = int(name_counts.get(key, 0)) + 1
					if offender.is_empty():
						offender = "%s@%s" % [mmi.name, str(wp)]
					break
				if nm_report and dist < near_limit and wp.y < dr.y + 2.0:
					var nkey := "%s/%s" % [mmi.get_parent().name, mmi.name]
					near_counts[nkey] = int(near_counts.get(nkey, 0)) + 1
					break
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		var nm := String(mi.name).to_lower()
		if nm.contains("grass") or nm.contains("lawn") or nm.contains("mark") \
				or nm.contains("skirt") or nm.contains("ground") or nm.contains("band"):
			continue
		if mi.mesh == null:
			continue
		var verts: PackedVector3Array = _mesh_sample_verts(mi.mesh, vert_cache)
		if verts.is_empty():
			continue
		objects += 1
		var xf := mi.global_transform
		var nm_key := String(mi.name)
		var nm_report2 := true
		for skip in near_skip:
			if nm.contains(skip):
				nm_report2 = false
				break
		for v in verts:
			var wp: Vector3 = xf * v
			var dr := _flat_dist_and_road_y(wp, road_pts)
			var dist := dr.x
			min_dist = minf(min_dist, dist)
			if dist < limit and wp.y < dr.y + 1.0:
				violations += 1
				name_counts["%s/%s" % [mi.get_parent().name, nm_key]] = \
					int(name_counts.get("%s/%s" % [mi.get_parent().name, nm_key], 0)) + 1
				if offender.is_empty():
					offender = "%s(parent=%s)@%s mesh_size=%s origin=%s origin_dist=%.2f" % [
						mi.name, mi.get_parent().name, str(wp), str(mi.mesh.get_aabb().size),
						str(xf.origin), VenueKit.distance_to_track(path, xf.origin)]
				break
			if nm_report2 and dist < near_limit and wp.y < dr.y + 2.0:
				var nkey2 := "%s/%s" % [mi.get_parent().name, nm_key]
				near_counts[nkey2] = int(near_counts.get(nkey2, 0)) + 1
				break
	if violations > 0:
		print("[CLIP]   %s first offender: %s" % [track_id, offender])
		var pairs := []
		for k in name_counts:
			pairs.append([k, name_counts[k]])
		pairs.sort_custom(func(a, b): return int(a[1]) > int(b[1]))
		var top := []
		for p in pairs.slice(0, 4):
			top.append("%s x%d" % [p[0], p[1]])
		print("[CLIP]   %s top offenders: %s" % [track_id, ", ".join(top)])
	if near_counts.size() > 0:
		var npairs := []
		for k in near_counts:
			npairs.append([k, near_counts[k]])
		npairs.sort_custom(func(a, b): return int(a[1]) > int(b[1]))
		var ntop := []
		for p in npairs.slice(0, 8):
			ntop.append("%s x%d" % [p[0], p[1]])
		print("[CLIP]   %s near-barrier (<=3m): %s" % [track_id, ", ".join(ntop)])
	return {"objects": objects, "min_dist": min_dist, "violations": violations}


## 每个网格资源缓存抽样顶点（顶点烘焙了世界坐标时也能代表几何位置）。
func _mesh_sample_verts(mesh: Mesh, cache: Dictionary) -> PackedVector3Array:
	var key := "%d" % mesh.get_instance_id()
	if cache.has(key):
		return cache[key]
	var out := PackedVector3Array()
	for s in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(s)
		if arrays.size() <= Mesh.ARRAY_VERTEX or arrays[Mesh.ARRAY_VERTEX] == null:
			continue
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var stride := maxi(1, verts.size() / 120)
		var k := 0
		while k < verts.size():
			out.append(verts[k])
			k += stride
	cache[key] = out
	return out


static func _flat_distance_to_polyline(p: Vector3, pts: PackedVector3Array) -> float:
	var best := 9999.0
	for q in pts:
		var dx := p.x - q.x
		var dz := p.z - q.z
		var d2 := dx * dx + dz * dz
		if d2 < best:
			best = d2
	return sqrt(best)


## 水平距离 + 最近路点高度：用于区分「地面压路」与「高空跨越/悬挑」。
static func _flat_dist_and_road_y(p: Vector3, pts: PackedVector3Array) -> Vector2:
	var best := 1.0e12
	var road_y := 0.0
	for q in pts:
		var dx := p.x - q.x
		var dz := p.z - q.z
		var d2 := dx * dx + dz * dz
		if d2 < best:
			best = d2
			road_y = q.y
	return Vector2(sqrt(best), road_y)


func _autopilot_for(target_car: Car, path: TrackPath) -> Dictionary:
	if target_car == null or path == null:
		return {"steer": 0.0, "throttle": 0.0, "handbrake": false, "nitro": false, "reverse_pressed": false}
	var speed_mps := maxf(target_car.speed_kph / 3.6, 1.0)
	var look := clampf(speed_mps * 0.8, 10.0, 45.0)
	var f := path.frame_at(target_car.progress_dist + look)
	if f.is_empty():
		return {"steer": 0.0, "throttle": 0.5, "handbrake": false, "nitro": false, "reverse_pressed": false}
	var target: Vector3 = f["pos"]
	var to_target := target - target_car.pos
	var desired := atan2(to_target.x, to_target.z)
	var diff := wrapf(desired - target_car.heading, -PI, PI)
	var steer := clampf(-diff * 3.0, -1.0, 1.0)
	# 刹车视野随车速延长：固定 90m 在 200km/h 只剩 1.5s，自动驾驶会带着墙进弯
	var horizon := clampf(target_car.speed_kph * 0.45, 70.0, 170.0)
	var curvature := path.max_curvature_ahead(target_car.progress_dist, horizon, 6.0)
	var throttle := clampf(1.0 - curvature * 70.0, 0.3, 1.0)
	if curvature > 0.0001:
		var corner_kph := sqrt(8.5 / curvature) * 3.6
		if target_car.speed_kph > corner_kph:
			throttle = clampf((corner_kph - target_car.speed_kph) / 22.0, -1.0, 0.6)
	return {"steer": steer, "throttle": throttle, "handbrake": false, "nitro": false, "reverse_pressed": false}


# ---------------------------------------------------------------------------
# world dressing
# ---------------------------------------------------------------------------

func _setup_environment(parent: Node3D, def: Dictionary) -> void:
	var theme: Dictionary = def.get("theme", {})
	var night := SceneryKit.is_night_theme(theme)
	var weather_kind := String(theme.get("weather", "none"))
	var cloud_coverage := 0.45
	var cloud_speed := 0.008
	match weather_kind:
		"rain":
			cloud_coverage = 0.9
			cloud_speed = 0.02
		"snow":
			cloud_coverage = 0.72
			cloud_speed = 0.006
		"dust":
			cloud_coverage = 0.5
			cloud_speed = 0.012
		_:
			cloud_coverage = 0.45 if bool(theme.get("clouds", true)) else 0.18
	var sky_material := ShaderMaterial.new()
	sky_material.shader = load("res://shaders/sky_clouds.gdshader")
	sky_material.set_shader_parameter("top_color", _c(theme.get("skyTop", "#1c62b4"), Color(0.11, 0.38, 0.71)))
	sky_material.set_shader_parameter("horizon_color", _c(theme.get("skyHorizon", "#d9eef2"), Color(0.85, 0.93, 0.95)))
	sky_material.set_shader_parameter("ground_color", _c(theme.get("skyBottom", "#8fc8d2"), Color(0.56, 0.78, 0.82)))
	sky_material.set_shader_parameter("sun_color", _c(theme.get("sunColor", "#fff2da"), Color(1.0, 0.95, 0.86)))
	var cloud_tint := _c(theme.get("cloudColor", "#ffffff"), Color(1.0, 1.0, 1.0))
	sky_material.set_shader_parameter("cloud_light", cloud_tint)
	sky_material.set_shader_parameter("cloud_shadow", _c(theme.get("fogColor", "#c8e4ea"), Color(0.7, 0.78, 0.85)).darkened(0.35))
	sky_material.set_shader_parameter("cloud_coverage", clampf(cloud_coverage + 0.12, 0.18, 0.95))
	sky_material.set_shader_parameter("cloud_opacity", 0.95 if weather_kind != "none" else 0.82)
	sky_material.set_shader_parameter("cloud_scale", 1.9 if not night else 1.15)
	sky_material.set_shader_parameter("cloud_speed", cloud_speed)
	sky_material.set_shader_parameter("night", 1.0 if night else 0.0)
	sky_material.set_shader_parameter("stars_amount", clampf(float(theme.get("stars", 0.0)), 0.0, 1.0))
	sky_material.set_shader_parameter("sun_size", 0.04 if not night else 0.022)
	sky_material.set_shader_parameter("sun_glow", 0.75 if not night else 0.3)
	sky_material.set_shader_parameter("haze_strength", 0.24)
	sky_material.set_shader_parameter("horizon_softness", 0.38)

	var hdri_used := false
	var sky := Sky.new()
	# 云层动画极慢，radiance 每帧全量重算 6 面 cubemap 纯属白烧 GPU；
	# 增量模式分几帧收敛，天空本体和反射观感不变（环境光本来就不采样天空）。
	sky.process_mode = Sky.PROCESS_MODE_INCREMENTAL
	var hdri_path := ""
	match String(def.get("id", "")):
		"coast":
			hdri_path = "res://assets/thirdparty/polyhaven/hdri/kloofendal_48d_partly_cloudy_puresky_2k.hdr"
		"alpine":
			hdri_path = "res://assets/thirdparty/polyhaven/hdri/kloofendal_43d_clear_puresky_2k.hdr"
		"glacier":
			hdri_path = "res://assets/thirdparty/polyhaven/hdri/kloofendal_38d_partly_cloudy_puresky_2k.hdr"
	if not hdri_path.is_empty():
		if ResourceLoader.exists(hdri_path):
			var pano_mat := ShaderMaterial.new()
			pano_mat.shader = load("res://shaders/hdri_clouds.gdshader")
			pano_mat.set_shader_parameter("panorama", load(hdri_path))
			pano_mat.set_shader_parameter("cloud_light", Color(0.93, 0.94, 0.96))
			pano_mat.set_shader_parameter("cloud_shadow", Color(0.58, 0.63, 0.7))
			pano_mat.set_shader_parameter("cloud_coverage", clampf(cloud_coverage + 0.12, 0.18, 0.7))
			pano_mat.set_shader_parameter("cloud_opacity", 0.44)
			pano_mat.set_shader_parameter("cloud_scale", 0.5)
			pano_mat.set_shader_parameter("cloud_speed", 0.014)
			pano_mat.set_shader_parameter("horizon_softness", 0.12)
			pano_mat.set_shader_parameter("sky_brightness", 0.72)
			# HDRI 天空也要吃主题的夜色/星空/雾色，否则极夜雪原会挂一张白昼全景
			pano_mat.set_shader_parameter("night", 1.0 if night else 0.0)
			pano_mat.set_shader_parameter("stars_amount",
				clampf(float(theme.get("stars", 0.0)), 0.0, 1.0))
			pano_mat.set_shader_parameter("haze_color",
				_c(theme.get("fogColor", "#c8e4ea"), Color(0.8, 0.86, 0.9)).darkened(0.34)
					.lerp(Color(0.46, 0.53, 0.65), 0.62))
			pano_mat.set_shader_parameter("haze_strength", 0.35 if not night else 0.22)
			pano_mat.set_shader_parameter("sun_color",
				_c(theme.get("sunColor", "#fff2da"), Color(1.0, 0.95, 0.86)))
			sky.sky_material = pano_mat
			sky.radiance_size = Sky.RADIANCE_SIZE_512
			hdri_used = true
		
	if not hdri_used:
		sky.sky_material = sky_material

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = clampf(float(theme.get("exposure", 1.05)) * 0.63, 0.54, 1.02)
	env.tonemap_white = 3.4
	# 环境光统一用「主题天空色」做固定补光，而不是采样天空。
	# 原因：海岸/峡谷/熔岩用的是 HDRI 全景，转过身后半天空本身很暗，
	# 采样天空会让同一条赛道在某个朝向上整段掉进黑夜，亮度完全不可控。
	var amb_color := _c(theme.get("hemiSky", "#b4d8f8"), Color(0.70, 0.82, 0.95))
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = amb_color if not night else Color(0.34, 0.42, 0.66)
	# 夜间环境光提到 0.85：0.72 时暗面楼体/岩石会黑成一团剪影
	env.ambient_light_energy = 0.85 if night else (0.66 if hdri_used else 0.54)
	# 主题可单独抬环境光：山谷在逆光山影里暗面会糊成剪影，纹理全丢。
	env.ambient_light_energy = clampf(
		float(theme.get("ambientEnergy", env.ambient_light_energy)), 0.2, 1.2)
	env.adjustment_enabled = true
	env.adjustment_contrast = 1.24
	env.adjustment_saturation = 1.18 if not night else 1.08
	env.adjustment_brightness = 1.00
	env.ssao_radius = 2.4
	env.ssao_intensity = 4.0
	env.ssao_power = 1.7
	env.ssao_sharpness = 0.98
	env.ssao_light_affect = 0.06
	env.ssr_enabled = true
	env.ssr_max_steps = 56
	env.ssr_fade_in = 0.12
	env.ssr_fade_out = 1.5
	env.ssr_depth_tolerance = 0.4
	env.ssao_intensity = 2.6
	env.ssil_enabled = true
	env.ssil_intensity = 1.15
	env.ssil_radius = 6.0
	env.ssil_sharpness = 0.98
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.glow_enabled = true
	env.glow_intensity = clampf(float(theme.get("glowOpacity", 0.4)) * 1.1, 0.25, 1.4)
	env.glow_bloom = 0.08
	env.ssao_enabled = true
	env.ssao_radius = 1.6
	env.fog_enabled = true
	# 远景清晰度基线：雾色不再压暗 55%，雾密度降约 30%；far_clarity 可在设置里再调
	_base_fog_color = _c(theme.get("fogColor", "#c8e4ea"), Color(0.78, 0.89, 0.92)).darkened(0.34)
	# HDRI 照片的地平线是蓝灰雾；环境雾对齐它，远海/远岛才不会先雾成偏绿的灰，
	# 再在地平线处硬切到偏蓝的天空。
	if hdri_used:
		_base_fog_color = _base_fog_color.lerp(Color(0.46, 0.53, 0.65), 0.62)
	env.fog_light_color = _base_fog_color
	var fog_far := maxf(float(theme.get("fogFar", 3600.0)), 800.0)
	_base_fog_density = clampf(0.72 / fog_far, 0.00010, 0.00065)
	env.fog_density = _base_fog_density
	env.fog_aerial_perspective = 0.20
	# subtle atmosphere for sun shafts on clear days too
	env.volumetric_fog_enabled = true
	_base_vol_density = 0.0016 if weather_kind == "none" else 0.008
	env.volumetric_fog_density = _base_vol_density
	env.volumetric_fog_albedo = _c(theme.get("fogColor", "#c8e4ea"), Color(0.8, 0.86, 0.95)).darkened(0.25)
	env.volumetric_fog_emission = _c(theme.get("sunColor", "#ffe5bb"), Color(1.0, 0.9, 0.75)).darkened(0.75) * 0.35
	env.volumetric_fog_length = 720.0
	env.volumetric_fog_ambient_inject = 0.16
	env.volumetric_fog_sky_affect = 0.10
	env.volumetric_fog_gi_inject = 0.4
	env.volumetric_fog_anisotropy = 0.55
	var misty := weather_kind != "none" or night
	if misty:
		env.volumetric_fog_enabled = true
		# 沙尘只是薄霾：0.008 会把峡谷/熔岩压成剪影，dust 用轻一档
		_base_vol_density = 0.008 if (weather_kind == "rain" or weather_kind == "snow") else 0.0035
		env.volumetric_fog_density = _base_vol_density
		env.volumetric_fog_albedo = _c(theme.get("fogColor", "#c8e4ea"), Color(0.7, 0.78, 0.85)).darkened(0.25)
		env.volumetric_fog_emission = _c(theme.get("accent", "#ffffff"), Color(0.3, 0.6, 0.8)).darkened(0.7) * 0.25
		env.volumetric_fog_length = 260.0
		env.volumetric_fog_ambient_inject = 0.35
		env.volumetric_fog_sky_affect = 0.35
	env.fog_sky_affect = 0.16

	var world_env := WorldEnvironment.new()
	world_env.name = "WorldEnvironment"
	world_env.environment = env
	parent.add_child(world_env)
	_env = env

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	var sun_dir: Array = theme.get("sunDir", [0.42, 0.52, 0.2])
	var dir := Vector3(float(sun_dir[0]), float(sun_dir[1]), float(sun_dir[2])).normalized()
	if not night:
		dir = Vector3(dir.x, clampf(dir.y * 0.62, 0.14, 0.45), dir.z).normalized()
	sun.transform = Transform3D(Basis.looking_at(-dir, Vector3.UP), Vector3.ZERO)
	if night:
		sun.light_energy = clampf(float(theme.get("sunPower", 5.0)) * 0.30, 0.9, 2.0)
		sun.light_color = _c(theme.get("sunColor", "#cdd8ff"), Color(0.8, 0.85, 1.0))
	else:
		sun.light_energy = clampf(float(theme.get("sunPower", 5.0)) * 0.46, 1.9, 3.2)
		sun.light_color = _c(theme.get("sunColor", "#fff2da"), Color(1.0, 0.95, 0.86)).lerp(
			Color(1.0, 0.82, 0.58), 0.45)
	sun.shadow_enabled = true
	sun.shadow_bias = 0.016
	sun.shadow_normal_bias = 1.1
	sun.shadow_blur = 1.35
	sun.shadow_opacity = 1.0
	sun.directional_shadow_max_distance = sun.directional_shadow_max_distance
	sun.directional_shadow_blend_splits = false
	# 4 分裂会把整个可见场景画进 4 张阴影图：实测 M1 Pro 上阴影 pass
	# 占了一半以上的 draw call。赛车游戏远景阴影几乎看不到，改成 2 分裂 + 收短距离。
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	parent.add_child(sun)
	_sun = sun
	_volumetric_allowed = env.volumetric_fog_enabled
	_apply_quality()


func _open_pause() -> void:
	if state != AppState.RACE or pause_screen != null:
		return
	if race != null and race.state == RaceManager.State.RESULTS:
		return
	pause_screen = PauseScreen.new()
	pause_screen.name = "PauseScreen"
	pause_screen.setup(
		String(track_def.get("name", "")) if not track_def.is_empty() else "",
		String(GameData.car(current_car_id).get("name", current_car_id)))
	add_child(pause_screen)
	pause_screen.resume_requested.connect(_close_pause)
	pause_screen.restart_requested.connect(_on_pause_restart)
	pause_screen.settings_requested.connect(_on_pause_settings)
	pause_screen.menu_requested.connect(_on_pause_menu)
	get_tree().paused = true


func _close_pause() -> void:
	get_tree().paused = false
	if pause_screen != null:
		pause_screen.queue_free()
		pause_screen = null


func _on_pause_restart() -> void:
	get_tree().paused = false
	if pause_screen != null:
		pause_screen.queue_free()
		pause_screen = null
	if open_world_active:
		# 开放世界不重建 9km 地图，直接把车送回出生点
		if open_world != null and car != null:
			var sp: Dictionary = open_world.spawn()
			car.pos = sp["pos"]
			car.heading = float(sp.get("heading", 0.0))
			car.vel = Vector3.ZERO
			car.speed_kph = 0.0
		return
	_start_race(current_track_id, current_car_id, current_mode)


func _on_pause_settings() -> void:
	_close_pause()
	_open_settings()


func _on_pause_menu() -> void:
	get_tree().paused = false
	if pause_screen != null:
		pause_screen.queue_free()
		pause_screen = null
	_show_menu()


func _open_achievements() -> void:
	if ResourceLoader.exists("res://scripts/ui/achievements_screen.gd"):
		var screen: Node = load("res://scripts/ui/achievements_screen.gd").new()
		screen.name = "Achievements"
		add_child(screen)
		if screen.has_signal("closed"):
			screen.closed.connect(func() -> void:
				if is_instance_valid(screen):
					screen.queue_free())


func _open_daily() -> void:
	if ResourceLoader.exists("res://scripts/ui/daily_screen.gd"):
		var screen: Node = load("res://scripts/ui/daily_screen.gd").new()
		screen.name = "Daily"
		add_child(screen)
		if screen.has_signal("closed"):
			screen.closed.connect(func() -> void:
				if is_instance_valid(screen):
					screen.queue_free()
				if is_instance_valid(menu):
					menu.refresh())


func _open_circuit_archive() -> void:
	if menu == null or not is_instance_valid(menu):
		return
	if not ResourceLoader.exists("res://scripts/ui/circuit_archive.gd"):
		return
	var screen = load("res://scripts/ui/circuit_archive.gd").new()
	screen.name = "CircuitArchive"
	screen.track_lengths = menu.track_lengths.duplicate()
	screen.current_track_id = menu.selected_track_id()
	add_child(screen)
	screen.track_selected.connect(func(track_id: String) -> void:
		_select_menu_track(track_id)
		if is_instance_valid(screen):
			screen.queue_free())
	screen.closed.connect(func() -> void:
		if is_instance_valid(screen):
			screen.queue_free())


func _select_menu_track(track_id: String) -> void:
	if menu == null or not is_instance_valid(menu):
		return
	for i in GameData.tracks.size():
		if String(GameData.tracks[i].get("id", "")) == track_id:
			menu.track_index = i
			menu.refresh()
			break


func _open_settings() -> void:
	if settings_screen == null:
		return
	settings_screen.open()
	if not shot_mode:
		get_tree().paused = true


func _on_settings_closed() -> void:
	get_tree().paused = false


func apply_quality_now() -> void:
	_apply_quality()


func _apply_quality() -> void:
	var q := Settings.preset()
	var preset_id := String(q["id"])
	CityFacadesScript.set_detail(Settings.index)
	var vp := get_viewport()
	var temporal := false
	# 扩展画质细项：分辨率 / 帧率上限 / 垂直同步 / 渲染缩放（字段由 Settings 提供）
	if not shot_mode and not _perf_mode:
		var fps_setting = Settings.get("fps_limit")
		if fps_setting != null:
			Engine.max_fps = int(fps_setting)
		var vsync_setting = Settings.get("vsync_enabled")
		if vsync_setting != null:
			DisplayServer.window_set_vsync_mode(
				DisplayServer.VSYNC_ENABLED if bool(vsync_setting) else DisplayServer.VSYNC_DISABLED)
		# 只有窗口化模式才允许改窗口尺寸；全屏/无边框下强制 set_size 会让画面缩到左上角
		var w_setting = Settings.get("window_width")
		var h_setting = Settings.get("window_height")
		var mode_setting = Settings.get("window_mode")
		var is_windowed := mode_setting == null or String(mode_setting) == "windowed"
		if is_windowed and w_setting != null and h_setting != null:
			var target_size := Vector2i(int(w_setting), int(h_setting))
			if target_size.x >= 1024 and target_size.y >= 640 and DisplayServer.window_get_size() != target_size:
				DisplayServer.window_set_size(target_size)
	if vp != null:
		var scale := float(q["scale"])
		var custom_scale = Settings.get("render_scale")
		if custom_scale != null:
			scale = clampf(float(custom_scale), 0.5, 1.0)
		var mode: int = Viewport.SCALING_3D_MODE_BILINEAR
		var want := Settings.upscale
		# 平台自适应：macOS 走 MetalFX（GPU 原生时间升频），桌面走 FSR2；
		# 二者都会替代内置 TAA，避免两套时间累积叠加成糊/闪烁。
		if want != "off":
			if PlatformProfile.supports_metalfx():
				if scale < 0.99 and want != "on":
					mode = Viewport.SCALING_3D_MODE_METALFX_SPATIAL
				else:
					mode = Viewport.SCALING_3D_MODE_METALFX_TEMPORAL
					temporal = true
			elif PlatformProfile.supports_fsr2():
				mode = Viewport.SCALING_3D_MODE_FSR2
				temporal = true
		if temporal:
			scale = 1.0  # 原生分辨率做时间抗锯齿，画面最稳最清楚
			vp.msaa_3d = Viewport.MSAA_DISABLED  # MetalFX/FSR2 自带 AA，避免引擎内部再关一次并告警
		else:
			vp.msaa_3d = Settings.msaa_mode()
		vp.scaling_3d_mode = mode
		vp.scaling_3d_scale = scale
		vp.use_taa = bool(q.get("taa", false)) and not temporal
		vp.use_debanding = true
	# 阴影预算按档位走：低档小图集 + 硬阴影省 GPU，超高档大图 + 高质量软阴影。
	# 以前全档位共用 project.godot 的 8192 图集，低档白白画一张大阴影图。
	RenderingServer.directional_shadow_atlas_set_size(Settings.shadow_atlas(), Settings.shadow_filter())
	if _env != null:
		_env.ssr_enabled = bool(q["ssr"])
		_env.ssr_max_steps = int(q["ssr_steps"])
		_env.ssao_enabled = bool(q["ssao"])
		_env.ssil_enabled = bool(q["ssil"])
		_env.volumetric_fog_enabled = _volumetric_allowed and bool(q["vol"])
		if _env.sky != null:
			_env.sky.radiance_size = Settings.sky_radiance() as Sky.RadianceSize
			var sky_mat := _env.sky.sky_material
			if sky_mat is ShaderMaterial:
				(sky_mat as ShaderMaterial).set_shader_parameter(
					"cloud_octaves", Settings.cloud_octaves())
				(sky_mat as ShaderMaterial).set_shader_parameter(
					"cloud_detail", Settings.cloud_detail())
		_apply_far_clarity()
	if _sun != null:
		_sun.directional_shadow_max_distance = float(q["shadow_dist"])
		# 超高：两级阴影级联之间混合过渡，远处阴影边界不再有硬切换线
		_sun.directional_shadow_blend_splits = preset_id == "ultra"
	if streamer != null:
		# 开放世界的剔除距离在 _start_open_world 里单独收紧过（大地图分块大，
		# 默认远景会让剔除失效），换画质档时不能被通用远景覆盖回去。
		if open_world_active:
			streamer.max_distance = 1600.0
			streamer.tight_sector = true
		else:
			streamer.max_distance = Settings.far_distance()
		streamer.prefetch_strength = 1.35 if preset_id == "ultra" else (1.15 if preset_id == "high" else 0.9)
	_apply_lod_bias_all()
	_sync_post_params()
	print("[QUALITY] %s  缩放 %.2f  %s  锐化 %.2f  远景 %.2f" % [
		preset_id, float(q["scale"]),
		("MetalFX/FSR2 时间升频" if temporal else ("空间升频" if Settings.upscale != "off" else "内置 TAA")),
		Settings.sharpen, Settings.far_clarity])


func _apply_far_clarity() -> void:
	if _env == null:
		return
	var clarity := clampf(Settings.far_clarity, 0.6, 1.6)
	_env.fog_density = _base_fog_density / clarity
	_env.volumetric_fog_density = _base_vol_density / clarity
	_env.fog_aerial_perspective = clampf(0.20 + (clarity - 1.0) * 0.06, 0.10, 0.28)
	_env.fog_light_color = _base_fog_color.lightened(maxf((clarity - 1.0) * 0.12, 0.0))
	_env.volumetric_fog_length = 720.0 * clarity
	_env.fog_sky_affect = clampf(0.16 + (clarity - 1.0) * 0.05, 0.08, 0.24)


func _sync_post_params() -> void:
	if motion_blur_mat == null or get_viewport() == null:
		return
	var size := Vector2(get_viewport().size)
	motion_blur_mat.set_shader_parameter("sharpen", Settings.sharpen)
	motion_blur_mat.set_shader_parameter("taps", Settings.blur_taps())
	motion_blur_mat.set_shader_parameter("texel", Vector2(
		1.0 / maxf(size.x, 1.0), 1.0 / maxf(size.y, 1.0)))
	if motion_blur_rect != null:
		motion_blur_rect.visible = Settings.sharpen > 0.001 or _last_blur_amount > 0.004


## 换画质档时把全场几何的 LOD 偏移同步到当前档位：
## 低档 <1 让车/树/建筑更早切低模省帧率，超高档 >1 把满精度模型留到更远。
## 新建场景里的物件在摆放入口（RealAssetKit / CarVisual）按当前档写入初始值。
func _apply_lod_bias_all() -> void:
	var bias := Settings.lod_bias()
	for node in get_tree().root.find_children("*", "GeometryInstance3D", true, false):
		(node as GeometryInstance3D).lod_bias = bias
	for ai in ais:
		if ai != null and is_instance_valid(ai) and ai.has_method("apply_quality_shadows"):
			ai.apply_quality_shadows()


func _sync_post_amount(amount: float) -> void:
	_last_blur_amount = amount
	if motion_blur_mat == null:
		return
	motion_blur_mat.set_shader_parameter("amount", amount)
	if motion_blur_rect != null:
		motion_blur_rect.visible = amount > 0.004 or Settings.sharpen > 0.001


func _c(hex: String, fallback: Color) -> Color:
	if hex.is_empty():
		return fallback
	return Color.from_string(hex, fallback)


# ---------------------------------------------------------------------------
# args
# ---------------------------------------------------------------------------

func _parse_args() -> void:
	var args := OS.get_cmdline_user_args()
	verify_mode = "--verify" in args
	for arg in args:
		if arg.begins_with("--shot="):
			shot_mode = true
			shot_path = arg.substr(7)
		elif arg.begins_with("--shot-scene="):
			shot_scene = arg.substr(13)
		elif arg.begins_with("--shot-dist="):
			_shot_dist = float(arg.substr(12))
		elif arg.begins_with("--shot-delay="):
			_shot_delay = maxf(0.0, float(arg.substr(13)))
		elif arg.begins_with("--movie-frames="):
			_movie_frames = int(arg.substr(15))
		elif arg.begins_with("--movie-dir="):
			_movie_dir = arg.substr(12)
		elif arg.begins_with("--movie-skip="):
			_movie_skip = maxi(0, int(arg.substr(13)))
		elif arg.begins_with("--trailer-shot="):
			_trailer_shot = arg.substr(15)
		elif arg.begins_with("--trailer-hud="):
			_trailer_hud = int(arg.substr(14))
		elif arg == "--trailer-nogrid":
			_trailer_nogrid = true
		elif arg.begins_with("--track="):
			_arg_track = arg.substr(8)
		elif arg.begins_with("--car="):
			_arg_car = arg.substr(6)
		elif arg.begins_with("--mode="):
			_arg_mode = arg.substr(7)
		elif arg.begins_with("--quality="):
			_arg_quality = arg.substr(10)
		elif arg.begins_with("--camera="):
			_arg_camera = int(arg.substr(9))
		elif arg.begins_with("--shot-speed="):
			_arg_shot_speed = float(arg.substr(13))
		elif arg == "--tune":
			_tune_demo = true
		elif arg == "--perf-test":
			_perf_mode = true
		elif arg == "--analog-test":
			_analog_test_mode = true
		elif arg == "--drift-test":
			_drift_test_mode = true
		elif arg == "--openworld-test":
			_openworld_test_mode = true


func _track_or_default() -> String:
	return _arg_track if not _arg_track.is_empty() else DEFAULT_TRACK


func _car_or_default() -> String:
	return _arg_car if not _arg_car.is_empty() else DEFAULT_CAR


func _mode_or_default() -> String:
	return _arg_mode if _arg_mode in ["gp", "ta", "duel"] else "gp"


## 车辆碰撞尺寸：用 manifest 里每台车实测的 contact = [宽, 长]（米），
## 取代原来固定的 r=2.1 圆形碰撞（圆直径 4.2m 比车宽/车长都不匹配，侧向像一堵看不见的墙）。
func _car_half_extents(car_id: String) -> Vector2:
	var cars: Dictionary = GameData.car_manifest.get("cars", {})
	var entry: Dictionary = cars.get(car_id, {})
	var c: Array = entry.get("contact", [1.9, 4.4])
	var w := float(c[0]) if c.size() > 0 else 1.9
	var l := float(c[1]) if c.size() > 1 else 4.4
	return Vector2(clampf(w * 0.5, 0.80, 1.30), clampf(l * 0.5, 1.80, 2.90))


## 2D 带朝向矩形（OBB）SAT 求最小分离向量。
## 返回 {hit, normal(从 B 指向 A 的单位向量), depth, mtv(世界 xz)}。
func _obb_mtv(pos_a: Vector2, yaw_a: float, half_a: Vector2,
		pos_b: Vector2, yaw_b: float, half_b: Vector2) -> Dictionary:
	var out := {"hit": false, "normal": Vector2.ZERO, "depth": 0.0, "mtv": Vector2.ZERO}
	var ra := Vector2(cos(yaw_a), -sin(yaw_a))
	var fa := Vector2(sin(yaw_a), cos(yaw_a))
	var rb := Vector2(cos(yaw_b), -sin(yaw_b))
	var fb := Vector2(sin(yaw_b), cos(yaw_b))
	var axes: Array[Vector2] = [ra, fa, rb, fb]
	var d := pos_a - pos_b
	var best_depth := 1e30
	var best_axis := Vector2.ZERO
	for axis in axes:
		var proj_a := absf(ra.dot(axis)) * half_a.x + absf(fa.dot(axis)) * half_a.y
		var proj_b := absf(rb.dot(axis)) * half_b.x + absf(fb.dot(axis)) * half_b.y
		var dist := absf(d.dot(axis))
		var overlap := proj_a + proj_b - dist
		if overlap <= 0.0:
			return out
		if overlap < best_depth:
			best_depth = overlap
			best_axis = axis
	out["hit"] = true
	out["depth"] = best_depth
	var normal: Vector2 = best_axis if d.dot(best_axis) >= 0.0 else -best_axis
	out["normal"] = normal
	out["mtv"] = normal * best_depth
	return out


func _resolve_car_contacts() -> float:
	if car == null or track_path == null:
		return 0.0
	var player_half := _car_half_extents(current_car_id)
	var player_fwd := car.forward()
	var max_impact := 0.0
	for ai in ais:
		var ai_id := String(ai.spec.get("id", ""))
		var ai_half := _car_half_extents(ai_id) if not ai_id.is_empty() else Vector2(0.95, 2.2)
		var hit := _obb_mtv(
			Vector2(car.pos.x, car.pos.z), car.heading, player_half,
			Vector2(ai.pos.x, ai.pos.z), ai.heading, ai_half)
		if not hit["hit"]:
			continue
		var mtv: Vector2 = hit["mtv"]
		var normal: Vector2 = hit["normal"]
		var depth: float = hit["depth"]
		if depth < 0.0005:
			continue
		# ---- 接触解算：小步位置修正 + 接触分离速度，避免「闪现」和「粘上碰」----
		var n3 := Vector3(normal.x, 0.0, normal.y)
		var ai_fwd := Vector3(sin(ai.heading), 0.0, cos(ai.heading))
		var ai_vel := ai_fwd * ai.speed
		var rel := car.vel - ai_vel
		var vn := rel.dot(n3)  # <0：两车还在相互压；>0：正在分开

		# 位置修正每帧限幅，宁可多弹几帧也不瞬移（用户反馈「直接闪到前面去了」）。
		# 上限比旧版放宽：撞上后要较快脱离接触，否则两车会贴着磨蹭（「黏」）。
		var push := minf(depth * 0.75, 0.38)
		var desired_ai := -n3 * push
		var ai_got := Vector3.ZERO
		var frame := track_path.frame_at(ai.dist)
		if not frame.is_empty():
			var side: Vector3 = frame["side"]
			var tangent: Vector3 = frame["tangent"]
			var want_lat := desired_ai.x * side.x + desired_ai.z * side.z
			var want_along := desired_ai.x * tangent.x + desired_ai.z * tangent.z
			var prev_off := ai.offset
			var prev_dist := ai.dist
			var limit := maxf(float(frame.get("half_width", track_path.half_width)) - 1.4, 0.55)
			ai.offset = clampf(ai.offset + want_lat, -limit, limit)
			ai.dist = maxf(ai.dist + want_along, 0.0)
			var got_lat := ai.offset - prev_off
			var got_along := ai.dist - prev_dist
			ai_got = Vector3(side.x * got_lat + tangent.x * got_along, 0.0,
				side.z * got_lat + tangent.z * got_along)
		# AI 被护栏/边界夹住而没让出去的位移，只补一小部分给玩家（限幅，避免闪现）
		var unfulfilled := desired_ai - ai_got
		var car_push := n3 * push - unfulfilled
		var push_cap := push * 1.8
		if car_push.length() > push_cap and push_cap > 0.0001:
			car_push = car_push.normalized() * push_cap
		car.pos.x += car_push.x
		car.pos.z += car_push.z
		# 任何接触都给 AI 一个侧向弹开锁存：撞完先让开，不要下一帧又贴回玩家。
		if not frame.is_empty():
			var ai_side_v: Vector3 = frame["side"]
			ai.bump_lat = clampf(ai.bump_lat - n3.dot(ai_side_v) * minf(0.55 + depth, 1.4), -2.8, 2.8)
			ai.bump_timer = maxf(ai.bump_timer, 0.65)

		# 接触分离速度：低速轻碰也有 1.3m/s 的轻微弹开；高速对撞按 38% 反弹。
        # 单帧速度修正限幅，避免「闪一下窜出去」。
		var target_sep := maxf(1.3, -vn * 0.38)
		var vn_dv := clampf(target_sep - vn, 0.0, 3.0)
		if vn < target_sep:
			var car_share := 0.70
			var ai_share := 0.30
			car.vel += n3 * (vn_dv * car_share)
			var ai_new := ai_vel - n3 * (vn_dv * ai_share)
			ai.speed = clampf(ai_new.dot(ai_fwd), 0.0,
				maxf(ai.speed, ai_new.length()) + 5.0)
			var vf := car.vel.dot(player_fwd)
			if vf < -0.5:
				car.vel -= player_fwd * vf
		if vn < -1.2:
			max_impact = maxf(max_impact, -vn)
			last_hit_pos = ((car.pos + ai.pos) * 0.5) + Vector3(0.0, 0.55, 0.0)
			last_hit_active = true
		# ---- 真实碰撞反馈：撞一下 → 双方掉速 → AI 沿侧向弹开 0.9s ----
		var impact := -vn
		if impact > 0.8:
			# AI 按撞击强度掉速（撞得越狠掉得越多，最少也蹭掉一成）
			ai.speed = maxf(ai.speed * clampf(1.0 - impact * 0.045, 0.70, 1.0), 2.0)
			# 玩家正面撞上时前向速度也按冲量掉（侧面刮蹭不刹车）
			var frontness := absf(n3.dot(player_fwd))
			if frontness > 0.35:
				var fdrop := minf(impact * 0.30 * frontness, 6.0)
				var vf0 := car.vel.dot(player_fwd)
				if vf0 > 0.0:
					car.vel -= player_fwd * minf(fdrop, vf0)
			# AI 弹开冲量：沿赛道侧向被撞开，update_ai 里 0.9s 衰减回走线
			var ai_side: Vector3 = frame["side"]
			ai.bump_lat = clampf(-n3.dot(ai_side), -1.0, 1.0) * minf(1.2 + impact * 0.25, 2.8)
			ai.bump_timer = 0.9
		elif depth > 0.03 and game_feel != null and game_feel.has_method("on_scrape"):
			# 低速贴住/并排磨蹭：给少量火花，避免「撞了但没反馈」。
			game_feel.on_scrape(
				clampf(-vn / 6.0 + depth * 0.4, 0.05, 0.6),
				((car.pos + ai.pos) * 0.5) + Vector3(0.0, 0.45, 0.0))

	# AI 互相分离：OBB 精确求最小分离向量。旧版只用赛道纵横矩形近似，
	# 两车斜着并排时会漏判出可见穿模；这里同时做位置、相对速度、弹开锁存。
	for i in ais.size():
		for j in range(i + 1, ais.size()):
			var a: AICar = ais[i]
			var b: AICar = ais[j]
			var half_a := _car_half_extents(String(a.spec.get("id", "")))
			var half_b := _car_half_extents(String(b.spec.get("id", "")))
			var hit := _obb_mtv(
				Vector2(a.pos.x, a.pos.z), a.heading, half_a,
				Vector2(b.pos.x, b.pos.z), b.heading, half_b)
			if not hit["hit"]:
				continue
			var normal: Vector2 = hit["normal"]  # B → A
			var depth: float = hit["depth"]
			if depth < 0.0005:
				continue
			var frame := track_path.frame_at(a.dist)
			if frame.is_empty():
				continue
			var side: Vector3 = frame["side"]
			var tangent: Vector3 = frame["tangent"]
			var n3 := Vector3(normal.x, 0.0, normal.y)
			# 位置分离：A 沿 n3、B 沿 -n3，投影回 offset/dist 并限幅。
			var push := minf(depth * 0.70, 0.36)
			var limit_a := maxf(float(frame.get("half_width", track_path.half_width)) - 1.4, 0.55)
			var frame_b := track_path.frame_at(b.dist)
			var limit_b := limit_a
			if not frame_b.is_empty():
				limit_b = maxf(float(frame_b.get("half_width", track_path.half_width)) - 1.4, 0.55)
			a.offset = clampf(a.offset + n3.dot(side) * push, -limit_a, limit_a)
			a.dist = maxf(a.dist + n3.dot(tangent) * push, 0.0)
			b.offset = clampf(b.offset - n3.dot(side) * push, -limit_b, limit_b)
			b.dist = maxf(b.dist - n3.dot(tangent) * push, 0.0)
			# 分离速度：沿各自车头方向补一点相对速度，避免同速并排被“焊死”。
			var fwd_a := Vector3(sin(a.heading), 0.0, cos(a.heading))
			var fwd_b := Vector3(sin(b.heading), 0.0, cos(b.heading))
			var rel_vn := (fwd_a * a.speed - fwd_b * b.speed).dot(n3)
			var sep := maxf(0.9, -rel_vn * 0.25)
			var dv := clampf(sep - rel_vn, 0.0, 2.0)
			if dv > 0.0:
				a.speed = maxf(a.speed + dv * 0.5 * n3.dot(fwd_a), 0.0)
				b.speed = maxf(b.speed - dv * 0.5 * n3.dot(fwd_b), 0.0)
			# 接触掉速 + 弹开锁存（bump_lat 在 update_ai 里 0.8s 衰减）
			var scrape := clampf(depth * 0.06, 0.0, 0.15)
			a.speed *= 1.0 - scrape
			b.speed *= 1.0 - scrape
			var lateral_bump := n3.dot(side) * minf(0.6 + depth, 1.5)
			a.bump_lat = clampf(a.bump_lat + lateral_bump, -2.8, 2.8)
			b.bump_lat = clampf(b.bump_lat - lateral_bump, -2.8, 2.8)
			a.bump_timer = maxf(a.bump_timer, 0.8)
			b.bump_timer = maxf(b.bump_timer, 0.8)
			max_impact = maxf(max_impact, -rel_vn)
			if game_feel != null and game_feel.has_method("on_scrape"):
				game_feel.on_scrape(
					clampf(-rel_vn / 8.0 + depth * 0.35, 0.04, 0.5),
					((a.pos + b.pos) * 0.5) + Vector3(0.0, 0.45, 0.0))
	return max_impact


# ---------------------------------------------------------------------------
# verification
# ---------------------------------------------------------------------------

func _run_verification() -> void:
	print("[M1] === data ===")
	print("[M1] " + GameData.summary())
	var failures: PackedStringArray = []
	var dt := 1.0 / 120.0
	var spec := GameData.car(DEFAULT_CAR)
	print("[M1] nitro fill: drift %.1fs / idle %.0fs" % [
		1.0 / Car.NITRO_DRIFT_GAIN, 1.0 / Car.NITRO_IDLE_GAIN])
	if 1.0 / Car.NITRO_DRIFT_GAIN < 4.0:
		failures.append("nitro fills too fast (drift %.1fs)" % (1.0 / Car.NITRO_DRIFT_GAIN))

	print("[M1] === analog input (磁轴/桥接深度) ===")
	var analog_err := AnalogInput.self_test()
	print("[M1] analog self-test: %s" % ("OK" if analog_err.is_empty() else analog_err))
	if not analog_err.is_empty():
		failures.append("analog input: " + analog_err)
	var analog_enabled_backup := Settings.analog_input_enabled
	var steer_curve_backup := Settings.analog_curve_steer
	var throttle_curve_backup := Settings.analog_curve_throttle
	var deadzone_backup := Settings.analog_deadzone
	Settings.analog_input_enabled = false
	AnalogInput.clear_debug_values()
	var digital_input := InputSetup.read_drive_input()
	print("[M1] analog off → fallback digital: steer=%.2f throttle=%.2f" % [
		float(digital_input.get("steer", 0.0)), float(digital_input.get("throttle", 0.0))])
	if absf(float(digital_input.get("steer", 0.0))) > 0.001 or absf(float(digital_input.get("throttle", 0.0))) > 0.001:
		failures.append("analog off but fallback input not neutral")
	# 模拟量 → read_drive_input：注入深度 0.6/0.8，等待平滑收敛后应是连续量（旧键盘只有 ±1/0）
	Settings.analog_input_enabled = true
	Settings.analog_curve_steer = 1.0
	Settings.analog_curve_throttle = 1.0
	Settings.analog_deadzone = 0.0
	AnalogInput.set_debug_values(0.6, 0.8)
	var last_input := {}
	for i in 14:
		await get_tree().create_timer(0.02).timeout
		last_input = InputSetup.read_drive_input()
	AnalogInput.clear_debug_values()
	print("[M1] analog depth(0.60, 0.80) → steer=%.2f throttle=%.2f" % [
		float(last_input.get("steer", 0.0)), float(last_input.get("throttle", 0.0))])
	if float(last_input.get("steer", 0.0)) < 0.35 or float(last_input.get("throttle", 0.0)) < 0.55:
		failures.append("analog depth did not reach continuous steer/throttle")
	Settings.analog_curve_steer = steer_curve_backup
	Settings.analog_curve_throttle = throttle_curve_backup
	Settings.analog_deadzone = deadzone_backup
	Settings.analog_input_enabled = analog_enabled_backup

	print("[M1] === car collision (OBB 按 manifest 车宽车长) ===")
	var half_m3 := _car_half_extents("bmw_m3_e46_gtr")
	var half_gl8 := _car_half_extents("buick_gl8")
	print("[M1] contact half: m3_e46=(%.2f, %.2f)m  gl8=(%.2f, %.2f)m" % [half_m3.x, half_m3.y, half_gl8.x, half_gl8.y])
	if absf(half_m3.x - 0.93) > 0.06 or absf(half_m3.y - 2.245) > 0.06:
		failures.append("M3 E46 contact size mismatch: %s" % str(half_m3))
	if half_gl8.x < 1.0 or half_gl8.y < 2.4:
		failures.append("GL8 contact size mismatch: %s" % str(half_gl8))
	# 同向并排：车宽 1.86m → 中心距 ~1.9m 应已被判定接触；4.2m 圆形旧逻辑会误判
	var probes := [
		[Vector2(0.0, 0.0), 0.0, Vector2(1.78, 0.0), 0.0, true],   # 并排重叠（旧圆 4.2m 才判碰）
		[Vector2(0.0, 0.0), 0.0, Vector2(2.00, 0.0), 0.0, false],  # 并排不碰（车宽 1.86m）
		[Vector2(0.0, 0.0), 0.0, Vector2(0.0, 4.40), 0.0, true],   # 追尾重叠（车长 4.49m）
		[Vector2(0.0, 0.0), 0.0, Vector2(0.0, 4.70), 0.0, false],  # 追尾不碰
	]
	var probe_ok := 0
	for pr in probes:
		var res := _obb_mtv(pr[0], pr[1], half_m3, pr[2], pr[3], half_m3)
		if bool(res["hit"]) == bool(pr[4]):
			probe_ok += 1
		else:
			failures.append("OBB probe mismatched expectation: %s → %s" % [str(pr), str(res["hit"])])
	print("[M1] OBB probes: %d/%d as expected" % [probe_ok, probes.size()])

	print("[M1] === car models (wheels / bounds) ===")
	var car_entries: Dictionary = GameData.car_manifest.get("cars", {})
	var model_issues := 0
	for car_id in car_entries.keys():
		var car_spec: Dictionary = GameData.car(String(car_id))
		var model_root := Node3D.new()
		add_child(model_root)
		var built := CarVisual.build(car_spec, model_root)
		var spins: Array = built.get("spin_wheels", [])
		var steers: Array = built.get("steer_wheels", [])
		var model: Node3D = built.get("model")
		var bounds: AABB = CarVisual.model_aabb(model) if model != null else AABB()
		var wheel_ok := spins.size() == 4 and steers.size() == 2
		var bounds_ok := bounds.size.x > 0.9 and bounds.size.y > 0.5 and bounds.size.z > 1.6
		if not wheel_ok or not bounds_ok:
			model_issues += 1
			print("[CAR] %-28s wheels=%d/4 steer=%d/2 bounds=%.2f x %.2f x %.2f" % [
				String(car_id), spins.size(), steers.size(),
				bounds.size.x, bounds.size.y, bounds.size.z])
		model_root.free()
	print("[M1] car models: %d checked, %d issues" % [car_entries.size(), model_issues])
	if model_issues > 0:
		failures.append("car model audit: %d issues" % model_issues)

	print("[M1] === track matrix ===")
	var probe := Car.new()
	probe.name = "ProbeCar"
	add_child(probe)
	probe.setup(spec, TrackPath.new(), 7.0, 0.0)
	for def in GameData.tracks:
		var path := TrackPath.new()
		path.build_from_def(def, 2.0)
		if path.samples.size() < 8:
			failures.append("track %s: too few samples" % String(def.get("id", "?")))
			continue
		var holder := Node3D.new()
		add_child(holder)
		var builder := TrackBuilder.new()
		holder.add_child(builder)
		builder.build(def)
		var mesh_count := _count_meshes(holder)
		holder.free()
		var scenery_holder := Node3D.new()
		add_child(scenery_holder)
		var scenery_stats := SceneryKit.build(scenery_holder, path, def)
		var scenery_count := _count_meshes(scenery_holder)
		# 穿模审计：所有场景物体落点对整条赛道样条求最小距离（不止最近样本点，
		# 能抓到环形折返段互相压住的建筑/树/道具）。
		# 注意：--headless 下 dummy 渲染服务器会把 MultiMesh 实例变换读回成
		# 单位阵，审计会满屏假阳性 —— 穿模审计只在有渲染的会话里跑。
		if DisplayServer.get_name() == "headless":
			print("[CLIP] %-8s skipped (headless MultiMesh readback unreliable)" % [
				String(def.get("id", "?"))])
		else:
			var clip := _audit_track_clipping(path, scenery_holder, String(def.get("id", "?")))
			print("[CLIP] %-8s objects=%4d min_dist=%5.2fm on_road=%d" % [
				String(def.get("id", "?")), clip["objects"], clip["min_dist"], clip["violations"]])
			if int(clip["violations"]) > 0:
				failures.append("track %s: %d scenery objects on the road" % [
					String(def.get("id", "?")), int(clip["violations"])])
		scenery_holder.free()
		if path.total_length < 800.0:
			failures.append("track %s: length %.1fm too short" % [String(def.get("id", "?")), path.total_length])
		if mesh_count < 4:
			failures.append("track %s: only %d meshes" % [String(def.get("id", "?")), mesh_count])

		probe.track = path
		probe.reset(7.0, 0.0)
		var travelled := 0.0
		var max_kph := 0.0
		var prev := probe.pos
		var steps := int(10.0 / dt)
		for i in steps:
			var input := _autopilot_for(probe, path)
			probe.update_car(dt, input)
			travelled += probe.pos.distance_to(prev)
			prev = probe.pos
			max_kph = maxf(max_kph, probe.speed_kph)
		print("[M1] %-8s len=%7.1fm width=%4.1fm meshes=%2d sim=%6.1fm max=%5.1fkph" % [
			String(def.get("id", "?")), path.total_length, path.width, mesh_count, travelled, max_kph])
		print("[M3] %-8s scenery: nodes=%3d instances=%4d" % [
			String(def.get("id", "?")), scenery_count, int(scenery_stats["instances"])])
		if int(scenery_stats["instances"]) < 40:
			failures.append("M3: track %s scenery only %d instances" % [String(def.get("id", "?")), int(scenery_stats["instances"])])
		if travelled < 80.0:
			failures.append("track %s: car only travelled %.1fm in 10s" % [String(def.get("id", "?")), travelled])
	probe.queue_free()

	print("[M1] === full GP race: coast, 3 laps, 3 AI ===")
	_start_race("coast", DEFAULT_CAR, "gp")
	if race == null:
		failures.append("race manager failed to start")
	else:
		_ai_probe = {"n": 0, "gap_sum": 0.0, "gap_min": 9999.0, "close": 0, "cluster": 0,
			"spread_sum": 0.0, "along_sum": 0.0, "along_close": 0}
		_ai_probe_t = 0.0
		var simulated := _simulate_until_results(400.0, dt)
		print("[M1] simulated %.1fs of race in %d steps" % [simulated, int(simulated / dt)])
		var probe_n := maxi(1, int(_ai_probe["n"]))
		print("[M1] AI spacing: avg_closest=%.1fm min=%.1fm packed(<10m)=%.0f%% trio(<16m)=%.0f%% track_spread=%.0fm along_closest=%.1fm along_close(<12m)=%.0f%%" % [
			float(_ai_probe["gap_sum"]) / float(probe_n), float(_ai_probe["gap_min"]),
			100.0 * float(_ai_probe["close"]) / float(probe_n),
			100.0 * float(_ai_probe["cluster"]) / float(probe_n),
			float(_ai_probe["spread_sum"]) / float(probe_n),
			float(_ai_probe["along_sum"]) / float(probe_n),
			100.0 * float(_ai_probe["along_close"]) / float(probe_n)])
		for ai in ais:
			print("[M1]   AI %-12s lap=%d finished=%s dist=%.0fm (player %.0fm)" % [
				ai.display_name, ai.lap, str(ai.finished), ai.race_dist, race.player_race_dist])
		print("[M1] state=%d t=%.2fs laps=%d/%d pos=P%d/%d best_lap=%s medal=%s" % [
			int(race.state), race.race_time, race.player_laps, race.race_laps,
			race.player_position, race.total_cars,
			RaceManager.format_time(race.best_lap_time), race.medal])
		if race.state != RaceManager.State.RESULTS:
			failures.append("race did not reach RESULTS (state=%d)" % int(race.state))
		else:
			if race.results.size() != 4:
				failures.append("standings has %d entries (expected 4)" % race.results.size())
			if race.best_lap_time <= 0.0:
				failures.append("player best lap not recorded")
			var ai_laps := 0
			for ai in ais:
				ai_laps = maxi(ai_laps, ai.lap)
			if ai_laps < 1:
				failures.append("AI rivals did not complete a lap")
			for row in race.results:
				print("[M1]   P%d  %-14s %s" % [int(row["rank"]), String(row["name"]), String(row["time_text"])])
			if not FileAccess.file_exists("user://records.json"):
				failures.append("records.json was not written")
			else:
				print("[M1] records: " + JSON.stringify(RecordsStore.load_all()))
		_clear_race()

	print("[M2] === garage / tuning ===")
	var garage_backup: Dictionary = Garage.cars.duplicate(true)
	var car_id := DEFAULT_CAR
	var stock := GameData.car(car_id)
	var cfg0 := Garage.config(car_id)
	print("[M2] options: palettes=%d wheels=%d tires=%d wings=%d calipers=%d" % [
		Garage.palette_size(car_id),
		GameData.garage.get("wheel_styles", []).size(),
		GameData.garage.get("tire_styles", []).size(),
		GameData.garage.get("wing_styles", []).size(),
		GameData.garage.get("calipers", []).size()])
	var stock_top := float(stock.get("topKph", 0))
	var stock_grip := float(stock.get("grip", 0.0))
	# 改装现在花 XP：验证期间临时给足积分，M2 结束恢复玩家档案。
	var ps_prof := load("res://scripts/core/profile_store.gd")
	var profile_backup: Dictionary = ps_prof.load_profile()
	var verify_profile := profile_backup.duplicate(true)
	verify_profile["xp"] = maxi(int(verify_profile.get("xp", 0)), 200000)
	ps_prof.save_profile(verify_profile)
	for key in Garage.UPGRADE_KEYS:
		for i in 5:
			Garage.add_upgrade_level(car_id, key)
	var tuned := Garage.effective_spec(car_id)
	print("[M2] tuned: topKph %d -> %d | accel %.2f -> %.2f | grip %.2f -> %.2f | 0-100 %.1f -> %.1f | nitro Lv%d" % [
		int(stock_top), int(tuned.get("topKph", 0)),
		float(stock.get("accel", 0.0)), float(tuned.get("accel", 0.0)),
		stock_grip, float(tuned.get("grip", 0.0)),
		float(stock.get("zeroTo100", 0.0)), float(tuned.get("zeroTo100", 0.0)),
		int(tuned.get("nitroLevel", 0))])
	if int(tuned.get("topKph", 0)) <= int(stock_top):
		failures.append("M2: engine upgrade did not raise top speed")
	if float(tuned.get("grip", 0.0)) <= stock_grip:
		failures.append("M2: tyres/aero upgrade did not raise grip")
	cfg0["paint"] = 1
	cfg0["wheel"] = 1
	cfg0["tire"] = 1
	cfg0["wing"] = 1
	cfg0["caliper"] = 2
	Garage.save_to_disk()
	var garage_holder := Node3D.new()
	add_child(garage_holder)
	var preview := CarVisual.build(Garage.effective_spec(car_id), garage_holder)
	var applied := GarageLook.apply(preview["model"], car_id, cfg0)
	print("[M2] look: rims=%d tyres=%d wing=%s calipers=%d" % [
		int(applied["rims"]), int(applied["tires"]), str(applied["wing"]), int(applied.get("calipers", 0))])
	# v0.54 重开外观改装：wheel/tire/wing 都应挂载成功（按每台车实测尺寸生成）
	if int(applied["rims"]) == 0 or int(applied["tires"]) == 0 or not bool(applied["wing"]):
		failures.append("M2: garage parts should mount again (rims/tires/wing)")
	# 换色确实生效：CARPAINT 材质 albedo ≈ 调色板颜色
	var want_paint := Garage.paint_color(car_id)
	var paint_hit := false
	for mi_node in preview["model"].find_children("*", "MeshInstance3D", true, false):
		var mi2 := mi_node as MeshInstance3D
		if mi2.mesh == null:
			continue
		for si in mi2.mesh.get_surface_count():
			var m2 := mi2.get_active_material(si) as StandardMaterial3D
			if m2 == null:
				continue
			var mn2 := String(m2.resource_name).to_lower()
			if mn2.contains("carpaint") or mn2.contains("paint"):
				if m2.albedo_color.r > want_paint.r - 0.08 and m2.albedo_color.r < want_paint.r + 0.08 \
						and m2.albedo_color.g > want_paint.g - 0.08 and m2.albedo_color.g < want_paint.g + 0.08:
					paint_hit = true
					break
		if paint_hit:
			break
	print("[M2] paint applied: %s (want %s)" % [str(paint_hit), str(want_paint)])
	if not paint_hit:
		failures.append("M2: garage paint colour did not apply")
	garage_holder.free()
	Garage.load_from_disk()
	var reloaded := Garage.config(car_id)
	if int(reloaded.get("engine", 0)) != 5 or int(reloaded.get("wheel", 0)) != 1:
		failures.append("M2: garage save/load roundtrip failed")
	print("[M2] save/load: engine=%d wheel=%d paint=%d" % [
		int(reloaded.get("engine", 0)), int(reloaded.get("wheel", 0)), int(reloaded.get("paint", 0))])
	_open_garage(car_id)
	if garage_screen == null or garage_world == null:
		failures.append("M2: garage screen failed to open")
	else:
		var ui_car := garage_screen._current_car_id()
		garage_screen.car_index = posmod(garage_screen.car_index + 1, GameData.cars_specs.size())
		garage_screen.refresh()
		print("[M2] garage UI: opened with %s, car switch -> %s" % [ui_car, garage_screen._current_car_id()])
	_clear_race()
	ps_prof.save_profile(profile_backup)
	_start_race("coast", car_id, "gp")
	var rim_nodes := 0
	if car == null:
		failures.append("M2: tuned race car failed to spawn")
	else:
		if car.model != null:
			rim_nodes = car.model.find_children("ProceduralPartWheel_*", "", true, false).size()
		print("[M4] venue: nodes=%d instances=%d" % [int(_venue_stats.get("meshes", 0)), int(_venue_stats.get("instances", 0))])
		print("[M4] vegetation clearance (placement-time): rejected=%d min_tree_dist=%.2fm limit=%.2fm" % [
			VenueKit.rejected_placements, VenueKit.min_tree_clearance,
			track_path.half_width + 7.0])
		if race_root != null:
			var has_sea := get_node_or_null("RaceWorld/TrackBuilder/Sea") != null
			var has_grid := get_node_or_null("RaceWorld/TrackBuilder/StartGrid") != null
			var has_marks := get_node_or_null("RaceWorld/TrackBuilder/TireMarks") != null
			print("[M4] coast extras: sea=%s start_grid=%s tyre_marks=%s" % [str(has_sea), str(has_grid), str(has_marks)])
			if not has_sea or not has_grid or not has_marks:
				failures.append("M4: coast extras missing")
	print("[M2] race car: maxSpeed=%.2f (tuned %.2f) topKph=%d procedural_wheels=%d" % [
		car.max_speed, float(tuned.get("maxSpeed", 0.0)),
		int(car.spec.get("topKph", 0)), rim_nodes])
	if absf(car.max_speed - float(tuned.get("maxSpeed", 0.0))) > 0.01:
		failures.append("M2: race car did not use the tuned spec")
	if rim_nodes != 4:
		failures.append("M2: race car should mount 4 procedural wheels (%d)" % rim_nodes)
	_clear_race()
	_start_race("city", DEFAULT_CAR, "gp")
	if car != null and car.model != null:
		var headlights := car.model.find_children("Headlight*", "", true, false).size()
		print("[M3] night race (city): headlights=%d scenery=%s" % [headlights, str(race != null)])
		if headlights != 2:
			failures.append("M3: night car headlights %d/2" % headlights)
	var weather_ok := weather != null and weather.kind == "rain" and weather.particles != null
	print("[M3] weather fx (city rain): ok=%s" % str(weather_ok))
	if not weather_ok:
		failures.append("M3: rain weather fx missing")
	if car != null and track_path != null:
		# barrier clamp: car body must not sit inside the guardrail
		var frame := track_path.frame_at(car.progress_dist + 3.0)
		if not frame.is_empty():
			var side: Vector3 = frame["side"]
			car.pos = (frame["pos"] as Vector3) + side * (track_path.half_width + 4.0)
			car.vel = Vector3.ZERO
			car._update_track_contact(1.0 / 120.0)
			var info := track_path.nearest(car.pos, car.track_index)
			var lat := absf(float(info["lateral"]))
			print("[M3] barrier clamp: lateral=%.2fm (limit=%.2fm)" % [lat, track_path.half_width + 0.55])
			if lat > track_path.half_width + 0.95:
				failures.append("M3: car body still inside guardrail (lateral %.2f)" % lat)
			# camera clamp: chase camera must stay inside the corridor
			if cam != null:
				cam.global_position = (frame["pos"] as Vector3) + side * (track_path.half_width + 6.0) + Vector3(0.0, 2.5, 0.0)
				cam._keep_camera_on_track()
				var cinfo := track_path.nearest(cam.global_position, car.track_index)
				print("[M3] camera clamp: lateral=%.2fm" % absf(float(cinfo["lateral"])))
				if absf(float(cinfo["lateral"])) > track_path.half_width + 1.3:
					failures.append("M3: chase camera clips outside guardrail")
		# car-car contact resolution
		if ais.size() > 0:
			var ai0: AICar = ais[0]
			car.pos = ai0.pos + Vector3(0.2, 0.0, 0.1)
			car.vel = Vector3.ZERO
			for n in 16:
				_resolve_car_contacts()
			var sep := Vector2(car.pos.x - ai0.pos.x, car.pos.z - ai0.pos.z).length()
			print("[M3] car contact: separation after forced overlap = %.2fm" % sep)
			if sep < 1.8:
				failures.append("M3: car-car contact resolution failed (%.2fm)" % sep)
			# 防粘 + 防闪现：朝对方给 8m/s 的接触速度，解算一帧后位移必须很小、且已产生分离速度
			car.pos = ai0.pos + Vector3(0.32, 0.0, 0.18)
			car.vel = Vector3.ZERO
			var ai_half_t := _car_half_extents(String(ai0.spec.get("id", "")))
			var car_half_t := _car_half_extents(current_car_id)
			var probe_hit := _obb_mtv(Vector2(car.pos.x, car.pos.z), car.heading, car_half_t,
				Vector2(ai0.pos.x, ai0.pos.z), ai0.heading, ai_half_t)
			if probe_hit["hit"]:
				var nn: Vector2 = probe_hit["normal"]
				var n3t := Vector3(nn.x, 0.0, nn.y)
				car.vel = -n3t * 8.0  # 朝对方压过去
				var max_move := 0.0
				for k in 18:
					var pos_before := car.pos
					_resolve_car_contacts()
					max_move = maxf(max_move, car.pos.distance_to(pos_before))
				var ai_vel_t := Vector3(sin(ai0.heading), 0.0, cos(ai0.heading)) * ai0.speed
				var vn_after := (car.vel - ai_vel_t).dot(n3t)
				print("[M3] contact impulse: max_move=%.2fm rel_vn=%.2f (单帧位移应小、最终应 >=0)" % [max_move, vn_after])
				if max_move > 0.40:
					failures.append("M3: contact position snap too big (%.2fm)" % max_move)
				if vn_after < -0.2:
					failures.append("M3: contact did not separate (rel_vn %.2f)" % vn_after)
		# AI-AI contact: 三台 AI 之间也不能穿模或焊死
		if ais.size() >= 2 and track_path != null:
			var aa: AICar = ais[0]
			var bb: AICar = ais[1]
			var af0 := track_path.frame_at(aa.dist)
			if not af0.is_empty():
				bb.dist = aa.dist + 0.15
				bb.offset = clampf(aa.offset + 0.45, -track_path.half_width + 2.2, track_path.half_width - 2.2)
				bb.speed = aa.speed
				for n in 24:
					_resolve_car_contacts()
					var af := track_path.frame_at(aa.dist)
					aa.pos = (af["pos"] as Vector3) + (af["side"] as Vector3) * aa.offset
					aa.heading = atan2((af["tangent"] as Vector3).x, (af["tangent"] as Vector3).z)
					var bf := track_path.frame_at(bb.dist)
					bb.pos = (bf["pos"] as Vector3) + (bf["side"] as Vector3) * bb.offset
					bb.heading = atan2((bf["tangent"] as Vector3).x, (bf["tangent"] as Vector3).z)
				var half_aa := _car_half_extents(String(aa.spec.get("id", "")))
				var half_bb := _car_half_extents(String(bb.spec.get("id", "")))
				var residual := _obb_mtv(Vector2(aa.pos.x, aa.pos.z), aa.heading, half_aa,
					Vector2(bb.pos.x, bb.pos.z), bb.heading, half_bb)
				var residual_depth := float(residual["depth"]) if bool(residual["hit"]) else 0.0
				var sep_ai := Vector2(aa.pos.x - bb.pos.x, aa.pos.z - bb.pos.z).length()
				print("[M3] ai-ai contact: residual_depth=%.2fm separation=%.2fm" % [residual_depth, sep_ai])
				if residual_depth > 0.08:
					failures.append("M3: AI-AI overlap not resolved (%.2fm)" % residual_depth)
	_clear_race()
	Garage.cars = garage_backup
	Garage.save_to_disk()

	if failures.is_empty():
		print("[VERIFY] PASS")
		_clear_race()
		await get_tree().process_frame
		get_tree().quit(0)
	else:
		for failure in failures:
			print("[M1] FAIL: " + failure)
		print("[VERIFY] FAIL (%d)" % failures.size())
		_clear_race()
		await get_tree().process_frame
		get_tree().quit(2)


func _simulate_until_results(max_seconds: float = 400.0, dt: float = 1.0 / 120.0) -> float:
	if race == null or car == null:
		return 0.0
	var sim := 0.0
	var steps := int(max_seconds / dt)
	for i in steps:
		if race.state == RaceManager.State.RESULTS:
			break
		var input: Dictionary
		if race.state == RaceManager.State.COUNTDOWN:
			input = COUNTDOWN_INPUT
		else:
			input = _autopilot_input()
		car.update_car(dt, input)
		_update_player_pace(dt)
		if race.state != RaceManager.State.COUNTDOWN:
			for ai in ais:
				ai.update_ai(dt, car, race.race_laps, ais, race.player_pace)
			_resolve_car_contacts()
		race.update(dt)
		if current_mode == "ta":
			_update_ghost(dt)
		_ai_probe_t += dt
		if _ai_probe_t >= 0.5 and race.state != RaceManager.State.COUNTDOWN and ais.size() >= 2:
			_ai_probe_t = 0.0
			var closest := 9999.0
			var closest_along := 9999.0
			var farthest := 0.0
			var min_dist := 9999.0
			var max_dist := -9999.0
			for a in range(ais.size()):
				min_dist = minf(min_dist, ais[a].race_dist)
				max_dist = maxf(max_dist, ais[a].race_dist)
				for b in range(a + 1, ais.size()):
					var gap := ais[a].pos.distance_to(ais[b].pos)
					closest = minf(closest, gap)
					farthest = maxf(farthest, gap)
					closest_along = minf(closest_along, absf(ais[a].race_dist - ais[b].race_dist))
			_ai_probe["n"] = int(_ai_probe["n"]) + 1
			_ai_probe["gap_sum"] = float(_ai_probe["gap_sum"]) + closest
			_ai_probe["gap_min"] = minf(float(_ai_probe["gap_min"]), closest)
			_ai_probe["spread_sum"] = float(_ai_probe["spread_sum"]) + (max_dist - min_dist)
			_ai_probe["along_sum"] = float(_ai_probe["along_sum"]) + closest_along
			if closest < 10.0:
				_ai_probe["close"] = int(_ai_probe["close"]) + 1
			if closest_along < 12.0:
				_ai_probe["along_close"] = int(_ai_probe["along_close"]) + 1
			if farthest < 16.0:
				_ai_probe["cluster"] = int(_ai_probe["cluster"]) + 1
		sim += dt
	return sim


func _perf_tick(dt: float) -> void:
	if state != AppState.RACE:
		return
	_perf_time += dt
	_perf_sample_timer += dt
	if _perf_sample_timer >= 0.1 and _perf_time > 2.5:
		_perf_sample_timer = 0.0
		_perf_samples.append(float(Engine.get_frames_per_second()))
		_perf_drawcalls.append(float(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)))
		_perf_triangles.append(float(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)))
		_perf_proc_us.append(float(Performance.get_monitor(Performance.TIME_PROCESS)))
		_perf_phys_us.append(float(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)))
	if _perf_time < 10.0:
		return
	var fps_sum := 0.0
	var fps_min := 9999.0
	var draw_sum := 0.0
	var tri_sum := 0.0
	for i in _perf_samples.size():
		fps_sum += _perf_samples[i]
		fps_min = minf(fps_min, _perf_samples[i])
		if i < _perf_drawcalls.size():
			draw_sum += _perf_drawcalls[i]
			tri_sum += _perf_triangles[i]
	var n := maxi(1, _perf_samples.size())
	var proc_ms := 0.0
	var phys_ms := 0.0
	for i in _perf_proc_us.size():
		proc_ms += _perf_proc_us[i]
		phys_ms += _perf_phys_us[i]
	var m := maxi(1, _perf_proc_us.size())
	print("[PERF] track=%s car=%s mode=%s vsync_off" % [current_track_id, current_car_id, current_mode])
	print("[PERF] fps avg=%.1f min=%.1f | draw_calls avg=%.0f | primitives avg=%.0f" % [
		fps_sum / float(n), fps_min, draw_sum / float(n), tri_sum / float(n)])
	print("[PERF] script_process avg=%.2f ms | physics avg=%.2f ms (帧预算 %.1f ms)" % [
		proc_ms / float(m), phys_ms / float(m), 1000.0 / (fps_sum / float(n))])
	get_tree().quit(0)


## 模拟输入链路自测：等待外部 UDP 桥发包 2.5s，打印收到的包数与映射值。
## 用法：先 `python3 tools/analog_input/analog_bridge.py --test`，再
##       `Godot --headless --path . -- --analog-test`（退出码 0=收到包, 2=没收到）
func _run_analog_test() -> void:
	var port := _ace68_effective_port()
	var t0 := Time.get_ticks_msec()
	var st := {"packets": 0, "active": false}
	while Time.get_ticks_msec() - t0 < 2500:
		st = AnalogInput.poll(port, true)
		await get_tree().process_frame
	st = AnalogInput.poll(port, true)
	var packets := int(st.get("packets", 0))
	var active := bool(st.get("active", false))
	var steer := AnalogInput.map_steer(float(st.get("steer", 0.0)), Settings.analog_deadzone, Settings.analog_curve_steer)
	var throttle := AnalogInput.map_throttle(float(st.get("throttle", 0.0)), Settings.analog_curve_throttle)
	print("[ANALOG-TEST] port=%d packets=%d active=%s steer=%.3f throttle=%.3f status=%s" % [
		port, packets, str(active), steer, throttle, AnalogInput.status_text(port)])
	get_tree().quit(0 if active and packets > 0 else 2)


func _run_scenery_debug() -> void:
	var def := GameData.track(_track_or_default())
	var path := TrackPath.new()
	path.build_from_def(def, 2.0)
	var holder := Node3D.new()
	add_child(holder)
	var stats := SceneryKit.build(holder, path, def)
	print("[DBG] scenery stats=", stats)
	for child in holder.find_children("*", "MultiMeshInstance3D", true, false):
		if child is MultiMeshInstance3D:
			var mmi := child as MultiMeshInstance3D
			var mat = mmi.material_override
			var info := "no-material"
			if mat is StandardMaterial3D:
				var m := mat as StandardMaterial3D
				info = "tex=%s em=%s emE=%.2f albedo=%s" % [
					str(m.albedo_texture != null), str(m.emission_enabled),
					m.emission_energy_multiplier, str(m.albedo_color)]
			print("  %-12s inst=%-4d mat=%s %s" % [mmi.name, mmi.multimesh.instance_count, mat.get_class() if mat != null else "null", info])
	get_tree().quit(0)


# ---------------------------------------------------------------------------
# 场景几何审计（--scenery-audit）
# 按「顶点实测」检查 4 类看起来假的问题（必须在带窗口的会话里跑：headless 下
# MultiMesh 实例变换读回全是单位阵，见 verify 的穿模审计注释）：
#   [ASSET] 装饰资产模板包围盒：原点离底面多远 —— 摆放公式坐没坐对地方的前提
#   [FLOAT] 悬空：实例最低点高于足迹下方最低地面（含坡地单侧悬空）
#   [TIP]   尖点/棱边着地：几乎没有埋深、底面接触带又极窄（石头立在一个尖上）
#   [SUNK]  掩埋过深：底面埋进地下太多，肉眼只剩一小截
#   [XSEC]  互相穿模：不同装饰组的实例顶点扎进对方包围盒
# ---------------------------------------------------------------------------

const AUDIT_SKIP_PATTERNS: PackedStringArray = [
	"sea", "water", "ground", "far", "sky", "cloud", "road", "kerb", "curb",
	"guardrail", "post", "startline", "startgrid", "tiremark", "runoff",
	"lanemark", "valleywall", "grass", "lawn", "mark", "skirt", "band",
	"canopy", "gantry", "bird", "truss", "bridge", "wire", "cable",
	"boat", "ship", "buoy", "cone", "reflector", "bollard", "tyre", "tire",
	"palm", "pine", "tree", "trunk", "shrub", "reed", "cactus", "bush",
	"mountain", "hill",
	# powerline 网格自带跨谷导线，AABB 跨在低地上，地面参照无意义；
	# manhole 是路面贴花，贴在护栏底下不算穿模；glow 是热浪特效；
	# pass_terrain_basin 是导入地形件，半埋进山体是设计
	"powerline", "manhole", "glow", "basin",
]


func _run_scenery_audit() -> void:
	var only := _track_or_default()
	var cache := {}
	var grand := {"float": 0, "tip": 0, "sunk": 0, "xsec": 0, "objects": 0}
	var printed_assets := {}
	for def in GameData.tracks:
		var track_id := String(def.get("id", "?"))
		if not only.is_empty() and only != "all" and track_id != only:
			continue
		if track_id == "open_world":
			print("[AUDIT] %-9s skipped（开放世界走 OpenWorld 流水线，非环形赛道）" % track_id)
			continue
		var holder := Node3D.new()
		holder.name = "AuditWorld"
		add_child(holder)
		var builder := TrackBuilder.new()
		holder.add_child(builder)
		var path := builder.build(def)
		if bool(def.get("realCity", false)):
			# 实景城市：真实游戏只摆 CityRing 场景 + 起跑线（build 内部早退），
			# 不跑通用 SceneryKit/VenueKit —— 审计必须和游戏同管线才有意义
			TrackBuilder.configure_terrain(path)
			add_city_model(holder)
		else:
			SceneryKit.build(holder, path, def)
			VenueKit.build(holder, path, def, def.get("theme", {}))
			DecorOverrides.apply(holder, track_id)
		var res := _scenery_audit_track(holder, track_id, cache)
		holder.free()
		for k in grand.keys():
			grand[k] = int(grand[k]) + int(res.get(k, 0))
		var st := path.main_straight()
		print("[AUDIT] %-9s objects=%4d float=%-3d tip=%-3d sunk=%-3d xsec=%d  straight center=%.0f len=%.0f" % [
			track_id, int(res.get("objects", 0)), int(res.get("float", 0)),
			int(res.get("tip", 0)), int(res.get("sunk", 0)), int(res.get("xsec", 0)),
			float(st.get("center_dist", 0.0)), float(st.get("length", 0.0))])
		for a in res.get("assets", []):
			var asset_name := String(a)
			if printed_assets.has(asset_name):
				continue
			printed_assets[asset_name] = true
			var box := _audit_asset_bounds(asset_name)
			if box.size.y > 0.01:
				print("  [ASSET] %-20s size=(%.1f,%.1f,%.1f) 底面低于原点 %d%%" % [
					asset_name, box.size.x, box.size.y, box.size.z,
					int(round(100.0 * -box.position.y / box.size.y))])
		for row in res.get("rows", []):
			print("  " + String(row))
	print("[AUDIT] === total === objects=%d float=%d tip=%d sunk=%d xsec=%d" % [
		int(grand["objects"]), int(grand["float"]), int(grand["tip"]),
		int(grand["sunk"]), int(grand["xsec"])])
	get_tree().quit(0)


func _audit_skip_name(nm: String) -> bool:
	var low := nm.to_lower()
	for p in AUDIT_SKIP_PATTERNS:
		if low.contains(p):
			return true
	return false


func _audit_category(nm: String, asset: String) -> String:
	var low_asset := asset.to_lower()
	var low := (nm + " " + low_asset).to_lower()
	for k in ["block", "apt", "tower", "downtown", "factory", "station",
			"colony", "launch", "lovedeath", "building", "qt_"]:
		if low.contains(k):
			return "building"
	if not asset.is_empty():
		return RealAssetKit.category_of(asset)
	for k in ["rock", "boulder", "stone", "breakwater", "peak"]:
		if low.contains(k):
			return "rock"
	for k in ["grandstand", "pit", "facade", "venue", "city_",
			"ledge", "podium", "cornerfin", "spire", "citytier",
			"cityneon", "entranceneon"]:
		if low.contains(k):
			return "building"
	return "prop"


var _audit_mi_cache: Dictionary = {}


func _audit_subtree_mi_count(node: Node) -> int:
	var pid := node.get_instance_id()
	if _audit_mi_cache.has(pid):
		return int(_audit_mi_cache[pid])
	var n := node.find_children("*", "MeshInstance3D", true, false).size()
	_audit_mi_cache[pid] = n
	return n


## 足迹下方地面高度范围（含 8 个环点，覆盖坡地单侧悬空）。
func _audit_ground_range(pos: Vector3, r: float) -> Vector2:
	var gmin := 1e9
	var gmax := -1e9
	var offs: Array[Vector3] = [
		Vector3.ZERO, Vector3(r, 0, 0), Vector3(-r, 0, 0),
		Vector3(0, 0, r), Vector3(0, 0, -r),
		Vector3(r * 0.7, 0, r * 0.7), Vector3(-r * 0.7, 0, r * 0.7),
		Vector3(r * 0.7, 0, -r * 0.7), Vector3(-r * 0.7, 0, -r * 0.7),
	]
	for off in offs:
		var h := Terrain.height_at(pos + off)
		gmin = minf(gmin, h)
		gmax = maxf(gmax, h)
	return Vector2(gmin, gmax)


func _scenery_audit_track(root: Node3D, track_id: String, vert_cache: Dictionary) -> Dictionary:
	var objects := 0
	var caps := {"float": 40, "tip": 12, "sunk": 12}
	var counts := {"float": 0, "tip": 0, "sunk": 0}
	var row_counts := {"float": 0, "tip": 0, "sunk": 0}
	var group_counts := {"float": {}, "tip": {}, "sunk": {}}
	var rows: Array = []
	var asset_names: Array = []
	var clusters := {}
	_audit_mi_cache = {}

	# 收集并按「同一摆放」聚类：多 surface 资产（树干/树冠、广告牌面/支腿）
	# 会被拆成多个 MultiMesh，单独审树冠组会误报悬空。
	# key 优先用 decor_group meta + 实例序号；MeshInstance3D 的 venue 建筑
	# 分面（*_mat_*）按前缀整栋合并。
	for node in root.find_children("*", "MultiMeshInstance3D", true, false):
		var mmi := node as MultiMeshInstance3D
		if mmi == null or mmi.multimesh == null or mmi.multimesh.mesh == null:
			continue
		if _audit_skip_name(String(mmi.name)):
			continue
		var asset := String(mmi.get_meta("decor_asset", "")) if mmi.has_meta("decor_asset") else ""
		var cat := String(mmi.get_meta("audit_cat", "")) if mmi.has_meta("audit_cat") \
			else _audit_category(String(mmi.name), asset)
		var verts := _mesh_sample_verts(mmi.multimesh.mesh, vert_cache)
		if verts.is_empty():
			continue
		var grp_key := ""
		if mmi.has_meta("decor_group"):
			# key 必须带 chunk：place_chunked 会把实例按空间分块，每块里都有 0 号实例，
			# 不带 chunk 会把全赛道所有块的 0 号实例并成一簇
			grp_key = "%s_g%d" % [String(mmi.get_meta("decor_group")),
				int(mmi.get_meta("decor_chunk", 0))]
		else:
			grp_key = String(mmi.name)
		var nm_low := String(mmi.name).to_lower()
		if grp_key.contains("_mat_"):
			# venue 建筑分面（*_mat_*）：整栋合并，屋顶/檐口单独看必然「悬空」
			grp_key = "MAT:%s" % grp_key.substr(0, grp_key.find("_mat_"))
		if not asset.is_empty():
			asset_names.append(asset)
		for i in mmi.multimesh.instance_count:
			var xf := mmi.global_transform * mmi.multimesh.get_instance_transform(i)
			objects += _audit_cluster_add(clusters, "%s#%d" % [grp_key, i],
				verts, mmi.multimesh.mesh.get_aabb(), xf, grp_key, asset, cat, i)
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi == null or mi.mesh == null or _audit_skip_name(String(mi.name)):
			continue
		var asset2 := String(mi.get_meta("decor_asset", "")) if mi.has_meta("decor_asset") else ""
		var cat2 := String(mi.get_meta("audit_cat", "")) if mi.has_meta("audit_cat") \
			else _audit_category(String(mi.name), asset2)
		var verts2 := _mesh_sample_verts(mi.mesh, vert_cache)
		if verts2.is_empty():
			continue
		if OS.get_environment("AUDIT_DEBUG").length() > 0 and String(mi.name).begins_with("@"):
			var ab := mi.get_aabb()
			print("[MI-DBG] %s parent=%s path=%s aabb=(%.1f,%.1f,%.1f)-(%1.f,%.1f,%.1f) gpos=(%.1f,%.1f,%.1f)" % [
				String(mi.name), String(mi.get_parent().name) if mi.get_parent() != null else "-",
				String(mi.get_path()) if mi.is_inside_tree() else "-",
				ab.position.x, ab.position.y, ab.position.z,
				ab.end.x, ab.end.y, ab.end.z,
				mi.global_transform.origin.x, mi.global_transform.origin.y, mi.global_transform.origin.z])
		var nm := String(mi.name)
		var key2 := "ND:%s" % nm
		var grp2 := nm
		if nm.contains("_mat_"):
			key2 = "MAT:%s" % nm.substr(0, nm.find("_mat_"))
		elif nm.begins_with("@"):
			# 场景实例的自动命名子网格：上溯到最近的具名祖先合并成一个物件，
			# 但父节点必须是个小物件（子树 ≤ 8 个 mesh）——城市容器挂着上百个
			# 楼体/屋顶，合并会把整座城并成一簇，支撑/穿模判定全部失效
			var p: Node = mi
			while p != null and String(p.name).begins_with("@"):
				p = p.get_parent()
			if p != null and p != root and _audit_subtree_mi_count(p) <= 8:
				key2 = "NDP:%d" % p.get_instance_id()
				grp2 = String(p.name)
		if not asset2.is_empty():
			asset_names.append(asset2)
		objects += _audit_cluster_add(clusters, key2, verts2, mi.mesh.get_aabb(),
			mi.global_transform, grp2, asset2, cat2, -1)

	var cands: Array = []
	for k in clusters.keys():
		var cl: Dictionary = clusters[k]
		var mn: Vector3 = cl["mn"]
		var mx: Vector3 = cl["mx"]
		var pos := (mn + mx) * 0.5
		# 采样环钳到 4m：大建筑（看台 30m 宽）的环会飘到几十米外的海床/远坡，
		# 把坐得好好的建筑误判成悬空；坡地单侧悬空在 4m 环内照样能抓到
		var gr := _audit_ground_range(pos, minf(0.5 * maxf(mx.x - mn.x, mx.z - mn.z), 4.0))
		var parts: Array = cl["parts"]
		# 实测顶点半径：采样顶点到簇中心的水平距离最大值。切角/L 形足迹
		# （qt 楼宇切角）的网格 AABB 盒角是空的，顶点扎进盒角会误报穿模；
		# 盒角必在实测半径之外，用它把「盒角假扎」滤掉。
		var vr := 0.0
		for p_v2 in parts:
			var pv: Dictionary = p_v2
			var pxf := pv["xf"] as Transform3D
			for v_v in (pv["verts"] as PackedVector3Array):
				var wv := pxf * v_v
				vr = maxf(vr, Vector2(wv.x - pos.x, wv.z - pos.z).length())
		cands.append({
			"key": String(k),
			"group": String(cl["group"]),
			"members": int(cl["members"]),
			"asset": String(cl["asset"]), "cat": String(cl["cat"]),
			"idx": int(cl["idx"]),
			"parts": parts,
			"mn": mn, "mx": mx,
			"vol": (mx.x - mn.x) * (mx.y - mn.y) * (mx.z - mn.z),
			"min_y": mn.y, "max_y": mx.y,
			"height": maxf(mx.y - mn.y, 0.4),
			"radius": maxf(0.5 * maxf(mx.x - mn.x, mx.z - mn.z), 0.8),
			"band_r": float(parts[0]["band_r"]) if parts.size() == 1 else 999.0,
			"vert_r": vr,
			"center": pos, "gmin": gr.x, "gmax": gr.y,
		})

	# 空间哈希：挂载判定与互相穿模共用
	var cell := 30.0
	var grid := {}
	for i in cands.size():
		var c0: Dictionary = cands[i]
		var key0 := Vector2i(int(floor(float(c0["center"].x) / cell)), int(floor(float(c0["center"].z) / cell)))
		if not grid.has(key0):
			grid[key0] = []
		(grid[key0] as Array).append(i)

	for c_v in cands:
		var c: Dictionary = c_v
		var kind := _audit_classify(c)
		if kind == "float" and _audit_has_support(c, cands, grid, cell):
			kind = ""  # 装在别的构件上（层叠/托架/雨棚），不是悬空
		if kind.is_empty():
			continue
		counts[kind] = int(counts[kind]) + 1
		var g := String(c["group"])
		var gc: Dictionary = group_counts[kind]
		gc[g] = int(gc.get(g, 0)) + 1
		if int(row_counts[kind]) < int(caps[kind]):
			row_counts[kind] = int(row_counts[kind]) + 1
			rows.append("[%s] %-24s (%s) x%-3d pos=(%.0f,%.1f,%.0f) bottom=%+.2f ground=[%.2f..%.2f] gap=%+.2f sink=%d%%" % [
				kind.to_upper(), g, String(c["asset"]) if not String(c["asset"]).is_empty() else "-",
				int(c["members"]), float(c["center"].x), float(c["center"].y), float(c["center"].z),
				float(c["min_y"]), float(c["gmin"]), float(c["gmax"]),
				float(c["min_y"]) - float(c["gmin"]),
				int(round(100.0 * (float(c["gmax"]) - float(c["min_y"])) / maxf(float(c["height"]), 0.4)))])
	for kind in ["float", "tip", "sunk"]:
		if int(counts[kind]) > int(row_counts[kind]):
			var gc2: Dictionary = group_counts[kind]
			var top := []
			for g in gc2.keys():
				top.append("%s x%d" % [g, int(gc2[g])])
			rows.append("[%s] 其余 %d 处: %s" % [
				kind.to_upper(), int(counts[kind]) - int(row_counts[kind]), ", ".join(top)])

	# 互相穿模：空间哈希 → 包围盒重叠 → 顶点扎进对方分件包围盒的数量
	var xsec_n := 0
	var xsec_rows := 0
	for i in cands.size():
		var a: Dictionary = cands[i]
		if float(a["vol"]) < 0.6 or String(a["cat"]) in ["tree", "shrub"]:
			continue
		var ca := Vector2i(int(floor(float(a["center"].x) / cell)), int(floor(float(a["center"].z) / cell)))
		for dx in [-1, 0, 1]:
			for dz in [-1, 0, 1]:
				var key2: Vector2i = ca + Vector2i(dx, dz)
				if not grid.has(key2):
					continue
				for j_v in grid[key2]:
					var j := int(j_v)
					if j <= i:
						continue
					var b: Dictionary = cands[j]
					# 树冠/灌木是软轮廓：蹭到广告牌/灯柱不算穿模，两侧都跳
					if float(b["vol"]) < 0.6 \
							or String(b["cat"]) in ["tree", "shrub"] \
							or String(a["cat"]) in ["tree", "shrub"]:
						continue
					# 巨型网格（整张地形/远景山环）OBB 覆盖全世界，顶点对 OBB
					# 测试无意义；远景环撞名后会丢 "far" 名字漏过 skip 表
					if float(a["mx"].x) - float(a["mn"].x) > 1500.0 \
							or float(a["mx"].z) - float(a["mn"].z) > 1500.0 \
							or float(b["mx"].x) - float(b["mn"].x) > 1500.0 \
							or float(b["mx"].z) - float(b["mn"].z) > 1500.0:
						continue
					if String(b["key"]) == String(a["key"]):
						continue
					# 同资产实例对跳过：护栏段 6% 重叠是无缝拼接设计，同族岩石
					# 散点互相搭边也是常规造型，都不是要抓的穿模
					var aa := String(a["asset"])
					if not aa.is_empty() and aa == String(b["asset"]):
						continue
					# 城市/楼群相邻建筑贴着建是密度设计，不算穿模
					if String(a["cat"]) == "building" and String(b["cat"]) == "building":
						continue
					# 霓虹灯带从招牌 xform 派生挂底（设计即贴合），不算穿模
					var ga := String(a["group"])
					var gb := String(b["group"])
					if (ga.contains("CityNeonPanels") and gb.contains("CityNeonStrips")) \
							or (ga.contains("CityNeonStrips") and gb.contains("CityNeonPanels")):
						continue
					# 孤丘从熔岩湖里拔起是岩岛构图，不算穿模
					if (ga.contains("DesertButtes") and gb.contains("MagmaLake")) \
							or (ga.contains("MagmaLake") and gb.contains("DesertButtes")):
						continue
					# 岩石×岩石/孤丘互相搭边、石块嵌进丘体基座是石堆造型；
					# 砾石带贴着孤丘/巨石基座是碎石坡（砾石箱与基座底部在
					# 地面必然搭边），都不是要抓的穿模
					var fam_a := String(a["cat"]) == "rock" \
						or ga.contains("DesertButtes") or ga.contains("DesertBoulders") \
						or ga.contains("DesertMegaliths") or ga.contains("DesertGravel")
					var fam_b := String(b["cat"]) == "rock" \
						or gb.contains("DesertButtes") or gb.contains("DesertBoulders") \
						or gb.contains("DesertMegaliths") or gb.contains("DesertGravel")
					if fam_a and fam_b:
						continue
					if not _audit_boxes_overlap(a, b):
						continue
					# 垂直搭接太薄的「上下叠放」不算穿模：层叠段/底座/雨棚/桥架
					var oy := minf(float(a["max_y"]), float(b["max_y"])) \
						- maxf(float(a["min_y"]), float(b["min_y"]))
					if oy < 0.25 * minf(float(a["height"]), float(b["height"])):
						continue
					var pen := _audit_pair_penetration(a, b)
					if pen >= 10:
						xsec_n += 1
						if xsec_rows < (60 if OS.get_environment("AUDIT_DEBUG").length() > 0 else 12):
							xsec_rows += 1
							rows.append("[XSEC] %s × %s pen=%d pos=(%.0f,%.1f,%.0f)" % [
								String(a["group"]), String(b["group"]), pen,
								float(a["center"].x), float(a["center"].y), float(a["center"].z)])
						if OS.get_environment("AUDIT_DEBUG").length() > 0:
							var pa: Dictionary = (a["parts"] as Array)[0]
							var pb: Dictionary = (b["parts"] as Array)[0]
							var xa := pa["xf"] as Transform3D
							var xb := pb["xf"] as Transform3D
							rows.append("[DBG] A %s n=%d origin=(%.1f,%.1f,%.1f) sc=%.2f box=(%.1f,%.1f,%.1f) | B %s n=%d origin=(%.1f,%.1f,%.1f) sc=%.2f box=(%.1f,%.1f,%.1f)" % [
								String(a["group"]), int(a["members"]),
								xa.origin.x, xa.origin.y, xa.origin.z, xa.basis.get_scale().x,
								float(a["mx"].x) - float(a["mn"].x), float(a["mx"].y) - float(a["mn"].y), float(a["mx"].z) - float(a["mn"].z),
								String(b["group"]), int(b["members"]),
								xb.origin.x, xb.origin.y, xb.origin.z, xb.basis.get_scale().x,
								float(b["mx"].x) - float(b["mn"].x), float(b["mx"].y) - float(b["mn"].y), float(b["mx"].z) - float(b["mn"].z)])
	return {"objects": objects, "float": int(counts["float"]), "tip": int(counts["tip"]),
		"sunk": int(counts["sunk"]), "xsec": xsec_n, "rows": rows, "assets": asset_names}


## 往聚类里加一个实例分件（同一摆放的 surface 共享 key）。
func _audit_cluster_add(clusters: Dictionary, key: String, verts: PackedVector3Array,
		aabb: AABB, xf: Transform3D, group: String, asset: String, cat: String, idx: int) -> int:
	# 包围盒用网格 AABB 全 8 角精确变换：采样顶点（每面 ≤120 个）会跳过
	# 塔基等稀疏底缘，高层塔楼因此被误报悬空（bottom=+2.15 的假阳性）。
	var mn := Vector3(1e9, 1e9, 1e9)
	var mx := Vector3(-1e9, -1e9, -1e9)
	for cx in [aabb.position.x, aabb.end.x]:
		for cy in [aabb.position.y, aabb.end.y]:
			for cz in [aabb.position.z, aabb.end.z]:
				var w := xf * Vector3(cx, cy, cz)
				mn = mn.min(w)
				mx = mx.max(w)
	var height := maxf(mx.y - mn.y, 0.4)
	var center := (mn + mx) * 0.5
	var band_r := 0.0
	for v in verts:
		var w := xf * v
		if w.y <= mn.y + 0.15 * height:
			band_r = maxf(band_r, Vector2(w.x - center.x, w.z - center.z).length())
	# 局部空间包围盒 + 逆变换：穿模判定用定向盒，不用世界 AABB。
	# 盒体也用精确 AABB——采样顶点会漏掉极端点，盒偏小导致漏报。
	var part := {"xf": xf, "inv": xf.affine_inverse(), "verts": verts,
		"mn": mn, "mx": mx, "lmn": aabb.position, "lmx": aabb.end, "band_r": band_r,
		"vol": (mx.x - mn.x) * (mx.y - mn.y) * (mx.z - mn.z)}
	if clusters.has(key):
		var cl: Dictionary = clusters[key]
		cl["mn"] = (cl["mn"] as Vector3).min(mn)
		cl["mx"] = (cl["mx"] as Vector3).max(mx)
		cl["members"] = int(cl["members"]) + 1
		(cl["parts"] as Array).append(part)
		return 1
	clusters[key] = {
		"group": group, "asset": asset, "cat": cat, "idx": idx, "members": 1,
		"mn": mn, "mx": mx,
		"parts": [part],
	}
	return 1


## 悬空 / 尖点着地 / 掩埋过深 判定。sink_ratio = 掩埋量 / 物体高度。
func _audit_classify(c: Dictionary) -> String:
	# CityRing.glb 实景城市砖内子件：整砖一次性实例化、子件位置全美术定死，
	# 地下基础层（-1.7m）和高楼顶部构件（+50m）都是楼体本身，按子件判悬空
	# /掩埋没有意义；砖间穿模仍走 XSEC 判定
	if String(c["group"]).begins_with("City_"):
		return ""
	var cat := String(c["cat"])
	var height := maxf(float(c["height"]), 0.4)
	var gap := float(c["min_y"]) - float(c["gmin"])
	var sink_ratio := (float(c["gmax"]) - float(c["min_y"])) / height
	var fl := 0.55
	match cat:
		"rock":
			fl = 0.5
		"building":
			fl = 1.1
		"tree", "shrub":
			fl = 0.9
	# 陡坡散点：环内地面高差 > 2m 时，底部落在地面范围里就是坐在坡上
	# （低侧悬空/高侧埋住是坡地常态，棕榈/岩石散布全靠这条去伪）
	var slope := (float(c["gmax"]) - float(c["gmin"])) > 2.0
	# 嵌在山坡里的岩石：一侧悬空但过半埋住，属正常造型，不算悬空
	if gap > fl and sink_ratio < 0.55:
		if slope and float(c["min_y"]) <= float(c["gmax"]) + 0.35:
			pass
		else:
			return "float"
	# 平铺贴片（碎石滩/毛巾/路面装饰）高度不足，半埋是设计、sink 会被夸大
	if height < 0.6:
		return ""
	if sink_ratio > 0.75:
		if slope and float(c["min_y"]) >= float(c["gmin"]) - 0.2:
			pass
		else:
			return "sunk"
	if cat == "rock" and sink_ratio < 0.10 and height >= 0.6:
		var band_ratio := float(c["band_r"]) / maxf(float(c["radius"]), 0.3)
		if band_ratio < 0.24:
			return "tip"
	return ""


## 底下有没有别的构件托着（层叠段/杆上托架/杆顶雨棚）：查邻格里
## xz 盖住本物体、顶面恰好托住本底的候选；有支撑就不算悬空。
func _audit_has_support(c: Dictionary, cands: Array, grid: Dictionary, cell: float) -> bool:
	var ca := Vector2i(int(floor(float(c["center"].x) / cell)), int(floor(float(c["center"].z) / cell)))
	for dx in [-1, 0, 1]:
		for dz in [-1, 0, 1]:
			var key: Vector2i = ca + Vector2i(dx, dz)
			if not grid.has(key):
				continue
			for j_v in grid[key]:
				var o: Dictionary = cands[int(j_v)]
				if o == c:
					continue
				var oy := float(o["max_y"])
				var ob := float(o["min_y"])
				var bot := float(c["min_y"])
				if oy < bot - 0.45:
					continue  # 顶面够不到本底
				# 本物体底嵌在支撑体高度范围内（挂塔身的横条/杆顶横臂）也算支撑
				var embedded := ob <= bot + 0.45 and oy >= bot + 0.45
				if not embedded and oy > float(c["max_y"]) + 0.45:
					continue  # 只是旁边立着更高的物体，不是支撑
				var ex: float = maxf(0.6, 0.5 * float(o["radius"]))
				if float(c["center"].x) < float((o["mn"] as Vector3).x) - ex \
						or float(c["center"].x) > float((o["mx"] as Vector3).x) + ex \
						or float(c["center"].z) < float((o["mn"] as Vector3).z) - ex \
						or float(c["center"].z) > float((o["mx"] as Vector3).z) + ex:
					continue
				return true
	return false


func _audit_boxes_overlap(a: Dictionary, b: Dictionary) -> bool:
	var amn: Vector3 = a["mn"]
	var amx: Vector3 = a["mx"]
	var bmn: Vector3 = b["mn"]
	var bmx: Vector3 = b["mx"]
	return amx.x > bmn.x and amn.x < bmx.x \
		and amx.y > bmn.y and amn.y < bmx.y \
		and amx.z > bmn.z and amn.z < bmx.z


## 小物体顶点扎进大物体分件的「定向盒」（换到分件局部空间测）。
## 斜放建筑的轴对齐包围盒四角是空的，按世界 AABB 测全是假阳性。
func _audit_pair_penetration(a: Dictionary, b: Dictionary) -> int:
	var src: Dictionary = a if float(a["vol"]) <= float(b["vol"]) else b
	var dst: Dictionary = b if src == a else a
	var boxes: Array = dst["parts"]
	var cnt := 0
	for p_v in src["parts"]:
		var p: Dictionary = p_v
		var xf: Transform3D = p["xf"]
		var verts: PackedVector3Array = p["verts"]
		for v in verts:
			var w := xf * v
			for bx_v in boxes:
				var bx: Dictionary = bx_v
				var lv := (bx["inv"] as Transform3D) * w
				var lmn: Vector3 = bx["lmn"]
				var lmx: Vector3 = bx["lmx"]
				# 严格盒内判定：真穿透的顶点本来就在盒内，外扩容差只会把
				# 贴墙件（门窗 0.01m 安装缝）误判成穿模
				if lv.x > lmn.x and lv.x < lmx.x \
						and lv.y > lmn.y and lv.y < lmx.y \
						and lv.z > lmn.z and lv.z < lmx.z:
					# 盒角是空的（切角/L 形足迹）：扎点在实测顶点半径之外，
					# 只是扎进了网格 AABB 的空盒角，不是真穿插
					if Vector2(w.x - float(dst["center"].x), w.z - float(dst["center"].z)).length() \
							> float(dst["vert_r"]) + 0.1:
						continue
					# 贴在对方顶面上的支撑接触（AC 机组坐退台顶、塔身坐裙楼顶、
					# 雪层贴坡屋顶）不算穿模。贴面带在分件局部空间量：斜屋顶的
					# 贴合面是斜的，世界 Y 带罩不到下坡端的贴面顶点
					var band_scale: float = maxf((bx["xf"] as Transform3D).basis.get_scale().x, 0.001)
					if lv.y >= lmx.y - 0.30 / band_scale and lv.y <= lmx.y + 0.60 / band_scale:
						continue
					cnt += 1
					break
	return cnt


## 资产模板包围盒：原点到底面的距离占比（0%=原点在底面，50%=原点在中心）。
func _audit_asset_bounds(asset: String) -> AABB:
	var box := AABB()
	var first := true
	for part in RealAssetKit.surfaces(asset):
		var ab: AABB = (part["rel"] as Transform3D) * (part["mesh"] as Mesh).get_aabb()
		if first:
			box = ab
			first = false
		else:
			box = box.merge(ab)
	return box

## 把现场生成的场景装饰烘焙成 data/decor/<track>.json。
##
## 场景装饰原本是固定随机种子现场撒出来的，代码里没有「某一棵树」这种身份，
## 编辑器也就选不中它。烘焙之后每个装饰都有稳定的 (资产, 位置, 朝向, 缩放)，
## 才能被编辑器读出来、选中、移动、保存。草不参与（两万个，手改无意义）。
func _run_bake_decor() -> void:
	var track_id := _track_or_default()
	var def := GameData.track(track_id)
	if def.is_empty():
		push_error("bake-decor: unknown track '%s'" % track_id)
		get_tree().quit(1)
		return
	var path := TrackPath.new()
	path.build_from_def(def, 2.0)
	var holder := Node3D.new()
	holder.name = "DecorBake"
	add_child(holder)

	RealAssetKit.capture_begin()
	SceneryKit.build(holder, path, def)
	VenueKit.build(holder, path, def, def.get("theme", {}))
	var items := RealAssetKit.capture_end()

	# 诊断：看看场景里还有多少 MultiMesh 没被采集到，以及能否从 mesh 反推资产名
	var seen := 0
	for mmi_node in holder.find_children("*", "MultiMeshInstance3D", true, false):
		var mmi2 := mmi_node as MultiMeshInstance3D
		if mmi2 == null or mmi2.multimesh == null or mmi2.multimesh.mesh == null:
			continue
		seen += int(mmi2.multimesh.instance_count)
		if seen < 999999:
			var mp := mmi2.multimesh.mesh.resource_path
			if seen < 40:
				print("[BAKE-DIAG] %-26s inst=%-5d mesh_path='%s'" % [
					String(mmi2.name), mmi2.multimesh.instance_count, mp])
	print("[BAKE-DIAG] 场景中 MultiMesh 实例总数=", seen, " 采集到=", items.size())

	# 按类别汇总，便于核对数量
	var by_cat := {}
	for it in items:
		var c := String(it["cat"])
		by_cat[c] = int(by_cat.get(c, 0)) + 1

	var out: Array = []
	for it in items:
		var xf: Transform3D = it["xf"]
		var q := xf.basis.get_rotation_quaternion()
		var s := xf.basis.get_scale()
		out.append({
			"asset": String(it["asset"]),
			"cat": String(it["cat"]),
			"p": [snappedf(xf.origin.x, 0.01), snappedf(xf.origin.y, 0.01), snappedf(xf.origin.z, 0.01)],
			"q": [snappedf(q.x, 0.0001), snappedf(q.y, 0.0001), snappedf(q.z, 0.0001), snappedf(q.w, 0.0001)],
			"s": [snappedf(s.x, 0.0001), snappedf(s.y, 0.0001), snappedf(s.z, 0.0001)],
		})

	var doc := {
		"track": track_id,
		"count": out.size(),
		"categories": by_cat,
		"items": out,
	}
	var dir := "res://data/decor"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var target := "%s/%s.json" % [dir, track_id]
	var f := FileAccess.open(target, FileAccess.WRITE)
	if f == null:
		push_error("bake-decor: cannot write %s" % target)
		get_tree().quit(1)
		return
	f.store_string(JSON.stringify(doc, "  "))
	f.close()
	print("[BAKE] %s -> %s  (%d items)" % [track_id, target, out.size()])
	print("[BAKE] categories=", by_cat)
	get_tree().quit(0)


func _run_audio_test() -> void:
	await get_tree().process_frame
	audio = AudioManager.new()
	audio.name = "Audio"
	add_child(audio)
	print("[AUDIO] bgm entries=%d" % GameData.bgm.size())
	audio.play_menu_bgm()
	audio.start_engine()
	audio.update_engine(0.6, 1.0, 0.4, 3)
	await get_tree().create_timer(0.8).timeout
	var menu_ok := audio.current_bgm == "apex" and audio.engine != null
	print("[AUDIO] menu bgm='%s' playing=%s engine=%s" % [
		audio.current_bgm, str(audio.bgm_player.playing), str(audio.engine != null)])
	for track_def in GameData.tracks:
		var track_id := String(track_def.get("id", ""))
		audio.play_race_bgm(track_id)
		await get_tree().create_timer(0.05).timeout
		print("[AUDIO] %-8s -> %s" % [track_id, audio.current_bgm])
	var pass_test := menu_ok and audio.bgm_player.stream != null
	print("[AUDIO] " + ("PASS" if pass_test else "FAIL"))
	get_tree().quit(0 if pass_test else 2)


func _count_meshes(node: Node) -> int:
	var count := 1 if (node is MeshInstance3D or node is MultiMeshInstance3D) else 0
	for child in node.get_children():
		count += _count_meshes(child)
	return count


# ---------------------------------------------------------------------------
# screenshot mode
# ---------------------------------------------------------------------------

func _enter_backdrop_mode() -> void:
	if track_path == null or track_path.samples.is_empty():
		return
	# 选曲率最大的弯作为每张地图 key art 的构图点
	var hero_index := 0
	var hero_curv := 0.0
	for i in range(20, track_path.samples.size() - 20):
		var c := absf(track_path.curvatures[i])
		if c > hero_curv:
			hero_curv = c
			hero_index = i
	var dist := track_path.accumulated[hero_index]
	var frame := track_path.frame_at(dist)
	if frame.is_empty():
		return
	var pos: Vector3 = frame["pos"]
	var tangent: Vector3 = frame["tangent"]
	var side: Vector3 = frame["side"]
	var half := track_path.half_width
	if car != null:
		car.visible = false
	for ai in ais:
		if ai != null:
			ai.visible = false
	if hud != null:
		hud.visible = false
	if cam != null:
		cam.set_process(false)
		cam.set_physics_process(false)
	var outward := side * signf(float(track_path.curvatures[hero_index]))
	if outward.length() < 0.1:
		outward = side
	_backdrop_cam = Camera3D.new()
	_backdrop_cam.name = "BackdropCamera"
	_backdrop_cam.fov = 52.0
	var attrs := CameraAttributesPractical.new()
	attrs.dof_blur_far_enabled = true
	attrs.dof_blur_far_distance = 26.0
	attrs.dof_blur_far_transition = 24.0
	attrs.dof_blur_amount = 0.18
	_backdrop_cam.attributes = attrs
	add_child(_backdrop_cam)
	# 机位放在进弯前的路面上、贴近地面：前景左下是沥青，弯道和景色在右/中景，
	# 这样车可以放在左下角，透视和背景对得上，不会像贴图。
	var cam_pos := pos - tangent * 16.0 + side * half * 0.35 + Vector3(0.0, 1.45, 0.0)
	_backdrop_cam.global_position = cam_pos
	_backdrop_cam.look_at(pos + tangent * 9.0 + Vector3(0.0, 1.15, 0.0), Vector3.UP)
	_backdrop_cam.current = true
	if streamer != null:
		streamer.setup(_backdrop_cam, race_root)


func _grab_screenshot() -> void:
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var err := image.save_png(shot_path)
	print("[SHOT] %s (err=%d, %dx%d)" % [shot_path, err, image.get_width(), image.get_height()])
	_clear_race()
	await get_tree().process_frame
	get_tree().quit(0 if err == OK else 1)


# ---------------------------------------------------------------------------
# trailer capture · 宣传片逐帧拍摄
#
#   --movie-dir=/abs/dir      每帧输出 f_00001.jpg ...（真实渲染帧，非合成）
#   --movie-frames=N          渲染 N 帧后退出
#   --movie-skip=M            前 M 帧不落盘（用于跳过发车倒数/加载）
#   --trailer-shot=<preset>   每帧重摆机位：hero/lead/side/aerial/chase/wheel
#   --trailer-hud=0|1         隐藏/显示比赛 HUD
#
# 只影响 --shot 拍摄进程；常规启动完全不走这段逻辑。
# ---------------------------------------------------------------------------

func _capture_movie_frame(idx: int) -> void:
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	if image != null and not image.is_empty():
		image.save_jpg("%s/f_%05d.jpg" % [_movie_dir, idx], 0.93)
	_movie_busy = false


## 每帧按车所在的赛道坐标重摆相机，禁用追尾相机的自动跟随。
## 发车阶段保留游戏自带的开场电影机位（intro_cam），倒数结束才接管。
func _update_trailer_camera() -> void:
	if intro_cam != null:
		return
	if cam == null or car == null or track_path == null:
		return
	if cam.is_processing():
		cam.set_process(false)
		cam.set_physics_process(false)
	cam.current = true
	if hud != null and _trailer_hud >= 0:
		hud.visible = (_trailer_hud == 1)
	var f := track_path.frame_at(car.progress_dist)
	if f.is_empty():
		return
	var tan: Vector3 = f["tangent"]
	var side: Vector3 = f["side"]
	var cp: Vector3 = car.pos
	var cam_pos := cp
	var look_pt := cp + Vector3(0.0, 1.0, 0.0)
	match _trailer_shot:
		"hero":    # 低侧后 3/4：车侧身 + 前方赛道与天际线
			cam_pos = cp - tan * 8.5 + side * 5.0 + Vector3(0.0, 1.7, 0.0)
			look_pt = cp + tan * 5.0 + Vector3(0.0, 1.0, 0.0)
		"lead":    # 迎面 3/4 低机位：车头朝镜头，背景快速流动
			cam_pos = cp + tan * 13.0 + side * 2.8 + Vector3(0.0, 1.05, 0.0)
			look_pt = cp + tan * 1.5 + Vector3(0.0, 0.80, 0.0)
		"side":    # 正侧平移：车身与横向流动的景观
			cam_pos = cp + side * 11.0 + tan * 1.0 + Vector3(0.0, 2.1, 0.0)
			look_pt = cp + Vector3(0.0, 0.9, 0.0)
		"aerial":  # 高处俯瞰：赛道线形 + 周围地貌
			cam_pos = cp - tan * 26.0 + Vector3(0.0, 20.0, 0.0)
			look_pt = cp + tan * 26.0 + Vector3(0.0, 0.5, 0.0)
		"chase":   # 贴地追尾：车尾 + 长直道
			cam_pos = cp - tan * 8.0 + Vector3(0.0, 2.6, 0.0)
			look_pt = cp + tan * 14.0 + Vector3(0.0, 1.2, 0.0)
		"wheel":   # 贴地轮组特写
			cam_pos = cp + side * 3.2 - tan * 1.5 + Vector3(0.0, 0.55, 0.0)
			look_pt = cp + tan * 4.0 + Vector3(0.0, 0.7, 0.0)
		"cockpit": # 驾驶位主观视角：隐藏本车模型，只看路面、对手与 HUD
			if car.visible:
				car.visible = false
			cam_pos = cp + tan * 0.35 + Vector3(0.0, 1.18, 0.0)
			look_pt = cp + tan * 45.0 + Vector3(0.0, 1.05, 0.0)
		_:
			return
	cam.fov = 76.0 if _trailer_shot == "cockpit" else (58.0 if _trailer_shot == "aerial" else 62.0)
	cam.global_position = cam_pos
	cam.look_at(look_pt, Vector3.UP)
