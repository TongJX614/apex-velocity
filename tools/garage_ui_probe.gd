extends Node3D
## 车库改版验收探针（窗口化运行）：
##   Godot --path . res://tools/garage_ui_probe.tscn
## 验证：7 项改装 4+3 两行布局 / 文字不截断 / 同车换件保留拖拽朝向与机位 /
## 换车重置视角 / 车漆色板可用。输出截图到 /tmp/garage_after_*.png。

var world: GarageWorld
var screen: GarageScreen
var failures: Array[String] = []
var car_id := "bmw_m3_e46_gtr"


func _ready() -> void:
	await get_tree().process_frame
	world = GarageWorld.new()
	add_child(world)
	screen = GarageScreen.new()
	screen.world = world
	screen.initial_car = car_id
	add_child(screen)
	await get_tree().process_frame
	await get_tree().create_timer(0.7).timeout

	_check_layout()
	_check_paint_ui()
	await _shot("/tmp/garage_after_default.png")

	# 用户把车尾拖向镜头后换尾翼：朝向与机位都必须保持
	var yaw := -2.2
	world.holder.rotation.y = yaw
	var cam_tf := world._camera.global_transform
	screen._select_category(3)   # 尾翼
	Garage.cycle_option(car_id, "wing", 1)
	world.show_car(car_id)
	await get_tree().process_frame
	_check(absf(world.holder.rotation.y - yaw) < 0.0001,
		"wing swap keeps dragged yaw (got %.4f want %.4f)" % [world.holder.rotation.y, yaw])
	_check(world._camera.global_transform.origin.distance_to(cam_tf.origin) < 0.0001,
		"wing swap keeps camera position")
	await get_tree().create_timer(0.3).timeout
	await _shot("/tmp/garage_after_wing_rotated.png")

	# 轮毂 / 车漆同样保持
	Garage.cycle_option(car_id, "wheel", 1)
	world.show_car(car_id)
	_check(absf(world.holder.rotation.y - yaw) < 0.0001, "wheel swap keeps dragged yaw")
	Garage.set_option(car_id, "paint", 2)
	world.show_car(car_id)
	_check(absf(world.holder.rotation.y - yaw) < 0.0001, "paint swap keeps dragged yaw")

	# 换另一台车：回到默认朝向并重新取景
	world.show_car("bmw_i8")
	await get_tree().process_frame
	_check(absf(world.holder.rotation.y) < 0.0001, "switching car resets yaw")
	_check(world._camera.global_transform.origin.distance_to(cam_tf.origin) > 0.01,
		"switching car reframes camera")

	# 回到原车验证色板交互
	world.show_car(car_id)
	screen._select_category(5)
	screen._select_paint(1)
	_check(Garage.get_option(car_id, "paint") == 1, "paint chip click applies paint")
	await get_tree().create_timer(0.3).timeout
	await _shot("/tmp/garage_after_paint.png")

	print("[PROBE] %s (%d checks failed)" % ["PASS" if failures.is_empty() else "FAIL", failures.size()])
	for f in failures:
		print("[PROBE][FAIL] " + f)
	get_tree().quit(0 if failures.is_empty() else 1)


func _check(ok: bool, msg: String) -> void:
	if ok:
		print("[PROBE][OK] " + msg)
	else:
		failures.append(msg)


func _check_layout() -> void:
	var segs := screen._tuning_segs
	_check(segs.size() == 7, "7 tuning segments")
	if segs.size() != 7:
		return
	var card_rect := screen._tuning_card.get_global_rect()
	for i in segs.size():
		var r := segs[i].get_global_rect()
		_check(r.size.x >= 120.0 and r.size.x <= 140.0,
			"seg %d width %.1f in [120,140]" % [i, r.size.x])
		_check(r.size.y >= 34.0, "seg %d height %.1f >= 34" % [i, r.size.y])
		_check(card_rect.encloses(r), "seg %d inside tuning card" % i)
		var row := i / 4
		var col := i % 4
		var expect_y := card_rect.position.y + 24.0 + row * 40.0
		_check(absf(r.position.y - expect_y) < 0.5, "seg %d row %d y %.1f" % [i, row, r.position.y])
		if col > 0:
			var prev := segs[i - 1].get_global_rect()
			_check(r.position.x >= prev.end.x + 3.0, "seg %d no overlap with left neighbor" % i)
		# 标题 / 数值文本宽度必须放得下（不被截断）
		var title := screen._tuning_titles[i]
		var value := screen._tuning_values[i]
		for lbl in [title, value]:
			var font: Font = lbl.get_theme_font("font")
			var fs: int = lbl.get_theme_font_size("font_size")
			var tw := font.get_string_size(lbl.text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
			_check(tw <= r.size.x - 4.0,
				"seg %d text '%s' width %.1f fits %.1f" % [i, lbl.text, tw, r.size.x - 4.0])
	# 改装卡与下方性能卡不重叠
	var perf := screen._perf_card.get_global_rect()
	_check(card_rect.end.y + 4.0 <= perf.position.y, "tuning card clears perf card")
	# 选车网格仍可见 4 行
	var grid := screen._grid_scroll.get_global_rect()
	_check(grid.size.y >= 288.0, "grid viewport %.1f keeps 4 rows" % grid.size.y)


func _check_paint_ui() -> void:
	screen._select_category(5)
	_check(screen._paint_row.visible, "paint row visible in paint category")
	var palette := GameData.palette_for(car_id)
	var visible_chips := 0
	for c in screen._paint_chips:
		if c.visible:
			visible_chips += 1
	_check(visible_chips == mini(palette.size(), 8),
		"paint chips %d == palette %d" % [visible_chips, palette.size()])
	var row_rect := screen._paint_row.get_global_rect()
	var card_rect := screen._tuning_card.get_global_rect()
	_check(card_rect.encloses(row_rect), "paint row inside tuning card")
	screen._select_category(0)
	_check(not screen._paint_row.visible, "paint row hidden outside paint category")


func _shot(path: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var err := img.save_png(path)
	print("[PROBE] shot %s err=%d %dx%d" % [path, err, img.get_width(), img.get_height()])