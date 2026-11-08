class_name UIStyle
extends RefCounted
## APEX VELOCITY · 统一 UI 设计系统 v2（高级赛车玻璃拟态）
##
## 设计语言：暗调电影感底 + 品牌青（#55e7d2）霓虹点缀 + 琥珀黄数据 + 玻璃面板。
## 集中管理：
##   · Token 色板（背景 4 级 / 玻璃 2 级 / 文字 4 级 / 品牌青・琥珀・状态色）
##   · 字体层级（DIN 显示字体 + 系统 CJK 字体回退 + 字距追踪）
##   · 间距网格（4/8/12/16/24/32）与圆角（4/8/10/14）
##   · 面板玻璃（半透明 + 细描边 + 顶部渐隐高光）、按钮 5 态、Tab、Chip、
##     滑条、开关、滚动条、程序化贴图（碳纤、网格、扫描线、辉光、渐隐带）
##   · 入场 / 悬停 / 按下 / 焦点动效
## 所有界面只从这里取样式，保证 boot / menu / garage / settings / HUD 语言一致。

# ---------------------------------------------------------------------------
# 颜色 Token
# ---------------------------------------------------------------------------
# 背景：由深到浅 4 级，始终保持暗调
const BG_DEEP := Color(0.012, 0.020, 0.028, 0.97)     # 全屏底 / 遮罩
const BG_PANEL := Color(0.028, 0.043, 0.057, 0.94)    # 大面板玻璃
const BG_CARD := Color(0.036, 0.056, 0.074, 0.90)     # 卡片玻璃
const BG_CARD_HI := Color(0.055, 0.086, 0.112, 0.94)  # 卡片悬停 / 高亮
const BG_INSET := Color(0.018, 0.030, 0.041, 0.88)    # 内嵌槽 / 读数格

# 描边：冷灰蓝，避免死黑
const LINE := Color(0.26, 0.36, 0.46, 0.55)
const LINE_SOFT := Color(0.19, 0.27, 0.35, 0.40)

# 文字 4 级
const TXT := Color(0.957, 0.976, 0.992, 1.0)          # 主标题 / 关键读数
const TXT_SUB := Color(0.700, 0.780, 0.850, 1.0)      # 正文 / 次级
const TXT_DIM := Color(0.520, 0.605, 0.690, 1.0)      # 说明
const TXT_FAINT := Color(0.380, 0.455, 0.535, 1.0)    # 标签 / 水印

# 品牌色：青（主力）+ 冷蓝（辅助渐变）+ 琥珀（数据值）
const ACCENT := Color(0.333, 0.906, 0.824, 1.0)       # #55e7d2
const ACCENT_2 := Color(0.243, 0.760, 0.941, 1.0)     # #3ec2f0
const ACCENT_DEEP := Color(0.071, 0.388, 0.420, 1.0)
const GOLD := Color(1.0, 0.776, 0.360, 1.0)           # 琥珀黄数值
const AMBER := GOLD
const SILVER := Color(0.788, 0.843, 0.894, 1.0)
const RED := Color(1.0, 0.353, 0.290, 1.0)
const GREEN := Color(0.400, 0.890, 0.604, 1.0)

# 间距网格
const SP_1 := 4
const SP_2 := 8
const SP_3 := 12
const SP_4 := 16
const SP_5 := 20
const SP_6 := 24
const SP_8 := 32

# 圆角
const R_XS := 3
const R_SM := 5
const R_MD := 8
const R_LG := 11
const R_XL := 14
const R_PILL := 96

# 字号层级
const F_DISPLAY := 64
const F_H1 := 40
const F_H2 := 28
const F_H3 := 20
const F_BODY := 15
const F_SMALL := 13
const F_MICRO := 11

static var _tex_cache: Dictionary = {}
static var _icon_cache: Dictionary = {}
static var _font_cache: Dictionary = {}
static var _theme_cache: Theme = null
static var _cjk_font: Font = null
static var _display_font: Font = null
static var _tech_font: Font = null


# ---------------------------------------------------------------------------
# 字体：系统 CJK（中文）+ DIN（英文标题 / 数值），不引入外部字体依赖
# ---------------------------------------------------------------------------

static func system_cjk_font() -> Font:
	if _cjk_font != null:
		return _cjk_font
	var candidates := [
		"/System/Library/Fonts/Hiragino Sans GB.ttc",
		"/System/Library/Fonts/STHeiti Medium.ttc",
		"/System/Library/Fonts/PingFang.ttc",
		"/System/Library/Fonts/Supplemental/Songti.ttc",
		"C:/Windows/Fonts/msyh.ttc",
		"C:/Windows/Fonts/simhei.ttf",
		"/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
		"/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc",
	]
	var font := _load_font_file(candidates)
	_cjk_font = font if font != null else ThemeDB.fallback_font
	return _cjk_font


static func _load_font_file(paths: Array) -> FontFile:
	for path in paths:
		if not FileAccess.file_exists(String(path)):
			continue
		var font := FontFile.new()
		var err := font.load_dynamic_font(String(path))
		if err == OK:
			return font
	return null


## 展示字体：DIN 等宽高工业感字体，缺字自动回退到 CJK / 默认字体。
static func display_font() -> Font:
	if _display_font != null:
		return _display_font
	var base := _load_font_file([
		"/System/Library/Fonts/Supplemental/DIN Alternate Bold.ttf",
		"/System/Library/Fonts/Supplemental/DIN Condensed Bold.ttf",
		"C:/Windows/Fonts/bahnschrift.ttf",
		"C:/Windows/Fonts/seguisb.ttf",
		"/usr/share/fonts/truetype/dejavu/DejaVuSansCondensed-Bold.ttf",
		"/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
	])
	if base == null:
		_display_font = system_cjk_font()
		return _display_font
	var fallbacks: Array[Font] = [system_cjk_font()]
	if ThemeDB.fallback_font != null and ThemeDB.fallback_font != system_cjk_font():
		fallbacks.append(ThemeDB.fallback_font)
	base.fallbacks = fallbacks
	_display_font = base
	return _display_font


## 数据字体：更窄更硬朗的 DIN Condensed，用于仪表 / 大数字。
static func tech_font() -> Font:
	if _tech_font != null:
		return _tech_font
	var base := _load_font_file([
		"/System/Library/Fonts/Supplemental/DIN Condensed Bold.ttf",
		"/System/Library/Fonts/Supplemental/Arial Narrow Bold.ttf",
		"/System/Library/Fonts/Supplemental/DIN Alternate Bold.ttf",
		"C:/Windows/Fonts/bahnschrift.ttf",
		"/usr/share/fonts/truetype/dejavu/DejaVuSansCondensed-Bold.ttf",
	])
	if base == null:
		_tech_font = display_font()
		return _tech_font
	var fallbacks: Array[Font] = [system_cjk_font()]
	if ThemeDB.fallback_font != null and ThemeDB.fallback_font != system_cjk_font():
		fallbacks.append(ThemeDB.fallback_font)
	base.fallbacks = fallbacks
	_tech_font = base
	return _tech_font


## 给任意字体加字距（商业车游常见的标题拉字距）。
static func tracked_font(base: Font, spacing: int = 2) -> Font:
	if base == null:
		base = system_cjk_font()
	var key := "%d_%d" % [base.get_instance_id(), spacing]
	if _font_cache.has(key):
		return _font_cache[key]
	var fv := FontVariation.new()
	fv.base_font = base
	fv.spacing_glyph = spacing
	_font_cache[key] = fv
	return fv


static func make_theme() -> Theme:
	if _theme_cache != null:
		return _theme_cache
	var theme := Theme.new()
	theme.default_font = system_cjk_font()
	theme.default_font_size = 15
	theme.set_color("font_color", "Label", TXT)
	# 滚动条：统一为细青条，成就 / 设置里的长列表不再是系统默认样式
	var track := StyleBoxFlat.new()
	track.bg_color = Color(0.05, 0.075, 0.095, 0.55)
	track.set_corner_radius_all(R_PILL)
	track.content_margin_left = 2
	track.content_margin_right = 2
	var grab := StyleBoxFlat.new()
	grab.bg_color = a(ACCENT, 0.42)
	grab.set_corner_radius_all(R_PILL)
	grab.content_margin_left = 2
	grab.content_margin_right = 2
	var grab_hi := grab.duplicate() as StyleBoxFlat
	grab_hi.bg_color = a(ACCENT, 0.72)
	var grab_down := grab.duplicate() as StyleBoxFlat
	grab_down.bg_color = a(ACCENT, 0.92)
	for type_name in ["VScrollBar", "HScrollBar"]:
		theme.set_stylebox("scroll", type_name, track)
		theme.set_stylebox("grabber", type_name, grab)
		theme.set_stylebox("grabber_highlight", type_name, grab_hi)
		theme.set_stylebox("grabber_pressed", type_name, grab_down)
	# 折叠区域 / 弹出面板的默认底色
	theme.set_stylebox("panel", "PopupPanel", popup_style(ACCENT))
	_theme_cache = theme
	return theme


static func apply_theme(root: Control) -> void:
	if root == null:
		return
	root.theme = make_theme()


# ---------------------------------------------------------------------------
# 基础工具
# ---------------------------------------------------------------------------

static func a(color: Color, alpha: float) -> Color:
	return Color(color.r, color.g, color.b, alpha)


static func accent_from(value: Variant, fallback: Color = ACCENT) -> Color:
	if value is Color:
		return value
	var hex := String(value)
	if hex.is_empty():
		return fallback
	return Color.from_string(hex, fallback)


static func bright(color: Color, amount: float = 0.18) -> Color:
	return color.lightened(amount)


static func pct(value: float) -> String:
	return "%d%%" % int(round(value * 100.0))


static func spaced(text: String) -> String:
	var out := ""
	for i in text.length():
		var ch := text.substr(i, 1)
		out += ch
		if i < text.length() - 1 and ch != " ":
			out += " "
	return out


static func spacer() -> Control:
	var node := Control.new()
	node.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return node


static func vspace(height: float) -> Control:
	var node := Control.new()
	node.custom_minimum_size = Vector2(0, height)
	node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return node


# ---------------------------------------------------------------------------
# 玻璃面板 / 描边 / 分隔
# ---------------------------------------------------------------------------

## 卡片玻璃：圆角 + 极细青色描边 + 半透明深底，最高级的一层。
static func glass_style(accent_color: Color = ACCENT, alpha: float = 0.92,
		corner: int = R_LG, border_alpha: float = 0.26, hover: bool = false) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	var base := BG_CARD_HI if hover else BG_CARD
	s.bg_color = Color(base.r, base.g, base.b, alpha)
	s.border_color = a(accent_color, border_alpha * (1.55 if hover else 1.0))
	s.set_border_width_all(1)
	s.set_corner_radius_all(corner)
	s.corner_detail = 5
	s.anti_aliasing = true
	s.shadow_color = Color(0.0, 0.0, 0.0, 0.38)
	s.shadow_size = 10
	s.shadow_offset = Vector2(0, 4)
	return s


static func panel_style(accent: Color = ACCENT, alpha: float = 0.94, corner: int = R_LG,
		border_alpha: float = 0.26, margin: int = 0, border_width: int = 1) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = a(BG_PANEL, alpha)
	s.border_color = a(accent, border_alpha)
	s.set_border_width_all(border_width)
	s.set_corner_radius_all(corner)
	s.set_content_margin_all(margin)
	s.anti_aliasing = true
	s.corner_detail = 5
	return s


static func card_style(accent: Color = ACCENT, hover: bool = false, alpha: float = 0.92) -> StyleBoxFlat:
	var s := glass_style(accent, alpha, R_LG, 0.28, hover)
	s.content_margin_left = 18
	s.content_margin_right = 18
	s.content_margin_top = 14
	s.content_margin_bottom = 14
	return s


static func inset_style(accent: Color = ACCENT, alpha: float = 0.6) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = a(BG_INSET, alpha)
	s.border_color = a(accent, 0.16)
	s.set_border_width_all(1)
	s.set_corner_radius_all(R_MD)
	s.content_margin_left = 12
	s.content_margin_right = 12
	s.content_margin_top = 8
	s.content_margin_bottom = 8
	s.anti_aliasing = true
	s.corner_detail = 4
	return s


static func bar_style(fill: bool, accent: Color = ACCENT) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = a(accent, 0.95) if fill else Color(0.075, 0.105, 0.135, 0.85)
	s.set_corner_radius_all(R_SM)
	s.anti_aliasing = true
	s.corner_detail = 3
	if fill:
		s.shadow_color = a(accent, 0.38)
		s.shadow_size = 5
		s.set_content_margin_all(0)
	return s


static func divider(accent: Color = ACCENT, alpha: float = 0.18) -> Control:
	var line := ColorRect.new()
	line.color = a(accent, alpha)
	line.custom_minimum_size = Vector2(0, 1)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return line


## 面板顶部一条「左亮右隐」的青色高光，玻璃质感的点睛。
static func add_top_glow(panel: Control, accent: Color = ACCENT, alpha: float = 0.9) -> TextureRect:
	var tex := TextureRect.new()
	tex.texture = gradient_band_texture(accent)
	tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tex.stretch_mode = TextureRect.STRETCH_SCALE
	tex.modulate = Color(1, 1, 1, alpha)
	tex.set_anchors_preset(Control.PRESET_TOP_WIDE)
	tex.offset_left = 14
	tex.offset_right = -14
	tex.offset_top = 0
	tex.offset_bottom = 1
	tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(tex)
	return tex


## 底部一条横贯的渐隐分隔带（内容是手动摆放时用来分区的）。
static func add_bottom_glow(panel: Control, accent: Color = ACCENT, alpha: float = 0.5) -> TextureRect:
	var tex := TextureRect.new()
	tex.texture = gradient_band_texture(accent)
	tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tex.stretch_mode = TextureRect.STRETCH_SCALE
	tex.flip_h = true
	tex.modulate = Color(1, 1, 1, alpha)
	tex.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	tex.offset_left = 14
	tex.offset_right = -14
	tex.offset_top = -1
	tex.offset_bottom = 0
	tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(tex)
	return tex


# ---------------------------------------------------------------------------
# 按钮 / Tab / Chip（统一 5 态：normal / hover / pressed / focus / disabled）
# ---------------------------------------------------------------------------

static func button_style(accent: Color, kind: String = "ghost", state: String = "normal") -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	var hover: bool = state == "hover"
	var focus: bool = state == "focus"
	var down := state == "pressed"
	var disabled := state == "disabled"
	s.set_corner_radius_all(R_MD)
	s.corner_detail = 4
	s.anti_aliasing = true
	match kind:
		"primary":
			s.bg_color = a(accent, 0.16 if not hover else 0.28)
			if down:
				s.bg_color = a(accent, 0.38)
			s.border_color = a(accent, 0.92 if (hover or focus) else 0.62)
			s.set_border_width_all(1)
			s.shadow_color = a(accent, 0.24 if (hover or focus) else 0.10)
			s.shadow_size = 14 if (hover or focus) else 6
		"solid":
			s.bg_color = a(accent, 0.88 if not hover else 1.0)
			if down:
				s.bg_color = bright(accent, -0.12)
			s.border_color = a(Color.WHITE, 0.22)
			s.set_border_width_all(1)
		"danger":
			s.bg_color = a(BG_CARD_HI, 0.92)
			if hover or focus:
				s.bg_color = a(RED, 0.16)
			s.border_color = a(RED, 0.72 if (hover or focus) else 0.30)
			s.set_border_width_all(1)
			if hover or focus:
				s.shadow_color = a(RED, 0.16)
				s.shadow_size = 10
		_:
			s.bg_color = Color(0.070, 0.102, 0.130, 0.94) if not (hover or focus) else Color(0.098, 0.148, 0.180, 0.97)
			if down:
				s.bg_color = Color(0.056, 0.086, 0.112, 0.98)
			s.border_color = a(accent, 0.80 if (hover or focus) else 0.20)
			s.set_border_width_all(1)
			if hover or focus:
				s.shadow_color = a(accent, 0.15)
				s.shadow_size = 9
	if focus and not disabled:
		s.border_color = a(accent, 1.0)
		s.set_border_width_all(2)
	if disabled:
		s.bg_color = Color(0.055, 0.065, 0.078, 0.65)
		s.border_color = a(LINE, 0.25)
		s.shadow_size = 0
	s.content_margin_left = 16
	s.content_margin_right = 16
	s.content_margin_top = 7
	s.content_margin_bottom = 7
	if down:
		s.content_margin_top = 8
		s.content_margin_bottom = 6
	return s


static func tab_style(accent: Color, active: bool, hover: bool = false) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = a(accent, 0.14) if active else (a(BG_CARD_HI, 0.9) if hover else Color(0.028, 0.043, 0.057, 0.86))
	s.border_color = a(accent, 0.95 if active else (0.35 if hover else 0.14))
	s.border_width_left = 3 if active else 1
	s.border_width_top = 1
	s.border_width_bottom = 1
	s.border_width_right = 1
	s.set_corner_radius_all(R_MD)
	s.corner_detail = 4
	s.content_margin_left = 18
	s.content_margin_right = 12
	s.content_margin_top = 8
	s.content_margin_bottom = 8
	s.anti_aliasing = true
	return s


static func chip_style(accent: Color, active: bool, hover: bool = false) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = a(accent, 0.86) if active else (a(accent, 0.10) if hover else Color(0.036, 0.052, 0.068, 0.9))
	s.border_color = a(accent, 0.95 if active else (0.45 if hover else 0.18))
	s.set_border_width_all(1)
	s.set_corner_radius_all(R_SM)
	s.corner_detail = 4
	s.set_content_margin_all(0)
	s.anti_aliasing = true
	if active:
		s.shadow_color = a(accent, 0.22)
		s.shadow_size = 8
	return s


static func popup_style(accent: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.024, 0.040, 0.054, 0.985)
	s.border_color = a(accent, 0.45)
	s.set_border_width_all(1)
	s.set_corner_radius_all(R_MD)
	s.set_content_margin_all(6)
	s.corner_detail = 4
	return s


# ---------------------------------------------------------------------------
# 控件工厂
# ---------------------------------------------------------------------------

static func label(text: String, font_size: int = F_BODY, color: Color = TXT,
		align: int = HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.horizontal_alignment = align
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", font_size)
	lbl.add_theme_color_override("font_color", color)
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return lbl


## 展示字体标签：英文标题 / 车名 / 站名，追踪字距营造工业感。
static func label_display(text: String, font_size: int = F_H2, color: Color = TXT,
		align: int = HORIZONTAL_ALIGNMENT_LEFT, tracking: int = 1) -> Label:
	var lbl := label(text, font_size, color, align)
	lbl.add_theme_font_override("font", tracked_font(display_font(), tracking))
	return lbl


## 数据字体标签：计时 / 速度 / 档位 / 数值，窄体硬朗。
static func label_tech(text: String, font_size: int = F_H2, color: Color = TXT,
		align: int = HORIZONTAL_ALIGNMENT_LEFT, tracking: int = 0) -> Label:
	var lbl := label(text, font_size, color, align)
	lbl.add_theme_font_override("font", tracked_font(tech_font(), tracking))
	return lbl


## 全大写小标签：kicker / 分区标题，字距拉开。
static func label_tracked(text: String, font_size: int = F_MICRO, color: Color = TXT_DIM,
		align: int = HORIZONTAL_ALIGNMENT_LEFT, tracking: int = 2) -> Label:
	var lbl := label(text, font_size, color, align)
	lbl.add_theme_font_override("font", tracked_font(display_font(), tracking))
	return lbl


static func glow_label(text: String, font_size: int, color: Color,
		align: int = HORIZONTAL_ALIGNMENT_LEFT, outline: int = 4) -> Label:
	var lbl := label(text, font_size, color, align)
	lbl.add_theme_color_override("font_outline_color", a(Color(0, 0, 0), 0.72))
	lbl.add_theme_constant_override("outline_size", outline)
	lbl.add_theme_color_override("font_shadow_color", a(Color(0, 0, 0), 0.5))
	lbl.add_theme_constant_override("shadow_offset_x", 1)
	lbl.add_theme_constant_override("shadow_offset_y", 2)
	return lbl


static func kicker(text: String, accent: Color = ACCENT) -> Label:
	var lbl := label_tracked(text, F_MICRO, a(accent, 0.92), HORIZONTAL_ALIGNMENT_LEFT, 2)
	lbl.add_theme_constant_override("outline_size", 0)
	return lbl


## 01 / 02 这样的序号徽章。
static func index_badge(text: String, accent: Color = ACCENT, size: int = 24) -> PanelContainer:
	var panel := PanelContainer.new()
	var s := StyleBoxFlat.new()
	s.bg_color = a(accent, 0.14)
	s.border_color = a(accent, 0.55)
	s.set_border_width_all(1)
	s.set_corner_radius_all(R_SM)
	s.corner_detail = 4
	s.content_margin_left = 7
	s.content_margin_right = 7
	s.content_margin_top = 0
	s.content_margin_bottom = 0
	panel.add_theme_stylebox_override("panel", s)
	panel.custom_minimum_size = Vector2(size + 8, size)
	panel.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var lbl := label_tracked(text, 11, accent, HORIZONTAL_ALIGNMENT_CENTER, 1)
	panel.add_child(lbl)
	return panel


## 键盘键帽：把快捷键渲染成一个小圆角块，统一所有操作提示的视觉。
static func keycap(text: String, accent: Color = ACCENT, font_size: int = 11) -> PanelContainer:
	var panel := PanelContainer.new()
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.085, 0.118, 0.148, 0.92)
	s.border_color = a(accent, 0.38)
	s.set_border_width_all(1)
	s.set_corner_radius_all(R_SM)
	s.corner_detail = 4
	s.content_margin_left = 7
	s.content_margin_right = 7
	s.content_margin_top = 2
	s.content_margin_bottom = 3
	panel.add_theme_stylebox_override("panel", s)
	panel.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var lbl := label_tracked(text, font_size, a(TXT, 0.92), HORIZONTAL_ALIGNMENT_CENTER, 1)
	panel.add_child(lbl)
	return panel


static func apply_button(btn: Button, accent: Color = ACCENT, kind: String = "ghost",
		font_size: int = F_BODY) -> Button:
	btn.add_theme_font_size_override("font_size", font_size)
	btn.add_theme_font_override("font", display_font())
	btn.add_theme_color_override("font_color", TXT)
	btn.add_theme_color_override("font_hover_color", Color.WHITE)
	btn.add_theme_color_override("font_pressed_color", Color.WHITE)
	btn.add_theme_color_override("font_focus_color", Color.WHITE)
	btn.add_theme_color_override("font_disabled_color", TXT_FAINT)
	btn.add_theme_stylebox_override("normal", button_style(accent, kind, "normal"))
	btn.add_theme_stylebox_override("hover", button_style(accent, kind, "hover"))
	btn.add_theme_stylebox_override("pressed", button_style(accent, kind, "pressed"))
	btn.add_theme_stylebox_override("focus", button_style(accent, kind, "focus"))
	btn.add_theme_stylebox_override("disabled", button_style(accent, kind, "disabled"))
	btn.focus_mode = Control.FOCUS_ALL
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	wire_motion(btn)
	return btn


static func make_button(text: String, accent: Color = ACCENT, kind: String = "ghost",
		font_size: int = F_BODY, min_height: float = 38.0) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(0, min_height)
	btn.alignment = HORIZONTAL_ALIGNMENT_CENTER
	apply_button(btn, accent, kind, font_size)
	return btn


## 悬停 / 按下的统一微动效：轻微缩放 + 焦点亮起。
## 注意：所有 lambda 都在按钮自身信号内使用它，不做延迟回调，避免退出时捕获失效。
static func _motion_scale(btn: Button, target: float, dur: float,
		trans: int = Tween.TRANS_SINE) -> void:
	if not is_instance_valid(btn) or not btn.is_inside_tree():
		return
	btn.pivot_offset = btn.size * 0.5
	var tw := btn.create_tween()
	tw.tween_property(btn, "scale", Vector2(target, target), dur) \
		.set_trans(trans).set_ease(Tween.EASE_OUT)


static func wire_motion(btn: Button) -> void:
	if btn == null or btn.has_meta("ui_motion"):
		return
	btn.set_meta("ui_motion", true)
	btn.mouse_entered.connect(func() -> void:
		if not is_instance_valid(btn) or btn.disabled:
			return
		_motion_scale(btn, 1.012, 0.14)
	)
	btn.mouse_exited.connect(func() -> void:
		if not is_instance_valid(btn):
			return
		_motion_scale(btn, 1.0, 0.18)
	)
	btn.button_down.connect(func() -> void:
		if not is_instance_valid(btn):
			return
		_motion_scale(btn, 0.985, 0.08)
	)
	btn.button_up.connect(func() -> void:
		if not is_instance_valid(btn):
			return
		_motion_scale(btn, 1.012, 0.16, Tween.TRANS_BACK)
	)


static func apply_tab(btn: Button, accent: Color) -> Button:
	btn.toggle_mode = true
	btn.focus_mode = Control.FOCUS_ALL
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	btn.add_theme_font_override("font", display_font())
	btn.add_theme_font_size_override("font_size", F_BODY)
	btn.add_theme_color_override("font_color", TXT_DIM)
	btn.add_theme_color_override("font_hover_color", TXT)
	btn.add_theme_color_override("font_pressed_color", TXT)
	btn.add_theme_color_override("font_hover_pressed_color", TXT)
	btn.add_theme_color_override("font_focus_color", TXT)
	for state in ["normal", "hover", "pressed", "focus", "hover_pressed", "disabled"]:
		var active: bool = state in ["pressed", "hover_pressed"]
		var hover: bool = state in ["hover", "focus"]
		btn.add_theme_stylebox_override(state, tab_style(accent, active, hover))
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	wire_motion(btn)
	return btn


static func apply_chip(btn: Button, accent: Color, font_size: int = F_SMALL) -> Button:
	btn.toggle_mode = true
	btn.add_theme_font_override("font", display_font())
	btn.add_theme_font_size_override("font_size", font_size)
	btn.add_theme_color_override("font_color", TXT_SUB)
	btn.add_theme_color_override("font_hover_color", TXT)
	btn.add_theme_color_override("font_pressed_color", Color(0.02, 0.06, 0.07))
	btn.add_theme_color_override("font_hover_pressed_color", Color(0.02, 0.06, 0.07))
	btn.add_theme_color_override("font_focus_color", TXT)
	for state in ["normal", "hover", "pressed", "focus", "hover_pressed"]:
		var active: bool = state in ["pressed", "hover_pressed"]
		var hover: bool = state in ["hover", "focus"]
		btn.add_theme_stylebox_override(state, chip_style(accent, active, hover))
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	wire_motion(btn)
	return btn


static func style_option_button(opt: OptionButton, accent: Color = ACCENT,
		font_size: int = F_BODY) -> OptionButton:
	opt.add_theme_font_size_override("font_size", font_size)
	opt.add_theme_color_override("font_color", TXT)
	opt.add_theme_color_override("font_hover_color", Color.WHITE)
	opt.add_theme_color_override("font_pressed_color", Color.WHITE)
	opt.add_theme_color_override("font_focus_color", Color.WHITE)
	opt.add_theme_color_override("font_disabled_color", TXT_FAINT)
	opt.add_theme_stylebox_override("normal", button_style(accent, "ghost", "normal"))
	opt.add_theme_stylebox_override("hover", button_style(accent, "ghost", "hover"))
	opt.add_theme_stylebox_override("pressed", button_style(accent, "ghost", "pressed"))
	opt.add_theme_stylebox_override("focus", button_style(accent, "ghost", "focus"))
	opt.add_theme_stylebox_override("disabled", button_style(accent, "ghost", "disabled"))
	opt.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var popup := opt.get_popup()
	popup.add_theme_stylebox_override("panel", popup_style(accent))
	popup.add_theme_stylebox_override("hover", chip_style(accent, false, true))
	popup.add_theme_stylebox_override("separator", bar_style(false, accent))
	popup.add_theme_font_size_override("font_size", font_size)
	popup.add_theme_color_override("font_color", TXT_SUB)
	popup.add_theme_color_override("font_hover_color", TXT)
	popup.add_theme_constant_override("item_start_padding", 12)
	popup.add_theme_constant_override("item_end_padding", 12)
	popup.add_theme_constant_override("v_separation", 10)
	return opt


static func style_slider(slider: HSlider, accent: Color = ACCENT) -> HSlider:
	slider.custom_minimum_size = Vector2(0, 28)
	var track := StyleBoxFlat.new()
	track.bg_color = Color(0.070, 0.100, 0.126, 0.95)
	track.set_corner_radius_all(R_PILL)
	track.content_margin_top = 9
	track.content_margin_bottom = 9
	var fill := StyleBoxFlat.new()
	fill.bg_color = Color(accent.r, accent.g, accent.b, 0.92)
	fill.set_corner_radius_all(R_PILL)
	fill.content_margin_top = 9
	fill.content_margin_bottom = 9
	fill.shadow_color = Color(accent.r, accent.g, accent.b, 0.32)
	fill.shadow_size = 5
	var fill_hi := fill.duplicate() as StyleBoxFlat
	fill_hi.bg_color = bright(accent, 0.15)
	slider.add_theme_stylebox_override("slider", track)
	slider.add_theme_stylebox_override("grabber_area", fill)
	slider.add_theme_stylebox_override("grabber_area_highlight", fill_hi)
	slider.add_theme_icon_override("grabber", grabber_texture(accent))
	slider.add_theme_icon_override("grabber_highlight", grabber_texture(bright(accent, 0.1)))
	slider.add_theme_icon_override("grabber_disabled", grabber_texture(TXT_FAINT))
	slider.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	return slider


static func style_progress(bar: ProgressBar, accent: Color = ACCENT) -> ProgressBar:
	bar.show_percentage = false
	bar.add_theme_stylebox_override("background", bar_style(false, accent))
	bar.add_theme_stylebox_override("fill", bar_style(true, accent))
	return bar


static func style_separator(sep: HSeparator, accent: Color = ACCENT, alpha: float = 0.25) -> HSeparator:
	var s := StyleBoxFlat.new()
	s.bg_color = a(accent, alpha)
	s.set_content_margin_all(0)
	s.content_margin_top = 1
	sep.add_theme_stylebox_override("separator", s)
	return sep


static func accent_line(accent: Color, height: float = 2.0, alpha: float = 0.9) -> ColorRect:
	var line := ColorRect.new()
	line.color = a(accent, alpha)
	line.custom_minimum_size = Vector2(0, height)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return line


static func accent_bar(accent: Color, width: float = 4.0) -> ColorRect:
	var bar := ColorRect.new()
	bar.color = a(accent, 0.95)
	bar.custom_minimum_size = Vector2(width, 0)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return bar


# ---------------------------------------------------------------------------
# 程序化贴图（不依赖任何外部素材）
# ---------------------------------------------------------------------------

static func gradient_texture(top: Color, bottom: Color, horizontal: bool = false) -> GradientTexture2D:
	var key := "grad_%s_%s_%s" % [top.to_html(), bottom.to_html(), horizontal]
	if _tex_cache.has(key):
		return _tex_cache[key]
	var grad := Gradient.new()
	grad.offsets = PackedFloat32Array([0.0, 1.0])
	grad.colors = PackedColorArray([top, bottom])
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.width = 64
	tex.height = 64
	tex.fill_from = Vector2(0.0, 0.0)
	tex.fill_to = Vector2(1.0, 0.0) if horizontal else Vector2(0.0, 1.0)
	_tex_cache[key] = tex
	return tex


static func carbon_texture(base: Color = Color(0.028, 0.038, 0.05, 1.0), tone: Color = Color(0.055, 0.072, 0.09, 1.0)) -> ImageTexture:
	var key := "carbon_%s_%s" % [base.to_html(), tone.to_html()]
	if _tex_cache.has(key):
		return _tex_cache[key]
	var n := 96
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in n:
		for x in n:
			var cell := 12
			var cx := x / cell
			var cy := y / cell
			var weave := 0.5 + 0.5 * sin(float(cx + cy) * PI)
			var warp := 0.5 + 0.5 * sin(float(x) * 0.9 + float(y) * 1.7)
			var t := clampf(weave * 0.6 + warp * 0.4, 0.0, 1.0)
			var col := base.lerp(tone, t * 0.85)
			var sheen := clampf((sin(float(x + y) * 0.12) * 0.5 + 0.5) * 0.10, 0.0, 0.1)
			col = col.lightened(sheen)
			img.set_pixel(x, y, col)
	img.generate_mipmaps()
	var tex := ImageTexture.create_from_image(img)
	_tex_cache[key] = tex
	return tex


static func grid_texture(line: Color = Color(0.45, 0.75, 0.85, 0.16), cell: int = 34) -> ImageTexture:
	var key := "grid_%s_%d" % [line.to_html(), cell]
	if _tex_cache.has(key):
		return _tex_cache[key]
	var n := cell * 4
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for i in range(0, n, cell):
		for k in n:
			img.set_pixel(i, k, line)
			img.set_pixel(k, i, line)
	img.generate_mipmaps()
	var tex := ImageTexture.create_from_image(img)
	_tex_cache[key] = tex
	return tex


static func scanline_texture(alpha: float = 0.10, step: int = 3) -> ImageTexture:
	var key := "scan_%.2f_%d" % [alpha, step]
	if _tex_cache.has(key):
		return _tex_cache[key]
	var img := Image.create(4, step * 2, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for x in 4:
		for y in step:
			img.set_pixel(x, y, Color(0, 0, 0, alpha))
	var tex := ImageTexture.create_from_image(img)
	_tex_cache[key] = tex
	return tex


static func glow_texture(color: Color = ACCENT, power: float = 2.0) -> ImageTexture:
	var key := "glow_%s_%.1f" % [color.to_html(), power]
	if _tex_cache.has(key):
		return _tex_cache[key]
	var n := 128
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var mid := (n - 1) * 0.5
	for y in n:
		for x in n:
			var d := Vector2(float(x) - mid, float(y) - mid).length() / (mid + 1.0)
			var alpha := pow(clampf(1.0 - d, 0.0, 1.0), power)
			img.set_pixel(x, y, Color(color.r, color.g, color.b, alpha * 0.85))
	img.generate_mipmaps()
	var tex := ImageTexture.create_from_image(img)
	_tex_cache[key] = tex
	return tex


static func gradient_band_texture(accent: Color, from_left: bool = true) -> ImageTexture:
	var key := "band_%s_%s" % [accent.to_html(), from_left]
	if _tex_cache.has(key):
		return _tex_cache[key]
	var n := 64
	var img := Image.create(n, 4, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for x in n:
		var t := float(x) / float(n - 1)
		if not from_left:
			t = 1.0 - t
		var alpha := pow(1.0 - t, 1.6) * 0.9
		for y in 4:
			img.set_pixel(x, y, Color(accent.r, accent.g, accent.b, alpha))
	var tex := ImageTexture.create_from_image(img)
	_tex_cache[key] = tex
	return tex


static func grabber_texture(color: Color = ACCENT) -> ImageTexture:
	var key := "grab_%s" % color.to_html()
	if _tex_cache.has(key):
		return _tex_cache[key]
	var w := 14
	var h := 26
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var radius := 4
	for y in h:
		for x in w:
			var dx := minf(x, w - 1 - x)
			var dy := minf(y, h - 1 - y)
			if dx < radius and dy < radius:
				continue
			var edge := dx <= 1 or dy <= 1
			var col := Color(0.92, 0.97, 1.0, 1.0) if edge else color
			if y == h / 2:
				col = Color(0.98, 0.99, 1.0, 1.0)
			img.set_pixel(x, y, col)
	var tex := ImageTexture.create_from_image(img)
	_tex_cache[key] = tex
	return tex


static func vignette_texture(center: Vector2 = Vector2(0.5, 0.5), strength: float = 0.5,
		radius: float = 0.42) -> ImageTexture:
	var key := "vig_%s_%.2f_%.2f" % [center, strength, radius]
	if _tex_cache.has(key):
		return _tex_cache[key]
	var n := 192
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	for y in n:
		for x in n:
			var uv := Vector2(float(x) / n, float(y) / n)
			var dx := (uv.x - center.x) / 0.72
			var dy := (uv.y - center.y) / 0.72
			var d := sqrt(dx * dx + dy * dy)
			var alpha := clampf((d - radius) / (1.0 - radius), 0.0, 1.0)
			alpha = pow(alpha, 1.5) * strength
			img.set_pixel(x, y, Color(0, 0, 0, alpha))
	img.generate_mipmaps()
	var tex := ImageTexture.create_from_image(img)
	_tex_cache[key] = tex
	return tex


## 横向渐隐遮罩贴图：给 3D 场景压边用（左右/上下都能翻转）。
static func edge_fade_texture(edge_color: Color = Color(0, 0, 0, 0.85), fade_from: bool = true) -> ImageTexture:
	var key := "edgefade_%s_%s" % [edge_color.to_html(), fade_from]
	if _tex_cache.has(key):
		return _tex_cache[key]
	var n := 128
	var img := Image.create(n, 4, false, Image.FORMAT_RGBA8)
	for x in n:
		var t := float(x) / float(n - 1)
		if not fade_from:
			t = 1.0 - t
		var alpha := edge_color.a * pow(1.0 - t, 1.4)
		for y in 4:
			img.set_pixel(x, y, Color(edge_color.r, edge_color.g, edge_color.b, alpha))
	img.generate_mipmaps()
	var tex := ImageTexture.create_from_image(img)
	_tex_cache[key] = tex
	return tex


# ---------------------------------------------------------------------------
# 场景级背景装饰（菜单 / 车库 / 结算共用）
# ---------------------------------------------------------------------------

## 全屏电影感压暗：上下渐隐 + 暗角，确保 3D 实景上的文字可读。
static func cinematic_backdrop(parent: Control, top_alpha: float = 0.55,
		bottom_alpha: float = 0.82, vignette: float = 0.55) -> void:
	var top := TextureRect.new()
	top.texture = gradient_texture(Color(0, 0, 0, top_alpha), Color(0, 0, 0, 0.0))
	top.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	top.stretch_mode = TextureRect.STRETCH_SCALE
	top.set_anchors_preset(Control.PRESET_TOP_WIDE)
	top.offset_bottom = 200
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(top)
	var bottom := TextureRect.new()
	bottom.texture = gradient_texture(Color(0, 0, 0, 0.0), Color(0, 0, 0, bottom_alpha))
	bottom.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bottom.stretch_mode = TextureRect.STRETCH_SCALE
	bottom.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	bottom.offset_top = -280
	bottom.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(bottom)
	var vig := TextureRect.new()
	vig.texture = vignette_texture(Vector2(0.5, 0.5), vignette, 0.30)
	vig.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	vig.stretch_mode = TextureRect.STRETCH_SCALE
	vig.set_anchors_preset(Control.PRESET_FULL_RECT)
	vig.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(vig)


## 右侧信息栏的横向渐隐底（菜单 / 车库）。
static func side_rail(parent: Control, width: float = 700.0, alpha: float = 0.94) -> TextureRect:
	var tex := TextureRect.new()
	tex.texture = gradient_texture(Color(0.012, 0.020, 0.028, 0.0),
		Color(0.012, 0.020, 0.028, alpha), true)
	tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tex.stretch_mode = TextureRect.STRETCH_SCALE
	tex.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	tex.offset_left = -width
	tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(tex)
	return tex


# ---------------------------------------------------------------------------
# 动效
# ---------------------------------------------------------------------------

static func reveal(node: CanvasItem, delay: float = 0.0, dur: float = 0.35) -> void:
	if node == null:
		return
	node.modulate.a = 0.0
	var tw := node.create_tween()
	tw.tween_property(node, "modulate:a", 1.0, dur).set_delay(delay).set_trans(Tween.TRANS_SINE)


static func slide_in(node: Control, from_x: float = 48.0, delay: float = 0.0, dur: float = 0.5) -> void:
	if node == null:
		return
	var base := node.position
	node.modulate.a = 0.0
	node.position = base + Vector2(from_x, 0.0)
	var tw := node.create_tween()
	tw.set_parallel(true)
	tw.tween_property(node, "modulate:a", 1.0, dur * 0.7).set_delay(delay)
	tw.tween_property(node, "position", base, dur).set_delay(delay) \
		.set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)


static func scale_in(node: Control, delay: float = 0.0, dur: float = 0.3) -> void:
	if node == null:
		return
	node.pivot_offset = node.size * 0.5
	node.scale = Vector2(0.97, 0.97)
	node.modulate.a = 0.0
	var tw := node.create_tween()
	tw.set_parallel(true)
	tw.tween_property(node, "modulate:a", 1.0, dur).set_delay(delay)
	tw.tween_property(node, "scale", Vector2.ONE, dur).set_delay(delay) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


static func flash(node: CanvasItem, color: Color, peak: float = 0.22, dur: float = 0.32) -> void:
	if node == null:
		return
	var tw := node.create_tween()
	tw.tween_property(node, "modulate", Color(1.0 + peak, 1.0 + peak, 1.0 + peak, 1.0), dur * 0.35)
	tw.tween_property(node, "modulate", Color.WHITE, dur * 0.65)


static func hover_glow(control: Control, accent: Color, bar: Control = null,
		glow: Control = null) -> void:
	if control == null:
		return
	control.mouse_entered.connect(func() -> void:
		var tw := control.create_tween()
		tw.set_parallel(true)
		tw.tween_property(control, "modulate", Color(1.06, 1.06, 1.06, 1.0), 0.16)
		if bar != null:
			tw.tween_property(bar, "color", a(accent, 1.0), 0.16)
		if glow != null:
			tw.tween_property(glow, "modulate:a", 1.0, 0.20))
	control.mouse_exited.connect(func() -> void:
		var tw := control.create_tween()
		tw.set_parallel(true)
		tw.tween_property(control, "modulate", Color.WHITE, 0.20)
		if bar != null:
			tw.tween_property(bar, "color", a(accent, 0.55), 0.20)
		if glow != null:
			tw.tween_property(glow, "modulate:a", 0.0, 0.24))


static func place(control: Control, al: float, at: float, ar: float, ab: float,
		ol: float, ot: float, orr: float, ob: float) -> void:
	control.anchor_left = al
	control.anchor_top = at
	control.anchor_right = ar
	control.anchor_bottom = ab
	control.offset_left = ol
	control.offset_top = ot
	control.offset_right = orr
	control.offset_bottom = ob


static func full_rect(control: Control) -> void:
	control.set_anchors_preset(Control.PRESET_FULL_RECT)
