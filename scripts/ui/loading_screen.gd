class_name LoadingScreen
extends CanvasLayer
## 赛道切换 / 开赛过场加载 · 商业赛车游戏风格。
## 深色碳纤底 + 斜向光带 shader + 中央分段进度环 + 大标题 + 底部提示。
## 对外 API：show_loading(title) / finish_and_free()，行为与旧版一致。

var _root: Control
var _title: Label
var _sub: Label
var _tip: Label
var _bar: Control
var _progress := 0.0
var _shown := 0.0
var _time := 0.0
var _ring: Control
var _pct_label: Label
var _stage_label: Label
var _tips := [
	"高速转向会变重，入弯前先减速",
	"起跑线之后才开始计时，别抢跑",
	"跟车可以获得尾流加速",
	"手刹可以让车尾甩出去",
	"不同赛道的弯道特性完全不同",
	"Shift 氮气在直道末端最好用",
]


func _ready() -> void:
	layer = 88
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()


func _build() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	UIStyle.apply_theme(_root)
	add_child(_root)

	# 程序化转场背景：流动的斜向色带
	var flow := ColorRect.new()
	flow.set_anchors_preset(Control.PRESET_FULL_RECT)
	flow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var shader := Shader.new()
	shader.code = """shader_type canvas_item;
uniform vec4 base_a : source_color = vec4(0.008, 0.016, 0.026, 1.0);
uniform vec4 base_b : source_color = vec4(0.028, 0.062, 0.090, 1.0);
uniform vec4 accent : source_color = vec4(0.24, 0.82, 0.94, 1.0);
void fragment() {
	vec2 uv = UV;
	float t = TIME * 0.32;
	vec2 p = vec2(uv.x + uv.y * 0.62, uv.y);
	float bands = sin((p.x * 8.0 - t * 3.0) * 3.14159) * 0.5 + 0.5;
	bands = smoothstep(0.62, 1.0, bands);
	vec2 p2 = vec2(uv.x * 0.65 - uv.y * 0.95, uv.y);
	float sweep = sin((p2.x * 1.8 + p2.y * 1.0 - t * 1.4) * 3.14159) * 0.5 + 0.5;
	sweep = pow(sweep, 7.0);
	float hlines = smoothstep(0.985, 1.0, sin((uv.y + t * 0.05) * 900.0) * 0.5 + 0.5) * 0.10;
	vec3 col = mix(base_a.rgb, base_b.rgb, uv.y * 0.85 + 0.15);
	col += accent.rgb * bands * 0.035;
	col += accent.rgb * sweep * 0.11;
	col += accent.rgb * hlines * 0.22;
	float vig = smoothstep(1.05, 0.18, length(uv - vec2(0.5)));
	col *= mix(0.42, 1.0, vig);
	COLOR = vec4(col, 1.0);
}"""
	var mat := ShaderMaterial.new()
	mat.shader = shader
	flow.material = mat
	_root.add_child(flow)

	var carbon := TextureRect.new()
	carbon.texture = UIStyle.carbon_texture(Color(0.014, 0.022, 0.030), Color(0.030, 0.044, 0.058))
	carbon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	carbon.stretch_mode = TextureRect.STRETCH_TILE
	carbon.modulate = Color(1, 1, 1, 0.55)
	carbon.set_anchors_preset(Control.PRESET_FULL_RECT)
	carbon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(carbon)

	var dim := ColorRect.new()
	dim.color = Color(0.004, 0.007, 0.010, 0.58)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(dim)

	var vig := TextureRect.new()
	vig.texture = UIStyle.vignette_texture(Vector2(0.5, 0.5), 0.74, 0.28)
	vig.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	vig.stretch_mode = TextureRect.STRETCH_SCALE
	vig.set_anchors_preset(Control.PRESET_FULL_RECT)
	vig.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(vig)

	# 顶部品牌
	var slash := ColorRect.new()
	slash.color = UIStyle.ACCENT
	UIStyle.place(slash, 0, 0, 0, 0, 46, 38, 49, 78)
	slash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(slash)
	var brand := UIStyle.label_display("APEX / VELOCITY", 19, UIStyle.TXT,
		HORIZONTAL_ALIGNMENT_LEFT, 2)
	UIStyle.place(brand, 0, 0, 0, 0, 60, 32, 500, 62)
	_root.add_child(brand)
	var tag := UIStyle.label_tracked("RACE WEEKEND   /   比赛周末", 9,
		Color(0.66, 0.86, 0.92, 1.0), HORIZONTAL_ALIGNMENT_LEFT, 2)
	UIStyle.place(tag, 0, 0, 0, 0, 62, 64, 500, 84)
	_root.add_child(tag)

	var frame := UIFrame.new()
	frame.setup(UIStyle.ACCENT, 30.0, 0.30)
	frame.scan = true
	UIStyle.place(frame, 0, 0, 1, 1, 18, 18, -18, -18)
	_root.add_child(frame)

	# 中央进度环
	_ring = Control.new()
	_ring.custom_minimum_size = Vector2(240, 240)
	UIStyle.place(_ring, 0.5, 0.5, 0.5, 0.5, -120, -196, 120, 44)
	_ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ring.draw.connect(_draw_ring)
	_root.add_child(_ring)

	_pct_label = UIStyle.label_tech("0%", 30, UIStyle.TXT, HORIZONTAL_ALIGNMENT_CENTER)
	UIStyle.place(_pct_label, 0.5, 0.5, 0.5, 0.5, -120, -128, 120, -88)
	_root.add_child(_pct_label)

	_title = UIStyle.label_display("正在加载", 32, UIStyle.TXT, HORIZONTAL_ALIGNMENT_CENTER, 2)
	_title.add_theme_color_override("font_outline_color", UIStyle.a(Color(0, 0, 0), 0.7))
	_title.add_theme_constant_override("outline_size", 5)
	UIStyle.place(_title, 0.5, 0.5, 0.5, 0.5, -600, 56, 600, 102)
	_root.add_child(_title)

	_sub = UIStyle.label_tracked("LOADING   ·   准备赛道与对手", 10,
		UIStyle.a(UIStyle.ACCENT, 0.95), HORIZONTAL_ALIGNMENT_CENTER, 2)
	UIStyle.place(_sub, 0.5, 0.5, 0.5, 0.5, -600, 102, 600, 126)
	_root.add_child(_sub)

	# 进度条（环下面一条细线，双保险）
	_bar = Control.new()
	UIStyle.place(_bar, 0.5, 0.5, 0.5, 0.5, -260, 140, 260, 148)
	_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bar.draw.connect(_draw_bar)
	_root.add_child(_bar)

	_stage_label = UIStyle.label_tracked("BUILDING TRACK GEOMETRY   ·   SCENERY   ·   GRID", 8,
		Color(0.58, 0.72, 0.82, 0.95), HORIZONTAL_ALIGNMENT_CENTER, 1)
	UIStyle.place(_stage_label, 0.5, 0.5, 0.5, 0.5, -600, 154, 600, 174)
	_root.add_child(_stage_label)

	_tip = UIStyle.label("", 12, Color(0.74, 0.83, 0.90, 1.0), HORIZONTAL_ALIGNMENT_CENTER)
	UIStyle.place(_tip, 0.5, 1, 0.5, 1, -600, -132, 600, -108)
	_root.add_child(_tip)

	var hint := UIStyle.label_tracked("提示  /  TIP", 8, Color(0.56, 0.70, 0.80, 0.92),
		HORIZONTAL_ALIGNMENT_CENTER, 2)
	UIStyle.place(hint, 0.5, 1, 0.5, 1, -600, -154, 600, -134)
	_root.add_child(hint)

	_root.modulate.a = 0.0


func _draw_ring() -> void:
	var center := _ring.size * 0.5
	var radius := minf(_ring.size.x, _ring.size.y) * 0.5 - 26.0
	var start := -PI * 0.5
	var t := _time
	# 背景环
	_ring.draw_arc(center, radius, 0.0, TAU, 96, Color(0.45, 0.62, 0.72, 0.16), 2.0, true)
	_ring.draw_arc(center, radius - 12.0, 0.0, TAU, 96, Color(0.45, 0.62, 0.72, 0.08), 1.0, true)
	# 进度环
	var frac := clampf(_shown, 0.0, 1.0)
	if frac > 0.002:
		_ring.draw_arc(center, radius, start, start + TAU * frac, 96,
			UIStyle.a(UIStyle.ACCENT, 0.16), 12.0, true)
		_ring.draw_arc(center, radius, start, start + TAU * frac, 96,
			UIStyle.a(UIStyle.ACCENT, 0.98), 3.4, true)
	# 旋转的扫描弧
	var spin := t * 2.2
	_ring.draw_arc(center, radius - 24.0, spin, spin + 1.4, 32,
		UIStyle.a(UIStyle.GOLD, 0.85), 2.0, true)
	var dot_angle := spin + 1.4
	_ring.draw_circle(center + Vector2(cos(dot_angle), sin(dot_angle)) * (radius - 24.0), 3.0,
		UIStyle.a(UIStyle.GOLD, 0.98))
	# 刻度
	for i in 36:
		var a := float(i) / 36.0 * TAU
		var dir := Vector2(cos(a), sin(a))
		var major := i % 6 == 0
		_ring.draw_line(center + dir * (radius + 6.0), center + dir * (radius + (14.0 if major else 10.0)),
			Color(0.55, 0.75, 0.85, 0.35 if major else 0.16), 1.0, true)
	# 中心十字
	_ring.draw_line(center - Vector2(9, 0), center - Vector2(3, 0), Color(0.4, 0.7, 0.8, 0.35), 1.0)
	_ring.draw_line(center + Vector2(3, 0), center + Vector2(9, 0), Color(0.4, 0.7, 0.8, 0.35), 1.0)
	_ring.draw_line(center - Vector2(0, 9), center - Vector2(0, 3), Color(0.4, 0.7, 0.8, 0.35), 1.0)
	_ring.draw_line(center + Vector2(0, 3), center + Vector2(0, 9), Color(0.4, 0.7, 0.8, 0.35), 1.0)


func _draw_bar() -> void:
	var w := _bar.size.x
	_bar.draw_rect(Rect2(0, 0, w, 5), Color(0.07, 0.10, 0.13, 0.9))
	var fw := w * clampf(_shown, 0.0, 1.0)
	_bar.draw_rect(Rect2(0, 0, fw, 5), UIStyle.a(UIStyle.ACCENT, 0.92))
	_bar.draw_rect(Rect2(0, 0, fw, 1), Color(1, 1, 1, 0.45))
	_bar.draw_circle(Vector2(fw, 2.5), 3.0, UIStyle.a(UIStyle.ACCENT, 0.55))
	for i in 32:
		var x := w * float(i) / 32.0
		_bar.draw_line(Vector2(x, 0), Vector2(x, 4), Color(0, 0, 0, 0.35), 1.0)


func show_loading(title: String) -> void:
	_title.text = title
	_sub.text = "LOADING   ·   准备赛道与对手"
	_tip.text = "提示：" + String(_tips[randi() % _tips.size()])
	_root.modulate.a = 0.0
	create_tween().tween_property(_root, "modulate:a", 1.0, 0.26)
	_shown = 0.0
	_progress = 0.0


func _process(dt: float) -> void:
	_time += dt
	if _ring != null:
		_ring.queue_redraw()
	if _bar != null:
		_bar.queue_redraw()
	_shown = minf(_shown + dt * 0.82, 0.94)
	if _pct_label != null:
		_pct_label.text = "%d%%" % int(round(_shown * 100.0))
	if _stage_label != null and _shown > 0.66:
		_stage_label.text = "WARMING UP SHADERS   ·   GRID   ·   READY"


func finish_and_free() -> void:
	_shown = 1.0
	_pct_label.text = "100%"
	var fade := create_tween()
	fade.tween_interval(0.18)
	fade.tween_property(_root, "modulate:a", 0.0, 0.32)
	await fade.finished
	queue_free()
