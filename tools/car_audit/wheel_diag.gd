extends Node
## 临时诊断：dump 指定车指定轮位的节点层级 + 变换 + 网格 AABB，定位装配缺陷根因。
## 用法（场景模式）: Godot --path . res://tools/car_audit/wheel_diag.tscn -- --car=zeekr_7x --wheel=FL

var _car := "byd_seal"
var _wheel := "FL"
var _raw := false


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--car="):
			_car = arg.substr(6)
		elif arg.begins_with("--wheel="):
			_wheel = arg.substr(8)
		elif arg == "--raw":
			_raw = true
	var manifest: Dictionary = GameData.car_manifest.get("cars", {})
	var entry: Dictionary = manifest.get(_car, {})
	var model := String(entry.get("model", ""))
	if _raw:
		_raw_dump(model)
		return
	var holder := Node3D.new()
	var built := CarVisual.build({"id": _car, "model": model}, holder)
	var root: Node = built.get("model", null)
	if root == null:
		print("[DIAG] load failed")
		get_tree().quit(1)
		return
	print("[DIAG] car=%s wheel=%s model=%s" % [_car, _wheel, model])
	# 从 model 根到 Wheel_XX 的祖先链
	var steer := root.find_child("Wheel_" + _wheel, true, false) as Node3D
	if steer == null:
		print("[DIAG] no Wheel_ node")
		get_tree().quit(1)
		return
	var chain: Array[Node3D] = []
	var n: Node = steer
	while n != null and n != root:
		if n is Node3D:
			chain.append(n as Node3D)
		n = n.get_parent()
	chain.reverse()
	print("[DIAG] ancestor chain (model->steer):")
	for a in chain:
		print("[DIAG]   %-22s pos=%s rot=%s scale=%s" % [String(a.name), str(a.position), str(a.rotation), str(a.scale)])
	# steer 子树
	print("[DIAG] steer subtree:")
	_dump(steer, root, 1)
	holder.free()
	get_tree().quit(0)


func _dump(node: Node3D, root: Node, depth: int) -> void:
	var pad := "  ".repeat(depth)
	var rel := _rel(node, root)
	var extra := ""
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		if mi.mesh != null:
			var box: AABB = rel * mi.mesh.get_aabb()
			extra = " MESH aabbCenter(model)=%s size=%s" % [str(box.get_center()), str(box.size)]
	print("[DIAG] %s%-22s pos=%s rot=%s scale=%s%s" % [pad, String(node.name), str(node.position), str(node.rotation), str(node.scale), extra])
	for c in node.get_children():
		if c is Node3D:
			_dump(c as Node3D, root, depth + 1)


func _rel(node: Node3D, ancestor: Node) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var n: Node = node
	while n != null and n != ancestor:
		if n is Node3D:
			xf = (n as Node3D).transform * xf
		n = n.get_parent()
	return xf


## 原始 GLB（不经 CarVisual 修正）：dump 指定轮位轮胎网格的真实 PCA 最薄轴向量 + AABB。
func _raw_dump(model_file: String) -> void:
	var path := "res://cars/assets/models/" + model_file
	var packed: PackedScene = load(path) as PackedScene
	if packed == null:
		print("[RAW] load failed ", path)
		get_tree().quit(1)
		return
	var root := packed.instantiate() as Node3D
	add_child(root)
	var spin := root.find_child("Spin_Wheel_" + _wheel, true, false) as Node3D
	if spin == null:
		print("[RAW] no Spin_Wheel_", _wheel)
		get_tree().quit(1)
		return
	print("[RAW] car=%s wheel=%s (uncorrected GLB)" % [_car, _wheel])
	# spin 相对 model 根的变换
	var rel_spin := _rel(spin, root)
	print("[RAW] spin rel-model pos=%s rot=%s scale=%s" % [str(rel_spin.origin), str(rel_spin.basis.get_euler()), str(rel_spin.basis.get_scale())])
	for mi in spin.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		if m.mesh == null:
			continue
		var nm := String(m.name).to_lower()
		var rel := _rel(m, spin)
		var box: AABB = rel * m.mesh.get_aabb()
		var pts := _points_rel(m, spin)
		var ax := _pca_thinnest_vec(pts)
		var ax_model := rel_spin.basis * ax
		print("[RAW]   %-20s verts=%d aabbCenter(spin)=%s size=%s" % [String(m.name), pts.size(), str(box.get_center()), str(box.size)])
		print("[RAW]       thinnestAxis(spin)=%s  vsX=%.1fdeg  axis(model)=%s vsX=%.1fdeg" % [str(ax), rad_to_deg(acos(clampf(absf(ax.x), 0.0, 1.0))), str(ax_model.normalized()), rad_to_deg(acos(clampf(absf(ax_model.normalized().x), 0.0, 1.0)))])
	root.free()
	get_tree().quit(0)


func _points_rel(mi: MeshInstance3D, ancestor: Node3D) -> PackedVector3Array:
	var out := PackedVector3Array()
	var rel := _rel(mi, ancestor)
	for s in mi.mesh.get_surface_count():
		var arr := mi.mesh.surface_get_arrays(s)
		var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		for v in verts:
			out.append(rel * v)
	return out


func _pca_thinnest_vec(points: PackedVector3Array) -> Vector3:
	if points.size() < 16:
		return Vector3.ZERO
	var n := float(points.size())
	var mean := Vector3.ZERO
	for p in points:
		mean += p
	mean /= n
	var cxx := 0.0; var cyy := 0.0; var czz := 0.0
	var cxy := 0.0; var cxz := 0.0; var cyz := 0.0
	for p in points:
		var d := p - mean
		cxx += d.x * d.x; cyy += d.y * d.y; czz += d.z * d.z
		cxy += d.x * d.y; cxz += d.x * d.z; cyz += d.y * d.z
	cxx /= n; cyy /= n; czz /= n; cxy /= n; cxz /= n; cyz /= n
	var tr := cxx + cyy + czz
	var v := Vector3(0.31, 0.53, 0.81).normalized()
	for iter in 200:
		var w := Vector3(
			(tr - cxx) * v.x - cxy * v.y - cxz * v.z,
			-cxy * v.x + (tr - cyy) * v.y - cyz * v.z,
			-cxz * v.x - cyz * v.y + (tr - czz) * v.z)
		if w.length() < 1e-12:
			return Vector3.ZERO
		v = w.normalized()
	return v