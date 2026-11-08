extends SceneTree
## Car-library audit: materials, wheel pivots, wheel/body AABB sanity.
## Usage:
##   "$GODOT" --headless --path . --script res://tools/audit_cars.gd
## Report: /tmp/car_audit_report.txt

const MODELS_DIR := "res://assets/cars/models"
const DATA_DIR := "res://data"
const OUT_PATH := "/tmp/car_audit_report.txt"
const OFFSET_TOL := 0.03
const WHITE_MIN := 0.80
const SUFFIXES := ["FL", "FR", "RL", "RR"]

var _white_raw: Array[String] = []
var _white_after_paint: Array[String] = []


func _init() -> void:
	var manifest := _read_json(DATA_DIR.path_join("car_manifest.json"))
	var cars_doc: Dictionary = manifest.get("cars", {})
	var files := DirAccess.get_files_at(MODELS_DIR)
	var glbs: Array[String] = []
	for f in files:
		if f.ends_with(".glb"):
			glbs.append(f)
	glbs.sort()

	var lines: PackedStringArray = []
	lines.append("APEX VELOCITY · 极速巅峰 — 车辆模型审计报告")
	lines.append("生成时间: %s" % Time.get_datetime_string_from_system())
	lines.append("模型目录: %s  GLB 数量: %d" % [MODELS_DIR, glbs.size()])
	lines.append("")

	var offset_bad: Array[String] = []
	var size_bad: Array[String] = []
	var axis_bad: Array[String] = []
	var shape_bad: Array[String] = []
	var clip_suspect: Array[String] = []
	var wheel_missing: Array[String] = []
	var all_ok := 0

	for glb in glbs:
		var car_id := glb.get_basename()
		var entry: Dictionary = cars_doc.get(car_id, {})
		var data_radius := float(entry.get("wheelRadius", 0.34))
		var packed := load(MODELS_DIR.path_join(glb))
		if not (packed is PackedScene):
			lines.append("!! %s : 无法加载" % glb)
			continue
		var root := (packed as PackedScene).instantiate() as Node3D
		if root == null:
			lines.append("!! %s : 实例化失败" % glb)
			continue

		var car_lines: PackedStringArray = []
		var has_issue := false
		var meshes := root.find_children("*", "MeshInstance3D", true, false)

		# ---------------- 1. materials ----------------
		var mesh_total := 0
		var surface_total := 0
		var white_hits: Array[String] = []
		var white_names: Dictionary = {}
		var missing_hits: Array[String] = []
		var mat_names: Dictionary = {}
		var kw: Dictionary = _new_keyword_counts()
		for node in meshes:
			var mi := node as MeshInstance3D
			mesh_total += 1
			var mesh := mi.mesh
			if mesh == null:
				continue
			for s in mesh.get_surface_count():
				surface_total += 1
				var mat := mi.get_active_material(s)
				var node_path := String(root.get_path_to(mi))
				if mat == null:
					missing_hits.append("%s[%d] 无材质" % [node_path, s])
					continue
				var mat_name := _material_name(mat)
				mat_names[mat_name.to_lower()] = true
				_classify_keyword(mat_name, kw)
				if mat is StandardMaterial3D:
					var st := mat as StandardMaterial3D
					var c := st.albedo_color
					var is_white := st.albedo_texture == null and c.r > WHITE_MIN \
						and c.g > WHITE_MIN and c.b > WHITE_MIN and st.metallic < 0.35 \
						and not st.emission_enabled
					if is_white:
						var key := mat_name.to_lower()
						white_names[key] = int(white_names.get(key, 0)) + 1
						white_hits.append("%s[%d] mat=%s rgb=(%.2f,%.2f,%.2f)" % [
							node_path, s, mat_name, c.r, c.g, c.b])
		var white_uncovered := 0
		for nm in white_names.keys():
			if not _is_paint_name(String(nm)):
				white_uncovered += 1
		if white_hits.size() > 0:
			_white_raw.append("%s(%d)" % [car_id, white_hits.size()])
			if white_uncovered > 0:
				has_issue = true
				_white_after_paint.append("%s(%d种)" % [car_id, white_uncovered])
				car_lines.append(" [材质] 车漆覆盖后仍是纯白膜 %d 种 / 共 %d 处:" % [
					white_uncovered, white_hits.size()])
				var shown := 0
				for h in white_hits:
					if shown >= 12:
						car_lines.append("    ... (其余省略)")
						break
					if not _is_paint_name(_extract_mat(h)):
						car_lines.append("    - " + h)
						shown += 1
			else:
				car_lines.append(" [材质] 纯白仅出现在 paint 命名材质 (%d 处)，会被车库车漆覆盖" % white_hits.size())
		if missing_hits.size() > 0:
			has_issue = true
			car_lines.append(" [材质] 缺材质 %d 处:" % missing_hits.size())
			for h in missing_hits:
				car_lines.append("    - " + h)

		# ---------------- 2. wheels ----------------
		var body_aabb := AABB()
		var body_init := false
		var wheel_mesh_set: Dictionary = {}
		var wheel_aabbs: Dictionary = {}
		var wheel_centers: Dictionary = {}
		var spin_total := 0
		var worst_offset := 0.0
		var worst_detail := ""
		var worst_axis_ratio := 0.0
		var wheel_diam := 0.0
		var wheel_width := 0.0
		for suffix in SUFFIXES:
			var wheel_node := _find_node3d(root, "Wheel_" + suffix)
			var spin := _find_node3d(root, "Spin_Wheel_" + suffix)
			if wheel_node == null or spin == null:
				wheel_missing.append("%s %s" % [car_id, suffix])
				continue
			spin_total += 1
			var waabb := AABB()
			var waabb_init := false
			var meshes_under: Array = _mesh_descendants(spin)
			for c in meshes_under:
				var mi2 := c as MeshInstance3D
				if mi2.mesh == null:
					continue
				wheel_mesh_set[c] = true
				var a := _rel_xform(mi2, spin) * mi2.get_aabb()
				waabb = waabb.merge(a) if waabb_init else a
				waabb_init = true
			if not waabb_init:
				continue
			wheel_aabbs[suffix] = waabb
			wheel_centers[suffix] = waabb.get_center()
			wheel_diam = maxf(wheel_diam, maxf(waabb.size.y, waabb.size.z))
			wheel_width = maxf(wheel_width, waabb.size.x)
			var off := waabb.get_center().length()
			if off > worst_offset:
				worst_offset = off
				worst_detail = "%s centre=(%+.3f,%+.3f,%+.3f) size=(%.2f,%.2f,%.2f) mesh=%d" % [
					suffix, waabb.get_center().x, waabb.get_center().y, waabb.get_center().z,
					waabb.size.x, waabb.size.y, waabb.size.z, meshes_under.size()]
			var thin_ratio := waabb.size.x / maxf(maxf(waabb.size.y, waabb.size.z), 0.001)
			if thin_ratio > 0.75:
				worst_axis_ratio = maxf(worst_axis_ratio, thin_ratio)
			var round_err := absf(waabb.size.y - waabb.size.z) / maxf(maxf(waabb.size.y, waabb.size.z), 0.001)
			if round_err > 0.06:
				shape_bad.append("%s %s (y/z=%.3f/%.3f)" % [car_id, suffix, waabb.size.y, waabb.size.z])
		for node in meshes:
			if wheel_mesh_set.has(node):
				continue
			var mi3 := node as MeshInstance3D
			if mi3.mesh == null:
				continue
			var a2 := _rel_xform(mi3, root) * mi3.get_aabb()
			body_aabb = body_aabb.merge(a2) if body_init else a2
			body_init = true

		if spin_total != 4:
			has_issue = true
			car_lines.append(" [车轮] 找齐滚转节点 %d/4" % spin_total)
		if worst_offset > OFFSET_TOL:
			has_issue = true
			offset_bad.append(car_id)
			car_lines.append(" [车轮] Spin 原点 vs 轮几何中心偏移 %.3f m (>%.2f) — 滚转会晃/偏心:" % [
				worst_offset, OFFSET_TOL])
			car_lines.append("    - " + worst_detail)
		if worst_axis_ratio > 0.0:
			has_issue = true
			axis_bad.append(car_id)
			car_lines.append(" [车轮] 轮宽/轮径=%.2f 偏大，滚转轴可能不是 X 轴" % worst_axis_ratio)

		# ---------------- 3. size / clipping sanity ----------------
		if spin_total == 4 and body_init:
			var diam_err := 0.0
			if data_radius > 0.01:
				diam_err = absf(wheel_diam - data_radius * 2.0) / (data_radius * 2.0)
			if diam_err > 0.10:
				has_issue = true
				size_bad.append(car_id)
				car_lines.append(" [尺寸] 轮径 %.3f m vs 数据 2×wheelRadius=%.3f m 误差 %.0f%%" % [
					wheel_diam, data_radius * 2.0, diam_err * 100.0])
			var body_half := maxf(absf(body_aabb.position.x), absf(body_aabb.end.x))
			for suffix in SUFFIXES:
				if not wheel_centers.has(suffix):
					continue
				var wc: Vector3 = wheel_centers[suffix]
				var wa: AABB = wheel_aabbs[suffix]
				var outer := absf(wc.x) + wa.size.x * 0.5
				if outer > body_half + 0.12:
					has_issue = true
					clip_suspect.append("%s %s 轮外缘超车身" % [car_id, suffix])
					car_lines.append(" [穿模?] %s 轮外缘 X=%.2f 超出车身半宽 %.2f (+%.2f)" % [
						suffix, outer, body_half, outer - body_half])
				var wheel_bottom := wc.y - maxf(wa.size.y, wa.size.z) * 0.5
				if wheel_bottom > body_aabb.position.y + 0.10:
					has_issue = true
					clip_suspect.append("%s %s 轮胎悬空" % [car_id, suffix])
					car_lines.append(" [穿模?] %s 轮胎最低点 %.2f 高于车身底面 %.2f（悬空）" % [
						suffix, wheel_bottom, body_aabb.position.y])
				if wheel_bottom < body_aabb.position.y - 0.25:
					has_issue = true
					clip_suspect.append("%s %s 轮胎过度下探" % [car_id, suffix])
					car_lines.append(" [穿模?] %s 轮胎最低点 %.2f 低于车身底面 %.2f 太多" % [
						suffix, wheel_bottom, body_aabb.position.y])
			car_lines.append(" [尺寸] 轮径=%.3f 轮宽=%.3f 数据直径=%.3f | 车身AABB pos=(%.2f,%.2f,%.2f) size=(%.2f,%.2f,%.2f)" % [
				wheel_diam, wheel_width, data_radius * 2.0,
				body_aabb.position.x, body_aabb.position.y, body_aabb.position.z,
				body_aabb.size.x, body_aabb.size.y, body_aabb.size.z])

		# ---------------- summary line ----------------
		var paint_names: Array[String] = []
		for nm in mat_names.keys():
			if _is_paint_name(String(nm)):
				paint_names.append(String(nm))
		lines.append("=== %s  (%s) ===" % [car_id, glb])
		lines.append("  mesh=%d surface=%d 材质种类=%d 车轮节点=%d/4 轮径=%.3f" % [
			mesh_total, surface_total, mat_names.size(), spin_total, wheel_diam])
		lines.append("  材质关键词: " + _kw_text(kw))
		lines.append("  车漆材质: " + (", ".join(paint_names) if paint_names.size() > 0 else "无 paint 命名材质"))
		lines.append("  材质清单: " + ", ".join(_sorted_keys(mat_names)))
		for l in car_lines:
			lines.append("  " + l)
		if not has_issue:
			all_ok += 1
		lines.append("")
		root.free()

	# ---------------- summary ----------------
	var summary: PackedStringArray = []
	summary.append("========== 汇总 ==========")
	summary.append("GLB 总数: %d | 无问题: %d | 有疑点: %d" % [glbs.size(), all_ok, glbs.size() - all_ok])
	summary.append("纯白材质(原始，含 paint 命名): %d 台 -> %s" % [_white_raw.size(), ", ".join(_white_raw)])
	summary.append("白膜残留在车漆覆盖之外: %d 台 -> %s" % [
		_white_after_paint.size(), ", ".join(_white_after_paint)])
	summary.append("车轮节点缺失 (%d): %s" % [wheel_missing.size(), ", ".join(wheel_missing)])
	summary.append("Spin 原点偏移>%.2fm (%d): %s" % [OFFSET_TOL, offset_bad.size(), ", ".join(offset_bad)])
	summary.append("轮径与数据不符 (%d): %s" % [size_bad.size(), ", ".join(size_bad)])
	summary.append("滚转轴可疑 (%d): %s" % [axis_bad.size(), ", ".join(axis_bad)])
	summary.append("轮形不圆/异常 (%d): %s" % [shape_bad.size(), ", ".join(shape_bad)])
	summary.append("AABB 穿模可疑 (%d): %s" % [clip_suspect.size(), ", ".join(clip_suspect)])
	summary.append("")
	var final_lines: PackedStringArray = summary
	final_lines.append_array(lines)
	var f := FileAccess.open(OUT_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(final_lines))
		f.close()
		print("审计报告已写入 " + OUT_PATH)
	else:
		print("无法写入 " + OUT_PATH)
	print("\n".join(summary))
	quit(0)


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

func _new_keyword_counts() -> Dictionary:
	return {
		"glass": 0, "chrome": 0, "plastic": 0, "tyre": 0, "rim": 0,
		"brake": 0, "interior": 0, "paint": 0, "light": 0, "other": 0,
	}


func _classify_keyword(mat_name: String, kw: Dictionary) -> void:
	var nm := mat_name.to_lower()
	if nm.contains("glass") or nm.contains("glazing") or nm.contains("window") or nm.contains("glas"):
		kw["glass"] += 1
	elif nm.contains("chrome") or nm.contains("chorme") or nm.contains("pchrome") or nm.contains("mirror"):
		kw["chrome"] += 1
	elif nm.contains("brake") or nm.contains("disc"):
		kw["brake"] += 1
	elif nm.contains("rim") or nm.contains("spoke") or nm.contains("centernut") or nm.contains("caliper"):
		kw["rim"] += 1
	elif nm.contains("tyre") or nm.contains("tire"):
		kw["tyre"] += 1
	elif nm.contains("paint") or nm.contains("carpaint"):
		kw["paint"] += 1
	elif nm.contains("light") or nm.contains("emis"):
		kw["light"] += 1
	elif nm.contains("interior") or nm.contains("internal") or nm.contains("int_") \
			or nm.contains("neishi") or nm.contains("torpeda") or nm.contains("dveri") \
			or nm.contains("potolok") or nm.contains("sideniya"):
		kw["interior"] += 1
	elif nm.contains("plastic") or nm.contains("black") or nm.contains("grille") \
			or nm.contains("chassis") or nm.contains("chasis"):
		kw["plastic"] += 1
	else:
		kw["other"] += 1


func _kw_text(kw: Dictionary) -> String:
	var parts: PackedStringArray = []
	for k in kw.keys():
		if int(kw[k]) > 0:
			parts.append("%s=%d" % [k, kw[k]])
	return " ".join(parts)


func _material_name(mat: Material) -> String:
	var nm := String(mat.resource_name)
	if nm.is_empty() and mat is BaseMaterial3D:
		nm = String((mat as BaseMaterial3D).get_meta("gltf_material_name", ""))
	return nm if not nm.is_empty() else "<未命名>"


func _extract_mat(hit: String) -> String:
	var idx := hit.find("mat=")
	if idx < 0:
		return ""
	var rest := hit.substr(idx + 4)
	var sp := rest.find(" ")
	return rest.substr(0, sp) if sp > 0 else rest


func _is_paint_name(nm: String) -> bool:
	var n := nm.to_lower()
	return n.contains("paint") or n.contains("carpaint") or n.contains("coloured")


## Transform of `node` relative to `ancestor` (does not rely on the scene tree:
## --script SceneTree nodes are never "inside tree", so global_transform is IDENTITY).
func _rel_xform(node: Node3D, ancestor: Node) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var n: Node = node
	while n != null and n != ancestor:
		if n is Node3D:
			xf = (n as Node3D).transform * xf
		n = n.get_parent()
	return xf


func _find_node3d(root: Node, name: String) -> Node3D:
	return root.find_child(name, true, false) as Node3D


func _mesh_descendants(node: Node) -> Array:
	var out: Array = []
	for child in node.get_children():
		if child is MeshInstance3D:
			out.append(child)
		out.append_array(_mesh_descendants(child))
	return out


func _sorted_keys(d: Dictionary) -> Array:
	var keys := d.keys()
	keys.sort()
	return keys


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}
