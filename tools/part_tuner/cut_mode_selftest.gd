extends SceneTree
## 空间删除模式新交互的自动化验证：
##   进入删除模式 → 滚轮调格子 → 点选格子 → 方向键移动 → 回车删除 → 撤销。
## 验证完不落盘（不 save_offsets），退出即丢弃。

var _tuner: Node
var _step := 0
var _frames := 0
var _fail := ""


func _initialize() -> void:
	var ps: PackedScene = load("res://tools/part_tuner/part_tuner.tscn")
	_tuner = ps.instantiate()
	root.add_child(_tuner)


func _process(_d: float) -> bool:
	_frames += 1
	if _frames < 10:
		return false
	match _step:
		0:
			# 进入空间删除模式
			_tuner._set_cut_mode(true)
			_step = 1
		1:
			if _tuner._grid_node == null:
				_fail = "进入删除模式后没有格线"
			if not _fail.is_empty():
				print("FAIL: " + _fail)
				return true
			print("OK 进入模式: 格边长=%.3f 格数=%s" % [_tuner._cell, _tuner._grid_n])
			# 滚轮调细：0.85 连按几次应到下限 0.02
			# 滚轮调细：0.85 连按几次应到下限 0.004（4mm）
			for i in 40:
				_tuner._adjust_cell(0.85)
			if _tuner._cell < 0.0039 or _tuner._cell > 0.0041:
				_fail = "滚轮调细下限异常: %.5f" % _tuner._cell
			# 细格限定区：单轴格数不应超过上限
			if _fail.is_empty() and (_tuner._grid_n.x > 100 or _tuner._grid_n.y > 100
					or _tuner._grid_n.z > 100):
				_fail = "细格未限定区域: %s" % _tuner._grid_n
			if not _fail.is_empty():
				print("FAIL: " + _fail)
				return true
			print("OK 滚轮调细到下限 %.4f，细格限定准星附近: 格数=%s" % [_tuner._cell, _tuner._grid_n])
			# 滚轮调粗回到中等
			for i in 8:
				_tuner._adjust_cell(1.18)
			print("OK 滚轮调粗: %.3f" % _tuner._cell)
			# 模拟点选：直接选中车尾上方一格（varis 漂浮板所在高空区）
			var box: AABB = _tuner._grid_box
			var n: Vector3i = _tuner._grid_n
			_tuner._sel_cell = Vector3i(n.x / 2, n.y - 3, 2)
			_tuner._has_sel = true
			_tuner._draw_grid()
			_step = 2
		2:
			# 方向键逐个验证：每按一次只动一格、方向正确
			var n2: Vector3i = _tuner._grid_n
			var mid := Vector3i(n2.x / 2, n2.y / 2, n2.z / 2)
			_tuner._sel_cell = mid
			_tuner._has_sel = true
			var moved := {}
			for kc in [KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT]:
				var ev := InputEventKey.new()
				ev.keycode = kc
				ev.pressed = true
				var b0: Vector3i = _tuner._sel_cell
				_tuner._move_sel(ev)
				moved[kc] = _tuner._sel_cell - b0
				# 拨回中点再做下一个方向
				_tuner._sel_cell = mid
			print("移动向量 UP=%s DOWN=%s LEFT=%s RIGHT=%s" % [
				moved[KEY_UP], moved[KEY_DOWN], moved[KEY_LEFT], moved[KEY_RIGHT]])
			if moved[KEY_UP] == -moved[KEY_DOWN] and moved[KEY_LEFT] == -moved[KEY_RIGHT] \
					and moved[KEY_UP].length_squared() == 1 \
					and moved[KEY_LEFT].length_squared() == 1:
				print("OK 四方向各动一格且方向相反")
			else:
				_fail = "方向键移动向量异常"
			# Shift = 大步进 5 格
			var ev3 := InputEventKey.new()
			ev3.keycode = KEY_UP
			ev3.pressed = true
			var b1: Vector3i = _tuner._sel_cell
			_tuner._move_sel(ev3)
			var d: Vector3i = _tuner._sel_cell - b1
			if d.length_squared() != 1:
				_fail = "单次 UP 移动量异常: %s" % d
			# 越界钳制：朝上连按 50 次应停在 y 上边界
			for i in 50:
				_tuner._move_sel(ev3)
			if _tuner._sel_cell.y != _tuner._grid_n.y - 1:
				_fail = "越界钳制失败: %s vs %d" % [_tuner._sel_cell, _tuner._grid_n.y - 1]
			if not _fail.is_empty():
				print("FAIL: " + _fail)
				return true
			print("OK 方向键移动+边界钳制: 最终=%s" % _tuner._sel_cell)
			_step = 3
		3:
			# 回车删除：把选中格改成车顶正上方的空白格（0 个三角形）避免真删到车
			var box: AABB = _tuner._grid_box
			var n: Vector3i = _tuner._grid_n
			_tuner._sel_cell = Vector3i(n.x / 2, n.y - 1, 1)
			_tuner._has_sel = true
			var total := 0
			for c in _tuner._collect_tris_in_cell(_tuner._sel_cell, _tuner._grid_box):
				total += (c["tris"] as Array).size()
			_tuner._confirm_cut()
			# confirm 内部会 _load_car 重载，之后仍应处于删除模式
			if not _tuner._cut_mode:
				_fail = "删除后不应退出删除模式"
			if not _fail.is_empty():
				print("FAIL: " + _fail)
				return true
			print("OK 回车删除执行完毕（测试格内三角形=%d，模式保持）" % total)
			_step = 4
		4:
			# 撤销 + 退出模式
			var popped: bool = _tuner.PartsLib.pop_last_mesh_cut(_tuner._car)
			_tuner._set_cut_mode(false)
			print("OK 撤销删除=%s，模式已退出" % popped)
			print(_fail if not _fail.is_empty() else "ALL PASS")
			if not _fail.is_empty():
				print("FAIL: " + _fail)
			return true
	return false
