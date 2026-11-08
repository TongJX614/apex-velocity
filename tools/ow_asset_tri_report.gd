extends SceneTree
## 一次性诊断：开放世界出生区布景按资产类别的实例数与三角面统计。

func _init() -> void:
	var holder := Node3D.new()
	holder.name = "DiagHolder"
	root.add_child(holder)
	var world := OpenWorld.new()
	holder.add_child(world)
	world.build()
	OpenWorldScenery.build_initial(world, holder)
	var per_asset := {}
	for node in holder.find_children("*", "MultiMeshInstance3D", true, false):
		var mmi := node as MultiMeshInstance3D
		if mmi == null or mmi.multimesh == null or mmi.multimesh.mesh == null:
			continue
		var group := String(mmi.get_meta("decor_group") if mmi.has_meta("decor_group") else mmi.name)
		var asset := group.get_slice("__", 1) if group.contains("__") else String(group)
		var tris := 0
		for s in mmi.multimesh.mesh.get_surface_count():
			var arrays := mmi.multimesh.mesh.surface_get_arrays(s)
			if arrays.size() <= Mesh.ARRAY_VERTEX or arrays[Mesh.ARRAY_VERTEX] == null:
				continue
			var idx = arrays[Mesh.ARRAY_INDEX]
			var vc: int = (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
			tris += (vc / 3) if idx == null else (idx as PackedInt32Array).size() / 3
		var e: Dictionary = per_asset.get_or_add(asset, {"inst": 0, "tris": 0, "nodes": 0})
		e["inst"] = int(e["inst"]) + mmi.multimesh.instance_count
		e["tris"] = int(e["tris"]) + tris * mmi.multimesh.instance_count
		e["nodes"] = int(e["nodes"]) + 1
	var rows := []
	var total_tris := 0
	var total_inst := 0
	for k in per_asset:
		rows.append([k, per_asset[k]])
		total_tris += int(per_asset[k]["tris"])
		total_inst += int(per_asset[k]["inst"])
	rows.sort_custom(func(a, b): return int(a[1]["tris"]) > int(b[1]["tris"]))
	print("[DIAG] total instances=%d  tris(all)=%d" % [total_inst, total_tris])
	for r in rows.slice(0, 20):
		print("[DIAG] %-28s nodes=%4d inst=%5d tris=%9d  (%.1f%%)" % [
			r[0], int(r[1]["nodes"]), int(r[1]["inst"]), int(r[1]["tris"]),
			100.0 * float(r[1]["tris"]) / maxf(float(total_tris), 1.0)])
	quit(0)
