class_name AudioManager
extends Node
## BGM + 程序化引擎声 + 风噪 / 轮胎 / 碰撞音效，全部走独立 AudioServer Bus，
## 方便设置面板分轨调节（Music / Engine / Wind / SFX / UI）。

const AUDIO_ROOT := "res://assets/audio"
const MENU_BGM_ID := "apex"
const BUS_NAMES := ["Music", "Engine", "Wind", "SFX", "UI"]

var bgm_player: AudioStreamPlayer
var engine: EngineAudio
var wind_player: AudioStreamPlayer
var tire_player: AudioStreamPlayer
var impact_player: AudioStreamPlayer
var current_bgm := ""
var muted := false
var engine_profile_spec: Dictionary = {}

## 音乐 ducking：用 Music bus 上的独立 AudioEffectAmplify 叠一层临时增益，
## 不写 bus 的 volume_db / mute，所以 Settings 的 Music 音量始终是基准，不会被覆盖。
const DUCK_EFFECT_NAME := "GameFeelDuck"
var _duck_effect: AudioEffectAmplify
var _duck_active := false
var _duck_started_ms := 0
var _duck_from_db := 0.0
var _duck_peak_db := 0.0
var _duck_attack := 0.04
var _duck_hold := 0.60
var _duck_release := 0.24


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	ensure_audio_buses()
	bgm_player = AudioStreamPlayer.new()
	bgm_player.name = "BGM"
	bgm_player.bus = "Music"
	bgm_player.volume_db = -13.0
	add_child(bgm_player)

	wind_player = AudioStreamPlayer.new()
	wind_player.name = "Wind"
	wind_player.bus = "Wind"
	wind_player.stream = _make_loop_noise("wind")
	wind_player.volume_db = -80.0
	add_child(wind_player)
	wind_player.play()

	tire_player = AudioStreamPlayer.new()
	tire_player.name = "Tire"
	tire_player.bus = "SFX"
	tire_player.stream = _make_loop_noise("tire")
	tire_player.volume_db = -80.0
	add_child(tire_player)
	tire_player.play()

	impact_player = AudioStreamPlayer.new()
	impact_player.name = "Impact"
	impact_player.bus = "SFX"
	impact_player.stream = _make_impact_stream()
	impact_player.volume_db = -80.0
	add_child(impact_player)

	Settings.audio_changed.connect(apply_settings)
	if Settings.has_method("apply_audio_buses"):
		Settings.apply_audio_buses()
	apply_settings()


func ensure_audio_buses() -> void:
	for bus_name in BUS_NAMES:
		if AudioServer.get_bus_index(bus_name) >= 0:
			continue
		var idx := AudioServer.bus_count
		AudioServer.add_bus(idx)
		AudioServer.set_bus_name(idx, bus_name)
		AudioServer.set_bus_send(idx, "Master")
	_setup_bus_effects()


## 总线处理：Master 限幅 + 压缩避免碰撞/氮气叠加时爆音；
## Wind/Tire 低通去掉刺耳的高频嘶声；Engine 高通清掉浑浊低频。
func _setup_bus_effects() -> void:
	var master := AudioServer.get_bus_index("Master")
	if master >= 0 and not _bus_has_effect(master, "SafetyLimiter"):
		var limiter := AudioEffectLimiter.new()
		limiter.resource_name = "SafetyLimiter"
		limiter.threshold_db = -2.0
		limiter.ceiling_db = -0.8
		limiter.soft_clip_db = -1.0
		limiter.soft_clip_ratio = 2.0
		AudioServer.add_bus_effect(master, limiter)
	if master >= 0 and not _bus_has_effect(master, "GlueComp"):
		var comp := AudioEffectCompressor.new()
		comp.resource_name = "GlueComp"
		comp.threshold = -16.0
		comp.ratio = 2.4
		comp.attack_us = 12000.0
		comp.release_ms = 180.0
		comp.gain = 1.5
		AudioServer.add_bus_effect(master, comp)
	var wind_bus := AudioServer.get_bus_index("Wind")
	if wind_bus >= 0 and not _bus_has_effect(wind_bus, "WindLowPass"):
		var lp := AudioEffectLowPassFilter.new()
		lp.resource_name = "WindLowPass"
		lp.cutoff_hz = 1900.0
		lp.resonance = 0.35
		AudioServer.add_bus_effect(wind_bus, lp)
	var sfx_bus := AudioServer.get_bus_index("SFX")
	if sfx_bus >= 0 and not _bus_has_effect(sfx_bus, "TireLowPass"):
		var lp2 := AudioEffectLowPassFilter.new()
		lp2.resource_name = "TireLowPass"
		lp2.cutoff_hz = 3200.0
		lp2.resonance = 0.25
		AudioServer.add_bus_effect(sfx_bus, lp2)
	var engine_bus := AudioServer.get_bus_index("Engine")
	if engine_bus >= 0 and not _bus_has_effect(engine_bus, "EngineHighPass"):
		var hp := AudioEffectHighPassFilter.new()
		hp.resource_name = "EngineHighPass"
		hp.cutoff_hz = 38.0
		hp.resonance = 0.2
		AudioServer.add_bus_effect(engine_bus, hp)


func _bus_has_effect(bus_index: int, effect_name: String) -> bool:
	for i in AudioServer.get_bus_effect_count(bus_index):
		var effect := AudioServer.get_bus_effect(bus_index, i)
		if effect != null and String(effect.resource_name) == effect_name:
			return true
	return false


func set_bus_volume(bus_name: String, linear: float) -> void:
	var idx := AudioServer.get_bus_index(bus_name)
	if idx < 0:
		return
	var value := clampf(linear, 0.0, 1.0)
	AudioServer.set_bus_mute(idx, value <= 0.001)
	AudioServer.set_bus_volume_db(idx, linear_to_db(maxf(value, 0.001)))


func get_bus_volume(bus_name: String) -> float:
	var idx := AudioServer.get_bus_index(bus_name)
	if idx < 0:
		return 1.0
	if AudioServer.is_bus_mute(idx):
		return 0.0
	return clampf(db_to_linear(AudioServer.get_bus_volume_db(idx)), 0.0, 1.0)


func apply_settings() -> void:
	# 分轨音量统一由 AudioServer bus 控制，播放器保持固定基电平，避免双重衰减
	if bgm_player != null:
		bgm_player.volume_db = -6.0
	# 引擎声压提升 3dB（用户要求引擎声更醒目），风噪在 update_ambience 里单独压低
	if engine != null and is_instance_valid(engine):
		engine.volume_db = -8.5
	if Settings.has_method("apply_audio_buses"):
		Settings.apply_audio_buses()


## 撞击时短暂压低 Music bus（-6 ~ -10 dB，按强度），保持 0.5~0.9s 后平滑恢复。
## 通过 Music bus 末尾的 AudioEffectAmplify 实现，Settings 的 Music bus 音量
## 和静音状态完全不受影响；重复调用会从当前音量重新起包络，不会叠成静音。
func duck_music(strength: float) -> void:
	var s := clampf(strength, 0.0, 1.0)
	_ensure_duck_effect()
	if _duck_effect == null or not is_instance_valid(_duck_effect):
		return
	_duck_from_db = _duck_effect.volume_db
	_duck_peak_db = -lerpf(6.0, 10.0, s)
	_duck_attack = 0.04
	_duck_hold = lerpf(0.50, 0.90, s)
	_duck_release = 0.24
	_duck_started_ms = Time.get_ticks_msec()
	_duck_active = true
	set_process(true)


func _ensure_duck_effect() -> void:
	var bus_index := AudioServer.get_bus_index("Music")
	if bus_index < 0:
		ensure_audio_buses()
		bus_index = AudioServer.get_bus_index("Music")
	if bus_index < 0:
		return
	if _duck_effect != null and is_instance_valid(_duck_effect):
		_duck_effect.volume_db = clampf(_duck_effect.volume_db, -12.0, 0.0)
		return
	for i in AudioServer.get_bus_effect_count(bus_index):
		var effect := AudioServer.get_bus_effect(bus_index, i)
		if effect is AudioEffectAmplify and String(effect.resource_name) == DUCK_EFFECT_NAME:
			_duck_effect = effect as AudioEffectAmplify
			_duck_effect.volume_db = 0.0
			return
	var amp := AudioEffectAmplify.new()
	amp.resource_name = DUCK_EFFECT_NAME
	amp.volume_db = 0.0
	AudioServer.add_bus_effect(bus_index, amp)
	_duck_effect = amp


func _process(_delta: float) -> void:
	if not _duck_active:
		return
	if _duck_effect == null or not is_instance_valid(_duck_effect):
		_duck_active = false
		return
	var elapsed := float(Time.get_ticks_msec() - _duck_started_ms) / 1000.0
	var db := 0.0
	if elapsed < _duck_attack:
		var k := elapsed / maxf(_duck_attack, 0.001)
		db = lerpf(_duck_from_db, _duck_peak_db, smoothstep(0.0, 1.0, k))
	elif elapsed < _duck_attack + _duck_hold:
		db = _duck_peak_db
	elif elapsed < _duck_attack + _duck_hold + _duck_release:
		var k := (elapsed - _duck_attack - _duck_hold) / maxf(_duck_release, 0.001)
		db = lerpf(_duck_peak_db, 0.0, smoothstep(0.0, 1.0, k))
	else:
		_duck_active = false
	_duck_effect.volume_db = db


func _exit_tree() -> void:
	_duck_active = false
	if _duck_effect != null and is_instance_valid(_duck_effect):
		_duck_effect.volume_db = 0.0
	_duck_effect = null


func play_menu_bgm() -> void:
	_play_bgm_id(MENU_BGM_ID)


func play_race_bgm(track_id: String) -> void:
	var entries: Array = GameData.bgm
	for entry in entries:
		if typeof(entry) == TYPE_DICTIONARY and String(entry.get("map", "")) == track_id:
			_play_bgm_id(String(entry.get("id", "")))
			return
	if entries.size() > 0 and typeof(entries[0]) == TYPE_DICTIONARY:
		_play_bgm_id(String(entries[0].get("id", "")))


func _play_bgm_id(bgm_id: String) -> void:
	if bgm_id.is_empty():
		return
	if bgm_id == current_bgm and bgm_player.playing:
		return
	var res_path := ""
	var entries: Array = GameData.bgm
	for entry in entries:
		if typeof(entry) == TYPE_DICTIONARY and String(entry.get("id", "")) == bgm_id:
			var file := String(entry.get("file", ""))
			if not file.is_empty():
				res_path = AUDIO_ROOT.path_join(file)
			break
	if res_path.is_empty():
		res_path = AUDIO_ROOT.path_join("bgm/%s.ogg" % bgm_id)
	if not ResourceLoader.exists(res_path):
		push_warning("AudioManager: missing BGM %s" % res_path)
		return
	var stream = load(res_path)
	if stream == null:
		return
	if stream is AudioStreamOggVorbis:
		(stream as AudioStreamOggVorbis).loop = true
	current_bgm = bgm_id
	bgm_player.stream = stream
	bgm_player.play()
	apply_settings()


func stop_bgm() -> void:
	bgm_player.stop()
	current_bgm = ""


func start_engine() -> void:
	if engine != null:
		return
	engine = EngineAudio.new()
	engine.name = "EngineAudio"
	engine.bus = "Engine"
	add_child(engine)
	if not engine_profile_spec.is_empty():
		engine.set_profile(engine_profile_spec)
	apply_settings()


## main.gd 在开赛时调用：按当前车的 spec 切换引擎声线
## （fuelType/engineProfile/aspiration/redline/powerHp/weightKg）。
func set_engine_profile(spec: Dictionary) -> void:
	engine_profile_spec = spec.duplicate(true)
	if engine != null and is_instance_valid(engine):
		engine.set_profile(engine_profile_spec)


func get_engine_profile() -> String:
	return engine.profile if engine != null and is_instance_valid(engine) else String(engine_profile_spec.get("engineProfile", ""))


## fuel_cut 是三态：1 = 车辆确实在断油，0 = 明确没断油，-1 = 未提供（由引擎自行推断）。
func update_engine(rpm: float, throttle: float, speed01: float, gear: int,
		fuel_cut: int = -1) -> void:
	if engine != null:
		engine.update_sound(rpm, throttle, speed01, gear, fuel_cut)


func update_ambience(speed01: float, slip01: float, offroad: bool,
		dt: float = 1.0 / 120.0) -> void:
	var smooth := 1.0 - exp(-4.5 * clampf(dt, 0.0001, 0.1))
	if wind_player != null:
		# 风噪只做高速衬托：整体再压低，且随速度平滑过渡（旧版逐帧 0.18 插值会抽动）
		var wind_target := -80.0 if speed01 < 0.02 else lerpf(-56.0, -30.0, pow(speed01, 0.9))
		wind_player.volume_db = lerpf(wind_player.volume_db, wind_target, smooth)
		wind_player.pitch_scale = 0.66 + speed01 * 0.62
	if tire_player != null:
		var tire_level := clampf(slip01, 0.0, 1.0)
		if offroad:
			tire_level = maxf(tire_level, 0.28)
		var target := -80.0 if tire_level < 0.04 else lerpf(-42.0, -18.0, tire_level)
		tire_player.volume_db = lerpf(tire_player.volume_db, target, smooth)
		tire_player.pitch_scale = (0.62 if offroad else 1.0) + tire_level * 0.35


func play_impact(strength: float) -> void:
	if impact_player == null:
		return
	var s := clampf(strength, 0.0, 1.0)
	impact_player.volume_db = linear_to_db(0.15 + s * 0.85) - 4.0
	impact_player.pitch_scale = 1.2 - s * 0.4 + randf() * 0.1
	impact_player.play()


func stop_engine() -> void:
	if engine != null:
		engine.queue_free()
		engine = null


# ---------------------------------------------------------------------------
# 程序化循环噪声（风 / 轮胎），生成 1 秒循环 WAV
# ---------------------------------------------------------------------------
func _make_loop_noise(kind: String) -> AudioStreamWAV:
	var rate := 22050
	var frames := rate
	var data := PackedByteArray()
	data.resize(frames * 2)
	var low := 0.0
	var band := 0.0
	for i in frames:
		var n := randf_range(-1.0, 1.0)
		low = lerpf(low, n, 0.09)
		var s := 0.0
		if kind == "wind":
			s = low * (0.55 + 0.45 * sin(float(i) / float(frames) * TAU * 3.0))
		else:
			band = lerpf(band, n - low, 0.32)
			s = band * 0.75
		data.encode_s16(i * 2, int(clampf(s, -1.0, 1.0) * 32767.0))
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = rate
	stream.stereo = false
	stream.data = data
	stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
	stream.loop_begin = 0
	stream.loop_end = frames
	return stream


func _make_impact_stream() -> AudioStreamWAV:
	var rate := 22050
	var frames := int(rate * 0.32)
	var data := PackedByteArray()
	data.resize(frames * 2)
	var low := 0.0
	for i in frames:
		var t := float(i) / float(rate)
		var env := exp(-t * 16.0)
		var n := randf_range(-1.0, 1.0)
		low = lerpf(low, n, 0.22)
		var s := (low * 0.8 + sin(TAU * 78.0 * t) * 0.5 + sin(TAU * 43.0 * t) * 0.3) * env
		data.encode_s16(i * 2, int(clampf(s, -1.0, 1.0) * 32767.0))
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = rate
	stream.stereo = false
	stream.data = data
	return stream
