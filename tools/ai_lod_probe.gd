extends SceneTree
## AI 低模探针：批量检查车轮节点、面数与车漆材质是否保留。

func _initialize() -> void:
	var dir := "res://cars/assets/models_lod"
	var files: Array[String] = []
	for name in DirAccess.get_files_at(dir):
		if String(name).ends_with(".glb"):
			files.append(String(name))
	files.sort()
	var failures: Array[String] = []
	var total_faces := 0
	for file in files:
		var path := dir.path_join(file)
		var packed := load(path) as PackedScene
		if packed == null:
			failures.append("%s load fail" % file)
			continue
		var root := packed.instantiate()
		var faces := 0
		var meshes := 0
		var paint := ""
		for node in root.find_children("*", "MeshInstance3D", true, false):
			var mi := node as MeshInstance3D
			if mi.mesh == null:
				continue
			meshes += 1
			for s in mi.mesh.get_surface_count():
				var idx: int = mi.mesh.surface_get_array_index_len(s)
				var vcount: int = mi.mesh.surface_get_array_len(s)
				faces += (idx / 3) if idx > 0 else (vcount / 3)
				var m := mi.get_active_material(s) as StandardMaterial3D
				if m != null and paint.is_empty():
					var n := String(m.resource_name).to_lower()
					if n.contains("paint") or n.contains("coloured"):
						paint = n
		var wheels := 0
		for suffix in ["FL", "FR", "RL", "RR"]:
			if root.find_child("Spin_Wheel_" + suffix, true, false) != null:
				wheels += 1
		total_faces += faces
		print("[AILOD] %-28s faces=%7d meshes=%3d wheels=%d paint=%s" % [
			file, faces, meshes, wheels, paint])
		if wheels < 4:
			failures.append("%s wheels=%d" % [file, wheels])
		root.free()
	print("[AILOD] files=%d faces=%d" % [files.size(), total_faces])
	if failures.is_empty():
		print("[AILOD] PASS")
		quit(0)
	else:
		print("[AILOD] FAIL")
		for f in failures:
			print("[AILOD]   " + f)
		quit(1)