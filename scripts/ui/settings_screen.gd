class_name SettingsScreen
extends CanvasLayer
## APEX VELOCITY · 商业赛车游戏风格设置中心。
## 分类 Tab：画面 GRAPHICS / 音频 AUDIO / 操作 CONTROLS / 游戏 GAME。
## · 画面：画质档位 + 分辨率・窗口模式・帧率上限・垂直同步 + 渲染细项
##        （渲染缩放 / 升频 / MSAA / TAA / SSR / SSAO / SSIL / 体积雾）+ 画面效果
## · 音频：Master / Music / Engine / Wind / SFX / UI 六条总线独立滑条，实时生效
## · 操作：键盘映射表 + 转向灵敏度 / 相机震动
## · 游戏：HUD 元素开关、速度单位、圈数覆盖、平台信息、恢复默认
## 所有改动即时生效并写入 user://settings.json。

const PlatformProfile := preload("res://scripts/core/platform_profile.gd")

signal closed

const TABS := [
	{"cn": "画面", "en": "GRAPHICS", "icon": "01"},
	{"cn": "音频", "en": "AUDIO", "icon": "02"},
	{"cn": "操作", "en": "CONTROLS", "icon": "03"},
	{"cn": "游戏", "en": "GAME", "icon": "04"},
]

var main_ref: Node
var selected_tab := 0
var accent := UIStyle.ACCENT

var _root: Control
var _backdrop: Control
var _panel: Control
var _pages: Array[Control] = []
var _tab_buttons: Array[Button] = []
var _footer: Control
var _summary_label: Label
var _tab_titles: Array[Label] = []

var _quality_buttons: Array[Button] = []
var _quality_detail_labels: Array[Label] = []
var _resolution_opt: OptionButton
var _chips: Dictionary = {}          # key -> Array[Button]
var _toggles: Dictionary = {}        # key -> UIToggle
var _sliders: Dictionary = {}        # key -> HSlider
var _value_labels: Dictionary = {}   # key -> Label
var _bus_status: Dictionary = {}     # key -> Label (总线检测)
var _platform_label: Label
var _budget_label: Label
var _output_label: Label
var _save_label: Label
var _rail_platform: Label
var _hud_preview: Control
var _syncing := false
var _opened_once := false
var _closing := false
var _analog_status: Label
var _analog_timer: Timer


func _ready() -> void:
	layer = 80
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()
	visible = false
	_analog_timer = Timer.new()
	_analog_timer.wait_time = 0.5
	_analog_timer.autostart = true
	_analog_timer.timeout.connect(_refresh_analog_status)
	add_child(_analog_timer)
	Settings.changed.connect(_on_settings_changed)
	Settings.audio_changed.connect(_on_settings_changed)


# ---------------------------------------------------------------------------
# 构建
# ---------------------------------------------------------------------------

func _build() -> void:
	_root = Control.new()
	_root.name = "Root"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	UIStyle.apply_theme(_root)
	add_child(_root)

	_backdrop = _build_backdrop()
	_root.add_child(_backdrop)

	_build_header()
	_build_rail()
	_build_footer()

	# 内容区
	var content := Control.new()
	content.name = "Content"
	UIStyle.place(content, 0, 0, 0, 0, 244, 96, 1600, 812)
	_root.add_child(content)
	_panel = content
	for i in TABS.size():
		var page := _build_page_container(i)
		content.add_child(page)
		_pages.append(page)
	_build_graphics_page(_pages[0])
	_build_audio_page(_pages[1])
	_build_controls_page(_pages[2])
	_build_game_page(_pages[3])
	_sync_all()


func _build_backdrop() -> Control:
	var bg := Control.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var base := ColorRect.new()
	base.color = Color(0.005, 0.008, 0.012, 1.0)
	base.set_anchors_preset(Control.PRESET_FULL_RECT)
	base.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.add_child(base)

	var carbon := TextureRect.new()
	carbon.texture = UIStyle.carbon_texture(Color(0.020, 0.028, 0.038), Color(0.040, 0.055, 0.070))
	carbon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	carbon.stretch_mode = TextureRect.STRETCH_TILE
	carbon.modulate = Color(1, 1, 1, 0.55)
	carbon.set_anchors_preset(Control.PRESET_FULL_RECT)
	carbon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.add_child(carbon)

	var grid := TextureRect.new()
	grid.texture = UIStyle.grid_texture(Color(0.35, 0.75, 0.90, 0.07), 48)
	grid.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	grid.stretch_mode = TextureRect.STRETCH_TILE
	grid.set_anchors_preset(Control.PRESET_FULL_RECT)
	grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.add_child(grid)

	# 左上主题色辉光
	var glow := TextureRect.new()
	glow.texture = UIStyle.glow_texture(accent, 1.8)
	glow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	glow.stretch_mode = TextureRect.STRETCH_SCALE
	glow.modulate = Color(1, 1, 1, 0.20)
	UIStyle.place(glow, 0, 0, 0, 0, -420, -460, 980, 700)
	glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.add_child(glow)

	# 右侧大号品牌水印
	var mark := UIStyle.label("APEX\nVELOCITY", 128, Color(0.60, 0.90, 1.0, 0.045),
		HORIZONTAL_ALIGNMENT_RIGHT)
	mark.add_theme_constant_override("line_spacing", -22)
	UIStyle.place(mark, 1, 1, 1, 1, -780, -420, -40, -40)
	bg.add_child(mark)

	var vig := TextureRect.new()
	vig.texture = UIStyle.vignette_texture(Vector2(0.5, 0.5), 0.62, 0.35)
	vig.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	vig.stretch_mode = TextureRect.STRETCH_SCALE
	vig.set_anchors_preset(Control.PRESET_FULL_RECT)
	vig.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.add_child(vig)

	var top_line := ColorRect.new()
	top_line.color = Color(accent.r, accent.g, accent.b, 0.55)
	UIStyle.place(top_line, 0, 0, 1, 0, 0, 0, 0, 2)
	top_line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.add_child(top_line)
	return bg


func _build_header() -> void:
	var header := Control.new()
	UIStyle.place(header, 0, 0, 1, 0, 0, 0, 0, 92)
	_root.add_child(header)

	var slash := ColorRect.new()
	slash.color = accent
	UIStyle.place(slash, 0, 0, 0, 0, 40, 26, 44, 68)
	slash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.add_child(slash)

	var title := UIStyle.label_display("SETTINGS", 38, UIStyle.TXT,
		HORIZONTAL_ALIGNMENT_LEFT, 2)
	UIStyle.place(title, 0, 0, 0, 0, 60, 18, 460, 70)
	header.add_child(title)

	var cn := UIStyle.label_tracked("设 置 中 心   ·   APEX VELOCITY", 11, Color(accent.r, accent.g, accent.b, 0.95),
		HORIZONTAL_ALIGNMENT_LEFT, 2)
	UIStyle.place(cn, 0, 0, 0, 0, 62, 64, 620, 88)
	header.add_child(cn)

	_summary_label = UIStyle.label("", 12, Color(0.70, 0.80, 0.88, 1.0), HORIZONTAL_ALIGNMENT_RIGHT)
	UIStyle.place(_summary_label, 1, 0, 1, 0, -900, 30, -252, 60)
	header.add_child(_summary_label)

	var close_btn := UIStyle.make_button("✕   完成   ESC", accent, "ghost", 15, 42.0)
	UIStyle.place(close_btn, 1, 0, 1, 0, -232, 26, -40, 68)
	close_btn.pressed.connect(close)
	header.add_child(close_btn)

	var sep := ColorRect.new()
	sep.color = Color(accent.r, accent.g, accent.b, 0.22)
	UIStyle.place(sep, 0, 0, 1, 0, 40, 90, -40, 91)
	sep.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.add_child(sep)


func _build_rail() -> void:
	var rail := Panel.new()
	rail.add_theme_stylebox_override("panel", UIStyle.panel_style(accent, 0.55, 0, 0.10, 0, 0))
	UIStyle.place(rail, 0, 0, 0, 1, 0, 91, 244, -88)
	rail.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(rail)

	var rail_line := ColorRect.new()
	rail_line.color = Color(accent.r, accent.g, accent.b, 0.16)
	UIStyle.place(rail_line, 0, 0, 0, 1, 243, 91, 244, -88)
	rail_line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(rail_line)

	for i in TABS.size():
		var btn := Button.new()
		btn.text = "  %s    %s  %s" % [String(TABS[i]["icon"]), String(TABS[i]["cn"]),
			String(TABS[i]["en"])]
		btn.toggle_mode = true
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.add_theme_font_override("font", UIStyle.display_font())
		btn.add_theme_font_size_override("font_size", 14)
		btn.add_theme_color_override("font_color", UIStyle.TXT_DIM)
		btn.add_theme_color_override("font_hover_color", UIStyle.TXT)
		btn.add_theme_color_override("font_pressed_color", accent)
		btn.add_theme_color_override("font_hover_pressed_color", accent)
		btn.add_theme_color_override("font_focus_color", UIStyle.TXT)
		for state in ["normal", "hover", "pressed", "focus", "hover_pressed"]:
			var active: bool = state in ["pressed", "hover_pressed"]
			var hover: bool = state in ["hover", "focus"]
			btn.add_theme_stylebox_override(state, UIStyle.tab_style(accent, active, hover))
		btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		UIStyle.place(btn, 0, 0, 0, 0, 20, 118 + i * 66, 224, 176 + i * 66)
		btn.pressed.connect(_select_tab.bind(i))
		_tab_buttons.append(btn)
		_root.add_child(btn)

	# 左下角平台标签
	var platform := UIStyle.label("", 11, UIStyle.TXT_FAINT)
	platform.add_theme_constant_override("line_spacing", 4)
	UIStyle.place(platform, 0, 1, 0, 1, 28, -238, 224, -112)
	platform.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_root.add_child(platform)
	_rail_platform = platform

	var ver := UIStyle.label("v0.4  ·  APEX UI", 11, Color(accent.r, accent.g, accent.b, 0.45))
	UIStyle.place(ver, 0, 1, 0, 1, 28, -104, 224, -84)
	_root.add_child(ver)
	_refresh_rail_platform(platform)


func _refresh_rail_platform(label: Label) -> void:
	if label == null:
		return
	var info := PlatformProfile.info()
	var gpu := String(info["gpu"])
	if gpu.length() > 26:
		gpu = gpu.substr(0, 26) + "…"
	label.text = "%s\n%s\n%s / %s\nHiDPI %.1fx   ·   推荐 %s" % [
		String(info["os"]), gpu, String(info["driver"]), String(info["method"]),
		float(info["scale"]), String(Settings.PRESETS[int(info["recommended"])]["name"])]


func _build_footer() -> void:
	_footer = Control.new()
	UIStyle.place(_footer, 0, 1, 1, 1, 0, -88, 0, 0)
	_root.add_child(_footer)

	var line := ColorRect.new()
	line.color = Color(accent.r, accent.g, accent.b, 0.20)
	UIStyle.place(line, 0, 0, 1, 0, 40, 0, -40, 1)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_footer.add_child(line)

	var hint := UIStyle.label(
		"S / ESC / F2 关闭     ·     Tab / ←→ 切换分页     ·     滑块可拖动或用方向键微调     ·     改动即时生效并自动保存",
		12, UIStyle.TXT_FAINT)
	UIStyle.place(hint, 0, 1, 0, 1, 42, -50, 900, -22)
	_footer.add_child(hint)

	var reset := UIStyle.make_button("↺   恢复默认  RESET", UIStyle.GOLD, "ghost", 14, 38.0)
	UIStyle.place(reset, 1, 1, 1, 1, -420, -56, -238, -18)
	reset.pressed.connect(_on_reset_pressed)
	_footer.add_child(reset)

	var done := UIStyle.make_button("✓   应用并返回  DONE", accent, "primary", 15, 40.0)
	UIStyle.place(done, 1, 1, 1, 1, -220, -57, -40, -17)
	done.pressed.connect(close)
	_footer.add_child(done)


func _build_page_container(i: int) -> Control:
	var holder := Control.new()
	holder.name = "Page%d" % i
	UIStyle.place(holder, 0, 0, 1, 1, 0, 0, 0, 0)
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE

	# 页头
	var head := Control.new()
	UIStyle.place(head, 0, 0, 1, 0, 0, 0, 0, 84)
	holder.add_child(head)

	var kicker := UIStyle.label_tracked("APEX / %s" % String(TABS[i]["en"]), 9,
		Color(accent.r, accent.g, accent.b, 0.9), HORIZONTAL_ALIGNMENT_LEFT, 2)
	UIStyle.place(kicker, 0, 0, 0, 0, 26, 4, 500, 24)
	head.add_child(kicker)

	var title_text := "%s   /   %s" % [String(TABS[i]["cn"]), String(TABS[i]["en"])]
	var title := UIStyle.label_display(title_text, 30, UIStyle.TXT,
		HORIZONTAL_ALIGNMENT_LEFT, 1)
	UIStyle.place(title, 0, 0, 0, 0, 24, 22, 760, 72)
	head.add_child(title)
	_tab_titles.append(title)

	var idx := UIStyle.label_tech(String(TABS[i]["icon"]), 54, Color(accent.r, accent.g, accent.b, 0.16),
		HORIZONTAL_ALIGNMENT_RIGHT)
	UIStyle.place(idx, 1, 0, 1, 0, -160, 8, -20, 78)
	head.add_child(idx)

	var hline := ColorRect.new()
	hline.color = Color(accent.r, accent.g, accent.b, 0.14)
	UIStyle.place(hline, 0, 0, 1, 0, 24, 82, -20, 83)
	hline.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_child(hline)
	return holder


func _column(parent: Control, x: float, y: float, w: float, h: float) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.position = Vector2(x, y)
	box.size = Vector2(w, h)
	box.add_theme_constant_override("separation", 10)
	parent.add_child(box)
	return box


# ---------------------------------------------------------------------------
# 画面页
# ---------------------------------------------------------------------------

func _build_graphics_page(page: Control) -> void:
	var left := _column(page, 24, 96, 632, 620)
	var right := _column(page, 684, 96, 632, 620)
	_build_quality_section(left)
	_build_display_section(left)
	_build_budget_section(left)
	_build_render_section(right)
	_build_effect_section(right)

	var sweep := UIFrame.new()
	sweep.setup(Color(accent.r, accent.g, accent.b, 1.0), 18.0, 0.16)
	sweep.scan = true
	UIStyle.place(sweep, 0, 0, 1, 1, 0, 84, 0, -4)
	page.add_child(sweep)


func _section(parent: Control, cn: String, en: String) -> VBoxContainer:
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 10)
	var mark := ColorRect.new()
	mark.color = accent
	mark.custom_minimum_size = Vector2(4, 14)
	mark.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_child(mark)
	var title := UIStyle.label_display(cn, 14, UIStyle.TXT, HORIZONTAL_ALIGNMENT_LEFT, 1)
	head.add_child(title)
	var sub := UIStyle.label_tracked("  /  %s" % en, 9, Color(accent.r, accent.g, accent.b, 0.85),
		HORIZONTAL_ALIGNMENT_LEFT, 1)
	head.add_child(sub)
	var line := ColorRect.new()
	line.color = Color(accent.r, accent.g, accent.b, 0.14)
	line.custom_minimum_size = Vector2(0, 1)
	line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(line)
	parent.add_child(head)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 3)
	parent.add_child(box)
	return box


func _build_quality_section(col: VBoxContainer) -> void:
	var body := _section(col, "画质档位", "QUALITY PRESET")
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 10)
	body.add_child(grid)
	for i in Settings.PRESETS.size():
		var preset: Dictionary = Settings.PRESETS[i]
		var card := Button.new()
		card.toggle_mode = true
		card.custom_minimum_size = Vector2(0, 76)
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		card.add_theme_stylebox_override("normal", UIStyle.card_style(accent, false, 0.86))
		card.add_theme_stylebox_override("hover", UIStyle.card_style(accent, true, 0.92))
		card.add_theme_stylebox_override("pressed", UIStyle.card_style(accent, true, 0.98))
		card.add_theme_stylebox_override("focus", UIStyle.card_style(accent, true, 0.92))
		card.add_theme_stylebox_override("hover_pressed", UIStyle.card_style(accent, true, 0.98))
		card.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		card.pressed.connect(_select_quality.bind(i))
		grid.add_child(card)
		_quality_buttons.append(card)

		var box := VBoxContainer.new()
		box.set_anchors_preset(Control.PRESET_FULL_RECT)
		box.offset_left = 14
		box.offset_top = 10
		box.offset_right = -12
		box.offset_bottom = -8
		box.add_theme_constant_override("separation", 2)
		box.mouse_filter = Control.MOUSE_FILTER_IGNORE
		card.add_child(box)

		var name_label := UIStyle.label(String(preset["name"]), 19, UIStyle.TXT)
		box.add_child(name_label)
		if i == PlatformProfile.recommended_quality():
			var rec := UIStyle.label("推荐", 9, UIStyle.GOLD, HORIZONTAL_ALIGNMENT_RIGHT)
			rec.set_anchors_preset(Control.PRESET_TOP_RIGHT)
			rec.offset_left = -90
			rec.offset_right = -12
			rec.offset_top = 6
			rec.offset_bottom = 22
			rec.mouse_filter = Control.MOUSE_FILTER_IGNORE
			card.add_child(rec)
		var detail := UIStyle.label("", 10, UIStyle.TXT_DIM)
		detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		box.add_child(detail)
		_quality_detail_labels.append(detail)

		var bar := ColorRect.new()
		bar.custom_minimum_size = Vector2(0, 2)
		bar.color = Color(accent.r, accent.g, accent.b, 0.30)
		bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(bar)

	var note := UIStyle.label("切换档位会重置渲染细项；单独调整细项即进入「自定义」。", 10, UIStyle.TXT_FAINT)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(note)


func _build_display_section(col: VBoxContainer) -> void:
	var body := _section(col, "显示", "DISPLAY")

	# 分辨率
	var row := _row(body, "分辨率", "RESOLUTION", "窗口 / 全屏下的渲染分辨率")
	_resolution_opt = OptionButton.new()
	_resolution_opt.custom_minimum_size = Vector2(260, 38)
	_resolution_opt.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	UIStyle.style_option_button(_resolution_opt, accent, 14)
	for i in Settings.RESOLUTIONS.size():
		var res: Dictionary = Settings.RESOLUTIONS[i]
		_resolution_opt.add_item("%s   %s" % [String(res["name"]), String(res["tag"])], i)
	_resolution_opt.item_selected.connect(_on_resolution_selected)
	row.add_child(_resolution_opt)

	# 窗口模式
	var mode_row := _row(body, "显示模式", "DISPLAY MODE", "全屏独占 / 无边框 / 窗口")
	_chip_row(mode_row, "window_mode", Settings.DISPLAY_MODES, 92.0)

	# 帧率上限
	var fps_row := _row(body, "帧率上限", "FRAME RATE LIMIT", "限制最大帧率，降低功耗与发热")
	_chip_row(fps_row, "fps_limit", Settings.FPS_OPTIONS, 54.0)

	# 垂直同步
	_toggle_row(body, "垂直同步", "V-SYNC", "vsync_enabled",
		"消除画面撕裂；高刷新率屏幕上建议开启", 150.0)


func _build_budget_section(col: VBoxContainer) -> void:
	var body := _section(col, "渲染预算", "RENDER BUDGET")
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UIStyle.inset_style(accent, 0.5))
	body.add_child(panel)
	_budget_label = UIStyle.label("", 11, UIStyle.TXT_SUB)
	_budget_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_budget_label.add_theme_constant_override("line_spacing", 4)
	panel.add_child(_budget_label)


func _build_render_section(col: VBoxContainer) -> void:
	var body := _section(col, "渲染", "RENDERING")
	_slider_row(body, "渲染缩放", "RENDER SCALE", "render_scale", 0.5, 1.0, 0.01, "%.0f%%", 100.0)

	var up_row := _row(body, "时间升频 / 抗锯齿", "TEMPORAL UPSCALING", "macOS 走 MetalFX，桌面走 FSR2")
	_chip_row(up_row, "upscale", _upscale_options(), 98.0)

	var msaa_row := _row(body, "多重采样 MSAA", "MULTISAMPLE AA", "配合 TAA 使用，边缘更干净")
	_chip_row(msaa_row, "msaa", Settings.MSAA_OPTIONS, 80.0)

	var taa_row := _row(body, "时间抗锯齿 TAA", "TEMPORAL AA", "静态画面更稳；快速移动可能轻微拖影")
	_toggle_row_direct(taa_row, "taa", 120.0)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 2)
	body.add_child(grid)
	_add_toggle_cell(grid, "屏空间反射 SSR", "ssr", "车身/水面反射")
	_add_toggle_cell(grid, "屏空间环境光遮蔽", "ssao", "接触阴影更扎实")
	_add_toggle_cell(grid, "屏空间间接光照", "ssil", "暗部颜色更丰富")
	_add_toggle_cell(grid, "体积雾", "volumetric", "空气感 / 光束")
	_add_toggle_cell(grid, "树木阴影", "tree_shadows", "更真实但更吃性能")


func _build_effect_section(col: VBoxContainer) -> void:
	var body := _section(col, "画面效果", "IMAGE EFFECTS")
	var blur_row := _row(body, "速度动态模糊", "MOTION BLUR", "高速时画面边缘拉丝")
	_toggle_row_direct(blur_row, "motion_blur_enabled", 110.0)
	_slider_row(body, "动态模糊强度", "BLUR AMOUNT", "motion_blur", 0.0, 1.0, 0.01, "%d%%", 100.0)
	_slider_row(body, "画面锐化", "SHARPNESS", "sharpen", 0.0, 1.0, 0.01, "%d%%", 100.0)
	_slider_row(body, "远景清晰度", "FAR CLARITY", "far_clarity", 0.6, 1.6, 0.01, "%.2fx", 100.0)
	var vig_row := _row(body, "暗角", "VIGNETTE", "比赛 HUD 四周电影感压暗")
	_toggle_row_direct(vig_row, "vignette", 120.0)


# ---------------------------------------------------------------------------
# 音频页
# ---------------------------------------------------------------------------

func _build_audio_page(page: Control) -> void:
	var left := _column(page, 24, 96, 720, 620)
	var right := _column(page, 776, 96, 540, 620)
	_build_audio_buses(left)
	_build_audio_options(right)


func _build_audio_buses(col: VBoxContainer) -> void:
	var body := _section(col, "混音总线", "MIXER BUS")
	var detected := 0
	for entry in Settings.AUDIO_BUSES:
		if Settings.audio_bus_available(String(entry["bus"])):
			detected += 1
	var status := UIStyle.label("已检测到 %d / %d 条总线" % [detected, Settings.AUDIO_BUSES.size()],
		11, UIStyle.GREEN if detected >= Settings.AUDIO_BUSES.size() else UIStyle.GOLD)
	col.add_child(status)

	for entry in Settings.AUDIO_BUSES:
		var key := String(entry["key"])
		var bus := String(entry["bus"])
		var row_panel := PanelContainer.new()
		row_panel.add_theme_stylebox_override("panel", UIStyle.inset_style(accent, 0.62))
		row_panel.custom_minimum_size = Vector2(0, 62)
		body.add_child(row_panel)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 14)
		row_panel.add_child(row)

		var name_box := VBoxContainer.new()
		name_box.custom_minimum_size = Vector2(150, 0)
		name_box.add_theme_constant_override("separation", 1)
		row.add_child(name_box)
		var name_label := UIStyle.label(String(entry["cn"]), 17, UIStyle.TXT)
		name_box.add_child(name_label)
		var en_label := UIStyle.label("%s  ·  %s" % [String(entry["en"]), bus], 10,
			Color(accent.r, accent.g, accent.b, 0.8))
		name_box.add_child(en_label)

		var slider := HSlider.new()
		slider.min_value = 0.0
		slider.max_value = 1.0
		slider.step = 0.01
		slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		slider.custom_minimum_size = Vector2(0, 26)
		UIStyle.style_slider(slider, accent)
		slider.value_changed.connect(_on_slider_changed.bind(key))
		row.add_child(slider)
		_sliders[key] = slider

		var value_label := UIStyle.label("", 15, UIStyle.TXT, HORIZONTAL_ALIGNMENT_RIGHT)
		value_label.custom_minimum_size = Vector2(58, 0)
		row.add_child(value_label)
		_value_labels[key] = value_label

		var dot := ColorRect.new()
		dot.custom_minimum_size = Vector2(8, 8)
		dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		dot.color = UIStyle.GREEN if Settings.audio_bus_available(bus) else UIStyle.GOLD
		dot.tooltip_text = "总线已创建" if Settings.audio_bus_available(bus) else "总线未创建（数值仍会保存）"
		row.add_child(dot)

	var hint := UIStyle.label("滑条实时写入 AudioServer 对应总线；比赛中的引擎 / 风噪 / 音效即时变化。", 11, UIStyle.TXT_FAINT)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(hint)


func _build_audio_options(col: VBoxContainer) -> void:
	var body := _section(col, "音乐", "MUSIC")
	var bgm_row := _row(body, "背景音乐", "BGM", "菜单与比赛中的赛道主题曲")
	_toggle_row_direct(bgm_row, "bgm_enabled", 110.0)
	_slider_note(body, "关闭背景音乐时保持播放进度，再次打开从原位置继续；音量在左侧 Music 总线调节。")

	var tips := _section(col, "调音提示", "TUNING TIPS")
	var tip_text := UIStyle.label(
		"· 引擎与风噪在高速时会自然变大，建议先调 Music 再调 Engine。\n"
		+ "· 总音量会统一缩放所有分轨，追求安静时优先拉低 Master。\n"
		+ "· 音效 / 界面音量影响碰撞、轮胎和按钮反馈，适度保留更有速度感。",
		12, UIStyle.TXT_DIM)
	tip_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tips.add_child(tip_text)

	var box := PanelContainer.new()
	box.add_theme_stylebox_override("panel", UIStyle.inset_style(accent, 0.6))
	col.add_child(box)
	var mix := VBoxContainer.new()
	box.add_child(mix)
	var title := UIStyle.label("当前混音状态  /  LIVE MIX", 12, Color(accent.r, accent.g, accent.b, 0.9))
	mix.add_child(title)
	var live := UIStyle.label("", 12, UIStyle.TXT_SUB)
	live.name = "LiveMix"
	mix.add_child(live)
	live.set_meta("live_mix", true)

	var out_sec := _section(col, "输出设备", "OUTPUT DEVICE")
	var out_panel := PanelContainer.new()
	out_panel.add_theme_stylebox_override("panel", UIStyle.inset_style(accent, 0.5))
	out_sec.add_child(out_panel)
	_output_label = UIStyle.label("", 11, UIStyle.TXT_SUB)
	_output_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_output_label.add_theme_constant_override("line_spacing", 3)
	out_panel.add_child(_output_label)

	var map_sec := _section(col, "总线映射", "BUS ROUTING")
	var map_panel := PanelContainer.new()
	map_panel.add_theme_stylebox_override("panel", UIStyle.inset_style(accent, 0.45))
	map_sec.add_child(map_panel)
	var map_text := UIStyle.label(
		"Master   →   全部声音总增益\n"
		+ "Music    →   菜单 / 赛道 BGM\n"
		+ "Engine   →   发动机、排气、涡轮\n"
		+ "Wind     →   高速风噪与环境风声\n"
		+ "SFX      →   轮胎、碰撞、尾流\n"
		+ "UI       →   按钮、提示、结算音效", 11, UIStyle.TXT_DIM)
	map_text.add_theme_constant_override("line_spacing", 3)
	map_panel.add_child(map_text)

	var design_sec := _section(col, "声音设计", "SOUND DESIGN")
	var design_text := UIStyle.label(
		"· 分轨为线性百分比，内部换算 dB；Master 0% 时整体静音。\n"
		+ "· 关闭 BGM 保持播放进度，再次开启从原位置继续。\n"
		+ "· 引擎与风噪随速度提升，音效触发在碰撞 / 打滑瞬间。",
		11, UIStyle.TXT_DIM)
	design_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	design_sec.add_child(design_text)


# ---------------------------------------------------------------------------
# 操作页
# ---------------------------------------------------------------------------

func _build_controls_page(page: Control) -> void:
	var left := _column(page, 24, 96, 720, 620)
	var right := _column(page, 776, 96, 540, 620)

	var body := _section(left, "驾驶输入", "DRIVING INPUT")
	var controls := [
		["W / ↑", "油门", "THROTTLE"],
		["S / ↓", "刹车 / 倒车", "BRAKE / REVERSE"],
		["A / D  ·  ← / →", "转向", "STEER"],
		["SPACE", "手刹 / 漂移", "HANDBRAKE"],
		["SHIFT", "氮气", "NITRO"],
		["Q / E", "降挡 / 升挡", "SHIFT DOWN / UP"],
		["T", "手动 / 自动挡切换", "GEARBOX MODE"],
		["R", "复位到赛道", "RESET CAR"],
		["C", "切换相机", "CAMERA"],
	]
	for entry in controls:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 14)
		row.custom_minimum_size = Vector2(0, 36)
		var key := UIStyle.label(String(entry[0]), 13, UIStyle.TXT)
		key.custom_minimum_size = Vector2(190, 0)
		row.add_child(key)
		var action := UIStyle.label(String(entry[1]), 15, UIStyle.TXT_SUB)
		action.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(action)
		var en := UIStyle.label(String(entry[2]), 11, UIStyle.TXT_FAINT)
		row.add_child(en)
		body.add_child(row)
		var hair := ColorRect.new()
		hair.color = Color(1, 1, 1, 0.045)
		hair.custom_minimum_size = Vector2(0, 1)
		body.add_child(hair)

	var sys := _section(left, "系统快捷键", "SYSTEM")
	var sys_rows := [["ESC", "暂停 / 继续"], ["M", "返回主菜单"], ["F2", "比赛中打开设置"], ["TAB", "在设置分页间切换"]]
	for entry in sys_rows:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 14)
		var key := UIStyle.label(String(entry[0]), 13, UIStyle.TXT)
		key.custom_minimum_size = Vector2(190, 0)
		row.add_child(key)
		var action := UIStyle.label(String(entry[1]), 14, UIStyle.TXT_DIM)
		row.add_child(action)
		left.add_child(row)

	var tune := _section(right, "手感", "FEEL")
	_slider_row(tune, "转向灵敏度", "STEER SENSITIVITY", "steer_sensitivity", 0.5, 1.5, 0.05, "%.2fx", 100.0)
	_slider_note(tune, "1.00x 为默认；调低更稳、调高更灵敏。")
	var shake_row := _row(tune, "相机震动", "CAMERA SHAKE", "碰撞与路面颠簸的镜头反馈")
	_toggle_row_direct(shake_row, "camera_shake", 110.0)
	var haptic_row := _row(tune, "手柄震动", "HAPTICS", "起步 / 加速 / 刹车深度 / 漂移 分档反馈")
	_toggle_row_direct(haptic_row, "haptics_enabled", 110.0)
	_slider_row(tune, "震动强度", "HAPTIC INTENSITY", "haptics_intensity", 0.6, 2.0, 0.05, "%.2fx", 100.0)
	_slider_note(tune, "静止与匀速巡航不震；油门越深、刹车越重、漂移越猛，震感越强（6 档）。")

	# ---- 模拟输入（磁轴键盘 / UDP 桥接）----------------------------------
	var analog := _section(right, "模拟输入", "ANALOG INPUT")
	var enable_row := _row(analog, "启用模拟输入", "ENABLE", "磁轴键盘 / 桥接设备（无设备时自动回退键盘或手柄）")
	_toggle_row_direct(enable_row, "analog_input_enabled", 100.0)
	_slider_row(analog, "UDP 端口", "UDP PORT", "analog_udp_port", 1024, 65535, 1, "%d", 100.0)
	_slider_row(analog, "转向死区", "STEER DEADZONE", "analog_deadzone", 0.0, 0.6, 0.01, "%.2f", 100.0)
	_slider_row(analog, "转向曲线", "STEER CURVE", "analog_curve_steer", 0.6, 3.0, 0.05, "%.2fx", 100.0)
	_slider_row(analog, "油门曲线", "THROTTLE CURVE", "analog_curve_throttle", 0.6, 3.0, 0.05, "%.2fx", 100.0)
	var analog_note := UIStyle.label(
		"磁轴键盘经厂商软件桥接（tools/analog_input/README.md），按下深度映射转向角与油门开度。",
		10, UIStyle.TXT_FAINT)
	analog_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	analog.add_child(analog_note)
	_analog_status = UIStyle.label("", 10, UIStyle.GREEN)
	_analog_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	analog.add_child(_analog_status)

	var pad_sec := _section(right, "手柄", "GAMEPAD")
	var pad_grid := GridContainer.new()
	pad_grid.columns = 2
	pad_grid.add_theme_constant_override("h_separation", 14)
	pad_grid.add_theme_constant_override("v_separation", 3)
	pad_sec.add_child(pad_grid)
	var pad_rows := [
		["左摇杆", "转向 · 菜单选择"],
		["RT / LT", "油门 / 刹车·倒车"],
		["Ⓐ", "漂移 / 手刹 · 确认"],
		["Ⓧ", "氮气"],
		["LB / RB", "降挡 / 升挡"],
		["Ⓨ", "手动 / 自动挡"],
		["Ⓑ", "切换相机"],
		["START", "暂停 / 返回"],
	]
	for entry in pad_rows:
		var cell := HBoxContainer.new()
		cell.add_theme_constant_override("separation", 8)
		var key := UIStyle.label(String(entry[0]), 11, UIStyle.TXT)
		key.custom_minimum_size = Vector2(74, 0)
		cell.add_child(key)
		cell.add_child(UIStyle.label(String(entry[1]), 11, UIStyle.TXT_DIM))
		pad_grid.add_child(cell)
	var pad_note := UIStyle.label("菜单内 A 确认、START 返回；十字键不绑定功能。驾驶振动在上方 FEEL 分区调节。", 10, UIStyle.TXT_FAINT)
	pad_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	pad_sec.add_child(pad_note)

	var drive_sec := _section(left, "驾驶提示", "DRIVING NOTES")
	var drive_text := UIStyle.label(
		"· 手刹会瞬间降低后轮抓地，制造转向过度；氮气在直道末端收益最大。\n"
		+ "· 高速转向会变重，入弯前先刹车；冲出赛道会显著降低抓地。", 11, UIStyle.TXT_DIM)
	drive_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	drive_sec.add_child(drive_text)


# ---------------------------------------------------------------------------
# 游戏页
# ---------------------------------------------------------------------------

func _build_game_page(page: Control) -> void:
	var left := _column(page, 24, 96, 720, 620)
	var right := _column(page, 776, 96, 540, 620)

	var hud := _section(left, "比赛 HUD", "RACE HUD")
	var hud_grid := GridContainer.new()
	hud_grid.columns = 2
	hud_grid.add_theme_constant_override("h_separation", 8)
	hud_grid.add_theme_constant_override("v_separation", 4)
	hud.add_child(hud_grid)
	var rows := [
		["小地图", "MINIMAP", "hud_minimap", "赛道轮廓与对手位置"],
		["转速表", "TACHOMETER", "hud_tach", "右下角环形转速表"],
		["速度表", "SPEEDOMETER", "hud_speed", "大号速度与档位"],
		["操作提示", "CONTROL HINTS", "hud_hints", "底部按键提示行"],
		["帧率显示", "FPS COUNTER", "show_fps", "左上角实时帧率"],
	]
	for entry in rows:
		_add_toggle_cell(hud_grid, "%s  %s" % [String(entry[0]), String(entry[1])],
			String(entry[2]), String(entry[3]))

	var units_row := _row(left, "速度单位", "SPEED UNIT", "HUD 速度数字的单位")
	_chip_row(units_row, "hud_units", Settings.HUD_UNITS, 92.0)

	var race := _section(left, "比赛", "RACE")
	var laps_row := _row(race, "圈数覆盖", "LAP OVERRIDE", "0 = 使用赛道默认圈数")
	var lap_options: Array[Dictionary] = [
		{"value": 0, "name": "默认", "en": "TRACK"},
		{"value": 3, "name": "3 圈", "en": "3 LAPS"},
		{"value": 5, "name": "5 圈", "en": "5 LAPS"},
		{"value": 8, "name": "8 圈", "en": "8 LAPS"},
	]
	_chip_row(laps_row, "laps_override", lap_options, 68.0)
	var lap_hint := UIStyle.label("圈数覆盖在下一场比赛生效（main.gd 读取 Settings.laps_override）。",
		11, UIStyle.TXT_FAINT)
	lap_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	left.add_child(lap_hint)

	var save_sec := _section(left, "存档数据", "SAVE DATA")
	var save_panel := PanelContainer.new()
	save_panel.add_theme_stylebox_override("panel", UIStyle.inset_style(accent, 0.5))
	save_sec.add_child(save_panel)
	_save_label = UIStyle.label("", 11, UIStyle.TXT_SUB)
	_save_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_save_label.add_theme_constant_override("line_spacing", 3)
	save_panel.add_child(_save_label)

	var info := _section(right, "平台信息", "PLATFORM")
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UIStyle.inset_style(accent, 0.58))
	right.add_child(panel)
	_platform_label = UIStyle.label("", 12, UIStyle.TXT_SUB)
	_platform_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_platform_label.add_theme_constant_override("line_spacing", 5)
	panel.add_child(_platform_label)

	var about := _section(right, "关于", "ABOUT")
	var about_text := UIStyle.label(
		"APEX VELOCITY · 极速巅峰  —  Godot 4 重制版\n"
		+ "46 台赛车 · 8 条真实赛道 · 大奖赛 / 计时赛\n"
		+ "设置保存在 user://settings.json，可随时恢复默认。",
		12, UIStyle.TXT_DIM)
	about_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	about.add_child(about_text)

	var reset_panel := PanelContainer.new()
	reset_panel.add_theme_stylebox_override("panel", UIStyle.inset_style(UIStyle.GOLD, 0.55))
	right.add_child(reset_panel)
	var reset_box := VBoxContainer.new()
	reset_panel.add_child(reset_box)
	reset_box.add_child(UIStyle.label("恢复默认设置", 14, UIStyle.GOLD))
	var reset_text := UIStyle.label("画质、显示、音频、操作与 HUD 全部回到平台推荐值。", 11, UIStyle.TXT_DIM)
	reset_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	reset_box.add_child(reset_text)
	var reset_btn := UIStyle.make_button("↺   重置全部  RESET ALL", UIStyle.GOLD, "ghost", 13, 34.0)
	reset_btn.pressed.connect(_on_reset_pressed)
	reset_box.add_child(reset_btn)


# ---------------------------------------------------------------------------
# 通用行控件
# ---------------------------------------------------------------------------

func _row(parent: Control, cn: String, en: String, desc: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.custom_minimum_size = Vector2(0, 36)
	parent.add_child(row)
	var text := VBoxContainer.new()
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.add_theme_constant_override("separation", 0)
	row.add_child(text)
	var title := UIStyle.label_display("%s   %s" % [cn, en], 13, UIStyle.TXT,
		HORIZONTAL_ALIGNMENT_LEFT, 1)
	text.add_child(title)
	if not desc.is_empty():
		var sub := UIStyle.label(desc, 9, UIStyle.TXT_FAINT)
		sub.autowrap_mode = TextServer.AUTOWRAP_OFF
		text.add_child(sub)
	return row


func _toggle_row(parent: Control, cn: String, en: String, key: String, desc: String,
		width: float = 110.0) -> UIToggle:
	var row := _row(parent, cn, en, desc)
	var toggle := UIToggle.new()
	toggle.size_flags_horizontal = Control.SIZE_SHRINK_END
	toggle.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	toggle.custom_minimum_size = Vector2(width, 32)
	toggle.accent = accent
	toggle.toggled.connect(func(on: bool) -> void: _on_toggle_changed(key, on))
	row.add_child(toggle)
	_toggles[key] = toggle
	return toggle


func _toggle_row_direct(row: HBoxContainer, key: String, width: float = 110.0) -> UIToggle:
	var toggle := UIToggle.new()
	toggle.size_flags_horizontal = Control.SIZE_SHRINK_END
	toggle.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	toggle.custom_minimum_size = Vector2(width, 32)
	toggle.accent = accent
	toggle.toggled.connect(func(on: bool) -> void: _on_toggle_changed(key, on))
	row.add_child(toggle)
	_toggles[key] = toggle
	return toggle


func _add_toggle_cell(grid: GridContainer, cn: String, key: String, desc: String) -> void:
	var cell := PanelContainer.new()
	cell.add_theme_stylebox_override("panel", UIStyle.inset_style(accent, 0.42))
	cell.custom_minimum_size = Vector2(0, 38)
	grid.add_child(cell)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	cell.add_child(row)
	var text := VBoxContainer.new()
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.add_theme_constant_override("separation", 0)
	row.add_child(text)
	text.add_child(UIStyle.label(cn, 12, UIStyle.TXT_SUB))
	text.add_child(UIStyle.label(desc, 9, UIStyle.TXT_FAINT))
	var toggle := UIToggle.new()
	toggle.custom_minimum_size = Vector2(58, 28)
	toggle.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	toggle.accent = accent
	toggle.toggled.connect(func(on: bool) -> void: _on_toggle_changed(key, on))
	row.add_child(toggle)
	_toggles[key] = toggle


func _slider_row(parent: Control, cn: String, en: String, key: String,
		min_v: float, max_v: float, step: float, fmt: String, width: float = 100.0) -> HSlider:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.custom_minimum_size = Vector2(0, 36)
	parent.add_child(row)
	var title := UIStyle.label("%s   %s" % [cn, en], 12, UIStyle.TXT_SUB)
	title.custom_minimum_size = Vector2(236, 0)
	row.add_child(title)
	var slider := HSlider.new()
	slider.min_value = min_v
	slider.max_value = max_v
	slider.step = step
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	UIStyle.style_slider(slider, accent)
	slider.value_changed.connect(_on_slider_changed.bind(key))
	row.add_child(slider)
	_sliders[key] = slider
	var value := UIStyle.label("", 13, Color(accent.r, accent.g, accent.b, 1.0), HORIZONTAL_ALIGNMENT_RIGHT)
	value.custom_minimum_size = Vector2(width * 0.5, 0)
	row.add_child(value)
	_value_labels[key] = value
	_value_labels[key + "__fmt"] = fmt
	return slider


func _slider_note(parent: Control, text: String) -> void:
	var note := UIStyle.label(text, 10, UIStyle.TXT_FAINT)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(note)


func _chip_row(parent: Control, key: String, options: Array, chip_width: float = 0.0) -> Array[Button]:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.size_flags_horizontal = Control.SIZE_SHRINK_END
	row.alignment = BoxContainer.ALIGNMENT_END
	parent.add_child(row)
	var buttons: Array[Button] = []
	for i in options.size():
		var opt: Dictionary = options[i]
		var text := String(opt.get("name", ""))
		if opt.has("en") and chip_width > 0.0:
			text = String(opt.get("name", ""))
		var btn := Button.new()
		btn.text = text
		btn.toggle_mode = true
		btn.custom_minimum_size = Vector2(chip_width, 34)
		btn.add_theme_font_size_override("font_size", 12)
		btn.add_theme_color_override("font_color", UIStyle.TXT_DIM)
		btn.add_theme_color_override("font_hover_color", UIStyle.TXT)
		btn.add_theme_color_override("font_pressed_color", Color(0.02, 0.07, 0.08))
		btn.add_theme_color_override("font_hover_pressed_color", Color(0.02, 0.07, 0.08))
		btn.add_theme_color_override("font_focus_color", UIStyle.TXT)
		for state in ["normal", "hover", "pressed", "focus", "hover_pressed"]:
			var active: bool = state in ["pressed", "hover_pressed"]
			var hover: bool = state in ["hover", "focus"]
			btn.add_theme_stylebox_override(state, UIStyle.chip_style(accent, active, hover))
		btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		btn.set_meta("option_value", opt.get("value", opt.get("id", i)))
		var value: Variant = opt.get("value", opt.get("id", i))
		btn.pressed.connect(func() -> void: _on_chip_pressed(key, value))
		row.add_child(btn)
		buttons.append(btn)
	_chips[key] = buttons
	return buttons


func _upscale_options() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for i in Settings.UPSCALE_IDS.size():
		out.append({"value": Settings.UPSCALE_IDS[i], "name": Settings.UPSCALE_NAMES[i]})
	return out


# ---------------------------------------------------------------------------
# 交互
# ---------------------------------------------------------------------------

func _on_settings_changed() -> void:
	if visible and not _syncing:
		_sync_all()


func _select_tab(i: int) -> void:
	var target := clampi(i, 0, TABS.size() - 1)
	if target == selected_tab and _opened_once:
		return
	selected_tab = target
	_apply_tab_visibility(true)


func _apply_tab_visibility(animate: bool) -> void:
	for i in _tab_buttons.size():
		_tab_buttons[i].button_pressed = (i == selected_tab)
	for i in _pages.size():
		var page := _pages[i]
		var show := i == selected_tab
		if show and not page.visible:
			page.visible = true
			page.modulate.a = 0.0
			if animate:
				var tw := page.create_tween()
				tw.tween_property(page, "modulate:a", 1.0, 0.18)
			else:
				page.modulate.a = 1.0
		elif not show:
			page.visible = false
		elif show:
			page.modulate.a = 1.0


func _select_quality(i: int) -> void:
	Settings.set_quality(i)
	_sync_all()


func _on_resolution_selected(index: int) -> void:
	if _syncing:
		return
	Settings.set_resolution(index)
	_sync_all()


func _on_toggle_changed(key: String, on: bool) -> void:
	if _syncing:
		return
	Settings.set_value(key, on)
	_sync_all()
	_refresh_audio_live()


func _on_slider_changed(value: float, key: String) -> void:
	if _syncing:
		return
	Settings.set_value(key, value)
	_update_value_label(key, value)
	_refresh_audio_live()


func _on_chip_pressed(key: String, value: Variant) -> void:
	if _syncing:
		return
	Settings.set_value(key, value)
	_sync_all()


func _on_reset_pressed() -> void:
	Settings.reset_defaults()
	_sync_all()
	UIStyle.flash(_pages[selected_tab], UIStyle.GOLD, 0.25, 0.5)


func _update_value_label(key: String, value: float) -> void:
	if not _value_labels.has(key):
		return
	var fmt := "%d%%"
	if _value_labels.has(key + "__fmt"):
		fmt = String(_value_labels[key + "__fmt"])
	var label := _value_labels[key] as Label
	if label == null:
		return
	if key == "analog_udp_port":
		label.text = str(int(round(value)))
	elif fmt.ends_with("%%"):
		label.text = fmt % int(round(value * 100.0))
	elif fmt.contains(".2f"):
		label.text = fmt % value
	else:
		label.text = fmt % value


func _refresh_audio_live() -> void:
	# 音频页的实时状态面板
	for node in _root.find_children("*", "Label", true, false):
		if node.has_meta("live_mix"):
			var bus_count := 0
			for entry in Settings.AUDIO_BUSES:
				if Settings.audio_bus_available(String(entry["bus"])):
					bus_count += 1
			(node as Label).text = "%s  ·  总音量 %d%%  ·  总线 %d/%d%s" % [
				"播放中 PLAYING" if (Settings.music_volume > 0.01 and Settings.bgm_enabled) else "静音 MUTED",
				int(round(Settings.master_volume * 100.0)),
				bus_count, Settings.AUDIO_BUSES.size(),
				"" if bus_count >= Settings.AUDIO_BUSES.size() else "  ·  其余总线待音频层创建"]
			break
	if _output_label != null:
		var device := AudioServer.get_output_device()
		if device.is_empty():
			device = "系统默认输出"
		var devices := AudioServer.get_output_device_list()
		_output_label.text = "输出设备   %s\n采样率     %d Hz      ·      设备数 %d\n混音总线   由 Settings 直接写入 AudioServer" % [
			device, int(AudioServer.get_mix_rate()), devices.size()]


# ---------------------------------------------------------------------------
# 同步
# ---------------------------------------------------------------------------

func _sync_all() -> void:
	_syncing = true
	_apply_tab_visibility(false)
	for i in _quality_buttons.size():
		_quality_buttons[i].button_pressed = (i == Settings.index)
	for i in _quality_detail_labels.size():
		var preset: Dictionary = Settings.PRESETS[i]
		_quality_detail_labels[i].text = "渲染 %d%%  ·  MSAA %s  ·  %s" % [
			int(float(preset["scale"]) * 100.0),
			"关" if int(preset["msaa"]) == 0 else "%dx" % int(preset["msaa"]),
			"SSR+SSAO" if bool(preset["ssr"]) and bool(preset["ssao"]) else "基础"]
	if _resolution_opt != null:
		_resolution_opt.select(Settings.resolution_index())
	_sync_chips("window_mode", Settings.window_mode)
	_sync_chips("fps_limit", Settings.fps_limit)
	_sync_chips("msaa", Settings.msaa)
	_sync_chips("upscale", Settings.upscale)
	_sync_chips("hud_units", Settings.hud_units)
	_sync_chips("laps_override", Settings.laps_override)
	for key in _toggles.keys():
		(_toggles[key] as UIToggle).set_on(_toggle_value(String(key)), false)
	for key in _sliders.keys():
		var slider := _sliders[key] as HSlider
		var value := _slider_value(String(key))
		slider.value = value
		_update_value_label(String(key), value)
	_refresh_budget()
	_summary_label.text = "当前画质  %s      ·      %s      ·      %s" % [
		Settings.detail_name(), Settings.resolution_label(), Settings.fps_text()]
	_refresh_platform()
	_refresh_audio_live()
	_refresh_rail_platform(_rail_platform)
	_refresh_analog_status()
	_syncing = false


func _refresh_budget() -> void:
	if _budget_label == null:
		return
	var q: Dictionary = Settings.preset()
	var filter_names := {0: "硬阴影", 2: "软阴影·低", 3: "软阴影·中", 4: "软阴影·高"}
	var filter_name: String = filter_names.get(Settings.shadow_filter(), "软阴影")
	_budget_label.text = (
		"渲染缩放 %d%%       MSAA %s       TAA %s\n"
		+ "SSR %s       SSAO %s       SSIL %s       体积雾 %s\n"
		+ "升频 %s       锐化 %d%%       远景 %.2fx\n"
		+ "阴影 %.0fm       植被 %.2fx       粒子 %.2fx\n"
		+ "阴影精度 %s       模型细节 %.2fx       有效远景 %.0f m"
	) % [
		int(float(q["scale"]) * 100.0),
		"关" if int(q["msaa"]) == 0 else "%dx" % int(q["msaa"]),
		"开" if bool(q["taa"]) else "关",
		"开" if bool(q["ssr"]) else "关", "开" if bool(q["ssao"]) else "关",
		"开" if bool(q["ssil"]) else "关", "开" if bool(q["vol"]) else "关",
		Settings.upscale, int(round(Settings.sharpen * 100.0)), Settings.far_clarity,
		float(q["shadow_dist"]), float(q["content"]), float(q["particles"]),
		filter_name, Settings.lod_bias(), Settings.far_distance()]


func _sync_chips(key: String, current: Variant) -> void:
	if not _chips.has(key):
		return
	var current_text := str(current)
	for btn in (_chips[key] as Array):
		var value: Variant = (btn as Button).get_meta("option_value", null)
		var match_ := str(value) == current_text
		if key == "fps_limit" or key == "laps_override" or key == "msaa":
			match_ = int(value) == int(current)
		(btn as Button).button_pressed = match_


func _toggle_value(key: String) -> bool:
	match key:
		"vsync_enabled": return Settings.vsync_enabled
		"taa": return Settings.taa
		"ssr": return Settings.ssr
		"ssao": return Settings.ssao
		"ssil": return Settings.ssil
		"volumetric": return Settings.volumetric
		"tree_shadows": return Settings.tree_shadows
		"motion_blur_enabled": return Settings.motion_blur_enabled
		"vignette": return Settings.vignette
		"bgm_enabled": return Settings.bgm_enabled
		"camera_shake": return Settings.camera_shake
		"haptics_enabled": return Settings.haptics_enabled
		"hud_minimap": return Settings.hud_minimap
		"hud_tach": return Settings.hud_tach
		"hud_speed": return Settings.hud_speed
		"hud_hints": return Settings.hud_hints
		"show_fps": return Settings.show_fps
		"analog_input_enabled": return Settings.analog_input_enabled
	return false


func _slider_value(key: String) -> float:
	match key:
		"render_scale": return Settings.render_scale
		"motion_blur": return Settings.motion_blur_amount
		"sharpen": return Settings.sharpen
		"far_clarity": return Settings.far_clarity
		"steer_sensitivity": return Settings.steer_sensitivity
		"haptics_intensity": return Settings.haptics_intensity
		"analog_udp_port": return float(Settings.analog_udp_port)
		"analog_deadzone": return Settings.analog_deadzone
		"analog_curve_steer": return Settings.analog_curve_steer
		"analog_curve_throttle": return Settings.analog_curve_throttle
		"master_volume": return Settings.master_volume
		"music_volume": return Settings.music_volume
		"engine_volume": return Settings.engine_volume
		"wind_volume": return Settings.wind_volume
		"sfx_volume": return Settings.sfx_volume
		"ui_volume": return Settings.ui_volume
	return 0.0


func _refresh_analog_status() -> void:
	if _analog_status == null:
		return
	if not visible:
		return
	_analog_status.text = AnalogInput.status_text(Settings.analog_udp_port)
	_analog_status.add_theme_color_override("font_color",
		UIStyle.GREEN if _analog_status.text.contains("已连接") else UIStyle.TXT_SUB)


func _refresh_platform() -> void:
	if _platform_label == null:
		return
	var info := PlatformProfile.info()
	var stream_text := ""
	if main_ref != null:
		var st: Variant = main_ref.get("streamer")
		if st != null and st is Node:
			stream_text = String((st as Node).call("stats"))
	_platform_label.text = (
		"平台        %s\n"
		+ "图形驱动    %s  ·  渲染方法 %s\n"
		+ "MetalFX     %s      FSR2     %s\n"
		+ "推荐画质    %s\n"
		+ "当前窗口    %s  @  %s\n"
		+ "远景距离    %.0f m\n"
		+ "%s"
	) % [
		PlatformProfile.summary(), String(info["driver"]), String(info["method"]),
		"可用" if bool(info["metalfx"]) else "不可用",
		"可用" if bool(info["fsr2"]) else "不可用",
		String(Settings.PRESETS[int(info["recommended"])]["name"]),
		Settings.resolution_label(), Settings.fps_text(),
		Settings.far_distance(), stream_text]
	if _save_label != null:
		var records: Dictionary = RecordsStore.load_all()
		var tracks_saved: int = (records.get("tracks", {}) as Dictionary).size()
		var upgrade_total := 0
		for car_key in Garage.cars.keys():
			for upgrade_key in Garage.UPGRADE_KEYS:
				upgrade_total += Garage.upgrade_level(String(car_key), String(upgrade_key))
		_save_label.text = (
			"已保存赛道纪录   %d / %d      ·      车库车辆 %d 台\n"
			+ "设置文件   user://settings.json      ·      纪录文件   user://records.json\n"
			+ "当前设置：画质 %s   ·   %s   ·   %s"
		) % [
			tracks_saved, GameData.tracks.size(), GameData.cars_specs.size(),
			Settings.detail_name(), Settings.resolution_label(), Settings.fps_text()]


# ---------------------------------------------------------------------------
# 生命周期
# ---------------------------------------------------------------------------

func open() -> void:
	if visible:
		return
	visible = true
	_sync_all()
	_apply_tab_visibility(false)
	# 调试：--settings-tab=audio|controls|game 可直达指定分页
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--settings-tab="):
			var wanted := arg.substr(15)
			for i in TABS.size():
				if String(TABS[i]["en"]).to_lower() == wanted or String(TABS[i]["cn"]) == wanted:
					selected_tab = i
					break
			_apply_tab_visibility(false)
	_opened_once = true
	_closing = false
	if not _tab_buttons.is_empty():
		_tab_buttons[selected_tab].grab_focus.call_deferred()
	_root.modulate.a = 0.0
	var tw := create_tween()
	tw.tween_property(_root, "modulate:a", 1.0, 0.16)
	for i in _tab_buttons.size():
		var btn := _tab_buttons[i]
		btn.modulate.a = 0.0
		btn.create_tween().tween_property(btn, "modulate:a", 1.0, 0.22).set_delay(0.03 * i)
	if _pages[selected_tab] != null:
		_pages[selected_tab].modulate.a = 0.0
		_pages[selected_tab].create_tween().tween_property(
			_pages[selected_tab], "modulate:a", 1.0, 0.24).set_delay(0.06)


func _panel_opacity_in() -> void:
	if _backdrop != null:
		_backdrop.modulate.a = 1.0


func close() -> void:
	if not visible or _closing:
		return
	_closing = true
	var tw := create_tween()
	tw.tween_property(_root, "modulate:a", 0.0, 0.13)
	await tw.finished
	visible = false
	_closing = false
	_root.modulate.a = 1.0
	closed.emit()


func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()
		return
	# 手柄 LB / RB 切换分页（键鼠仍用 TAB / ← →）
	if event is InputEventJoypadButton and event.pressed:
		var jb := event as InputEventJoypadButton
		if jb.button_index == JOY_BUTTON_LEFT_SHOULDER:
			_select_tab(posmod(selected_tab - 1, TABS.size()))
			get_viewport().set_input_as_handled()
			return
		if jb.button_index == JOY_BUTTON_RIGHT_SHOULDER:
			_select_tab(posmod(selected_tab + 1, TABS.size()))
			get_viewport().set_input_as_handled()
			return
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var key := (event as InputEventKey).keycode
	match key:
		KEY_S, KEY_ESCAPE, KEY_F2:
			close()
		KEY_TAB:
			_select_tab((selected_tab + 1) % TABS.size())
		KEY_LEFT, KEY_RIGHT:
			var focus := get_viewport().gui_get_focus_owner()
			if focus == null or not (focus is HSlider):
				_select_tab(posmod(selected_tab + (1 if key == KEY_RIGHT else -1), TABS.size()))
				get_viewport().set_input_as_handled()
			else:
				return
		_:
			return
	get_viewport().set_input_as_handled()
