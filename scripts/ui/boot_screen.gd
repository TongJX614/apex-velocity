class_name BootScreen
extends CanvasLayer
## 启动宣传片 · 商业赛车游戏开幕式。
## 有真实 CG（assets/video/launch.ogv）时播放 CG，并叠加品牌 HUD 边框、
## 进度条、跳过提示；没有视频时用程序化 key art 蒙太奇 + 标题动画。
## 信号 finished 与 10 秒左右时长保持不变。

signal finished

const SHOTS := [
	{"path": "res://assets/backdrops/coast.png", "cn": "翡翠海岸", "en": "COASTAL RUN", "sub": "碧海蓝天 · 高速海岸线"},
	{"path": "res://assets/backdrops/alpine.png", "cn": "雪山隘口", "en": "ALPINE PASS", "sub": "连续发卡弯 · 云端之上"},
	{"path": "res://assets/backdrops/city.png", "cn": "霓虹都市", "en": "NEON CITY", "sub": "霓虹赛道 · 午夜狂飙"},
	{"path": "res://assets/backdrops/canyon.png", "cn": "赤岩峡谷", "en": "RED CANYON", "sub": "红色岩壁 · 极限贴弯"},
	{"path": "res://assets/backdrops/skyline.png", "cn": "天际环城", "en": "SKYLINE CIRCUIT", "sub": "黄昏城市 · 天际线冲刺"},
	{"path": "res://assets/backdrops/glacier.png", "cn": "极地冰川", "en": "GLACIER EDGE", "sub": "冰雪路面 · 低温抓地"},
	{"path": "res://docs/m32/menu-car-in-scene-coast.png", "cn": "选择你的赛车", "en": "CHOOSE YOUR MACHINE", "sub": "46 台赛车 · 车库改装 · 生涯大奖赛"},
]

const ACCENT := UIStyle.ACCENT

var _root: Control
var _shot: TextureRect
var _flash: ColorRect
var _fade: ColorRect
var _caption_cn: Label
var _caption_en: Label
var _caption_sub: Label
var _caption_line: ColorRect
var _brand: Label
var _brand_sub: Label
var _skip: Label
var _skip_key: Label
var _start_hint: Label
var _progress: ColorRect
var _progress_bg: Control
var _progress_pct: Label
var _progress_segments: Array[ColorRect] = []
var _frame: UIFrame
var _time := 0.0
var _finishing := false
var _video: VideoStreamPlayer
var _video_ready := false


func _ready() -> void:
	layer = 95
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()


func _build() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UIStyle.apply_theme(_root)
	add_child(_root)
	var black := ColorRect.new()
	black.color = Color(0.0, 0.0, 0.0, 1.0)
	black.set_anchors_preset(Control.PRESET_FULL_RECT)
	black.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(black)

	# 真实 CG：只放一遍，叠加品牌 HUD
	var vpath := "res://assets/video/launch.ogv"
	if not ResourceLoader.exists(vpath):
		vpath = "res://assets/video/intro.ogv"
	if ResourceLoader.exists(vpath):
		var stream := load(vpath) as VideoStream
		if stream != null:
			_video = VideoStreamPlayer.new()
			_video.stream = stream
			_video.autoplay = false
			_video.loop = false
			_video.volume_db = -3.0
			_root.add_child(_video)
			_video.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
			_video.expand = true
			_video_ready = true
			_video.finished.connect(_on_video_finished)

	_shot = TextureRect.new()
	_shot.set_anchors_preset(Control.PRESET_FULL_RECT)
	_shot.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_shot.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_shot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_shot.modulate = Color(1, 1, 1, 0)
	_root.add_child(_shot)

	var shade := TextureRect.new()
	shade.texture = UIStyle.gradient_texture(Color(0.0, 0.0, 0.0, 0.70), Color(0.0, 0.0, 0.0, 0.0))
	shade.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	shade.stretch_mode = TextureRect.STRETCH_SCALE
	UIStyle.place(shade, 0, 1, 0, 1, 0, -420, 0, 0)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(shade)

	var top_shade := TextureRect.new()
	top_shade.texture = UIStyle.gradient_texture(Color(0.0, 0.0, 0.0, 0.68), Color(0.0, 0.0, 0.0, 0.0))
	top_shade.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	top_shade.stretch_mode = TextureRect.STRETCH_SCALE
	UIStyle.place(top_shade, 0, 0, 0, 0, 0, 0, 0, 190)
	top_shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(top_shade)

	# ---- 电影字幕（无视频时使用）-----------------------------------------
	_caption_cn = UIStyle.glow_label("", 58, UIStyle.TXT)
	UIStyle.place(_caption_cn, 0, 0.70, 0, 0.70, 70, 0, 1180, 78)
	_caption_cn.modulate.a = 0.0
	_root.add_child(_caption_cn)
	_caption_en = UIStyle.label_tracked("", 16, Color(ACCENT.r, ACCENT.g, ACCENT.b, 1.0),
		HORIZONTAL_ALIGNMENT_LEFT, 3)
	UIStyle.place(_caption_en, 0, 0.70, 0, 0.70, 72, 84, 1180, 112)
	_caption_en.modulate.a = 0.0
	_root.add_child(_caption_en)
	_caption_sub = UIStyle.label("", 14, Color(0.72, 0.79, 0.86, 1.0))
	UIStyle.place(_caption_sub, 0, 0.70, 0, 0.70, 73, 116, 1180, 140)
	_caption_sub.modulate.a = 0.0
	_root.add_child(_caption_sub)
	_caption_line = ColorRect.new()
	_caption_line.color = ACCENT
	UIStyle.place(_caption_line, 0, 0.70, 0, 0.70, 70, 76, 190, 78)
	_caption_line.modulate.a = 0.0
	_caption_line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_caption_line)

	# ---- 标题（无视频时使用）---------------------------------------------
	_brand = UIStyle.label_display("APEX / VELOCITY", 82, UIStyle.TXT,
		HORIZONTAL_ALIGNMENT_CENTER, 9)
	_brand.add_theme_color_override("font_outline_color", UIStyle.a(Color(0, 0, 0), 0.72))
	_brand.add_theme_constant_override("outline_size", 8)
	_brand.anchor_left = 0.5
	_brand.anchor_right = 0.5
	_brand.anchor_top = 0.40
	_brand.anchor_bottom = 0.40
	_brand.offset_left = -800
	_brand.offset_right = 800
	_brand.offset_top = -52
	_brand.offset_bottom = 64
	_brand.modulate = Color(1, 1, 1, 0)
	_root.add_child(_brand)

	_brand_sub = UIStyle.label_tracked("A P E X   V E L O C I T Y      ·      极 速 巅 峰", 14,
		Color(0.80, 0.90, 0.96, 1.0), HORIZONTAL_ALIGNMENT_CENTER, 3)
	_brand_sub.anchor_left = 0.5
	_brand_sub.anchor_right = 0.5
	_brand_sub.anchor_top = 0.52
	_brand_sub.anchor_bottom = 0.52
	_brand_sub.offset_left = -800
	_brand_sub.offset_right = 800
	_brand_sub.offset_top = -40
	_brand_sub.offset_bottom = -12
	_brand_sub.modulate = Color(1, 1, 1, 0)
	_root.add_child(_brand_sub)

	# ---- 品牌 HUD 边框（视频与程序化都显示）-------------------------------
	_frame = UIFrame.new()
	_frame.setup(ACCENT, 34.0, 0.38)
	_frame.scan = true
	UIStyle.place(_frame, 0, 0, 1, 1, 22, 22, -22, -22)
	_frame.modulate.a = 0.0
	_root.add_child(_frame)

	var brand_slash := ColorRect.new()
	brand_slash.color = ACCENT
	UIStyle.place(brand_slash, 0, 0, 0, 0, 44, 36, 47, 74)
	brand_slash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(brand_slash)

	var brand_small := UIStyle.label_display("APEX / VELOCITY", 19, UIStyle.TXT,
		HORIZONTAL_ALIGNMENT_LEFT, 2)
	UIStyle.place(brand_small, 0, 0, 0, 0, 58, 30, 460, 60)
	_root.add_child(brand_small)

	var launch_tag := UIStyle.label_tracked("LAUNCH SEQUENCE   /   启 动 序 列", 9,
		Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.95), HORIZONTAL_ALIGNMENT_LEFT, 2)
	UIStyle.place(launch_tag, 0, 0, 0, 0, 60, 62, 560, 82)
	_root.add_child(launch_tag)

	# ---- 跳过提示 ----------------------------------------------------------
	_skip = UIStyle.label("按任意键 / 点击画面   跳过", 12, Color(0.78, 0.86, 0.92, 1.0),
		HORIZONTAL_ALIGNMENT_RIGHT)
	UIStyle.place(_skip, 1, 0, 1, 0, -420, 38, -46, 62)
	_root.add_child(_skip)
	_skip_key = UIStyle.label("SKIP   ▶▶", 11, Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.85),
		HORIZONTAL_ALIGNMENT_RIGHT)
	UIStyle.place(_skip_key, 1, 0, 1, 0, -420, 64, -46, 86)
	_root.add_child(_skip_key)

	# ---- 底部进度 ----------------------------------------------------------
	_progress_bg = Control.new()
	UIStyle.place(_progress_bg, 0, 1, 1, 1, 46, -96, -46, -34)
	_progress_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_progress_bg)

	var bar_bg := ColorRect.new()
	bar_bg.color = Color(0.07, 0.10, 0.13, 0.9)
	UIStyle.place(bar_bg, 0, 0, 1, 0, 0, 31, 0, 35)
	bar_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_progress_bg.add_child(bar_bg)

	_progress = ColorRect.new()
	_progress.color = ACCENT
	UIStyle.place(_progress, 0, 0, 0, 0, 0, 31, 0, 35)
	_progress.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_progress_bg.add_child(_progress)

	for i in 24:
		var tick := ColorRect.new()
		tick.color = Color(1, 1, 1, 0.10)
		var t := float(i) / 24.0
		UIStyle.place(tick, t, 0, t, 0, 0, 26, 1, 41)
		_progress_segments.append(tick)
		_progress_bg.add_child(tick)

	var cap := UIStyle.label_tracked("CINEMATIC INTRO   ·   APEX VELOCITY", 8,
		Color(0.62, 0.76, 0.85, 1.0), HORIZONTAL_ALIGNMENT_LEFT, 1)
	UIStyle.place(cap, 0, 0, 0, 0, 0, 8, 460, 24)
	_progress_bg.add_child(cap)
	_progress_pct = UIStyle.label_tech("0%", 11, Color(ACCENT.r, ACCENT.g, ACCENT.b, 1.0),
		HORIZONTAL_ALIGNMENT_RIGHT)
	UIStyle.place(_progress_pct, 0, 0, 1, 0, -80, 8, 0, 24)
	_progress_bg.add_child(_progress_pct)

	_start_hint = UIStyle.label_tracked("点击任意处 / 按任意键进入   ·   CLICK OR PRESS ANY KEY", 12,
		Color(0.88, 0.94, 0.98, 1.0), HORIZONTAL_ALIGNMENT_CENTER, 2)
	UIStyle.place(_start_hint, 0.5, 1, 0.5, 1, -500, -140, 500, -110)
	_start_hint.modulate = Color(1, 1, 1, 0)
	_root.add_child(_start_hint)

	_flash = ColorRect.new()
	_flash.color = Color(1.0, 1.0, 1.0, 0.0)
	_flash.set_anchors_preset(Control.PRESET_FULL_RECT)
	_flash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_flash)

	var scan := TextureRect.new()
	scan.texture = UIStyle.scanline_texture(0.06, 3)
	scan.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	scan.stretch_mode = TextureRect.STRETCH_TILE
	scan.set_anchors_preset(Control.PRESET_FULL_RECT)
	scan.mouse_filter = Control.MOUSE_FILTER_IGNORE
	scan.modulate = Color(1, 1, 1, 0.5)
	_root.add_child(scan)

	var vig := TextureRect.new()
	vig.texture = UIStyle.vignette_texture(Vector2(0.5, 0.5), 0.75, 0.28)
	vig.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	vig.stretch_mode = TextureRect.STRETCH_SCALE
	vig.set_anchors_preset(Control.PRESET_FULL_RECT)
	vig.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(vig)

	_fade = ColorRect.new()
	_fade.color = Color(0.0, 0.0, 0.0, 0.0)
	_fade.set_anchors_preset(Control.PRESET_FULL_RECT)
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_fade)

	_root.modulate = Color(1, 1, 1, 0)
	create_tween().tween_property(_root, "modulate:a", 1.0, 0.35)
	create_tween().tween_property(_frame, "modulate:a", 1.0, 0.8).set_delay(0.2)
	if _video_ready:
		_shot.visible = false
		_caption_cn.visible = false
		_caption_en.visible = false
		_caption_sub.visible = false
		_caption_line.visible = false
		_brand.visible = false
		_brand_sub.visible = false
		_start_hint.visible = false
		_video.play()
		# 兜底：个别系统上 OGV 解码器不出 finished 信号（窗口被遮挡时也会暂停），
		# 到片长 +1s 强制收尾，避免永远卡在开场；读不到片长时给 45s 上限。
		var length := _video.get_stream_length()
		var limit := (length + 1.0) if length > 0.5 else 45.0
		get_tree().create_timer(limit).timeout.connect(func() -> void:
			if not _finishing:
				_begin_finish())
	else:
		_run.call_deferred()
	# 跳过提示呼吸
	var pulse := create_tween().set_loops()
	pulse.tween_property(_skip_key, "modulate:a", 0.35, 0.9)
	pulse.tween_property(_skip_key, "modulate:a", 1.0, 0.9)


func _label(text: String, font_size: int, color: Color, pos: Vector2, size: Vector2) -> Label:
	var label := Label.new()
	label.text = text
	label.position = pos
	label.size = size
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.65))
	label.add_theme_constant_override("outline_size", 4)
	return label


func _fade_alpha(node: CanvasItem, to: float, dur: float) -> Tween:
	var t := create_tween()
	t.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_SINE)
	t.tween_property(node, "modulate:a", to, dur)
	return t


func _set_progress(frac: float) -> void:
	if _progress == null:
		return
	var clamped := clampf(frac, 0.0, 1.0)
	_progress.anchor_right = clamped
	_progress_pct.text = "%d%%" % int(round(clamped * 100.0))
	for i in _progress_segments.size():
		var t := float(i) / float(maxi(_progress_segments.size() - 1, 1))
		_progress_segments[i].color = Color(0.25, 0.86, 0.95, 0.55) if t <= clamped \
			else Color(1, 1, 1, 0.08)


func _process(dt: float) -> void:
	if _video_ready and not _finishing and _video.is_playing():
		var length: float = maxf(_video.get_stream_length(), 0.01)
		_set_progress(_video.stream_position / length)
		var t := _video.stream_position
		_skip.modulate.a = 1.0 if t < length - 1.5 else 0.0
		_skip_key.modulate.a = _skip.modulate.a
	else:
		_time += dt


func _on_video_finished() -> void:
	if not _finishing:
		_begin_finish()


func _sequence() -> void:
	# 1) 标题
	_brand.modulate.a = 0.0
	_brand_sub.modulate.a = 0.0
	_brand.scale = Vector2(1.10, 1.10)
	_brand.pivot_offset = Vector2(800, 60)
	var t1 := create_tween()
	t1.set_parallel(true)
	t1.tween_property(_brand, "modulate:a", 1.0, 0.8)
	t1.tween_property(_brand, "scale", Vector2.ONE, 1.5).set_trans(Tween.TRANS_EXPO)
	t1.tween_property(_brand_sub, "modulate:a", 1.0, 0.9).set_delay(0.5)
	await get_tree().create_timer(1.5).timeout
	if _finishing:
		return
	create_tween().tween_property(_brand, "modulate:a", 0.0, 0.4)
	create_tween().tween_property(_brand_sub, "modulate:a", 0.0, 0.4)

	# 2) 场景快切
	for shot in SHOTS:
		if _finishing:
			return
		var path := String(shot["path"])
		var tex: Texture2D = null
		if ResourceLoader.exists(path):
			tex = load(path) as Texture2D
		_shot.texture = tex
		_shot.modulate.a = 0.0
		_shot.scale = Vector2(1.06, 1.06)
		_shot.pivot_offset = Vector2(800, 450)
		_caption_cn.text = String(shot["cn"])
		_caption_en.text = String(shot["en"])
		_caption_sub.text = String(shot["sub"])
		_caption_cn.modulate.a = 0.0
		_caption_en.modulate.a = 0.0
		_caption_sub.modulate.a = 0.0
		_caption_line.modulate.a = 0.0
		var fps := 1.5 if path.contains("menu-car-in-scene") else 1.0
		var t2 := create_tween()
		t2.set_parallel(true)
		t2.tween_property(_shot, "modulate:a", 1.0, 0.22)
		t2.tween_property(_shot, "scale", Vector2(1.0, 1.0), fps + 0.3).set_trans(Tween.TRANS_SINE)
		t2.tween_property(_caption_cn, "modulate:a", 1.0, 0.35).set_delay(0.18)
		t2.tween_property(_caption_en, "modulate:a", 1.0, 0.35).set_delay(0.24)
		t2.tween_property(_caption_sub, "modulate:a", 1.0, 0.35).set_delay(0.30)
		t2.tween_property(_caption_line, "modulate:a", 1.0, 0.25).set_delay(0.12)
		create_tween().tween_property(_flash, "modulate:a", 0.14, 0.06)
		create_tween().tween_property(_flash, "modulate:a", 0.0, 0.28).set_delay(0.06)
		await get_tree().create_timer(fps).timeout
		if _finishing:
			return
		create_tween().tween_property(_caption_cn, "modulate:a", 0.0, 0.18)
		create_tween().tween_property(_caption_en, "modulate:a", 0.0, 0.18)
		create_tween().tween_property(_caption_sub, "modulate:a", 0.0, 0.18)
		create_tween().tween_property(_caption_line, "modulate:a", 0.0, 0.18)

	# 3) 收尾：标题 + 提示
	if _finishing:
		return
	_shot.texture = null
	_brand.scale = Vector2(0.96, 0.96)
	var t3 := create_tween()
	t3.set_parallel(true)
	t3.tween_property(_brand, "modulate:a", 1.0, 0.5)
	t3.tween_property(_brand_sub, "modulate:a", 1.0, 0.5).set_delay(0.15)
	t3.tween_property(_start_hint, "modulate:a", 1.0, 0.5).set_delay(0.5)
	await get_tree().create_timer(2.2).timeout
	if _finishing:
		return
	_begin_finish()


func _run() -> void:
	var total := 1.5 + 1.0 * (SHOTS.size() - 2) + 1.5 + 2.2
	var t := create_tween()
	t.tween_method(_set_progress, 0.0, 1.0, total)
	_sequence()


func _input(event: InputEvent) -> void:
	if _finishing:
		return
	var skip := false
	if event is InputEventMouseButton and event.pressed:
		skip = true
	elif event is InputEventKey and event.pressed and not event.echo:
		skip = true
	elif event is InputEventScreenTouch and event.pressed:
		skip = true
	if skip:
		get_viewport().set_input_as_handled()
		_begin_finish()


func _begin_finish() -> void:
	if _finishing:
		return
	_finishing = true
	var t := create_tween()
	t.set_parallel(true)
	t.tween_property(_root, "modulate:a", 0.0, 0.22).set_trans(Tween.TRANS_SINE)
	await get_tree().create_timer(0.24).timeout
	finished.emit()
	queue_free()
