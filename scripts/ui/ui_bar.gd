class_name UIBar
extends Control
## 斜切数据条 v2：用于 HUD 的氮气 / 油门 / 刹车 / 温度等条形指示。
## 纯 _draw 绘制，支持分段刻度、危险色、平滑追值，不依赖贴图。

var value := 0.0
var target := 0.0
var accent := UIStyle.ACCENT
var danger_from := 0.85
var danger_color := UIStyle.RED
var segments := 18
var chamfer := 7.0
var show_ticks := true
var caption := ""
var caption_size := 10


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(true)


func setup(color_value: Color, caption_text: String = "") -> UIBar:
	accent = color_value
	caption = caption_text
	queue_redraw()
	return self


func set_value(v: float, immediate: bool = false) -> void:
	target = clampf(v, 0.0, 1.0)
	if immediate:
		value = target
		queue_redraw()


func _process(dt: float) -> void:
	var next := lerpf(value, target, 1.0 - exp(-10.0 * dt))
	if absf(next - value) > 0.0005:
		value = next
		queue_redraw()


func _draw() -> void:
	var w := size.x
	var h := size.y
	if w < 8.0 or h < 4.0:
		return
	var ch := minf(chamfer, h * 0.5)
	# 斜切轮廓 + 内嵌底
	var outline := PackedVector2Array([
		Vector2(ch, 0.0), Vector2(w, 0.0), Vector2(w - ch, h), Vector2(0.0, h),
	])
	draw_colored_polygon(outline, Color(0.045, 0.068, 0.088, 0.90))
	draw_polyline(PackedVector2Array([outline[0], outline[1], outline[2], outline[3], outline[0]]),
		Color(0.55, 0.70, 0.80, 0.16), 1.0, true)
	var accent_col := accent.lerp(danger_color, clampf((value - danger_from) / maxf(1.0 - danger_from, 0.01), 0.0, 1.0))
	if value > 0.001:
		var fw := w * value
		var fch := minf(ch, fw * 0.5)
		var fill_poly := PackedVector2Array([
			Vector2(fch, 0.0), Vector2(fw, 0.0), Vector2(maxf(fw - fch, 0.0), h), Vector2(0.0, h),
		])
		# 外发光（放大一圈的低透明填充）
		draw_colored_polygon(fill_poly, Color(accent_col.r, accent_col.g, accent_col.b, 0.16))
		draw_colored_polygon(fill_poly, Color(accent_col.r, accent_col.g, accent_col.b, 0.95))
		# 顶部高光 + 底部暗边，制造体积感
		draw_line(Vector2(fch + 1.0, 1.0), Vector2(maxf(fw - fch, 0.0), 1.0),
			Color(1, 1, 1, 0.40), 1.0)
		draw_line(Vector2(1.0, h - 1.0), Vector2(maxf(fw - fch, 0.0), h - 1.0),
			Color(0, 0, 0, 0.28), 1.0)
		# 满值端点光晕
		if value > 0.02:
			draw_circle(Vector2(fw, h * 0.5), h * 0.9,
				Color(accent_col.r, accent_col.g, accent_col.b, 0.10))
	# 分段刻度
	if show_ticks and segments > 1:
		for i in range(1, segments):
			var t := float(i) / float(segments)
			var x := w * t
			var dx := ch * 0.35
			draw_line(Vector2(x - dx, 2.0), Vector2(x - dx, h - 2.0), Color(0, 0, 0, 0.28), 1.0)
			draw_line(Vector2(x, 2.0), Vector2(x, h - 2.0), Color(1, 1, 1, 0.06), 1.0)
	if not caption.is_empty():
		var font := UIStyle.tech_font()
		draw_string(font, Vector2(0.0, -3.0), caption, HORIZONTAL_ALIGNMENT_LEFT, -1.0,
			caption_size, Color(0.66, 0.76, 0.84, 0.95))
