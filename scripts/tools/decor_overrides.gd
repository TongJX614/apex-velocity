class_name DecorOverrides
extends RefCounted
## 场景装饰的用户改动（override）—— 游戏与编辑器共用的应用层。
##
## 装饰本身仍然是程序化生成的（固定随机种子，同一条赛道每次生成顺序一致），
## 所以只需要记录**用户动过的那几条**，不必把上千个实例全部烘焙成数据。
##
## 稳定标识（见 decor_editor.gd 的 _collect_items）：
##   MultiMesh 实例 → "MM:<节点名>#<实例序号>"   节点名形如 CoastPalms_s0_g3
##   独立节点       → "ND:<节点名>"               节点名由摆放方传入
## 两者都不含场景路径，因此在菜单预览、比赛、分屏等不同挂载位置下都一致。
##
## 前提：改了 data/tracks.json 的赛道形状后，实例数量与分组会变，
##       旧 override 可能对不上号（表现为某棵树回不到原处）。这时重新编辑即可。

const DIR := "res://data/decor/overrides"


static func path_for(track_id: String) -> String:
	return "%s/%s.json" % [DIR, track_id]


static func exists(track_id: String) -> bool:
	return FileAccess.file_exists(path_for(track_id))


static func load_doc(track_id: String) -> Dictionary:
	var f := FileAccess.open(path_for(track_id), FileAccess.READ)
	if f == null:
		return {}
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	return parsed


## 把 override 应用到已经生成好的场景上。返回实际生效的条数。
##
## 处理顺序很重要：先把用户新增的模型摆出来，再建索引，最后才套 edits。
## 这样新增的模型也能被同一条 edits 记录移动/缩放，不必为它单独写一套逻辑。
##
## 注意：如果同一棵树被分到多个 chunk（一个资产可能有多个 surface），
## 每个节点名的实例序号是各自独立的，所以直接按 key 匹配即可。
static func apply(root: Node3D, track_id: String) -> int:
	var doc := load_doc(track_id)
	if doc.is_empty():
		return 0
	var edits: Array = doc.get("edits", [])
	var removed: Array = doc.get("removed", [])
	var added: Array = doc.get("added", [])
	if edits.is_empty() and removed.is_empty() and added.is_empty():
		return 0

	var spawned := 0
	for a in added:
		if spawn_added(root, a) != null:
			spawned += 1

	# 建索引：key -> [ {node, idx}, ... ]
	# 一个资产会被拆成多个 surface 节点（s0/s1/s2），它们装的是同一批实例，
	# 所以一个 key 可能对应多个节点，必须全部写，否则模型只有一部分跟着动。
	var index := {}
	for node in root.find_children("*", "MultiMeshInstance3D", true, false):
		var mmi := node as MultiMeshInstance3D
		if mmi == null or mmi.multimesh == null or not mmi.has_meta("decor_group"):
			continue
		var grp := "%s_g%d" % [String(mmi.get_meta("decor_group")), int(mmi.get_meta("decor_chunk", 0))]
		for i in mmi.multimesh.instance_count:
			var k := "MM:%s#%d" % [grp, i]
			if not index.has(k):
				index[k] = []
			(index[k] as Array).append({"node": mmi, "idx": i})
	for node in root.find_children("*", "Node3D", true, false):
		if node.has_meta("decor_asset"):
			index["ND:%s" % String(node.name)] = [{"node": node, "idx": -1}]

	var applied := spawned
	for key in removed:
		var list = index.get(String(key))
		if list == null:
			continue
		for it in list:
			_shrink(it)
		applied += 1

	for e in edits:
		var key := String(e.get("key", ""))
		var list = index.get(key)
		if list == null:
			continue
		var first: Dictionary = list[0]
		var xf: Transform3D = _xf_from(e, first)
		for it in list:
			_write(it, xf)
		applied += 1
	return applied


## 还原一条「用户手动摆放的模型」。编辑器重开时也用它重建。
static func spawn_added(root: Node3D, a: Dictionary) -> Node3D:
	var asset := String(a.get("asset", ""))
	var id := String(a.get("id", ""))
	if asset.is_empty() or id.is_empty():
		return null
	if not RealAssetKit.has(asset):
		push_warning("decor override: 缺少资产 %s，跳过新增模型 %s" % [asset, id])
		return null
	return RealAssetKit.place_unique(root, asset, _added_xf(a), "Added_" + id)


static func _added_xf(a: Dictionary) -> Transform3D:
	var p: Array = a.get("p", [])
	var q: Array = a.get("q", [])
	var s: Array = a.get("s", [])
	var origin := Vector3.ZERO
	var basis := Basis()
	if p.size() == 3:
		origin = Vector3(float(p[0]), float(p[1]), float(p[2]))
	if q.size() == 4:
		basis = Basis(Quaternion(float(q[0]), float(q[1]), float(q[2]), float(q[3])))
	if s.size() == 3:
		basis = basis.scaled(Vector3(float(s[0]), float(s[1]), float(s[2])))
	return Transform3D(basis, origin)


static func _xf_from(e: Dictionary, it: Dictionary) -> Transform3D:
	var base: Transform3D = _read(it)
	var origin := base.origin
	var basis := base.basis
	var p: Array = e.get("p", [])
	var q: Array = e.get("q", [])
	var s: Array = e.get("s", [])
	if p.size() == 3:
		origin = Vector3(float(p[0]), float(p[1]), float(p[2]))
	if q.size() == 4:
		basis = Basis(Quaternion(float(q[0]), float(q[1]), float(q[2]), float(q[3])))
		if s.size() == 3:
			basis = basis.scaled(Vector3(float(s[0]), float(s[1]), float(s[2])))
	elif s.size() == 3:
		basis = basis.scaled(Vector3(float(s[0]), float(s[1]), float(s[2])))
	return Transform3D(basis, origin)


static func _read(it: Dictionary) -> Transform3D:
	var node = it["node"]
	var idx := int(it["idx"])
	if node is MultiMeshInstance3D and idx >= 0:
		var mmi := node as MultiMeshInstance3D
		return mmi.global_transform * mmi.multimesh.get_instance_transform(idx)
	if node is Node3D:
		return (node as Node3D).transform
	return Transform3D.IDENTITY


static func _write(it: Dictionary, xf: Transform3D) -> void:
	var node = it["node"]
	var idx := int(it["idx"])
	if node is MultiMeshInstance3D and idx >= 0:
		var mmi := node as MultiMeshInstance3D
		mmi.multimesh.set_instance_transform(idx, mmi.global_transform.affine_inverse() * xf)
	elif node is Node3D:
		(node as Node3D).transform = xf


## MultiMesh 没有「删除实例」的接口，缩到 0.0001 让它在画面上消失。
static func _shrink(it: Dictionary) -> void:
	var xf := _read(it)
	_write(it, Transform3D(xf.basis.scaled(Vector3.ONE * 0.0001), xf.origin))
