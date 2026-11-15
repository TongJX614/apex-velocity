extends Node
## 一次性诊断：找横跨赛道路面的场景网格（默认山壁 ValleyWalls）。
## 用法：Godot --headless --path <工程> res://tools/audit_road_blockers.tscn -- --track=magma

const GRID := 24.0


func _ready() -> void:
	var track_id := "magma"
	for a in OS.get_cmdline_user_args():
		if String(a).begins_with("--track="):
			track_id = String(a).substr(8)
	var def := _track_def(track_id)
	if def.is_empty():
		printerr("[BLOCK] unknown track ", track_id)
		get_tree().quit(2)
		return
	var path := TrackPath.new()
	path.build_from_def(def, 2.0)
	TrackBuilder.configure_terrain(path)
	var holder := Node3D.new()
	add_child(holder)
	SceneryKit.build(holder, path, def)
	print("[BLOCK] track=%s len=%.0f half=%.1f samples=%d" % [
		track_id, path.total_length, path.half_width, path.samples.size()])
	var cells := _build_grid(path)
	print("[BLOCK] grid_cells=%d sample10=%s nearest_sample10=%s" % [
		cells.size(), str(path.samples[10]), str(_nearest(path, cells, path.samples[10]))])
	for mi in holder.find_children("*", "MeshInstance3D", true, false):
		var mesh_inst := mi as MeshInstance3D
		if mesh_inst.mesh == null:
			continue
		_scan_mesh(mesh_inst, path, cells)
	get_tree().quit(0)


func _track_def(track_id: String) -> Dictionary:
	var f := FileAccess.open("res://data/tracks.json", FileAccess.READ)
	if f == null:
		return {}
	var doc = JSON.parse_string(f.get_as_text())
	if typeof(doc) != TYPE_DICTIONARY:
		return {}
	for t in (doc as Dictionary).get("tracks", []):
		if typeof(t) == TYPE_DICTIONARY and String(t.get("id", "")) == track_id:
			return t as Dictionary
	return {}


func _build_grid(path: TrackPath) -> Dictionary:
	var cells: Dictionary = {}
	for i in path.samples.size():
		var p: Vector3 = path.samples[i]
		var key := Vector2i(floori(p.x / GRID), floori(p.z / GRID))
		var arr: PackedInt32Array = cells.get(key, PackedInt32Array())
		arr.append(i)
		cells[key] = arr
	return cells


func _nearest(path: TrackPath, cells: Dictionary, p: Vector3) -> Vector2:
	var best := 1e24
	var best_i := -1
	var cx := floori(p.x / GRID)
	var cz := floori(p.z / GRID)
	for gx in range(cx - 2, cx + 3):
		for gz in range(cz - 2, cz + 3):
			var arr: PackedInt32Array = cells.get(Vector2i(gx, gz), PackedInt32Array())
			for j in arr.size():
				var i: int = arr[j]
				var s: Vector3 = path.samples[i]
				var dx := s.x - p.x
				var dz := s.z - p.z
				var d := dx * dx + dz * dz
				if d < best:
					best = d
					best_i = i
	return Vector2(sqrt(best) if best_i >= 0 else 1.0e6, float(best_i))


func _scan_mesh(mi: MeshInstance3D, path: TrackPath, cells: Dictionary) -> void:
	# 用全局 transform：place_unique 的资产可能挂在父 Node3D 下，
	# 局部矩阵会把整棵树搬回原点，制造「树压路」假阳性。
	var xf := mi.global_transform
	var faces := mi.mesh.get_faces()
	var hits: Array[float] = []
	var near_flat: Array[float] = []
	var near_hi: Array[float] = []
	var min_d := 1.0e9
	var worst := 0.0
	var worst_at := Vector3.ZERO
	for k in range(0, faces.size(), 3):
		var cen: Vector3 = xf * ((faces[k] as Vector3 + faces[k + 1] as Vector3
			+ faces[k + 2] as Vector3) / 3.0)
		var qc := _nearest(path, cells, cen)
		min_d = minf(min_d, qc.x)
		var hit := false
		for vi in 3:
			var w: Vector3 = xf * (faces[k + vi] as Vector3)
			var q := _nearest(path, cells, w)
			var idx := int(q.y)
			var ry := (path.samples[idx] as Vector3).y
			if q.x < path.half_width + 2.0:
				near_flat.append(path.accumulated[idx])
				if w.y - ry > 1.0:
					near_hi.append(path.accumulated[idx])
			if q.x < path.half_width + 1.2 and w.y - ry > 0.35:
				hit = true
				var above := w.y - ry
				if above > worst:
					worst = above
					worst_at = w
		if hit:
			hits.append(path.accumulated[int(qc.y)])
			if hits.size() <= 8:
				for vi in 3:
					var wv: Vector3 = xf * (faces[k + vi] as Vector3)
					var qv := _nearest(path, cells, wv)
					var iv := int(qv.y)
					if qv.x < path.half_width + 1.2:
						print("[BLOCK]   命中顶点 %s 横距=%.1f 高差=%.1f 弧长=%.0f 曲率=%.5f" % [
							str(wv), qv.x, wv.y - (path.samples[iv] as Vector3).y,
							path.accumulated[iv], path.curvatures[iv]])
	print("[BLOCK] %-24s tris=%d 近路顶点(≤half+2)=%d 高于路面1m=%d minD=%.1f" % [
		String(mi.name), faces.size() / 3, near_flat.size(), near_hi.size(), min_d])
	if not near_flat.is_empty():
		near_flat.sort()
		print("[BLOCK]   near_flat dists: %s ... %s" % [
			_format_clusters(near_flat), str(near_flat.slice(maxi(0, near_flat.size() - 5)))])
	if not near_hi.is_empty():
		near_hi.sort()
		print("[BLOCK]   near_hi   dists: %s" % _format_clusters(near_hi))
	if hits.is_empty():
		return
	var lo := 1.0e9
	var hi := -1.0e9
	for d in hits:
		lo = minf(lo, d)
		hi = maxf(hi, d)
	print("[BLOCK] %-24s 压路三角=%d 赛段 %.0f..%.0f m；最低横距 %.1fm；最高侵入 %.1fm @ %s" % [
		String(mi.name), hits.size(), lo, hi, min_d, worst, str(worst_at)])


func _format_clusters(d: Array[float]) -> String:
	var parts: PackedStringArray = []
	var start := d[0]
	var prev := d[0]
	for v in d.slice(1):
		var val := float(v)
		if val - prev > 12.0:
			parts.append("%.0f..%.0f" % [start, prev])
			start = val
		prev = val
	parts.append("%.0f..%.0f" % [start, prev])
	return ", ".join(parts)
