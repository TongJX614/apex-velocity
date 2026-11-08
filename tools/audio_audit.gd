extends SceneTree
## 引擎声渲染审计 —— 逐车、逐档位渲染引擎声并输出客观测量数据。
##
## 目的：用数据证明改造有效，而不是靠主观听感。
##   · 点火基频：验证 V8/V6/I4/I3 的基频关系符合物理（缸数/2 × rpm/60）
##   · 峰值/RMS/削波率：验证无削波、音量一致
##   · 档位区分度：验证 idle / cruise / pull / redline 四档音色确实不同
##   · 逐车档案生效：验证每台车用的是自己的缸数/转速区间，而不是回退到默认族
##
## 频谱分析（频谱质心 / 谐波结构 / 分频段能量）不在本文件里做：
## GDScript 里原先用的 Goertzel 幅度加权法测质心是**无效**的
## （用已知信号标定时偏差达 3 倍以上：理论 583Hz 测成 1931Hz）。
## 频谱部分改由 tools/analyze_engine_spectrum.py 用 numpy FFT 完成，
## 本文件只负责渲染 WAV + 输出时域指标 + 写 manifest。
##
## 用法：
##   "$GODOT" --headless --path . --script res://tools/audio_audit.gd
## 产出：
##   /tmp/engine_audio_samples/<scene>/<car_id>.wav
##   /tmp/engine_audio_manifest.json
##
## 注意：本工具在隔离沙盒里运行（不依赖主项目的其它脚本），因为主项目
## 可能有其它会话正在并行编辑。本脚本只依赖 engine_audio.gd 与
## data/engine_sounds.json。

const ENGINE_AUDIO := preload("res://scripts/core/engine_audio.gd")
const PROFILE_JSON := "res://data/engine_sounds.json"
const OUT_DIR := "/tmp/engine_audio_samples"
const OUT_MANIFEST := "/tmp/engine_audio_manifest.json"

const MIX_RATE := 44100
## 每台车渲染的时长（秒）
const RENDER_SECONDS := 1.0
## 采样点：与真实游戏一致的档位采样
const SCENES := [
	{"name": "idle", "rpm": 0.112, "throttle": 0.0, "speed": 0.0},
	{"name": "cruise", "rpm": 0.45, "throttle": 0.35, "speed": 0.35},
	{"name": "pull", "rpm": 0.80, "throttle": 0.95, "speed": 0.7},
	# 红区：转速取**这台车自己的归一化红线**，而不是写死的 0.99。
	# 写死 0.99 时，红线 0.94 的车 rpm 已经冲过红线（引擎会自行进入断油），
	# 红线 1.0 的车却还差一截——同一个数字对 45 台车是 45 种含义。
	# 取自己的红线，"红区"才是名副其实的红区。
	{"name": "redline", "rpm": "redline", "throttle": 1.0, "speed": 0.9},
	# 断油档：与红区同转速同油门，但强制切断点火。
	# 用来客观验证"断油之后是什么声音"：点火断续门 + 机械哒哒声，
	# 应该比正常红区明显更"稀"，同时不能出现刺耳的高频边带。
	{"name": "fuelcut", "rpm": "redline", "throttle": 1.0, "speed": 0.9, "fuel_cut": 1},
]


func _init() -> void:
	var profiles := _load_profiles()
	if profiles.is_empty():
		push_error("无法加载 %s" % PROFILE_JSON)
		quit(1)
		return
	for s in SCENES:
		DirAccess.make_dir_recursive_absolute("%s/%s" % [OUT_DIR, String(s["name"])])

	var manifest := []
	var mismatches := []
	var clipped := []

	# ---- 逐车逐档位渲染 ----
	for car_id in profiles.keys():
		var prof: Dictionary = profiles[car_id]
		var is_hybrid := String(prof.get("fuel", "ice")) == "hybrid"
		for scene in SCENES:
			var res := _render_car(car_id, prof, String(scene["name"]), "full")
			if res.is_empty():
				continue
			if String(res.get("profile_mismatch", "")) != "":
				mismatches.append("%s: %s" % [car_id, String(res["profile_mismatch"])])
			if float(res["clip_pct"]) > 0.1:
				clipped.append("%s/%s" % [car_id, String(scene["name"])])
			manifest.append(res)

			# 混动车额外渲染一份"仅内燃机层"的样本。
			# 原因：混动是**双声源**（点火谐波 + 逆变器主音），在完整混音里
			# 逆变器音可能比点火基频还强（例如 bmw_i8 巡航 911.7Hz vs 86.0Hz），
			# "取最强峰"的基频检测器会锁到电机音上去，得出假的 FAIL。
			# 电驱层是完全可加的（ICE 之后单独叠加），把它关掉就能拿到干净的
			# 内燃机层，两层分开测、各测各的。
			if is_hybrid:
				var res2 := _render_car(car_id, prof, String(scene["name"]), "iceonly")
				if res2.is_empty():
					continue
				if String(res2.get("profile_mismatch", "")) != "":
					mismatches.append("%s(iceonly): %s" % [car_id, String(res2["profile_mismatch"])])
				if float(res2["clip_pct"]) > 0.1:
					clipped.append("%s/%s(iceonly)" % [car_id, String(scene["name"])])
				manifest.append(res2)

	# ---- 写 manifest ----
	var f := FileAccess.open(OUT_MANIFEST, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({"mix_rate": MIX_RATE, "samples": manifest}))
		f.close()

	# ---- 控制台摘要 ----
	print("=".repeat(78))
	print("引擎声渲染审计 —— 摘要")
	print("=".repeat(78))
	print("档案车数: %d    渲染样本数: %d" % [profiles.size(), manifest.size()])
	print("样本目录: %s/<scene>/<car_id>.wav" % OUT_DIR)
	print("manifest: %s" % OUT_MANIFEST)
	print("")
	if mismatches.is_empty():
		print("逐车档案生效: PASS (45 台车全部命中 data/engine_sounds.json 的专属档案)")
	else:
		print("逐车档案生效: FAIL")
		for m in mismatches:
			print("   %s" % m)
	print("削波检查: %s" % ("PASS (无样本削波)" if clipped.is_empty() \
		else "FAIL -> " + ", ".join(clipped)))
	var hyb_ice := 0
	for m in manifest:
		if String(m.get("fuel", "")) == "hybrid" and String(m.get("layer", "")) == "iceonly":
			hyb_ice += 1
	print("混动分层渲染: %d 个 ICE 单层样本（与完整混音样本一一对应）" % hyb_ice)
	print("")
	print("频谱分析请运行: python3 tools/analyze_engine_spectrum.py")
	quit(0)


# ---------------------------------------------------------------------------
# 渲染
# ---------------------------------------------------------------------------
func _render_car(car_id: String, prof: Dictionary, scene_name: String,
		layer: String = "full") -> Dictionary:
	var ea = ENGINE_AUDIO.new()
	# 关键：EngineAudio 的档案表是在 _ready() 里加载的。审计工具不把节点挂进
	# 场景树（headless 下不需要 AudioServer），所以 _ready() 不会执行，必须
	# 显式调用 _load_profiles()。否则 _profiles 为空，set_profile() 会走
	# _fallback_from_engine_profile()，而 "v8_cross"/"i6" 这类族名不在那条
	# match 分支里 → 所有 ICE 车都退化成默认 i6（idle 800 / redline 6000 /
	# firingDiv 3.0），渲染出来频谱完全一致，根本区分不出缸型。
	ea._load_profiles()
	ea.set_profile({
		"id": car_id,
		"fuelType": prof.get("fuel", "ice"),
		"aspiration": "na",
		"engineProfile": String(prof.get("family", "i6")),
	})
	# "iceonly" 层：把电机参与度清零，只留内燃机层。
	# 电驱层在 _fill_ice 末尾是**纯叠加**的（m_amp = ev_assist × …），
	# 因此 ev_assist=0 得到的就是完整混音里内燃机层的原样。
	if layer == "iceonly":
		ea.ev_assist = 0.0

	# 校验档案确实被逐车档案接管（而不是回退到默认族）
	var mismatch := ""
	var prof_fuel := String(prof.get("fuel", "ice"))
	if String(ea.profile) != String(prof.get("family", "i6")):
		mismatch = "族不符 期望=%s 实际=%s" % [String(prof.get("family", "")), ea.profile]
	elif String(ea.fuel_type) != prof_fuel:
		mismatch = "燃料不符 期望=%s 实际=%s" % [prof_fuel, ea.fuel_type]
	# 缸数只对内燃机有意义：EV 没有内燃机，档案里也不写 cylinders
	elif prof_fuel != "ev" and int(ea.cylinders) != int(prof.get("cylinders", 0)):
		mismatch = "缸数不符 期望=%d 实际=%d" % [int(prof.get("cylinders", 0)), ea.cylinders]
	elif prof_fuel != "ev" and absf(ea.idle_rpm - float(prof.get("idleRpm", 0.0))) > 1.0:
		mismatch = "怠速不符 期望=%.0f 实际=%.0f" % [float(prof.get("idleRpm", 0.0)), ea.idle_rpm]

	var scene := {}
	for s in SCENES:
		if String(s["name"]) == scene_name:
			scene = s
			break
	if scene.is_empty():
		scene = SCENES[2]

	# 这台车自己的归一化红线（与 engine_audio.gd 用的是同一个来源）
	var redline_norm := float(prof.get("redlineNorm", 0.97))
	# 场景转速："redline" 是占位符，替换成这台车自己的红线
	var scene_rpm := float(scene["rpm"]) if typeof(scene["rpm"]) != TYPE_STRING \
		else redline_norm
	# fuel_cut 是三态：1 = 确实在断油，0 = 明确没断油，-1 = 未提供（引擎自行推断）。
	# 四个正常档位显式传 0（"车还在正常给油"），"fuelcut" 档传 1。
	# 不显式传 0 的话，红区档的转速已经等于红线，引擎的兜底推断会自行进入
	# 断油状态，红区与断油两个样本就完全一样，A/B 对比就没意义了。
	var fuel_cut := int(scene.get("fuel_cut", 0))
	ea.update_sound(scene_rpm, float(scene["throttle"]),
		float(scene["speed"]), 3, fuel_cut)
	# 期望的逆变器主音频率。直接调引擎的公开函数取，公式只有一处，
	# 不会因为"实现改了、测试没改"而得出假的 FAIL。非混动车返回 0。
	var expect_motor_hz := ea.motor_tone_hz()

	# 直接调用内部合成（绕过 AudioServer，保证 headless 下能取到样本）
	var total := int(MIX_RATE * RENDER_SECONDS)
	var samples := PackedFloat32Array()
	samples.resize(total)
	var idx := 0
	# 预热 0.15s 让相位/滤波/涡轮建立进入稳态
	var warm := int(MIX_RATE * 0.15)
	# 固定随机种子：机械噪声层用全局 RNG，不播种的话同一台车两次渲染的
	# 噪声序列不同，"完整混音 − ICE 单层" 就减不干净。播种后两层共用
	# 同一条噪声轨迹，差值恰好等于电驱层。
	seed(abs(hash(car_id + "|" + scene_name)))
	for i in warm:
		ea.update_sound(scene_rpm, float(scene["throttle"]),
			float(scene["speed"]), 3, fuel_cut)
	while idx < total:
		var frames := int(MIX_RATE * 0.05)
		var buf := PackedVector2Array()
		buf.resize(frames)
		ea._fill_ice(buf, frames, 1.0) if String(prof.get("fuel", "ice")) != "ev" \
			else ea._fill_ev(buf, frames, 1.0)
		for i in frames:
			if idx >= total:
				break
			samples[idx] = buf[i].x
			idx += 1
	ea.free()

	# 时域指标
	var peak := 0.0
	var sum_sq := 0.0
	var clip_count := 0
	for i in samples.size():
		var v := samples[i]
		peak = maxf(peak, absf(v))
		sum_sq += v * v
		if absf(v) >= 0.999:
			clip_count += 1
	var rms := sqrt(sum_sq / float(maxi(samples.size(), 1)))

	# 期望点火频率（物理真值，供 numpy 分析器交叉核对）
	# 换算基准必须和 engine_audio.gd 完全一致：
	#   frac = (rpm - 0.112) / (redline_norm - 0.112)
	# 引擎声按**每台车自己的归一化红线**换算真实转速，这里若用固定 0.9 基准，
	# 两边就会得出不同的 rpm，基频比对会误判 FAIL。
	var frac := clampf((scene_rpm - 0.112) / maxf(redline_norm - 0.112, 0.05), 0.0, 1.25)
	var real_rpm := float(prof.get("idleRpm", 800.0)) \
		+ frac * (float(prof.get("redlineRpm", 6000.0)) - float(prof.get("idleRpm", 800.0)))
	var fire_hz := real_rpm / 60.0 * float(prof.get("firingDiv", 3.0))

	var out_path := "%s/%s/%s%s.wav" % [OUT_DIR, scene_name, car_id,
		".iceonly" if layer == "iceonly" else ""]
	_write_wav(out_path, samples)

	return {
		"car_id": car_id,
		"tag": String(prof.get("tag", car_id)),
		"scene": scene_name,
		"layer": layer,
		"file": out_path,
		"fuel": String(prof.get("fuel", "ice")),
		"family": String(prof.get("family", "i6")),
		"cylinders": int(prof.get("cylinders", 0)),
		"firing_div": float(prof.get("firingDiv", 0.0)),
		"idle_rpm": float(prof.get("idleRpm", 0.0)),
		"redline_rpm": float(prof.get("redlineRpm", 0.0)),
		"redline_norm": redline_norm,
		"real_rpm": real_rpm,
		"expect_fire_hz": fire_hz,
		"expect_motor_hz": expect_motor_hz,
		"fuel_cut": fuel_cut,
		"peak": peak,
		"rms": rms,
		"clip_pct": float(clip_count) / float(maxi(samples.size(), 1)) * 100.0,
		"profile_mismatch": mismatch,
	}


func _write_wav(path: String, samples: PackedFloat32Array) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	var data := PackedByteArray()
	data.resize(samples.size() * 2)
	for i in samples.size():
		data.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32767.0))
	f.store_buffer(_wav_header(samples.size()))
	f.store_buffer(data)
	f.close()


func _wav_header(frames: int) -> PackedByteArray:
	var h := PackedByteArray()
	h.resize(44)
	var data_size := frames * 2
	h.encode_u8(0, 0x52); h.encode_u8(1, 0x49); h.encode_u8(2, 0x46); h.encode_u8(3, 0x46)
	h.encode_u32(4, 36 + data_size)
	h.encode_u8(8, 0x57); h.encode_u8(9, 0x41); h.encode_u8(10, 0x56); h.encode_u8(11, 0x45)
	h.encode_u8(12, 0x66); h.encode_u8(13, 0x6D); h.encode_u8(14, 0x74); h.encode_u8(15, 0x20)
	h.encode_u32(16, 16)
	h.encode_u16(20, 1)
	h.encode_u16(22, 1)
	h.encode_u32(24, MIX_RATE)
	h.encode_u32(28, MIX_RATE * 2)
	h.encode_u16(32, 2)
	h.encode_u16(34, 16)
	h.encode_u8(36, 0x64); h.encode_u8(37, 0x61); h.encode_u8(38, 0x74); h.encode_u8(39, 0x61)
	h.encode_u32(40, data_size)
	return h


# ---------------------------------------------------------------------------
# 辅助
# ---------------------------------------------------------------------------
func _load_profiles() -> Dictionary:
	if not FileAccess.file_exists(PROFILE_JSON):
		push_error("缺少 %s" % PROFILE_JSON)
		return {}
	var f := FileAccess.open(PROFILE_JSON, FileAccess.READ)
	if f == null:
		return {}
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	return parsed.get("profiles", {})
