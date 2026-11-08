class_name GarageLook
extends RefCounted
## 改装工厂外观挂载（v0.55 真件版）：
##   · 车漆：原厂漆保留贴图/拉花，换色走纯色覆盖（哑光单独路径）；
##   · 轮毂/轮胎：真件互换 —— 从其它车款的 GLB 原模型里抠出原厂轮毂+轮胎
##     网格（PartsLibrary），按本车实测轮径/胎宽缩放后挂到 Spin_Wheel_XX 上；
##     选「原厂造型」时保留本车原轮。轮毂色/轮胎色按节点名染色（保留贴图）；
##   · 卡钳：程序化制动盘+卡钳挂在转向节点，不随轮转；换真件时把原厂
##     刹车盘/卡钳网格一并藏掉（部分车如仰望 U8 的刹车件在 Wheel_XX 下）；
##   · 尾翼：真件移植 —— 抠出供体车整组尾翼（翼面+支架），按本车实测车宽
##     等比缩放，底部落在本车后备箱上表面的实测高度上、贴近车尾边缘；
##     同时隐藏本车原厂尾翼网格（wing/spoiler/ducktail/尾翼）。
## 配置来源 Garage.config(car_id)；数值层（effective_spec）见 GarageStore。

const TAG := "ProceduralPart"   # 挂载件统一打标，重装前按标移除
# 真件库：preload 显式加载（不依赖全局类缓存，避免编译期 Identifier not declared）
const PartsLibrary := preload("res://scripts/cars/parts_library.gd")

# 焊死式原厂尾翼表：个别车的原厂尾翼可能不是独立 Spoiler 节点，而是焊进
# 后备箱盖等网格里（按节点名匹配不到 → 会出现「新翼叠在原翼上」）。
# 键 = car_id，值 = [[网格节点名, surface 索引], ...]。
# 注：bmw_m4_gt4 曾属此表（整组大尾翼焊在 BOOT 网格与 Body_05 里），
# 2026-11-07 已用 tools/car_audit/split_m4_gt4_wing.py 在 GLB 资产里把尾翼
# 拆成独立的 Spoiler_01/Spoiler_02 节点，回归命名约定，条目随之移除。
# 新发现焊死案例时优先做同样的 GLB 拆分（一次性、资产级、可复原）；实在
# 拆不动（尾翼与车身几何在同一 surface 交织）才往这张表加 surface 级条目。
# 不要用泛化的几何猜测（尾灯/后挡玻璃/牌照都在车尾带内，泛化规则会误删）。
const WELDED_STOCK_WING := {}
const META_SAVED_WING_MESH := "stock_wing_saved_mesh"   # 还原用：原网格或 "visible"


static func apply(model: Node3D, car_id: String, cfg: Dictionary) -> Dictionary:
	var applied := {"rims": 0, "tires": 0, "wing": false, "calipers": 0}
	if model == null:
		return applied
	# ---- 车漆 ---------------------------------------------------------------
	var paint := Color.TRANSPARENT
	if not Garage.paint_is_factory(car_id):
		paint = Garage.paint_color(car_id)
	CarVisual.apply_paint(model, paint, Garage.paint_is_matte(car_id), Garage.paint_color(car_id))
	if cfg.is_empty():
		return applied
	# ---- 轮毂 + 轮胎（真件互换） ---------------------------------------------
	var wheel_index := Garage.get_option(car_id, "wheel")
	var tire_index := Garage.get_option(car_id, "tire")
	var wheel_donor := Garage.wheel_donor_id(car_id)
	var rim_col := Garage.rim_color(car_id)
	var cal_col := Garage.caliper_color(car_id)
	var tire_tint := Garage.tire_tint(car_id)
	var manifest_radius := CarVisual.wheel_radius_for(car_id)
	# 车宽中线（模型局部）：判定轮位在左/右侧，供体轮转向与 dx 镜像都用它
	var model_cx := PartsLibrary._subtree_aabb(model).get_center().x
	for suffix in ["FL", "FR", "RL", "RR"]:
		var spin := model.find_child("Spin_Wheel_" + suffix, true, false) as Node3D
		if spin == null:
			continue
		# 先按本车轮胎网格实测尺寸（必须在藏原轮之前量）
		var dims := CarVisual.wheel_dims(spin, manifest_radius)
		# 车轮组宿主：Wheel_XX 转向节点（内含 Spin 与部分车的原厂刹车盘/卡钳）
		var wheel_host := model.find_child("Wheel_" + suffix, true, false) as Node3D
		if wheel_host == null:
			wheel_host = spin.get_parent() as Node3D
		if wheel_host == null or not String(wheel_host.name).begins_with("Wheel"):
			wheel_host = spin   # 防御：避免误拿到车身根节点把整车藏掉
		_remove_tagged(spin)
		_remove_tagged(wheel_host, TAG + "Brake_" + suffix)
		if wheel_donor.is_empty():
			# 原厂造型：还原本车原厂轮毂/轮胎/刹车
			_set_subtree_meshes_visible(wheel_host, true)
			continue
		# 真件：藏起本车整组车轮网格（轮毂/轮胎/刹车盘/卡钳），挂供体轮
		_set_subtree_meshes_visible(wheel_host, false)
		var donor_wheel := PartsLibrary.build_wheel(
			wheel_donor, dims["radius"], dims["width"], rim_col, tire_tint)
		if donor_wheel == null:
			# 供体抠件失败（如 GLB 缺失）→ 回退本车原轮
			_set_subtree_meshes_visible(wheel_host, true)
			continue
		donor_wheel.name = TAG + "Wheel_" + suffix
		donor_wheel.set_meta(TAG, true)
		# 供体件抠自供体车左轮（辐条面朝模型局部 +x）。挂到右侧轮位时若不转向，
		# 看到的就是轮毂背面（像旧轮毂）。按几何判定：供体面朝向与"从轮心指向
		# 车宽中线外"的方向相反时，绕 Y 转 180°（滚动仍由父级 Spin 绕 X 轴驱动，方向不变）。
		var spin_rel := PartsLibrary._relative_to(spin, model)
		var outward := spin_rel.origin.x - model_cx
		if (spin_rel.basis.x.x) * outward < 0.0:
			donor_wheel.rotation.y = PI
		# 人工微调（part_tuner 工具产出）：按「车 + 供体轮 + 前/后轴」分桶。
		# dx 为"向外"位移，左右轮按几何侧自动镜像；转了 180° 的右轮 position
		# 仍定义在父级 Spin 坐标系，镜像用几何侧符号而不是节点名。
		var axle := "front" if suffix.begins_with("F") else "rear"
		var woff: Dictionary = PartsLibrary.wheel_axle_offsets(car_id, wheel_donor, axle)
		var side := 1.0 if outward > 0.0 else -1.0
		donor_wheel.position = Vector3(
			side * float(woff.get("dx", 0.0)),
			float(woff.get("dy", 0.0)),
			float(woff.get("dz", 0.0)))
		spin.add_child(donor_wheel)
		applied["rims"] = wheel_index
		applied["tires"] = tire_index
		# 制动盘/卡钳：挂转向节点，不随轮滚转
		var brake := ProceduralParts.build_brake(dims["radius"], dims["width"], cal_col)
		brake.name = TAG + "Brake_" + suffix
		brake.set_meta(TAG, true)
		brake.position = Vector3.ZERO
		wheel_host.add_child(brake)
		applied["calipers"] += 1
	# ---- 尾翼（真件移植） -----------------------------------------------------
	_show_stock_wing(model, car_id)
	_show_welded_wing(model)
	var model_parent := model.get_parent()
	var wing_host := (model_parent as Node3D) if model_parent != null else model
	_remove_tagged(wing_host, TAG + "Wing")
	_remove_tagged(model, TAG + "Wing")
	var wing_donor := Garage.wing_donor_id(car_id)
	# part_tuner 的装配禁用标记：车级禁翼 / 这台车禁装此翼 → 当作原厂尾翼处理
	# （存档里残留的禁用翼索引在这里兜底，游戏 UI 侧已跳过这些选项）
	if not wing_donor.is_empty() and (PartsLibrary.car_no_wing(car_id)
			or PartsLibrary.wing_banned(car_id, wing_donor)):
		wing_donor = ""
	applied["wing"] = false
	if not wing_donor.is_empty():
		_hide_stock_wing(model, car_id)
		_hide_welded_wing(model, car_id)
		# 尺寸/落位由 PartsLibrary 按目标车实测车宽与后备箱上表面高度计算
		# （含 part_offsets.json 的人工微调，part_tuner 工具产出）
		var wing := PartsLibrary.build_wing(wing_donor, model, car_id)
		if wing != null:
			wing.name = TAG + "Wing"
			wing.set_meta(TAG, true)
			# 供体翼网格节点名也是 Spoiler_*，打上 TAG 防止被
			# _hide/_show_stock_wing 误伤（同一模型重复 apply 时的防御）
			for node in wing.find_children("*", "MeshInstance3D", true, false):
				(node as MeshInstance3D).set_meta(TAG, true)
			model.add_child(wing)
			applied["wing"] = true
	# ---- 空间删除（part_tuner 空间格子模式记录的三角形切除，幂等） ----------
	PartsLibrary.apply_mesh_cuts(model, car_id)
	return applied


## 显隐一棵子树里的全部网格（真件替换时藏原厂件 / 恢复原厂时还原）
static func _set_subtree_meshes_visible(root: Node3D, shown: bool) -> void:
	if root == null:
		return
	for node in root.find_children("*", "MeshInstance3D", true, false):
		(node as MeshInstance3D).visible = shown


## 把原厂尾翼/鸭尾网格隐藏（换改装翼时调用）。
## 匹配 = 名字规则（排除后视镜：WingMirror 是倒车镜）∪ 人工选区 add 表，
## 再减去人工选区 del 表 —— add/del 在 part_tuner 工具里 Shift/Alt 点选维护。
static func _hide_stock_wing(model: Node3D, car_id: String = "") -> void:
	var extra_add: Array = []
	var extra_del: Array = []
	if not car_id.is_empty():
		var pk: Dictionary = PartsLibrary.part_offsets(car_id).get("wing_pick", {})
		extra_add = pk.get("add", [])
		extra_del = pk.get("del", [])
	for node in model.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.get_meta(TAG, false):
			continue   # 别把自己装的尾翼藏掉
		var nm := String(mi.name).to_lower()
		var matched := PartsLibrary._name_is_wing(nm)
		var node_name := String(mi.name)
		if not matched and not extra_add.has(node_name):
			continue
		if extra_del.has(node_name):
			continue
		mi.visible = false


static func _show_stock_wing(model: Node3D, car_id: String = "") -> void:
	var extra_add: Array = []
	var extra_del: Array = []
	if not car_id.is_empty():
		var pk: Dictionary = PartsLibrary.part_offsets(car_id).get("wing_pick", {})
		extra_add = pk.get("add", [])
		extra_del = pk.get("del", [])
	for node in model.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.get_meta(TAG, false):
			continue
		var nm := String(mi.name).to_lower()
		var matched := PartsLibrary._name_is_wing(nm)
		var node_name := String(mi.name)
		if not matched and not extra_add.has(node_name):
			continue
		if extra_del.has(node_name):
			continue
		mi.visible = true


## 焊死式原厂尾翼（WELDED_STOCK_WING 表）：把尾翼所在的 surface 从网格里
## 摘除（换色/改件共用一份 MeshInstance，摘面 = 新旧翼不可能同框）；
## 只有一个 surface 的网格直接整节点隐藏。还原时把缓存的原网格挂回去。
static func _hide_welded_wing(model: Node3D, car_id: String) -> void:
	var entries: Array = WELDED_STOCK_WING.get(car_id, [])
	for e in entries:
		if e.size() < 2:
			continue
		var mi := model.find_child(String(e[0]), true, false) as MeshInstance3D
		if mi == null or mi.mesh == null or mi.has_meta(META_SAVED_WING_MESH):
			continue
		var idx := int(e[1])
		if idx < 0 or idx >= mi.mesh.get_surface_count():
			continue
		if mi.mesh.get_surface_count() <= 1:
			mi.set_meta(META_SAVED_WING_MESH, "visible")
			mi.visible = false
			continue
		var stripped := mi.mesh.duplicate() as ArrayMesh
		if stripped == null:
			continue
		stripped.surface_remove(idx)
		mi.set_meta(META_SAVED_WING_MESH, mi.mesh)
		mi.mesh = stripped


static func _show_welded_wing(model: Node3D) -> void:
	for node in model.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if not mi.has_meta(META_SAVED_WING_MESH):
			continue
		var saved: Variant = mi.get_meta(META_SAVED_WING_MESH)
		if typeof(saved) == TYPE_STRING:
			mi.visible = true
		else:
			mi.mesh = saved
		mi.remove_meta(META_SAVED_WING_MESH)


static func _remove_tagged(root: Node3D, prefix: String = TAG) -> void:
	var doomed: Array[Node] = []
	for node in root.get_children():
		if node.name.begins_with(prefix) or (node.has_meta(TAG) and String(node.name).begins_with("Procedural")):
			doomed.append(node)
	for node in doomed:
		root.remove_child(node)
		node.queue_free()
