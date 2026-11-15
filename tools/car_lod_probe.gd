extends SceneTree
## 车模三角面分布探针：按网格统计面数，找出可远距剔除的细节件。

func _initialize() -> void:
	var dir := "res://cars/assets/models"
	var files: Array[String] = []
	for name in DirAccess.get_files_at(dir):
		if name.ends_with(".glb"):
			files.append(name)
	files.sort()
	var grand := 0
	for file in files:
		var packed := load(dir.path_join(file)) as PackedScene
		if packed == null:
			print("[LOD] %-28s LOAD FAIL" % file)
			continue
		var root := packed.instantiate()
		var entries: Array = []
		var total := 0
		for node in root.find_children("*", "MeshInstance3D", true, false):
			var mi := node as MeshInstance3D
			if mi.mesh == null:
				continue
			var faces := 0
			for s in mi.mesh.get_surface_count():
				var idx: int = mi.mesh.surface_get_array_index_len(s)
				var vcount: int = mi.mesh.surface_get_array_len(s)
				faces += (idx / 3) if idx > 0 else (vcount / 3)
			total += faces
			entries.append({"name": String(root.get_path_to(mi)), "faces": faces})
		entries.sort_custom(func(a, b): return int(a["faces"]) > int(b["faces"]))
		grand += total
		print("[LOD] %-28s total=%7d meshes=%3d" % [file, total, entries.size()])
		for i in mini(5, entries.size()):
			print("[LOD]    %7d  %s" % [int(entries[i]["faces"]), String(entries[i]["name"])])
		root.free()
	print("[LOD] grand total=%d" % grand)
	quit(0)