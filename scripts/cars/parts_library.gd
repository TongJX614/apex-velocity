class_name PartsLibrary
extends RefCounted
## 真件改装库（v0.55）：
## 直接从每台车的 GLB 原模型里抠出「原厂轮毂 + 轮胎」与「尾翼」的真实建模网格，
## 作为可互换改装件 —— 任何一台车都可以装上其它车款的原厂真件
## （例如把比亚迪海豚的轮毂装到 BMW M3 上），替换掉程序化画的辐条。
##
## 工作原理：
##   1. 目录扫描：只解析 GLB 的 JSON 头（不导入网格），判断每台车
##      Spin_Wheel_FL 下是否挂了真实轮毂/轮胎网格（可作轮毂供体）、
##      是否存在 Spoiler/Wing 网格（可作尾翼供体）。
##   2. 供体模板：按需 load 供体 GLB → 抠出 Spin_Wheel_FL / Spoiler 网格 →
##      复制并烘到供体局部坐标 → 平移到几何中心（旋转枢轴=轮心）→ 缓存模板。
##   3. 装车：按目标车实测轮径/胎宽缩放（X=胎宽、YZ=轮径），轮毂色/轮胎色
##      通过 albedo 乘色染色（保留原贴图细节）；尾翼按供体在原车上的
##      高度/纵向比例，等比映射到目标车尾部。

const MODELS_DIR := "res://assets/cars/models"
const GLB_JSON_MAGIC := 0x4E4F534A   # 'JSON' chunk type（小端）
const OFFSETS_FILE := "res://data/part_offsets.json"   # 人工微调偏移（part_tuner 工具写）

static var _scanned := false
static var _glb_docs: Dictionary = {}     # car_id -> glTF JSON Dictionary（只解析头）
static var _wheel_donors: Array = []      # 轮毂可抠的车 id（GameData 顺序）
static var _wing_donors: Array = []       # 有尾翼网格的车 id
static var _wheel_tpl: Dictionary = {}    # donor_id -> {node, radius, width}
static var _wing_tpl: Dictionary = {}     # donor_id -> {node, width, height, depth, fz, rel}
static var _offsets: Dictionary = {}      # car_id -> {wing/wheels: {dy, dz}}
static var _offsets_loaded := false


# ---------------------------------------------------------------------------
# 人工微调偏移（part_tuner 工具场景产出，游戏挂装时自动生效）
# ---------------------------------------------------------------------------

## 读某台车的人工偏移表 {wing: {dy,dz}, wheels: {dy,dz}}，单位米（模型局部）。
static func part_offsets(car_id: String) -> Dictionary:
	_ensure_offsets()
	return _offsets.get(car_id, {})


## 更新某台车某部件的偏移（只改内存缓存；write=true 时同时写盘）。
static func set_part_offset(car_id: String, part: String, dy: float, dz: float,
		write: bool = false) -> void:
	_ensure_offsets()
	var entry: Dictionary = _offsets.get(car_id, {})
	var p: Dictionary = entry.get(part, {})
	p["dy"] = snappedf(dy, 0.001)
	p["dz"] = snappedf(dz, 0.001)
	entry[part] = p
	_offsets[car_id] = entry
	if write:
		save_offsets()


## 读某台车某个供体翼的人工调整 {dy, dz, scale}（每个翼位独立保存，互不影响）。
static func wing_offsets(car_id: String, donor_id: String) -> Dictionary:
	_ensure_offsets()
	var wing: Dictionary = _offsets.get(car_id, {}).get("wing", {})
	return wing.get(donor_id, {})


## 写某台车某个供体翼的 dy/dz（只改内存；write=true 同时写盘）。
static func set_wing_offset(car_id: String, donor_id: String, dy: float, dz: float,
		write: bool = false) -> void:
	_ensure_offsets()
	var entry: Dictionary = _offsets.get(car_id, {})
	var wing: Dictionary = entry.get("wing", {})
	var p: Dictionary = wing.get(donor_id, {})
	p["dy"] = snappedf(dy, 0.001)
	p["dz"] = snappedf(dz, 0.001)
	wing[donor_id] = p
	entry["wing"] = wing
	_offsets[car_id] = entry
	if write:
		save_offsets()


## 写某台车某个供体翼的缩放乘数（1.0=原始；范围 0.5~2.0）。
static func set_wing_scale(car_id: String, donor_id: String, scale_v: float,
		write: bool = false) -> void:
	_ensure_offsets()
	var entry: Dictionary = _offsets.get(car_id, {})
	var wing: Dictionary = entry.get("wing", {})
	var p: Dictionary = wing.get(donor_id, {})
	p["scale"] = snappedf(clampf(scale_v, 0.5, 2.0), 0.001)
	wing[donor_id] = p
	entry["wing"] = wing
	_offsets[car_id] = entry
	if write:
		save_offsets()


## 读某台车某个供体轮的人工偏移 {dy, dz}（每个轮位独立保存；兼容旧版整组一份）。
static func wheel_offsets(car_id: String, donor_id: String) -> Dictionary:
	_ensure_offsets()
	var wheels: Dictionary = _offsets.get(car_id, {}).get("wheels", {})
	if wheels.has(donor_id):
		return wheels.get(donor_id, {})
	if wheels.has("dy") or wheels.has("dz"):
		return wheels   # 旧版：无分桶的整组数据
	return {}


## 写某台车某个供体轮的 dy/dz（只改内存；write=true 同时写盘）。
static func set_wheel_offset(car_id: String, donor_id: String, dy: float, dz: float,
		write: bool = false) -> void:
	_ensure_offsets()
	var entry: Dictionary = _offsets.get(car_id, {})
	var wheels: Dictionary = entry.get("wheels", {})
	var p: Dictionary = wheels.get(donor_id, {})
	p["dy"] = snappedf(dy, 0.001)
	p["dz"] = snappedf(dz, 0.001)
	wheels[donor_id] = p
	entry["wheels"] = wheels
	_offsets[car_id] = entry
	if write:
		save_offsets()


## 读某台车某个供体轮某根车轴（"front"/"rear"）的人工偏移 {dx, dy, dz}。
## dx = 沿车轴向外为正（左右轮自动镜像），dy 上下，dz 前后；单位模型局部米。
## 兼容两级旧数据：{donor:{dy,dz}} 分桶 / 无分桶整组 {dy,dz} —— 旧数据前后轴共用。
static func wheel_axle_offsets(car_id: String, donor_id: String, axle: String) -> Dictionary:
	var base := wheel_offsets(car_id, donor_id)
	if base.has("front") or base.has("rear"):
		return base.get(axle, {})
	return base   # 旧版数据：不分轴，前后共用


## 写某台车某个供体轮某根车轴的 dx/dy/dz（只改内存；write=true 同时写盘）。
static func set_wheel_axle_offset(car_id: String, donor_id: String, axle: String,
		dx: float, dy: float, dz: float, write: bool = false) -> void:
	_ensure_offsets()
	var entry: Dictionary = _offsets.get(car_id, {})
	var wheels: Dictionary = entry.get("wheels", {})
	var donor_d: Dictionary = wheels.get(donor_id, {})
	var p: Dictionary = donor_d.get(axle, {})
	p["dx"] = snappedf(dx, 0.001)
	p["dy"] = snappedf(dy, 0.001)
	p["dz"] = snappedf(dz, 0.001)
	donor_d[axle] = p
	wheels[donor_id] = donor_d
	entry["wheels"] = wheels
	_offsets[car_id] = entry
	if write:
		save_offsets()


## 归零某台车某个供体轮某根车轴的人工偏移。
static func clear_wheel_axle_offset(car_id: String, donor_id: String, axle: String,
		write: bool = false) -> void:
	set_wheel_axle_offset(car_id, donor_id, axle, 0.0, 0.0, 0.0, write)


# ---------------------------------------------------------------------------
# 空间删除（part_tuner 空间格子模式）：按「节点路径 + 面 + 三角形序号」记录
# 用户在空间格子里圈中并确认删除的三角形，模型加载后运行时切除。
# 三角形序号 = 该 surface 索引数组里的第几个三角形（对导入结果稳定）。
# 所有 cut 都针对「未切除的原始网格」记录；应用时一次性聚合切除，故多条 cut
# 之间序号不会互相移位。
# ---------------------------------------------------------------------------

## 某台车的全部切除记录
static func mesh_cuts(car_id: String) -> Array:
	_ensure_offsets()
	return (_offsets.get(car_id, {}) as Dictionary).get("cuts", [])


## 追加一条切除记录（只改内存；随 Enter 保存写盘）
static func add_mesh_cut(car_id: String, node_path: String, surf: int, tris: Array) -> void:
	_ensure_offsets()
	var entry: Dictionary = _offsets.get(car_id, {})
	var cuts: Array = entry.get("cuts", [])
	cuts.append({"node": node_path, "surf": surf, "tris": tris})
	entry["cuts"] = cuts
	_offsets[car_id] = entry


## 撤销最后一条切除记录（返回是否撤销了东西）
static func pop_last_mesh_cut(car_id: String) -> bool:
	_ensure_offsets()
	var entry: Dictionary = _offsets.get(car_id, {})
	var cuts: Array = entry.get("cuts", [])
	if cuts.is_empty():
		return false
	cuts.pop_back()
	entry["cuts"] = cuts
	_offsets[car_id] = entry
	return true


## 把记录的三角形从模型上切除（幂等：同一模型实例只切一次）。
## 返回切除的三角形总数。对运行时新建的节点（供体翼/轮），节点路径不存在则跳过。
static func apply_mesh_cuts(model: Node3D, car_id: String) -> int:
	if model == null or model.has_meta("ProceduralCuts") or car_id.is_empty():
		return 0
	var cuts := mesh_cuts(car_id)
	if cuts.is_empty():
		return 0
	# 按 节点路径 -> surface -> 序号集合 聚合
	var per_mesh: Dictionary = {}
	for c in cuts:
		var np := String(c.get("node", ""))
		var per_surf: Dictionary = per_mesh.get(np, {})
		var s := int(c.get("surf", 0))
		var lst: Array = per_surf.get(s, [])
		lst.append_array(c.get("tris", []))
		per_surf[s] = lst
		per_mesh[np] = per_surf
	var removed := 0
	for np in per_mesh:
		var mi := model.get_node_or_null(NodePath(np)) as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		# 复制网格资源再改，防共享（Body_06/07 这类副本网格各自独立切除）
		mi.mesh = mi.mesh.duplicate()
		var am := mi.mesh as ArrayMesh
		if am == null:
			continue
		var per_surf: Dictionary = per_mesh[np]
		var new_mesh := ArrayMesh.new()
		for s in am.get_surface_count():
			var arrays := am.surface_get_arrays(s)
			if arrays.size() > Mesh.ARRAY_INDEX and arrays[Mesh.ARRAY_INDEX] != null \
					and per_surf.has(s):
				var kill := {}
				for t in per_surf[s]:
					kill[int(t)] = true
				var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
				var ntri := idx.size() / 3
				var keep := PackedInt32Array()
				for k in ntri:
					if not kill.has(k):
						keep.append_array(idx.slice(k * 3, k * 3 + 3))
				removed += ntri - keep.size() / 3
				arrays[Mesh.ARRAY_INDEX] = keep
			new_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			new_mesh.surface_set_material(new_mesh.get_surface_count() - 1,
				am.surface_get_material(s))
		mi.mesh = new_mesh
	model.set_meta("ProceduralCuts", true)
	return removed


## 把内存里的偏移缓存写盘（part_tuner 的保存按钮调用）。
static func save_offsets() -> void:
	_ensure_offsets()
	var f := FileAccess.open(OFFSETS_FILE, FileAccess.WRITE)
	if f == null:
		push_error("PartsLibrary: 无法写入 " + OFFSETS_FILE)
		return
	f.store_string(JSON.stringify(_offsets, "\t"))
	f.close()


static func _ensure_offsets() -> void:
	if _offsets_loaded:
		return
	_offsets_loaded = true
	if not FileAccess.file_exists(OFFSETS_FILE):
		return
	var f := FileAccess.open(OFFSETS_FILE, FileAccess.READ)
	if f == null:
		return
	var parsed = JSON.parse_string(f.get_as_text())
	if typeof(parsed) == TYPE_DICTIONARY:
		_offsets = parsed


# ---------------------------------------------------------------------------
# 选区人工增删（part_tuner 里 Shift/Alt 点选产出，游戏隐藏旧翼按同表执行）
# ---------------------------------------------------------------------------

## 读某台车某组的人工选区 {add: [节点名...], del: [节点名...]}。
## add = 强制加入该组（规则漏选时补上）；del = 强制排除（规则多选时剔除）。
static func pick_lists(car_id: String, group: String) -> Dictionary:
	return part_offsets(car_id).get(group + "_pick", {"add": [], "del": []})


## 增/删一条选区（只改内存缓存；write=true 同时写盘）。
static func pick_edit(car_id: String, group: String, node_name: String, add: bool,
		write: bool = false) -> void:
	_ensure_offsets()
	var entry: Dictionary = _offsets.get(car_id, {})
	var key := group + "_pick"
	var pk: Dictionary = entry.get(key, {})
	var addl: Array = pk.get("add", [])
	var dell: Array = pk.get("del", [])
	if add:
		dell.erase(node_name)
		if not addl.has(node_name):
			addl.append(node_name)
	else:
		addl.erase(node_name)
		if not dell.has(node_name):
			dell.append(node_name)
	pk["add"] = addl
	pk["del"] = dell
	entry[key] = pk
	_offsets[car_id] = entry
	if write:
		save_offsets()


## 名字规则里的翼匹配（排除后视镜：WingMirror/DoorMirror 是倒车镜不是尾翼）
static func _name_is_wing(nm_lower: String) -> bool:
	if nm_lower.contains("mirror") or nm_lower.contains("后视镜"):
		return false
	return nm_lower.contains("spoiler") or nm_lower.contains("wing") \
		or nm_lower.contains("ducktail") or nm_lower.contains("尾翼")


# ---------------------------------------------------------------------------
# 调参进度（part_tuner 车辆清单用）：done = 人工标记「已完成」
# ---------------------------------------------------------------------------

static func set_car_done(car_id: String, done: bool, write: bool = true) -> void:
	_ensure_offsets()
	var entry: Dictionary = _offsets.get(car_id, {})
	entry["done"] = done
	_offsets[car_id] = entry
	if write:
		save_offsets()


static func car_done(car_id: String) -> bool:
	return bool(part_offsets(car_id).get("done", false))


# ---------------------------------------------------------------------------
# 装配禁用标记（part_tuner 里标记，游戏选件时生效）：
#   · 车级 no_wing     = 这台车在游戏里选不了尾翼（保持原厂尾翼）；
#   · 配对禁装 wing_bans = 这台车不能装配某个指定供体翼（其它车不受影响）。
# 数据都存 part_offsets.json（车级 "no_wing" 字段 / "wing_bans" 供体 id 数组）。
# ---------------------------------------------------------------------------

## 车：游戏内禁选尾翼（立即写盘，防误关丢标记）
static func set_car_no_wing(car_id: String, on: bool, write: bool = true) -> void:
	_ensure_offsets()
	var entry: Dictionary = _offsets.get(car_id, {})
	entry["no_wing"] = on
	_offsets[car_id] = entry
	if write:
		save_offsets()


static func car_no_wing(car_id: String) -> bool:
	return bool(part_offsets(car_id).get("no_wing", false))


## 车+翼配对禁装：car_id 这台车在游戏里装不了 donor_id 这颗翼（立即写盘）
static func set_wing_banned(car_id: String, donor_id: String, banned: bool,
		write: bool = true) -> void:
	_ensure_offsets()
	var entry: Dictionary = _offsets.get(car_id, {})
	var lst: Array = entry.get("wing_bans", [])
	var changed := false
	if banned and not lst.has(donor_id):
		lst.append(donor_id)
		changed = true
	elif not banned and lst.has(donor_id):
		lst.erase(donor_id)
		changed = true
	if changed:
		entry["wing_bans"] = lst
		_offsets[car_id] = entry
		if write:
			save_offsets()


## 读：car_id 这台车是否被禁装 donor_id 这颗翼
static func wing_banned(car_id: String, donor_id: String) -> bool:
	if donor_id.is_empty():
		return false
	return (part_offsets(car_id).get("wing_bans", []) as Array).has(donor_id)


## 该车是否调过任何东西（翼/轮偏移、缩放、选区增删）——用于清单上的黄点提示
static func car_has_tuning(car_id: String) -> bool:
	var e := part_offsets(car_id)
	if bool(e.get("no_wing", false)):
		return true
	if (e.get("wing_bans", []) as Array).size() > 0:
		return true
	for k in ["wing", "wheels"]:
		var v: Variant = e.get(k, {})
		if typeof(v) == TYPE_DICTIONARY and not (v as Dictionary).is_empty():
			return true
	for k in ["wing_pick", "wheels_pick"]:
		var pk: Dictionary = e.get(k, {})
		if (pk.get("add", []) as Array).size() > 0 or (pk.get("del", []) as Array).size() > 0:
			return true
	return false


# ---------------------------------------------------------------------------
# 目录（GLB JSON 头扫描）
# ---------------------------------------------------------------------------

static func _glb_doc(car_id: String) -> Dictionary:
	if _glb_docs.has(car_id):
		return _glb_docs[car_id]
	var doc := {}
	var model_file := String(GameData.car(car_id).get("model", ""))
	if model_file.is_empty():
		model_file = car_id + ".glb"
	var f := FileAccess.open(MODELS_DIR.path_join(model_file), FileAccess.READ)
	if f != null:
		f.get_32()   # magic
		f.get_32()   # version
		f.get_32()   # total length
		var chunk_len := f.get_32()
		var chunk_type := f.get_32()
		if chunk_type == GLB_JSON_MAGIC:
			var parsed = JSON.parse_string(f.get_buffer(chunk_len).get_string_from_utf8())
			if typeof(parsed) == TYPE_DICTIONARY:
				doc = parsed
		f.close()
	_glb_docs[car_id] = doc
	return doc


static func _ensure_catalog() -> void:
	if _scanned:
		return
	_scanned = true
	if GameData == null:
		return
	for spec in GameData.cars_specs:
		var car_id := String(spec.get("id", ""))
		if car_id.is_empty():
			continue
		var doc := _glb_doc(car_id)
		if doc.is_empty():
			continue
		var wheel_ok := false
		var wing_ok := false
		for n in doc.get("nodes", []):
			if typeof(n) != TYPE_DICTIONARY:
				continue
			var nm := String(n.get("name", "")).to_lower()
			if not wheel_ok and nm.contains("spin_wheel_fl") \
					and (n.get("children", []) as Array).size() > 0:
				wheel_ok = true   # Spin_Wheel_FL 下挂了真实轮毂/轮胎网格
			if not wing_ok and n.has("mesh"):
				if nm.contains("spoiler") or (nm.contains("wing") and not nm.contains("wingmount")):
					wing_ok = _name_is_wing(nm)   # 外层已限 spoiler/wing，这里再排掉后视镜
		if wheel_ok:
			_wheel_donors.append(car_id)
		if wing_ok:
			_wing_donors.append(car_id)


static func wheel_donor_ids() -> Array:
	_ensure_catalog()
	return _wheel_donors


static func wing_donor_ids() -> Array:
	_ensure_catalog()
	return _wing_donors


static func wheel_option_count() -> int:
	return maxi(1, wheel_donor_ids().size() + 1)   # 0=原厂造型，之后每台车一个真件


static func wing_option_count() -> int:
	return maxi(1, wing_donor_ids().size() + 1)


## index -> 供体车 id（"" = 原厂 / 本车原件）
static func wheel_donor_of(index: int) -> String:
	var donors := wheel_donor_ids()
	if index <= 0 or donors.is_empty():
		return ""
	return String(donors[clampi(index - 1, 0, donors.size() - 1)])


static func wing_donor_of(index: int) -> String:
	var donors := wing_donor_ids()
	if index <= 0 or donors.is_empty():
		return ""
	return String(donors[clampi(index - 1, 0, donors.size() - 1)])


static func wheel_option_entry(index: int) -> Dictionary:
	if wheel_donor_of(index).is_empty():
		return {"id": "factory", "name": "原厂造型", "en": "FACTORY"}
	var donor := wheel_donor_of(index)
	var spec := GameData.car(donor)
	return {
		"id": "donor:" + donor,
		"name": String(spec.get("name", donor)),
		"en": "DONOR WHEELS",
	}


static func wing_option_entry(index: int) -> Dictionary:
	if wing_donor_of(index).is_empty():
		return {"id": "stock", "name": "原厂尾翼", "en": "FACTORY"}
	var donor := wing_donor_of(index)
	var spec := GameData.car(donor)
	return {
		"id": "donor:" + donor,
		"name": String(spec.get("name", donor)),
		"en": "DONOR WING",
	}


# ---------------------------------------------------------------------------
# 轮毂 + 轮胎真件
# ---------------------------------------------------------------------------

static func _model_file(car_id: String) -> String:
	var model_file := String(GameData.car(car_id).get("model", ""))
	if model_file.is_empty():
		model_file = car_id + ".glb"
	return MODELS_DIR.path_join(model_file)


static func _instantiate(car_id: String) -> Node3D:
	var res_path := _model_file(car_id)
	if not ResourceLoader.exists(res_path):
		return null
	var packed := load(res_path) as PackedScene
	if packed == null:
		return null
	return packed.instantiate() as Node3D


## 抠出供体 FL 轮（轮毂+轮胎网格），几何中心移到原点。返回
## {node, radius, width}；供体不可抠时返回 {}。
static func _wheel_template(donor_id: String) -> Dictionary:
	if _wheel_tpl.has(donor_id):
		return _wheel_tpl[donor_id]
	var out := {}
	var inst := _instantiate(donor_id)
	if inst != null:
		var spin := inst.find_child("Spin_Wheel_FL", true, false) as Node3D
		if spin != null:
			var wrapper := Node3D.new()
			wrapper.name = "DonorWheelTemplate"
			var inner := Node3D.new()
			wrapper.add_child(inner)
			for node in spin.find_children("*", "MeshInstance3D", true, false):
				var mi := node as MeshInstance3D
				if mi.mesh == null:
					continue
				var copy := mi.duplicate() as MeshInstance3D
				copy.transform = _relative_to(mi, spin)   # 烘到轮局部坐标
				inner.add_child(copy)
			var full := _subtree_aabb(wrapper)
			if full.size.y > 0.01 and full.size.z > 0.01:
				var tyre := _tyre_box(wrapper)
				var rbox := tyre if tyre.size.y > 0.01 else full
				var radius := maxf(rbox.size.y, rbox.size.z) * 0.5
				var width := rbox.size.x if rbox.size.x > 0.02 else full.size.x
				if radius > 0.05:
					inner.position = -full.get_center()   # 旋转枢轴 = 轮心
					out = {"node": wrapper, "radius": radius, "width": width}
		inst.free()
	_wheel_tpl[donor_id] = out
	return out


## 生成装到目标车上的供体轮（按目标车实测轮径/胎宽缩放 + 染色）。
static func build_wheel(donor_id: String, host_radius: float, host_width: float,
		rim_color: Color, tire_tint: Color) -> Node3D:
	var tpl := _wheel_template(donor_id)
	if tpl.is_empty():
		return null
	var node := (tpl["node"] as Node3D).duplicate() as Node3D
	node.name = "DonorWheel"
	var sy := clampf(host_radius / maxf(float(tpl["radius"]), 0.05), 0.35, 2.8)
	var sx := clampf(host_width / maxf(float(tpl["width"]), 0.02), 0.40, 2.5)
	node.scale = Vector3(sx, sy, sy)
	_tint_wheel(node, rim_color, tire_tint)
	return node


## 按节点名分类染色：Tyre_* 乘轮胎色，Rim/Wheel_* 乘轮毂色（保留原贴图）。
static func _tint_wheel(root: Node3D, rim_color: Color, tire_tint: Color) -> void:
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			continue
		var nm := String(mi.name).to_lower()
		var is_tyre := nm.contains("tyre") or nm.contains("tire") or nm.contains("轮胎")
		var is_rim := nm.contains("rim") or nm.contains("spoke") or nm.contains("轮毂") \
			or (nm.contains("wheel") and not is_tyre)
		if not is_tyre and not is_rim:
			continue
		var tint := tire_tint if is_tyre else rim_color
		if tint.a <= 0.001:
			continue
		for s in mi.mesh.get_surface_count():
			var mat := mi.get_active_material(s) as StandardMaterial3D
			if mat == null:
				continue
			var dup := mat.duplicate() as StandardMaterial3D
			var base := dup.albedo_color
			# 白底轮胎贴图修正（与 CarVisual 同规则）
			if is_tyre and dup.albedo_texture != null \
					and base.r > 0.75 and base.g > 0.75 and base.b > 0.75:
				base = Color(0.045, 0.047, 0.052)
			dup.albedo_color = Color(base.r * tint.r, base.g * tint.g, base.b * tint.b, base.a)
			if is_rim:
				dup.metallic = clampf(dup.metallic + 0.25, 0.0, 1.0)
				dup.roughness = clampf(dup.roughness, 0.08, 0.45)
			mi.set_surface_override_material(s, dup)


# ---------------------------------------------------------------------------
# 尾翼真件
# ---------------------------------------------------------------------------

## 抠出供体整套尾翼组（翼面 + WingMount 支架），烘到供体模型局部坐标并居中。
## 返回 {node, width, height, depth, fz}：fz 是翼组中心在供体车身 z 轴上的占比，
## 用于判断该导出约定的车尾在 +z 还是 -z 侧（全部车模同一管线导出）。
static func _wing_template(donor_id: String) -> Dictionary:
	if _wing_tpl.has(donor_id):
		return _wing_tpl[donor_id]
	var out := {}
	var inst := _instantiate(donor_id)
	if inst != null:
		var car_box := _subtree_aabb(inst)
		var meshes: Array[MeshInstance3D] = []
		for node in inst.find_children("*", "MeshInstance3D", true, false):
			var mi := node as MeshInstance3D
			if mi.mesh == null or not mi.visible:
				continue
			var nm := String(mi.name).to_lower()
			# WingMount 是翼面支架，属于翼组的一部分（没有它翼会悬空没腿）
			if _name_is_wing(nm) or nm.contains("wingmount"):
				meshes.append(mi)
		if not meshes.is_empty() and car_box.size.y > 0.5:
			var wrapper := Node3D.new()
			wrapper.name = "DonorWingTemplate"
			var inner := Node3D.new()
			wrapper.add_child(inner)
			for mi in meshes:
				var copy := mi.duplicate() as MeshInstance3D
				copy.transform = _relative_to(mi, inst)   # 烘到车模局部坐标
				inner.add_child(copy)
			var wing_box := _subtree_aabb(wrapper)
			if wing_box.size.x > 0.05:
				inner.position = -wing_box.get_center()
				# 供体原车上「翼底相对行李箱面」的嵌入量（负=埋进盖板，正=架在上面）。
				# 用与装车时相同的窄带测量（立柱实际落点），装车时复现这个关系。
				var rear_is_min_d := float((wing_box.get_center().z - car_box.position.z) / car_box.size.z) < 0.5
				var donor_deck := _deck_height(inst, car_box, rear_is_min_d,
					wing_box.get_center().z, maxf(0.10, wing_box.size.z * 0.45))
				var rel := 0.015
				if donor_deck > 0.0:
					rel = wing_box.position.y - donor_deck
				out = {
					"node": wrapper,
					"width": wing_box.size.x,
					"height": wing_box.size.y,
					"depth": wing_box.size.z,
					"fz": (wing_box.get_center().z - car_box.position.z) / car_box.size.z,
					"rel": clampf(rel, -0.25, 0.12),
				}
		inst.free()
	_wing_tpl[donor_id] = out
	return out


## 实测行李箱盖/尾门上表面高度（指定 z 窄带的局部表面）。
## 旧两版教训：
##   ① 「车尾带内最高顶点」会把溜背车后挡风玻璃顶当成行李箱面 → 翼架在玻璃上方；
##   ② 「整个车尾 12% 带取 97 分位」在斜面盖板上取到最前缘高点 → 立柱落点处悬空。
## 新版在**翼柱实际落点的 z 窄带 + 车宽中央 70% x 带**内测表面高度：
##   - 只统计法线朝上的顶点（ny>0.82，盖板/尾门顶是近水平面）；
##   - x 收窄到中央带，排除两侧翼子板上沿的干扰；
##   - 取 90 分位滤掉盖板棱线/小凸起。
## 无有效顶点时返回 -1（调用方逐级放宽重试）。
static func _deck_height(model: Node3D, box: AABB, rear_is_min: bool,
		z_center: float, band: float) -> float:
	var z_lo: float
	var z_hi: float
	if rear_is_min:
		z_lo = box.position.z
		z_hi = minf(z_center + band, box.position.z + box.size.z * 0.45)
	else:
		z_lo = maxf(z_center - band, box.position.z + box.size.z * 0.55)
		z_hi = box.position.z + box.size.z
	var x_lo := box.get_center().x - box.size.x * 0.35
	var x_hi := box.get_center().x + box.size.x * 0.35
	var ys: Array[float] = []
	for child in model.find_children("*", "MeshInstance3D", true, false):
		var mi := child as MeshInstance3D
		if mi.mesh == null or not mi.visible:
			continue
		var nm := String(mi.name).to_lower()
		# 原车尾翼不算行李箱面（装新翼时会被藏掉）
		if _name_is_wing(nm) or nm.contains("wingmount"):
			continue
		var rel := _relative_to(mi, model)
		var mabb: AABB = rel * mi.mesh.get_aabb()
		# 预剪枝：整块网格都在带外就跳过
		if mabb.position.z > z_hi or mabb.position.z + mabb.size.z < z_lo:
			continue
		for s in mi.mesh.get_surface_count():
			var arrays := mi.mesh.surface_get_arrays(s)
			if arrays.size() <= Mesh.ARRAY_VERTEX or arrays[Mesh.ARRAY_VERTEX] == null:
				continue
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var norms: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL] \
					if arrays.size() > Mesh.ARRAY_NORMAL else PackedVector3Array()
			for i in verts.size():
				var w := rel * verts[i]
				if w.z < z_lo or w.z > z_hi or w.x < x_lo or w.x > x_hi:
					continue
				# 只收朝上的面（行李箱盖/尾门顶）；无法线数据的网格退化收顶点
				if norms.size() > i:
					var n := (rel.basis * norms[i]).normalized()
					if n.y < 0.82:
						continue
				elif w.y < box.position.y + box.size.y * 0.5:
					continue
				ys.append(w.y)
	if ys.is_empty():
		return -1.0
	ys.sort()
	var deck: float = ys[mini(ys.size() - 1, int(ys.size() * 0.90))]
	return clampf(deck, box.position.y + box.size.y * 0.30, box.position.y + box.size.y * 0.95)


## 兼容入口：车尾 12% 带的行李箱面高度（探针/诊断用）
static func _rear_deck_y(model: Node3D, box: AABB, rear_is_min: bool) -> float:
	var rear_edge := box.position.z if rear_is_min else box.position.z + box.size.z
	var frac := box.size.z * 0.12
	var center := rear_edge + (frac * 0.5 if rear_is_min else -frac * 0.5)
	var deck := _deck_height(model, box, rear_is_min, center, frac * 0.5)
	if deck < 0.0:
		return box.position.y + box.size.y * 0.72
	return deck


## 生成装到目标车尾的供体尾翼：
##   · 尺寸按目标车实测车宽等比缩放（保留供体翼型/攻角/支架高度）；
##   · z：纵向贴近车尾边缘往里收一点；
##   · y：在翼柱落点的 z 窄带实测行李箱面高度，翼底 = 局部表面 - 供体嵌入量
##     （供体原车上翼底与行李箱面的关系原样复现 → 立柱真正落在盖板上）；
##   · car_id 非空时叠加 part_offsets.json 里的人工微调（part_tuner 工具产出）。
static func build_wing(donor_id: String, host_model: Node3D, car_id: String = "") -> Node3D:
	var tpl := _wing_template(donor_id)
	if tpl.is_empty() or host_model == null:
		return null
	var box := _subtree_aabb(host_model)
	if box.size.y <= 0.5 or box.size.z <= 1.0:
		return null
	var node := (tpl["node"] as Node3D).duplicate() as Node3D
	node.name = "DonorWing"
	var w := maxf(float(tpl["width"]), 0.05)
	var h := maxf(float(tpl["height"]), 0.02)
	var d := maxf(float(tpl["depth"]), 0.02)
	var scale := clampf(box.size.x * 0.86 / w, 0.5, 2.0)
	node.scale = Vector3.ONE * scale
	# 车尾在模型局部坐标的哪一侧：用供体翼组中心的 z 占比判断（同管线导出）
	var rear_is_min := float(tpl["fz"]) < 0.5
	var sign_z := -1.0 if rear_is_min else 1.0
	var rear_edge := box.position.z if rear_is_min else box.position.z + box.size.z
	var d_s := d * scale
	var wing_cz := rear_edge - sign_z * (d_s * 0.5 + maxf(0.05, box.size.z * 0.015))
	# 在翼柱落点窄带测行李箱面；逐步放宽带宽防斜面/玻璃区无顶点。
	# 规则：立柱底（=翼组 AABB 底，8 个供体实测立柱底与 AABB 底差≤7mm）
	# 直接落在窄带实测面上，再整体下压 0.03 保证贴合不悬空。
	# 不搬运供体的嵌入量：各车盖板曲面形状不同，供体嵌入量是供体车身
	# 特有的形状差，搬到异体车上会变成抬高（悬空）。
	var deck_y := -1.0
	var band := maxf(0.07, d_s * 0.30)
	for mult in [1.0, 2.0, 4.0]:
		deck_y = _deck_height(host_model, box, rear_is_min, wing_cz, band * mult)
		if deck_y >= 0.0:
			break
	if deck_y < 0.0:
		deck_y = _rear_deck_y(host_model, box, rear_is_min)
	var bottom_y := clampf(deck_y - 0.03,
		box.position.y + box.size.y * 0.30, box.position.y + box.size.y * 0.97)
	# 人工微调（part_tuner 工具），按「车 + 供体翼」独立保存：
	#   scale 缩放乘数（以翼底为锚，放大不埋进盖板）、dy 上下 / dz 前后（模型局部米）
	var scale_f := scale
	var off := {}
	if not car_id.is_empty():
		off = wing_offsets(car_id, donor_id)
		scale_f = scale * clampf(float(off.get("scale", 1.0)), 0.5, 2.0)
	node.scale = Vector3.ONE * scale_f
	node.position = Vector3(
		box.get_center().x,
		bottom_y + h * scale_f * 0.5,
		wing_cz)
	if not off.is_empty():
		node.position += Vector3(0.0, float(off.get("dy", 0.0)), float(off.get("dz", 0.0)))
	return node


# ---------------------------------------------------------------------------
# 几何工具（与 CarVisual 同规则）
# ---------------------------------------------------------------------------

static func _relative_to(node: Node, ancestor: Node) -> Transform3D:
	var rel := Transform3D.IDENTITY
	var cur: Node = node
	while cur != null and cur != ancestor:
		if cur is Node3D:
			rel = (cur as Node3D).transform * rel
		cur = cur.get_parent()
	return rel


static func _subtree_aabb(node: Node3D) -> AABB:
	var box := AABB()
	var first := true
	for child in node.find_children("*", "MeshInstance3D", true, false):
		var mi := child as MeshInstance3D
		if mi.mesh == null:
			continue
		var rel := _relative_to(mi, node)
		var aabb: AABB = rel * mi.mesh.get_aabb()
		if first:
			box = aabb
			first = false
		else:
			box = box.merge(aabb)
	return box


static func _tyre_box(root: Node3D) -> AABB:
	var box := AABB()
	var first := true
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			continue
		var nm := String(mi.name).to_lower()
		if not (nm.contains("tyre") or nm.contains("tire") or nm.contains("轮胎")):
			continue
		var rel := _relative_to(mi, root)
		var aabb: AABB = rel * mi.mesh.get_aabb()
		if first:
			box = aabb
			first = false
		else:
			box = box.merge(aabb)
	return box
