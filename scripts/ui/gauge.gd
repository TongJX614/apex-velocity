class_name Gauge
extends Control
## 商业赛车游戏风格仪表盘 v2：玻璃表盘 + 主题色数值弧 + 黄区/红区 + 锥形指针。
## 用于 HUD 转速表 / 速度表。API 与旧版一致（setup / set_value / 字段）。

enum Kind { SPEED, RPM }

const START_DEG := 138.0
const SWEEP_DEG := 264.0

var kind: Kind = Kind.SPEED
var max_value := 300.0
var major_step := 40.0
var minor_per_major := 4
var redline_from := -1.0
var warn_from := -1.0              # 黄区起点（换挡提示区）
var hot := false                   # 红线/断油闪烁
var accent := UIStyle.ACCENT
var dial_face := Color(0.02, 0.03, 0.045, 0.55)
var needle_color := Color(1.0, 0.72, 0.30)
var digital_text := ""
var sub_text := ""
var unit_text := ""
var pending := false
## 紧凑模式（HUD 右下小仪表）：隐藏刻度数字/小刻度，只保留弧与指针
var show_numbers := true
var show_minor := true

var _current := 0.0
var _target := 0.0


func setup(dial_kind: Kind, maximum: float, step: float) -> void:
	kind = dial_kind
	max_value = maximum
	major_step = step
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(200, 200)


func set_value(value: float, immediate: bool = false) -> void:
	_target = clampf(value, 0.0, max_value * 1.05)
	if immediate:
		_current = _target


func _process(dt: float) -> void:
	var rate := 16.0 if _target > _current else 9.0
	_current = lerpf(_current, _target, 1.0 - exp(-rate * dt))
	queue_redraw()


func _draw() -> void:
	var radius := minf(size.x, size.y) * 0.5 - 5.0
	var center := size * 0.5
	if radius <= 8.0:
		return
	var font := UIStyle.tech_font()
	var start_rad := deg_to_rad(START_DEG)
	var end_rad := deg_to_rad(START_DEG + SWEEP_DEG)

	# 表盘玻璃底：外暗、内亮的一圈渐变 + 细表圈
	if dial_face.a > 0.01:
		draw_circle(center, radius + 1.0, dial_face)
		draw_circle(center, radius - 2.0, Color(0.035, 0.055, 0.070, 0.62))
	# 外圈：低透明描边 + 顶部高光弧
	draw_arc(center, radius + 1.0, 0.0, TAU, 96,
		Color(0.62, 0.78, 0.86, 0.16), 1.2, true)
	draw_arc(center, radius + 1.0, start_rad, start_rad + deg_to_rad(SWEEP_DEG), 96,
		Color(0.82, 0.90, 0.95, 0.20), 1.6, true)
	# 表盘内侧细环
	draw_arc(center, radius - 3.0, 0.0, TAU, 96,
		Color(accent.r, accent.g, accent.b, 0.10), 1.0, true)

	var value_frac := clampf(_current / maxf(max_value, 1.0), 0.0, 1.0)

	# 背景进度弧（始终可见的暗轨）
	draw_arc(center, radius - 8.0, start_rad, end_rad, 96,
		Color(0.32, 0.40, 0.47, 0.22), 3.0, true)

	# 黄区（换挡提示区）/ 红区
	if warn_from > 0.0:
		var warn_frac := clampf(warn_from / maxf(max_value, 1.0), 0.0, 1.0)
		var warn_end := redline_from if redline_from > 0.0 else max_value
		draw_arc(center, radius - 1.0,
			start_rad + deg_to_rad(SWEEP_DEG) * warn_frac,
			start_rad + deg_to_rad(SWEEP_DEG) * clampf(warn_end / maxf(max_value, 1.0), 0.0, 1.0),
			48, Color(1.0, 0.72, 0.18, 0.85), 2.2, true)
	if redline_from > 0.0:
		var red_frac := clampf(redline_from / maxf(max_value, 1.0), 0.0, 1.0)
		var red_alpha := 0.95
		var red_width := 2.6
		if hot:
			red_alpha = 0.55 + 0.45 * (0.5 + 0.5 * sin(Time.get_ticks_msec() * 0.03))
			red_width = 4.2
		draw_arc(center, radius - 1.0, start_rad + deg_to_rad(SWEEP_DEG) * red_frac,
			end_rad, 56, Color(1.0, 0.22, 0.16, red_alpha), red_width, true)
		draw_arc(center, radius - 1.0, start_rad + deg_to_rad(SWEEP_DEG) * red_frac,
			end_rad, 56, Color(1.0, 0.22, 0.16, 0.16), 9.0, true)

	# 数值弧（外发光 + 主弧 + 弧头亮点）
	if value_frac > 0.002:
		var arc_end := start_rad + deg_to_rad(SWEEP_DEG) * value_frac
		draw_arc(center, radius - 8.0, start_rad, arc_end, 96,
			Color(accent.r, accent.g, accent.b, 0.14), 11.0, true)
		draw_arc(center, radius - 8.0, start_rad, arc_end, 96,
			Color(accent.r, accent.g, accent.b, 0.96), 3.4, true)
		draw_arc(center, radius - 8.0, maxf(arc_end - 0.10, start_rad), arc_end, 8,
			Color(1.0, 1.0, 1.0, 0.85), 2.2, true)

	# 刻度：主刻度向外 + 次刻度短
	var total_major := maxi(1, int(round(max_value / major_step)))
	for i in total_major + 1:
		var frac := float(i) / float(total_major)
		var angle := start_rad + deg_to_rad(SWEEP_DEG) * frac
		var dir := Vector2(cos(angle), sin(angle))
		var major_color := Color(0.86, 0.92, 0.97, 0.92)
		if redline_from > 0.0 and float(i) * major_step >= redline_from:
			major_color = Color(1.0, 0.38, 0.28, 0.95)
		draw_line(center + dir * (radius - 17.0), center + dir * (radius - 27.0),
			major_color, 1.8, true)
		if show_numbers:
			var text := _label_for(i * major_step)
			var text_pos := center + dir * (radius - 40.0)
			draw_string(font, text_pos + Vector2(-22.0, 5.0), text, HORIZONTAL_ALIGNMENT_CENTER,
				44.0, 11, Color(0.78, 0.86, 0.92, 0.92))
		if not show_minor:
			continue
		for m in range(1, minor_per_major):
			var minor_angle := angle + deg_to_rad(SWEEP_DEG) / float(total_major) \
				* float(m) / float(minor_per_major)
			var minor_dir := Vector2(cos(minor_angle), sin(minor_angle))
			draw_line(center + minor_dir * (radius - 18.0), center + minor_dir * (radius - 23.0),
				Color(0.58, 0.68, 0.77, 0.45), 1.0, true)

	# 指针（细长锥形 + 投影）
	var needle_angle := start_rad + deg_to_rad(SWEEP_DEG) * value_frac
	var needle_dir := Vector2(cos(needle_angle), sin(needle_angle))
	var needle_side := Vector2(-needle_dir.y, needle_dir.x)
	var tip := center + needle_dir * (radius - 22.0)
	var base := center - needle_dir * (radius * 0.14)
	var needle_poly := PackedVector2Array([
		tip, base + needle_side * 2.6, base - needle_side * 2.6,
	])
	var needle_shadow := PackedVector2Array([
		tip + Vector2(1.5, 1.5), base + needle_side * 2.6 + Vector2(2.5, 2.5),
		base - needle_side * 2.6 + Vector2(2.5, 2.5),
	])
	draw_colored_polygon(needle_shadow, Color(0, 0, 0, 0.30))
	draw_colored_polygon(needle_poly, needle_color)
	draw_line(center, tip, Color(1.0, 1.0, 1.0, 0.42), 1.0, true)

	# 中心盖
	draw_circle(center, 9.0, Color(0.045, 0.060, 0.075, 1.0))
	draw_arc(center, 9.0, 0.0, TAU, 32,
		Color(accent.r, accent.g, accent.b, 0.75), 1.3, true)
	draw_circle(center, 4.2, Color(0.86, 0.92, 0.96, 1.0))
	draw_circle(center, 2.0, Color(0.10, 0.14, 0.18, 1.0))

	# 数字与单位（HUD 主数字在外部时留空即可）
	if not digital_text.is_empty():
		draw_string(font, Vector2(0.0, center.y + radius * 0.48), digital_text,
			HORIZONTAL_ALIGNMENT_CENTER, size.x, 26, Color(0.96, 0.98, 1.0))
	if not unit_text.is_empty():
		draw_string(font, Vector2(0.0, center.y + radius * 0.70), unit_text,
			HORIZONTAL_ALIGNMENT_CENTER, size.x, 10, Color(0.66, 0.78, 0.86))
	if not sub_text.is_empty():
		draw_string(font, Vector2(0.0, center.y - radius * 0.36), sub_text,
			HORIZONTAL_ALIGNMENT_CENTER, size.x, 11, Color(0.66, 0.78, 0.86))


func _label_for(value: float) -> String:
	if kind == Kind.RPM:
		return str(int(value / 1000.0))
	return str(int(value))
