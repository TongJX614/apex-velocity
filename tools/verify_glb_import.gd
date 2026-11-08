extends SceneTree
## Dev tool: verify every car GLB in the library imports and loads cleanly.
## Usage:
##   ~/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script res://tools/verify_glb_import.gd

const MODELS_DIR := "res://assets/cars/models"


func _init() -> void:
	var files := DirAccess.get_files_at(MODELS_DIR)
	var glbs: Array[String] = []
	for f in files:
		if f.ends_with(".glb"):
			glbs.append(f)
	glbs.sort()
	var ok := 0
	var failed: Array[String] = []
	var total_nodes := 0
	var total_meshes := 0
	for f in glbs:
		var path := MODELS_DIR.path_join(f)
		var packed = load(path)
		if packed is PackedScene:
			var root: Node = (packed as PackedScene).instantiate()
			if root == null:
				failed.append(f + " (instantiate failed)")
				continue
			ok += 1
			var wheels := 0
			for suffix in ["FL", "FR", "RL", "RR"]:
				if root.find_child("Spin_Wheel_" + suffix, true, false) != null:
					wheels += 1
			total_nodes += _count_nodes(root)
			total_meshes += _count_meshes(root)
			if wheels != 4:
				failed.append(f + " (wheel nodes: %d/4)" % wheels)
			root.free()
		else:
			failed.append(f + " (load failed)")
	print("[GLB] loaded %d/%d, nodes=%d meshes=%d" % [ok, glbs.size(), total_nodes, total_meshes])
	if failed.is_empty():
		print("[GLB] ALL OK")
		quit(0)
	else:
		for f in failed:
			print("[GLB] FAIL ", f)
		quit(1)


func _count_nodes(node: Node) -> int:
	var n := 1
	for c in node.get_children():
		n += _count_nodes(c)
	return n


func _count_meshes(node: Node) -> int:
	var n := 1 if node is MeshInstance3D else 0
	for c in node.get_children():
		n += _count_meshes(c)
	return n
