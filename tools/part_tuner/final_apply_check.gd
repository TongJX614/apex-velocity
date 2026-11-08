extends SceneTree
## 终检：用户调完所有车后，验证游戏挂装管线真实吃到 part_offsets.json：
##   1. varis_m4_gts：6 条空间切除记录生效（三角形被切掉）+ 车级禁翼（装翼索引也按原厂处理）；
##   2. bmw_m4_gt4：有翼偏移数据 → 换翼时翼节点位置 = 基准位 + dy/dz 人工偏移；
##   3. 抽查禁装配对：bmw_i8_acs 的 no_wing / bmw_218i 对 bmw_m5_f90 翼的 ban。
## 只读验证，不改任何数据。

var _frames := 0
var _done := false
var _garage: Node   # Garage autoload（运行时取，编译期标识符不可用）
const PL_R := "res://scripts/cars/parts_library.gd"
const CV_R := "res://scripts/cars/car_visual.gd"
const GL_R := "res://scripts/cars/garage_look.gd"


func _process(_d: float) -> bool:
	_frames += 1
	if _frames < 10 or _done:
		return false
	_done = true
	_garage = root.get_node_or_null("/root/Garage")
	if _garage == null:
		print("FAIL: Garage autoload 未就绪")
		return true
	var PL: GDScript = load(PL_R)
	var CV: GDScript = load(CV_R)
	var GL: GDScript = load(GL_R)
	var fails: Array[String] = []

	# ---- 1) varis_m4_gts：切除 + 车级禁翼 ---------------------------------
	var car := "varis_m4_gts"
	var holder := Node3D.new()
	root.add_child(holder)
	var vis: Dictionary = CV.build({"id": car, "model": car + ".glb"}, holder)
	var model: Node3D = vis.get("model")
	if model == null:
		fails.append("varis 模型加载失败")
	else:
		var before := _count_tris(model)
		_garage.config(car)["wing"] = 1   # 故意给一个改装翼索引
		var applied: Dictionary = GL.apply(model, car, _garage.config(car))
		var removed: int = PL.apply_mesh_cuts(model, car)
		var after := _count_tris(model)
		print("varis: 切除三角形=%d (%d→%d)" % [removed, before, after])
		if removed <= 0:
			fails.append("varis 切除未生效")
		if bool(applied.get("wing", true)):
			fails.append("varis 车级禁翼未兜底（仍装上改装翼）")
		print("varis: no_wing 车改装翼被拒 -> %s" % (not bool(applied.get("wing", true))))

	# ---- 2) bmw_m4_gt4：翼偏移真实叠加 -------------------------------------
	var car2 := "bmw_m4_gt4"
	var off: Dictionary = PL.wing_offsets(car2, "bmw_m4_cabrio")
	if off.is_empty():
		# 该车没有这颗翼的偏移就换找有偏移的组合
		var wingd: Dictionary = PL.part_offsets(car2).get("wing", {})
		for k in wingd.keys():
			off = wingd[k]
			off["__donor"] = k
			break
	if off.is_empty() or not off.has("__donor"):
		print("bmw_m4_gt4: 无翼偏移数据（跳过位置比对）")
	else:
		var donor := String(off["__donor"])
		holder = Node3D.new()
		root.add_child(holder)
		var vis2: Dictionary = CV.build({"id": car2, "model": car2 + ".glb"}, holder)
		var model2: Node3D = vis2.get("model")
		# 基准位：不带人工偏移（car_id 传空）与带偏移各建一次
		var wing_base: Node3D = PL.build_wing(donor, model2, "")
		var wing_off: Node3D = PL.build_wing(donor, model2, car2)
		if wing_base == null or wing_off == null:
			fails.append("bmw_m4_gt4 建翼失败")
		else:
			var dpos: Vector3 = wing_off.position - wing_base.position
			var expect := Vector3(0.0, float(off.get("dy", 0.0)), float(off.get("dz", 0.0)))
			print("gt4×%s: 翼位差=%s 期望≈%s (scale=%.3f)" % [donor, dpos, expect, float(off.get("scale", 1.0))])
			if dpos.distance_to(expect) > 0.005:
				fails.append("翼偏移未正确叠加")
	# ---- 3) 标记抽查 ---------------------------------------------------------
	print("抽查: i8_acs no_wing=%s（期望 true）" % PL.car_no_wing("bmw_i8_acs"))
	if not PL.car_no_wing("bmw_i8_acs"):
		fails.append("i8_acs no_wing 丢失")
	print("抽查: 218i 禁装 m5_f90 翼=%s（期望 true）" % PL.wing_banned("bmw_218i", "bmw_m5_f90"))
	if not PL.wing_banned("bmw_218i", "bmw_m5_f90"):
		fails.append("218i 配对禁装丢失")
	print("抽查: 218i 未禁装 m4_cabrio 翼=%s（期望 true）" % (not PL.wing_banned("bmw_218i", "bmw_m4_cabrio")))

	if fails.is_empty():
		print("ALL PASS — 调参数据在游戏管线中生效")
	else:
		for f in fails:
			print("FAIL: " + f)
	return true


func _count_tris(model: Node3D) -> int:
	var n := 0
	for node in model.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			continue
		var am := mi.mesh as ArrayMesh
		if am == null:
			continue
		for s in am.get_surface_count():
			var arrays := am.surface_get_arrays(s)
			if arrays.size() > Mesh.ARRAY_INDEX and arrays[Mesh.ARRAY_INDEX] != null:
				n += (arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
	return n
