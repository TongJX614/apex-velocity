extends SceneTree
var _f := 0
func _process(_d: float) -> bool:
	_f += 1
	if _f < 10:
		return false
	var PL: GDScript = load("res://scripts/cars/parts_library.gd")
	var CV: GDScript = load("res://scripts/cars/car_visual.gd")
	var car := "varis_m4_gts"
	var holder := Node3D.new()
	root.add_child(holder)
	var vis: Dictionary = CV.build({"id": car, "model": car + ".glb"}, holder)
	var model: Node3D = vis.get("model")
	var before := _count(model)
	# 验证每条 cut 的节点路径能否解析
	var cuts: Array = PL.mesh_cuts(car)
	for c in cuts:
		var mi := model.get_node_or_null(NodePath(c["node"])) as MeshInstance3D
		if mi == null:
			print("节点解析失败: ", c["node"])
		else:
			var idx: PackedInt32Array = (mi.mesh as ArrayMesh).surface_get_arrays(c["surf"])[Mesh.ARRAY_INDEX]
			var ntri := idx.size() / 3
			var bad := 0
			for t in c["tris"]:
				if int(t) >= ntri:
					bad += 1
			print("cut 节点OK tri总数=%d 记录序号=%s 越界=%d" % [ntri, c["tris"], bad])
	var removed: int = PL.apply_mesh_cuts(model, car)
	var after := _count(model)
	print("removed=%d before=%d after=%d diff=%d" % [removed, before, after, before - after])
	return true
func _count(m: Node3D) -> int:
	var n := 0
	for node in m.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null: continue
		var am := mi.mesh as ArrayMesh
		if am == null: continue
		for s in am.get_surface_count():
			var arr := am.surface_get_arrays(s)
			if arr.size() > Mesh.ARRAY_INDEX and arr[Mesh.ARRAY_INDEX] != null:
				n += (arr[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
	return n
