class_name EngineAudio
extends AudioStreamPlayer
## 物理建模引擎声 —— 按真实点火频率合成，叠加真实录音燃烧质感层。
##
## 与旧版（纯正弦谐波堆栈 + 任意基频表）的根本区别：
##   · 基频来自**真实点火频率** = rpm/60 × 每转点火次数（firingDiv = 缸数/2）。
##     V8 @3000rpm = 200Hz，V6 = 150Hz，I4 = 100Hz，I3 = 75Hz —— 这是听感上
##     区分 V6/V8/I4/I3 的物理来源。旧版的基频与转速完全脱钩，所以全都雷同。
##   · 谐波权重按**缸体特征**分配（十字平面 V8 的 4 阶突出、直六的 2/3 阶突出、
##     三缸奇数点火的深 lope），而不是一套通用权重表。
##   · EV 不再叠加 6 阶高频谐波（那正是刺耳啸叫的来源），改为逆变器基频 +
##     极少量谐波 + 齿轮啸叫 + 低频 NVH，频谱质心大幅下降。
##   · 真实录音素材（assets/audio/engine/*.wav）作为**燃烧质感层**叠加，
##     提供程序化合成难以得到的排气粗糙感与机械噪声。
##
## 分档位（每档一张独立波表，音色目标不同）：
##   idle   怠速：低频 lope 明显、高频收敛、排气有"点火不齐"的颗粒感
##   cruise 低中转：谐波完整、涡轮开始建立
##   pull   大转：高频占比抬升、涡轮哨声上扬、排气变亮
##   redline 红区：谐波最强，叠加断油（fuel cut）的节奏性顿挫与回火
##
## 断油表现：不是简单的正弦门限，而是「点火断续 + 哒哒机械声 + 转速回落」；
## 收油（overrun）按排气性格给出回火，涡轮车另有泄压阀的气流噪声。
##
## 性能：用**波表合成**而非逐采样累加 16 阶正弦。每档位预生成一张 2048 点
## 波表，运行时只做一次查表 + 线性插值，CPU 相比旧版不升反降。
##
## 数据来源：data/engine_sounds.json（由 tools/build_engine_sounds.py 生成）。
## main.gd 通过 AudioManager.set_engine_profile(spec) 切换。

const MIX_RATE := 44100.0
const PROFILE_PATH := "res://data/engine_sounds.json"
const TABLE_SIZE := 2048

## 真实录音燃烧质感层素材（按缸体族选择）。
##
## 选材依据（对每个候选做过自相关 + 分频段能量实测，脚本见
## tools/analyze_engine_spectrum.py 的选材说明）：
##   · 质感层**绝不能**在 40~90Hz 有强峰 —— 那是点火基频区，两层都在那里
##     发力就会互相打架，听起来像"两台引擎"。race_loop_p* 系列 40~90Hz
##     能量高达 43.5%、且 83~95% 能量集中在基频（近乎纯音），已排除。
##   · motor_seamless_* 系列低频集中度极低（motor_seamless_13 仅 0.4%）、
##     谱平坦度高，是真正的宽带燃烧粗糙感，适合做质感层。
##   · ev_motor_fan 自相关仅 0.04（非周期）、>2kHz 仅 3.2%，是宽频电机
##     噪声而非纯音，不会和逆变器基频打架。
##
## 全部为 CC0 素材（授权见 assets/audio/engine/README.md）。
const TEXTURE_FILES := {
	# V8：motor_seamless_13 —— 40~90Hz 仅 0.4%，90~300Hz 占 81.6%（厚实的排气体量）
	"v8": "res://assets/audio/engine/motor_seamless_13.ogg",
	# I6：motor_seamless_12 —— 40~90Hz 仅 0.6%，中频饱满
	"i6": "res://assets/audio/engine/motor_seamless_12.ogg",
	# I4：motor_seamless_10 —— 40~90Hz 仅 1.1%，高频略多（I4 高转更亮）
	"i4": "res://assets/audio/engine/motor_seamless_10.ogg",
	# I3：motor_seamless_02 —— 40~90Hz 2.9%，粗糙度最高（三缸点火不匀）
	"i3": "res://assets/audio/engine/motor_seamless_02.ogg",
}
## EV 电机质感素材
const EV_TEXTURE := "res://assets/audio/engine/ev_motor_fan.ogg"

# --- 引擎档案 ---------------------------------------------------------------
var profile := "i6"
var fuel_type := "ice"
var aspiration := "na"
var cylinders := 6
var firing_div := 3.0          # 四冲程每转点火次数 = 缸数/2
var idle_rpm := 800.0
var redline_rpm := 6000.0
## 游戏内归一化红线（0.92~1.0，来自 cars.json）。
## 断油判定必须按这台车自己的红线走 —— 用固定阈值会让 33/45 台车永远不触发断油。
var redline_norm := 0.97
var base_harmonics: PackedFloat32Array = PackedFloat32Array()
var lope := 0.12
var sub_weight := 0.16
var pulse_sharp := 0.70
var base_gain := 1.0
var bright := 0.78
var pop := 0.60
var growl := 0.70
var has_turbo := false
var spool_rpm := 0.0
var whistle_gain := 0.0
var whistle_hz := 0.0
var bov_gain := 0.0
var induction := 0.10
var ev_tier := ""
var ev_assist := 0.0
var ev_max_whine := 1450.0
var ev_harmonic := 0.075
var ev_third := 0.030
var ev_gear_whine := 0.038
var ev_nvh := 0.13
var ev_body := 0.18

# --- 波表 -------------------------------------------------------------------
## 按转速预生成的波表组：_speed_tables[step][band] = 一张波表。
## 运行时按当前转速选组，并在相邻组之间交叉淡化，避免阶次跳变。
var _speed_tables: Array = []
var _tables_ready := false
## 当前选中的波表组索引与组内混合权重
var _speed_step := 0
var _speed_blend := 0.0

# --- 运行时状态 -------------------------------------------------------------
var _playback: AudioStreamGeneratorPlayback
var _firing_phase := 0.0        # 点火相位（1 周期 = 一次点火间隔）
var _crank_phase := 0.0         # 曲轴相位（1 周期 = 一转）
var _half_phase := 0.0          # 半频相位（lope / NVH 用）
var _ev_phase := 0.0
var _gear_phase := 0.0
var _noise := 0.0
var _noise2 := 0.0
var _noise_lp := 0.0
var _rpm := 0.0                 # 归一化转速（0.112 怠速 ~ 1.0 红线）
var _throttle := 0.0
var _speed01 := 0.0
var _gear := 1
var _last_gear := 1
var _real_rpm := 800.0
var _band := 0                  # 0 idle / 1 cruise / 2 pull / 3 redline
var _band_frac := 0.0

# 瞬态事件
var _shift_pop := 0.0           # 换挡回火
var _blow_off := 0.0            # 泄压阀
var _overrun_pop := 0.0         # 收油回火
var _limiter := 0.0             # 断油
var _last_throttle := 0.0
var _turbo_boost := 0.0         # 涡轮建立度（滞后跟随）
var _fuel_cut := 0.0            # 断油节奏相位

# 燃烧质感层（真实录音）
var _texture: AudioStreamPlayer
var _ev_texture: AudioStreamPlayer

var _profiles: Dictionary = {}


func _ready() -> void:
	var generator := AudioStreamGenerator.new()
	generator.mix_rate = MIX_RATE
	generator.buffer_length = 0.1
	stream = generator
	volume_db = -14.0
	play()
	_playback = get_stream_playback() as AudioStreamGeneratorPlayback
	_load_profiles()
	_setup_texture()
	_apply_profile()


func _load_profiles() -> void:
	if FileAccess.file_exists(PROFILE_PATH):
		var f := FileAccess.open(PROFILE_PATH, FileAccess.READ)
		if f != null:
			var parsed = JSON.parse_string(f.get_as_text())
			f.close()
			if typeof(parsed) == TYPE_DICTIONARY:
				_profiles = parsed.get("profiles", {})


## 加载真实录音燃烧质感层：按缸体族选择素材。
## 素材为等长循环；音高交给谐波骨架精确控制，纹理层只贡献"燃烧颗粒感"，
## 因此它的 pitch 只做档位驱动的微调（避免大范围变调产生磁带感）。
func _setup_texture() -> void:
	if _texture == null:
		_texture = AudioStreamPlayer.new()
		_texture.name = "EngineTexture"
		_texture.bus = "Engine"
		_texture.volume_db = -80.0
		add_child(_texture)
	if _ev_texture == null:
		_ev_texture = AudioStreamPlayer.new()
		_ev_texture.name = "EngineTextureEV"
		_ev_texture.bus = "Engine"
		_ev_texture.volume_db = -80.0
		add_child(_ev_texture)
		if ResourceLoader.exists(EV_TEXTURE):
			var ev_stream = load(EV_TEXTURE)
			if ev_stream is AudioStream:
				_set_loop(ev_stream as AudioStream)
				_ev_texture.stream = ev_stream
				_ev_texture.play()


func _texture_for_family() -> String:
	match profile:
		"v8_cross", "v8_flat":
			return String(TEXTURE_FILES.get("v8", ""))
		"i6":
			return String(TEXTURE_FILES.get("i6", ""))
		"i4":
			return String(TEXTURE_FILES.get("i4", ""))
		"i3":
			return String(TEXTURE_FILES.get("i3", ""))
	return ""


func is_ev() -> bool:
	return fuel_type == "ev"


func is_hybrid() -> bool:
	return fuel_type == "hybrid"


## 混动电驱层的逆变器主音频率（Hz）。
##
## 抽成公开函数是为了让**合成实现**和**审计工具**共用同一个公式：
## 以前审计工具只能自己抄一份公式，两边一旦不同步就会得出假的 FAIL。
## 现在审计工具直接调本函数取期望值，公式只有这一处。
func motor_tone_hz() -> float:
	if fuel_type != "hybrid":
		return 0.0
	# 电机基频随车速平滑上扬（电机的关键听感特征），负载再抬一点
	var w := lerpf(180.0, ev_max_whine, pow(clampf(_speed01, 0.0, 1.0), 0.82))
	w *= lerpf(0.94, 1.06, _throttle)
	return clampf(w, 120.0, ev_max_whine)


func set_profile(spec: Dictionary) -> void:
	fuel_type = String(spec.get("fuelType", "ice")).to_lower()
	aspiration = String(spec.get("aspiration", "na")).to_lower()
	var car_id := String(spec.get("id", ""))
	# 逐车档案优先；缺失则回退到旧的 engineProfile 粗分类
	var prof: Dictionary = {}
	if not car_id.is_empty() and _profiles.has(car_id):
		prof = _profiles[car_id]
	if prof.is_empty():
		_fallback_from_engine_profile(String(spec.get("engineProfile", "i6")))
		_apply_profile()
		return
	profile = String(prof.get("family", "i6"))
	# data/engine_sounds.json 用的是 "fuel" 键（不是 "fuelType"）。
	# 早期版本读 "fuelType" 导致 EV/混动的档案燃料类型全部落回默认值，
	# 也就是"燃油车被配了电车声音"的根因之一。这里两个键都读，以档案为准。
	var prof_fuel := String(prof.get("fuel", ""))
	if prof_fuel.is_empty():
		prof_fuel = String(prof.get("fuelType", ""))
	if not prof_fuel.is_empty():
		fuel_type = prof_fuel.to_lower()
	cylinders = int(prof.get("cylinders", 6))
	firing_div = float(prof.get("firingDiv", cylinders / 2.0))
	idle_rpm = float(prof.get("idleRpm", 800.0))
	redline_rpm = float(prof.get("redlineRpm", 6000.0))
	redline_norm = float(prof.get("redlineNorm", 0.97))
	base_harmonics = _to_f32(prof.get("base", []))
	lope = float(prof.get("lope", 0.12))
	sub_weight = float(prof.get("subWeight", 0.16))
	pulse_sharp = float(prof.get("pulseSharp", 0.70))
	base_gain = float(prof.get("gain", 1.0))
	bright = float(prof.get("bright", 0.78))
	pop = float(prof.get("pop", 0.60))
	growl = float(prof.get("growl", 0.70))
	has_turbo = bool(prof.get("turbo", false))
	spool_rpm = float(prof.get("spoolRpm", 0.0))
	whistle_gain = float(prof.get("whistle", 0.0))
	whistle_hz = float(prof.get("whistleHz", 0.0))
	bov_gain = float(prof.get("bov", 0.0))
	induction = float(prof.get("induction", 0.10))
	ev_tier = String(prof.get("evTier", ""))
	ev_assist = float(prof.get("evAssist", 0.0))
	ev_max_whine = float(prof.get("maxWhineHz", 1450.0))
	ev_harmonic = float(prof.get("harmonic", 0.075))
	ev_third = float(prof.get("third", 0.030))
	ev_gear_whine = float(prof.get("gearWhine", 0.038))
	ev_nvh = float(prof.get("nvh", 0.13))
	ev_body = float(prof.get("body", 0.18))
	_apply_profile()


func _fallback_from_engine_profile(p: String) -> void:
	match p:
		"ev":
			profile = "ev"
			fuel_type = "ev"
			ev_tier = "mainstream"
			return
		"v8":
			profile = "v8_cross"
		"v10", "v12":
			profile = "v8_flat"
		"i6", "i5":
			profile = "i6"
		"i4", "flat4", "rotary":
			profile = "i4"
		"i3":
			profile = "i3"
		"flat6":
			profile = "i6"
		_:
			profile = "i6"
	match profile:
		"v8_cross", "v8_flat":
			cylinders = 8
		"i6":
			cylinders = 6
		"i4":
			cylinders = 4
		"i3":
			cylinders = 3
	firing_div = cylinders / 2.0
	if base_harmonics.size() < 8:
		base_harmonics = _default_harmonics(profile)
	idle_rpm = 800.0
	redline_rpm = 6000.0


func _to_f32(arr) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	if typeof(arr) == TYPE_ARRAY:
		for v in arr:
			out.append(float(v))
	return out


func _default_harmonics(fam: String) -> PackedFloat32Array:
	match fam:
		"v8_cross":
			return _to_f32([1.0, 0.42, 0.30, 0.46, 0.14, 0.22, 0.09, 0.15,
				0.06, 0.10, 0.04, 0.08, 0.03, 0.06, 0.02, 0.05])
		"v8_flat":
			return _to_f32([1.0, 0.55, 0.34, 0.40, 0.20, 0.26, 0.12, 0.18,
				0.08, 0.12, 0.05, 0.09, 0.04, 0.06, 0.03, 0.05])
		"i3":
			return _to_f32([1.0, 0.52, 0.46, 0.34, 0.28, 0.22, 0.26, 0.14,
				0.18, 0.10, 0.13, 0.07, 0.09, 0.05, 0.06, 0.03])
		"i4":
			return _to_f32([1.0, 0.68, 0.40, 0.40, 0.24, 0.28, 0.16, 0.22,
				0.12, 0.16, 0.09, 0.12, 0.07, 0.09, 0.05, 0.06])
		_:
			return _to_f32([1.0, 0.58, 0.44, 0.30, 0.30, 0.18, 0.24, 0.12,
				0.16, 0.09, 0.12, 0.07, 0.08, 0.05, 0.05, 0.03])


## 档案切换后重建波表与燃烧质感层素材。
func _apply_profile() -> void:
	_build_wavetables()
	if _texture == null:
		return
	# 切换燃烧质感层素材
	var path := _texture_for_family()
	if not path.is_empty() and ResourceLoader.exists(path):
		var st = load(path)
		if st is AudioStream:
			_set_loop(st as AudioStream)
			_texture.stream = st
			_texture.play()
	elif _texture.stream != null:
		_texture.stop()
		_texture.stream = null
	# 混动：电机层独立于 ICE 层
	if _ev_texture != null:
		if fuel_type == "hybrid":
			if not _ev_texture.playing:
				_ev_texture.play()
		elif _ev_texture.playing:
			_ev_texture.stop()


# ---------------------------------------------------------------------------
# 波表构建
# ---------------------------------------------------------------------------
## 依据档位调制谐波权重，然后合成一个周期的波形。
## 档位越高，高阶谐波占比越大（排气变亮）；低阶在怠速更强（低频体量足）。
##
## 关键：谐波阶次必须按**绝对频率上限**裁剪，而不是固定取前 N 阶。
## 真实排气的谐波随频率快速衰减（3kHz 以上几乎没有能量），若按固定
## 16 阶合成，V8 在 3000rpm 时 16 阶就冲到 3.2kHz、更高的混叠到 7kHz+
## （实测 7000Hz 占 16.7%、11500Hz 占 7.5%），既刺耳又让所有缸型听感雷同。
##
## 实现：按**转速档**预生成波表组（每组含 idle/cruise/pull/redline 四张表），
## 运行时按当前转速选组并在其间交叉淡化。这样阶次上限随转速自适应，
## 又不需要每帧重建（重建 4×2048×16 次正弦太贵）。
const SPEED_STEPS := 6

func _build_wavetables() -> void:
	_speed_tables.clear()
	_tables_ready = false
	if base_harmonics.size() < 4:
		base_harmonics = _default_harmonics(profile)
	var count := mini(16, base_harmonics.size())
	# 4 个档位的高/低阶权重
	var hi_boost := [0.30, 0.72, 1.18, 1.55]
	var lo_boost := [1.34, 1.05, 0.90, 0.82]
	# 各档位的频谱上限（Hz）—— 怠速闷、大转亮、红区最亮但仍有上限
	var cutoff := [2600.0, 3400.0, 4200.0, 4800.0]
	# 预生成 SPEED_STEPS 组，每组对应一个转速区间
	for step in SPEED_STEPS:
		var frac := (float(step) + 0.5) / float(SPEED_STEPS)
		var fire_hz := maxf((idle_rpm + frac * (redline_rpm - idle_rpm)) / 60.0 * firing_div, 20.0)
		var group: Array[PackedFloat32Array] = []
		for band in 4:
			var tbl := PackedFloat32Array()
			tbl.resize(TABLE_SIZE)
			var hb: float = hi_boost[band] * bright
			var lb: float = lo_boost[band] * growl
			# 该档位下的最大有效阶次（按绝对频率上限反推）
			#
			# 下限不能是死板的 4 阶：I3/I4 的点火频率低（怠速 20~30Hz），
			# 若只保留 4 阶，它们的谐波结构就只剩基频+2+3+4，缸型特征被抹平。
			# 这里让最低保留阶次随点火频率自适应：点火频率越低，保留越多阶，
			# 保证低频缸型在中频仍有可听的谐波纹理。
			var min_order := clampi(int(ceil(1200.0 / fire_hz)), 4, 10)
			var max_order := mini(count, maxi(min_order, int(ceil(cutoff[band] / fire_hz))))
			for i in TABLE_SIZE:
				var theta := float(i) / float(TABLE_SIZE) * TAU
				var s := 0.0
				for k in max_order:
					var w := base_harmonics[k]
					if w <= 0.0:
						continue
					var order := float(k + 1)
					var bw := hb if order >= 3.0 else lb
					var par := 1.25 if (profile.begins_with("v8") and fmod(order, 2.0) < 0.5) else 1.0
					s += sin(theta * order) * w * bw * par
				# 半频低频体量（V8 的"胸腔感"）
				s += sin(theta * 0.5) * sub_weight * lb * 0.55
				tbl[i] = s * 0.30
			group.append(tbl)
		_speed_tables.append(group)
	_tables_ready = true


## 按当前转速选出波表组，并在相邻组之间交叉淡化。
## 这样阶次上限随转速平滑自适应，不会出现阶次跳变造成的"咔哒"声。
func _select_speed_tables(frac: float) -> void:
	if _speed_tables.is_empty():
		return
	var pos := clampf(frac, 0.0, 1.0) * float(SPEED_STEPS)
	var idx := clampi(int(floor(pos)), 0, SPEED_STEPS - 1)
	var blend := pos - float(idx)
	# 最后一组不向后混合
	if idx >= SPEED_STEPS - 1:
		idx = SPEED_STEPS - 2
		blend = 1.0
	_speed_step = idx
	_speed_blend = blend


## 取当前档位在两个转速组之间的混合采样值（带线性插值）。
func _table_sample(tbl_a: PackedFloat32Array, tbl_b: PackedFloat32Array, phase: float) -> float:
	var tp := phase * float(TABLE_SIZE)
	var ti := int(tp)
	var tf := tp - float(ti)
	var ti2 := (ti + 1) % TABLE_SIZE
	var va: float = tbl_a[ti] * (1.0 - tf) + tbl_a[ti2] * tf
	if _speed_blend <= 0.001:
		return va
	var vb: float = tbl_b[ti] * (1.0 - tf) + tbl_b[ti2] * tf
	return va * (1.0 - _speed_blend) + vb * _speed_blend


# ---------------------------------------------------------------------------
# 状态更新
# ---------------------------------------------------------------------------
func update_sound(rpm: float, throttle: float, speed01: float, gear: int,
		fuel_cut: int = -1) -> void:
	_rpm = clampf(rpm, 0.0, 1.15)
	_throttle = clampf(absf(throttle), 0.0, 1.0)
	_speed01 = clampf(speed01, 0.0, 1.0)
	_gear = maxi(gear, 1)
	if _gear != _last_gear:
		_last_gear = _gear
		_shift_pop = 1.0
		# 收油换挡：涡轮泄压
		if has_turbo and bov_gain > 0.0:
			_blow_off = bov_gain
	# 收油回火：高转突然松油门
	if _last_throttle > 0.55 and _throttle < 0.12 and _rpm > 0.62:
		_overrun_pop = pop
	_last_throttle = _throttle
	# 断油（红区 limiter）。
	# fuel_cut 是**三态**：
	#   1 = 车辆确实在断油（权威，来自 car.gd 的 limiter_active）
	#   0 = 车辆明确没有断油（权威，不要自己推断）
	#  -1 = 调用方没提供（仅调试/审计用），此时才按这台车自己的归一化红线推断。
	# 早先用 bool 两态时，false 与"未提供"无法区分，车辆还没断油但转速过线时
	# 引擎会自行断油（实测 33/45 台车出现"幽灵断油"），所以这里必须用 int 三态。
	if fuel_cut >= 0:
		_limiter = 1.0 if fuel_cut == 1 else 0.0
	else:
		# 兜底推断阈值必须和 car.gd 的断油阈值一致（0.998），否则会出现
		# "车还在给油、引擎却已经熄火"的错位。car.gd 用 0.998 是因为顶挡
		# 极速恰好等于红线，阈值高于红线就永远触发不了（详见 car.gd 注释）。
		_limiter = 1.0 if _rpm >= redline_norm * 0.998 else 0.0
	# 真实转速换算（归一化 → rpm）。
	# 基准用这台车自己的归一化红线，而不是写死的 0.9 —— 否则红线 0.92 的车
	# 永远到不了自己的红线，1.0 的车又提前很久就到顶，转速与档位都会失真。
	var span := maxf(redline_norm - 0.112, 0.05)
	var frac := clampf((_rpm - 0.112) / span, 0.0, 1.25)
	_real_rpm = idle_rpm + frac * (redline_rpm - idle_rpm)
	_band_frac = clampf(frac, 0.0, 1.0)
	_band = _band_for(frac)
	_select_speed_tables(_band_frac)
	# 涡轮建立度：滞后跟随（spool 有延迟）
	var boost_target := 0.0
	if has_turbo:
		boost_target = clampf((_real_rpm - spool_rpm) / maxf(redline_rpm - spool_rpm, 1.0), 0.0, 1.0)
		boost_target *= clampf(_throttle * 1.3, 0.0, 1.0)
	_turbo_boost = lerpf(_turbo_boost, boost_target, 0.06)
	_fill_buffer()


## 依据归一化转速位置选择音色档位。
## 0 = 怠速，1 = 巡航，2 = 大转，3 = 红区。
func _band_for(frac: float) -> int:
	if frac < 0.16:
		return 0
	if frac < 0.55:
		return 1
	if frac < 0.92:
		return 2
	return 3


# ---------------------------------------------------------------------------
# 音频缓冲
# ---------------------------------------------------------------------------
func _fill_buffer() -> void:
	if _playback == null:
		return
	var frames := _playback.get_frames_available()
	if frames <= 0:
		return
	var buffer := PackedVector2Array()
	buffer.resize(frames)
	var load := 0.22 + _throttle * 0.78
	if fuel_type == "ev":
		_fill_ev(buffer, frames, load)
	else:
		_fill_ice(buffer, frames, load)
	_playback.push_buffer(buffer)


func _fill_ice(buffer: PackedVector2Array, frames: int, load: float) -> void:
	if not _tables_ready:
		_build_wavetables()
	# --- 真实点火频率 ---
	var fire_hz := _real_rpm / 60.0 * firing_div
	fire_hz = clampf(fire_hz, 8.0, 1200.0)
	var fire_inc := fire_hz / MIX_RATE
	var half_inc := fire_inc * 0.5

	# --- 涡轮哨声频率随转速上扬 ---
	# 物理依据：哨声频率 = 涡轮轴速 × 叶片数。涡轮轴随发动机转速线性上升，
	# 所以哨声必须**随转速持续上扬**才有"涡轮建立"的感觉。
	# 档案 whistleHz=2900/3400 是红线处的目标频率，乘 0.52 得到涡轮刚建立
	# 时的频率（下限 0.52 = spool 刚过时的轴速比），再随转速升到 0.92。
	#
	# 上限放宽到 4200Hz：真实乘用车涡轮的哨声主要能量就在 2~6kHz，
	# 早先版本把上限压到 1950Hz 是基于一次**被证伪的质心测量**（Goertzel
	# 幅度加权法把 583Hz 的标定信号测成 1931Hz），压掉了哨声随转速上扬的
	# 听感特征。现在上限只用来防止哨声跑到刺耳区（>6kHz），
	# 真正的"不掩盖点火基频"由 0.12 的增益系数保证。
	var whistle_f := 0.0
	var whistle_amp := 0.0
	if has_turbo and _turbo_boost > 0.02:
		whistle_f = whistle_hz * (0.52 + 0.40 * clampf(_real_rpm / maxf(redline_rpm, 1.0), 0.0, 1.4))
		whistle_f = minf(whistle_f, 4200.0)
		whistle_amp = whistle_gain * _turbo_boost
	var whistle_inc := whistle_f / MIX_RATE
	var whistle_phase := 0.0

	var amp := (0.06 + _speed01 * 0.05 + _throttle * 0.11) * base_gain
	# 怠速要听得见、大转要够凶
	amp *= lerpf(1.25, 0.92, clampf(_rpm, 0.0, 1.0))

	var group_a: Array = _speed_tables[_speed_step] if _speed_step < _speed_tables.size() else []
	var group_b: Array = _speed_tables[mini(_speed_step + 1, _speed_tables.size() - 1)] \
		if not _speed_tables.is_empty() else []
	var tbl_a: PackedFloat32Array = group_a[_band] if _band < group_a.size() else PackedFloat32Array()
	var tbl_b: PackedFloat32Array = group_b[_band] if _band < group_b.size() else tbl_a
	var mech_amt := (0.10 + induction * 0.5) * (0.35 + _throttle * 0.65) \
		* (0.55 + 0.45 * clampf(_rpm, 0.0, 1.0))
	# lope 深度：怠速最明显
	var lope_depth := lope * (1.0 if _band == 0 else 0.45)
	var lope_rate := half_inc * 2.0

	for i in frames:
		# --- 相位推进 ---
		_firing_phase = fposmod(_firing_phase + fire_inc, 1.0)
		_half_phase = fposmod(_half_phase + half_inc, 1.0)

		# --- 波表查表（两组交叉淡化 + 线性插值）---
		var sample := _table_sample(tbl_a, tbl_b, _firing_phase)

		# --- 怠速 lope：点火不齐造成的慢速起伏 ---
		if lope_depth > 0.0:
			_lope_sin = sin(_half_phase * TAU)
			sample *= 1.0 - lope_depth * 0.5 * (0.5 + 0.5 * _lope_sin)

		# --- 排气脉冲锐度：低转更"顿"，高转更连续 ---
		if pulse_sharp > 0.0:
			var s_env := sin(_firing_phase * TAU)
			sample *= 1.0 + pulse_sharp * 0.30 * (pow(maxf(s_env, 0.0), 6.0) - 0.5)

		# --- 机械噪声：带限噪声（不是白噪声）---
		# 真实引擎的机械噪声（气门、链条、进气）集中在 150Hz~2.5kHz，
		# 高频几乎没有能量。若用白噪声，宽带能量会把频谱质心拉到 4kHz+，
		# 既听着"嘶嘶"又让所有缸型听感雷同。
		#
		# 两级滤波：_noise2 是一阶低通（截止 ~2.4kHz），_noise_lp 是更慢的
		# 低通，两者相减得到高通，去掉 120Hz 以下的漂移与隆隆声。
		var n := randf_range(-1.0, 1.0)
		_noise = lerpf(_noise, n, 0.06)
		_noise2 = lerpf(_noise2, n, 0.22)
		# 高通（去掉 120Hz 以下的直流漂移）
		var hp := _noise2 - _noise_lp
		_noise_lp = lerpf(_noise_lp, _noise2, 0.04)
		var mech := (_noise2 * 0.45 + hp * 0.55) * 0.5
		sample += mech * mech_amt * 0.30

		# --- 涡轮哨声：受 boost 控制的中频气流音 ---
		# 量级刻意压低（*0.12），确保它只是"背景层"，不掩盖点火基频的缸型特征。
		if whistle_amp > 0.0:
			whistle_phase = fposmod(whistle_phase + whistle_inc, 1.0)
			sample += sin(whistle_phase * TAU) * whistle_amp * 0.12
			# 用噪声成分而非二次谐波来表现"气流"，避免产生新的尖锐峰
			sample += _noise2 * whistle_amp * 0.06

		# --- 瞬态 ---
		if _shift_pop > 0.001:
			_shift_pop = maxf(0.0, _shift_pop - float(frames) / MIX_RATE * 5.0)
			sample += _noise * _shift_pop * 0.28 * pop
		if _blow_off > 0.001:
			_blow_off = maxf(0.0, _blow_off - float(frames) / MIX_RATE * 1.8)
			# 泄压阀：高频气流噪声
			sample += _noise2 * _blow_off * 0.34
		if _overrun_pop > 0.001:
			_overrun_pop = maxf(0.0, _overrun_pop - float(frames) / MIX_RATE * 6.5)
			sample += _noise * _overrun_pop * 0.30
			sample += sin(_firing_phase * TAU * 0.5) * _overrun_pop * 0.10

		# --- 断油：点火断续 + 哒哒机械声 ---
		#
		# 关键：门限**必须是平滑的**，不能用方波。
		# 方波的陡峭边沿在频谱上等于给每个谐波加一对宽带边带，
		# 实测 ICE 红区 >6kHz 能量占比因此高达 2.09%（pandem_m3_e92/redline），
		# 是 EV 最差值（0.33%）的 6.3 倍 —— 听着像"金属啸叫"而不是"断油顿挫"。
		# 改成升余弦门（raised cosine）后边带被压回谐波本体的包络内。
		if _limiter > 0.0:
			# 用点火频率的一半做断续门限，转速越高断续越细密
			var cut_freq := clampf(fire_hz * 0.5, 8.0, 60.0)
			_fuel_cut = fposmod(_fuel_cut + cut_freq / MIX_RATE, 1.0)
			# 断续：升余弦门。0.45 处为点火窗口中心，窗口宽 0.45，
			# 两侧用余弦平滑过渡到 0.12 的"熄火"电平。
			var ph := _fuel_cut / 0.45 if _fuel_cut < 0.45 else (1.0 - _fuel_cut) / 0.55
			ph = clampf(ph, 0.0, 1.0)
			var gate := 0.12 + 0.88 * (0.5 - 0.5 * cos(ph * PI))
			# 熄火窗口里没有燃烧声，只有机械哒哒声
			sample *= gate
			sample += _noise * (1.0 - gate) * 0.16

		sample = clampf(sample, -1.0, 1.0)
		buffer[i] = Vector2(sample * amp, sample * amp)

	# --- 混动：叠加电驱合成层 ---
	# 混动车的声音是**两层**的：内燃机的点火声 + 电机的逆变器上扬。
	# 早期版本只加了真实电机录音当质感层，听起来就是"燃油车+一层模糊噪声"，
	# 完全没有混动的特征。这里补上程序化的电驱层：
	#   · 电机基频随车速平滑上扬（电机的关键听感特征）
	#   · 参与度 ev_assist 决定电机在总声场里的比重
	#   · 低速时电机主导（EV 模式），高速时内燃机接管
	if fuel_type == "hybrid":
		var m_whine := motor_tone_hz()
		var m_inc := m_whine / MIX_RATE
		# 电机音量跟着**油门**走，而不是一直响。
		#
		# 物理依据：电机只在真正出力时才发出明显啸叫。原式 (0.55+油门·0.45)
		# 意味着即使完全不踩油门，电机仍有 55% 的音量——实测怠速时电驱层
		# 占了整台车总能量的 78%，V8 的怠速"突突"声被压到听不见，
		# 听起来就是"燃油车被配了电车声音"（用户明确抱怨过这一点）。
		# 改成 (0.15+油门·0.85) 后：怠速只剩极轻的电流声（纯内燃机），
		# 起步/大油门时电机才明显介入，符合真实混动的行为。
		var motor_load := clampf(_throttle, 0.0, 1.0)
		var m_amp := ev_assist * lerpf(0.085, 0.035, clampf(_speed01, 0.0, 1.0)) * (0.15 + motor_load * 0.85)
		for i in frames:
			_ev_phase = fposmod(_ev_phase + m_inc, 1.0)
			var m := sin(_ev_phase * TAU) * 0.72
			m += sin(_ev_phase * TAU * 2.0) * ev_harmonic
			m += sin(_ev_phase * TAU * 3.0) * ev_third
			# NVH：电机本体的低频振动
			_half_phase = fposmod(_half_phase + m_inc * 0.5, 1.0)
			m += sin(_half_phase * TAU) * ev_nvh * 0.6
			buffer[i] = Vector2(buffer[i].x + m * m_amp, buffer[i].y + m * m_amp)

	# 燃烧质感层：真实录音音量与转速/负载联动
	if _texture != null and _texture.stream != null:
		var t_amp := lerpf(-26.0, -13.0, clampf(_throttle * 0.7 + _band_frac * 0.5, 0.0, 1.0))
		_texture.volume_db = t_amp
		# 音高由谐波骨架精确控制，纹理层只做档位驱动的微调
		_texture.pitch_scale = lerpf(0.94, 1.08, _band_frac)

	# 混动：真实电机录音质感层（叠加在程序化电驱层之上，只贡献宽带粗糙感）
	if _ev_texture != null and fuel_type == "hybrid" and _ev_texture.stream != null:
		_ev_texture.volume_db = lerpf(-34.0, -24.0, clampf(ev_assist * (0.4 + _throttle * 0.6), 0.0, 1.0))
		_ev_texture.pitch_scale = lerpf(0.96, 1.10, clampf(_speed01, 0.0, 1.0))


func _fill_ev(buffer: PackedVector2Array, frames: int, load: float) -> void:
	# --- EV 电机：逆变器基频随车速上升 ---
	# 旧版是 140→2590Hz 的纯正弦 + 6 阶谐波，正是"尖锐啸叫"的来源。
	# 新版：基频上限按车型分档封顶（城市车 900Hz / 超跑 2250Hz），
	# 谐波只保留 2 阶与 3 阶的极小量，并加入 NVH 低频与齿轮啸叫，
	# 让声音从"刺耳"变成"顺滑上扬"。
	var speed_frac := clampf(_speed01, 0.0, 1.0)
	var whine := lerpf(180.0, ev_max_whine, pow(speed_frac, 0.82))
	# 负载会让基频再抬一点（电机扭矩电流变化）
	whine *= lerpf(0.94, 1.06, _throttle)
	whine = clampf(whine, 120.0, ev_max_whine)
	var whine_inc := whine / MIX_RATE
	# 齿轮啸叫：跟随车速的独立高频成分，音量低
	# 上限压到 2.6kHz：真实 EV 的齿轮啸叫是"细微沙沙"，不该盖过电机基频，
	# 否则整台车听感就变成一段尖锐的电子高音（实测质心会冲到 4.1kHz）。
	var gear_f := lerpf(700.0, 2600.0, pow(speed_frac, 0.9))
	var gear_inc := gear_f / MIX_RATE
	# NVH：电机本体的低频振动
	var nvh_f := lerpf(60.0, 220.0, speed_frac)
	var nvh_inc := nvh_f / MIX_RATE

	var amp := (0.020 + _throttle * 0.052 + _speed01 * 0.030) * base_gain
	amp *= lerpf(1.15, 0.90, speed_frac)
	for i in frames:
		_ev_phase = fposmod(_ev_phase + whine_inc, 1.0)
		_gear_phase = fposmod(_gear_phase + gear_inc, 1.0)
		_half_phase = fposmod(_half_phase + nvh_inc, 1.0)

		var sample := sin(_ev_phase * TAU) * 0.72
		# 极少量谐波：保留电机的"电子感"但不刺耳
		sample += sin(_ev_phase * TAU * 2.0) * ev_harmonic
		sample += sin(_ev_phase * TAU * 3.0) * ev_third
		# 齿轮啸叫：量级刻意压低，保持"背景沙沙"而非主旋律
		sample += sin(_gear_phase * TAU) * ev_gear_whine * 0.55
		# NVH 低频体量
		sample += sin(_half_phase * TAU) * ev_nvh
		# 电机体的低频"哼"
		sample += sin(_half_phase * TAU * 2.0) * ev_body * 0.5
		# 轻微的电流纹波，让纯音不至于太"电子"
		var n := randf_range(-1.0, 1.0)
		_noise = lerpf(_noise, n, 0.05)
		sample += _noise * 0.035 * (0.4 + _throttle * 0.6)

		sample = clampf(sample, -1.0, 1.0)
		buffer[i] = Vector2(sample * amp, sample * amp)

	# EV 质感层（真实电机录音）
	if _ev_texture != null and _ev_texture.stream != null:
		_ev_texture.volume_db = lerpf(-28.0, -15.0, clampf(_throttle * 0.6 + speed_frac * 0.6, 0.0, 1.0))
		_ev_texture.pitch_scale = lerpf(0.94, 1.12, speed_frac)


## lope 相位的缓存（避免在采样循环里重复三角函数）
var _lope_sin := 0.0


## 循环播放：AudioStreamWAV 没有 `loop` 属性（Godot 4 用 loop_mode），
## 直接赋值会在运行时报错。Ogg / MP3 用 loop，WAV 用 loop_mode。
func _set_loop(stream: AudioStream) -> void:
	if stream == null:
		return
	if stream is AudioStreamWAV:
		(stream as AudioStreamWAV).loop_mode = AudioStreamWAV.LOOP_FORWARD
		(stream as AudioStreamWAV).loop_end = 0
	else:
		stream.loop = true
