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
const PhotoModeScript := preload("res://scripts/ui/photo_mode.gd")
const TutorialScript := preload("res://scripts/ui/tutorial_overlay.gd")

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
var _sun_glare: Node3D
var _theme_ssr_allowed := true
var _theme_sdfgi_allowed := false
var _volumetric_allowed := false
var settings_screen: SettingsScreen
var streamer
var _last_blur_amount := 0.0
var _post_grade: Dictionary = {}
var _post_grade_active := false
var _post_vignette := 0.0
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
var skid_marks: SkidMarks
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
var _race_pos_prev := 0
var _overtake_cd := 0.0
var _launch_armed := false
var _prev_race_state := -1
var _last_player_laps := 0
var _lap_wall_hits := 0
var _lap_offroad := 0.0
var _clean_laps := 0
var _hud_acc := 0.0
var _ai_acc := 0.0
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
var cone_field: ConeField = null
var cone_editor: ConeEditor = null
var _cone_knocked := 0
var photo_mode: Node
var tutorial: CanvasLayer = null
var _tutorial_session := false
var _tutorial_test_mode := false
var _tut_unstick := 0.0
var _tut_last_step := -1
## 验收第三程（逆向弹窗）输入接管：0 关闭 1 前进越线 2 倒车 3 恢复前进。
var _tut_phase3 := 0
var menu_car_pivot: Node3D
var menu_car_model: Node3D
var menu_cam: Camera3D
var menu_time := 0.0
var menu_car_angle := 0.0
var menu_dragging := false
var _menu_stick_active := false
var _menu_kicker: SpotLight3D
var _menu_sweep_t := 0.0
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
var _perf_render_cpu: Array[float] = []
var _perf_render_gpu: Array[float] = []
var _perf_sample_timer := 0.0
var _perf_measure_on := false
# 动态分辨率守门员与车辆碰撞解算：逻辑已拆到独立类，这里只持引用。
var governor := PerfGovernor.new()
var contacts := CarContacts.new()
# 进赛卡顿诊断：APEX_LOAD_LOG=1 时打印分阶段耗时与入场后长帧。
var _hitch_log_until := 0
var _hitch_log_start := 0
var _frame_log_on := false
var _frame_log_start := 0
var _frame_log_intro: Array[float] = []
var _frame_log_race: Array[float] = []
var _results_shown := false

var verify_mode := false
var shot_mode := false
var shot_path := ""
var shot_scene := "race"
var _shot_frames := 0
var _backdrop_cam: Camera3D
var _shot_dist := 0.0
var _shot_reset_applied := false
var _shot_delay := 0.0
var _shot_wall := 0.0
var _shot_results_done := false
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
## 启动探针：--drive-probe=<秒> 时倒计时结束后自动全油门行驶并打印遥测，
## 用于复现「某张图起步异常」这类只能在真实比赛流程里出现的问题。
var _drive_probe_time := -1.0
var _drive_probe_elapsed := 0.0
var _drive_probe_log := 0.0
var _ai_probe := {"n": 0, "gap_sum": 0.0, "gap_min": 9999.0, "close": 0, "cluster": 0,
	"spread_sum": 0.0, "along_sum": 0.0, "along_close": 0}
var _ai_probe_t := 0.0


# --- 城市实景（都会环线）-----------------------------------------------------
## 真实城市模型没有引擎碰撞体：建筑掩体由离线烘焙的 SDF 提供，
## 车可以开进任意街道，只有房屋是实体。
var _city_world: Node = null
const CityWorldScript := preload("res://maps/scripts/openworld/city_world.gd")
const CityFacadesScript := preload("res://maps/scripts/openworld/city_facades.gd")
const SunGlareScript := preload("res://scripts/fx/sun_glare.gd")


func _ready() -> void:
	streamer = FrustumStreamer.new()
	streamer.name = "FrustumStreamer"
	add_child(streamer)
	# 太阳/月亮眩光：常驻一个实例，按菜单/赛道主题切方向与强度。
	_sun_glare = SunGlareScript.new()
	_sun_glare.name = "SunGlare"
	add_child(_sun_glare)
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
	governor.setup(self)
	contacts.setup(self)
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
			if OS.get_environment("APEX_PERF_FULLSCREEN") == "1":
				win.mode = Window.MODE_FULLSCREEN
			else:
				win.mode = Window.MODE_WINDOWED
				win.borderless = false
				var win_size := Vector2i(1600, 900)
				if OS.get_environment("APEX_PERF_W").is_valid_int() and OS.get_environment("APEX_PERF_H").is_valid_int():
					win_size = Vector2i(int(OS.get_environment("APEX_PERF_W")), int(OS.get_environment("APEX_PERF_H")))
				win.size = win_size
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
	var bake_menu_arg := ""
	for a in OS.get_cmdline_user_args():
		if a == "--bake-menu" or a.begins_with("--bake-menu="):
			bake_menu_arg = a
			break
	if not bake_menu_arg.is_empty():
		_run_bake_menu(bake_menu_arg.get_slice("=", 1) if "=" in bake_menu_arg else "")
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
	if "--tutorial" in OS.get_cmdline_user_args():
		_start_tutorial()
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
		elif shot_scene == "settings" or shot_scene == "settings-controls" \
				or shot_scene == "settings-game":
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
	if "--tutorial-test" in OS.get_cmdline_user_args():
		_run_tutorial_test()


## ACE68 磁轴键盘桥：游戏启动时自动拉起（macOS 且 exe 存在时），退出时杀掉并还原键盘开关。
## 关掉「设置→操作→模拟输入」即不会再自动启动；也可以手动跑
## tools/analog_input/ace68/ace68_macos --stream 后游戏会复用。
func _maybe_start_ace68_bridge() -> void:
	if OS.get_name() != "macOS":
		return
	if verify_mode or shot_mode or _perf_mode:
		return
	for flag in ["--bake-menu", "--scenery-debug", "--bake-decor", "--audio-test"]:
		for a in OS.get_cmdline_user_args():
			if a == flag or a.begins_with(flag + "="):
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
	# 自动化测试不等开场影片（无窗口焦点时视频会暂停，测试会一直吊住）；
	# 但 TUT_FRESH 沙箱轮要验首次自动触发，必须走完整 boot → _on_boot_finished 链路。
	var skip_boot := _drift_test_mode or "--menu-nav-test" in OS.get_cmdline_user_args() \
		or "--race-test" in OS.get_cmdline_user_args() \
		or ("--tutorial-test" in OS.get_cmdline_user_args() \
			and OS.get_environment("TUT_FRESH") != "1")
	if skip_boot:
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


## 新手教程全流程验收：--tutorial-test。脚本按当前任务项驾驶，
## 依次触发 8 项判定 → 冲线 → 毕业条 → 返回菜单，截图留档并断言。
## 测试会写档案/纪录/幽灵，开跑前备份、退出前原样恢复，不污染玩家进度。
## 环境变量 TUT_FRESH=1（配合沙箱 HOME）时清空存档，改验首次自动触发与奖励发放。
func _run_tutorial_test() -> void:
	var ps := ProfileStore
	var fresh := OS.get_environment("TUT_FRESH") == "1"
	var shot_prefix := "/tmp/tutorial_fresh" if fresh else "/tmp/tutorial"
	_tut_log("[TUTORIAL-TEST] harness begin fresh=%s" % fresh)
	if fresh:
		# 沙箱 HOME + 清空存档：验证首次进入自动触发与毕业奖励发放。
		_tut_backup_saves()
		_tut_wipe_saves()
		var auto_deadline := Time.get_ticks_msec() + 240000
		while not _tutorial_session and Time.get_ticks_msec() < auto_deadline:
			await get_tree().process_frame
		_tut_log("[TUTORIAL-TEST] fresh profile auto start=%s" % _tutorial_session)
		if not _tutorial_session:
			_tut_restore_saves()
			_tut_log("[TUTORIAL-TEST] -> FAIL")
			get_tree().quit(1)
			return
	else:
		while menu == null:
			await get_tree().process_frame
		await get_tree().create_timer(1.0).timeout
		_tut_backup_saves()
		_tut_log("[TUTORIAL-TEST] start tutorial from menu")
		_start_tutorial()
	var ready_deadline := Time.get_ticks_msec() + 90000
	while (race == null or car == null or tutorial == null or loading_screen != null) \
			and Time.get_ticks_msec() < ready_deadline:
		await get_tree().process_frame
	_tut_log("[TUTORIAL-TEST] ready: race=%s car=%s tutorial=%s loading=%s" % [
		race != null, car != null, tutorial != null, loading_screen != null])
	if race == null or car == null or tutorial == null or loading_screen != null:
		_tut_restore_saves()
		_tut_log("[TUTORIAL-TEST] -> FAIL (race not ready)")
		get_tree().quit(1)
		return
	await get_tree().create_timer(0.8).timeout
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	if img != null:
		img.save_png("%s_welcome.png" % shot_prefix)
	race.countdown = 0.0
	race.state = RaceManager.State.RACING
	race.race_time = 0.0
	_tutorial_test_mode = true
	var deadline := Time.get_ticks_msec() + 300000
	var last_step := -1
	var cam_switched := false
	var drift_shot := false
	var keys_shot := false
	var stuck_t := 0.0
	var reset_count := 0
	while Time.get_ticks_msec() < deadline:
		await get_tree().physics_frame
		if tutorial == null or race == null or car == null:
			break
		var step: int = tutorial.step_index()
		if step != last_step:
			_tut_log("[TUTORIAL-TEST] enter step %d  t=%.1f  speed=%.0f" % [
				step, race.race_time, car.speed_kph])
			last_step = step
		if step == 6 and not cam_switched:
			cam_switched = true
			var ev := InputEventKey.new()
			ev.keycode = KEY_C
			ev.physical_keycode = KEY_C
			ev.pressed = true
			Input.parse_input_event(ev)
			var ev_up := InputEventKey.new()
			ev_up.keycode = KEY_C
			ev_up.physical_keycode = KEY_C
			ev_up.pressed = false
			Input.parse_input_event(ev_up)
		if _tut_phase3 == 0 and step >= 1 and race.state == RaceManager.State.RACING \
				and car.speed_kph < 8.0:
			stuck_t += get_physics_process_delta_time()
		else:
			stuck_t = 0.0
		if stuck_t > 1.5 and reset_count < 8:
			reset_count += 1
			stuck_t = 0.0
			_tut_unstick = 1.1
			_tut_log("[TUTORIAL-TEST] stuck recovery: reverse #%d at step %d" % [reset_count, step])
		if not keys_shot and step == 0 and tutorial._key_grid != null and tutorial._key_grid.visible:
			keys_shot = true
			await RenderingServer.frame_post_draw
			var key_img := get_viewport().get_texture().get_image()
			if key_img != null:
				key_img.save_png("%s_keys.png" % shot_prefix)
			_tut_log("[TUTORIAL-TEST] keys grid captured")
		if not drift_shot and ((step == 4 and car.drift_active and car.speed_kph > 40.0) or step > 4):
			drift_shot = true
			await get_tree().create_timer(0.5).timeout
			await RenderingServer.frame_post_draw
			var shot := get_viewport().get_texture().get_image()
			if shot != null:
				shot.save_png("%s_drift.png" % shot_prefix)
		if tutorial.is_graduated():
			break
	await get_tree().create_timer(0.6).timeout
	await RenderingServer.frame_post_draw
	var lap_img := get_viewport().get_texture().get_image()
	if lap_img != null:
		lap_img.save_png("%s_lapcard.png" % shot_prefix)
	var lap_card_ok := hud != null and hud.lap_card_shown()
	_tut_log("[TUTORIAL-TEST] lap card shown=%s keys grid=%s" % [lap_card_ok, keys_shot])
	while race != null and race.state != RaceManager.State.RESULTS \
			and Time.get_ticks_msec() < deadline:
		await get_tree().physics_frame
	await get_tree().create_timer(1.6).timeout
	await RenderingServer.frame_post_draw
	img = get_viewport().get_texture().get_image()
	if img != null:
		img.save_png("%s_graduated.png" % shot_prefix)
	var ok: bool = tutorial != null and tutorial.is_graduated() \
		and race != null and race.state == RaceManager.State.RESULTS
	ok = ok and lap_card_ok
	ok = ok and keys_shot
	var profile_done := String(ps.load_profile().get("tutorial", "")) == "done"
	var grad_text := String(tutorial._grad_sub.text) if tutorial != null else ""
	_tut_log("[TUTORIAL-TEST] graduated=%s results=%s profile_done=%s" % [
		tutorial != null and tutorial.is_graduated(),
		race != null and race.state == RaceManager.State.RESULTS, profile_done])
	_tut_log("[TUTORIAL-TEST] grad sub: %s" % grad_text)
	ok = ok and profile_done
	if fresh:
		var xp_ok: bool = int(ps.load_profile().get("xp", 0)) >= ps.XP_TUTORIAL \
			and grad_text.contains("已入账")
		_tut_log("[TUTORIAL-TEST] fresh xp grant ok=%s" % xp_ok)
		ok = ok and xp_ok
	if ok:
		tutorial._grad_menu_btn.pressed.emit()
		await get_tree().create_timer(1.2).timeout
		ok = state == AppState.MENU and tutorial == null
		_tut_log("[TUTORIAL-TEST] back to menu clean=%s" % ok)
		await RenderingServer.frame_post_draw
		img = get_viewport().get_texture().get_image()
		if img != null:
			img.save_png("%s_menu.png" % shot_prefix)
	# 第二程：主菜单 N 键重学入口 + 暂停重开保留进度 + 中途跳过（跳过后比赛继续、浮层卸载）
	if ok:
		var ev_n := InputEventKey.new()
		ev_n.keycode = KEY_N
		ev_n.physical_keycode = KEY_N
		ev_n.pressed = true
		Input.parse_input_event(ev_n)
		var ev_n_up := InputEventKey.new()
		ev_n_up.keycode = KEY_N
		ev_n_up.physical_keycode = KEY_N
		ev_n_up.pressed = false
		Input.parse_input_event(ev_n_up)
		var entry_deadline := Time.get_ticks_msec() + 30000
		while (tutorial == null or race == null) and Time.get_ticks_msec() < entry_deadline:
			await get_tree().process_frame
		var skip_ok := tutorial != null and _tutorial_session
		_tut_log("[TUTORIAL-TEST] phase2 entry=%s session=%s" % [tutorial != null, _tutorial_session])
		if skip_ok:
			# 暂停面板「重新开始」会重 bind 浮层：同一浮层实例、进度不回退、HUD 换新。
			# 等待期间脚本驾驶会合法推进任务，故只要求 step 不回退而非相等。
			var step_before: int = tutorial.step_index()
			var tut_before := tutorial
			var hud_before := hud
			_on_pause_restart()
			await get_tree().create_timer(4.0).timeout
			skip_ok = tutorial != null and tutorial == tut_before and _tutorial_session \
				and tutorial.step_index() >= step_before \
				and hud != null and hud != hud_before and state == AppState.RACE
			_tut_log("[TUTORIAL-TEST] phase2 pause-restart keeps overlay=%s (step %d->%d hud_new=%s racing=%s)" % [
				skip_ok, step_before, tutorial.step_index() if tutorial != null else -1,
				hud != hud_before, state == AppState.RACE])
		if skip_ok:
			await get_tree().create_timer(0.4).timeout
			tutorial._skip_btn.pressed.emit()
			await get_tree().create_timer(0.5).timeout
			skip_ok = skip_ok and tutorial == null and not _tutorial_session \
				and state == AppState.RACE \
				and String(ps.load_profile().get("tutorial", "")) == "skipped"
			_tut_log("[TUTORIAL-TEST] phase2 after skip: overlay=%s session=%s state=%s profile=%s" % [
				tutorial == null, not _tutorial_session, state == AppState.RACE,
				String(ps.load_profile().get("tutorial", ""))])
		_tut_log("[TUTORIAL-TEST] menu N entry + skip ok=%s" % skip_ok)
		ok = ok and skip_ok
	# 第三程：逆向全屏弹窗。先前进取越起跑线开始计时，再倒车触发警告，
	# 截图留档后恢复前进，验证警告自动清除。
	if ok:
		_tut_phase3 = 1
		var p3_deadline := Time.get_ticks_msec() + 30000
		while race != null and not race.race_started and Time.get_ticks_msec() < p3_deadline:
			await get_tree().physics_frame
		var started_ok := race != null and race.race_started
		_tut_log("[TUTORIAL-TEST] phase3 race_started=%s" % started_ok)
		if started_ok:
			_tut_phase3 = 2
			var ww_deadline := Time.get_ticks_msec() + 20000
			while race != null and not race.wrong_way and Time.get_ticks_msec() < ww_deadline:
				await get_tree().physics_frame
			await get_tree().create_timer(0.6).timeout
			await RenderingServer.frame_post_draw
			var ww_img := get_viewport().get_texture().get_image()
			if ww_img != null:
				ww_img.save_png("%s_wrongway.png" % shot_prefix)
			var ww_ok := race != null and race.wrong_way and hud != null and hud.wrong_way_shown()
			_tut_log("[TUTORIAL-TEST] phase3 wrong_way=%s overlay=%s" % [
				race != null and race.wrong_way, hud != null and hud.wrong_way_shown()])
			_tut_phase3 = 3
			var clear_deadline := Time.get_ticks_msec() + 20000
			while race != null and race.wrong_way and Time.get_ticks_msec() < clear_deadline:
				await get_tree().physics_frame
			await get_tree().create_timer(0.5).timeout
			var cleared := race != null and not race.wrong_way \
				and hud != null and not hud.wrong_way_shown()
			_tut_log("[TUTORIAL-TEST] phase3 cleared=%s" % cleared)
			ok = ok and ww_ok and cleared
		else:
			ok = false
		_tut_phase3 = 0
	_tut_restore_saves()
	_tut_log("[TUTORIAL-TEST] -> %s" % ("PASS" if ok else "FAIL"))
	get_tree().quit(0 if ok else 1)


## 教程验收的脚本驾驶：按任务项给输入，其余交给赛道自动驾驶。
func _tutorial_test_input() -> Dictionary:
	if _tut_phase3 == 2:
		return {"throttle": -1.0, "steer": 0.0, "handbrake": false, "nitro": false}
	if _tut_phase3 == 1 or _tut_phase3 == 3:
		return {"throttle": 1.0, "steer": 0.0, "handbrake": false, "nitro": false}
	if _tut_unstick > 0.0:
		_tut_unstick -= get_physics_process_delta_time()
		return {"throttle": -1.0, "steer": 0.0, "handbrake": false, "nitro": false}
	var input := _autopilot_input()
	var step: int = tutorial.step_index() if tutorial != null else 99
	if step != _tut_last_step:
		_tut_last_step = step
	input["nitro"] = false
	input["handbrake"] = false
	match step:
		0:
			input["throttle"] = 0.0
		1:
			input["throttle"] = 1.0
		2:
			input["throttle"] = maxf(float(input.get("throttle", 0.5)), 0.55)
			var phase := fmod(race.race_time if race != null else 0.0, 2.4)
			input["steer"] = clampf(float(input.get("steer", 0.0)) \
				+ (0.45 if phase < 1.2 else -0.45), -1.0, 1.0)
		3:
			if car.speed_kph > 60.0:
				input["throttle"] = -1.0
			else:
				input["throttle"] = 0.3
		4:
			input["throttle"] = 1.0
			if car.speed_kph > 35.0:
				input["handbrake"] = true
				var phase4 := fmod(race.race_time if race != null else 0.0, 2.4)
				input["steer"] = clampf(float(input.get("steer", 0.0)) \
					+ (0.5 if phase4 < 1.2 else -0.5), -1.0, 1.0)
			else:
				input["handbrake"] = false
		5:
			input["throttle"] = maxf(float(input.get("throttle", 0.5)), 0.85)
			input["nitro"] = true
		6:
			input["throttle"] = maxf(float(input.get("throttle", 0.5)), 0.6)
		_:
			input["throttle"] = 1.0
	return input


var _tut_save_backup: Dictionary = {}


## 验收日志即时落盘：重定向到文件时 stdout 有缓冲，stderr 无缓冲，卡住也能看到最后一步。
func _tut_log(msg: String) -> void:
	printerr(msg)


func _tut_backup_saves() -> void:
	var car_id := menu.selected_car_id() if menu != null else DEFAULT_CAR
	var paths := ["user://profile.json", "user://records.json", "user://settings.json",
		"user://ghost_best_coast.json", "user://ghost_coast_%s.json" % car_id]
	# .bak 一并备份/清空：否则 SafeJson 会从旧备份恢复出已毕业的存档。
	for base in paths:
		for p in [base, base + ".bak"]:
			if FileAccess.file_exists(p):
				var f := FileAccess.open(p, FileAccess.READ)
				if f != null:
					_tut_save_backup[p] = f.get_as_text()
					f.close()
			else:
				_tut_save_backup[p] = null


func _tut_wipe_saves() -> void:
	for p in _tut_save_backup:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)


func _tut_restore_saves() -> void:
	for p in _tut_save_backup:
		var text = _tut_save_backup[p]
		if text == null:
			if FileAccess.file_exists(p):
				DirAccess.remove_absolute(p)
		else:
			var f := FileAccess.open(p, FileAccess.WRITE)
			if f != null:
				f.store_string(String(text))
				f.close()
	_tut_save_backup.clear()


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
	_maybe_auto_tutorial()


## 首次进入游戏（全新档案且没跑过任何比赛）自动开跑新手教程；
## 跳过或毕业后不再自动触发，主菜单「新手教程」入口可随时重学。
func _maybe_auto_tutorial() -> void:
	if shot_mode or verify_mode or _perf_mode:
		return
	var ps := ProfileStore
	var profile: Dictionary = ps.load_profile()
	if String(profile.get("tutorial", "")) == "" and int(profile.get("races", 0)) == 0:
		print("[TUTORIAL] fresh profile -> auto start")
		_start_tutorial()


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
	if _hitch_log_until > 0:
		var now_ms := Time.get_ticks_msec()
		if now_ms < _hitch_log_until:
			if dt > 0.045:
				print("[HITCH] %.0f ms  t=%.2f  state=%d" % [
					dt * 1000.0, float(now_ms - _hitch_log_start) / 1000.0, state])
		else:
			_hitch_log_until = 0
	if _frame_log_on:
		if race != null and race.state == RaceManager.State.RACING:
			_frame_log_race.append(dt)
		else:
			_frame_log_intro.append(dt)
		if Time.get_ticks_msec() - _frame_log_start >= 15000:
			_frame_log_on = false
			_print_frame_stats()
	if intro_cam != null and race != null:
		intro_t += dt
		var k := clampf(intro_t / 3.0, 0.0, 1.0)
		var e := k * k * (3.0 - 2.0 * k)
		intro_cam.global_position = intro_from_pos.lerp(intro_to_pos, e)
		intro_cam.look_at(intro_from_look.lerp(intro_to_look, e), Vector3.UP)
		# 亮度锁定：开场不再压暗/恢复泛光。整屏泛光糊白的问题改由太阳眩光
		# 收窄全屏薄雾解决（sun_glare.gd），泛光强度全程保持主题锁定值。
		if k >= 1.0 or race.state != RaceManager.State.COUNTDOWN:
			intro_cam.queue_free()
			intro_cam = null
			if cam != null:
				cam.current = true
				cam.snap()
	if state == AppState.MENU and menu_world != null:
		menu_time += dt
		_animate_menu_showroom(dt)
	if _perf_mode:
		_perf_tick(dt)
		return
	if not shot_mode:
		governor.tick(dt)
		return
	_shot_frames += 1
	_shot_wall += dt
	# _start_race 是 async：_ready 里立即 reset 时 car 还没生成。等车真的进树后
	# 再按 --shot-dist 定位，否则所有赛道截图都会落回起跑线（2026-11 修复）。
	if _shot_dist > 0.0 and not _shot_reset_applied and car != null and race != null:
		car.reset(_shot_dist)
		_shot_reset_applied = true
	# _start_race 是 async，_ready 里 race 还是 null；结算截图必须等它真的建好再模拟
	if shot_scene == "results" and not _shot_results_done and car != null and race != null:
		_shot_results_done = true
		_simulate_until_results()
		if hud != null:
			hud.show_results(race)
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
		"menu":
			# 按墙钟等 delay：展车自转与轮廓扫光都走 dt，若按帧数等，低帧率
			# （别的进程抢 GPU）会让同一 --shot-delay 拍出不同转角/扫光相位，
			# 前后对比全被污染。45 帧下限在慢机上反而晚于墙钟，压到 12 帧
			# 只做渲染预热，拍摄时刻完全由 _shot_wall 决定。
			ready = _shot_frames >= 12 and _shot_wall >= _shot_delay + 0.75
		"results", "settings":
			ready = _shot_frames >= 45 + int(round(_shot_delay * 60.0))
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
		"settings-game":
			if _shot_frames == 30 and settings_screen != null:
				settings_screen._select_tab(3)
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
	elif _trailer_hud >= 0 and hud != null:
		# 内建机位（drift / nitro / pack）也要能隐藏 HUD
		hud.visible = (_trailer_hud == 1)
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
	if race == null:
		return
	# 完美起步探测：倒计时最后 0.95s 内把油门踩下去，GO 瞬间给奖励。
	# 读取原始输入而不是 COUNTDOWN_INPUT（后者被强制为 0）。
	if race.state == RaceManager.State.COUNTDOWN and not verify_mode and not shot_mode:
		var raw := InputSetup.read_drive_input()
		if race.countdown <= 0.95 and float(raw.get("throttle", 0.0)) > 0.55:
			_launch_armed = true
	var input: Dictionary
	if race.state == RaceManager.State.COUNTDOWN:
		input = COUNTDOWN_INPUT
	elif shot_mode:
		if shot_scene == "drift":
			input = _autopilot_input()
			input["throttle"] = maxf(float(input.get("throttle", 0.0)), 0.7)
			var drift_now := race != null and race.race_started and race.race_time < 1.25
			# 拍片：race_started 在起跑线附近永远不为真，按帧数给一段固定甩尾窗口
			if _movie_frames > 0:
				drift_now = _shot_frames >= 150 and _shot_frames <= 195
			if drift_now:
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
	elif _tutorial_test_mode:
		input = _tutorial_test_input()
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
	_apply_draft_targets()
	if _drive_probe_time >= 0.0 and race.state != RaceManager.State.COUNTDOWN:
		input = _autopilot_input()
		input["throttle"] = 1.0
		input["nitro"] = false
		input["handbrake"] = false
		_drive_probe_elapsed += dt
		_drive_probe_log += dt
		if _drive_probe_log >= 0.5:
			_drive_probe_log = 0.0
			print("[PROBE] t=%.1f speed=%.1f kph pos=(%.1f,%.1f) gear=%d rpm=%.2f off=%s surf=%s wall=%s prog=%.0f" % [
				_drive_probe_elapsed, car.speed_kph, car.pos.x, car.pos.z,
				car.gear, car.rpm, str(car.offroad), car.world_surface,
				str(car.wall_contact), car.progress_dist])
		if _drive_probe_elapsed >= _drive_probe_time:
			get_tree().quit(0)
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
			# P2 也能吃到 P1 的尾流：双人追逐同样有超车手段。
			duel_p2.draft_target = _draft_target_for(duel_p2, [car])
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
		# AI 决策 60Hz 足够（样条运动学 + 阻尼平滑），物理 120Hz 下省一半脚本开销；
		# 渲染位置每个物理帧插值，高刷屏上不会看出台阶。
		_ai_acc += dt
		if _ai_acc >= 1.0 / 60.0:
			for ai in ais:
				ai.update_ai(_ai_acc, car, race.race_laps, ais, race.player_pace)
			_ai_acc = 0.0
	for ai in ais:
		ai.interpolate_visual(_ai_acc)
	var impact := contacts.resolve()
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
	if cone_field != null and cone_editor == null and race.state == RaceManager.State.RACING:
		var cone_half := CarContacts.half_extents(current_car_id)
		var knocked_now := cone_field.update_knock(Vector2(car.pos.x, car.pos.z), car.heading, cone_half)
		if knocked_now > 0:
			_cone_knocked += knocked_now
			if hud != null:
				hud.show_message("碰倒锥桶  ×%d" % _cone_knocked, UIStyle.GOLD, 1.6)
	if _prev_race_state == RaceManager.State.COUNTDOWN \
			and race.state == RaceManager.State.RACING:
		_apply_start_bonus()
	_prev_race_state = race.state
	_update_lap_cleanliness(dt)
	_update_overtake_reward(dt)
	_update_ghost(dt)
	_update_skid_marks()
	if audio != null:
		audio.update_engine(car.rpm, car.throttle, clampf(car.speed_kph / 300.0, 0.0, 1.0), car.gear, (1 if car.limiter_active else 0))
	if game_feel != null and game_feel.has_method("update_state"):
		game_feel.update_state(dt, car, race.state)
	if cam != null and intro_cam == null and shot_scene != "venue" and shot_scene != "panorama" \
			and shot_scene != "rt" and shot_scene != "pack":
		cam.follow_update(dt)
	# HUD 以 60Hz 刷新：物理 120Hz 下每帧更新十几组标签/样式是纯浪费，
	# 60Hz 对速度表/转速表已经足够顺滑。提示计时用累计帧时长补偿。
	_hud_acc += dt
	if _hud_acc >= 1.0 / 60.0:
		if hud != null:
			hud.refresh(race, car, track_path, _hud_acc)
		_hud_acc = 0.0
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
			if race != null and race.track != null:
				targets = ProfileStore.medal_targets(race.track, race.race_laps, race.mode, int(race.track_def.get("difficulty", 2)))
				var summary: Dictionary = ProfileStore.submit_race(race, car, {
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
			if hud.has_method("append_result_line") and _clean_laps > 0:
				hud.append_result_line("干净圈  %d / %d" % [_clean_laps, race.race_laps])
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
	if tutorial != null:
		tutorial.tick(dt, car, race, cam)


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
	if cone_editor != null:
		return
	if event.is_action_pressed("reset_car"):
		_start_race(current_track_id, current_car_id, current_mode)
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("camera_mode") and cam != null \
			and (race == null or race.state != RaceManager.State.RESULTS):
		var cam_label := cam.cycle_mode()
		if hud != null and hud.has_method("set_camera_name"):
			hud.set_camera_name(cam_label)
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("camera_reset") and cam != null:
		cam.recenter_look()
		get_viewport().set_input_as_handled()
		return
	# 十字键左右：拍照 / 快速设置。上下已绑定升/降挡，不在这里拦截。
	if event is InputEventJoypadButton and (event as InputEventJoypadButton).pressed \
			and race != null and race.state != RaceManager.State.RESULTS:
		var dpad_btn := (event as InputEventJoypadButton).button_index
		if dpad_btn == JOY_BUTTON_DPAD_LEFT:
			_open_race_photo()
			get_viewport().set_input_as_handled()
			return
		if dpad_btn == JOY_BUTTON_DPAD_RIGHT:
			_open_settings()
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
		if btn == JOY_BUTTON_A or btn == JOY_BUTTON_START or btn == JOY_BUTTON_B:
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
	if event.is_action_pressed("ui_cancel"):
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
		elif key == KEY_P:
			_open_race_photo()
			get_viewport().set_input_as_handled()
		elif key == KEY_V and track_path != null and track_path.open_field:
			_toggle_cone_editor()
			get_viewport().set_input_as_handled()
		elif key == KEY_ENTER and race != null and race.state == RaceManager.State.RESULTS:
			var next_track := _next_track_id(current_track_id)
			_start_race(next_track, current_car_id, current_mode)
			get_viewport().set_input_as_handled()


# ---------------------------------------------------------------------------
# menu / race lifecycle
# ---------------------------------------------------------------------------

func _show_menu() -> void:
	_end_tutorial_session()
	_clear_race()
	_sync_post_amount(0.0)
	_set_post_grade({})
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
	menu.tutorial_requested.connect(_start_tutorial)
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
	_apply_menu_camera_attributes()
	# 截图计时从"装饰完成"起算：展车自转与轮廓扫光都从这一刻开始走 dt，
	# 与 _shot_wall 严格同步。慢机/加载耗时不再让拍摄时的转角和扫光相位漂移。
	_shot_wall = 0.0
	_menu_sweep_t = 0.0
	if menu_car_pivot != null:
		menu_car_angle = menu_car_pivot.rotation.y
	return true


func _decorate_menu_scene() -> void:
	if menu_world == null:
		return
	_menu_apply_render_stability()
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
				"volumetric": env.volumetric_fog_enabled,
			}
		# 展厅曝光：暗色赛道只抬到能读懂车形的程度，不再 ×1.75 把车漆推过曝。
		# 白天赛道用 1.0（与比赛锁定亮度一致），暗色 1.25 保留展厅可读性。
		var expo_mul := 1.25 if dark_menu else 1.0
		if menu_track_id == "alpine":
			expo_mul = 0.88
		env.tonemap_exposure = minf(env.tonemap_exposure * expo_mul, 2.1)
		# 静态展厅重新开 SSR：车漆/轮胎在湿路面与展台上的倒影是「高级感」的
		# 主要来源。相机固定 + FXAA，不跑时间重投影，不会出现比赛里的抖动。
		# 低画质档仍关闭，避免弱机在菜单就吃满预算。
		env.ssr_enabled = Settings.index >= 2
		env.ssr_max_steps = 48 if Settings.index >= 3 else 24
		env.ssr_fade_in = 0.10
		env.ssr_fade_out = 2.2
		env.ssr_depth_tolerance = 0.45
		if OS.get_environment("APEX_Q_MENU_SSR") == "0":
			env.ssr_enabled = false
		env.ssil_enabled = false
		env.sdfgi_enabled = false
		# 体积雾是半分辨率 + 时间重投影，静态展厅里会随每帧抖动；
		# 菜单用常规雾 + 天空霾保持空气感，画面稳定优先。
		env.volumetric_fog_enabled = false
		# 展厅是静态机位，SSAO 不会像比赛里那样闪；开着让车底/展台接缝有接触阴影。
		env.ssao_enabled = true
		env.ssao_intensity = minf(env.ssao_intensity, 2.2)
		env.adjustment_brightness = maxf(env.adjustment_brightness, 1.0 if not dark_menu else 1.05)
		# 展台车漆高光收紧：亮色车漆被辅助灯推到 HDR 高区后，泛光会把车头
		# 糊成一团白（车缓转时尤其明显）。阈值 2.6 只让真正的亮源发光
		# （路灯/霓虹/尾灯 HDR 3~8 仍泛光，拍板夜景不受影响）。
		env.glow_hdr_threshold = maxf(env.glow_hdr_threshold, 2.6)
		env.glow_intensity *= 0.78
		env.glow_bloom = minf(env.glow_bloom, 0.04)
		if OS.get_environment("APEX_Q_MENU_GLOW") == "0":
			env.glow_enabled = false
		env.glow_map = _lens_dirt_texture() if Settings.index >= 2 else null
		env.glow_map_strength = 0.28 if Settings.index >= 3 else 0.18
		if dark_menu:
			env.ambient_light_energy = minf(env.ambient_light_energy + 0.18, 0.95)
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
	# 展厅的主光必须是场景自己的太阳：补光只负责「暗面读懂车形」。
	# 旧版 5 盏影棚聚光 + 烘焙遗留聚光把车打得比环境亮一截、高光方向又和
	# 影子对不上，车像贴上去的。这里把补光压到辅助级，并让主补光顺着太阳方向。
	var car_pos := menu_car_pivot.global_position
	var scene_sun := menu_world.find_child("Sun", true, false) as DirectionalLight3D
	for node in menu_world.find_children("*", "SpotLight3D", true, false):
		var baked := node as SpotLight3D
		if menu_decor_lights.has(baked):
			continue
		baked.light_energy = minf(baked.light_energy, 1.4)
		baked.light_specular = 0.0
		if scene_sun != null:
			baked.light_color = scene_sun.light_color
	# 烘焙场景里还带着一份旧车底氛围灯：运行时又会新建一盏，两盏叠加把车侧
	# 下半部推到 HDR 2~6，泛光在镜壳/A 柱烧出死白光斑。只压车身边 3m 内的
	# 旧 Omni（街灯等环境 Omni 离车远，不受影响）。
	# 街灯 Omni 的镜面镜像在挡风玻璃/镜壳上是 HDR 几十的圆光斑（玻璃粗糙度
	# 近 0），留 10% 都仍过泛光阈值烧成白球；湿路暖光池同理。烘焙 Omni 统一
	# 关 specular：湿地反光交给 SSR 与霓虹自发光，漫反射光池保留。
	for node in menu_world.find_children("*", "OmniLight3D", true, false):
		var baked_omni := node as OmniLight3D
		if menu_decor_lights.has(baked_omni):
			continue
		baked_omni.light_specular = 0.0
		var dp := baked_omni.global_position - car_pos
		if dp.length() < 3.0 and dp.y < 1.0:
			baked_omni.light_energy = minf(baked_omni.light_energy, 0.35)
	var toward_sun := Vector3(0.42, 0.62, 0.2).normalized()
	var key_color := Color(1.0, 0.94, 0.85)
	if scene_sun != null:
		toward_sun = scene_sun.global_transform.basis.z.normalized()
		key_color = scene_sun.light_color
	var key := SpotLight3D.new()
	var key_from := toward_sun * 9.0 + Vector3(0.0, 4.0, 0.0)
	# 聚光按平方反比衰减：9m 外能量个位数几乎不可见；但几十的能量会把
	# 亮色车漆推过泛光阈值，车头糊成一团白光。数值按白漆车收敛到「能读懂
	# 车形、又不触发泛光」的量级，主光仍是场景太阳。
	var key_energy := 13.5 if dark_menu else 6.2
	if night and menu_cam != null:
		# 夜景：月光方向往往背着相机，顺月亮打车会让展车正面全黑。
		# 改从相机侧打一盏暖色「路灯感」主光，和街灯色温一致。
		var to_cam := menu_cam.global_position - car_pos
		to_cam.y = 0.0
		if to_cam.length_squared() > 0.01:
			key_from = to_cam.normalized() * 8.0 + Vector3(0.0, 5.0, 0.0)
			key_color = Color(1.0, 0.86, 0.64)
			key_energy = 11.5
	key.position = car_pos + key_from
	key.light_color = key_color
	key.light_energy = key_energy
	key.spot_range = 32.0
	key.spot_angle = 38.0
	# 主光开阴影：展车在展台/地面上落下一道柔和接触影，车形立体、不「贴」在场景里。
	key.shadow_enabled = true
	key.shadow_blur = 1.6
	# 补光只做漫反射：点光源在玻璃/清漆里的镜像是一个过曝死白点，泛光把它
	# 放大成光晕、湿路 SSR 再铺到地面——亮漆车因此比暗漆车「整片地更亮」。
	# 镜面高光交给太阳/天空/霓虹，五盏补光统一关 specular。
	key.light_specular = 0.0
	menu_world.add_child(key)
	key.look_at(car_pos + Vector3(0.0, 0.8, 0.0), Vector3.UP)
	menu_decor_lights.append(key)
	var rim := SpotLight3D.new()
	rim.position = car_pos + Vector3(-6.0, 3.2, -6.0)
	rim.light_color = Color(0.55, 0.82, 1.0)
	rim.light_energy = 6.2 if night else (8.2 if dark_menu else 3.6)
	rim.spot_range = 26.0
	rim.spot_angle = 42.0
	rim.shadow_enabled = false
	rim.light_specular = 0.0
	menu_world.add_child(rim)
	rim.look_at(car_pos + Vector3(0.0, 0.9, 0.0), Vector3.UP)
	menu_decor_lights.append(rim)
	var probe := ReflectionProbe.new()
	probe.position = car_pos + Vector3(0.0, 2.5, 0.0)
	probe.size = Vector3(14.0, 8.0, 14.0)
	probe.box_projection = true
	probe.interior = false
	probe.update_mode = ReflectionProbe.UPDATE_ONCE
	probe.enable_shadows = false
	# 只拍环境层：车体已统一在层 2，避免车漆反射自己的车身/内饰。
	probe.cull_mask = 1
	probe.max_distance = 120.0
	if OS.get_environment("APEX_Q_MENU_PROBE") != "0":
		menu_world.add_child(probe)
		menu_decor_lights.append(probe)
	var fill := SpotLight3D.new()
	fill.position = car_pos + Vector3(-5.0, 4.5, -4.5)
	fill.light_color = accent
	fill.light_energy = 4.4 if night else (5.2 if dark_menu else 2.2)
	fill.spot_range = 26.0
	fill.spot_angle = 50.0
	fill.shadow_enabled = false
	fill.light_specular = 0.0
	menu_world.add_child(fill)
	fill.look_at(car_pos + Vector3(0.0, 0.8, 0.0), Vector3.UP)
	menu_decor_lights.append(fill)
	# 车底氛围灯：夜间保留一圈主色光池；白天只留极弱一点，否则像加装霓虹灯。
	var under := OmniLight3D.new()
	under.position = car_pos + Vector3(0.0, 0.30, 0.0)
	under.light_color = accent
	under.light_energy = 0.55 if dark_menu else 0.13
	under.omni_range = 6.0 if not dark_menu else 7.5
	under.omni_attenuation = 1.7
	under.shadow_enabled = false
	under.light_specular = 0.0
	menu_world.add_child(under)
	menu_decor_lights.append(under)
	# 顶后轮廓光：勾出发动机盖、尾翼和车顶的高光边，车漆更有金属感。
	var kicker := SpotLight3D.new()
	kicker.position = car_pos + Vector3(2.5, 8.5, -7.0)
	kicker.light_color = Color(0.95, 0.97, 1.0)
	kicker.light_energy = 7.5 if night else (10.5 if dark_menu else 5.0)
	kicker.spot_range = 32.0
	kicker.spot_angle = 34.0
	kicker.shadow_enabled = false
	kicker.light_specular = 0.0
	menu_world.add_child(kicker)
	kicker.look_at(car_pos + Vector3(0.0, 0.9, 0.0), Vector3.UP)
	menu_decor_lights.append(kicker)
	_menu_kicker = kicker
	_menu_sweep_t = 0.0
	_setup_menu_glare(theme, dark_menu)
	_add_menu_weather(theme)


## 菜单展厅沿用赛道主题天气：城市雨夜/雪山飘雪/峡谷扬尘。粒子只跟随展车，
## 不影响 UI 与静态相机；切换赛道时随 menu_world 一起释放。
func _add_menu_weather(theme: Dictionary) -> void:
	if menu_world == null or menu_car_pivot == null:
		return
	var kind := String(theme.get("weather", "none"))
	if kind.is_empty() or kind == "none":
		return
	var fx := WeatherFX.new()
	fx.name = "MenuWeather"
	menu_world.add_child(fx)
	fx.setup(kind, theme, menu_car_pivot)
	# 展厅是近景静态镜头：雨量降到赛道的 ~1/4，雨丝缩短，避免贴脸大雨条。
	if kind == "rain":
		if fx.particles != null:
			fx.particles.amount = int(900 * Settings.particle_scale())
			var quad := fx.particles.draw_pass_1 as QuadMesh
			if quad != null:
				quad.size = Vector2(0.045, 0.5)
		var splash := menu_car_pivot.find_child("RainSplashes", true, false) as GPUParticles3D
		if splash != null:
			splash.amount = int(90 * Settings.particle_scale())


## 菜单展厅的太阳眩光：优先用烘焙场景里的 Sun 光方向，没 Sun 时退回主题 sunDir。
func _setup_menu_glare(theme: Dictionary, dark_menu: bool) -> void:
	if OS.get_environment("APEX_Q_SUN_GLARE") == "0":
		_setup_sun_glare(Vector3.ZERO, Color.WHITE, 0.0)
		return
	var dir := Vector3(0.42, 0.52, 0.2)
	var color := Color(1.0, 0.95, 0.86)
	var sun := menu_world.find_child("Sun", true, false) as DirectionalLight3D if menu_world != null else null
	if sun != null:
		dir = sun.global_transform.basis.z.normalized()
		color = sun.light_color
	else:
		var sd: Array = theme.get("sunDir", [0.42, 0.52, 0.2])
		dir = Vector3(float(sd[0]), float(sd[1]), float(sd[2])).normalized()
		color = Color.from_string(String(theme.get("sunColor", "#fff2da")), color)
	_setup_sun_glare(dir, color, 0.55 if not dark_menu else 0.26)


func _setup_sun_glare(dir: Vector3, color: Color, strength: float) -> void:
	if _sun_glare == null:
		return
	if dir.length_squared() < 0.0001 or strength <= 0.002:
		_sun_glare.set("intensity", 0.0)
		_sun_glare.visible = false
		return
	_sun_glare.call("setup", dir, color, strength)


## 赛道太阳眩光：方向取真实太阳；夜间压成月光，雨雪天减半。
func _setup_race_sun_glare() -> void:
	if _sun == null:
		_setup_sun_glare(Vector3.ZERO, Color.WHITE, 0.0)
		return
	var theme: Dictionary = track_def.get("theme", {}) if not track_def.is_empty() else {}
	var strength := 0.22 if SceneryKit.is_night_theme(theme) else 0.72
	if theme.has("sunGlare"):
		strength = clampf(float(theme["sunGlare"]), 0.0, 2.0)
	if String(theme.get("weather", "none")) in ["rain", "snow"]:
		strength *= 0.45
	_setup_sun_glare(_sun.global_transform.basis.z.normalized(), _sun.light_color, strength)


## 菜单是纯静态展厅：4K 下按 0.70 缩放走 MetalFX 时间升频，静止画面里的
## 远景山脊/栏杆/云边会逐帧抖动（屏幕上看就是背景在闪）。菜单改用原生
## 分辨率 + FXAA 的空间路径，并关掉体积雾的逐帧抖动；回到比赛/车库时
## _apply_quality() 会把这些全部恢复成比赛配置。
func _menu_apply_render_stability() -> void:
	var vp := get_viewport()
	if vp == null:
		return
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	vp.scaling_3d_scale = 1.0
	vp.use_taa = false
	vp.msaa_3d = Viewport.MSAA_DISABLED
	vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA
	vp.use_debanding = true


## 展厅轻景深：车在 9m 左右保持全清晰，远景楼群/山体柔化，把车从背景里推出来。
## 只在静态菜单开，比赛相机不受影响；低画质档跳过。
func _apply_menu_camera_attributes() -> void:
	if menu_cam == null:
		return
	if Settings.index < 2:
		menu_cam.attributes = null
		return
	var attrs := CameraAttributesPractical.new()
	attrs.dof_blur_far_enabled = true
	attrs.dof_blur_far_distance = 30.0
	attrs.dof_blur_far_transition = 60.0
	attrs.dof_blur_amount = 0.02
	menu_cam.attributes = attrs


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
				env.volumetric_fog_enabled = bool(menu_env_backup.get("volumetric", true))
	menu_env_backup.clear()


func _bake_menu_scenes(only_id: String = "") -> void:
	_bake_menu_active = true
	var dir := "res://assets/menu_scenes"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	for def in GameData.tracks:
		var id := String(def.get("id", ""))
		if id.is_empty():
			continue
		if not only_id.is_empty() and id != only_id:
			continue
		var t0 := Time.get_ticks_msec()
		_build_menu_showroom(id, "", true)
		if menu_world == null:
			continue
		var err := _pack_owned_scene(menu_world, "%s/%s.scn" % [dir, id])
		print("[BAKE] %s err=%s took=%dms" % [id, err, Time.get_ticks_msec() - t0])
		_free_menu_world()
	_bake_menu_active = false


func _run_bake_menu(only_id: String = "") -> void:
	_bake_menu_scenes(only_id)
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
				mi.set_script(load("res://maps/scripts/tracks/baked_multimesh.gd"))
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
	if bool(def.get("openField", false)):
		_build_field_showroom(car_id, bake_only)
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
const CITY_RING_SCENE := "res://maps/assets/city_ring/city_ring.glb"
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


## 漂移练习展台：整片空旷柏油就是背景。车停在场地中心，机位贴地斜看出去，
## 路面一直铺到地平线，突出「一公里见方、没有障碍随便漂」的开阔感。
func _build_field_showroom(car_id: String, bake_only: bool = false) -> void:
	var builder := TrackBuilder.new()
	builder.name = "MenuTrack"
	menu_world.add_child(builder)
	builder.build(GameData.track(menu_track_id))
	var car_pos := Vector3(0.0, 0.03, 0.0)
	var car_yaw := 0.42
	menu_car_pivot = Node3D.new()
	menu_car_pivot.name = "MenuCarPivot"
	menu_car_pivot.position = car_pos
	menu_car_pivot.rotation.y = car_yaw
	menu_world.add_child(menu_car_pivot)
	menu_car_angle = car_yaw
	if not bake_only:
		_menu_build_car(car_id)

	var fwd := Vector3(sin(car_yaw), 0.0, cos(car_yaw))
	var side := Vector3(-fwd.z, 0.0, fwd.x)
	var key := SpotLight3D.new()
	key.position = car_pos + side * 5.0 - fwd * 4.0 + Vector3(0.0, 7.0, 0.0)
	key.light_color = Color(1.0, 0.93, 0.82)
	key.light_energy = 7.0
	key.spot_range = 26.0
	key.spot_angle = 40.0
	key.shadow_enabled = false
	menu_world.add_child(key)
	key.look_at(car_pos + Vector3(0.0, 0.7, 0.0), Vector3.UP)

	var cam_pos := car_pos + side * 7.5 - fwd * 6.0 + Vector3(0.0, 2.05, 0.0)
	var look := car_pos + fwd * 26.0 + Vector3(0.0, 0.95, 0.0)
	menu_cam = Camera3D.new()
	menu_cam.name = "MenuCamera"
	menu_cam.fov = 46.0
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


func _animate_menu_showroom(dt: float) -> void:
	if menu_car_pivot != null:
		# 手柄右摇杆直接转车；没有输入时保留展厅自动慢转。
		var rs := InputSetup.right_stick()
		_menu_stick_active = rs.length_squared() > 0.0
		if _menu_stick_active:
			menu_car_angle += rs.x * 2.4 * dt
		elif not menu_dragging:
			menu_car_angle += 0.18 * dt
		menu_car_pivot.rotation.y = menu_car_angle
	# 顶后轮廓光缓慢左右扫过车身：静止展厅里也能看到一条高光沿车漆流动。
	if _menu_kicker != null and is_instance_valid(_menu_kicker) and menu_car_pivot != null:
		_menu_sweep_t += dt
		var car_pos := menu_car_pivot.global_position
		var drift := sin(_menu_sweep_t * 0.55)
		_menu_kicker.global_position = car_pos + Vector3(2.5 + drift * 6.5, 8.5, -7.0 + drift * 2.5)
		# 亮度锁定：轮廓光只移动位置扫高光，不再随时间泵能量（避免整车亮度呼吸）。
		_menu_kicker.look_at(car_pos + Vector3(0.0, 0.9, 0.0), Vector3.UP)
	# 相机保持完全静止，避免细微抖动造成地面高光闪烁


func _on_menu_start(track_id: String, car_id: String, mode: String) -> void:
	_start_race(track_id, car_id, mode)


## 新手教程：海岸线 1 圈计时赛（无 AI 干扰），浮层任务条全程引导。
func _start_tutorial() -> void:
	if shot_mode or verify_mode or _perf_mode:
		return
	_tutorial_session = true
	var car_id := DEFAULT_CAR
	if menu != null:
		car_id = menu.selected_car_id()
	_start_race(DEFAULT_TRACK, car_id, "ta")


## 回菜单 / 离开教程比赛时收尾：中途离开记为跳过（不再自动触发），
## 已毕业则保持 done。浮层卸载时会把 HUD 的避让偏移还原。
func _end_tutorial_session() -> void:
	if tutorial != null:
		if _tutorial_session and not tutorial.is_graduated():
			var ps := ProfileStore
			ps.set_tutorial_state("skipped")
		tutorial.uninstall()
		tutorial = null
	_tutorial_session = false


func _on_tutorial_skip() -> void:
	var ps := ProfileStore
	ps.set_tutorial_state("skipped")
	_tutorial_session = false
	if tutorial != null:
		tutorial.uninstall()
		tutorial = null
	if hud != null:
		hud.show_message("教程已跳过 · 自由驾驶", UIStyle.TXT_SUB, 2.0)


func _on_tutorial_completed() -> void:
	var ps := ProfileStore
	if String(ps.load_profile().get("tutorial", "")) != "done":
		ps.grant_tutorial_bonus()
	ps.set_tutorial_state("done")
	_tutorial_session = false
	print("[TUTORIAL] graduated, profile marked done")


func _on_tutorial_race_again() -> void:
	_start_race(current_track_id, current_car_id, "ta")


func _on_menu_garage(car_id: String) -> void:
	_open_garage(car_id)


func _free_menu_world() -> void:
	if streamer != null:
		streamer.clear()
	if menu_stage_viewport != null:
		menu_stage_viewport.queue_free()
		menu_stage_viewport = null
	elif menu_world != null:
		# 同样要立刻摘出场景树：切换赛道时旧展台会跟新展台叠一帧。
		if menu_world.get_parent() != null:
			menu_world.get_parent().remove_child(menu_world)
		menu_world.queue_free()
	menu_world = null
	menu_car_pivot = null
	menu_car_model = null
	menu_cam = null
	_menu_kicker = null
	menu_car_id = ""
	menu_track_id = ""


func _open_garage(initial_car: String) -> void:
	_apply_quality()
	_setup_sun_glare(Vector3.ZERO, Color.WHITE, 0.0)
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


func _load_mark(t0: int, label: String) -> void:
	if OS.get_environment("APEX_LOAD_LOG") == "1":
		print("[LOAD] %-14s %5d ms" % [label, Time.get_ticks_msec() - t0])


## 驾驶图鉴：正式游玩时记录本场车辆；验证/拍片/性能测试不写玩家档案。
func _mark_car_driven_if_playing() -> void:
	if verify_mode or shot_mode or _perf_mode \
			or _tune_demo or _analog_test_mode or _drift_test_mode:
		return
	if _movie_frames > 0 or not _trailer_shot.is_empty():
		return
	if current_car_id.is_empty():
		return
	var ps := ProfileStore
	ps.mark_car_driven(current_car_id, GameData.cars_specs.size())


func _start_race(track_id: String, car_id: String, mode: String) -> void:
	var load_t0 := Time.get_ticks_msec()
	var prev_track := current_track_id
	var prev_state := state
	_apply_quality()
	_results_shown = false
	current_track_id = track_id
	current_car_id = car_id
	current_mode = mode
	_mark_car_driven_if_playing()
	track_def = GameData.track(track_id)
	if track_def.is_empty():
		track_def = GameData.track(DEFAULT_TRACK)
		current_track_id = DEFAULT_TRACK
	# 开放漂移场地只有单人自由练习：GP/对决没有圈数可跑，强制计时赛通道。
	if bool(track_def.get("openField", false)):
		current_mode = "ta"
	_set_post_grade(track_def.get("theme", {}))
	# 阴影预算/效果开关不在这里重算：自建世界由 _setup_environment 末尾统一
	# 应用，复用菜单/烘焙世界由 _bind_world_environment 应用。少一次画质管线
	# 重建，进赛加载少一段卡顿。

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
	# 车模是进赛最重的一次同步加载（玩家 + 三台 AI）：先在线程里读，
	# 等世界建完再取，加载动画不会被几百毫秒的磁盘/解析卡住。
	_begin_car_preload()
	_load_mark(load_t0, "loading-up")
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

	_load_mark(load_t0, "world")
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
		# 菜单世界/烘焙场景里已经带 WorldEnvironment 与 Sun：_env/_sun 必须
		# 重新指向它们，否则换图后仍会操作上一张图（甚至已释放）的环境对象。
		_bind_world_environment(world, track_def)
		_apply_quality()
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
	_load_mark(load_t0, "world-build")
	# 关键顺序：_setup_environment / _bind_world_environment 里的 _apply_quality
	# 会把守门员档位重置回 cap；必须等它们跑完再恢复本赛道上次的稳定比例，
	# 否则跨会话记住的动态分辨率档位永远不会生效。
	governor.apply_saved_scale()
	if track_path == null or track_path.samples.is_empty():
		push_error("Main: track build failed for %s" % current_track_id)
		if loading_shown:
			_end_loading()
		return

	await _await_car_preload()
	_load_mark(load_t0, "preload")
	_spawn_player()
	_load_mark(load_t0, "player")
	skid_marks = SkidMarks.new()
	skid_marks.name = "SkidMarks"
	race_root.add_child(skid_marks)
	skid_marks.setup()
	_maybe_add_car_reflection_probe()
	if car != null and _city_world != null:
		car.city = _city_world
	_spawn_duel_second()
	_nitro_use_count = 0
	_drift_time = 0.0
	_race_pos_prev = 0
	_overtake_cd = 0.0
	_launch_armed = false
	_prev_race_state = -1
	_last_player_laps = 0
	_lap_wall_hits = 0
	_lap_offroad = 0.0
	_clean_laps = 0
	_hud_acc = 0.0
	_ai_acc = 0.0
	_top_speed_kph = 0.0
	_was_nitro = false
	_last_gear_seen = 1
	_wall_hit_cd = 0.0
	_line_samples.clear()
	_line_acc = 0.0
	_run_recorded = false
	if car != null and SceneryKit.is_night_theme(track_def.get("theme", {})):
		car.add_headlights(_headlight_energy_scale(track_def.get("theme", {})))
		var rim_col := _c(String(track_def.get("theme", {}).get("fillColor", "")),
			Color(0.62, 0.78, 1.0)).lerp(Color(0.86, 0.92, 1.0), 0.35)
		car.add_night_rim(rim_col)
	_spawn_ai()
	_load_mark(load_t0, "ai")

	_ensure_fill_light(race_root, track_def)
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
	hud.result_restart_requested.connect(func() -> void:
		_start_race(current_track_id, current_car_id, current_mode))
	hud.result_next_requested.connect(func() -> void:
		_start_race(_next_track_id(current_track_id), current_car_id, current_mode))
	hud.result_menu_requested.connect(_show_menu)
	# 全景电影镜头不要赛车 HUD
	hud.visible = not (shot_mode and shot_scene == "panorama")
	hud.set_camera_name(cam.mode_label())
	_load_mark(load_t0, "view")

	race = RaceManager.new()
	var laps := int(track_def.get("laps", 3))
	var laps_override = Settings.get("laps_override")
	if laps_override != null and int(laps_override) > 0:
		laps = int(laps_override)
	if _tutorial_session:
		laps = 1
	var race_mode := "ta" if current_mode == "duel" else current_mode
	race.setup(track_path, track_def, laps, race_mode, car, ais)
	duel_total_laps = laps
	hud.bind_race(race, car, track_path)
	if bool(track_def.get("openField", false)):
		cone_field = ConeField.new()
		cone_field.name = "ConeField"
		race_root.add_child(cone_field)
		cone_field.set_layout(ConeStore.load_layout())
		_cone_knocked = 0
	if _tutorial_session:
		if tutorial == null:
			tutorial = TutorialScript.new()
			tutorial.name = "TutorialOverlay"
			tutorial.skip_requested.connect(_on_tutorial_skip)
			tutorial.completed.connect(_on_tutorial_completed)
			tutorial.menu_requested.connect(_show_menu)
			tutorial.race_requested.connect(_on_tutorial_race_again)
			add_child(tutorial)
		tutorial.bind(hud)
	elif tutorial != null:
		tutorial.uninstall()
		tutorial = null
	_load_mark(load_t0, "race-setup")
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
		_load_mark(load_t0, "bgm")
		audio.start_engine()
		_load_mark(load_t0, "engine")
		audio.start_ambience()
		if audio.has_method("set_engine_profile") and car != null:
			audio.set_engine_profile(car.spec)
	_load_mark(load_t0, "audio")
	if streamer != null:
		streamer.enabled = not (shot_mode and shot_scene in ["panorama", "rt", "venue"])
		streamer.setup(cam, race_root)
	if not shot_mode and not _perf_mode and not verify_mode and current_mode != "duel":
		_setup_race_intro_camera()
	_setup_race_sun_glare()
	if loading_shown:
		# 上一场全程宽裕（<13ms）说明档位保守了：借加载遮罩升一小档，
		# 换档引起的管线重建卡顿被遮罩吃掉，几场内收敛到真正需要的分辨率。
		governor.apply_saved_scale(true)
		# 加载动画至少 1.25s；淡出前先在遮罩后面渲染几帧，把管线/着色器
		# 编译和首批纹理上传吃掉，避免比赛第一秒的 60ms 长帧。
		if game_feel != null and game_feel.has_method("prewarm"):
			game_feel.prewarm()
		var elapsed := float(Time.get_ticks_msec() - loading_start) / 1000.0
		if elapsed < 1.25:
			await get_tree().create_timer(1.25 - elapsed).timeout
		for i in 3:
			await get_tree().process_frame
		_end_loading()
		_load_mark(load_t0, "end-loading")
	_load_mark(load_t0, "race-ready")
	if OS.get_environment("APEX_LOAD_LOG") == "1":
		_hitch_log_start = Time.get_ticks_msec()
		_hitch_log_until = _hitch_log_start + 8000
	if OS.get_environment("APEX_FRAME_LOG") == "1":
		_frame_log_start = Time.get_ticks_msec()
		_frame_log_intro.clear()
		_frame_log_race.clear()
		_frame_log_on = true


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
	if intro_cam != null:
		intro_cam.queue_free()
		intro_cam = null
	cam.current = false
	if track_path.open_field:
		# 场地没有起跑线：从斜前方低空掠过整片柏油，看向场地中心的车。
		intro_from_pos = car.global_position + Vector3(24.0, 6.5, 30.0)
	else:
		var frame := track_path.frame_at(0.0)
		if frame.is_empty():
			return
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
	# 自由练习没有「圈」可回放，也不录幽灵（无圈完赛会无限累积采样）。
	if track_path.open_field:
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
	# 幽灵是半透明叠加层，只看轮廓：用低模省加载与 alpha overdraw，删掉的内饰/引擎本来就看不见。
	var result := CarVisual.build(spec, ghost_root, Color.TRANSPARENT, true)
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


## 跟随式环境反射探针：车漆反射街道/霓虹/建筑而不是只反射天空。
## 高/超高默认开启；静止时不重绘，行驶中每 3s 重绘一次 6 面 cubemap。
## APEX_Q_CAR_PROBE=0/1 可强制关/开做 A/B。
func _maybe_add_car_reflection_probe() -> void:
	if car == null:
		return
	var override := OS.get_environment("APEX_Q_CAR_PROBE")
	if override == "0":
		return
	if override != "1" and Settings.index < 2:
		return
	var probe := CarReflectionProbe.new()
	probe.name = "CarReflectionProbe"
	probe.setup()
	car.add_child(probe)


func _update_skid_marks() -> void:
	if skid_marks == null or car == null:
		return
	if not is_instance_valid(skid_marks):
		skid_marks = null
		return
	if car.offroad or car.speed_kph < 8.0:
		return
	var skidding := car.drift_active or car.handbrake \
		or (car.braking and car.speed_kph > 35.0)
	if skidding:
		skid_marks.emit_from_car(car)


func _update_ghost(dt: float) -> void:
	if race == null or car == null or track_path == null:
		return
	if race.mode == "ta" and race.state == RaceManager.State.RACING and not track_path.open_field:
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
	if cone_editor != null:
		cone_editor.queue_free()
		cone_editor = null
		get_tree().paused = false
	cone_field = null
	_cone_knocked = 0
	if photo_mode != null:
		if is_instance_valid(photo_mode):
			photo_mode.queue_free()
		photo_mode = null
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		if hud != null:
			hud.visible = true
	ghost_root = null
	_ghost_data = {}
	_ghost_samples.clear()
	_ghost_visual_car = ""
	_line_samples.clear()
	_line_acc = 0.0
	_run_recorded = false
	_city_world = null
	if streamer != null:
		streamer.clear()
	if audio != null:
		audio.stop_engine()
		audio.stop_ambience()
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
		# queue_free 要到帧末才真正删除，这一帧里 race_root 还会照常渲染，
		# 切换世界时可能叠在新建的菜单世界上。摘出场景树可让这一帧干净。
		if race_root.get_parent() != null:
			race_root.get_parent().remove_child(race_root)
		race_root.queue_free()
		race_root = null
		skid_marks = null
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
	if SceneryKit.is_night_theme(track_def.get("theme", {})):
		duel_p2.add_headlights(_headlight_energy_scale(track_def.get("theme", {})))
	if _city_world != null:
		duel_p2.city = _city_world
	duel_p2_laps = 0
	duel_p2_prev_progress = fposmod(duel_p2.progress_dist, maxf(track_path.total_length, 1.0))
	duel_p2_lap_start = 0.0
	duel_p2_best_lap = -1.0
	duel_p2_finish_time = -1.0
	duel_winner = ""


var _car_preload_paths: Array[String] = []


## 选车和 AI 配色在开赛前就确定，可提前把车模与 BGM 丢给后台线程读。
func _begin_car_preload() -> void:
	_car_preload_paths.clear()
	var paths: Array[String] = []
	var seen := {}
	var player_spec := GameData.car(current_car_id)
	if not player_spec.is_empty():
		paths.append("res://cars/assets/models/" + String(player_spec.get("model", current_car_id + ".glb")))
	for id in _ai_variant_ids():
		var spec := GameData.car(id)
		if spec.is_empty():
			continue
		var model_file := String(spec.get("model", id + ".glb"))
		var lod_path := "res://cars/assets/models_lod/" + model_file
		paths.append(lod_path if ResourceLoader.exists(lod_path)
			else "res://cars/assets/models/" + model_file)
	if audio != null and audio.has_method("bgm_path_for"):
		var bgm := String(audio.call("bgm_path_for", current_track_id))
		if not bgm.is_empty():
			paths.append(bgm)
	for p in paths:
		if seen.has(p) or not ResourceLoader.exists(p):
			continue
		seen[p] = true
		_car_preload_paths.append(p)
		ResourceLoader.load_threaded_request(p, "", true)
	if OS.get_environment("APEX_LOAD_LOG") == "1":
		print("[LOAD] preload-queue %d files" % _car_preload_paths.size())


## 世界建完、刷车前把后台加载收尾：每帧只轮询一次，加载动画照常播。
## verify 专用：_start_race 是 async（车模线程预载），调用后必须等车/赛管进树，
## 否则紧接着的 car/race 断言全落在 null 上（M2 曾因此直接崩在 car.max_speed）。
func _await_race_ready() -> void:
	for i in 900:
		if car != null and race != null and track_path != null:
			return
		await get_tree().process_frame


func _await_car_preload() -> void:
	if _car_preload_paths.is_empty():
		return
	var finalized := {}
	while true:
		var pending := false
		for p in _car_preload_paths:
			if finalized.has(p):
				continue
			match ResourceLoader.load_threaded_get_status(p):
				ResourceLoader.THREAD_LOAD_IN_PROGRESS:
					pending = true
				ResourceLoader.THREAD_LOAD_LOADED:
					ResourceLoader.load_threaded_get(p)
					finalized[p] = true
					pending = true
				_:
					finalized[p] = true
		if not pending:
			break
		await get_tree().process_frame
	_car_preload_paths.clear()


func _ai_variant_ids() -> Array[String]:
	var ids: Array[String] = []
	var defs: Array = GameData.ai.get("defs", [])
	var offsets: Array = GameData.ai.get("rival_offsets", [1, 3, 5])
	if defs.is_empty() or GameData.cars_specs.is_empty():
		return ids
	var player_index := _car_index(current_car_id)
	for i in defs.size():
		var variant_id := current_car_id
		if not offsets.is_empty():
			var idx := posmod(player_index + int(offsets[i % offsets.size()]), GameData.cars_specs.size())
			variant_id = String(GameData.cars_specs[idx].get("id", variant_id))
		ids.append(variant_id)
	return ids


func _spawn_ai() -> void:
	ais.clear()
	if current_mode != "gp":
		return
	var defs: Array = GameData.ai.get("defs", [])
	var ids := _ai_variant_ids()
	if defs.is_empty() or ids.is_empty():
		return
	var night_scale := _headlight_energy_scale(track_def.get("theme", {}))
	var routes := _pick_ai_routes(defs.size())
	for i in ids.size():
		var ai_def: Dictionary = defs[i]
		var ai_spec := GameData.car(ids[i])
		if ai_spec.is_empty():
			ai_spec = GameData.car(DEFAULT_CAR)
		var ai := AICar.new()
		ai.name = "Rival%d" % (i + 1)
		add_child(ai)
		var color := Color.from_string(String(ai_def.get("color", "#cccccc")), Color(0.8, 0.8, 0.8))
		ai.setup(track_path, ai_spec, -9.0 - i * 8.0, 2.6 if i % 2 == 0 else -2.6,
			float(ai_def.get("baseSpeed", 72.0)), color,
			String(ai_def.get("name", "")), int(ai_def.get("number", 0)))
		if night_scale > 0.0:
			ai.add_headlights(night_scale)
		if i < routes.size():
			var entry: Dictionary = routes[i]
			ai.set_route(entry.get("line", {}), "%s %.2f" % [
				String(entry.get("car", "")), float(entry.get("lap", 0.0))])
		ais.append(ai)


## 赛道主题 → 车灯亮度系数；白天返回 0。manifest 里 headlightIntensity
## 是旧版网页的百分比口径（80 左右为基准），这里换算成灯能量倍率。
func _headlight_energy_scale(theme: Dictionary) -> float:
	if not SceneryKit.is_night_theme(theme):
		return 0.0
	var raw := float(theme.get("headlightIntensity", 80.0))
	return clampf(raw / 80.0, 0.55, 1.5)


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
# 尾流 / 超车
# ---------------------------------------------------------------------------

## 玩家 / 双人 P2 的尾流目标：正前方 2~34m、横向 <4m、同向行驶才吃得到。
## 强度按距离与横向偏移衰减，交给 Car 内部平滑，避免并线瞬间抖动。
func _draft_target_for(viewer: Car, others: Array) -> float:
	if viewer == null or not is_instance_valid(viewer):
		return 0.0
	if viewer.speed_kph < 55.0 or viewer.wall_contact:
		return 0.0
	var fwd := viewer.forward()
	var side := viewer.right()
	var best := 0.0
	for other in others:
		if other == null or not is_instance_valid(other) or other == viewer:
			continue
		var other_pos: Vector3 = other.pos
		var rel: Vector3 = other_pos - viewer.pos
		rel.y = 0.0
		var ahead := rel.dot(fwd)
		if ahead < 2.0 or ahead > 34.0:
			continue
		var lat := absf(rel.dot(side))
		if lat > 4.0:
			continue
		var other_heading := float(other.heading)
		if absf(wrapf(other_heading - viewer.heading, -PI, PI)) > 1.05:
			continue
		var gap01 := clampf((34.0 - ahead) / 30.0, 0.0, 1.0)
		var lat01 := clampf(1.0 - lat / 4.2, 0.0, 1.0)
		best = maxf(best, gap01 * lat01)
	return best


func _apply_draft_targets() -> void:
	if car == null:
		return
	var others: Array = []
	for ai in ais:
		if ai != null and is_instance_valid(ai):
			others.append(ai)
	if current_mode == "duel" and duel_p2 != null:
		others.append(duel_p2)
	car.draft_target = _draft_target_for(car, others)


## 完美起步：GO 瞬间给一次短促推力 + 四分之一管氮气，HUD 弹提示。
func _apply_start_bonus() -> void:
	if not _launch_armed:
		return
	_launch_armed = false
	if car == null:
		return
	car.grant_start_boost()
	car.add_nitro(0.25)
	if hud != null and hud.has_method("show_message"):
		hud.show_message("PERFECT START  ·  完美起步   +25% NITRO", UIStyle.GOLD, 2.0)


## 干净圈奖励：整圈不撞墙、离开路面不超过 1.5s，过线时补 18% 氮气。
## 让玩家在“拼圈速”之外多一个可追求的操作目标，也强化走线与刹车点练习。
func _update_lap_cleanliness(dt: float) -> void:
	if race == null or car == null:
		return
	if race.state != RaceManager.State.RACING:
		_last_player_laps = race.player_laps
		return
	if car.wall_impact > 2.2:
		_lap_wall_hits += 1
	if car.offroad:
		_lap_offroad += dt
	if race.player_laps <= _last_player_laps:
		return
	if _lap_wall_hits == 0 and _lap_offroad < 1.5:
		_clean_laps += 1
		car.add_nitro(0.18)
		if hud != null and hud.has_method("show_message"):
			hud.show_message("CLEAN LAP  ·  干净圈   +18% NITRO", UIStyle.GREEN, 1.8)
	_lap_wall_hits = 0
	_lap_offroad = 0.0
	_last_player_laps = race.player_laps


## 干净超车奖励氮气：提升名次时一次性充能，1.4s 冷却防止名次抖动刷分。
func _update_overtake_reward(dt: float) -> void:
	_overtake_cd = maxf(0.0, _overtake_cd - dt)
	if race == null or car == null:
		return
	if race.state == RaceManager.State.RACING and race.total_cars > 1 \
			and not race.player_finished:
		if _race_pos_prev > 0 and race.player_position < _race_pos_prev \
				and _overtake_cd <= 0.0:
			var gained := clampi(_race_pos_prev - race.player_position, 1, 3)
			car.add_nitro(0.055 * float(gained))
			_overtake_cd = 1.4
		_race_pos_prev = race.player_position
	else:
		_race_pos_prev = race.player_position


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
	# 白天太阳盘收小、光晕收弱：进场逆光时不再把天空和路面一起洗白。
	sky_material.set_shader_parameter("sun_size", 0.032 if not night else 0.022)
	sky_material.set_shader_parameter("sun_glow", 0.45 if not night else 0.3)
	sky_material.set_shader_parameter("haze_strength", 0.24)
	sky_material.set_shader_parameter("horizon_softness", 0.38)
	sky_material.set_shader_parameter("aurora_amount",
		clampf(float(theme.get("aurora", 0.0)), 0.0, 1.0))

	var hdri_used := false
	var sky := Sky.new()
	# 云层动画极慢，radiance 每帧全量重算 6 面 cubemap 纯属白烧 GPU；
	# 增量模式分几帧收敛，天空本体和反射观感不变（环境光本来就不采样天空）。
	sky.process_mode = Sky.PROCESS_MODE_INCREMENTAL
	var hdri_path := ""
	match String(def.get("id", "")):
		"coast":
			hdri_path = "res://maps/assets/polyhaven/hdri/kloofendal_48d_partly_cloudy_puresky_2k.hdr"
		"alpine":
			hdri_path = "res://maps/assets/polyhaven/hdri/kloofendal_43d_clear_puresky_2k.hdr"
		"glacier":
			hdri_path = "res://maps/assets/polyhaven/hdri/kloofendal_38d_partly_cloudy_puresky_2k.hdr"
		"drift":
			hdri_path = "res://maps/assets/polyhaven/hdri/kloofendal_43d_clear_puresky_2k.hdr"
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
			pano_mat.set_shader_parameter("sky_brightness", clampf(float(theme.get("skyBrightness", 0.72)), 0.3, 1.2))
			pano_mat.set_shader_parameter("aurora_amount",
				clampf(float(theme.get("aurora", 0.0)), 0.0, 1.0))
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
	# A/B：AgX 高光滚降更柔，白车/雪面不容易发死；默认仍用主题调好的 ACES。
	if OS.get_environment("APEX_Q_AGX") == "1":
		env.tonemap_mode = Environment.TONE_MAPPER_AGX
		env.tonemap_agx_contrast = clampf(float(theme.get("agxContrast", 1.12)), 1.0, 1.5)
		env.tonemap_agx_white = 8.0
		env.tonemap_exposure = clampf(float(theme.get("exposure", 1.05)) * 0.82, 0.55, 1.15)
	# 环境光统一用「主题天空色」做固定补光，而不是采样天空。
	# 原因：海岸/峡谷/熔岩用的是 HDRI 全景，转过身后半天空本身很暗，
	# 采样天空会让同一条赛道在某个朝向上整段掉进黑夜，亮度完全不可控。
	var amb_color := _c(theme.get("hemiSky", "#b4d8f8"), Color(0.70, 0.82, 0.95))
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = amb_color if not night else Color(0.34, 0.42, 0.66)
	# 夜间环境光提到 0.85：0.72 时暗面楼体/岩石会黑成一团剪影
	# 白天基准补光从 0.54 抬到 0.60：ACES 下暗面（山影里的路面、楼体背光面）
	# 原先黑成剪影，车和路面纹理全丢。主题仍可用 ambientEnergy 单独覆盖。
	env.ambient_light_energy = 0.85 if night else (0.66 if hdri_used else 0.60)
	# 主题可单独抬环境光：山谷在逆光山影里暗面会糊成剪影，纹理全丢。
	env.ambient_light_energy = clampf(
		float(theme.get("ambientEnergy", env.ambient_light_energy)), 0.2, 1.2)
	env.adjustment_enabled = true
	# 逐图调色：默认值与原全局值一致；主题可单独控制对比/饱和/亮度。
	env.adjustment_contrast = clampf(float(theme.get("gradeContrast", 1.24)), 1.0, 1.4)
	env.adjustment_saturation = clampf(
		float(theme.get("gradeSaturation", 1.18 if not night else 1.08)), 0.8, 1.6)
	env.adjustment_brightness = clampf(float(theme.get("gradeBrightness", 1.0)), 0.85, 1.2)
	# SSAO：逐图微调。城市/峡谷需要更深的接触阴影撑出体块，雪原要轻，
	# 否则纯白地面上 AO 会变成脏灰斑。默认仍是 1.6 / 2.6。
	env.ssao_radius = clampf(float(theme.get("ssaoRadius", 1.6)), 0.8, 3.2)
	env.ssao_intensity = clampf(float(theme.get("ssaoIntensity", 2.6)), 1.0, 4.0)
	env.ssao_power = 1.7
	env.ssao_sharpness = 0.98
	env.ssao_light_affect = 0.06
	env.ssr_enabled = true
	env.ssr_max_steps = 56
	env.ssr_fade_in = 0.12
	env.ssr_fade_out = 1.5
	env.ssr_depth_tolerance = 0.4
	env.ssil_enabled = true
	env.ssil_intensity = 1.15
	env.ssil_radius = 6.0
	env.ssil_sharpness = 0.98
	# SDFGI：静态峡谷/楼群的间接光反弹。只在 ULTRA 且主题允许时开（见 _apply_quality），
	# 统一压低能量，避免把已拍板的城市夜景整体提亮。
	env.sdfgi_enabled = false
	env.sdfgi_use_occlusion = true
	env.sdfgi_read_sky_light = true
	env.sdfgi_bounce_feedback = 0.40
	env.sdfgi_cascades = 3
	env.sdfgi_min_cell_size = 0.45
	env.sdfgi_max_distance = 170.0
	env.sdfgi_energy = 0.65
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.glow_enabled = true
	env.glow_intensity = clampf(float(theme.get("glowOpacity", 0.4)) * 1.1, 0.2, 1.2)
	env.glow_bloom = 0.08
	# 太阳/雪面/熔岩的 HDR 峰值很高，用主题的 glowHdr 抬高泛光门槛。
	# 霓虹夜城没有这个键 → 保持 1.0，亮度是用户拍板过的，不动。
	env.glow_hdr_threshold = clampf(float(theme.get("glowHdr", 1.0)), 1.0, 2.0)
	if not night:
		env.glow_hdr_threshold = maxf(env.glow_hdr_threshold, 1.32)
		env.glow_bloom = 0.045
	env.ssao_enabled = true
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
	env.fog_aerial_perspective = clampf(float(theme.get("aerial", 0.20)), 0.05, 0.6)
	# 低空雾层：晨雾/谷雾/海面薄雾贴着地表，远景山体有分层。
	env.fog_height = float(theme.get("fogHeight", 0.0))
	env.fog_height_density = clampf(float(theme.get("fogHeightDensity", 0.0)), -4.0, 4.0)
	# 雾朝太阳方向的散射，让落日天空与远山之间有暖色过渡。
	env.fog_sun_scatter = clampf(float(theme.get("fogSunScatter", 0.10)), 0.0, 1.0)
	# subtle atmosphere for sun shafts on clear days too
	var vol_theme := bool(theme.get("volumetric", true))
	env.volumetric_fog_enabled = vol_theme
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
		env.volumetric_fog_enabled = vol_theme
		# 沙尘只是薄霾：0.008 会把峡谷/熔岩压成剪影，dust 用轻一档
		_base_vol_density = 0.008 if (weather_kind == "rain" or weather_kind == "snow") else 0.0035
		env.volumetric_fog_density = _base_vol_density
		env.volumetric_fog_albedo = _c(theme.get("fogColor", "#c8e4ea"), Color(0.7, 0.78, 0.85)).darkened(0.25)
		env.volumetric_fog_emission = _c(theme.get("accent", "#ffffff"), Color(0.3, 0.6, 0.8)).darkened(0.7) * 0.25
		env.volumetric_fog_length = 260.0
		env.volumetric_fog_ambient_inject = 0.35
		env.volumetric_fog_sky_affect = 0.35
	env.volumetric_fog_anisotropy = clampf(
		float(theme.get("volumetricAnisotropy", 0.55)), 0.2, 0.9)
	# 雪原/冰湖的体积雾环境注入会抬平暗部岩壁，主题可单独压暗
	if theme.has("volAmbientInject"):
		env.volumetric_fog_ambient_inject = clampf(
			float(theme.get("volAmbientInject")), 0.0, 1.0)
	# 雪图默认 0.008 的密度会把近处岩壁糊成一片奶白，主题可按需减半
	if theme.has("volDensity"):
		_base_vol_density = clampf(float(theme.get("volDensity")), 0.0, 0.02)
		env.volumetric_fog_density = _base_vol_density
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
	# 光源角直径：0 是硬边阴影；半影柔化走 PCSS，实测 0.2° 就要 4% GPU。
	# 十图对比软/硬边观感差异很小，统一硬边 + shadow_blur 柔化，字段保留给个别主题按需开启。
	sun.light_angular_distance = clampf(float(theme.get("sunSoftness", 0.0)), 0.0, 5.0)
	sun.shadow_bias = 0.016
	sun.shadow_normal_bias = 1.1
	# 阴影边缘柔化：实测 1.35→2.6 没有可测帧率差（同一遍 PCF 采样），
	# 户外图默认更柔和，城内保持锐利以保住楼体投影轮廓。
	sun.shadow_blur = clampf(float(theme.get("shadowBlur", 1.35)), 0.0, 4.0)
	sun.shadow_opacity = 1.0
	sun.directional_shadow_blend_splits = false
	# 4 分裂会把整个可见场景画进 4 张阴影图：实测 M1 Pro 上阴影 pass
	# 占了一半以上的 draw call。赛车游戏远景阴影几乎看不到，改成 2 分裂 + 收短距离。
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	parent.add_child(sun)
	_sun = sun
	# 逐图效果预算：干燥晴天 SSR 只在车漆上可见，关掉省 6~7% GPU；
	# 湿滑/现代城市场景保留全量屏空间反射。
	_theme_ssr_allowed = bool(theme.get("ssr", true))
	_volumetric_allowed = vol_theme
	# SDFGI 实测在 1600×900 ULTRA 下吃掉约 23~25% 帧率，而 Canyon 的间接光收益
	# 只值回一部分，城市夜景还会整体提亮（用户拍板过亮度）。默认关闭，
	# 保留 APEX_Q_SDFGI=1 供高端机/截图对比使用。
	var sdfgi_tracks: Array[String] = []
	_theme_sdfgi_allowed = String(theme.get("name", "")) in sdfgi_tracks \
		and bool(theme.get("sdfgi", true))
	_apply_quality()


## 复用菜单/烘焙赛道时，把 _env/_sun 绑定到该世界，并补写逐图光照参数。
## 菜单场景是旧版本烘焙的 .scn，里面序列化的 SSAO/阴影参数不会自动更新。
## 逐图补光：太阳背面再放一盏无阴影的方向光，把背光岩壁/车侧从纯黑里拉回来。
## 不参与阴影投射，Forward+ 下开销很小；夜间城市刻意压到极低，避免破坏拍板亮度。
func _ensure_fill_light(root: Node3D, def: Dictionary) -> void:
	if root == null:
		return
	var theme: Dictionary = def.get("theme", {})
	var fill := root.find_child("FillLight", true, false) as DirectionalLight3D
	if fill == null:
		fill = DirectionalLight3D.new()
		fill.name = "FillLight"
		root.add_child(fill)
	var sun_dir: Array = theme.get("sunDir", [0.42, 0.52, 0.2])
	var fill_dir: Array = theme.get("fillDir", [
		-float(sun_dir[0]), 0.55, -float(sun_dir[2])])
	var dir := Vector3(float(fill_dir[0]), float(fill_dir[1]), float(fill_dir[2])).normalized()
	if dir.length_squared() < 0.001:
		dir = Vector3(-float(sun_dir[0]), 0.55, -float(sun_dir[2])).normalized()
	fill.transform = Transform3D(Basis.looking_at(-dir, Vector3.UP), Vector3.ZERO)
	fill.light_color = _c(String(theme.get("fillColor", "#bcd6ff")), Color(0.72, 0.84, 1.0))
	fill.light_energy = clampf(float(theme.get("fillPower", 0.0)), 0.0, 1.2)
	fill.shadow_enabled = false
	fill.light_specular = 0.25
	fill.visible = fill.light_energy > 0.001


func _bind_world_environment(root: Node3D, def: Dictionary) -> void:
	if root == null:
		return
	var theme: Dictionary = def.get("theme", {})
	var we := root.find_child("WorldEnvironment", true, false) as WorldEnvironment
	if we != null and we.environment != null:
		_env = we.environment
	var sun := root.find_child("Sun", true, false) as DirectionalLight3D
	if sun != null:
		_sun = sun
	# 烘焙场景里遗留的旧版展车聚光（能量 7）：进比赛后就是凭空多出的第二主光，
	# 直接隐藏。菜单侧由 _decorate_menu_scene 压到辅助级并顺太阳方向。
	for node in root.find_children("*", "SpotLight3D", true, false):
		node.visible = false
	if _env != null:
		_env.ssao_radius = clampf(float(theme.get("ssaoRadius", 1.6)), 0.8, 3.2)
		_env.ssao_intensity = clampf(float(theme.get("ssaoIntensity", 2.6)), 1.0, 4.0)
		# 逐图效果预算也要重建，否则缓存地图会沿用上一张图的 SSR/体积雾开关。
		_theme_ssr_allowed = bool(theme.get("ssr", true))
		_volumetric_allowed = bool(theme.get("volumetric", true))
		_theme_sdfgi_allowed = false
		_env.sdfgi_enabled = false
		_base_fog_color = _env.fog_light_color
		_base_fog_density = _env.fog_density
		_base_vol_density = _env.volumetric_fog_density
	if _sun != null:
		_sun.shadow_blur = clampf(float(theme.get("shadowBlur", 1.35)), 0.0, 4.0)


func _toggle_cone_editor() -> void:
	if cone_editor != null:
		_close_cone_editor()
		return
	if cone_field == null or car == null or track_path == null:
		return
	cone_editor = ConeEditor.new()
	cone_editor.name = "ConeEditor"
	cone_editor.setup(cone_field, car, track_path.field_half)
	cone_editor.closed.connect(_close_cone_editor)
	add_child(cone_editor)
	get_tree().paused = true


func _close_cone_editor() -> void:
	if cone_editor == null:
		return
	if cone_field != null:
		ConeStore.save_layout(cone_field.get_layout())
		if hud != null:
			hud.show_message("已保存 %d 个锥桶" % cone_field.positions.size(), UIStyle.GREEN, 1.8)
	cone_editor.queue_free()
	cone_editor = null
	get_tree().paused = false


## 比赛中直接进拍照（P / 十字左）：先冻结比赛，再切到自由机位。
## 退出时由 _on_photo_closed 回到暂停菜单。
func _open_race_photo() -> void:
	if state != AppState.RACE or race == null or race.state == RaceManager.State.RESULTS:
		return
	if photo_mode != null or pause_screen != null:
		return
	_open_pause()
	if pause_screen == null:
		return
	_on_pause_photo()


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
	pause_screen.photo_requested.connect(_on_pause_photo)
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
	_start_race(current_track_id, current_car_id, current_mode)


func _on_pause_settings() -> void:
	_close_pause()
	_open_settings()


## 拍照模式：树保持暂停（计时/AI 冻结），相机节点 PROCESS_MODE_ALWAYS。
func _on_pause_photo() -> void:
	if pause_screen != null:
		pause_screen.queue_free()
		pause_screen = null
	if hud != null:
		hud.visible = false
	photo_mode = PhotoModeScript.new()
	photo_mode.name = "PhotoMode"
	add_child(photo_mode)
	photo_mode.setup(cam, car)
	photo_mode.closed.connect(_on_photo_closed)


func _on_photo_closed() -> void:
	photo_mode = null
	if hud != null:
		hud.visible = true
	# 树一直处于暂停状态，退出拍照后回到暂停菜单。
	_open_pause()


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
	# 键位提示等开关在设置里改动后，回到菜单立即生效。
	if state == AppState.MENU and menu != null and is_instance_valid(menu):
		menu.refresh()


func apply_quality_now() -> void:
	_apply_quality()
	if state == AppState.MENU and menu_world != null:
		_menu_apply_render_stability()


func _apply_quality() -> void:
	var q := Settings.preset()
	var preset_id := String(q["id"])
	var scale_mode: int = Viewport.SCALING_3D_MODE_BILINEAR
	# 渲染预算审计：只在 APEX_PERF_OVERRIDE=1 时启用，逐项覆盖画质参数。
	# 用法例：APEX_PERF_OVERRIDE=1 APEX_Q_SSIL=0 APEX_Q_VOL=0 Godot ... --perf-test
	if OS.get_environment("APEX_PERF_OVERRIDE") == "1":
		q = q.duplicate()
		for pair in [
			["APEX_Q_SCALE", "scale"],
			["APEX_Q_SSR_STEPS", "ssr_steps"],
			["APEX_Q_SHADOW_DIST", "shadow_dist"],
			["APEX_Q_SHADOW_ATLAS", "shadow_atlas"],
			["APEX_Q_SHADOW_FILTER", "shadow_filter"],
			["APEX_Q_LOD_BIAS", "lod_bias"],
		]:
			var env_value := OS.get_environment(String(pair[0]))
			if env_value.is_valid_float():
				q[String(pair[1])] = float(env_value)
				print("[Q-OVERRIDE] %s=%s" % [String(pair[1]), env_value])
		for pair in [
			["APEX_Q_SSR", "ssr"],
			["APEX_Q_SSAO", "ssao"],
			["APEX_Q_SSIL", "ssil"],
			["APEX_Q_VOL", "vol"],
			["APEX_Q_TAA", "taa"],
		]:
			var flag := OS.get_environment(String(pair[0]))
			if flag == "0" or flag == "1":
				q[String(pair[1])] = flag == "1"
	CityFacadesScript.set_detail(Settings.index)
	var vp := get_viewport()
	var temporal := false
	var perf_override := OS.get_environment("APEX_PERF_OVERRIDE") == "1"
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
		if custom_scale != null and not perf_override:
			scale = clampf(float(custom_scale), 0.5, 1.0)
		# HiDPI 像素预算：Retina 上 3D 缓冲按物理像素算，1600×900 窗口实际是
		# 3200×1800。按档位把 3D 分辨率限制为「逻辑分辨率 × logical_scale」，
		# 剩下的清晰度交给升频器；这是高档 28fps → 60fps 的关键一步。
		# 1× 屏同样要按档位降分辨率，否则低档在普通显示器上等于满分辨率渲染。
		var hidpi := maxf(DisplayServer.screen_get_scale(), 1.0)
		if not perf_override:
			scale = minf(scale, Settings.logical_scale() / hidpi)
		var want := Settings.upscale
		if perf_override and not OS.get_environment("APEX_Q_UPSCALE").is_empty():
			want = OS.get_environment("APEX_Q_UPSCALE")
		# 大画布（Retina 全屏 / 4K）下，MetalFX/FSR2 的时间升频输出尺寸等于
		# 整个根视口画布。实测 macOS 3456×2160 全屏时升频后画布达 31MP，
		# 固定多吃 ~7ms：同 0.70 缩放，时间升频 54fps，空间路径 87fps。
		# 所以 auto 档在大画布上改走「稍高内部分辨率 + 双线性/FXAA」，
		# 画质不降反升（0.85 vs 0.70），帧率也更高。
		var win_px := Vector2i(1600, 900)
		if DisplayServer.get_name() != "headless":
			win_px = DisplayServer.window_get_size()
		var big_canvas := maxi(win_px.x, win_px.y) >= 2400
		# 玩家手动把渲染比例调到 1.0 以下时尊重他的选择，不再为了清晰度抬回去。
		var user_scale: Variant = Settings.get("render_scale")
		var allow_big_raise: bool = user_scale == null or float(user_scale) >= 0.99
		# 只在 Metal 时间升频上做这个切换：Windows/Linux 的 FSR2 输出成本曲线不同，
		# 保持原路径，避免为了 macOS 的固定开销误伤其它平台。
		if big_canvas and allow_big_raise and want == "auto" and not perf_override \
				and PlatformProfile.supports_metalfx():
			want = "off"
			scale = maxf(scale, clampf(float(q.get("big_scale", scale)), 0.4, 0.95))
		# 只在真的降分辨率时才启用升频器；原生分辨率下时间升频纯属白烧 GPU。
		# macOS 走 MetalFX，桌面走 FSR2；TAA 与时间升频不叠加，避免双重累积。
		if want != "off" and scale < 0.99:
			if PlatformProfile.supports_metalfx():
				# auto/on 都走时间升频：同分辨率下比空间升频干净得多，
				# 实测 M1 Pro 在 120 帧上限内没有帧率代价。
				scale_mode = Viewport.SCALING_3D_MODE_METALFX_TEMPORAL
				temporal = true
			elif PlatformProfile.supports_fsr2():
				scale_mode = Viewport.SCALING_3D_MODE_FSR2
				temporal = true
		if temporal:
			# 时间升频自带 AA；空间升频需要 FXAA 补边缘。
			vp.msaa_3d = Viewport.MSAA_DISABLED
		else:
			vp.msaa_3d = Settings.msaa_mode()
		if big_canvas and not perf_override:
			# 大画布上 4×MSAA 等于把 8MP 画布再乘 4；空间路径统一交给 FXAA。
			vp.msaa_3d = Viewport.MSAA_DISABLED
		if perf_override:
			var msaa_env := OS.get_environment("APEX_Q_MSAA")
			if msaa_env.is_valid_int():
				vp.msaa_3d = int(msaa_env) as Viewport.MSAA
				print("[Q-OVERRIDE] msaa=%s" % msaa_env)
		vp.scaling_3d_mode = scale_mode
		vp.scaling_3d_scale = scale
		# 网格 LOD 激进程度：阈值越大，远处模型越早切低模。低档把远景三角形
		# 砍掉大半，高档保持接近默认，超高档更晚切 LOD 保住轮廓。
		vp.mesh_lod_threshold = float(q.get("lod_threshold", 1.0))
		if perf_override and OS.get_environment("APEX_Q_LOD_THRESHOLD").is_valid_float():
			vp.mesh_lod_threshold = float(OS.get_environment("APEX_Q_LOD_THRESHOLD"))
		vp.use_taa = bool(q.get("taa", false)) and not temporal
		vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA \
			if vp.msaa_3d == Viewport.MSAA_DISABLED and not temporal and not vp.use_taa \
			else Viewport.SCREEN_SPACE_AA_DISABLED
		vp.use_debanding = true
		if perf_override and OS.get_environment("APEX_Q_OVERSAMPLE").is_valid_float():
			vp.oversampling_override = float(OS.get_environment("APEX_Q_OVERSAMPLE"))
		governor.reset_for_quality(scale, vp)
	# 阴影预算按档位走：低档小图集 + 硬阴影省 GPU，超高档大图 + 高质量软阴影。
	# 以前全档位共用 project.godot 的 8192 图集，低档白白画一张大阴影图。
	var shadow_atlas := int(q.get("shadow_atlas", Settings.shadow_atlas()))
	var shadow_filter := int(q.get("shadow_filter", Settings.shadow_filter()))
	RenderingServer.directional_shadow_atlas_set_size(shadow_atlas, shadow_filter)
	if _env != null:
		# 性能审计开关：临时强制覆盖逐图效果预算（仅 APEX_PERF_OVERRIDE=1 生效）。
		var ssr_allowed := _theme_ssr_allowed
		var vol_allowed := _volumetric_allowed
		# 直接 A/B：不跑性能覆盖也能单独开关逐图 SSR。
		var theme_ssr_flag := OS.get_environment("APEX_Q_THEME_SSR")
		if theme_ssr_flag == "1":
			ssr_allowed = true
		elif theme_ssr_flag == "0":
			ssr_allowed = false
		if perf_override:
			var ssr_flag := OS.get_environment("APEX_Q_THEME_SSR")
			if ssr_flag == "0" or ssr_flag == "1":
				ssr_allowed = ssr_flag == "1"
			var vol_flag := OS.get_environment("APEX_Q_THEME_VOL")
			if vol_flag == "0" or vol_flag == "1":
				vol_allowed = vol_flag == "1"
		_env.ssr_enabled = bool(q["ssr"]) and ssr_allowed
		_env.ssr_max_steps = int(q["ssr_steps"])
		_env.ssao_enabled = bool(q["ssao"])
		_env.ssil_enabled = bool(q["ssil"])
		# SDFGI 只给 ULTRA + 封闭静态地貌；APEX_Q_SDFGI=0/1 可做 A/B 对照。
		var sdfgi_want := preset_id == "ultra" and _theme_sdfgi_allowed
		var sdfgi_flag := OS.get_environment("APEX_Q_SDFGI")
		if sdfgi_flag == "1":
			sdfgi_want = true
		elif sdfgi_flag == "0":
			sdfgi_want = false
		_env.sdfgi_enabled = sdfgi_want
		_env.volumetric_fog_enabled = vol_allowed and bool(q["vol"])
		# 抬 AO 对直射光的响应（纯 uniform，不增加采样）：车底、墙角在阳光里
		# 也有暗部收紧，接触阴影更实，物体不再像贴在路面上。
		_env.ssao_light_affect = 0.16 if preset_id == "ultra" else (0.10 if preset_id == "high" else 0.06)
		# 最弱的那层泛光（1/16 分辨率）对画面几乎不可见，却要多走一遍升降采样。
		# 必须显式写回 1.0：只写 0 的话，从高档切回超高后这一层永远不会恢复。
		_env.set("glow_levels/4", 1.0 if preset_id == "ultra" else 0.0)
		var use_glow_map := (preset_id == "high" or preset_id == "ultra") \
			and OS.get_environment("APEX_Q_GLOW_MAP") != "0"
		_env.glow_map = _lens_dirt_texture() if use_glow_map else null
		_env.glow_map_strength = 0.35 if preset_id == "ultra" else 0.22
		if perf_override:
			var glow_flag := OS.get_environment("APEX_Q_GLOW")
			if glow_flag == "0" or glow_flag == "1":
				_env.glow_enabled = glow_flag == "1"
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
		# 逐图阴影预算：森林/雪山这类远景被树冠挡死的地图，420m 阴影只在
		# 看不见的远处烧 GPU；按主题收短到 300~400m，画面几乎无感。
		var shadow_mul := clampf(
			float(track_def.get("theme", {}).get("shadowDistMul", 1.0)), 0.5, 1.2)
		_sun.directional_shadow_max_distance = float(q["shadow_dist"]) * shadow_mul
		if perf_override:
			var soft_env := OS.get_environment("APEX_Q_SUNSOFT")
			if soft_env.is_valid_float():
				_sun.light_angular_distance = clampf(float(soft_env), 0.0, 5.0)
				print("[Q-OVERRIDE] sun_softness=%s" % soft_env)
			var blur_env := OS.get_environment("APEX_Q_SHADOWBLUR")
			if blur_env.is_valid_float():
				_sun.shadow_blur = clampf(float(blur_env), 0.0, 4.0)
				print("[Q-OVERRIDE] shadow_blur=%s" % blur_env)
		# 超高：两级阴影级联之间混合过渡，远处阴影边界不再有硬切换线
		_sun.directional_shadow_blend_splits = preset_id == "ultra"
	if streamer != null:
		streamer.max_distance = Settings.far_distance()
		streamer.prefetch_strength = 1.35 if preset_id == "ultra" else (1.15 if preset_id == "high" else 0.9)
	_apply_lod_bias_all()
	if perf_override and OS.get_environment("APEX_Q_LOD_BIAS").is_valid_float():
		_apply_lod_bias_all(float(OS.get_environment("APEX_Q_LOD_BIAS")))
	_sync_post_params()
	print("[QUALITY] %s  缩放 %.2f  %s  LOD %.1f  锐化 %.2f  远景 %.2f" % [
		preset_id, governor.scale,
		("MetalFX/FSR2 时间升频" if temporal else ("空间升频" if scale_mode != Viewport.SCALING_3D_MODE_BILINEAR else "无升频")),
		vp.mesh_lod_threshold if vp != null else 1.0,
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


## 逐图电影调色参数：theme 留空 = 中性（菜单/车库保持原样）。
## 只蓝本色相，曝光与亮度继续由环境/主题控制，避免动到已拍板的夜城亮度。
func _set_post_grade(theme: Dictionary) -> void:
	# 视觉审计开关：APEX_Q_GRADE=0 可逐图对比调色前后（不写存档）。
	if OS.get_environment("APEX_Q_GRADE") == "0":
		theme = {}
	var mix := clampf(float(theme.get("gradeMix", 0.0)), 0.0, 1.0)
	var grain := clampf(float(theme.get("filmGrain", 0.0)), 0.0, 0.05)
	# 电影暗角：比赛逐图默认 0.12（只压四角、中心亮度不变），菜单/空主题不加。
	_post_vignette = 0.0 if theme.is_empty() else clampf(float(theme.get("vignette", 0.16)), 0.0, 0.5)
	if mix <= 0.001 and grain <= 0.0005:
		_post_grade = {}
		_post_grade_active = false
	else:
		_post_grade = {
			"mix": mix,
			"temp": clampf(float(theme.get("gradeTemp", 0.0)), -1.0, 1.0),
			"shadow": _c(String(theme.get("gradeShadow", "")), Color(0.0, 0.0, 0.0)),
			"highlight": _c(String(theme.get("gradeHighlight", "")), Color(1.0, 1.0, 1.0)),
			"grain": grain,
		}
		_post_grade_active = true
	_sync_post_params()


func _sync_post_params() -> void:
	if motion_blur_mat == null or get_viewport() == null:
		return
	var size := Vector2(get_viewport().size)
	# 3D 内部分辨率越低，升频后的软化越明显：按比例补一点锐化（最多 +45%），
	# 让 0.4~0.5 渲染倍数下的画面仍然利落。纯 uniform 更新，不触发管线重建。
	var scale_k := clampf(governor.scale, 0.32, 1.0) if governor.cap > 0.0 else 1.0
	var sharp_boost := 1.0 + clampf((0.75 - scale_k) * 1.15, 0.0, 0.45)
	motion_blur_mat.set_shader_parameter("sharpen",
		clampf(Settings.sharpen * sharp_boost, 0.0, 0.85))
	motion_blur_mat.set_shader_parameter("taps", Settings.blur_taps())
	motion_blur_mat.set_shader_parameter("texel", Vector2(
		1.0 / maxf(size.x, 1.0), 1.0 / maxf(size.y, 1.0)))
	motion_blur_mat.set_shader_parameter("resolution", size)
	motion_blur_mat.set_shader_parameter("grade_mix", float(_post_grade.get("mix", 0.0)))
	motion_blur_mat.set_shader_parameter("grade_temp", float(_post_grade.get("temp", 0.0)))
	motion_blur_mat.set_shader_parameter("grade_shadow",
		_post_grade.get("shadow", Color(0.0, 0.0, 0.0)))
	motion_blur_mat.set_shader_parameter("grade_highlight",
		_post_grade.get("highlight", Color(1.0, 1.0, 1.0)))
	motion_blur_mat.set_shader_parameter("film_grain", float(_post_grade.get("grain", 0.0)))
	motion_blur_mat.set_shader_parameter("vignette", _post_vignette)
	if motion_blur_rect != null:
		motion_blur_rect.visible = Settings.sharpen > 0.001 or _last_blur_amount > 0.004 \
			or _post_grade_active or _post_vignette > 0.001


## 换画质档时把全场几何的 LOD 偏移同步到当前档位：
## 低档 <1 让车/树/建筑更早切低模省帧率，超高档 >1 把满精度模型留到更远。
## 新建场景里的物件在摆放入口（RealAssetKit / CarVisual）按当前档写入初始值。
func _apply_lod_bias_all(bias_override: float = -1.0) -> void:
	var bias := Settings.lod_bias() if bias_override < 0.0 else bias_override
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
		motion_blur_rect.visible = amount > 0.004 or Settings.sharpen > 0.001 \
			or _post_grade_active or _post_vignette > 0.001


static var _lens_dirt_cache: Texture2D = null


## 程序化镜头脏污：低频噪声 + 少量压暗斑，喂给 Environment.glow_map，
## 让霓虹/路灯的 bloom 带一点镜头污渍，而不是一圈干净的圆形光晕。
static func _lens_dirt_texture() -> Texture2D:
	if _lens_dirt_cache != null:
		return _lens_dirt_cache
	var size := 256
	var noise := FastNoiseLite.new()
	noise.seed = 20261111
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.011
	noise.fractal_octaves = 3
	noise.fractal_gain = 0.55
	var img := Image.create(size, size, false, Image.FORMAT_RGB8)
	for y in size:
		for x in size:
			var n := noise.get_noise_2d(float(x), float(y)) * 0.5 + 0.5
			var smudge := smoothstep(0.30, 0.78, n)
			var v := lerpf(0.55, 1.0, smudge)
			img.set_pixel(x, y, Color(v, v, v))
	img.generate_mipmaps()
	_lens_dirt_cache = ImageTexture.create_from_image(img)
	return _lens_dirt_cache


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
		elif arg.begins_with("--drive-probe="):
			_drive_probe_time = float(arg.substr(14))
		elif arg == "--tune":
			_tune_demo = true
		elif arg == "--perf-test":
			_perf_mode = true
		elif arg == "--analog-test":
			_analog_test_mode = true
		elif arg == "--drift-test":
			_drift_test_mode = true


func _track_or_default() -> String:
	return _arg_track if not _arg_track.is_empty() else DEFAULT_TRACK


func _car_or_default() -> String:
	return _arg_car if not _arg_car.is_empty() else DEFAULT_CAR


func _mode_or_default() -> String:
	return _arg_mode if _arg_mode in ["gp", "ta", "duel"] else "gp"


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
	# 负油门（磁轴 S 键 → 刹车/倒车）：带符号深度必须保留到车辆输入
	AnalogInput.set_debug_values(0.0, -0.8)
	var reverse_input := {}
	for i in 14:
		await get_tree().create_timer(0.02).timeout
		reverse_input = InputSetup.read_drive_input()
	AnalogInput.clear_debug_values()
	print("[M1] analog depth(0.00, -0.80) → steer=%.2f throttle=%.2f" % [
		float(reverse_input.get("steer", 0.0)), float(reverse_input.get("throttle", 0.0))])
	if float(reverse_input.get("throttle", 0.0)) > -0.55:
		failures.append("analog negative throttle lost (reverse)")
	Settings.analog_curve_steer = steer_curve_backup
	Settings.analog_curve_throttle = throttle_curve_backup
	Settings.analog_deadzone = deadzone_backup
	Settings.analog_input_enabled = analog_enabled_backup

	print("[M1] === car collision (OBB 按 manifest 车宽车长) ===")
	var half_m3 := CarContacts.half_extents("bmw_m3_e46_gtr")
	var half_gl8 := CarContacts.half_extents("buick_gl8")
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
		var res := CarContacts.obb_mtv(pr[0], pr[1], half_m3, pr[2], pr[3], half_m3)
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
		# 实景城市（metro）的路面/楼群来自 CityWorld 模型，TrackBuilder 只补
		# 起跑线 + 发车格两个网格；开放漂移场地只有柏油 + 草地两块，
		# 用程序化赛道的 4 网格门槛会误报。
		var open_field := bool(def.get("openField", false))
		var min_meshes := 2 if (bool(def.get("realCity", false)) or open_field) else 4
		if mesh_count < min_meshes:
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
		if not open_field and int(scenery_stats["instances"]) < 40:
			failures.append("M3: track %s scenery only %d instances" % [String(def.get("id", "?")), int(scenery_stats["instances"])])
		if travelled < 80.0:
			failures.append("track %s: car only travelled %.1fm in 10s" % [String(def.get("id", "?")), travelled])
	probe.queue_free()

	print("[M1] === full GP race: coast, 3 laps, 3 AI ===")
	_start_race("coast", DEFAULT_CAR, "gp")
	await _await_race_ready()
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
			var sector_ok := race.best_sector_times.size() == RaceManager.SECTOR_COUNT
			if sector_ok:
				for split in race.best_sector_times:
					if float(split) <= 0.0:
						sector_ok = false
			if not sector_ok:
				failures.append("sector best times incomplete: %s" % str(race.best_sector_times))
			else:
				var last_sum := 0.0
				for split in race.last_sector_times:
					last_sum += maxf(0.0, float(split))
				print("[M1] sectors best=%s last=%s sum=%.3fs lap=%s" % [
					str(race.best_sector_times), str(race.last_sector_times),
					last_sum, RaceManager.format_time(race.last_lap_time)])
				if race.last_sector_times.size() == RaceManager.SECTOR_COUNT \
						and float(race.last_sector_times[0]) > 0.0 \
						and float(race.last_sector_times[1]) > 0.0 \
						and float(race.last_sector_times[2]) > 0.0 \
						and absf(last_sum - race.last_lap_time) > 0.05:
					failures.append("sector sum %.3fs != last lap %.3fs" % [last_sum, race.last_lap_time])
				if race.record_summary.get("best_sectors", []).is_empty():
					failures.append("records.json did not persist best sectors")
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
	var ps_prof := ProfileStore
	var profile_backup: Dictionary = ps_prof.load_profile()
	var verify_profile := profile_backup.duplicate(true)
	verify_profile["xp"] = maxi(int(verify_profile.get("xp", 0)), 200000)
	verify_profile["xp_spent"] = 0
	# 成就进度清空，避免玩家已有记录让「首次解锁」断言失效。
	verify_profile["achievements"] = {}
	verify_profile["driven_cars"] = {}
	verify_profile["car_total"] = 46
	ps_prof.save_profile(verify_profile)
	# 免费改装下玩家存档里可能已经满级；不清零的话「升 5 级」会直接封顶 10，
	# 后面的 save/load 断言就随存档漂移。测试从 0 级起步，结束由 garage_backup 还原。
	var test_cfg := Garage.config(car_id)
	test_cfg["spent"] = {}
	for key in Garage.UPGRADE_KEYS:
		test_cfg[key] = 0
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
	# 真经济：扣款必须真实生效，超额消费必须拒绝且不改变余额。
	var balance_before: int = ps_prof.credit_balance()
	var spend_ok: bool = ps_prof.spend_credits(25)
	var balance_after: int = ps_prof.credit_balance()
	if not spend_ok or balance_after != balance_before - 25:
		failures.append("M2: real economy spend did not deduct balance")
	var overdraft: bool = ps_prof.spend_credits(balance_after + 1)
	if overdraft or ps_prof.credit_balance() != balance_after:
		failures.append("M2: overdraft should be rejected without changing balance")
	print("[M2] economy: balance %d -> %d  overdraft=%s" % [
		balance_before, balance_after, str(overdraft)])
	# 车辆收藏：首次驾驶 +40 XP，重复不加；5 / 15 / 全车系解锁成就。
	var car_first: Dictionary = ps_prof.mark_car_driven("probe_car_0", 46)
	var car_repeat: Dictionary = ps_prof.mark_car_driven("probe_car_0", 46)
	var garage5: Dictionary = {}
	for i in range(1, 5):
		garage5 = ps_prof.mark_car_driven("probe_car_%d" % i, 46)
	var garage_all: Dictionary = {}
	for i in range(5, 46):
		garage_all = ps_prof.mark_car_driven("probe_car_%d" % i, 46)
	var g5_ok := false
	for a in garage5.get("achievements", []):
		if String(a.get("id", "")) == "garage_5":
			g5_ok = true
	var gall_ok := false
	for a in garage_all.get("achievements", []):
		if String(a.get("id", "")) == "garage_all":
			gall_ok = true
	if int(car_first.get("xp_gain", 0)) < 40:
		failures.append("M2: first drive gave no XP")
	if int(car_repeat.get("xp_gain", 0)) != 0:
		failures.append("M2: repeated drive should not give XP")
	if not g5_ok:
		failures.append("M2: garage 5-car achievement missing")
	if not gall_ok:
		failures.append("M2: garage all-cars achievement missing")
	print("[M2] garage collection: first=+%d repeat=+%d 5car=%s all=%s" % [
		int(car_first.get("xp_gain", 0)), int(car_repeat.get("xp_gain", 0)),
		str(g5_ok), str(gall_ok)])
	_clear_race()
	ps_prof.save_profile(profile_backup)
	_start_race("coast", car_id, "gp")
	await _await_race_ready()
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
	await _await_race_ready()
	if car != null and car.model != null:
		var headlights := car.model.find_children("Headlight*", "", true, false).size()
		var ai_lights := 0
		for rival in ais:
			if rival != null and rival.model != null:
				ai_lights += rival.model.find_children("Headlight_*", "", true, false).size()
		print("[M3] night race (city): headlights=%d ai=%d/%d scenery=%s" % [
			headlights, ai_lights, ais.size() * 2, str(race != null)])
		if headlights != 2:
			failures.append("M3: night car headlights %d/2" % headlights)
		if ai_lights != ais.size() * 2:
			failures.append("M3: night AI headlights %d/%d" % [ai_lights, ais.size() * 2])
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
				contacts.resolve()
			var sep := Vector2(car.pos.x - ai0.pos.x, car.pos.z - ai0.pos.z).length()
			print("[M3] car contact: separation after forced overlap = %.2fm" % sep)
			if sep < 1.8:
				failures.append("M3: car-car contact resolution failed (%.2fm)" % sep)
			# 防粘 + 防闪现：朝对方给 8m/s 的接触速度，解算一帧后位移必须很小、且已产生分离速度
			car.pos = ai0.pos + Vector3(0.32, 0.0, 0.18)
			car.vel = Vector3.ZERO
			var ai_half_t := CarContacts.half_extents(String(ai0.spec.get("id", "")))
			var car_half_t := CarContacts.half_extents(current_car_id)
			var probe_hit := CarContacts.obb_mtv(Vector2(car.pos.x, car.pos.z), car.heading, car_half_t,
				Vector2(ai0.pos.x, ai0.pos.z), ai0.heading, ai_half_t)
			if probe_hit["hit"]:
				var nn: Vector2 = probe_hit["normal"]
				var n3t := Vector3(nn.x, 0.0, nn.y)
				car.vel = -n3t * 8.0  # 朝对方压过去
				var max_move := 0.0
				for k in 18:
					var pos_before := car.pos
					contacts.resolve()
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
					contacts.resolve()
					var af := track_path.frame_at(aa.dist)
					aa.pos = (af["pos"] as Vector3) + (af["side"] as Vector3) * aa.offset
					aa.heading = atan2((af["tangent"] as Vector3).x, (af["tangent"] as Vector3).z)
					var bf := track_path.frame_at(bb.dist)
					bb.pos = (bf["pos"] as Vector3) + (bf["side"] as Vector3) * bb.offset
					bb.heading = atan2((bf["tangent"] as Vector3).x, (bf["tangent"] as Vector3).z)
				var half_aa := CarContacts.half_extents(String(aa.spec.get("id", "")))
				var half_bb := CarContacts.half_extents(String(bb.spec.get("id", "")))
				var residual := CarContacts.obb_mtv(Vector2(aa.pos.x, aa.pos.z), aa.heading, half_aa,
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
			contacts.resolve()
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


## 帧间隔分布诊断：APEX_FRAME_LOG=1 时自 race-ready 起采集 15s，
## 分「入场/倒计时」与「比赛」两段打印分位数与超时帧数（不参与正式逻辑）。
func _print_frame_stats() -> void:
	for pair in [["intro", _frame_log_intro], ["race", _frame_log_race]]:
		var samples: Array = (pair[1] as Array).duplicate()
		var n := samples.size()
		if n == 0:
			continue
		samples.sort()
		var c17 := 0
		var c20 := 0
		var c25 := 0
		var c33 := 0
		var c50 := 0
		for v in samples:
			var ms := float(v) * 1000.0
			if ms > 16.7:
				c17 += 1
			if ms > 20.0:
				c20 += 1
			if ms > 25.0:
				c25 += 1
			if ms > 33.0:
				c33 += 1
			if ms > 50.0:
				c50 += 1
		print("[FRAME] %s n=%d p50=%.1f p90=%.1f p99=%.1f max=%.1f ms | >16.7=%d >20=%d >25=%d >33=%d >50=%d" % [
			String(pair[0]), n,
			float(samples[int(n * 0.50)]) * 1000.0,
			float(samples[int(n * 0.90)]) * 1000.0,
			float(samples[int(n * 0.99)]) * 1000.0,
			float(samples[n - 1]) * 1000.0,
			c17, c20, c25, c33, c50])


func _perf_tick(dt: float) -> void:
	if state != AppState.RACE:
		return
	_perf_time += dt
	_perf_sample_timer += dt
	var vp := get_viewport()
	if not _perf_measure_on:
		RenderingServer.viewport_set_measure_render_time(vp.get_viewport_rid(), true)
		_perf_measure_on = true
	if _perf_sample_timer >= 0.1 and _perf_time > 2.5:
		_perf_sample_timer = 0.0
		_perf_samples.append(float(Engine.get_frames_per_second()))
		_perf_drawcalls.append(float(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)))
		_perf_triangles.append(float(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)))
		_perf_proc_us.append(float(Performance.get_monitor(Performance.TIME_PROCESS)))
		_perf_phys_us.append(float(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)))
		_perf_render_cpu.append(RenderingServer.viewport_get_measured_render_time_cpu(vp.get_viewport_rid()))
		_perf_render_gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(vp.get_viewport_rid()))
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
	var cpu_ms := 0.0
	var gpu_ms := 0.0
	for i in _perf_proc_us.size():
		proc_ms += _perf_proc_us[i]
		phys_ms += _perf_phys_us[i]
		if i < _perf_render_cpu.size():
			cpu_ms += _perf_render_cpu[i]
			gpu_ms += _perf_render_gpu[i]
	var m := maxi(1, _perf_proc_us.size())
	var q := Settings.preset()
	var shadow_atlas := int(q.get("shadow_atlas", 0))
	print("[PERF] track=%s car=%s mode=%s preset=%s vsync_off" % [
		current_track_id, current_car_id, current_mode, String(Settings.PRESETS[Settings.index]["id"])])
	print("[PERF] fps avg=%.1f min=%.1f | frame %.2f ms | draw_calls avg=%.0f | primitives avg=%.0f" % [
		fps_sum / float(n), fps_min, 1000.0 / maxf(fps_sum / float(n), 0.001),
		draw_sum / float(n), tri_sum / float(n)])
	print("[PERF] render_cpu avg=%.2f ms | render_gpu avg=%.2f ms | script avg=%.2f ms | physics avg=%.2f ms" % [
		cpu_ms / float(m), gpu_ms / float(m), proc_ms / float(m), phys_ms / float(m)])
	print("[PERF] viewport=%dx%d win=%dx%d tex=%dx%d oversample=%.2f screen_scale=%.2f scale_3d=%.2f msaa=%d taa=%s shadow_atlas=%d shadow_dist=%.0f" % [
		vp.get_visible_rect().size.x, vp.get_visible_rect().size.y,
		DisplayServer.window_get_size().x, DisplayServer.window_get_size().y,
		vp.get_texture().get_size().x, vp.get_texture().get_size().y,
		vp.get_oversampling(), DisplayServer.screen_get_scale(),
		vp.scaling_3d_scale, vp.msaa_3d, str(vp.use_taa), shadow_atlas,
		_sun.directional_shadow_max_distance if _sun != null else 0.0])
	print("[PERF] allow_hidpi=%s content_scale_size=%s factor=%.2f" % [
		str(ProjectSettings.get_setting("display/window/dpi/allow_hidpi", false)),
		str(get_window().content_scale_size), get_window().content_scale_factor])
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
