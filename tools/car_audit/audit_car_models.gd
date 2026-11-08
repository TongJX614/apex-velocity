extends SceneTree
## APEX VELOCITY · 极速巅峰 — 车模升级前基线审计工具
##
## 用途：对 assets/cars/models/*.glb（按 data/car_manifest.json 索引）逐台审计：
##   - 加载/实例化是否成功、rootName 是否符合 manifest
##   - 节点层级：Wheel_FL/FR/RL/RR、Spin_Wheel_*、SteerPivot、WingMount 是否存在
##   - 轮子：Spin 轴心（相对模型根）与轮子几何中心偏移、轮半径（与 manifest wheelRadius 对比）
##   - 模型 AABB：应在 X/Z 居中、Y min ≈ 0
##   - 三角面数 / mesh 数 / surface 数 / 节点数
##   - 材质：材质名、albedo_color、是否有 albedo 贴图、metallic、roughness、
##           transparency 枚举、cull_mode、clearcoat、emission、cast_shadow
##   - 异常汇总：纯白无贴图材质、transparency != 0（尤其 4=ALPHA_DEPTH_PRE_PASS）、
##           玻璃材质、轮子 pivot 偏移、节点缺失、AABB 偏轴
##
## 运行（不依赖 autoload，直接 FileAccess 读取 manifest）：
##   /Users/tong/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##       --script res://tools/car_audit/audit_car_models.gd
##
## 可选参数（放在 Godot 参数 "--" 之后）：
##   --out-report=/tmp/car_audit_report.txt   （人读报告）
##   --out-json=/tmp/car_audit.json           （机器读 JSON）
##   --manifest=res://data/car_manifest.json  （默认即此）
##
## 退出码：0 = 审计完成（即使存在异常也继续跑完全部车辆）；2 = manifest 读取失败。

const DEFAULT_MANIFEST := "res://data/car_manifest.json"
const DEFAULT_CARS_DIR := "res://assets/cars/models"
const DEFAULT_REPORT_PATH := "/tmp/car_audit_report.txt"
const DEFAULT_JSON_PATH := "/tmp/car_audit.json"

const WHEEL_SUFFIXES: Array[String] = ["FL", "FR", "RL", "RR"]

## 判定阈值
const WHEEL_PIVOT_OFFSET_TOL := 0.03      ## Spin 轴心 vs 轮几何中心 (m)
const WHITE_CHANNEL_MIN := 0.80           ## 纯白材质 R/G/B 下限
const WHITE_METALLIC_MAX := 0.35          ## 纯白材质 metallic 上限（金属白不算白膜）
const AABB_X_CENTER_TOL := 0.10           ## 车身 AABB X 中心偏离 (m)
const AABB_Z_CENTER_TOL := 0.30           ## 车身 AABB Z 中心偏离 (m)
const AABB_Y_MIN_TOL := 0.05              ## 车身 AABB 最低点偏离 0 (m)
const WHEEL_RADIUS_TOL_PCT := 0.10        ## 轮半径 vs manifest wheelRadius 误差
const DETAIL_MATERIAL_CAP := 60           ## TXT 报告每台车最多列多少条材质

const TRANSPARENCY_NAMES: Array[String] = [
	"DISABLED", "ALPHA", "ALPHA_SCISSOR", "ALPHA_HASH", "ALPHA_DEPTH_PRE_PASS",
]
const CULL_MODE_NAMES: Array[String] = ["BACK", "FRONT", "DISABLED"]
const CAST_SHADOW_NAMES: Array[String] = ["OFF", "ON", "DOUBLE_SIDED", "SHADOWS_ONLY"]

var _manifest_path := DEFAULT_MANIFEST
var _cars_dir := DEFAULT_CARS_DIR
var _report_path := DEFAULT_REPORT_PATH
var _json_path := DEFAULT_JSON_PATH


func _init() -> void:
	_parse_user_args()

	var manifest := _read_json(_manifest_path)
	if manifest.is_empty():
		printerr("[CAR-AUDIT] 无法读取 manifest: " + _manifest_path)
		quit(2)
		return

	var result := _run_audit(manifest)
	_write_outputs(result)
	quit(0)


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------

func _run_audit(manifest: Dictionary) -> Dictionary:
	var cars_doc: Dictionary = manifest.get("cars", {})
	var manifest_ids: Array[String] = []
	for k in cars_doc.keys():
		manifest_ids.append(String(k))
	manifest_ids.sort()

	# 磁盘上的 GLB（用于交叉核对 manifest）
	var disk_glbs: Array[String] = []
	if DirAccess.dir_exists_absolute(_cars_dir):
		for f in DirAccess.get_files_at(_cars_dir):
			if f.ends_with(".glb"):
				disk_glbs.append(String(f))
	disk_glbs.sort()
	var disk_set := {}
	for f in disk_glbs:
		disk_set[f] = true

	var cars_out: Dictionary = {}
	var missing_model_entries: Array[String] = []
	var glb_not_in_manifest: Array[String] = []
	var manifest_ids_without_glb: Array[String] = []

	# 异常名单（供 summary / TXT 汇总）
	var load_failures: Array[String] = []
	var node_missing_cars: Dictionary = {}
	var wheel_missing_cars: Dictionary = {}
	var steer_missing: Array[String] = []
	var wing_missing: Array[String] = []
	var transparent_cars: Dictionary = {}
	var depth_prepass_cars: Dictionary = {}
	var white_no_tex_cars: Dictionary = {}
	var glass_cars: Dictionary = {}
	var emission_cars: Dictionary = {}
	var cast_shadow_off_cars: Dictionary = {}
	var no_albedo_texture_cars: Array[String] = []
	var pivot_offset_cars: Dictionary = {}
	var radius_mismatch_cars: Dictionary = {}
	var aabb_off_cars: Dictionary = {}
	var missing_material_cars: Array[String] = []
	var rootname_mismatch_cars: Dictionary = {}
	var white_nonpaint_cars: Dictionary = {}
	var clearcoat_source_cars: Dictionary = {}
	var clearcoat_dropped_cars: Dictionary = {}
	var missing_texture_cars: Dictionary = {}
	var embedded_texture_cars: Dictionary = {}
	var alpha_mismatch_cars: Dictionary = {}
	var paint_untextured_cars: Dictionary = {}

	var lib_total_nodes := 0
	var lib_total_meshes := 0
	var lib_total_surfaces := 0
	var lib_total_tris := 0
	var lib_total_materials := 0
	var lib_total_transparent_mats := 0
	var lib_total_white_mats := 0
	var lib_total_textured_surfaces := 0
	var lib_total_unique_textures := 0
	var lib_total_missing_textures := 0
	var lib_total_clearcoat_source := 0
	var lib_total_clearcoat_imported := 0
	var lib_total_clearcoat_dropped := 0
	var lib_total_paint_surfaces := 0
	var lib_total_paint_textured := 0

	for car_id in manifest_ids:
		var entry: Dictionary = cars_doc.get(car_id, {})
		var model := String(entry.get("model", ""))
		var expected_root := String(entry.get("rootName", ""))
		var manifest_radius := float(entry.get("wheelRadius", 0.0))
		var car_result := {
			"id": car_id,
			"name": String(entry.get("name", "")),
			"cn": String(entry.get("cn", "")),
			"model": model,
			"model_path": "",
			"model_exists": false,
			"model_size": 0,
			"model_sha256": "",
			"load_ok": false,
			"instantiate_ok": false,
			"error": "",
			"root_name_expected": expected_root,
			"root_name_actual": "",
			"root_name_path": "",
			"root_name_matches": false,
			"manifest_wheel_radius": manifest_radius,
			"manifest": entry,
			"source_glb": {},
			"counts": {},
			"node_presence": {},
			"nodes": [],
			"wheels": {},
			"aabb": {},
			"materials": [],
			"anomalies": [],
			"flags": {},
		}
		if model.is_empty():
			missing_model_entries.append(car_id)
			car_result["error"] = "manifest 无 model 字段"
			load_failures.append(car_id)
			car_result["anomalies"].append("manifest 无 model 字段")
			cars_out[car_id] = car_result
			continue
		var model_path := _cars_dir.path_join(model)
		car_result["model_path"] = model_path
		if not disk_set.has(model):
			manifest_ids_without_glb.append(car_id)
		if not FileAccess.file_exists(model_path):
			car_result["error"] = "GLB 文件不存在: " + model_path
			load_failures.append(car_id)
			car_result["anomalies"].append("GLB 文件不存在")
			cars_out[car_id] = car_result
			continue
		car_result["model_exists"] = true
		car_result["model_size"] = _file_size(model_path)
		car_result["model_sha256"] = _file_sha256(model_path)
		# 直接解析源 GLB 的 JSON chunk（绕过 Godot 导入缓存），用于「源文件 vs 导入结果」交叉核对
		var source_info := _glb_source_info(model_path)
		car_result["source_glb"] = source_info

		# --- 加载并实例化 ---
		var packed = load(model_path)
		if not (packed is PackedScene):
			car_result["error"] = "load() 未返回 PackedScene"
			load_failures.append(car_id)
			car_result["anomalies"].append("PackedScene 加载失败")
			cars_out[car_id] = car_result
			continue
		car_result["load_ok"] = true
		var root: Node = (packed as PackedScene).instantiate()
		if root == null:
			car_result["error"] = "instantiate() 返回 null"
			load_failures.append(car_id)
			car_result["anomalies"].append("实例化失败")
			cars_out[car_id] = car_result
			continue
		car_result["instantiate_ok"] = true
		if not (root is Node3D):
			car_result["error"] = "根节点不是 Node3D (%s)" % root.get_class()
			load_failures.append(car_id)
			root.free()
			cars_out[car_id] = car_result
			continue
		var root3d := root as Node3D
		car_result["root_name_actual"] = String(root.name)
		# manifest 的 rootName("CarRoot") 通常是导入场景根（文件名同名节点）下面的 glTF 场景根，
		# 所以同时接受「根节点同名」和「子树内存在同名节点」两种布局。
		var expected_root_path := ""
		if not expected_root.is_empty():
			var expected_node := root3d.find_child(expected_root, true, false)
			if expected_node != null:
				expected_root_path = String(root3d.get_path_to(expected_node))
		car_result["root_name_path"] = expected_root_path
		car_result["root_name_matches"] = expected_root.is_empty() \
			or String(root.name) == expected_root or not expected_root_path.is_empty()
		if not car_result["root_name_matches"]:
			rootname_mismatch_cars[car_id] = "%s (期望 %s)" % [root.name, expected_root]
			car_result["anomalies"].append("rootName 不符: 实际 %s / manifest %s" % [root.name, expected_root])

		_audit_car(car_id, car_result, root3d, root3d, source_info)

		# 汇总 library 统计
		var counts: Dictionary = car_result["counts"]
		lib_total_nodes += int(counts.get("nodes", 0))
		lib_total_meshes += int(counts.get("meshes", 0))
		lib_total_surfaces += int(counts.get("surfaces", 0))
		lib_total_tris += int(counts.get("triangles", 0))
		lib_total_materials += int(counts.get("material_names", 0))
		lib_total_transparent_mats += int(counts.get("transparent_materials", 0))
		lib_total_white_mats += int(counts.get("white_no_texture_materials", 0))
		lib_total_textured_surfaces += int(counts.get("textured_surfaces", 0))
		lib_total_unique_textures += int(counts.get("unique_textures", 0))
		lib_total_missing_textures += int(counts.get("missing_texture_surfaces", 0))
		lib_total_clearcoat_source += int(counts.get("clearcoat_source_materials", 0))
		lib_total_clearcoat_imported += int(counts.get("clearcoat_imported_materials", 0))
		lib_total_clearcoat_dropped += int(counts.get("clearcoat_dropped_materials", 0))
		lib_total_paint_surfaces += int(counts.get("paint_named_surfaces", 0))
		lib_total_paint_textured += int(counts.get("paint_textured_surfaces", 0))

		_collect_lists(car_result, car_id,
			transparent_cars, depth_prepass_cars, white_no_tex_cars, glass_cars,
			emission_cars, cast_shadow_off_cars, pivot_offset_cars, radius_mismatch_cars,
			aabb_off_cars, node_missing_cars, wheel_missing_cars,
			steer_missing, wing_missing, missing_material_cars, no_albedo_texture_cars,
			white_nonpaint_cars, clearcoat_source_cars, clearcoat_dropped_cars,
			missing_texture_cars, embedded_texture_cars, alpha_mismatch_cars,
			paint_untextured_cars)

		root.free()
		cars_out[car_id] = car_result

	# manifest 中不存在但磁盘上有的 GLB
	var manifest_model_set := {}
	for car_id in manifest_ids:
		var e: Dictionary = cars_doc.get(car_id, {})
		manifest_model_set[String(e.get("model", ""))] = true
	for f in disk_glbs:
		if manifest_model_set.has(f):
			continue
		var gid := String(f).get_basename()
		glb_not_in_manifest.append(f)
		cars_out[gid] = {
			"id": gid, "model": f, "in_manifest": false,
			"error": "GLB 存在但 manifest 无索引", "anomalies": ["manifest 无索引"],
		}

	var summary := {
		"generated_at": Time.get_datetime_string_from_system(),
		"unix_time": Time.get_unix_time_from_system(),
		"godot_version": str(Engine.get_version_info().get("string", "")),
		"godot_version_info": Engine.get_version_info(),
		"os": OS.get_name(),
		"manifest_path": _manifest_path,
		"manifest_version": int(manifest.get("version", -1)),
		"cars_dir": _cars_dir,
		"manifest_car_count": manifest_ids.size(),
		"glb_files_on_disk": disk_glbs.size(),
		"audited_cars": cars_out.size(),
		"library_totals": {
			"nodes": lib_total_nodes,
			"meshes": lib_total_meshes,
			"surfaces": lib_total_surfaces,
			"triangles": lib_total_tris,
			"material_names": lib_total_materials,
			"transparent_materials": lib_total_transparent_mats,
			"white_no_texture_materials": lib_total_white_mats,
			"textured_surfaces": lib_total_textured_surfaces,
			"unique_textures": lib_total_unique_textures,
			"missing_texture_surfaces": lib_total_missing_textures,
			"clearcoat_source_materials": lib_total_clearcoat_source,
			"clearcoat_imported_materials": lib_total_clearcoat_imported,
			"clearcoat_dropped_materials": lib_total_clearcoat_dropped,
			"paint_named_surfaces": lib_total_paint_surfaces,
			"paint_textured_surfaces": lib_total_paint_textured,
		},
		"anomaly_counts": {
			"load_failures": load_failures.size(),
			"rootname_mismatch": rootname_mismatch_cars.size(),
			"node_missing_cars": node_missing_cars.size(),
			"wheel_node_missing_cars": wheel_missing_cars.size(),
			"transparent_material_cars": transparent_cars.size(),
			"depth_prepass_cars": depth_prepass_cars.size(),
			"white_no_texture_cars": white_no_tex_cars.size(),
			"white_no_texture_nonpaint_cars": white_nonpaint_cars.size(),
			"glass_material_cars": glass_cars.size(),
			"emission_material_cars": emission_cars.size(),
			"cast_shadow_off_cars": cast_shadow_off_cars.size(),
			"no_albedo_texture_cars": no_albedo_texture_cars.size(),
			"missing_texture_cars": missing_texture_cars.size(),
			"embedded_texture_cars": embedded_texture_cars.size(),
			"clearcoat_source_cars": clearcoat_source_cars.size(),
			"clearcoat_dropped_cars": clearcoat_dropped_cars.size(),
			"alpha_import_mismatch_cars": alpha_mismatch_cars.size(),
			"paint_fully_untextured_cars": paint_untextured_cars.size(),
			"wheel_pivot_offset_cars": pivot_offset_cars.size(),
			"wheel_radius_mismatch_cars": radius_mismatch_cars.size(),
			"aabb_off_cars": aabb_off_cars.size(),
			"missing_material_cars": missing_material_cars.size(),
			"manifest_missing_model": missing_model_entries.size(),
			"manifest_id_without_glb": manifest_ids_without_glb.size(),
			"glb_without_manifest": glb_not_in_manifest.size(),
		},
		"anomaly_lists": {
			"load_failures": load_failures,
			"rootname_mismatch": _sorted_keys(rootname_mismatch_cars),
			"node_missing": node_missing_cars,
			"wheel_node_missing": wheel_missing_cars,
			"steer_pivot_missing": steer_missing,
			"wing_mount_missing": wing_missing,
			"transparent_materials": transparent_cars,
			"depth_prepass_materials": depth_prepass_cars,
			"white_no_texture": white_no_tex_cars,
			"white_no_texture_nonpaint": white_nonpaint_cars,
			"glass_materials": glass_cars,
			"emission_materials": emission_cars,
			"cast_shadow_off": cast_shadow_off_cars,
			"no_albedo_texture_cars": no_albedo_texture_cars,
			"missing_texture_cars": missing_texture_cars,
			"embedded_texture_cars": embedded_texture_cars,
			"clearcoat_source_cars": clearcoat_source_cars,
			"clearcoat_dropped_cars": clearcoat_dropped_cars,
			"alpha_import_mismatch_cars": alpha_mismatch_cars,
			"paint_untextured_cars": paint_untextured_cars,
			"wheel_pivot_offset": pivot_offset_cars,
			"wheel_radius_mismatch": radius_mismatch_cars,
			"aabb_off": aabb_off_cars,
			"missing_materials": missing_material_cars,
			"manifest_missing_model": missing_model_entries,
			"manifest_id_without_glb": manifest_ids_without_glb,
			"glb_without_manifest": glb_not_in_manifest,
		},
	}

	return {
		"tool": "tools/car_audit/audit_car_models.gd",
		"purpose": "pre-upgrade baseline audit of APEX VELOCITY car models",
		"thresholds": {
			"wheel_pivot_offset_tol": WHEEL_PIVOT_OFFSET_TOL,
			"white_channel_min": WHITE_CHANNEL_MIN,
			"aabb_x_center_tol": AABB_X_CENTER_TOL,
			"aabb_z_center_tol": AABB_Z_CENTER_TOL,
			"aabb_y_min_tol": AABB_Y_MIN_TOL,
			"wheel_radius_tol_pct": WHEEL_RADIUS_TOL_PCT,
		},
		"summary": summary,
		"cars": cars_out,
	}


# ---------------------------------------------------------------------------
# 单车审计
# ---------------------------------------------------------------------------

func _audit_car(car_id: String, car_result: Dictionary, root: Node3D, root_node: Node, source_info: Dictionary) -> void:
	var anomalies: Array = car_result["anomalies"]
	var source_by_name: Dictionary = source_info.get("material_by_name", {})
	var source_material_count := int(source_info.get("material_count", 0))
	var source_alpha_blend := int(source_info.get("alpha_blend", 0))
	var source_alpha_mask := int(source_info.get("alpha_mask", 0))
	var source_clearcoat := int(source_info.get("clearcoat_materials", 0))
	var source_double_sided := int(source_info.get("double_sided_materials", 0))

	# ---- 节点清单 ----
	var node_paths: Array = []
	var node_count := 0
	var mesh_nodes: Array[MeshInstance3D] = []
	_walk_nodes(root_node, root_node, node_paths, mesh_nodes)
	node_count = node_paths.size()

	# ---- 期望节点 ----
	var presence := {
		"Wheel_FL": null, "Wheel_FR": null, "Wheel_RL": null, "Wheel_RR": null,
		"Spin_Wheel_FL": null, "Spin_Wheel_FR": null, "Spin_Wheel_RL": null, "Spin_Wheel_RR": null,
		"SteerPivot": null, "WingMount": null,
	}
	var missing: Array[String] = []
	for nm in presence.keys():
		var found := root_node.find_child(String(nm), true, false)
		if found != null:
			presence[nm] = String(root_node.get_path_to(found))
		else:
			missing.append(String(nm))
	# SteerPivot / WingMount 允许变体命名：模糊匹配（记录全部）
	var steer_nodes: Array[String] = []
	var wing_nodes: Array[String] = []
	for np in node_paths:
		var base := String(np).get_file()
		var lower := base.to_lower()
		if lower.begins_with("steer") or lower.contains("steerpivot"):
			steer_nodes.append(String(np))
		if lower.begins_with("wingmount") or lower == "wingmount":
			wing_nodes.append(String(np))
	if presence["SteerPivot"] == null and steer_nodes.size() > 0:
		presence["SteerPivot"] = steer_nodes[0] + "  (模糊匹配)"
		missing.erase("SteerPivot")
	if presence["WingMount"] == null and wing_nodes.size() > 0:
		presence["WingMount"] = wing_nodes[0] + "  (模糊匹配)"
		missing.erase("WingMount")

	# ---- AABB + mesh / surface / tri ----
	var aabb := AABB()
	var aabb_init := false
	var total_tris := 0
	var total_surfaces := 0
	var tex_surfaces := 0
	var missing_material_surfaces := 0
	var mesh_count := 0
	for mi in mesh_nodes:
		if mi.mesh == null:
			continue
		mesh_count += 1
		var xf := _rel_xform(mi, root)
		var box := xf * mi.get_aabb()
		aabb = aabb.merge(box) if aabb_init else box
		aabb_init = true
		var mesh := mi.mesh
		for s in mesh.get_surface_count():
			total_surfaces += 1
			total_tris += _surface_triangles(mesh, s)
			var mat := mi.get_active_material(s)
			if mat == null:
				missing_material_surfaces += 1
			elif mat is BaseMaterial3D and (mat as BaseMaterial3D).albedo_texture != null:
				tex_surfaces += 1

	# ---- 材质明细 ----
	var mats: Array = []
	var seen_names := {}
	var trans_count := 0
	var depth_prepass_count := 0
	var white_count := 0
	var white_paint_count := 0
	var white_nonpaint_count := 0
	var cast_off_count := 0
	var emission_count := 0
	var glass_count := 0
	var paint_count := 0
	var paint_textured_count := 0
	var paint_untextured_names := {}
	var textured_surfaces := 0
	var embedded_tex_surfaces := 0
	var missing_tex_surfaces := 0
	var cull_disabled_surfaces := 0
	var clearcoat_imported_names := {}
	var clearcoat_source_names := {}
	var clearcoat_dropped_names := {}
	var alpha_imported_but_opaque_source := {}
	var alpha_missing_names := {}
	var unique_textures: Array[String] = []
	var missing_textures: Array[String] = []
	var tex_exists_cache := {}
	for mi in mesh_nodes:
		if mi.mesh == null or mi.mesh.get_surface_count() == 0:
			# 仍记录 cast_shadow 异常
			if mi.cast_shadow == 0:
				cast_off_count += 1
			continue
		if mi.cast_shadow == 0:
			cast_off_count += 1
		var node_path := String(root_node.get_path_to(mi))
		var mesh := mi.mesh
		for s in mesh.get_surface_count():
			var mat := mi.get_active_material(s)
			var rec := {
				"node": node_path,
				"surface": s,
				"material": "",
				"material_class": "",
				"albedo": "",
				"has_albedo_texture": false,
				"albedo_texture": "",
				"metallic": null,
				"roughness": null,
				"transparency": null,
				"transparency_name": "",
				"cull_mode": null,
				"cull_mode_name": "",
				"clearcoat": null,
				"emission": false,
				"emission_color": "",
				"is_glass_name": false,
				"is_paint_name": false,
				"suspicious_white": false,
				"cast_shadow": mi.cast_shadow,
				"cast_shadow_name": _enum_name(CAST_SHADOW_NAMES, mi.cast_shadow),
				"albedo_texture_exists": false,
				"albedo_texture_embedded": false,
				"source_alpha_mode": "",
				"source_clearcoat": false,
				"source_double_sided": false,
				"source_metallic": null,
				"source_roughness": null,
			}
			if mat == null:
				rec["material"] = "<无材质>"
				rec["material_class"] = ""
				mats.append(rec)
				continue
			rec["material"] = _material_name(mat)
			rec["material_class"] = mat.get_class()
			var mname := String(rec["material"])
			seen_names[mname.to_lower()] = true
			var lower := mname.to_lower()
			rec["is_glass_name"] = _is_glass_name(lower)
			rec["is_paint_name"] = _is_paint_name(lower)
			if mat is BaseMaterial3D:
				var bm := mat as BaseMaterial3D
				var col := bm.albedo_color
				rec["albedo"] = _col_text(col)
				rec["has_albedo_texture"] = bm.albedo_texture != null
				if bm.albedo_texture != null:
					var tex_path := String(bm.albedo_texture.resource_path)
					rec["albedo_texture"] = tex_path
					textured_surfaces += 1
					if tex_path.is_empty():
						# glTF 内嵌贴图（没有独立 png 资源路径）
						rec["albedo_texture_embedded"] = true
						embedded_tex_surfaces += 1
					else:
						if not tex_exists_cache.has(tex_path):
							var exists := FileAccess.file_exists(tex_path)
							tex_exists_cache[tex_path] = exists
							if exists:
								unique_textures.append(tex_path)
							else:
								missing_textures.append(tex_path)
						var tex_ok := bool(tex_exists_cache[tex_path])
						rec["albedo_texture_exists"] = tex_ok
						if not tex_ok:
							missing_tex_surfaces += 1
				rec["metallic"] = bm.metallic
				rec["roughness"] = bm.roughness
				rec["transparency"] = bm.transparency
				rec["transparency_name"] = _enum_name(TRANSPARENCY_NAMES, bm.transparency)
				rec["cull_mode"] = bm.cull_mode
				rec["cull_mode_name"] = _enum_name(CULL_MODE_NAMES, bm.cull_mode)
				if bm.cull_mode == 2:
					cull_disabled_surfaces += 1
				rec["clearcoat"] = bm.clearcoat_enabled
				rec["emission"] = bm.emission_enabled
				if bm.emission_enabled:
					rec["emission_color"] = _col_text(bm.emission) + " e=%.2f" % bm.emission_energy_multiplier
				if bm.transparency != 0:
					trans_count += 1
					if bm.transparency == 4:
						depth_prepass_count += 1
				if rec["is_glass_name"]:
					glass_count += 1
				if rec["is_paint_name"]:
					paint_count += 1
					if bm.albedo_texture != null:
						paint_textured_count += 1
					else:
						paint_untextured_names[mname] = true
				if bm.emission_enabled:
					emission_count += 1
				# ---- 源 GLB vs 导入结果交叉核对（按材质名匹配）----
				var src: Dictionary = source_by_name.get(mname, {})
				if not src.is_empty():
					var src_alpha := String(src.get("alpha_mode", "OPAQUE"))
					rec["source_alpha_mode"] = src_alpha
					rec["source_clearcoat"] = bool(src.get("clearcoat", false))
					rec["source_double_sided"] = bool(src.get("double_sided", false))
					rec["source_metallic"] = src.get("metallic", null)
					rec["source_roughness"] = src.get("roughness", null)
					if rec["source_clearcoat"]:
						clearcoat_source_names[mname] = true
					if rec["source_clearcoat"] and not bm.clearcoat_enabled:
						clearcoat_dropped_names[mname] = true
					if src_alpha == "OPAQUE" and bm.transparency != 0:
						alpha_imported_but_opaque_source[mname] = true
					if src_alpha in ["BLEND", "MASK"] and bm.transparency == 0:
						alpha_missing_names[mname] = true
				if bm.clearcoat_enabled:
					clearcoat_imported_names[mname] = true
				# 纯白无贴图：albedo_texture 空 + RGB 接近白 + 非金属 + 无自发光
				if bm.albedo_texture == null and not bm.emission_enabled \
						and col.r >= WHITE_CHANNEL_MIN and col.g >= WHITE_CHANNEL_MIN \
						and col.b >= WHITE_CHANNEL_MIN and bm.metallic < WHITE_METALLIC_MAX:
					rec["suspicious_white"] = true
					white_count += 1
					if rec["is_paint_name"]:
						white_paint_count += 1
					else:
						white_nonpaint_count += 1
			mats.append(rec)

	# ---- 轮子 ----
	var wheels := {}
	var worst_offset := 0.0
	var worst_offset_detail := ""
	var all_spin_present := true
	var all_wheel_present := true
	for suffix in WHEEL_SUFFIXES:
		var wheel_node := root_node.find_child("Wheel_" + suffix, true, false) as Node3D
		var spin_node := root_node.find_child("Spin_Wheel_" + suffix, true, false) as Node3D
		var wrec := {
			"wheel_node": null,
			"spin_node": null,
			"spin_pivot": null,
			"geom_center": null,
			"pivot_offset": null,
			"radius": null,
			"size": null,
			"mesh_count": 0,
		}
		if wheel_node == null:
			all_wheel_present = false
		else:
			wrec["wheel_node"] = String(root_node.get_path_to(wheel_node))
		if spin_node == null:
			all_spin_present = false
			wheels[suffix] = wrec
			continue
		wrec["spin_node"] = String(root_node.get_path_to(spin_node))
		var spin_xf := _rel_xform(spin_node, root)
		var pivot: Vector3 = spin_xf.origin
		wrec["spin_pivot"] = _v3(pivot)
		# 轮子几何：优先取 Spin_Wheel_* 下的 mesh，没有则取 Wheel_* 下的 mesh
		var wheel_aabb := AABB()
		var wheel_init := false
		var wmeshes: Array[MeshInstance3D] = []
		_collect_meshes(spin_node, wmeshes)
		if wmeshes.is_empty() and wheel_node != null:
			_collect_meshes(wheel_node, wmeshes)
		for wm in wmeshes:
			if wm.mesh == null:
				continue
			var wxf := _rel_xform(wm, root)
			var wbox := wxf * wm.get_aabb()
			wheel_aabb = wheel_aabb.merge(wbox) if wheel_init else wbox
			wheel_init = true
		wrec["mesh_count"] = wmeshes.size()
		if wheel_init:
			var center := wheel_aabb.get_center()
			var size := wheel_aabb.size
			var off := center.distance_to(pivot)
			wrec["geom_center"] = _v3(center)
			wrec["pivot_offset"] = snappedf(off, 0.0001)
			wrec["size"] = _v3(size)
			wrec["radius"] = snappedf(maxf(size.y, size.z) * 0.5, 0.0001)
			if off > worst_offset:
				worst_offset = off
				worst_offset_detail = "%s pivot=(%.3f,%.3f,%.3f) center=(%.3f,%.3f,%.3f) off=%.3f" % [
					suffix, pivot.x, pivot.y, pivot.z, center.x, center.y, center.z, off]
		wheels[suffix] = wrec

	# ---- AABB 判定 ----
	var aabb_dict := {"init": aabb_init}
	var aabb_ok := aabb_init
	var aabb_issues: Array[String] = []
	if aabb_init:
		var center := aabb.get_center()
		var y_min := aabb.position.y
		aabb_dict["position"] = _v3(aabb.position)
		aabb_dict["size"] = _v3(aabb.size)
		aabb_dict["end"] = _v3(aabb.end)
		aabb_dict["center"] = _v3(center)
		aabb_dict["x_center"] = snappedf(center.x, 0.0001)
		aabb_dict["z_center"] = snappedf(center.z, 0.0001)
		aabb_dict["y_min"] = snappedf(y_min, 0.0001)
		aabb_dict["x_centered"] = absf(center.x) <= AABB_X_CENTER_TOL
		aabb_dict["z_centered"] = absf(center.z) <= AABB_Z_CENTER_TOL
		aabb_dict["y_min_ok"] = absf(y_min) <= AABB_Y_MIN_TOL
		if not aabb_dict["x_centered"]:
			aabb_issues.append("AABB X 中心偏 %.3f m" % center.x)
		if not aabb_dict["z_centered"]:
			aabb_issues.append("AABB Z 中心偏 %.3f m" % center.z)
		if not aabb_dict["y_min_ok"]:
			aabb_issues.append("AABB Y min=%.3f m（应≈0）" % y_min)
	# 全车无 mesh 或空 AABB 视为异常
	if not aabb_init:
		aabb_issues.append("没有任何有效 mesh/AABB")
		aabb_ok = false

	# ---- 轮子判定 ----
	var wheel_issues: Array[String] = []
	if not all_wheel_present:
		wheel_issues.append("Wheel_* 节点缺失")
	if not all_spin_present:
		wheel_issues.append("Spin_Wheel_* 节点缺失")
	if worst_offset > WHEEL_PIVOT_OFFSET_TOL:
		wheel_issues.append("轮子 pivot 偏移 %.3f m 超过阈值 %.2f: %s" % [
			worst_offset, WHEEL_PIVOT_OFFSET_TOL, worst_offset_detail])
	var radius_mismatch := false
	var radius_detail := ""
	if car_result.has("manifest_wheel_radius"):
		var mr := float(car_result["manifest_wheel_radius"])
		if mr > 0.01:
			for suffix in WHEEL_SUFFIXES:
				var wr: Dictionary = wheels.get(suffix, {})
				if wr.get("radius", null) == null:
					continue
				var r := float(wr["radius"])
				var err := absf(r - mr) / mr
				if err > WHEEL_RADIUS_TOL_PCT:
					radius_mismatch = true
					radius_detail = "%s 半径 %.3f vs manifest %.3f (误差 %.0f%%)" % [
						suffix, r, mr, err * 100.0]
					break

	# ---- 汇总本车 anomalies ----
	if missing.size() > 0:
		anomalies.append("节点缺失: " + ", ".join(missing))
	if not all_wheel_present or not all_spin_present:
		anomalies.append("车轮节点不齐")
	if worst_offset > WHEEL_PIVOT_OFFSET_TOL:
		anomalies.append("轮子 pivot 偏移 %.3f m" % worst_offset)
	if radius_mismatch:
		anomalies.append("轮半径与 manifest 不符: " + radius_detail)
	if trans_count > 0:
		anomalies.append("透明材质 %d 个" % trans_count)
	if depth_prepass_count > 0:
		anomalies.append("!! transparency=4 ALPHA_DEPTH_PRE_PASS 材质 %d 个（可疑）" % depth_prepass_count)
	if white_count > 0:
		anomalies.append("无贴图纯白材质 %d 个（paint/车漆命名 %d 个会被运行时车漆覆盖，其余 %d 个可疑）" % [
			white_count, white_paint_count, white_nonpaint_count])
	if missing_material_surfaces > 0:
		anomalies.append("无材质 surface %d 个" % missing_material_surfaces)
	if missing_tex_surfaces > 0:
		anomalies.append("albedo 贴图文件缺失 %d 个: %s" % [
			missing_tex_surfaces, ", ".join(missing_textures)])
	if embedded_tex_surfaces > 0:
		anomalies.append("内嵌 albedo 贴图 surface %d 个（无独立 png 资源，升级后复验注意）" % embedded_tex_surfaces)
	if emission_count > 0:
		anomalies.append("自发光材质 %d 个" % emission_count)
	if cast_off_count > 0:
		anomalies.append("cast_shadow=OFF 的 mesh 节点 %d 个" % cast_off_count)
	if clearcoat_dropped_names.size() > 0:
		anomalies.append("!! 源 GLB 有 %d 个 KHR_materials_clearcoat 材质，但 Godot 导入后 clearcoat_enabled 全为 false（清漆层未生效）" % [
			clearcoat_source_names.size()])
	if alpha_imported_but_opaque_source.size() > 0:
		anomalies.append("源 alphaMode=OPAQUE 但导入为透明: " + ", ".join(_sorted_keys(alpha_imported_but_opaque_source)))
	if alpha_missing_names.size() > 0:
		anomalies.append("源半透(BLEND/MASK)但导入不透明: " + ", ".join(_sorted_keys(alpha_missing_names)))
	for a in aabb_issues:
		anomalies.append(a)
	if total_surfaces > 0 and textured_surfaces == 0:
		anomalies.append("全部 surface 无 albedo 贴图（纯色/纯白车模）")

	# ---- 写回 ----
	car_result["counts"] = {
		"nodes": node_count,
		"meshes": mesh_count,
		"surfaces": total_surfaces,
		"triangles": total_tris,
		"suspicious_white_meshes": white_count,  # 兼容旧命名
		"material_names": seen_names.size(),
		"transparent_materials": trans_count,
		"depth_prepass_materials": depth_prepass_count,
		"white_no_texture_materials": white_count,
		"white_paint_named_materials": white_paint_count,
		"white_nonpaint_materials": white_nonpaint_count,
		"glass_materials": glass_count,
		"paint_named_materials": paint_count,
		"paint_named_surfaces": paint_count,
		"paint_textured_surfaces": paint_textured_count,
		"paint_untextured_surfaces": paint_count - paint_textured_count,
		"transparent_surfaces": trans_count,
		"emission_materials": emission_count,
		"cast_shadow_off_meshes": cast_off_count,
		"cull_disabled_surfaces": cull_disabled_surfaces,
		"textured_surfaces": textured_surfaces,
		"unique_textures": unique_textures.size(),
		"missing_texture_surfaces": missing_tex_surfaces,
		"embedded_texture_surfaces": embedded_tex_surfaces,
		"missing_material_surfaces": missing_material_surfaces,
		"clearcoat_imported_materials": clearcoat_imported_names.size(),
		"clearcoat_source_materials": clearcoat_source_names.size(),
		"clearcoat_dropped_materials": clearcoat_dropped_names.size(),
		"source_material_count": source_material_count,
		"source_alpha_blend": source_alpha_blend,
		"source_alpha_mask": source_alpha_mask,
		"source_double_sided_materials": source_double_sided,
	}
	car_result["node_presence"] = {
		"present": presence,
		"missing": missing,
		"steer_nodes": steer_nodes,
		"wing_mount_nodes": wing_nodes,
		"node_paths": node_paths,
	}
	car_result["wheels"] = wheels
	car_result["wheels_worst_offset"] = snappedf(worst_offset, 0.0001)
	car_result["wheels_worst_offset_detail"] = worst_offset_detail
	car_result["aabb"] = aabb_dict
	car_result["materials"] = mats
	car_result["flags"] = {
		"all_wheel_nodes_present": all_wheel_present,
		"all_spin_nodes_present": all_spin_present,
		"steer_pivot_present": presence["SteerPivot"] != null,
		"wing_mount_present": presence["WingMount"] != null,
		"has_transparent_material": trans_count > 0,
		"has_depth_prepass": depth_prepass_count > 0,
		"has_white_no_texture": white_count > 0,
		"has_white_no_texture_nonpaint": white_nonpaint_count > 0,
		"has_glass_name_material": glass_count > 0,
		"has_emission_material": emission_count > 0,
		"has_any_albedo_texture": textured_surfaces > 0,
		"has_missing_texture_files": missing_tex_surfaces > 0,
		"has_embedded_textures": embedded_tex_surfaces > 0,
		"clearcoat_imported": clearcoat_imported_names.size() > 0,
		"clearcoat_source_dropped": clearcoat_dropped_names.size() > 0,
		"paint_fully_untextured": paint_count > 0 and paint_textured_count == 0,
		"paint_partially_textured": paint_textured_count > 0 and paint_textured_count < paint_count,
		"source_has_clearcoat": clearcoat_source_names.size() > 0,
		"alpha_import_mismatch": alpha_imported_but_opaque_source.size() > 0 or alpha_missing_names.size() > 0,
		"wheel_pivot_offset_bad": worst_offset > WHEEL_PIVOT_OFFSET_TOL,
		"wheel_radius_mismatch": radius_mismatch,
		"aabb_ok": aabb_ok,
		"full_flat_color_model": total_surfaces > 0 and textured_surfaces == 0,
	}
	car_result["anomalies"] = anomalies


# ---------------------------------------------------------------------------
# 异常名单收集
# ---------------------------------------------------------------------------

func _collect_lists(car_result: Dictionary, car_id: String,
		transparent_cars: Dictionary, depth_prepass_cars: Dictionary,
		white_no_tex_cars: Dictionary, glass_cars: Dictionary,
		emission_cars: Dictionary, cast_shadow_off_cars: Dictionary,
		pivot_offset_cars: Dictionary, radius_mismatch_cars: Dictionary,
		aabb_off_cars: Dictionary, node_missing_cars: Dictionary,
		wheel_missing_cars: Dictionary, steer_missing: Array[String],
		wing_missing: Array[String], missing_material_cars: Array[String],
		no_albedo_texture_cars: Array[String],
		white_nonpaint_cars: Dictionary, clearcoat_source_cars: Dictionary,
		clearcoat_dropped_cars: Dictionary, missing_texture_cars: Dictionary,
		embedded_texture_cars: Dictionary, alpha_mismatch_cars: Dictionary,
		paint_untextured_cars: Dictionary) -> void:
	var flags: Dictionary = car_result.get("flags", {})
	var counts: Dictionary = car_result.get("counts", {})
	var presence: Dictionary = car_result.get("node_presence", {})
	var mats: Array = car_result.get("materials", [])

	if flags.get("has_transparent_material", false):
		var names: Array[String] = []
		for m in mats:
			if m.get("transparency", 0) != null and int(m.get("transparency", 0)) != 0:
				var nm := String(m.get("material", ""))
				if not names.has(nm):
					names.append(nm)
		transparent_cars[car_id] = {
			"count": int(counts.get("transparent_materials", 0)),
			"materials": names,
		}
	if flags.get("has_depth_prepass", false):
		depth_prepass_cars[car_id] = int(counts.get("depth_prepass_materials", 0))
	if flags.get("has_white_no_texture", false):
		var names: Array[String] = []
		var nonpaint_names: Array[String] = []
		for m in mats:
			if bool(m.get("suspicious_white", false)):
				var nm := String(m.get("material", ""))
				if not names.has(nm):
					names.append(nm)
				if not bool(m.get("is_paint_name", false)) and not nonpaint_names.has(nm):
					nonpaint_names.append(nm)
		white_no_tex_cars[car_id] = {
			"count": int(counts.get("white_no_texture_materials", 0)),
			"paint_named": int(counts.get("white_paint_named_materials", 0)),
			"nonpaint": int(counts.get("white_nonpaint_materials", 0)),
			"materials": names,
		}
		if nonpaint_names.size() > 0:
			white_nonpaint_cars[car_id] = nonpaint_names
	if flags.get("has_glass_name_material", false):
		var names: Array[String] = []
		for m in mats:
			if bool(m.get("is_glass_name", false)):
				var nm := String(m.get("material", ""))
				if not names.has(nm):
					names.append(nm)
		glass_cars[car_id] = names
	if flags.get("has_emission_material", false):
		var names: Array[String] = []
		for m in mats:
			if bool(m.get("emission", false)):
				var nm := String(m.get("material", ""))
				if not names.has(nm):
					names.append(nm)
		emission_cars[car_id] = names
	if int(counts.get("cast_shadow_off_meshes", 0)) > 0:
		cast_shadow_off_cars[car_id] = int(counts.get("cast_shadow_off_meshes", 0))
	if flags.get("wheel_pivot_offset_bad", false):
		pivot_offset_cars[car_id] = car_result.get("wheels_worst_offset_detail", "")
	if flags.get("wheel_radius_mismatch", false):
		var detail := ""
		for a in car_result.get("anomalies", []):
			if String(a).begins_with("轮半径"):
				detail = String(a)
				break
		radius_mismatch_cars[car_id] = detail
	if not bool(flags.get("aabb_ok", true)):
		var issues: Array[String] = []
		for a in car_result.get("anomalies", []):
			if String(a).begins_with("AABB"):
				issues.append(String(a))
		aabb_off_cars[car_id] = issues
	if presence.get("missing", []).size() > 0:
		node_missing_cars[car_id] = presence.get("missing", [])
		if not bool(flags.get("steer_pivot_present", true)):
			steer_missing.append(car_id)
		if not bool(flags.get("wing_mount_present", true)):
			wing_missing.append(car_id)
	if not bool(flags.get("all_wheel_nodes_present", true)) or not bool(flags.get("all_spin_nodes_present", true)):
		wheel_missing_cars[car_id] = true
	if int(counts.get("missing_material_surfaces", 0)) > 0:
		missing_material_cars.append(car_id)
	if int(counts.get("surfaces", 0)) > 0 and not bool(flags.get("has_any_albedo_texture", false)):
		no_albedo_texture_cars.append(car_id)
	if flags.get("source_has_clearcoat", false):
		clearcoat_source_cars[car_id] = int(counts.get("clearcoat_source_materials", 0))
	if flags.get("clearcoat_source_dropped", false):
		clearcoat_dropped_cars[car_id] = "源 clearcoat 材质 %d 个 -> 导入后启用 %d 个" % [
			int(counts.get("clearcoat_source_materials", 0)),
			int(counts.get("clearcoat_imported_materials", 0))]
	if flags.get("has_missing_texture_files", false):
		var missing_paths: Array[String] = []
		for m in mats:
			var tp := String(m.get("albedo_texture", ""))
			if not tp.is_empty() and not bool(m.get("albedo_texture_exists", false)) and not missing_paths.has(tp):
				missing_paths.append(tp)
		missing_texture_cars[car_id] = missing_paths
	if flags.get("has_embedded_textures", false):
		embedded_texture_cars[car_id] = int(counts.get("embedded_texture_surfaces", 0))
	if flags.get("alpha_import_mismatch", false):
		var detail: Array[String] = []
		for a in car_result.get("anomalies", []):
			if String(a).begins_with("源 alphaMode") or String(a).begins_with("源半透"):
				detail.append(String(a))
		alpha_mismatch_cars[car_id] = detail
	if int(counts.get("paint_named_surfaces", 0)) > 0 and int(counts.get("paint_untextured_surfaces", 0)) > 0:
		var names: Array[String] = []
		for m in mats:
			if bool(m.get("is_paint_name", false)) and not bool(m.get("has_albedo_texture", false)):
				var nm := String(m.get("material", ""))
				if not names.has(nm):
					names.append(nm)
		paint_untextured_cars[car_id] = {
			"paint_surfaces": int(counts.get("paint_named_surfaces", 0)),
			"paint_textured_surfaces": int(counts.get("paint_textured_surfaces", 0)),
			"untextured_paint_materials": names,
		}


# ---------------------------------------------------------------------------
# 输出
# ---------------------------------------------------------------------------

func _write_outputs(result: Dictionary) -> void:
	var txt := _build_report_text(result)
	var jtxt := JSON.stringify(result, "\t")
	var err1 := _write_file(_report_path, txt)
	var err2 := _write_file(_json_path, jtxt)
	print("[CAR-AUDIT] report -> %s (err=%d, %d bytes)" % [_report_path, err1, txt.length()])
	print("[CAR-AUDIT] json   -> %s (err=%d, %d bytes)" % [_json_path, err2, jtxt.length()])
	print("[CAR-AUDIT] " + _summary_one_line(result))


func _build_report_text(result: Dictionary) -> String:
	var summary: Dictionary = result["summary"]
	var lists: Dictionary = summary["anomaly_lists"]
	var counts: Dictionary = summary["anomaly_counts"]
	var totals: Dictionary = summary["library_totals"]
	var lines: PackedStringArray = []

	lines.append("APEX VELOCITY · 极速巅峰 — 车模升级前基线审计报告")
	lines.append("生成时间: %s   Godot: %s   OS: %s" % [
		summary["generated_at"], summary["godot_version"], summary["os"]])
	lines.append("manifest: %s (version=%d, cars=%d)" % [
		summary["manifest_path"], summary["manifest_version"], summary["manifest_car_count"]])
	lines.append("模型目录: %s   磁盘 GLB: %d   已审计: %d" % [
		summary["cars_dir"], summary["glb_files_on_disk"], summary["audited_cars"]])
	lines.append("阈值: 轮 pivot 偏移>%.2fm / 纯白通道>=%.2f 且 metallic<%.2f / AABB X中心|%.2f| Z中心|%.2f| Ymin|%.2f| / 轮半径误差>%.0f%%" % [
		WHEEL_PIVOT_OFFSET_TOL, WHITE_CHANNEL_MIN, WHITE_METALLIC_MAX,
		AABB_X_CENTER_TOL, AABB_Z_CENTER_TOL, AABB_Y_MIN_TOL, WHEEL_RADIUS_TOL_PCT * 100.0])
	lines.append("")
	lines.append("========== 全库合计 ==========")
	lines.append("nodes=%d  meshes=%d  surfaces=%d  triangles=%d  材质名种类=%d" % [
		totals["nodes"], totals["meshes"], totals["surfaces"], totals["triangles"], totals["material_names"]])
	lines.append("透明材质=%d  纯白无贴图材质=%d  带贴图 surface=%d/%d  唯一贴图=%d  缺贴图 surface=%d" % [
		totals["transparent_materials"], totals["white_no_texture_materials"],
		totals["textured_surfaces"], totals["surfaces"], totals["unique_textures"],
		totals["missing_texture_surfaces"]])
	lines.append("源 GLB clearcoat 材质=%d  导入后启用 clearcoat=%d  丢失/未启用=%d" % [
		totals["clearcoat_source_materials"], totals["clearcoat_imported_materials"],
		totals["clearcoat_dropped_materials"]])
	lines.append("车漆材质 surface=%d  其中带 albedo 贴图=%d（%.1f%%）" % [
		totals["paint_named_surfaces"], totals["paint_textured_surfaces"],
		100.0 * float(totals["paint_textured_surfaces"]) / float(maxi(totals["paint_named_surfaces"], 1))])
	lines.append("")
	lines.append("========== 异常汇总 ==========")
	lines.append("加载/实例化失败: %d 台 -> %s" % [counts["load_failures"], _join_list(lists["load_failures"])])
	lines.append("manifest 无 model 字段: %d -> %s" % [counts["manifest_missing_model"], _join_list(lists["manifest_missing_model"])])
	lines.append("manifest 有 id 但磁盘无 GLB: %d -> %s" % [counts["manifest_id_without_glb"], _join_list(lists["manifest_id_without_glb"])])
	lines.append("磁盘 GLB 无 manifest 索引: %d -> %s" % [counts["glb_without_manifest"], _join_list(lists["glb_without_manifest"])])
	lines.append("rootName 不符(既非根也非子树节点): %d -> %s" % [counts["rootname_mismatch"], _join_list(lists["rootname_mismatch"])])
	lines.append("节点缺失(任意): %d 台 -> %s" % [counts["node_missing_cars"], _dict_keys_line(lists["node_missing"])])
	lines.append("  其中 SteerPivot 缺失 %d 台 -> %s" % [lists["steer_pivot_missing"].size(), _join_list(lists["steer_pivot_missing"])])
	lines.append("  其中 WingMount 缺失 %d 台 -> %s" % [lists["wing_mount_missing"].size(), _join_list(lists["wing_mount_missing"])])
	lines.append("Wheel/Spin 轮节点缺失: %d 台 -> %s" % [counts["wheel_node_missing_cars"], _dict_keys_line(lists["wheel_node_missing"])])
	lines.append("透明材质(transparency != 0)车辆: %d 台" % counts["transparent_material_cars"])
	lines.append("  !! transparency=4 ALPHA_DEPTH_PRE_PASS: %d 台 -> %s" % [
		counts["depth_prepass_cars"], _dict_keys_line(lists["depth_prepass_materials"])])
	lines.append("  transparency!=0 全名单:")
	_append_multi_map(lines, lists["transparent_materials"])
	lines.append("玻璃命名材质车辆: %d 台 -> %s" % [counts["glass_material_cars"], _dict_keys_line(lists["glass_materials"])])
	lines.append("无贴图纯白材质车辆: %d 台" % counts["white_no_texture_cars"])
	_append_multi_map(lines, lists["white_no_texture"])
	lines.append("  其中非 paint/车漆命名（运行时不会被车漆逻辑覆盖，可疑）: %d 台" % counts["white_no_texture_nonpaint_cars"])
	_append_multi_map(lines, lists["white_no_texture_nonpaint"])
	lines.append("全部 surface 无 albedo 贴图的「纯色车」: %d 台 -> %s" % [
		counts["no_albedo_texture_cars"], _join_list(lists["no_albedo_texture_cars"])])
	lines.append("albedo 贴图文件缺失车辆: %d 台" % counts["missing_texture_cars"])
	_append_multi_map(lines, lists["missing_texture_cars"])
	lines.append("内嵌 albedo 贴图（无独立 png）车辆: %d 台 -> %s" % [
		counts["embedded_texture_cars"], _dict_keys_line(lists["embedded_texture_cars"])])
	lines.append("自发光材质车辆: %d 台 -> %s" % [counts["emission_material_cars"], _dict_keys_line(lists["emission_materials"])])
	lines.append("cast_shadow=OFF mesh 车辆: %d 台 -> %s" % [counts["cast_shadow_off_cars"], _dict_keys_line(lists["cast_shadow_off"])])
	lines.append("源 GLB 带 clearcoat 扩展: %d 台 -> %s" % [
		counts["clearcoat_source_cars"], _dict_keys_line(lists["clearcoat_source_cars"])])
	lines.append("  !! 导入后 clearcoat 未启用: %d 台 -> %s" % [
		counts["clearcoat_dropped_cars"], _dict_keys_line(lists["clearcoat_dropped_cars"])])
	lines.append("alphaMode 导入不一致: %d 台 -> %s" % [
		counts["alpha_import_mismatch_cars"], _dict_keys_line(lists["alpha_import_mismatch_cars"])])
	lines.append("车漆材质无 albedo 贴图（运行时走调色板兜底色）: %d 台" % counts["paint_fully_untextured_cars"])
	_append_multi_map(lines, lists["paint_untextured_cars"])
	lines.append("轮子 pivot 偏移 > %.2fm: %d 台" % [WHEEL_PIVOT_OFFSET_TOL, counts["wheel_pivot_offset_cars"]])
	_append_multi_map(lines, lists["wheel_pivot_offset"])
	lines.append("轮半径与 manifest 不符: %d 台" % counts["wheel_radius_mismatch_cars"])
	_append_multi_map(lines, lists["wheel_radius_mismatch"])
	lines.append("AABB 异常(X/Z 不居中或 Y min≠0): %d 台" % counts["aabb_off_cars"])
	_append_multi_map(lines, lists["aabb_off"])
	lines.append("存在无材质 surface 的车: %d 台 -> %s" % [counts["missing_material_cars"], _join_list(lists["missing_materials"])])
	lines.append("")

	lines.append("========== 逐车详情 ==========")
	var cars: Dictionary = result["cars"]
	var ids: Array[String] = []
	for k in cars.keys():
		ids.append(String(k))
	ids.sort()
	for car_id in ids:
		var c: Dictionary = cars[car_id]
		var model := String(c.get("model", "?"))
		lines.append("")
		lines.append("=== %s  (%s)  %s ===" % [car_id, model, String(c.get("cn", ""))])
		if not bool(c.get("instantiate_ok", false)):
			lines.append("  !! 加载失败: " + String(c.get("error", "")))
			continue
		var cc: Dictionary = c["counts"]
		var flags: Dictionary = c["flags"]
		var pres: Dictionary = c["node_presence"]
		var aabb: Dictionary = c["aabb"]
		var src: Dictionary = c.get("source_glb", {})
		var root_path_text := String(c["root_name_path"])
		if root_path_text.is_empty():
			root_path_text = "<未找到>"
		lines.append("  root(导入场景根)=%s  manifest rootName=%s -> %s  匹配=%s  节点=%d mesh=%d surface=%d 三角面=%d 材质名=%d" % [
			c["root_name_actual"], c["root_name_expected"], root_path_text, str(c["root_name_matches"]),
			cc["nodes"], cc["meshes"], cc["surfaces"], cc["triangles"], cc["material_names"]])
		lines.append("  sha256=%s  size=%.1f MB" % [c["model_sha256"], float(c["model_size"]) / 1048576.0])
		if bool(src.get("parsed", false)):
			var extras: Dictionary = src.get("extras", {})
			lines.append("  源 GLB: 材质=%d BLEND=%d MASK=%d clearcoat扩展=%d doubleSided=%d nodes=%d 生成器=%s" % [
				int(src.get("material_count", 0)), int(src.get("alpha_blend", 0)), int(src.get("alpha_mask", 0)),
				int(src.get("clearcoat_materials", 0)), int(src.get("double_sided_materials", 0)),
				int(src.get("node_count", 0)), String(src.get("generator", ""))])
			if extras.size() > 0:
				lines.append("    源 extras: " + _dict_flat_text(extras))
			lines.append("    源 extensionsUsed: " + _join_list(src.get("extensions_used", [])))
		else:
			lines.append("  源 GLB: JSON chunk 解析失败（无法做源/导入交叉核对）")
		lines.append("  AABB: pos=(%s) size=(%s)  x_center=%s z_center=%s y_min=%s  [x居中=%s z居中=%s ymin≈0=%s]" % [
			_v3_text(aabb.get("position")), _v3_text(aabb.get("size")),
			str(aabb.get("x_center", "?")), str(aabb.get("z_center", "?")), str(aabb.get("y_min", "?")),
			str(aabb.get("x_centered", "?")), str(aabb.get("z_centered", "?")), str(aabb.get("y_min_ok", "?"))])
		lines.append("  轮节点: Wheel=%s Spin=%s SteerPivot=%s WingMount=%s" % [
			_flag_text(flags.get("all_wheel_nodes_present", false)),
			_flag_text(flags.get("all_spin_nodes_present", false)),
			_flag_text(flags.get("steer_pivot_present", false)),
			_flag_text(flags.get("wing_mount_present", false))])
		for suffix in WHEEL_SUFFIXES:
			var w: Dictionary = c["wheels"].get(suffix, {})
			if w.get("spin_node", null) == null:
				lines.append("    %s: 无 Spin 节点（wheel_node=%s）" % [suffix, str(w.get("wheel_node"))])
				continue
			lines.append("    %s: spin_pivot=%s geom_center=%s off=%s r=%s size=%s meshes=%d" % [
				suffix, _v3_text(w.get("spin_pivot")), _v3_text(w.get("geom_center")),
				str(w.get("pivot_offset")), str(w.get("radius")), _v3_text(w.get("size")),
				int(w.get("mesh_count", 0))])
		if pres["missing"].size() > 0:
			lines.append("  缺失节点: " + ", ".join(pres["missing"]))
		if pres["steer_nodes"].size() > 0:
			lines.append("  Steer 相关节点: " + ", ".join(pres["steer_nodes"]))
		if pres["wing_mount_nodes"].size() > 0:
			lines.append("  WingMount 节点: " + ", ".join(pres["wing_mount_nodes"]))
		lines.append("  贴图: 带 albedo 贴图 surface=%d/%d  唯一贴图=%d  缺失文件 surface=%d  内嵌 surface=%d" % [
			cc["textured_surfaces"], cc["surfaces"], cc["unique_textures"],
			cc["missing_texture_surfaces"], cc["embedded_texture_surfaces"]])
		lines.append("  clearcoat: 源扩展材质=%d  导入后启用=%d  丢失=%d   |  cull=DISABLED surface=%d/%d" % [
			cc["clearcoat_source_materials"], cc["clearcoat_imported_materials"],
			cc["clearcoat_dropped_materials"], cc["cull_disabled_surfaces"], cc["surfaces"]])
		lines.append("  车漆: paint 命名 surface=%d  带 albedo 贴图=%d  无贴图=%d" % [
			cc["paint_named_surfaces"], cc["paint_textured_surfaces"], cc["paint_untextured_surfaces"]])
		lines.append("  材质统计: transparent=%d (depth_prepass=%d) white_no_tex=%d (paint命名=%d/非paint=%d) glass_name=%d paint_name=%d emission=%d cast_shadow_off=%d" % [
			cc["transparent_materials"], cc["depth_prepass_materials"], cc["white_no_texture_materials"],
			cc["white_paint_named_materials"], cc["white_nonpaint_materials"],
			cc["glass_materials"], cc["paint_named_materials"], cc["emission_materials"],
			cc["cast_shadow_off_meshes"]])
		# 材质明细（去重后按名称列）
		var by_name := {}
		for m in c["materials"]:
			var nm := String(m.get("material", ""))
			if not by_name.has(nm):
				by_name[nm] = m
		var names: Array[String] = []
		for k in by_name.keys():
			names.append(String(k))
		names.sort()
		lines.append("  材质明细 (%d 种, 最多列 %d):" % [names.size(), DETAIL_MATERIAL_CAP])
		var shown := 0
		for nm in names:
			if shown >= DETAIL_MATERIAL_CAP:
				lines.append("    ... 其余 %d 种省略，见 JSON" % (names.size() - DETAIL_MATERIAL_CAP))
				break
			var m: Dictionary = by_name[nm]
			var src_info := ""
			if not String(m.get("source_alpha_mode", "")).is_empty():
				src_info = " srcAlpha=%s srcCC=%s" % [
					String(m.get("source_alpha_mode")), str(bool(m.get("source_clearcoat", false)))]
			lines.append("    - %s [%s] albedo=%s tex=%s metal=%s rough=%s transp=%s cull=%s clearcoat=%s emis=%s shadow=%s%s%s" % [
				nm, String(m.get("material_class", "")), String(m.get("albedo", "")),
				(_flag_text(bool(m.get("has_albedo_texture", false))) if not bool(m.get("has_albedo_texture", false)) else ("存在" if bool(m.get("albedo_texture_exists", true)) else "!!文件缺失")),
				_fmt_float(m.get("metallic")), _fmt_float(m.get("roughness")),
				String(m.get("transparency_name", "?")), String(m.get("cull_mode_name", "?")),
				str(m.get("clearcoat", "?")),
				(m.get("emission_color") if bool(m.get("emission", false)) else "off"),
				String(m.get("cast_shadow_name", "?")), src_info,
				("  <<< 纯白无贴图" if bool(m.get("suspicious_white", false)) else "")])
			shown += 1
		lines.append("  材质清单: " + ", ".join(names))
		if c["anomalies"].size() > 0:
			lines.append("  异常:")
			for a in c["anomalies"]:
				lines.append("    * " + String(a))
		else:
			lines.append("  异常: 无")
	lines.append("")
	lines.append("========== 报告结束 ==========")
	return "\n".join(lines) + "\n"


func _summary_one_line(result: Dictionary) -> String:
	var s: Dictionary = result["summary"]
	var c: Dictionary = s["anomaly_counts"]
	var t: Dictionary = s["library_totals"]
	return "cars=%d tris=%d transparent_cars=%d depth_prepass_cars=%d white_no_tex_cars=%d white_nonpaint_cars=%d glass_cars=%d pivot_offset_cars=%d aabb_off_cars=%d load_failures=%d no_texture_cars=%d clearcoat_dropped=%d missing_texture_cars=%d" % [
		s["audited_cars"], t["triangles"], c["transparent_material_cars"], c["depth_prepass_cars"],
		c["white_no_texture_cars"], c["white_no_texture_nonpaint_cars"], c["glass_material_cars"], c["wheel_pivot_offset_cars"],
		c["aabb_off_cars"], c["load_failures"], c["no_albedo_texture_cars"],
		t["clearcoat_dropped_materials"], c["missing_texture_cars"]]


# ---------------------------------------------------------------------------
# 通用工具
# ---------------------------------------------------------------------------

func _parse_user_args() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out-report="):
			_report_path = arg.substr(13)
		elif arg.begins_with("--out-json="):
			_json_path = arg.substr(11)
		elif arg.begins_with("--manifest="):
			_manifest_path = arg.substr(11)
		elif arg.begins_with("--cars-dir="):
			_cars_dir = arg.substr(11)


func _walk_nodes(node: Node, root: Node, out_paths: Array, out_meshes: Array[MeshInstance3D]) -> void:
	out_paths.append(String(root.get_path_to(node)))
	if node is MeshInstance3D:
		out_meshes.append(node as MeshInstance3D)
	for child in node.get_children():
		_walk_nodes(child, root, out_paths, out_meshes)


func _collect_meshes(node: Node, out: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D:
		out.append(node as MeshInstance3D)
	for child in node.get_children():
		_collect_meshes(child, out)


## node 相对 ancestor 的变换（--script SceneTree 中节点不在树上，global_transform 不可靠/为 I）
func _rel_xform(node: Node3D, ancestor: Node) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var n: Node = node
	while n != null and n != ancestor:
		if n is Node3D:
			xf = (n as Node3D).transform * xf
		n = n.get_parent()
	return xf


func _surface_triangles(mesh: Mesh, surface: int) -> int:
	var idx_len: int = int(mesh.surface_get_array_index_len(surface))
	if idx_len > 0:
		return floori(float(idx_len) / 3.0)
	var vtx_len: int = int(mesh.surface_get_array_len(surface))
	return floori(float(vtx_len) / 3.0)


func _material_name(mat: Material) -> String:
	var nm := String(mat.resource_name)
	if nm.is_empty():
		var meta = mat.get_meta("gltf_material_name", "")
		nm = String(meta)
	if nm.is_empty():
		nm = "<未命名:" + mat.get_class() + ">"
	return nm


func _is_glass_name(lower: String) -> bool:
	return lower.contains("glass") or lower.contains("glazing") or lower.contains("window") \
		or lower.contains("glas") or lower.contains("vault") or lower.contains("windshield") \
		or lower.contains("玻璃")


func _is_paint_name(lower: String) -> bool:
	return lower.contains("paint") or lower.contains("carpaint") or lower.contains("coloured") \
		or lower.contains("colorbody") or lower.contains("body") and lower.contains("color")


func _enum_name(names: Array[String], idx: int) -> String:
	if idx >= 0 and idx < names.size():
		return "%d(%s)" % [idx, names[idx]]
	return "%d(?)" % idx


func _v3(v) -> Array:
	if v == null:
		return []
	var vec := v as Vector3
	return [
		snappedf(vec.x, 0.0001),
		snappedf(vec.y, 0.0001),
		snappedf(vec.z, 0.0001),
	]


func _v3_text(v) -> String:
	if v == null:
		return "?"
	if v is Vector3:
		var vec := v as Vector3
		return "%.3f,%.3f,%.3f" % [vec.x, vec.y, vec.z]
	if v is Array:
		var arr := v as Array
		if arr.size() == 3:
			return "%.3f,%.3f,%.3f" % [float(arr[0]), float(arr[1]), float(arr[2])]
	return str(v)


func _col_text(c: Color) -> String:
	return "(%.3f,%.3f,%.3f,%.3f)" % [c.r, c.g, c.b, c.a]


func _fmt_float(v) -> String:
	if v == null:
		return "?"
	return "%.3f" % float(v)


func _dict_flat_text(d: Dictionary) -> String:
	var parts: PackedStringArray = []
	for k in d.keys():
		parts.append("%s=%s" % [String(k), str(d[k])])
	return " | ".join(parts)


func _flag_text(b: bool) -> String:
	return "OK" if b else "MISSING"


func _join_list(arr) -> String:
	if arr == null or (arr as Array).is_empty():
		return "无"
	var parts: PackedStringArray = []
	for v in arr:
		parts.append(String(v))
	return ", ".join(parts)


func _dict_keys_line(d: Dictionary) -> String:
	if d.is_empty():
		return "无"
	var keys: Array[String] = []
	for k in d.keys():
		keys.append(String(k))
	keys.sort()
	return ", ".join(keys)


func _append_multi_map(lines: PackedStringArray, d: Dictionary) -> void:
	if d.is_empty():
		lines.append("    (无)")
		return
	var keys: Array[String] = []
	for k in d.keys():
		keys.append(String(k))
	keys.sort()
	for k in keys:
		lines.append("    - %s: %s" % [k, str(d[k])])


func _sorted_keys(d: Dictionary) -> Array[String]:
	var keys: Array[String] = []
	for k in d.keys():
		keys.append(String(k))
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


## 直接读 GLB 容器的 JSON chunk（第 0 块），拿到「源文件」元数据，
## 用于和 Godot 导入结果交叉核对（alphaMode / clearcoat / doubleSided / extras）。
func _read_glb_json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var head := f.get_buffer(20)
	if head.size() < 20:
		f.close()
		return {}
	# GLB header: magic(4) version(4) length(4)，chunk0: chunkLength(4) chunkType(4)
	if head.decode_u32(0) != 0x46546C67:  # "glTF"
		f.close()
		return {}
	var chunk_len := int(head.decode_u32(12))
	var chunk_type := int(head.decode_u32(16))
	if chunk_type != 0x4E4F534A:  # "JSON"
		f.close()
		return {}
	if chunk_len <= 0 or chunk_len > 64 * 1024 * 1024:
		f.close()
		return {}
	var raw := f.get_buffer(chunk_len)
	f.close()
	var text := raw.get_string_from_utf8()
	var parsed = JSON.parse_string(text)
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}


## 汇总源 GLB 的材质/扩展/元数据（供 JSON 与报告使用）
func _glb_source_info(path: String) -> Dictionary:
	var doc := _read_glb_json(path)
	if doc.is_empty():
		return {"parsed": false}
	var out := {
		"parsed": true,
		"asset_version": "",
		"generator": "",
		"extensions_used": [],
		"material_count": 0,
		"alpha_blend": 0,
		"alpha_mask": 0,
		"clearcoat_materials": 0,
		"double_sided_materials": 0,
		"node_count": 0,
		"extras": {},
		"material_by_name": {},
		"materials": [],
	}
	var asset: Dictionary = doc.get("asset", {})
	out["asset_version"] = String(asset.get("version", ""))
	out["generator"] = String(asset.get("generator", ""))
	out["extensions_used"] = doc.get("extensionsUsed", [])
	out["node_count"] = (doc.get("nodes", []) as Array).size()
	var scenes: Array = doc.get("scenes", [])
	if scenes.size() > 0:
		var sc0: Dictionary = scenes[0]
		out["extras"] = sc0.get("extras", {})
	var by_name := {}
	var recs: Array = []
	for m in doc.get("materials", []):
		var md: Dictionary = m
		var nm := String(md.get("name", ""))
		var rec := {
			"name": nm,
			"alpha_mode": String(md.get("alphaMode", "OPAQUE")),
			"double_sided": bool(md.get("doubleSided", false)),
			"clearcoat": false,
			"metallic": null,
			"roughness": null,
			"base_color": [],
		}
		var pbr: Dictionary = md.get("pbrMetallicRoughness", {})
		if pbr.has("metallicFactor"):
			rec["metallic"] = pbr.get("metallicFactor")
		if pbr.has("roughnessFactor"):
			rec["roughness"] = pbr.get("roughnessFactor")
		if pbr.has("baseColorFactor"):
			rec["base_color"] = pbr.get("baseColorFactor")
		var ext: Dictionary = md.get("extensions", {})
		if ext.has("KHR_materials_clearcoat"):
			rec["clearcoat"] = true
			out["clearcoat_materials"] = int(out["clearcoat_materials"]) + 1
		if rec["alpha_mode"] == "BLEND":
			out["alpha_blend"] = int(out["alpha_blend"]) + 1
		elif rec["alpha_mode"] == "MASK":
			out["alpha_mask"] = int(out["alpha_mask"]) + 1
		if rec["double_sided"]:
			out["double_sided_materials"] = int(out["double_sided_materials"]) + 1
		recs.append(rec)
		by_name[nm] = rec
	out["materials"] = recs
	out["material_by_name"] = by_name
	out["material_count"] = recs.size()
	return out


func _write_file(path: String, text: String) -> int:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(text)
	f.close()
	return OK


func _file_size(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return -1
	var n := int(f.get_length())
	f.close()
	return n


func _file_sha256(path: String) -> String:
	return FileAccess.get_sha256(path)
