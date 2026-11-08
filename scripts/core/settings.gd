extends Node
## 统一设置中心 v2：画质档 + 画面细项 + 显示（分辨率/帧率/垂直同步）
## + 音频分轨（Master/Music/Engine/Wind/SFX/UI）+ 操作 + 游戏/HUD。
## 全部持久化到 user://settings.json。
##
## 兼容性约定（main.gd / audio_manager.gd 依赖，不可破坏）：
##   preset() / msaa_mode() / content_scale() / particle_scale() / far_distance()
##   name_text() / set_quality() / cycle() / set_value() / set_selection()
##   reset_defaults() / save_settings() / load_settings()
##   index / bgm_enabled / bgm_volume / engine_volume / motion_blur / sharpen
##   far_clarity / upscale / last_track / last_car / last_mode
##   PRESETS / FAR_BASE / AUDIO_KEYS / signals changed, audio_changed
##
## 新增（main.gd 由 Lead 接入，或调用 Settings.apply_display() 即可）：
##   fps_limit:int(0=不限) / window_width:int / window_height:int
##   window_mode:String(windowed|fullscreen|borderless)
##   render_scale:float(0.5..1.0) 覆盖预设 scale（经 preset() 合并，无需改 main）
##   msaa:int / taa:bool / ssr:bool / ssao:bool / ssil:bool / volumetric:bool
##   motion_blur_enabled:bool / vignette:bool
##   master_volume / music_volume / wind_volume / sfx_volume / ui_volume
##   hud_minimap / hud_tach / hud_speed / hud_hints / hud_units / show_fps
##   steer_sensitivity / camera_shake / laps_override
##   apply_display() / apply_audio_buses() / bus_name_for(key) / get_volume(key)

const PlatformProfile := preload("res://scripts/core/platform_profile.gd")

const PRESETS: Array[Dictionary] = [
	{
		"id": "low", "name": "低 LOW", "scale": 0.70, "msaa": 0, "taa": false,
		"ssr": false, "ssr_steps": 16, "ssao": false, "ssil": false, "tree_shadows": false,
		"vol": false, "shadow_dist": 120.0, "fog_scale": 0.7,
		"content": 0.35, "particles": 0.35,
		# 低档省帧率：小阴影图集 + 硬阴影（省掉 PCF 软采样）、模型更早切低模、
		# 动态模糊减半采样、天空反射缓存降一档
		"shadow_atlas": 2048, "shadow_filter": 0, "lod_bias": 0.5,
		"blur_taps": 6, "sky_radiance": Sky.RADIANCE_SIZE_256, "cloud_octaves": 3, "cloud_detail": 0.0,
	},
	{
		"id": "medium", "name": "中 MEDIUM", "scale": 0.85, "msaa": 0, "taa": false,
		"ssr": true, "ssr_steps": 32, "ssao": true, "ssil": false, "tree_shadows": false,
		"vol": false, "shadow_dist": 220.0, "fog_scale": 0.9,
		"content": 0.6, "particles": 0.6,
		"shadow_atlas": 4096, "shadow_filter": 2, "lod_bias": 0.8,
		"blur_taps": 8, "sky_radiance": Sky.RADIANCE_SIZE_512, "cloud_octaves": 4, "cloud_detail": 1.0,
	},
	{
		"id": "high", "name": "高 HIGH", "scale": 1.0, "msaa": 2, "taa": true,
		"ssr": true, "ssr_steps": 64, "ssao": true, "ssil": true, "tree_shadows": false,
		"vol": true, "shadow_dist": 240.0, "fog_scale": 1.0,
		"content": 1.0, "particles": 1.0,
		"shadow_atlas": 8192, "shadow_filter": 3, "lod_bias": 1.0,
		"blur_taps": 12, "sky_radiance": Sky.RADIANCE_SIZE_512, "cloud_octaves": 5, "cloud_detail": 1.0,
	},
	{
		"id": "ultra", "name": "超高 ULTRA", "scale": 1.0, "msaa": 8, "taa": true,
		"ssr": true, "ssr_steps": 128, "ssao": true, "ssil": true, "tree_shadows": true,
		"vol": true, "shadow_dist": 460.0, "fog_scale": 1.15,
		"content": 1.35, "particles": 1.6,
		# 超高拉满光影与模型精度：8192 图集 + 高质量软阴影、模型满精度保留到更远、
		# 1024 天空反射缓存（车漆/玻璃反射更细腻）、粒子加量
		"shadow_atlas": 8192, "shadow_filter": 3, "lod_bias": 1.7,
		"blur_taps": 12, "sky_radiance": Sky.RADIANCE_SIZE_512, "cloud_octaves": 5, "cloud_detail": 1.0,
	},
]

const FAR_BASE := [750.0, 1100.0, 1550.0, 2100.0]

const AUDIO_KEYS := [
	"bgm_enabled", "bgm_volume", "engine_volume",
	"master_volume", "music_volume", "wind_volume", "sfx_volume", "ui_volume",
]

## 音频按 Bus 分轨。Settings 会直接写 AudioServer；若某条 Bus 尚未创建则优雅跳过。
const AUDIO_BUSES: Array[Dictionary] = [
	{"key": "master_volume", "bus": "Master", "cn": "总音量", "en": "MASTER", "desc": "全部声音的总增益"},
	{"key": "music_volume", "bus": "Music", "cn": "音乐", "en": "MUSIC", "desc": "菜单 / 赛道 BGM"},
	{"key": "engine_volume", "bus": "Engine", "cn": "引擎", "en": "ENGINE", "desc": "发动机与排气"},
	{"key": "wind_volume", "bus": "Wind", "cn": "风噪", "en": "WIND", "desc": "高速风切与环境声"},
	{"key": "sfx_volume", "bus": "SFX", "cn": "音效", "en": "SFX", "desc": "轮胎 / 碰撞 / 尾流"},
	{"key": "ui_volume", "bus": "UI", "cn": "界面", "en": "UI", "desc": "按钮 / 提示音"},
]

const RESOLUTIONS: Array[Dictionary] = [
	{"w": 1280, "h": 720, "name": "1280 × 720", "tag": "HD"},
	{"w": 1440, "h": 810, "name": "1440 × 810", "tag": "16:9"},
	{"w": 1600, "h": 900, "name": "1600 × 900", "tag": "默认"},
	{"w": 1920, "h": 1080, "name": "1920 × 1080", "tag": "FHD"},
	{"w": 2560, "h": 1440, "name": "2560 × 1440", "tag": "QHD"},
	{"w": 3840, "h": 2160, "name": "3840 × 2160", "tag": "4K"},
]

const FPS_OPTIONS: Array[Dictionary] = [
	{"value": 0, "name": "无限制", "en": "UNLIMITED"},
	{"value": 30, "name": "30 帧", "en": "30 FPS"},
	{"value": 60, "name": "60 帧", "en": "60 FPS"},
	{"value": 120, "name": "120 帧", "en": "120 FPS"},
	{"value": 144, "name": "144 帧", "en": "144 FPS"},
]

const MSAA_OPTIONS: Array[Dictionary] = [
	{"value": 0, "name": "关闭", "en": "OFF"},
	{"value": 2, "name": "2× MSAA", "en": "2X"},
	{"value": 4, "name": "4× MSAA", "en": "4X"},
	{"value": 8, "name": "8× MSAA", "en": "8X"},
]

const DISPLAY_MODES: Array[Dictionary] = [
	{"id": "windowed", "name": "窗口化", "cn": "窗口化", "en": "WINDOWED"},
	{"id": "borderless", "name": "无边框", "cn": "无边框窗口", "en": "BORDERLESS"},
	{"id": "fullscreen", "name": "全屏", "cn": "全屏独占", "en": "FULLSCREEN"},
]

const UPSCALE_IDS := ["auto", "on", "off"]
const UPSCALE_NAMES := ["自动（推荐）", "强制开启", "关闭（用内置 TAA）"]
const HUD_UNITS := [{"id": "kph", "name": "km/h"}, {"id": "mph", "name": "mph"}]

const SAVE_VERSION := 4

signal changed
signal audio_changed

# ---- 画质档 ---------------------------------------------------------------
var index := 2

# ---- 画面细项（独立于画质档；切换画质档会重置为档位默认）------------------
var render_scale := 1.0
var msaa := 2
var taa := true
var ssr := true
var ssao := true
var ssil := true
var volumetric := true
var tree_shadows := false

# ---- 显示 -----------------------------------------------------------------
var fps_limit := 0
var vsync_enabled := true
var window_mode := "windowed"
var window_width := 1600
var window_height := 900

# ---- 音频（旧字段保留兼容）------------------------------------------------
var bgm_enabled := true
var bgm_volume := 0.70
var engine_volume := 0.75
var master_volume := 1.0
var music_volume := 0.70
var wind_volume := 0.42
var sfx_volume := 0.85
var ui_volume := 0.80

# ---- 画面效果 -------------------------------------------------------------
var motion_blur_amount := 0.62
var motion_blur_enabled := true
var sharpen := 0.38
var far_clarity := 1.0
var upscale := "auto"
var vignette := true

# ---- 操作 -----------------------------------------------------------------
var steer_sensitivity := 1.0
var camera_shake := true
# 手柄震动：开关 + 强度（0.6~2.0，默认比旧版明显）
var haptics_enabled := true
var haptics_intensity := 1.35
# 模拟输入（磁轴键盘 HID 桥接 / 厂商模拟手柄）：按键深度 → 转向/油门
var analog_input_enabled := true
var analog_udp_port := 48255
var analog_deadzone := 0.02
var analog_curve_steer := 1.0
var analog_curve_throttle := 1.0

# ---- 游戏 / HUD -----------------------------------------------------------
var hud_minimap := true
var hud_tach := true
var hud_speed := true
var hud_hints := true
var hud_units := "kph"
var show_fps := false
var laps_override := 0

# ---- 上次选择 -------------------------------------------------------------
var last_track := ""
var last_car := ""
var last_mode := "gp"

var _preset_cache: Dictionary = {}
var _preset_dirty := true
var _loading := false
var _migrated := false


## 动态模糊：关闭时对 main.gd 直接返回 0，无需 main 改动。
var motion_blur: float:
	get:
		return motion_blur_amount if motion_blur_enabled else 0.0
	set(value):
		motion_blur_amount = clampf(float(value), 0.0, 1.0)


func _ready() -> void:
	load_settings()
	apply_audio_buses()
	call_deferred("apply_audio_buses")
	# 启动时恢复窗口设置；截图 / 无头验证 / 性能测试模式下跳过，避免干扰取景
	if _should_apply_display_on_startup():
		apply_display()


# ---------------------------------------------------------------------------
# 画质档（对外 API 不变；返回合并了画面细项的最终渲染预算）
# ---------------------------------------------------------------------------

func preset() -> Dictionary:
	if _preset_dirty:
		_rebuild_preset()
	return _preset_cache


func _rebuild_preset() -> void:
	var base: Dictionary = PRESETS[clampi(index, 0, PRESETS.size() - 1)].duplicate()
	base["scale"] = clampf(render_scale, 0.5, 1.0)
	base["msaa"] = msaa
	base["taa"] = taa
	base["ssr"] = ssr
	base["ssao"] = ssao
	base["ssil"] = ssil
	base["tree_shadows"] = tree_shadows
	base["vol"] = volumetric
	_preset_cache = base
	_preset_dirty = false


func _mark_preset() -> void:
	_preset_dirty = true


func base_preset() -> Dictionary:
	return PRESETS[clampi(index, 0, PRESETS.size() - 1)]


func name_text() -> String:
	return String(PRESETS[clampi(index, 0, PRESETS.size() - 1)]["name"])


func detail_name() -> String:
	return "自定义 CUSTOM" if details_differ_from_preset() else name_text()


func details_differ_from_preset() -> bool:
	var base: Dictionary = PRESETS[clampi(index, 0, PRESETS.size() - 1)]
	return absf(render_scale - float(base["scale"])) > 0.005 \
		or msaa != int(base["msaa"]) or taa != bool(base["taa"]) \
		or ssr != bool(base["ssr"]) or ssao != bool(base["ssao"]) \
		or ssil != bool(base["ssil"]) or volumetric != bool(base["vol"]) \
		or tree_shadows != bool(base["tree_shadows"])


func set_quality(i: int) -> void:
	index = clampi(i, 0, PRESETS.size() - 1)
	sync_details_from_preset()
	save_settings()
	changed.emit()


func sync_details_from_preset() -> void:
	var base: Dictionary = PRESETS[clampi(index, 0, PRESETS.size() - 1)]
	render_scale = clampf(float(base["scale"]), 0.5, 1.0)
	msaa = int(base["msaa"])
	taa = bool(base["taa"])
	ssr = bool(base["ssr"])
	ssao = bool(base["ssao"])
	ssil = bool(base["ssil"])
	volumetric = bool(base["vol"])
	tree_shadows = bool(base["tree_shadows"])
	_mark_preset()


func cycle() -> void:
	set_quality((index + 1) % PRESETS.size())


func content_scale() -> float:
	return float(PRESETS[clampi(index, 0, PRESETS.size() - 1)]["content"])


func particle_scale() -> float:
	return float(PRESETS[clampi(index, 0, PRESETS.size() - 1)]["particles"])


## 阴影图集边长（2048/4096/8192）。低档用小图省 GPU，高档大图保证远影锐利。
func shadow_atlas() -> int:
	return int(base_preset().get("shadow_atlas", 4096))


## 软阴影滤波档位（0=硬阴影，2=软低，3=软中，4=软高）。
func shadow_filter() -> int:
	return int(base_preset().get("shadow_filter", 3))


## 模型 LOD 偏移：<1 更早切低模（省帧率），>1 满精度保留到更远（画面更扎实）。
func lod_bias() -> float:
	return float(base_preset().get("lod_bias", 1.0))


## 动态模糊径向采样数（低档减半）。
func blur_taps() -> int:
	return int(base_preset().get("blur_taps", 12))


## 天空辐射缓存档位（Sky.RadianceSize 枚举，反射贴图精度）。
func sky_radiance() -> int:
	return int(base_preset().get("sky_radiance", Sky.RADIANCE_SIZE_512))


## 云层 FBM 层数（低档 3 层，省全屏噪声采样）。
func cloud_octaves() -> int:
	return int(base_preset().get("cloud_octaves", 5))


## 云层细节层开关（0=单层云，低档省一半采样）。
func cloud_detail() -> float:
	return float(base_preset().get("cloud_detail", 1.0))


func far_distance() -> float:
	return float(FAR_BASE[clampi(index, 0, FAR_BASE.size() - 1)]) \
		* clampf(far_clarity, 0.6, 1.6)


func msaa_mode() -> Viewport.MSAA:
	match msaa:
		2:
			return Viewport.MSAA_2X
		4:
			return Viewport.MSAA_4X
		8:
			return Viewport.MSAA_8X
		_:
			return Viewport.MSAA_DISABLED


# ---------------------------------------------------------------------------
# 通用设置写入（设置面板走这里，全部即时生效 + 落盘）
# ---------------------------------------------------------------------------

func set_value(key: String, value: Variant) -> void:
	var is_audio := AUDIO_KEYS.has(key)
	match key:
		# ---- 兼容旧字段 ----
		"bgm_enabled":
			bgm_enabled = bool(value)
		"bgm_volume":
			bgm_volume = clampf(float(value), 0.0, 1.0)
			music_volume = bgm_volume
		"engine_volume":
			engine_volume = clampf(float(value), 0.0, 1.0)
		"master_volume":
			master_volume = clampf(float(value), 0.0, 1.0)
		"music_volume":
			music_volume = clampf(float(value), 0.0, 1.0)
			bgm_volume = music_volume
		"wind_volume":
			wind_volume = clampf(float(value), 0.0, 1.0)
		"sfx_volume":
			sfx_volume = clampf(float(value), 0.0, 1.0)
		"ui_volume":
			ui_volume = clampf(float(value), 0.0, 1.0)
		# ---- 画面效果 ----
		"motion_blur":
			motion_blur = float(value)
		"motion_blur_enabled":
			motion_blur_enabled = bool(value)
		"sharpen":
			sharpen = clampf(float(value), 0.0, 1.0)
		"far_clarity":
			far_clarity = clampf(float(value), 0.6, 1.6)
		"upscale":
			upscale = String(value)
		"vignette":
			vignette = bool(value)
		# ---- 画面细项 ----
		"render_scale":
			render_scale = clampf(float(value), 0.5, 1.0)
			_mark_preset()
		"msaa":
			msaa = _closest_msaa(int(value))
			_mark_preset()
		"taa":
			taa = bool(value)
			_mark_preset()
		"ssr":
			ssr = bool(value)
			_mark_preset()
		"ssao":
			ssao = bool(value)
			_mark_preset()
		"ssil":
			ssil = bool(value)
			_mark_preset()
		"volumetric":
			volumetric = bool(value)
			_mark_preset()
		"tree_shadows":
			tree_shadows = bool(value)
			_mark_preset()
		# ---- 显示 ----
		"fps_limit":
			fps_limit = int(value)
			apply_display()
		"vsync_enabled":
			vsync_enabled = bool(value)
			apply_display()
		"window_mode":
			window_mode = String(value)
			apply_display()
		"window_width":
			window_width = clampi(int(value), 960, 7680)
			apply_display()
		"window_height":
			window_height = clampi(int(value), 540, 4320)
			apply_display()
		# ---- 操作 ----
		"steer_sensitivity":
			steer_sensitivity = clampf(float(value), 0.5, 1.5)
		"camera_shake":
			camera_shake = bool(value)
		"haptics_enabled":
			haptics_enabled = bool(value)
		"haptics_intensity":
			haptics_intensity = clampf(float(value), 0.6, 2.0)
		# ---- 模拟输入（磁轴/桥接）----
		"analog_input_enabled":
			analog_input_enabled = bool(value)
		"analog_udp_port":
			analog_udp_port = clampi(int(value), 1024, 65535)
		"analog_deadzone":
			analog_deadzone = clampf(float(value), 0.0, 0.6)
		"analog_curve_steer":
			analog_curve_steer = clampf(float(value), 0.6, 3.0)
		"analog_curve_throttle":
			analog_curve_throttle = clampf(float(value), 0.6, 3.0)
		# ---- HUD / 游戏 ----
		"hud_minimap":
			hud_minimap = bool(value)
		"hud_tach":
			hud_tach = bool(value)
		"hud_speed":
			hud_speed = bool(value)
		"hud_hints":
			hud_hints = bool(value)
		"hud_units":
			hud_units = String(value)
		"show_fps":
			show_fps = bool(value)
		"laps_override":
			laps_override = clampi(int(value), 0, 20)
		_:
			return
	save_settings()
	if is_audio:
		apply_audio_buses()
		audio_changed.emit()
	else:
		changed.emit()


# ---------------------------------------------------------------------------
# 音频分轨
# ---------------------------------------------------------------------------

func bus_name_for(key: String) -> String:
	for entry in AUDIO_BUSES:
		if String(entry["key"]) == key:
			return String(entry["bus"])
	return "Master"


func get_volume(key: String) -> float:
	match key:
		"master_volume": return master_volume
		"music_volume": return music_volume
		"engine_volume": return engine_volume
		"wind_volume": return wind_volume
		"sfx_volume": return sfx_volume
		"ui_volume": return ui_volume
		"bgm_volume": return bgm_volume
	return 1.0


func audio_bus_available(bus: String) -> bool:
	return AudioServer.get_bus_index(bus) >= 0


## 幂等创建 6 条标准总线。AudioManager.ensure_audio_buses() 存在时会直接复用，
## 因此在音频层尚未实例化（截图 / 设置先从菜单打开）时滑条也能实时生效。
func ensure_audio_buses() -> void:
	for entry in AUDIO_BUSES:
		var bus := String(entry["bus"])
		if bus == "Master" or AudioServer.get_bus_index(bus) >= 0:
			continue
		var idx := AudioServer.bus_count
		AudioServer.add_bus(idx)
		AudioServer.set_bus_name(idx, bus)
		AudioServer.set_bus_send(idx, "Master")


## 把 6 条分轨音量写进 AudioServer。Bus 不存在时自动创建（幂等）。
## 由 Settings 自己调用；audio_manager 的 set_bus_volume() 是等价的冗余实现。
func apply_audio_buses() -> void:
	ensure_audio_buses()
	for entry in AUDIO_BUSES:
		var bus := String(entry["bus"])
		var bus_index := AudioServer.get_bus_index(bus)
		if bus_index < 0:
			continue
		var volume := clampf(get_volume(String(entry["key"])), 0.0, 1.0)
		AudioServer.set_bus_volume_db(bus_index, linear_to_db(maxf(volume, 0.0001)))
		AudioServer.set_bus_mute(bus_index, volume <= 0.001)
	# Master 的静音由总音量控制：设置里把 Master 拉到 0 时也静音
	var master_index := AudioServer.get_bus_index("Master")
	if master_index >= 0:
		AudioServer.set_bus_mute(master_index, master_volume <= 0.001)


# ---------------------------------------------------------------------------
# 显示（分辨率 / 帧率上限 / 垂直同步 / 窗口模式）
# ---------------------------------------------------------------------------

func resolution_index() -> int:
	for i in RESOLUTIONS.size():
		if int(RESOLUTIONS[i]["w"]) == window_width and int(RESOLUTIONS[i]["h"]) == window_height:
			return i
	# 自定义分辨率时匹配最接近的一项
	var best := 0
	var best_d := 1e12
	for i in RESOLUTIONS.size():
		var d := absf(float(RESOLUTIONS[i]["w"]) - float(window_width)) \
			+ absf(float(RESOLUTIONS[i]["h"]) - float(window_height))
		if d < best_d:
			best_d = d
			best = i
	return best


func resolution_label() -> String:
	for entry in RESOLUTIONS:
		if int(entry["w"]) == window_width and int(entry["h"]) == window_height:
			return "%s   %s" % [String(entry["name"]), String(entry["tag"])]
	return "%d × %d" % [window_width, window_height]


func set_resolution(i: int) -> void:
	var idx := clampi(i, 0, RESOLUTIONS.size() - 1)
	window_width = int(RESOLUTIONS[idx]["w"])
	window_height = int(RESOLUTIONS[idx]["h"])
	apply_display()
	save_settings()
	changed.emit()


func fps_text() -> String:
	if fps_limit <= 0:
		return "无限制 UNLIMITED"
	return "%d 帧 / FPS" % fps_limit


func display_mode_name() -> String:
	for entry in DISPLAY_MODES:
		if String(entry["id"]) == window_mode:
			return String(entry["cn"])
	return "窗口化"


func apply_display() -> void:
	Engine.max_fps = maxi(fps_limit, 0)
	if DisplayServer.get_name() == "headless":
		return
	if vsync_enabled:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED)
	else:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var win := get_window()
	if win == null:
		return
	match window_mode:
		"fullscreen":
			if win.mode != Window.MODE_FULLSCREEN:
				win.mode = Window.MODE_FULLSCREEN
		"borderless":
			if win.mode != Window.MODE_WINDOWED:
				win.mode = Window.MODE_WINDOWED
			win.borderless = true
			var screen := DisplayServer.window_get_current_screen()
			var screen_size := DisplayServer.screen_get_size(screen)
			win.size = screen_size
			win.position = Vector2i.ZERO
		_:
			if win.mode != Window.MODE_WINDOWED:
				win.mode = Window.MODE_WINDOWED
			win.borderless = false
			win.size = Vector2i(window_width, window_height)


func _should_apply_display_on_startup() -> bool:
	if DisplayServer.get_name() == "headless":
		return false
	var args := OS.get_cmdline_user_args()
	for arg in args:
		if arg.begins_with("--shot=") or arg == "--verify" or arg == "--perf" \
				or arg.begins_with("--bake-"):
			return false
	return true


# ---------------------------------------------------------------------------
# 选择 / 重置
# ---------------------------------------------------------------------------

func set_selection(track_id: String, car_id: String, mode: String) -> void:
	last_track = track_id
	last_car = car_id
	last_mode = mode
	save_settings()


func reset_defaults() -> void:
	index = PlatformProfile.recommended_quality()
	sync_details_from_preset()
	bgm_enabled = true
	bgm_volume = 0.70
	engine_volume = 0.75
	master_volume = 1.0
	music_volume = 0.70
	wind_volume = 0.80
	sfx_volume = 0.85
	ui_volume = 0.80
	motion_blur_amount = 0.62
	motion_blur_enabled = true
	sharpen = 0.38
	far_clarity = 1.0
	upscale = "auto"
	vignette = true
	fps_limit = 0
	vsync_enabled = true
	window_mode = "windowed"
	window_width = 1600
	window_height = 900
	steer_sensitivity = 1.0
	analog_input_enabled = true
	analog_udp_port = 48255
	analog_deadzone = 0.02
	analog_curve_steer = 1.0
	analog_curve_throttle = 1.0
	camera_shake = true
	hud_minimap = true
	hud_tach = true
	hud_speed = true
	hud_hints = true
	hud_units = "kph"
	show_fps = false
	laps_override = 0
	_mark_preset()
	save_settings()
	apply_audio_buses()
	apply_display()
	changed.emit()
	audio_changed.emit()


# ---------------------------------------------------------------------------
# 持久化
# ---------------------------------------------------------------------------

func save_settings() -> void:
	var data := {
		"version": SAVE_VERSION,
		# 画质
		"quality": String(PRESETS[clampi(index, 0, PRESETS.size() - 1)]["id"]),
		"render_scale": render_scale,
		"msaa": msaa,
		"taa": taa,
		"ssr": ssr,
		"ssao": ssao,
		"ssil": ssil,
		"volumetric": volumetric,
		"tree_shadows": tree_shadows,
		# 显示
		"fps_limit": fps_limit,
		"vsync_enabled": vsync_enabled,
		"window_mode": window_mode,
		"window_width": window_width,
		"window_height": window_height,
		# 音频
		"bgm_enabled": bgm_enabled,
		"bgm_volume": bgm_volume,
		"engine_volume": engine_volume,
		"master_volume": master_volume,
		"music_volume": music_volume,
		"wind_volume": wind_volume,
		"sfx_volume": sfx_volume,
		"ui_volume": ui_volume,
		# 画面效果
		"motion_blur": motion_blur_amount,
		"motion_blur_enabled": motion_blur_enabled,
		"sharpen": sharpen,
		"far_clarity": far_clarity,
		"upscale": upscale,
		"vignette": vignette,
		# 操作
		"steer_sensitivity": steer_sensitivity,
		"camera_shake": camera_shake,
		"haptics_enabled": haptics_enabled,
		"haptics_intensity": haptics_intensity,
		"analog_input_enabled": analog_input_enabled,
		"analog_udp_port": analog_udp_port,
		"analog_deadzone": analog_deadzone,
		"analog_curve_steer": analog_curve_steer,
		"analog_curve_throttle": analog_curve_throttle,
		"analog_mapping_version": 2,
		# HUD / 游戏
		"hud_minimap": hud_minimap,
		"hud_tach": hud_tach,
		"hud_speed": hud_speed,
		"hud_hints": hud_hints,
		"hud_units": hud_units,
		"show_fps": show_fps,
		"laps_override": laps_override,
		# 上次选择
		"last_track": last_track,
		"last_car": last_car,
		"last_mode": last_mode,
	}
	var file := FileAccess.open("user://settings.json", FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(data, "\t"))


func load_settings() -> void:
	_loading = true
	if not FileAccess.file_exists("user://settings.json"):
		index = PlatformProfile.recommended_quality()
		sync_details_from_preset()
		print("[PLATFORM] %s" % PlatformProfile.summary())
		print("[PLATFORM] 首次启动，按平台推荐画质：%s" % name_text())
		_loading = false
		return
	var file := FileAccess.open("user://settings.json", FileAccess.READ)
	if file == null:
		_loading = false
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if not (parsed is Dictionary):
		_loading = false
		return
	var d: Dictionary = parsed as Dictionary
	var wanted := String(d.get("quality", "high"))
	for i in PRESETS.size():
		if String(PRESETS[i]["id"]) == wanted:
			index = i
			break
	var base: Dictionary = PRESETS[clampi(index, 0, PRESETS.size() - 1)]
	# 画面细项：旧存档没有这些字段 → 跟随画质档默认
	render_scale = clampf(float(d.get("render_scale", base["scale"])), 0.5, 1.0)
	msaa = _closest_msaa(int(d.get("msaa", base["msaa"])))
	taa = bool(d.get("taa", base["taa"]))
	ssr = bool(d.get("ssr", base["ssr"]))
	ssao = bool(d.get("ssao", base["ssao"]))
	ssil = bool(d.get("ssil", base["ssil"]))
	volumetric = bool(d.get("volumetric", d.get("vol", base["vol"])))
	tree_shadows = bool(d.get("tree_shadows", base["tree_shadows"]))
	# 显示
	fps_limit = maxi(int(d.get("fps_limit", 0)), 0)
	vsync_enabled = bool(d.get("vsync_enabled", true))
	window_mode = String(d.get("window_mode", "windowed"))
	window_width = clampi(int(d.get("window_width", 1600)), 960, 7680)
	window_height = clampi(int(d.get("window_height", 900)), 540, 4320)
	# 音频
	bgm_enabled = bool(d.get("bgm_enabled", true))
	bgm_volume = clampf(float(d.get("bgm_volume", 0.70)), 0.0, 1.0)
	engine_volume = clampf(float(d.get("engine_volume", 0.75)), 0.0, 1.0)
	master_volume = clampf(float(d.get("master_volume", 1.0)), 0.0, 1.0)
	music_volume = clampf(float(d.get("music_volume", bgm_volume)), 0.0, 1.0)
	wind_volume = clampf(float(d.get("wind_volume", 0.42)), 0.0, 1.0)
	# v3（2026-11-08）：默认风噪整体下调，旧存档里等于默认值的 0.80 一次性降到 0.42。
	if int(d.get("version", 1)) < 3 and absf(wind_volume - 0.80) < 0.01:
		wind_volume = 0.42
		_migrated = true
	sfx_volume = clampf(float(d.get("sfx_volume", 0.85)), 0.0, 1.0)
	ui_volume = clampf(float(d.get("ui_volume", 0.80)), 0.0, 1.0)
	# 画面效果
	motion_blur_amount = clampf(float(d.get("motion_blur", 0.62)), 0.0, 1.0)
	motion_blur_enabled = bool(d.get("motion_blur_enabled", true))
	sharpen = clampf(float(d.get("sharpen", 0.38)), 0.0, 1.0)
	far_clarity = clampf(float(d.get("far_clarity", 1.0)), 0.6, 1.6)
	upscale = String(d.get("upscale", "auto"))
	vignette = bool(d.get("vignette", true))
	# 操作
	steer_sensitivity = clampf(float(d.get("steer_sensitivity", 1.0)), 0.5, 1.5)
	camera_shake = bool(d.get("camera_shake", true))
	haptics_enabled = bool(d.get("haptics_enabled", true))
	haptics_intensity = clampf(float(d.get("haptics_intensity", 1.35)), 0.6, 2.0)
	analog_input_enabled = bool(d.get("analog_input_enabled", true))
	analog_udp_port = clampi(int(d.get("analog_udp_port", 48255)), 1024, 65535)
	analog_deadzone = clampf(float(d.get("analog_deadzone", 0.02)), 0.0, 0.6)
	analog_curve_steer = clampf(float(d.get("analog_curve_steer", 1.0)), 0.6, 3.0)
	analog_curve_throttle = clampf(float(d.get("analog_curve_throttle", 1.0)), 0.6, 3.0)
	# v2 迁移（2026-11-06）：磁轴 ACE68 接入后默认改成「线性油门/线性转向」，
	# 旧存档里写过的 1.35/1.15 曲线一次性改成 1.0；之后再改由玩家/设置页决定。
	if int(d.get("analog_mapping_version", 0)) < 2:
		analog_curve_steer = 1.0
		analog_curve_throttle = 1.0
		analog_deadzone = minf(analog_deadzone, 0.02)
		_migrated = true
	# v4 迁移（2026-11-08）：动态模糊整体加强并在加速段叠加。
	# 旧存档默认 0.45 视为「没主动调过」，一次性提到新的 0.62；玩家手动改过的不动。
	if int(d.get("version", 1)) < 4 and absf(motion_blur_amount - 0.45) < 0.04:
		motion_blur_amount = 0.62
		_migrated = true
	# HUD / 游戏
	hud_minimap = bool(d.get("hud_minimap", true))
	hud_tach = bool(d.get("hud_tach", true))
	hud_speed = bool(d.get("hud_speed", true))
	hud_hints = bool(d.get("hud_hints", true))
	hud_units = String(d.get("hud_units", "kph"))
	show_fps = bool(d.get("show_fps", false))
	laps_override = clampi(int(d.get("laps_override", 0)), 0, 20)
	# 上次选择
	last_track = String(d.get("last_track", ""))
	last_car = String(d.get("last_car", ""))
	last_mode = String(d.get("last_mode", "gp"))
	_loading = false
	_mark_preset()
	if _migrated:
		_migrated = false
		save_settings()
	# 旧版存档只有 quality 一个字段（项目早期实测存档是 {"quality":"low"}，
	# 0.7x 渲染缩放正是"整体发糊"的直接原因）。首次升级时按平台重新推荐档位。
	if not d.has("sharpen"):
		var old_name := name_text()
		index = PlatformProfile.recommended_quality()
		sync_details_from_preset()
		print("[PLATFORM] 旧版设置（%s）→ 按平台提升为 %s" % [old_name, name_text()])
		save_settings()
	print("[PLATFORM] %s  |  画质 %s  升频 %s  |  %d×%d @ %s" % [
		PlatformProfile.summary(), name_text(), upscale, window_width, window_height, fps_text()])


func _closest_msaa(value: int) -> int:
	if value <= 0:
		return 0
	var best := 0
	var best_d := 999
	for entry in MSAA_OPTIONS:
		var d := absi(int(entry["value"]) - value)
		if d < best_d:
			best_d = d
			best = int(entry["value"])
	return best
