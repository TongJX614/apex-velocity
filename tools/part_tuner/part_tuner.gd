extends Node
## 配件人工微调工具（part_tuner）：
##   让人眼当裁判 —— 点选部件 → 方向键微调 → 实时看到效果 → 保存。
##   · 左键点选：点任意一条轮胎 = 选中四条；点尾翼 = 选中翼组；
##   · 右键拖动旋转视角，滚轮缩放；
##   · ↑/↓ 调高低，←/→ 调前后（Shift = 大步进 5cm，默认 1cm）；
##   · Enter 保存到 res://data/part_offsets.json（游戏挂装时自动生效）；
##   · 「测量面标记」= 原 wing_check --debug-geo 的红板(行李箱面)+绿框(翼组)。
## 用法：
##   Godot --path . res://tools/part_tuner/part_tuner.tscn
## 偏移生效机制：PartsLibrary.build_wing / GarageLook 供体轮挂载时叠加
##   part_offsets.json 里对应 car_id 的 {wing:{dy,dz}, wheels:{dy,dz}}。

const PartsLib := preload("res://scripts/cars/parts_library.gd")

var _cars: Array = []            # 所有车 id（GameData 顺序）
var _car_idx := 0
var _car := ""
var _wing_idx := 0
var _wheel_idx := 0
var _model: Node3D
var _holder: Node3D
var _cam: Camera3D

# 视角轨道参数
var _yaw := 0.35
var _pitch := 0.30
var _dist := 4.3
var _target := Vector3(0, 0.8, -1.3)

var _sel := ""                   # "" / "wing" / "wheels"
var _hl_list: Array = []         # 高亮中的 MeshInstance3D
var _hl_mat: StandardMaterial3D
var _dirty := false              # 有未保存改动

# UI 引用
var _lbl_car: Label
var _lbl_wing: Label
var _lbl_wheel: Label
var _lbl_info: Label
var _lbl_off: Label
var _lbl_saved: Label
var _btn_marker: Button
var _marker_on := false
var _marker_node: Node3D
# 车辆清单侧栏
var _list_panel: PanelContainer
var _list_vbox: VBoxContainer
var _list_title: Label
var _row_buttons: Dictionary = {}   # car_id -> Button
var _btn_done: Button
var _btn_nowing: Button     # 本车禁用尾翼（游戏内该车选不了翼）
var _btn_wingban: Button    # 此翼全局禁装（游戏内所有车装不了这颗翼）
# 空间删除模式：三维格子选区删三角形
var _cut_mode := false
var _cell := 0.15                   # 当前格子边长（滚轮调节）
var _grid_node: Node3D              # 格线（ImmediateMesh）
var _grid_box := AABB()             # 格子覆盖的世界包围盒（移动/钳制用）
var _grid_n := Vector3i.ONE         # 格子三向数量
var _car_box := AABB()              # 装载时缓存的车体包围盒（不含格线等辅助网格）
var _sel_cell := Vector3i.ZERO      # 选中的格子索引
var _has_sel := false               # 是否已选中格子（待回车/二次点击确认）
var _cut_btn: Button

const STEP_SMALL := 0.01
const STEP_BIG := 0.05
const CELL_MIN := 0.004     # 最细 4mm
const CELL_MAX := 0.5       # 最粗 50cm
const GRID_MAX_CELLS := 100 # 单轴最多画 100 格：细格只画准星附近，防百万线段卡死


func _ready() -> void:
	# 车辆清单（GameData 顺序）
	for spec in GameData.cars_specs:
		var id := String(spec.get("id", ""))
		if not id.is_empty():
			_cars.append(id)
	# 命令行可带 --car=xxx 直达
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--car="):
			var at := _cars.find(arg.substr(6))
			if at >= 0:
				_car_idx = at
	# 高亮材质：红色半透明、无光照、双面
	_hl_mat = StandardMaterial3D.new()
	_hl_mat.albedo_color = Color(1.0, 0.15, 0.1, 0.45)
	_hl_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_hl_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_hl_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	# 场景环境（与 wing_check 同款中性灰）
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.18, 0.19, 0.21)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.55, 0.57, 0.6)
	e.ambient_light_energy = 0.7
	env.environment = e
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-42.0, 32.0, 0.0)
	sun.light_energy = 1.25
	add_child(sun)
	_holder = Node3D.new()
	add_child(_holder)
	_cam = Camera3D.new()
	add_child(_cam)
	_cam.current = true
	_build_ui()
	_load_car()


# ---------------------------------------------------------------------------
# 车辆 / 翼位加载
# ---------------------------------------------------------------------------

func _load_car() -> void:
	_sel = ""
	_clear_highlight()
	_dirty = false
	_grid_node = null   # 格线挂在旧 model 下，随旧 model 一起释放
	_has_sel = false
	for c in _holder.get_children():
		_holder.remove_child(c)
		c.queue_free()
	_car = String(_cars[_car_idx])
	_lbl_car.text = String(GameData.car(_car).get("name", _car))
	# 走真实改装路径：直改内存仓配置（不写盘）
	Garage.config(_car)["wing"] = _wing_idx
	Garage.config(_car)["wheel"] = _wheel_idx
	var vis := CarVisual.build({"id": _car, "model": _car + ".glb"}, _holder)
	_model = vis.get("model") as Node3D
	if _model == null:
		_lbl_info.text = "模型加载失败：" + _car
		return
	var cfg: Dictionary = Garage.config(_car)
	GarageLook.apply(_model, _car, cfg)
	# 空间删除记录的三角形切除（幂等），必须在建拾取碰撞体之前
	PartsLib.apply_mesh_cuts(_model, _car)
	_build_pick_bodies(_model)
	# 相机对准车尾（全部车模统一约定：车尾 -z）
	var box := PartsLib._subtree_aabb(_model)
	_car_box = box   # 缓存：格线等辅助网格挂上后 _subtree_aabb 会被污染
	_target = Vector3(box.get_center().x, box.position.y + box.size.y * 0.55,
		box.position.z + box.size.z * 0.12)
	_dist = clampf(box.size.z * 1.7, 3.2, 8.0)
	_yaw = 0.35
	_pitch = 0.30
	_marker_node = null
	_update_cam()
	_refresh_info()
	if _marker_on:
		_draw_markers()
	if _cut_mode:
		_draw_grid()   # 保留用户滚轮选好的格边长，只重建格线


## 给所有网格建拾取碰撞体（挂在网格自身节点下，继承变换）
func _build_pick_bodies(model: Node3D) -> void:
	for node in model.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			continue
		var body := StaticBody3D.new()
		body.set_meta("pick_mi", mi)
		var cs := CollisionShape3D.new()
		cs.shape = mi.mesh.create_trimesh_shape()
		body.add_child(cs)
		mi.add_child(body)


# ---------------------------------------------------------------------------
# 点选与高亮
# ---------------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			_pick(mb.position)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			if _cut_mode:
				_adjust_cell(0.85)   # 滚轮向上 = 格子更细
			else:
				_zoom(0.92)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			if _cut_mode:
				_adjust_cell(1.18)   # 滚轮向下 = 格子更粗
			else:
				_zoom(1.08)
	elif event is InputEventPanGesture:
		# macOS 触控板双指滚动走的是 Pan 手势，不是滚轮按键
		var pg := event as InputEventPanGesture
		if _cut_mode:
			# 删除模式下双指滚动 = 调格子粗细（与滚轮一致：向下滚更粗）
			_adjust_cell(1.0 + clampf(pg.delta.y, -1.0, 1.0) * 0.12)
		else:
			_zoom(1.0 + clampf(pg.delta.y, -1.0, 1.0) * 0.10)
	elif event is InputEventMagnifyGesture:
		# 触控板捏合缩放；删除模式下捏合也调格子（张开=更细，捏拢=更粗）
		var factor := (event as InputEventMagnifyGesture).factor
		if _cut_mode:
			_adjust_cell(1.0 / maxf(factor, 0.05))
		else:
			_zoom(1.0 / maxf(factor, 0.05))
	elif event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		var mm := event as InputEventMouseMotion
		_yaw += mm.relative.x * 0.006
		_pitch = clampf(_pitch + mm.relative.y * 0.005, -0.35, 1.25)
	elif event is InputEventKey and event.is_pressed() and not event.is_echo():
		_on_key(event as InputEventKey)


func _zoom(ratio: float) -> void:
	_dist = clampf(_dist * ratio, 1.6, 14.0)


func _pick(screen_pos: Vector2) -> void:
	if _model == null:
		return
	if _cut_mode:
		_cut_pick(screen_pos)
		return
	var from := _cam.project_ray_origin(screen_pos)
	var dir := _cam.project_ray_normal(screen_pos)
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * 60.0)
	var hit: Dictionary = get_viewport().get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		_sel = ""
		_clear_highlight()
		_refresh_info()
		return
	var mi := (hit["collider"] as Node).get_meta("pick_mi") as MeshInstance3D
	var node_name := String(mi.name)
	# 手动增删选中：Shift+左键 = 加入当前组；Alt/⌘/Ctrl+左键 = 移出
	var editing := 0
	if Input.is_key_pressed(KEY_SHIFT):
		editing = 1
	elif Input.is_key_pressed(KEY_ALT) or Input.is_key_pressed(KEY_CTRL) \
			or Input.is_key_pressed(KEY_META):
		editing = -1
	if editing != 0:
		var target := _sel if not _sel.is_empty() else _group_of(mi)
		if target.is_empty():
			_lbl_info.text = "请先点选一组（翼/轮），再用 Shift/Alt 增删网格"
			return
		_sel = target
		PartsLib.pick_edit(_car, target, node_name, editing == 1)
		_dirty = true
		_highlight_group(target)
		_refresh_info()
		var group_name := "尾翼" if target == "wing" else \
			("前轮对" if target == "wheels_f" else "后轮对")
		var msg := "✚ 已把 [%s] 加入%s组（已选中：%s，Shift/Alt 继续增删）" if editing == 1 \
			else "− 已把 [%s] 移出%s组（已选中：%s，Shift/Alt 继续增删）"
		_lbl_info.text = msg % [node_name, group_name, group_name]
		_lbl_saved.text = "未保存（Enter 保存）"
		return
	var group := _group_of(mi)
	if group.is_empty():
		_sel = ""
		_clear_highlight()
		_lbl_info.text = "该部件不支持偏移（点轮胎或尾翼；Shift/Alt 可手动归组）"
		return
	_sel = group
	_highlight_group(group)
	_refresh_info()


## 判定网格属于哪个轮位角（FL/FR/RL/RR）：
## 供体轮的子网格都叫供体的名字（如 Rim_Wheel_FL），所以必须查祖先节点
## （Spin_Wheel_XX / Wheel_XX / ProceduralPartWheel_XX），查不到再退回网格名后缀。
func _corner_of(mi: MeshInstance3D) -> String:
	var cur: Node = mi
	while cur != null and cur != _model:
		var nm := String(cur.name)
		for suf in ["FL", "FR", "RL", "RR"]:
			if nm.ends_with("_" + suf) and (nm.begins_with("Spin_Wheel_")
					or nm.begins_with("Wheel_") or nm.begins_with("ProceduralPartWheel_")):
				return suf
		cur = cur.get_parent()
	var own := String(mi.name)
	for suf in ["FL", "FR", "RL", "RR"]:
		if own.ends_with("_" + suf):
			return suf
	return ""


## 按节点名与角位分组：翼组 / 前轮对（FL+FR）/ 后轮对（RL+RR）。
## 人工选区（part_offsets.json 的 wing_pick / wheels_pick add/del 表）优先级最高：
##   add 强制归组、del 强制排除；后视镜永远不归翼组。
func _group_of(mi: MeshInstance3D) -> String:
	var nm := String(mi.name).to_lower()
	if nm.contains("mirror") or nm.contains("后视镜"):
		return ""   # WingMirror 是倒车镜不是尾翼
	var g := ""
	if PartsLib._name_is_wing(nm):
		g = "wing"
	else:
		var corner := _corner_of(mi)
		if not corner.is_empty():
			g = "wheels_f" if corner.begins_with("F") else "wheels_r"
		elif nm.contains("wheel") or nm.contains("tyre") or nm.contains("tire") \
				or nm.contains("rim") or nm.contains("spoke") \
				or nm.contains("轮毂") or nm.contains("轮胎"):
			g = "wheels_f" if nm.contains("_fl") or nm.contains("_fr") else "wheels_r"
	if _car.is_empty():
		return g
	var off: Dictionary = PartsLib.part_offsets(_car)
	var wn := String(mi.name)
	if ((off.get("wing_pick", {}) as Dictionary).get("add", []) as Array).has(wn):
		return "wing"
	if ((off.get("wheels_f_pick", {}) as Dictionary).get("add", []) as Array).has(wn):
		return "wheels_f"
	if ((off.get("wheels_r_pick", {}) as Dictionary).get("add", []) as Array).has(wn):
		return "wheels_r"
	if g == "wing" and ((off.get("wing_pick", {}) as Dictionary).get("del", []) as Array).has(wn):
		return ""
	if g.begins_with("wheels"):
		var pk := off.get(g + "_pick", {}) as Dictionary
		if (pk.get("del", []) as Array).has(wn):
			return ""
	return g


func _highlight_group(group: String) -> void:
	_clear_highlight()
	if _model == null:
		return
	for node in _model.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if _group_of(mi) == group:
			mi.material_overlay = _hl_mat
			_hl_list.append(mi)


func _clear_highlight() -> void:
	for mi in _hl_list:
		if is_instance_valid(mi):
			mi.material_overlay = null
	_hl_list.clear()


# ---------------------------------------------------------------------------
# 空间删除模式：三维格子选区 → 删除格内三角形（二次点击确认，Esc 取消）
# ---------------------------------------------------------------------------

func _set_cut_mode(on: bool) -> void:
	_cut_mode = on
	_has_sel = false
	if on:
		_cell = _calc_cell()   # 进入模式时按当前视距定一个初始粗细，之后滚轮手动调
		_draw_grid()
		_lbl_info.text = "空间删除：点一个格子选中 → 方向键微调位置 → 回车删除；Esc 取消。滚轮/触控板双指滚动调格子粗细（最细 4mm，越细只画准星附近），+− 键缩放视角"
	else:
		if _grid_node != null:
			_grid_node.queue_free()
			_grid_node = null
		_refresh_info()


## 当前格边长：仅作为进入模式时的初值（0.5m → 4mm），之后由滚轮手动调节
func _calc_cell() -> float:
	return clampf(_dist / 8.0, CELL_MIN, CELL_MAX)


## 在车包围盒（略扩）的 6 个面上画格线；格边长变化时由 _process 触发重建
func _draw_grid() -> void:
	if _grid_node != null:
		_grid_node.queue_free()
		_grid_node = null
	if not _cut_mode or _model == null:
		return
	# 用装载时缓存的车体包围盒（不能用 _subtree_aabb —— 格线自己也挂在
	# model 下，会被算进包围盒再外扩，越画越大形成自反馈）
	var outer := _car_box.grow(_cell * 2.0)
	if outer.size == Vector3.ZERO:
		outer = PartsLib._subtree_aabb(_model).grow(_cell * 2.0)
	# 细格时把格线限定在准星附近一小块区域（单轴最多 GRID_MAX_CELLS 格），
	# 否则整车 4mm 格会生成百万级线段卡死；粗格时自然覆盖全车
	var size := Vector3(
		minf(outer.size.x, _cell * GRID_MAX_CELLS),
		minf(outer.size.y, _cell * GRID_MAX_CELLS),
		minf(outer.size.z, _cell * GRID_MAX_CELLS))
	var pos := Vector3(
		clampf(_target.x - size.x * 0.5, outer.position.x, outer.end.x - size.x),
		clampf(_target.y - size.y * 0.5, outer.position.y, outer.end.y - size.y),
		clampf(_target.z - size.z * 0.5, outer.position.z, outer.end.z - size.z))
	var box := AABB(pos, size)
	var origin := box.position
	var n := Vector3i(
		maxi(1, roundi(box.size.x / _cell)),
		maxi(1, roundi(box.size.y / _cell)),
		maxi(1, roundi(box.size.z / _cell)))
	_grid_box = box
	_grid_n = n
	# 选中的格子可能因格径变化出界，钳回格内
	if _has_sel:
		_sel_cell = Vector3i(
			clampi(_sel_cell.x, 0, n.x - 1), clampi(_sel_cell.y, 0, n.y - 1),
			clampi(_sel_cell.z, 0, n.z - 1))
	var mesh := ImmediateMesh.new()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.4, 0.75, 1.0, 0.55)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	# 每个面：沿两个轴向画平行线（车尾/车头面画 X-Y 格，左右面画 Z-Y 格，顶/底面画 X-Z 格）
	for ix in n.x + 1:
		var x := origin.x + ix * _cell
		for iy in n.y + 1:
			var y := origin.y + iy * _cell
			mesh.surface_add_vertex(Vector3(x, y, origin.z))
			mesh.surface_add_vertex(Vector3(x, y, origin.z + n.z * _cell))
	for iz in n.z + 1:
		var z := origin.z + iz * _cell
		for iy in n.y + 1:
			var y := origin.y + iy * _cell
			mesh.surface_add_vertex(Vector3(origin.x, y, z))
			mesh.surface_add_vertex(Vector3(origin.x + n.x * _cell, y, z))
	for ix in n.x + 1:
		var x := origin.x + ix * _cell
		for iz in n.z + 1:
			var z := origin.z + iz * _cell
			mesh.surface_add_vertex(Vector3(x, origin.y, z))
			mesh.surface_add_vertex(Vector3(x, origin.y + n.y * _cell, z))
	mesh.surface_end()
	_grid_node = Node3D.new()
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	_grid_node.add_child(mi)
	_model.add_child(_grid_node)
	# 已选格子：红色半透明盒
	if _has_sel:
		var sel := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3.ONE * _cell
		sel.mesh = bm
		var smat := StandardMaterial3D.new()
		smat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		smat.albedo_color = Color(1.0, 0.1, 0.1, 0.4)
		smat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		sel.material_override = smat
		_grid_node.add_child(sel)
		sel.position = origin + (Vector3(_sel_cell) + Vector3(0.5, 0.5, 0.5)) * _cell


## 空间删除模式的点击：第一次选中格子并统计格内三角形，第二次确认删除
func _cut_pick(screen_pos: Vector2) -> void:
	var from := _cam.project_ray_origin(screen_pos)
	var dir := _cam.project_ray_normal(screen_pos)
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * 60.0)
	var hit: Dictionary = get_viewport().get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		_has_sel = false
		_draw_grid()
		_lbl_info.text = "空间删除：没点到车身（点车上的部位所在格子）"
		return
	var cell := Vector3i(((hit.position - _grid_box.position) / _cell).floor())
	# 点到细格覆盖区之外的车身时钳回格内（提示滚粗格子覆盖更大范围）
	cell = Vector3i(
		clampi(cell.x, 0, _grid_n.x - 1), clampi(cell.y, 0, _grid_n.y - 1),
		clampi(cell.z, 0, _grid_n.z - 1))
	if _has_sel and cell == _sel_cell:
		_confirm_cut()
		return
	# 第一次点击：选中并统计
	_sel_cell = cell
	_has_sel = true
	_draw_grid()
	_show_sel_info()


func _show_sel_info() -> void:
	var total := 0
	for c in _collect_tris_in_cell(_sel_cell, _grid_box):
		total += (c["tris"] as Array).size()
	_lbl_info.text = "已选格子 %s：内含 %d 个三角形 —— 方向键移动 / 回车删除 / Esc 取消（格边长 %.1fcm，滚轮调粗细）" % [
		str(_sel_cell), total, _cell * 100.0]


## 确认删除当前选中格子内的三角形（回车或同格二次点击）
func _confirm_cut() -> void:
	var cuts := _collect_tris_in_cell(_sel_cell, _grid_box)
	var n_tris := 0
	for c in cuts:
		PartsLib.add_mesh_cut(_car, c["node"], c["surf"], c["tris"])
		n_tris += (c["tris"] as Array).size()
	_has_sel = false
	_dirty = true
	_lbl_info.text = "✂ 已删除 %s 格内 %d 个三角形 —— Enter 保存后游戏内生效；点错了按「撤销删除」" % [
		str(_sel_cell), n_tris]
	_lbl_saved.text = "未保存（Enter 保存）"
	_load_car()
	if _cut_mode:
		_draw_grid()


## 滚轮调节格子边长（空间删除模式下）
func _adjust_cell(factor: float) -> void:
	_cell = clampf(_cell * factor, CELL_MIN, CELL_MAX)
	_draw_grid()
	if _has_sel:
		_show_sel_info()
	else:
		_lbl_info.text = "格边长 %.1fcm —— 点一个格子选中，方向键微调，回车删除" % (_cell * 100.0)


## 方向键在屏幕平面上移动选中的格子（相机朝向自适应：屏幕左右/上下对应哪根世界轴）
func _move_sel(key: InputEventKey) -> void:
	if not _has_sel or _model == null:
		_lbl_info.text = "空间删除：先用鼠标点一个格子，才能用方向键移动"
		return
	var b := _cam.global_transform.basis
	var step := 5 if Input.is_key_pressed(KEY_SHIFT) else 1
	var d := Vector3i.ZERO
	if key.keycode == KEY_LEFT or key.keycode == KEY_RIGHT:
		# 屏幕左右 → 取相机右向量的主导世界轴
		var r := b.x
		if absf(r.x) >= absf(r.z):
			d.x = step if r.x >= 0.0 else -step
		else:
			d.z = step if r.z >= 0.0 else -step
		if key.keycode == KEY_LEFT:
			d = -d
	else:
		# 屏幕上下 → 取相机上向量的主导世界轴（一般是世界 Y）
		var u := b.y
		if absf(u.y) >= absf(u.x) and absf(u.y) >= absf(u.z):
			d.y = step if u.y >= 0.0 else -step
		elif absf(u.x) >= absf(u.z):
			d.x = step if u.x >= 0.0 else -step
		else:
			d.z = step if u.z >= 0.0 else -step
		if key.keycode == KEY_DOWN:
			d = -d
	_sel_cell = Vector3i(
		clampi(_sel_cell.x + d.x, 0, _grid_n.x - 1),
		clampi(_sel_cell.y + d.y, 0, _grid_n.y - 1),
		clampi(_sel_cell.z + d.z, 0, _grid_n.z - 1))
	_draw_grid()
	_show_sel_info()


## 收集某个格子内的三角形：[(node_path, surf, [三角形序号...])]。
## 三角形任一顶点（世界坐标）落进格子即算；序号针对原始网格（未切除），与 apply_mesh_cuts 对齐。
func _collect_tris_in_cell(cell: Vector3i, grid_box: AABB) -> Array:
	var cmin := grid_box.position + Vector3(cell) * _cell
	var cmax := cmin + Vector3.ONE * _cell
	var out: Array = []
	for node in _model.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null or not mi.visible or mi.is_queued_for_deletion():
			continue
		var xf := mi.global_transform
		var am := mi.mesh as ArrayMesh
		if am == null:
			continue
		for s in am.get_surface_count():
			var arrays := am.surface_get_arrays(s)
			if arrays.size() <= Mesh.ARRAY_INDEX or arrays[Mesh.ARRAY_INDEX] == null:
				continue
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			var tris: Array = []
			var ntri := idx.size() / 3
			for k in ntri:
				var inside := false
				for j in 3:
					var w := xf * verts[idx[k * 3 + j]]
					if w.x >= cmin.x and w.x <= cmax.x and w.y >= cmin.y \
							and w.y <= cmax.y and w.z >= cmin.z and w.z <= cmax.z:
						inside = true
						break
				if inside:
					tris.append(k)
			if not tris.is_empty():
				out.append({"node": String(_model.get_path_to(mi)), "surf": s, "tris": tris})
	return out


# ---------------------------------------------------------------------------
# 键盘微调
# ---------------------------------------------------------------------------

func _on_key(key: InputEventKey) -> void:
	match key.keycode:
		KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT:
			if _cut_mode:
				_move_sel(key)
				return
			if _sel.is_empty() or _model == null:
				return
			if _sel == "wing" and _wing_key() == "stock":
				_lbl_info.text = "原厂尾翼位置不可调 —— 先切到一个改装翼（[ ]键）"
				return
			if not _sel_axle().is_empty() and _wheels_key() == "factory":
				_lbl_info.text = "原厂车轮不可调 —— 先切到一个供体轮（, . 键）"
				return
			var step := STEP_BIG if key.is_shift_pressed() else STEP_SMALL
			var off: Dictionary = _sel_offsets()
			var dx := float(off.get("dx", 0.0))
			var dy := float(off.get("dy", 0.0))
			var dz := float(off.get("dz", 0.0))
			match key.keycode:
				KEY_UP:
					dy += step
				KEY_DOWN:
					dy -= step
				KEY_RIGHT:
					dz += step
				KEY_LEFT:
					dz -= step
			_write_sel_offset(dx, dy, dz)
			_dirty = true
			_apply_and_refresh()
		KEY_Q, KEY_E:
			if _sel.is_empty() or _model == null:
				return
			var step2 := STEP_BIG if key.is_shift_pressed() else STEP_SMALL
			if _sel == "wing":
				if _wing_key() == "stock":
					_lbl_info.text = "原厂尾翼不可调 —— 先切到一个改装翼（[ ]键）"
					return
				var sc := float(PartsLib.wing_offsets(_car, _wing_key()).get("scale", 1.0))
				var sstep := 0.1 if key.is_shift_pressed() else 0.03
				sc += sstep if key.keycode == KEY_E else -sstep
				PartsLib.set_wing_scale(_car, _wing_key(), sc)
			else:
				var axle := _sel_axle()
				if axle.is_empty():
					return
				if _wheels_key() == "factory":
					_lbl_info.text = "原厂车轮不可调 —— 先切到一个供体轮（, . 键）"
					return
				# E = 向外扩（左右轮自动镜像），Q = 向内收
				var dx := float(_sel_offsets().get("dx", 0.0))
				dx += step2 if key.keycode == KEY_E else -step2
				var off2: Dictionary = _sel_offsets()
				PartsLib.set_wheel_axle_offset(_car, _wheels_key(), axle, dx,
					float(off2.get("dy", 0.0)), float(off2.get("dz", 0.0)))
			_dirty = true
			_apply_and_refresh()
		KEY_ENTER, KEY_KP_ENTER:
			if _cut_mode and _has_sel:
				_confirm_cut()
			else:
				_save()
		KEY_S:
			_save()
		KEY_R:
			if not _sel.is_empty():
				if _sel == "wing":
					if _wing_key() == "stock":
						return
					PartsLib.set_wing_offset(_car, _wing_key(), 0.0, 0.0)
					PartsLib.set_wing_scale(_car, _wing_key(), 1.0)
				elif not _sel_axle().is_empty():
					if _wheels_key() == "factory":
						return
					PartsLib.clear_wheel_axle_offset(_car, _wheels_key(), _sel_axle())
				else:
					PartsLib.set_part_offset(_car, _sel, 0.0, 0.0)
				_dirty = true
				_apply_and_refresh()
		KEY_ESCAPE:
			if _cut_mode and _has_sel:
				_has_sel = false
				_draw_grid()
				_lbl_info.text = "已取消格子选择"
			else:
				_sel = ""
				_clear_highlight()
				_refresh_info()
		KEY_C:
			_car_idx = (_car_idx + 1) % _cars.size()
			_load_car()
		KEY_COMMA:
			_switch_wheel(-1)
		KEY_PERIOD:
			_switch_wheel(1)
		KEY_EQUAL, KEY_KP_ADD:
			_zoom(0.90)   # + / = 拉近
		KEY_MINUS, KEY_KP_SUBTRACT:
			_zoom(1.10)   # - 拉远
		KEY_BRACKETLEFT:
			_switch_wing(-1)
		KEY_BRACKETRIGHT:
			_switch_wing(1)


## 当前翼位的存储键："stock"（原厂，不可调）或供体车 id（每个翼独立一份数据）。
## 与 PartsLibrary.build_wing 的读取键（裸供体 id）保持一致，剥掉 "donor:" 前缀。
func _wing_key() -> String:
	var id := String(PartsLib.wing_option_entry(_wing_idx).get("id", ""))
	return id.substr(6) if id.begins_with("donor:") else id


## 当前轮位的存储键："factory"（原厂，不可调）或供体车 id（每个轮独立一份数据）
func _wheels_key() -> String:
	var id := String(PartsLib.wheel_option_entry(_wheel_idx).get("id", ""))
	return id.substr(6) if id.begins_with("donor:") else id


## 选中组对应的轮轴名（"wheels_f"->front / "wheels_r"->rear）；非轮组返回 ""。
func _sel_axle() -> String:
	return "front" if _sel == "wheels_f" else ("rear" if _sel == "wheels_r" else "")


## 当前选中组现有的调整数据（翼按供体分桶；轮按供体+前/后轴分桶）
func _sel_offsets() -> Dictionary:
	if _sel == "wing":
		return PartsLib.wing_offsets(_car, _wing_key())
	var axle := _sel_axle()
	if not axle.is_empty():
		return PartsLib.wheel_axle_offsets(_car, _wheels_key(), axle)
	return {}


func _write_sel_offset(dx: float, dy: float, dz: float) -> void:
	if _sel == "wing":
		PartsLib.set_wing_offset(_car, _wing_key(), dy, dz)
	elif not _sel_axle().is_empty():
		PartsLib.set_wheel_axle_offset(_car, _wheels_key(), _sel_axle(), dx, dy, dz)


func _apply_and_refresh() -> void:
	Garage.config(_car)["wing"] = _wing_idx
	GarageLook.apply(_model, _car, Garage.config(_car))
	_clear_highlight()   # 旧翼节点已被 apply 释放，清掉失效引用
	if not _sel.is_empty():
		_highlight_group(_sel)
	_lbl_saved.text = "未保存（Enter 保存）" if _dirty else ""
	_refresh_info()
	if _marker_on:
		_draw_markers()


func _save() -> void:
	PartsLib.save_offsets()
	_dirty = false
	_lbl_saved.text = "✓ 已保存，游戏内立即生效"
	_lbl_saved.add_theme_color_override("font_color", UIStyle.GREEN)
	var t := get_tree().create_timer(2.0)
	t.timeout.connect(func() -> void:
		if is_instance_valid(_lbl_saved):
			_lbl_saved.text = "")


# ---------------------------------------------------------------------------
# UI
# ---------------------------------------------------------------------------

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	# ---- 顶栏：车辆 / 尾翼切换 + 标记开关 -----------------------------------
	var top := PanelContainer.new()
	top.add_theme_stylebox_override("panel", UIStyle.panel_style(UIStyle.ACCENT, 0.94))
	top.set_anchors_preset(Control.PRESET_TOP_WIDE)
	top.offset_left = 12
	top.offset_right = -12
	top.offset_top = 10
	layer.add_child(top)
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 10)
	top.add_child(hb)
	hb.add_child(_mini_label("车辆"))
	hb.add_child(_nav_btn("◀", func() -> void:
		_car_idx = (_car_idx - 1 + _cars.size()) % _cars.size()
		_load_car()))
	_lbl_car = _mini_label("", UIStyle.TXT, 16)
	_lbl_car.custom_minimum_size = Vector2(190, 0)
	hb.add_child(_lbl_car)
	hb.add_child(_nav_btn("▶", func() -> void:
		_car_idx = (_car_idx + 1) % _cars.size()
		_load_car()))
	hb.add_child(UIStyle.spacer())
	hb.add_child(_mini_label("尾翼"))
	hb.add_child(_nav_btn("◀", func() -> void: _switch_wing(-1)))
	_lbl_wing = _mini_label("", UIStyle.TXT, 16)
	_lbl_wing.custom_minimum_size = Vector2(170, 0)
	hb.add_child(_lbl_wing)
	hb.add_child(_nav_btn("▶", func() -> void: _switch_wing(1)))
	hb.add_child(UIStyle.spacer())
	hb.add_child(_mini_label("车轮"))
	hb.add_child(_nav_btn("◀", func() -> void: _switch_wheel(-1)))
	_lbl_wheel = _mini_label("", UIStyle.TXT, 16)
	_lbl_wheel.custom_minimum_size = Vector2(140, 0)
	hb.add_child(_lbl_wheel)
	hb.add_child(_nav_btn("▶", func() -> void: _switch_wheel(1)))
	hb.add_child(UIStyle.spacer())
	_btn_marker = UIStyle.make_button("测量面标记", UIStyle.ACCENT, "ghost", 13, 32)
	_btn_marker.toggle_mode = true
	_btn_marker.focus_mode = Control.FOCUS_NONE
	_btn_marker.toggled.connect(func(on: bool) -> void:
		_marker_on = on
		if _marker_on:
			_draw_markers()
		elif _marker_node != null:
			_marker_node.queue_free()
			_marker_node = null)
	hb.add_child(_btn_marker)
	var btn_list := UIStyle.make_button("车辆清单", UIStyle.ACCENT, "primary", 13, 32)
	btn_list.toggle_mode = true
	btn_list.button_pressed = true
	btn_list.focus_mode = Control.FOCUS_NONE
	btn_list.toggled.connect(func(on: bool) -> void:
		_list_panel.visible = on)
	hb.add_child(btn_list)
	# ---- 底栏：状态 + 操作按钮 + 提示 ---------------------------------------
	var bottom := PanelContainer.new()
	bottom.add_theme_stylebox_override("panel", UIStyle.panel_style(UIStyle.ACCENT, 0.94))
	bottom.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	bottom.offset_left = 12
	bottom.offset_right = -12
	bottom.offset_top = -132
	bottom.offset_bottom = -10
	layer.add_child(bottom)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	bottom.add_child(vb)
	_lbl_info = _mini_label("", UIStyle.GOLD, 15)
	vb.add_child(_lbl_info)
	_lbl_off = _mini_label("", UIStyle.TXT, 14)
	vb.add_child(_lbl_off)
	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 10)
	vb.add_child(btn_row)
	btn_row.add_child(_action_btn("选中尾翼", func() -> void:
		_sel = "wing"
		_highlight_group("wing")
		_refresh_info()))
	btn_row.add_child(_action_btn("选中前轮", func() -> void:
		_sel = "wheels_f"
		_highlight_group("wheels_f")
		_refresh_info()))
	btn_row.add_child(_action_btn("选中后轮", func() -> void:
		_sel = "wheels_r"
		_highlight_group("wheels_r")
		_refresh_info()))
	btn_row.add_child(_action_btn("取消选中", func() -> void:
		_sel = ""
		_clear_highlight()
		_refresh_info()))
	btn_row.add_child(_action_btn("归零(本部件)", func() -> void:
		if _sel.is_empty():
			return
		if _sel == "wing":
			PartsLib.set_wing_offset(_car, _wing_key(), 0.0, 0.0)
			PartsLib.set_wing_scale(_car, _wing_key(), 1.0)
		elif not _sel_axle().is_empty():
			PartsLib.clear_wheel_axle_offset(_car, _wheels_key(), _sel_axle())
		else:
			PartsLib.set_part_offset(_car, _sel, 0.0, 0.0)
		_dirty = true
		_apply_and_refresh()))
	_btn_done = UIStyle.make_button("标记已完成", UIStyle.GREEN, "ghost", 14, 34)
	_btn_done.focus_mode = Control.FOCUS_NONE
	_btn_done.pressed.connect(_toggle_done)
	btn_row.add_child(_btn_done)
	_cut_btn = UIStyle.make_button("空间删除", UIStyle.GOLD, "ghost", 14, 34)
	_cut_btn.toggle_mode = true
	_cut_btn.focus_mode = Control.FOCUS_NONE
	_cut_btn.toggled.connect(func(on: bool) -> void: _set_cut_mode(on))
	btn_row.add_child(_cut_btn)
	# 装配禁用标记：游戏内生效（车级禁翼 / 本车禁装此翼），点击立即写盘
	_btn_nowing = UIStyle.make_button("本车禁用尾翼", UIStyle.GOLD, "ghost", 14, 34)
	_btn_nowing.focus_mode = Control.FOCUS_NONE
	_btn_nowing.pressed.connect(_toggle_no_wing)
	btn_row.add_child(_btn_nowing)
	_btn_wingban = UIStyle.make_button("此车禁装此翼", UIStyle.GOLD, "ghost", 14, 34)
	_btn_wingban.focus_mode = Control.FOCUS_NONE
	_btn_wingban.pressed.connect(_toggle_wingban)
	btn_row.add_child(_btn_wingban)
	btn_row.add_child(_action_btn("撤销删除", func() -> void:
		if PartsLib.pop_last_mesh_cut(_car):
			_dirty = true
			_lbl_info.text = "已撤销最近一次删除（Enter 保存生效）"
			_load_car()
			if _cut_mode:
				_draw_grid()
		else:
			_lbl_info.text = "这辆车没有可撤销的删除记录"))
	btn_row.add_child(UIStyle.spacer())
	_lbl_saved = _mini_label("", UIStyle.GREEN, 14)
	btn_row.add_child(_lbl_saved)
	btn_row.add_child(_action_btn("保存 (Enter)", func() -> void: _save(), "primary"))
	var hints := _mini_label(
		"点前轮=选中前轮对 / 点后轮=选中后轮对 · Shift+左键=加入组 · Alt/⌘+左键=移出 · 右键拖动旋转 · 滚轮/+− 缩放 · ↑↓ 高低 · ←→ 前后 · Q内收 E外扩(轮)/缩放(翼) · R 归零 · C 换车 · [ ] 换翼 · , . 换轮 · 空间删除=点格子选中→方向键移动→滚轮调格粗→回车删 · Enter 保存",
		UIStyle.TXT_DIM, 12)
	vb.add_child(hints)
	_build_list_panel(layer)
	_rebuild_list()


# ---------------------------------------------------------------------------
# 车辆清单侧栏（绿色=已标记完成，黄色●=调过未标记，▶=当前车）
# ---------------------------------------------------------------------------

func _build_list_panel(layer: CanvasLayer) -> void:
	_list_panel = PanelContainer.new()
	_list_panel.add_theme_stylebox_override("panel", UIStyle.panel_style(UIStyle.ACCENT, 0.94))
	_list_panel.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	_list_panel.offset_left = 12
	_list_panel.offset_top = 56
	_list_panel.offset_bottom = -140
	_list_panel.offset_right = 12
	_list_panel.custom_minimum_size = Vector2(240, 0)
	layer.add_child(_list_panel)
	var pv := VBoxContainer.new()
	pv.add_theme_constant_override("separation", 6)
	_list_panel.add_child(pv)
	_list_title = _mini_label("", UIStyle.ACCENT, 14)
	pv.add_child(_list_title)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	pv.add_child(scroll)
	_list_vbox = VBoxContainer.new()
	_list_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list_vbox.add_theme_constant_override("separation", 2)
	scroll.add_child(_list_vbox)


func _rebuild_list() -> void:
	if _list_vbox == null:
		return
	for c in _list_vbox.get_children():
		_list_vbox.remove_child(c)
		c.queue_free()
	_row_buttons.clear()
	var done_count := 0
	for id in _cars:
		var done := PartsLib.car_done(id)
		if done:
			done_count += 1
		var name := String(GameData.car(id).get("name", id))
		var nowing := " 🚫" if PartsLib.car_no_wing(id) else ""
		var status := ("  ✓ 已完成" if done else ("  ● 调过" if PartsLib.car_has_tuning(id) else "")) + nowing
		var row := Button.new()
		row.text = ("▶ " if id == _car else "") + name + status
		row.alignment = HORIZONTAL_ALIGNMENT_LEFT
		row.add_theme_font_size_override("font_size", 12)
		row.add_theme_color_override("font_color",
			UIStyle.GREEN if done else (UIStyle.GOLD if PartsLib.car_has_tuning(id) else UIStyle.TXT_DIM))
		row.flat = true
		row.focus_mode = Control.FOCUS_NONE
		row.custom_minimum_size = Vector2(0, 22)
		var car_id := String(id)
		row.pressed.connect(func() -> void:
			var at := _cars.find(car_id)
			if at >= 0 and at != _car_idx:
				_car_idx = at
				_load_car()
				_rebuild_list())
		_list_vbox.add_child(row)
		_row_buttons[id] = row
	_list_title.text = "车辆清单（已完成 %d / %d）" % [done_count, _cars.size()]


func _toggle_done() -> void:
	var now := not PartsLib.car_done(_car)
	PartsLib.set_car_done(_car, now)   # 立即写盘，防误关丢进度
	_update_done_btn()
	_rebuild_list()
	_lbl_info.text = "✓ [%s] 已标记完成" % _car if now else "已取消 [%s] 的完成标记" % _car


## 本车禁用尾翼：游戏里这台车的尾翼选项锁死为原厂
func _toggle_no_wing() -> void:
	var now := not PartsLib.car_no_wing(_car)
	PartsLib.set_car_no_wing(_car, now)   # 立即写盘
	_refresh_info()
	_rebuild_list()
	if now:
		_lbl_info.text = "🚫 [%s] 已禁用尾翼：游戏里这台车选不了任何改装翼（保持原厂）。再次点击解除" % _car
	else:
		_lbl_info.text = "已解除 [%s] 的禁翼标记，游戏里可正常选尾翼" % _car


## 此车禁装此翼：当前切到的这颗供体翼，只对当前这台车禁装（其它车不受影响）
func _toggle_wingban() -> void:
	var key := _wing_key()
	if key == "stock":
		_lbl_info.text = "原厂尾翼不用禁装 —— 用 [ ] 键切到某个改装翼再标记"
		return
	var now := not PartsLib.wing_banned(_car, key)
	PartsLib.set_wing_banned(_car, key, now)   # 立即写盘
	_refresh_info()
	if now:
		_lbl_info.text = "🚫 [%s] 已禁装翼[%s]：游戏里这台车选不到它，其它车不受影响（再次点击解除）" % [_car, key]
	else:
		_lbl_info.text = "已解除 [%s] 对翼[%s]的禁装标记" % [_car, key]


## 刷新两个禁用标记按钮的状态文字（跟随当前车/当前翼）
func _update_mark_btns() -> void:
	if _btn_nowing != null:
		var on := PartsLib.car_no_wing(_car)
		_btn_nowing.text = "🚫 已禁用尾翼(点此解除)" if on else "本车禁用尾翼"
		_btn_nowing.add_theme_color_override("font_color",
			UIStyle.GREEN if on else UIStyle.TXT)
	if _btn_wingban != null:
		var banned := PartsLib.wing_banned(_car, _wing_key())
		_btn_wingban.text = "🚫 此翼已禁装(点此解除)" if banned else "此车禁装此翼"
		_btn_wingban.add_theme_color_override("font_color",
			UIStyle.GREEN if banned else UIStyle.TXT)


func _update_done_btn() -> void:
	if _btn_done == null:
		return
	var done := PartsLib.car_done(_car)
	_btn_done.text = "✓ 已完成（点此取消）" if done else "标记已完成"
	_btn_done.add_theme_color_override("font_color", UIStyle.GREEN if done else UIStyle.TXT)


func _mini_label(text: String, color: Color = UIStyle.TXT_SUB, size: int = 13) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", size)
	lbl.add_theme_color_override("font_color", color)
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return lbl


func _nav_btn(text: String, cb: Callable) -> Button:
	var btn := UIStyle.make_button(text, UIStyle.ACCENT, "ghost", 14, 30)
	btn.custom_minimum_size = Vector2(34, 30)
	btn.focus_mode = Control.FOCUS_NONE   # 别抢方向键
	btn.pressed.connect(cb)
	return btn


func _action_btn(text: String, cb: Callable, kind: String = "ghost") -> Button:
	var btn := UIStyle.make_button(text, UIStyle.ACCENT, kind, 14, 34)
	btn.focus_mode = Control.FOCUS_NONE
	btn.pressed.connect(cb)
	return btn


func _switch_wing(delta: int) -> void:
	var count := PartsLib.wing_option_count()
	_wing_idx = wrapi(_wing_idx + delta, 0, count)
	if _model != null:
		Garage.config(_car)["wing"] = _wing_idx
		GarageLook.apply(_model, _car, Garage.config(_car))
		_clear_highlight()
		if not _sel.is_empty():
			_highlight_group(_sel)
		_refresh_info()
		if _marker_on:
			_draw_markers()


func _switch_wheel(delta: int) -> void:
	var count := PartsLib.wheel_option_count()
	_wheel_idx = wrapi(_wheel_idx + delta, 0, count)
	if _model != null:
		Garage.config(_car)["wheel"] = _wheel_idx
		GarageLook.apply(_model, _car, Garage.config(_car))
		_clear_highlight()
		if not _sel.is_empty():
			_highlight_group(_sel)
		_refresh_info()
		if _marker_on:
			_draw_markers()


# ---------------------------------------------------------------------------
# 状态刷新 / 测量面标记
# ---------------------------------------------------------------------------

func _refresh_info() -> void:
	_update_mark_btns()
	var wing_name := String(PartsLib.wing_option_entry(_wing_idx).get("name", ""))
	_lbl_wing.text = wing_name
	_lbl_wheel.text = String(PartsLib.wheel_option_entry(_wheel_idx).get("name", ""))
	if _sel.is_empty():
		_lbl_info.text = "未选中 —— 点车上的轮胎或尾翼（红色高亮=选中）"
		_lbl_off.text = ""
		return
	var off: Dictionary = _sel_offsets()
	var dx := float(off.get("dx", 0.0))
	var dy := float(off.get("dy", 0.0))
	var dz := float(off.get("dz", 0.0))
	var axle := _sel_axle()
	var group_name := "尾翼" if _sel == "wing" else \
		("前轮对（左前+右前，同步调整）" if axle == "front" else "后轮对（左后+右后，同步调整）")
	_lbl_info.text = "已选中：%s   （当前车：%s）" % [group_name, _car]
	var line := "偏移  dy=%.3fm (%+.1fcm)   dz=%.3fm (%+.1fcm)" % [dy, dy * 100.0, dz, dz * 100.0]
	if not axle.is_empty():
		line = "外扩 dx=%+.3fm (%+.1fcm)   ·   %s" % [dx, dx * 100.0, line]
		line += "   ·   Q 内收 / E 外扩（左右轮自动镜像，前后轴数据独立）"
	if _sel == "wing":
		var sc := float(off.get("scale", 1.0))
		line += "   缩放 ×%.2f (%d%%)" % [sc, int(round(sc * 100.0))]
		line += "   ·   Q/E 缩放（数据按翼位独立保存，调这翼不影响其它翼）"
	_lbl_off.text = line


## 保留自 wing_check --debug-geo：红板 = 实测行李箱面，绿框 = 翼组包围盒
func _draw_markers() -> void:
	if _marker_node != null:
		_marker_node.queue_free()
		_marker_node = null
	if _model == null:
		return
	var donor := Garage.wing_donor_id(_car)
	var box := _car_box   # 缓存盒，避免格线污染
	var wing := _model.find_child("ProceduralPartWing", true, false) as Node3D
	_marker_node = Node3D.new()
	_model.add_child(_marker_node)
	# 行李箱面（车尾 12% 带）
	var rear_is_min := true
	var wing_cz := box.position.z + box.size.z * 0.06
	if wing != null:
		var wbox := PartsLib._subtree_aabb(wing)
		wing_cz = wbox.get_center().z
		rear_is_min = absf(wing_cz - box.position.z) < absf(wing_cz - (box.position.z + box.size.z))
	var deck := PartsLib._rear_deck_y(_model, box, rear_is_min)
	var panel := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(box.size.z * 0.4, box.size.x * 0.96)
	panel.mesh = pm
	var pmat := StandardMaterial3D.new()
	pmat.albedo_color = Color(1, 0.1, 0.1, 0.45)
	pmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	pmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	panel.material_override = pmat
	panel.rotation_degrees = Vector3(0, 90, 0)
	panel.position = Vector3(box.get_center().x, deck, box.get_center().z)
	_marker_node.add_child(panel)
	# 翼组包围盒（绿）
	if wing != null:
		var wbox := PartsLib._subtree_aabb(wing)
		var xform := Transform3D.IDENTITY
		var cur: Node = wing
		while cur != null and cur != _model:
			if cur is Node3D:
				xform = (cur as Node3D).transform * xform
			cur = cur.get_parent()
		var wworld: AABB = xform * wbox
		var wire := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = wworld.size
		wire.mesh = bm
		var wmat := StandardMaterial3D.new()
		wmat.albedo_color = Color(0.1, 1, 0.2, 0.22)
		wmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		wmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		wire.material_override = wmat
		wire.position = wworld.get_center()
		_marker_node.add_child(wire)


func _process(_d: float) -> void:
	_update_cam()
	# 空间删除模式：格子粗细完全由滚轮手动控制（不再随视距自动变化）


func _update_cam() -> void:
	if _cam == null:
		return
	var cp := cos(_pitch)
	var pos := _target + Vector3(sin(_yaw) * cp, sin(_pitch), -cos(_yaw) * cp) * _dist
	_cam.position = pos
	_cam.look_at(_target)
