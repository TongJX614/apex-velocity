class_name UIFrame
extends Control
## 程序化装饰框 v2：极细全框 + 四角切角括号 + 顶部强调线 + 可选扫描高光。
## 所有界面共用同一套「赛事科技感」轮廓语言，不依赖任何贴图素材。

var accent := UIStyle.ACCENT
var corner_length := 24.0
var line_width := 1.0
var alpha := 0.5
var top_bar := true
var bottom_ticks := false
var left_bar := false
var scan := false
var _scan_pos := 0.0
var _time := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(scan)


func _process(dt: float) -> void:
	_time += dt
	_scan_pos = fposmod(_time * 0.22, 1.4) - 0.2
	queue_redraw()


func _draw() -> void:
	var w := size.x
	var h := size.y
	if w < 4.0 or h < 4.0:
		return
	var c := Color(accent.r, accent.g, accent.b, alpha * 0.45)
	var c_soft := Color(accent.r, accent.g, accent.b, alpha * 0.22)
	var c_strong := Color(accent.r, accent.g, accent.b, minf(alpha + 0.32, 0.95))
	var pad := line_width * 0.5
	var corner := minf(corner_length, minf(w, h) * 0.25)
	# 全框极细描边（低透明，只做边界暗示）
	draw_rect(Rect2(pad, pad, w - line_width, h - line_width), c_soft, false, line_width)
	# 四角切角括号
	if corner > 0.0:
		draw_line(Vector2(pad, pad), Vector2(corner, pad), c_strong, line_width * 1.4)
		draw_line(Vector2(pad, pad), Vector2(pad, corner), c_strong, line_width * 1.4)
		draw_line(Vector2(w - pad, pad), Vector2(w - corner, pad), c_strong, line_width * 1.4)
		draw_line(Vector2(w - pad, pad), Vector2(w - pad, corner), c_strong, line_width * 1.4)
		draw_line(Vector2(pad, h - pad), Vector2(corner, h - pad), c, line_width)
		draw_line(Vector2(pad, h - pad), Vector2(pad, h - corner), c, line_width)
		draw_line(Vector2(w - pad, h - pad), Vector2(w - corner, h - pad), c, line_width)
		draw_line(Vector2(w - pad, h - pad), Vector2(w - pad, h - corner), c, line_width)
	if top_bar:
		# 顶部强调线：中央亮、两端淡（三段式）
		var mid0 := w * 0.28
		var mid1 := w * 0.72
		draw_line(Vector2(corner + 8.0, pad), Vector2(mid0, pad), c_soft, line_width)
		draw_line(Vector2(mid0, pad), Vector2(mid1, pad), Color(accent.r, accent.g, accent.b, alpha * 0.8), line_width)
		draw_line(Vector2(mid1, pad), Vector2(w - corner - 8.0, pad), c_soft, line_width)
	if left_bar:
		draw_line(Vector2(pad, corner + 6.0), Vector2(pad, h - corner - 6.0), c, line_width)
	if bottom_ticks:
		var count := 7
		for i in count:
			var x := w - corner - 12.0 - float(i) * 7.0
			if x < w * 0.45:
				break
			draw_line(Vector2(x, h - pad), Vector2(x, h - pad - 8.0),
				Color(accent.r, accent.g, accent.b, alpha * 0.4), 1.0)
	if scan:
		var scan_y := lerpf(0.0, h, _scan_pos)
		if scan_y >= 0.0 and scan_y <= h:
			for i in 6:
				var line_alpha := (1.0 - float(i) / 6.0) * 0.12
				draw_line(Vector2(corner, scan_y - float(i) * 2.0), Vector2(w - corner, scan_y - float(i) * 2.0),
					Color(accent.r, accent.g, accent.b, line_alpha), 1.0)


func setup(color_value: Color, corner: float = 24.0, a: float = 0.5) -> UIFrame:
	accent = color_value
	corner_length = corner
	alpha = a
	return self
