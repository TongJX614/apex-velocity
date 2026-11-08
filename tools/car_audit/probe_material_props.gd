extends SceneTree
## 单材质属性探针（升级后复验 / 排障用）
##
## 用途：加载指定车模，打印指定材质（名称包含子串）的全部 BaseMaterial3D 关键属性，
## 并逐 surface 打印该材质被哪些 MeshInstance3D 使用。
##
## 用法：
##   Godot --headless --path . --script res://tools/car_audit/probe_material_props.gd \
##       -- --car=bmw_218i --match=CarPaint
##
##   --car=<id>    manifest 中的车辆 id（默认 bmw_m3_e46_gtr）
##   --match=<s>   材质名包含的子串，大小写敏感（默认 CarPaint）
##   --model=<f>   直接指定 assets/cars/models 下的文件名（覆盖 --car）
##   --all         打印所有材质（忽略 --match）

const MANIFEST_PATH := "res://data/car_manifest.json"
const MODELS_DIR := "res://assets/cars/models"

var _car := "bmw_m3_e46_gtr"
var _match := "CarPaint"
var _model := ""
var _print_all := false
var _direct := false


func _init() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--car="):
			_car = arg.substr(6)
		elif arg.begins_with("--match="):
			_match = arg.substr(8)
		elif arg.begins_with("--model="):
			_model = arg.substr(8)
		elif arg == "--all":
			_print_all = true
		elif arg == "--direct":
			_direct = true

	var model := _model
	if model.is_empty():
		var manifest := _read_json(MANIFEST_PATH)
		var entry: Dictionary = manifest.get("cars", {}).get(_car, {})
		model = String(entry.get("model", ""))
	if model.is_empty():
		printerr("[PROBE] 找不到车型: " + _car)
		quit(2)
		return
	var path := MODELS_DIR.path_join(model)
	var root: Node = null
	if _direct:
		# 绕过 .godot/imported 缓存，直接用 GLTFDocument 解析源 GLB，用于对比导入缓存是否过期
		var doc := GLTFDocument.new()
		var state := GLTFState.new()
		var err := doc.append_from_file(path, state)
		if err != OK:
			printerr("[PROBE] GLTFDocument.append_from_file 失败 err=%d" % err)
			quit(2)
			return
		root = doc.generate_scene(state)
		print("[PROBE] (direct GLTFDocument import, 绕过 .godot/imported 缓存)")
	else:
		var packed = load(path)
		if not (packed is PackedScene):
			printerr("[PROBE] 加载失败: " + path)
			quit(2)
			return
		root = (packed as PackedScene).instantiate()
	print("[PROBE] car=%s model=%s" % [_car, model])
	var seen := {}
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			continue
		for s in mi.mesh.get_surface_count():
			var mat := mi.get_active_material(s)
			if mat == null:
				continue
			var nm := _material_name(mat)
			if not _print_all and not nm.contains(_match):
				continue
			var key := nm + "|" + mat.get_class()
			seen[key] = true
			_dump_material(nm, mat, String(root.get_path_to(mi)), s, root)
	# 去重打印的汇总只针对匹配到的材质数量
	print("[PROBE] matched material instances (unique name|class) = %d" % seen.size())
	root.free()
	quit(0)


func _dump_material(nm: String, mat: Material, node_path: String, surface: int, root: Node) -> void:
	print("---- material '%s' [%s] node=%s surface=%d" % [nm, mat.get_class(), node_path, surface])
	if not (mat is BaseMaterial3D):
		print("     (非 BaseMaterial3D，属性列表:)")
		for p in mat.get_property_list():
			if String(p.get("name", "")).is_empty():
				continue
			var pname := String(p.get("name"))
			var pval := str(mat.get(pname)).substr(0, 120)
			print("     %s = %s" % [pname, pval])
		return
	var bm := mat as BaseMaterial3D
	var keys := [
		"albedo_color", "albedo_texture", "metallic", "metallic_specular",
		"roughness", "transparency", "blend_mode", "alpha_scissor_threshold",
		"cull_mode", "shading_mode", "clearcoat_enabled", "clearcoat",
		"clearcoat_roughness", "emission_enabled", "emission",
		"emission_energy_multiplier", "rim_enabled", "rim", "rim_tint",
		"anisotropy_enabled", "normal_enabled", "ao_enabled", "orm_texture",
	]
	for k in keys:
		var v = bm.get(k)
		var vs := str(v)
		if v is Texture2D:
			vs = "Texture2D(path=%s)" % (v as Texture2D).resource_path
		elif v is Color:
			var c := v as Color
			vs = "(%.3f,%.3f,%.3f,%.3f)" % [c.r, c.g, c.b, c.a]
		print("     %s = %s" % [k, vs])


func _material_name(mat: Material) -> String:
	var nm := String(mat.resource_name)
	if nm.is_empty():
		nm = String(mat.get_meta("gltf_material_name", ""))
	return nm


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
