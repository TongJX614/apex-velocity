extends Node
## 运行时探针（场景模式，autoload 可用 → 能加载真实 CarVisual / GarageLook）：
## 逐台车走游戏车库真实构建路径，验证：
##   1) CarVisual 能找到 4 个 Spin_Wheel_* 与 2 个前轮 Wheel_*（新层级兼容）
##   2) 轮子滚动：spin 子树 AABB 中心距 spin 原点、y/z 比例、顶点 PCA 最薄轴 vs X 夹角
##      → $OUT_DIR/wheel_roll_check.txt
##   2b) 轮下内容：spin 子树里只允许 tyre/rim 随轮滚动，卡钳/车身杂物不得随轮转（用户要求 1）
##   2c) 动态滚动：spin.rotation.x 扫一圈，轮心漂移 < 5mm、滚动半径变化 < 2%（用户要求 3：绕轮心正圆）
##   3) 前轮转向：Wheel_FL/FR rotation.y=0.35 前后轮组 AABB 变化；后轮 Spin 不在前轮 steer 下
##      → $OUT_DIR/wheel_steer_check.txt
##   3b) 转向方向：左打(+Y)胎前缘向 +X(左)、右打(-Y)向 -X(右)、转向轴竖直、后轮不入转向列表（用户要求 2）
##   4) 运行时材质：_fix_white_materials fallback 次数、apply_paint(原厂漆) 车漆贴图/clearcoat
##   5) 配件库管路：内存里把该车换成 paint=1/wheel=2(dish6)/tire=2(race)/wing=1(gt)/caliper=1，
##      走 GarageLook.apply 实测（不写磁盘、不碰用户存档）：原厂轮是否隐藏、程序化轮宽是否贴合、
##      GT 尾翼是否挂到 WingMount、原厂尾翼是否隐藏 → $OUT_DIR/parts_check.txt
##
## 必须用「场景」而非 --script 运行（CarVisual/GarageLook 引用 GameData/Garage autoload）：
##   Godot --headless --path . res://tools/car_audit/runtime_probe.tscn \
##       -- --out=/tmp/car_after/runtime_probe.json --txt=/tmp/car_after/runtime_probe.txt \
##          [--cars=bmw_i8,lamborghini_aventador]

const MODELS_DIR := "res://cars/assets/models"
const WHEEL_SUFFIXES: Array[String] = ["FL", "FR", "RL", "RR"]

## 轮子滚动判定
const ROLL_CENTER_OK := 0.02      # AABB 中心距 spin 原点 (m)
const ROLL_CENTER_WARN := 0.03
const ROLL_RATIO_MIN := 0.95
const ROLL_RATIO_MAX := 1.05
const ROLL_AXIS_WARN_DEG := 3.0
const ROLL_POINT_BUDGET := 5000

## 前轮转向判定
const STEER_ANGLE := 0.35
const STEER_DSIZE_MIN := 0.02     # 轮组 AABB 尺寸变化量 (m)
const STEER_DCENTER_MIN := 0.005  # 轮组 AABB 中心位移 (m)

## 轮下内容判定：Spin_ 子树里只允许轮子相关网格随轮滚动
const SPIN_ENVELOPE_CENTER := 0.5  # ×radius：无名网格中心距上限（视为轮体一部分）
const SPIN_ENVELOPE_EXTENT := 2.6  # ×radius：无名网格最大尺寸上限

## 转向方向判定：左打 rotation.y=+θ → 胎体前缘探针应向 +X（左）移动
const STEER_DIR_MIN_DX := 0.01     # 前缘探针横移最小量 (m)
const STEER_DIR_BASE_ROT := 0.02   # 转向/滚动节点出厂旋转容差 (rad)
const STEER_DIR_MAX_DY := 0.02     # 转向时探针垂直漂移上限 (m)（转向轴必须垂直）

## 动态滚动判定：spin.rotation.x 扫 8 个角度，轮心不许漂、半径不许变
## （用胎体全顶点，不做 stride 抽样——等距抽样会与顶点排列共振采到薄片，误判正圆轮）
const ROLL_DYN_STEPS := 8
const ROLL_DYN_DRIFT_WARN := 0.005 # 轮心漂移 (m)
const ROLL_DYN_VAR_WARN := 2.0     # 滚动半径变化 (%)

## 配件库判定
const WIDTH_FIT_TOL_PCT := 15.0

var _out_json := "/tmp/runtime_probe.json"
var _out_txt := "/tmp/runtime_probe.txt"
var _only: Array[String] = []
var _out_dir := "/tmp"


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			_out_json = arg.substr(6)
		elif arg.begins_with("--txt="):
			_out_txt = arg.substr(6)
		elif arg.begins_with("--cars="):
			for c in arg.substr(7).split(",", false):
				_only.append(String(c).strip_edges())
	_out_dir = _out_txt.get_base_dir()
	DirAccess.make_dir_recursive_absolute(_out_dir)

	var cars_doc: Dictionary = {}
	if GameData != null and GameData.car_manifest is Dictionary:
		cars_doc = GameData.car_manifest.get("cars", {})
	if cars_doc.is_empty():
		cars_doc = _read_json("res://data/car_manifest.json").get("cars", {})
	var ids: Array[String] = []
	for k in cars_doc.keys():
		ids.append(String(k))
	ids.sort()

	var results: Dictionary = {}
	var txt: PackedStringArray = []
	var roll_txt: PackedStringArray = []
	var steer_txt: PackedStringArray = []
	var parts_txt: PackedStringArray = []
	var stamp := Time.get_datetime_string_from_system()
	txt.append("APEX VELOCITY 运行时探针（CarVisual + GarageLook / 场景模式）  %s" % stamp)
	txt.append("Godot: %s" % str(Engine.get_version_info().get("string", "")))
	txt.append("")
	roll_txt.append("APEX VELOCITY 轮子滚动检查（CarVisual.build 之后、spin 局部坐标）  %s" % stamp)
	roll_txt.append("阈值: AABB 中心距 spin 原点 < %.2f 正常（>%.2f warn）；y/z 尺寸比 %.2f~%.2f；PCA 最薄轴 vs X 夹角 < %.1f°" % [
		ROLL_CENTER_OK, ROLL_CENTER_WARN, ROLL_RATIO_MIN, ROLL_RATIO_MAX, ROLL_AXIS_WARN_DEG])
	roll_txt.append("")
	steer_txt.append("APEX VELOCITY 前轮转向检查（Wheel_FL/FR rotation.y=%.2f rad 前后 AABB）  %s" % [STEER_ANGLE, stamp])
	steer_txt.append("阈值: 轮组 AABB 尺寸变化 > %.2f m 或中心位移 > %.3f m 视为可转向；后轮 Spin 不得挂在前轮 steer 下" % [
		STEER_DSIZE_MIN, STEER_DCENTER_MIN])
	steer_txt.append("")
	parts_txt.append("APEX VELOCITY 配件库管路检查（内存配置 paint=1/wheel=2 dish6/tire=2 race/wing=1 gt/caliper=1）  %s" % stamp)
	parts_txt.append("")

	var fail := 0
	for car_id in ids:
		if _only.size() > 0 and not _only.has(car_id):
			continue
		var entry: Dictionary = cars_doc.get(car_id, {})
		var model := String(entry.get("model", ""))
		var rec := {
			"id": car_id, "model": model, "loaded": false,
			"wheels_found": 0, "steers_found": 0,
			"spin_positions": {}, "spin_corrections": {},
			"fallback_overrides": 0, "glass_overrides": 0, "glass_runtime_transparent": 0,
			"paint_runtime_surfaces": 0, "paint_runtime_textured": 0,
			"paint_runtime_clearcoat": 0, "paint_untextured_names": [],
			"roll": {}, "roll_warn": [], "roll_worst_axis_deg": 0.0,
			"roll_dynamic": {}, "roll_dynamic_warn": [],
			"spin_content": {}, "spin_content_warn": [],
			"steer": {}, "steer_warn": [],
			"steer_dir": {}, "steer_dir_warn": [],
			"parts": {}, "parts_warn": [],
			"error": "",
		}
		var spec := {"id": car_id, "model": model}
		var holder := Node3D.new()
		holder.name = "RuntimeProbe_" + car_id
		var model_path := MODELS_DIR.path_join(model)
		var built: Dictionary = {}
		var load_ok := false
		if ResourceLoader.exists(model_path):
			var pristine_positions := _pristine_spin_positions(model_path)
			built = CarVisual.build(spec, holder)
			load_ok = built.get("model", null) != null
			if load_ok:
				var corr := {}
				for spin_node in built.get("spin_wheels", []):
					if spin_node is Node3D:
						var sp := spin_node as Node3D
						var old_pos: Vector3 = pristine_positions.get(String(sp.name), Vector3.ZERO)
						rec["spin_positions"][String(sp.name)] = _v3pos(sp.position)
						corr[String(sp.name)] = snappedf(sp.position.distance_to(old_pos), 0.0001)
				rec["spin_corrections"] = corr
		if not load_ok:
			rec["error"] = "CarVisual.build 返回 model=null（加载失败）"
			fail += 1
			results[car_id] = rec
			txt.append("[RT] %-24s FAIL %s" % [car_id, rec["error"]])
			roll_txt.append("[ROLL] %-24s FAIL 加载失败" % car_id)
			holder.free()
			continue
		rec["loaded"] = true
		var spins: Array = built.get("spin_wheels", [])
		var steers: Array = built.get("steer_wheels", [])
		rec["wheels_found"] = spins.size()
		rec["steers_found"] = steers.size()
		if spins.size() != 4 or steers.size() != 2:
			fail += 1
		var model_root: Node = built.get("model", null)

		# ---- 运行时材质（_fix_white_materials / apply_paint 原厂漆）----
		for node in model_root.find_children("*", "MeshInstance3D", true, false):
			var mi := node as MeshInstance3D
			if mi.mesh == null:
				continue
			for s in mi.mesh.get_surface_count():
				var ov := mi.get_surface_override_material(s)
				if not (ov is StandardMaterial3D):
					continue
				var sm := ov as StandardMaterial3D
				var nm := String(sm.resource_name).to_lower()
				var is_glass := _is_glass_name(nm)
				if is_glass or sm.transparency != 0:
					rec["glass_overrides"] = int(rec["glass_overrides"]) + 1
					if sm.transparency != 0:
						rec["glass_runtime_transparent"] = int(rec["glass_runtime_transparent"]) + 1
				elif sm.transparency == 0 and String(sm.resource_name).is_empty():
					rec["fallback_overrides"] = int(rec["fallback_overrides"]) + 1
		CarVisual.apply_paint(model_root, Color(0, 0, 0, 0), false, Color(0.5, 0.5, 0.5))
		var untex: Array[String] = []
		for node in model_root.find_children("*", "MeshInstance3D", true, false):
			var mi := node as MeshInstance3D
			if mi.mesh == null:
				continue
			for s in mi.mesh.get_surface_count():
				var ov := mi.get_surface_override_material(s)
				if not (ov is StandardMaterial3D):
					continue
				var sm := ov as StandardMaterial3D
				var nm := String(sm.resource_name).to_lower()
				if not _is_paint_name(nm):
					continue
				rec["paint_runtime_surfaces"] = int(rec["paint_runtime_surfaces"]) + 1
				if sm.albedo_texture != null:
					rec["paint_runtime_textured"] = int(rec["paint_runtime_textured"]) + 1
				elif not untex.has(String(sm.resource_name)):
					untex.append(String(sm.resource_name))
				if sm.clearcoat_enabled:
					rec["paint_runtime_clearcoat"] = int(rec["paint_runtime_clearcoat"]) + 1
		rec["paint_untextured_names"] = untex

		# ---- 轮子滚动检查（2）----
		var roll_summary: Array[String] = []
		for suffix in WHEEL_SUFFIXES:
			var spin := _find_spin(model_root, suffix)
			if spin == null:
				continue
			var r := _roll_metrics(spin)
			rec["roll"][suffix] = r
			if float(r["axis_deg"]) > float(rec["roll_worst_axis_deg"]):
				rec["roll_worst_axis_deg"] = float(r["axis_deg"])
			var warns: Array[String] = r.get("warn", [])
			for w in warns:
				var msg := "%s %s" % [suffix, String(w)]
				rec["roll_warn"].append(msg)
			roll_txt.append("[ROLL] %-24s %s center=%.4f yz=%.3f axis=%.2f° tyreAxis=%.2f° tyreYZ=%.3f rimAxis=%.2f° wrap=%s wheelMeshes=%d excluded=%d (full: center=%.4f axis=%.2f°)%s" % [
				car_id, suffix, float(r["center_dist"]), float(r["yz_ratio"]),
				float(r["axis_deg"]), float(r["tyre_axis_deg"]), float(r["tyre_yz_ratio"]), float(r["rim_axis_deg"]),
				("yes" if bool(r["roundfix"]) else "no"),
				int(r["wheel_meshes"]), int(r["excluded_meshes"]),
				float(r["full_center_dist"]), float(r["full_axis_deg"]),
				("  WARN: " + "; ".join(warns)) if warns.size() > 0 else ""])

		# ---- 轮下内容检查：只有轮子在转（2b）----
		_spin_content_check(car_id, model_root, rec, roll_txt)

		# ---- 动态滚动检查：绕轮心、正圆（2c）----
		_roll_dynamic_check(car_id, model_root, rec, roll_txt)

		# ---- 转向方向检查：左打向左、右打向右、后轮不参与（3b）----
		_steer_direction_check(car_id, model_root, steers, rec, steer_txt)

		# ---- 前轮转向检查（3）----
		var steer_ok_count := 0
		for front in ["FL", "FR"]:
			var steer_node := _find_node3d(model_root, "Wheel_" + front)
			if steer_node == null:
				rec["steer_warn"].append(front + " 无 Wheel_ 节点")
				continue
			var before := _subtree_aabb_rel(steer_node, model_root)
			steer_node.rotation.y = STEER_ANGLE
			var after := _subtree_aabb_rel(steer_node, model_root)
			steer_node.rotation.y = 0.0
			var dsize := (after.size - before.size).length()
			var dcenter := (after.get_center() - before.get_center()).length()
			var ok := dsize > STEER_DSIZE_MIN or dcenter > STEER_DCENTER_MIN
			if ok:
				steer_ok_count += 1
			else:
				rec["steer_warn"].append("%s 转向前后轮组 AABB 几乎不变（dsize=%.4f dcenter=%.4f）" % [front, dsize, dcenter])
			rec["steer"][front] = {
				"dsize": snappedf(dsize, 0.0001),
				"dcenter": snappedf(dcenter, 0.0001),
				"ok": ok,
			}
			steer_txt.append("[STEER] %-24s %s dsize=%.4f dcenter=%.4f ok=%s" % [car_id, front, dsize, dcenter, str(ok)])
		# 后轮 Spin 是否被误挂在前轮 steer 节点下
		var rear_under_steer: Array[String] = []
		for rear in ["RL", "RR"]:
			var spin := _find_spin(model_root, rear)
			if spin == null:
				continue
			var p: Node = spin.get_parent()
			while p != null and p != model_root:
				if p in steers:
					rear_under_steer.append(rear)
					break
				p = p.get_parent()
		if rear_under_steer.size() > 0:
			rec["steer_warn"].append("后轮 Spin 挂在前轮 steer 下: " + ", ".join(rear_under_steer))
		rec["steer"]["rear_under_steer"] = rear_under_steer
		rec["steer"]["front_ok_count"] = steer_ok_count
		rec["steer"]["steer_nodes_count"] = steers.size()
		steer_txt.append("[STEER] %-24s front_ok=%d/2 steer_nodes=%d rear_under_steer=%s%s" % [
			car_id, steer_ok_count, steers.size(), str(rear_under_steer),
			("  WARN: " + "; ".join(rec["steer_warn"])) if rec["steer_warn"].size() > 0 else ""])

		# ---- 配件库管路检查（4）----
		_parts_check(car_id, model_root, rec, parts_txt)

		results[car_id] = rec
		txt.append("[RT] %-24s load=OK wheels=%d/4 steers=%d/2 fallback=%d glass=%d/%d paint=%d tex=%d cc=%d roll_warn=%d dyn_warn=%d content_warn=%d steer_warn=%d dir_warn=%d parts_warn=%d" % [
			car_id, int(rec["wheels_found"]), int(rec["steers_found"]),
			int(rec["fallback_overrides"]), int(rec["glass_overrides"]),
			int(rec["glass_runtime_transparent"]), int(rec["paint_runtime_surfaces"]),
			int(rec["paint_runtime_textured"]), int(rec["paint_runtime_clearcoat"]),
			rec["roll_warn"].size(), rec["roll_dynamic_warn"].size(), rec["spin_content_warn"].size(),
			rec["steer_warn"].size(), rec["steer_dir_warn"].size(), rec["parts_warn"].size()])
		holder.free()

	# ---- 汇总 ----
	var bad_wheels: Array[String] = []
	var fallback_cars: Array[String] = []
	var paint_untextured_cars: Array[String] = []
	var paint_cc_cars: Array[String] = []
	var spin_corrected_cars: Array[String] = []
	var roll_warn_cars: Array[String] = []
	var steer_bad_cars: Array[String] = []
	var parts_bad_cars: Array[String] = []
	var spin_content_bad_cars: Array[String] = []
	var steer_dir_bad_cars: Array[String] = []
	var roll_dyn_bad_cars: Array[String] = []
	var roll_worst: Array = []
	for cid in results.keys():
		var r: Dictionary = results[cid]
		if not bool(r["loaded"]):
			continue
		if int(r["wheels_found"]) != 4 or int(r["steers_found"]) != 2:
			bad_wheels.append(String(cid))
		if int(r["fallback_overrides"]) > 0:
			fallback_cars.append(String(cid))
		if int(r["paint_runtime_surfaces"]) > 0 and int(r["paint_runtime_textured"]) == 0:
			paint_untextured_cars.append(String(cid))
		if int(r["paint_runtime_clearcoat"]) > 0:
			paint_cc_cars.append(String(cid))
		var max_corr := 0.0
		for v in (r["spin_corrections"] as Dictionary).values():
			max_corr = maxf(max_corr, float(v))
		if max_corr > 0.001:
			spin_corrected_cars.append(String(cid))
		if (r["roll_warn"] as Array).size() > 0:
			roll_warn_cars.append(String(cid))
		if (r["steer_warn"] as Array).size() > 0 or int(r["steer"].get("front_ok_count", 0)) != 2:
			steer_bad_cars.append(String(cid))
		if (r["parts_warn"] as Array).size() > 0:
			parts_bad_cars.append(String(cid))
		if (r["spin_content_warn"] as Array).size() > 0:
			spin_content_bad_cars.append(String(cid))
		if (r["steer_dir_warn"] as Array).size() > 0:
			steer_dir_bad_cars.append(String(cid))
		if (r["roll_dynamic_warn"] as Array).size() > 0:
			roll_dyn_bad_cars.append(String(cid))
		roll_worst.append([r["roll_worst_axis_deg"], String(cid)])
	for a in [bad_wheels, fallback_cars, paint_untextured_cars, paint_cc_cars, spin_corrected_cars, roll_warn_cars, steer_bad_cars, parts_bad_cars, spin_content_bad_cars, steer_dir_bad_cars, roll_dyn_bad_cars]:
		a.sort()
	roll_worst.sort()
	roll_worst.reverse()

	txt.append("")
	txt.append("汇总: 车辆=%d  加载失败=%d  Wheels缺失=%d %s  材质fallback=%d台 %s  spin被纠偏=%d台" % [
		results.size(), fail, bad_wheels.size(), str(bad_wheels), fallback_cars.size(), str(fallback_cars),
		spin_corrected_cars.size()])
	txt.append("      车漆全无贴图=%d %s  运行时clearcoat=%d台  roll预警=%d台  steer异常=%d台 %s  parts预警=%d台 %s  最差轮轴角=%s" % [
		paint_untextured_cars.size(), str(paint_untextured_cars), paint_cc_cars.size(),
		roll_warn_cars.size(), steer_bad_cars.size(), str(steer_bad_cars),
		parts_bad_cars.size(), str(parts_bad_cars),
		(str(roll_worst[0]) if roll_worst.size() > 0 else "无")])
	txt.append("      轮下杂物=%d台 %s  转向方向异常=%d台 %s  动态滚动异常=%d台 %s" % [
		spin_content_bad_cars.size(), str(spin_content_bad_cars),
		steer_dir_bad_cars.size(), str(steer_dir_bad_cars),
		roll_dyn_bad_cars.size(), str(roll_dyn_bad_cars)])

	roll_txt.append("")
	roll_txt.append("roll warning 车辆 (%d): %s" % [roll_warn_cars.size(), ", ".join(roll_warn_cars) if roll_warn_cars.size() > 0 else "无"])
	roll_txt.append("动态滚动异常车辆 (%d): %s" % [roll_dyn_bad_cars.size(), ", ".join(roll_dyn_bad_cars) if roll_dyn_bad_cars.size() > 0 else "无"])
	roll_txt.append("轮下杂物车辆 (%d): %s" % [spin_content_bad_cars.size(), ", ".join(spin_content_bad_cars) if spin_content_bad_cars.size() > 0 else "无"])
	roll_txt.append("最差 PCA 夹角 TOP10:")
	for row in roll_worst.slice(0, 10):
		roll_txt.append("  %-24s %.2f°" % [String(row[1]), float(row[0])])
	steer_txt.append("")
	steer_txt.append("steer 异常车辆 (%d): %s" % [steer_bad_cars.size(), ", ".join(steer_bad_cars) if steer_bad_cars.size() > 0 else "无"])
	steer_txt.append("转向方向异常车辆 (%d): %s" % [steer_dir_bad_cars.size(), ", ".join(steer_dir_bad_cars) if steer_dir_bad_cars.size() > 0 else "无"])
	parts_txt.append("")
	parts_txt.append("parts 预警车辆 (%d): %s" % [parts_bad_cars.size(), ", ".join(parts_bad_cars) if parts_bad_cars.size() > 0 else "无"])

	var payload := {
		"tool": "tools/car_audit/runtime_probe.gd (scene mode)",
		"generated_at": stamp,
		"cars": results,
		"summary": {
			"car_count": results.size(), "fail_count": fail,
			"wheels_bad": bad_wheels, "fallback_cars": fallback_cars,
			"spin_corrected_cars": spin_corrected_cars,
			"paint_all_untextured": paint_untextured_cars,
			"runtime_clearcoat_cars": paint_cc_cars,
			"roll_warn_cars": roll_warn_cars,
			"roll_worst_axis": roll_worst,
			"steer_bad_cars": steer_bad_cars,
			"parts_bad_cars": parts_bad_cars,
			"spin_content_bad_cars": spin_content_bad_cars,
			"steer_dir_bad_cars": steer_dir_bad_cars,
			"roll_dynamic_bad_cars": roll_dyn_bad_cars,
		},
	}
	var jf := FileAccess.open(_out_json, FileAccess.WRITE)
	if jf != null:
		jf.store_string(JSON.stringify(payload, "\t"))
		jf.close()
	for pair in [[_out_txt, txt], [_out_dir.path_join("wheel_roll_check.txt"), roll_txt],
			[_out_dir.path_join("wheel_steer_check.txt"), steer_txt],
			[_out_dir.path_join("parts_check.txt"), parts_txt]]:
		var f := FileAccess.open(String(pair[0]), FileAccess.WRITE)
		if f != null:
			f.store_string("\n".join(pair[1]) + "\n")
			f.close()
	print("[RT] " + "\n".join(txt))
	# 用户三项核心要求（轮下只有轮子 / 转向方向正确 / 绕轮心正圆滚动）任一异常都算失败
	var core_bad := spin_content_bad_cars.size() + steer_dir_bad_cars.size() + roll_dyn_bad_cars.size()
	print("[RT] json -> %s ; txt -> %s ; roll/steer/parts -> %s ; fail=%d core_bad=%d" % [_out_json, _out_txt, _out_dir, fail, core_bad])
	get_tree().quit(0 if (fail == 0 and core_bad == 0) else 1)


# ---------------------------------------------------------------------------
# 配件库管路（内存配置，不写盘）
# ---------------------------------------------------------------------------

func _parts_check(car_id: String, model_root: Node, rec: Dictionary, parts_txt: PackedStringArray) -> void:
	var p := {"applied": {}, "donor_wheels": 0, "factory_spin_visible": 0, "factory_spin_hidden": 0,
		"factory_width": {}, "donor_width": {}, "width_delta_pct": 0.0,
		"wing_mounted": false, "donor_wings": 0, "factory_wing_visible": 0}
	var radius := CarVisual.wheel_radius_for(car_id)
	var spins: Array[Node3D] = []
	for suffix in WHEEL_SUFFIXES:
		var spin := _find_spin(model_root, suffix)
		if spin != null:
			spins.append(spin)
			# 原厂胎宽（供体轮按此缩放）——必须在藏原轮 / 挂新轮之前量
			var dims := CarVisual.wheel_dims(spin, radius)
			p["factory_width"][suffix] = snappedf(float(dims["width"]), 0.0001)
	# 记录"原厂轮 mesh"集合（apply 后判断是否真正被隐藏；供体新轮不在其中）
	var factory_meshes: Array[MeshInstance3D] = []
	for spin in spins:
		for node in spin.find_children("*", "MeshInstance3D", true, false):
			factory_meshes.append(node as MeshInstance3D)
	# 保存用户配置 → 内存改成测试配置 → 调 GarageLook.apply → 还原（cfg 是 Garage  live 引用）
	var cfg: Dictionary = Garage.config(car_id)
	var saved: Dictionary = cfg.duplicate()
	cfg["paint"] = 1       # 曜石黑
	cfg["rim"] = 0
	cfg["caliper"] = 1     # 竞速黄
	cfg["wheel"] = 2       # 第 2 个供体轮
	cfg["tire"] = 2        # RACE SLICK
	cfg["wing"] = 1        # 第 1 个供体翼
	cfg["livery"] = 0
	var applied: Dictionary = GarageLook.apply(model_root, car_id, cfg)
	for k in saved.keys():
		cfg[k] = saved[k]
	p["applied"] = applied
	# 供体轮是否装上（ProceduralPartWheel_*）/ 原厂轮是否隐藏
	var donor_wheels := model_root.find_children("ProceduralPartWheel_*", "Node3D", true, false)
	p["donor_wheels"] = donor_wheels.size()
	var visible := 0
	var hidden := 0
	for mi in factory_meshes:
		if is_instance_valid(mi):
			if mi.visible:
				visible += 1
			else:
				hidden += 1
	p["factory_spin_visible"] = visible
	p["factory_spin_hidden"] = hidden
	# 供体轮宽 vs 原厂胎宽（贴合度）
	for dw in donor_wheels:
		var node := dw as Node3D
		var suffix := String(node.name).trim_prefix("ProceduralPartWheel_")
		# 在父级（spin）坐标系量，才能含供体轮自身的 sx 缩放（build_wheel 按原厂胎宽缩放）
		var dw_width := _subtree_aabb_rel(node, node.get_parent()).size.x
		p["donor_width"][suffix] = snappedf(dw_width, 0.0001)
		var fw := float(p["factory_width"].get(suffix, 0.0))
		if fw > 0.001 and dw_width > 0.001:
			var d := absf(dw_width - fw) / fw * 100.0
			p["width_delta_pct"] = maxf(float(p["width_delta_pct"]), snappedf(d, 0.01))
	# 尾翼：供体翼（ProceduralPartWing）+ 原厂尾翼是否隐藏（排除打了 TAG 的新翼）
	var donor_wings := model_root.find_children("ProceduralPartWing", "Node3D", true, false)
	p["donor_wings"] = donor_wings.size()
	p["wing_mounted"] = bool(applied.get("wing", false))
	var fw_visible := 0
	for node in model_root.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.get_meta("ProceduralPart", false):
			continue   # 新装的供体翼不算原厂翼
		if mi.visible and _is_factory_wing_name(String(mi.name)):
			fw_visible += 1
	p["factory_wing_visible"] = fw_visible
	# 判定
	if donor_wheels.size() != 4:
		rec["parts_warn"].append("供体轮只装上 %d/4" % donor_wheels.size())
	if visible > 0:
		rec["parts_warn"].append("原厂轮 mesh 仍可见 %d 个（应全部隐藏）" % visible)
	if not bool(p["wing_mounted"]):
		rec["parts_warn"].append("供体尾翼未挂上（applied.wing=false）")
	if fw_visible > 0:
		rec["parts_warn"].append("原厂尾翼仍可见 %d 个（应隐藏）" % fw_visible)
	if float(p["width_delta_pct"]) > WIDTH_FIT_TOL_PCT:
		rec["parts_warn"].append("供体轮宽与原厂胎宽差 %.1f%%（>%.0f%%）" % [
			float(p["width_delta_pct"]), WIDTH_FIT_TOL_PCT])
	rec["parts"] = p
	parts_txt.append("[PARTS] %-24s donor_wheels=%d/4 factory_visible=%d factory_hidden=%d wing=%s donor_wings=%d factory_wing_visible=%d widthΔ=%.1f%% (factory/donor FL=%.3f/%.3f)%s" % [
		car_id, donor_wheels.size(), visible, hidden, str(applied.get("wing", false)),
		donor_wings.size(), fw_visible, float(p["width_delta_pct"]),
		float(p["factory_width"].get("FL", 0.0)), float(p["donor_width"].get("FL", 0.0)),
		("  WARN: " + "; ".join(rec["parts_warn"])) if rec["parts_warn"].size() > 0 else ""])


# ---------------------------------------------------------------------------
# 轮子滚动指标
# ---------------------------------------------------------------------------

func _roll_metrics(spin: Node3D) -> Dictionary:
	# 轮体网格 = spin 子树里名字含 tyre/rim 的 mesh；排除 BrakeDisc/Caliper/其他杂项
	# （卡钳/刹车盘不在轮轴中心，会把 AABB 中心与 PCA 主轴带偏）
	var wheel_meshes: Array[MeshInstance3D] = []
	var excluded := 0
	for child in spin.find_children("*", "MeshInstance3D", true, false):
		var mi := child as MeshInstance3D
		var nm := String(mi.name).to_lower()
		var is_wheel := nm.contains("tyre") or nm.contains("tire") or nm.contains("rim") \
			or nm.contains("轮") or nm.contains("胎")
		var is_brake := nm.contains("brake") or nm.contains("disc") or nm.contains("caliper") \
			or nm.contains("刹车") or nm.contains("卡钳")
		if is_wheel and not is_brake:
			wheel_meshes.append(mi)
		else:
			excluded += 1
	if wheel_meshes.is_empty():
		for child in spin.find_children("*", "MeshInstance3D", true, false):
			wheel_meshes.append(child as MeshInstance3D)
	var box := _meshes_aabb_rel(wheel_meshes, spin)
	var center_dist := box.get_center().length()
	var yz_ratio := box.size.y / box.size.z if box.size.z > 0.0001 else 0.0
	var pts := _mesh_points_rel(wheel_meshes, spin, ROLL_POINT_BUDGET)
	var axis_deg := _thinnest_axis_vs_x_deg(pts)
	# 胎体（Tyre）单独做 PCA/AABB 更稳健：轮辐顶点分布会让 Rim 的 PCA 偏
	var tyre_meshes: Array[MeshInstance3D] = []
	var rim_meshes: Array[MeshInstance3D] = []
	for mi in wheel_meshes:
		var nm2 := String(mi.name).to_lower()
		if nm2.contains("tyre") or nm2.contains("tire") or nm2.contains("胎"):
			tyre_meshes.append(mi)
		elif nm2.contains("rim") or nm2.contains("轮毂") or nm2.contains("wheel"):
			rim_meshes.append(mi)
	var tyre_box := _meshes_aabb_rel(tyre_meshes, spin) if tyre_meshes.size() > 0 else AABB()
	var tyre_axis := _thinnest_axis_vs_x_deg(_mesh_points_rel(tyre_meshes, spin, ROLL_POINT_BUDGET)) if tyre_meshes.size() > 0 else -1.0
	var tyre_yz := (tyre_box.size.y / tyre_box.size.z) if (tyre_meshes.size() > 0 and tyre_box.size.z > 0.0001) else 0.0
	var rim_axis := _thinnest_axis_vs_x_deg(_mesh_points_rel(rim_meshes, spin, ROLL_POINT_BUDGET)) if rim_meshes.size() > 0 else -1.0
	# 全子树参考指标（含 brake/caliper 等）
	var full_box := _spin_local_aabb(spin)
	var full_pts := _spin_points_rel(spin, ROLL_POINT_BUDGET)
	var full_axis := _thinnest_axis_vs_x_deg(full_pts)
	var wrapped := false
	for c in spin.get_children():
		if String(c.name).begins_with("WheelRoundFix"):
			wrapped = true
			break
	var warns: Array[String] = []
	if center_dist > ROLL_CENTER_WARN:
		warns.append("AABB中心距spin原点 %.3f m (>%.2f)" % [center_dist, ROLL_CENTER_WARN])
	elif center_dist > ROLL_CENTER_OK:
		warns.append("AABB中心距 %.3f m (>%.2f 注意)" % [center_dist, ROLL_CENTER_OK])
	if yz_ratio > 0.0 and (yz_ratio < ROLL_RATIO_MIN or yz_ratio > ROLL_RATIO_MAX) and not wrapped:
		warns.append("y/z 尺寸比 %.3f 不在 %.2f~%.2f" % [yz_ratio, ROLL_RATIO_MIN, ROLL_RATIO_MAX])
	if tyre_yz > 0.0 and (tyre_yz < ROLL_RATIO_MIN or tyre_yz > ROLL_RATIO_MAX) and not wrapped:
		warns.append("胎体 y/z 尺寸比 %.3f 不在 %.2f~%.2f（可能椭圆）" % [tyre_yz, ROLL_RATIO_MIN, ROLL_RATIO_MAX])
	if tyre_axis >= 0.0 and tyre_axis > ROLL_AXIS_WARN_DEG:
		warns.append("胎体 PCA 最薄轴 vs X 夹角 %.1f° (>%.1f°)" % [tyre_axis, ROLL_AXIS_WARN_DEG])
	elif axis_deg > ROLL_AXIS_WARN_DEG:
		warns.append("PCA 最薄轴 vs X 夹角 %.1f° (>%.1f°；胎体 %.1f° 未超，可能轮辐顶点偏置)" % [
			axis_deg, ROLL_AXIS_WARN_DEG, tyre_axis])
	return {
		"center_dist": snappedf(center_dist, 0.0001),
		"yz_ratio": snappedf(yz_ratio, 0.0001),
		"axis_deg": snappedf(axis_deg, 0.01),
		"roundfix": wrapped,
		"wheel_meshes": wheel_meshes.size(),
		"excluded_meshes": excluded,
		"tyre_axis_deg": snappedf(tyre_axis, 0.01),
		"tyre_yz_ratio": snappedf(tyre_yz, 0.0001),
		"rim_axis_deg": snappedf(rim_axis, 0.01),
		"full_center_dist": snappedf(full_box.get_center().length(), 0.0001),
		"full_axis_deg": snappedf(full_axis, 0.01),
		"warn": warns,
	}


## 轮体网格（tyre/rim，排除刹车/卡钳）；找不到命名轮时退回全部 mesh
func _wheel_meshes_under(spin: Node3D) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	for child in spin.find_children("*", "MeshInstance3D", true, false):
		var mi := child as MeshInstance3D
		var nm := String(mi.name).to_lower()
		var is_wheel := nm.contains("tyre") or nm.contains("tire") or nm.contains("rim") \
			or nm.contains("轮") or nm.contains("胎")
		var is_brake := nm.contains("brake") or nm.contains("disc") or nm.contains("caliper") \
			or nm.contains("刹车") or nm.contains("卡钳")
		if is_wheel and not is_brake:
			out.append(mi)
	if out.is_empty():
		for child in spin.find_children("*", "MeshInstance3D", true, false):
			out.append(child as MeshInstance3D)
	return out


## 胎体网格（滚动接触面，定义"绕轮心正圆"）；无命名胎时退回轮体网格
func _tyre_meshes_under(spin: Node3D) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	for child in spin.find_children("*", "MeshInstance3D", true, false):
		var mi := child as MeshInstance3D
		var nm := String(mi.name).to_lower()
		if nm.contains("tyre") or nm.contains("tire") or nm.contains("胎"):
			out.append(mi)
	if out.is_empty():
		return _wheel_meshes_under(spin)
	return out


## 全顶点（不做 stride 抽样）：动态滚动判定必须用完整顶点，否则等距抽样会与
## 网格顶点排列共振，只采到轮子某一侧的薄片，把正圆居中轮误判成偏心椭圆。
func _all_points_rel(meshes: Array, ancestor: Node) -> PackedVector3Array:
	var out := PackedVector3Array()
	for child in meshes:
		var mi := child as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		var rel := _rel_xform(mi, ancestor)
		for s in mi.mesh.get_surface_count():
			var arrays := mi.mesh.surface_get_arrays(s)
			if arrays.size() <= Mesh.ARRAY_VERTEX:
				continue
			var vtx = arrays[Mesh.ARRAY_VERTEX]
			if vtx == null:
				continue
			for v in vtx:
				out.append(rel * (v as Vector3))
	return out


# ---------------------------------------------------------------------------
# 轮下内容：spin 子树里只允许轮子相关网格随轮滚动（用户要求 1）
# ---------------------------------------------------------------------------

func _spin_content_check(car_id: String, model_root: Node, rec: Dictionary, roll_txt: PackedStringArray) -> void:
	var radius := CarVisual.wheel_radius_for(car_id)
	for suffix in WHEEL_SUFFIXES:
		var spin := _find_spin(model_root, suffix)
		if spin == null:
			continue
		var wheel_n := 0
		var disc_n := 0
		var caliper_n := 0
		var unknown_n := 0
		var foreign: Array[String] = []
		for child in spin.find_children("*", "MeshInstance3D", true, false):
			var mi := child as MeshInstance3D
			if mi.mesh == null:
				continue
			var nm := String(mi.name).to_lower()
			var is_caliper := nm.contains("caliper") or nm.contains("卡钳") or nm.contains("刹车钳")
			var is_disc := nm.contains("disc") or nm.contains("rotor") or nm.contains("刹车盘") or nm.contains("制动盘")
			var is_wheel := nm.contains("tyre") or nm.contains("tire") or nm.contains("rim") \
				or nm.contains("wheel") or nm.contains("spoke") or nm.contains("hub") \
				or nm.contains("lug") or nm.contains("nut") or nm.contains("轮") or nm.contains("胎") \
				or nm.contains("毂") or nm.contains("辐") or nm.contains("螺")
			var box := _meshes_aabb_rel([mi], spin)
			var cdist := box.get_center().length()
			var ext := maxf(box.size.x, maxf(box.size.y, box.size.z))
			if is_caliper:
				caliper_n += 1
				foreign.append("%s(卡钳随轮转)" % mi.name)
			elif is_disc:
				disc_n += 1
			elif is_wheel:
				wheel_n += 1
				if cdist > radius * SPIN_ENVELOPE_EXTENT or ext > radius * SPIN_ENVELOPE_EXTENT * 2.0:
					foreign.append("%s(轮名但几何超包络)" % mi.name)
			else:
				unknown_n += 1
				if cdist > radius * SPIN_ENVELOPE_CENTER or ext > radius * SPIN_ENVELOPE_EXTENT:
					foreign.append("%s(非轮杂物)" % mi.name)
		rec["spin_content"][suffix] = {
			"wheel": wheel_n, "disc": disc_n, "caliper": caliper_n, "unknown": unknown_n,
			"foreign": foreign,
		}
		if foreign.size() > 0:
			rec["spin_content_warn"].append("%s 随轮转动异物: %s" % [suffix, ", ".join(foreign)])
		roll_txt.append("[CONTENT] %-24s %s wheel=%d disc=%d caliper=%d unknown=%d foreign=%s" % [
			car_id, suffix, wheel_n, disc_n, caliper_n, unknown_n,
			(", ".join(foreign)) if foreign.size() > 0 else "无"])


# ---------------------------------------------------------------------------
# 动态滚动：spin.rotation.x 扫一圈，轮心不漂、半径不变（用户要求 3）
# ---------------------------------------------------------------------------

func _roll_dynamic_check(car_id: String, model_root: Node, rec: Dictionary, roll_txt: PackedStringArray) -> void:
	for suffix in WHEEL_SUFFIXES:
		var spin := _find_spin(model_root, suffix)
		if spin == null:
			continue
		var pts_local := _all_points_rel(_tyre_meshes_under(spin), spin)
		if pts_local.size() < 16:
			continue
		var authored := spin.rotation
		var centers: Array[Vector3] = []
		var extents: Array[float] = []
		for k in ROLL_DYN_STEPS:
			spin.rotation.x = TAU * float(k) / float(ROLL_DYN_STEPS)
			var xf := spin.transform
			var b := xf.basis
			var o := xf.origin
			var mnx := INF; var mny := INF; var mnz := INF
			var mxx := -INF; var mxy := -INF; var mxz := -INF
			for p in pts_local:
				var qx := o.x + b.x.x * p.x + b.y.x * p.y + b.z.x * p.z
				var qy := o.y + b.x.y * p.x + b.y.y * p.y + b.z.y * p.z
				var qz := o.z + b.x.z * p.x + b.y.z * p.y + b.z.z * p.z
				if qx < mnx: mnx = qx
				if qx > mxx: mxx = qx
				if qy < mny: mny = qy
				if qy > mxy: mxy = qy
				if qz < mnz: mnz = qz
				if qz > mxz: mxz = qz
			centers.append(Vector3((mnx + mxx) * 0.5, (mny + mxy) * 0.5, (mnz + mxz) * 0.5))
			extents.append(maxf(mxy - mny, mxz - mnz))
		spin.rotation = authored
		var mean_center := Vector3.ZERO
		for c in centers:
			mean_center += c
		mean_center /= float(centers.size())
		var drift := 0.0
		for c in centers:
			drift = maxf(drift, c.distance_to(mean_center))
		var ext_min := INF
		var ext_max := 0.0
		var ext_sum := 0.0
		for e in extents:
			ext_min = minf(ext_min, e)
			ext_max = maxf(ext_max, e)
			ext_sum += e
		var ext_mean := ext_sum / float(extents.size())
		var var_pct := (ext_max - ext_min) / maxf(ext_mean, 0.0001) * 100.0
		var warns: Array[String] = []
		if drift > ROLL_DYN_DRIFT_WARN:
			warns.append("滚动轮心漂移 %.4f m (>%.3f，未绕轮心)" % [drift, ROLL_DYN_DRIFT_WARN])
		if var_pct > ROLL_DYN_VAR_WARN:
			warns.append("滚动半径变化 %.2f%% (>%.1f%%，非正圆)" % [var_pct, ROLL_DYN_VAR_WARN])
		rec["roll_dynamic"][suffix] = {
			"center_drift": snappedf(drift, 0.0001),
			"radius_var_pct": snappedf(var_pct, 0.01),
			"warn": warns,
		}
		for w in warns:
			rec["roll_dynamic_warn"].append("%s %s" % [suffix, w])
		roll_txt.append("[DYN] %-24s %s drift=%.4f radiusVar=%.2f%%%s" % [
			car_id, suffix, drift, var_pct,
			("  WARN: " + "; ".join(warns)) if warns.size() > 0 else ""])


# ---------------------------------------------------------------------------
# 转向方向：左打向左、右打向右、转向轴竖直、后轮不参与（用户要求 2）
# ---------------------------------------------------------------------------

func _steer_direction_check(car_id: String, model_root: Node, steers: Array, rec: Dictionary, steer_txt: PackedStringArray) -> void:
	for front in ["FL", "FR"]:
		# 用 build 返回的转向驱动节点（car.gd 实际写 rotation.y 的那个）做判定，
		# 而非按名字找 Wheel_：反向修正会插入外层 SteerPivot_XX，内层 Wheel_ 带
		# 静态补偿旋转，按名字找会把补偿误判成「烘焙转向」。
		var steer_node: Node3D = null
		for s in steers:
			var sn := s as Node3D
			if sn != null and String(sn.name).ends_with(front):
				steer_node = sn
				break
		if steer_node == null:
			steer_node = _find_node3d(model_root, "Wheel_" + front)
		var spin := _find_spin(model_root, front)
		if steer_node == null or spin == null:
			rec["steer_dir_warn"].append(front + " 缺 Wheel_/Spin_ 节点")
			continue
		var authored := steer_node.rotation
		var baked := absf(authored.x) > STEER_DIR_BASE_ROT or absf(authored.y) > STEER_DIR_BASE_ROT or absf(authored.z) > STEER_DIR_BASE_ROT
		var wheel_meshes := _wheel_meshes_under(spin)
		var box_local := _meshes_aabb_rel(wheel_meshes, steer_node)
		var probe_local := Vector3(box_local.get_center().x, box_local.get_center().y, box_local.end.z)
		steer_node.rotation = Vector3.ZERO
		var p0 := _rel_xform(steer_node, model_root) * probe_local
		steer_node.rotation.y = STEER_ANGLE
		var p1 := _rel_xform(steer_node, model_root) * probe_local
		steer_node.rotation.y = -STEER_ANGLE
		var p2 := _rel_xform(steer_node, model_root) * probe_local
		steer_node.rotation = authored
		var dx_left := p1.x - p0.x
		var dx_right := p2.x - p0.x
		var dy_left := absf(p1.y - p0.y)
		var ok_left := dx_left > STEER_DIR_MIN_DX
		var ok_right := dx_right < -STEER_DIR_MIN_DX
		var ok_vertical := dy_left < STEER_DIR_MAX_DY
		if not ok_left:
			rec["steer_dir_warn"].append("%s 左打(+Y)前缘未向左(+X)移 dx=%.4f" % [front, dx_left])
		if not ok_right:
			rec["steer_dir_warn"].append("%s 右打(-Y)前缘未向右(-X)移 dx=%.4f" % [front, dx_right])
		if not ok_vertical:
			rec["steer_dir_warn"].append("%s 转向时前缘上下漂 dy=%.4f（转向轴非竖直）" % [front, dy_left])
		if baked:
			rec["steer_dir_warn"].append("%s 转向节点带烘焙旋转 (%.3f,%.3f,%.3f)" % [front, authored.x, authored.y, authored.z])
		var ok := ok_left and ok_right and ok_vertical and not baked
		rec["steer_dir"][front] = {
			"dx_left": snappedf(dx_left, 0.0001),
			"dx_right": snappedf(dx_right, 0.0001),
			"dy_left": snappedf(dy_left, 0.0001),
			"baked": baked,
			"ok": ok,
		}
		steer_txt.append("[DIR] %-24s %s dxL=%.4f dxR=%.4f dyL=%.4f baked=%s ok=%s" % [
			car_id, front, dx_left, dx_right, dy_left, str(baked), str(ok)])
	var rear_steered: Array[String] = []
	for rear in ["RL", "RR"]:
		var rn := _find_node3d(model_root, "Wheel_" + rear)
		if rn != null and rn in steers:
			rear_steered.append(rear)
			rec["steer_dir_warn"].append(rear + " 后轮被加入转向驱动列表")
	rec["steer_dir"]["rear_steered"] = rear_steered
	steer_txt.append("[DIR] %-24s rear_steered=%s" % [car_id, str(rear_steered) if rear_steered.size() > 0 else "无"])


func _spin_local_aabb(spin: Node3D) -> AABB:
	return _subtree_aabb_rel(spin, spin)


func _subtree_aabb_rel(node: Node3D, ancestor: Node) -> AABB:
	var box := AABB()
	var first := true
	for child in node.find_children("*", "MeshInstance3D", true, false):
		var mi := child as MeshInstance3D
		if mi.mesh == null:
			continue
		var rel := _rel_xform(mi, ancestor)
		var aabb: AABB = rel * mi.get_aabb()
		box = aabb if first else box.merge(aabb)
		first = false
	return box


func _meshes_aabb_rel(meshes: Array, ancestor: Node) -> AABB:
	var box := AABB()
	var first := true
	for child in meshes:
		var mi := child as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		var rel := _rel_xform(mi, ancestor)
		var aabb: AABB = rel * mi.get_aabb()
		box = aabb if first else box.merge(aabb)
		first = false
	return box


func _mesh_points_rel(meshes: Array, ancestor: Node, budget: int) -> PackedVector3Array:
	var per_mesh := maxi(budget / maxi(meshes.size(), 1), 200)
	var out := PackedVector3Array()
	for child in meshes:
		var mi := child as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		var rel := _rel_xform(mi, ancestor)
		for s in mi.mesh.get_surface_count():
			var arrays := mi.mesh.surface_get_arrays(s)
			if arrays.size() <= Mesh.ARRAY_VERTEX:
				continue
			var vtx = arrays[Mesh.ARRAY_VERTEX]
			if vtx == null:
				continue
			var n: int = vtx.size()
			if n == 0:
				continue
			var stride := maxi(1, int(float(n) / float(per_mesh)))
			var i := 0
			while i < n and out.size() < budget:
				out.append(rel * (vtx[i] as Vector3))
				i += stride
	return out


## spin 局部坐标系下的顶点采样（每个 mesh 取若干点，总预算 budget）
func _spin_points_rel(spin: Node3D, budget: int) -> PackedVector3Array:
	var meshes := spin.find_children("*", "MeshInstance3D", true, false)
	var per_mesh := maxi(budget / maxi(meshes.size(), 1), 200)
	var out := PackedVector3Array()
	for child in meshes:
		var mi := child as MeshInstance3D
		if mi.mesh == null:
			continue
		var rel := _rel_xform(mi, spin)
		for s in mi.mesh.get_surface_count():
			var arrays := mi.mesh.surface_get_arrays(s)
			if arrays.size() <= Mesh.ARRAY_VERTEX:
				continue
			var vtx = arrays[Mesh.ARRAY_VERTEX]
			if vtx == null:
				continue
			var n: int = vtx.size()
			if n == 0:
				continue
			var stride := maxi(1, int(float(n) / float(per_mesh)))
			var i := 0
			while i < n and out.size() < budget:
				out.append(rel * (vtx[i] as Vector3))
				i += stride
	return out


## 顶点 PCA 最薄轴与 X 轴夹角（度）。用协方差补矩阵 tr*I-A 做幂迭代求最小特征向量。
func _thinnest_axis_vs_x_deg(points: PackedVector3Array) -> float:
	if points.size() < 16:
		return -1.0
	var n := float(points.size())
	var mean := Vector3.ZERO
	for p in points:
		mean += p
	mean /= n
	var cxx := 0.0
	var cyy := 0.0
	var czz := 0.0
	var cxy := 0.0
	var cxz := 0.0
	var cyz := 0.0
	for p in points:
		var d := p - mean
		cxx += d.x * d.x
		cyy += d.y * d.y
		czz += d.z * d.z
		cxy += d.x * d.y
		cxz += d.x * d.z
		cyz += d.y * d.z
	cxx /= n
	cyy /= n
	czz /= n
	cxy /= n
	cxz /= n
	cyz /= n
	var tr := cxx + cyy + czz
	var v := Vector3(0.31, 0.53, 0.81).normalized()
	for iter in 120:
		var w := Vector3(
			(tr - cxx) * v.x - cxy * v.y - cxz * v.z,
			-cxy * v.x + (tr - cyy) * v.y - cyz * v.z,
			-cxz * v.x - cyz * v.y + (tr - czz) * v.z)
		if w.length() < 1e-12:
			return -1.0
		v = w.normalized()
	var ax := clampf(absf(v.x), 0.0, 1.0)
	return rad_to_deg(acos(ax))


# ---------------------------------------------------------------------------
# 辅助
# ---------------------------------------------------------------------------

func _find_spin(model_root: Node, suffix: String) -> Node3D:
	return model_root.find_child("Spin_Wheel_" + suffix, true, false) as Node3D


func _find_node3d(model_root: Node, node_name: String) -> Node3D:
	return model_root.find_child(node_name, true, false) as Node3D


func _rel_xform(node: Node3D, ancestor: Node) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var n: Node = node
	while n != null and n != ancestor:
		if n is Node3D:
			xf = (n as Node3D).transform * xf
		n = n.get_parent()
	return xf


func _is_glass_name(nm: String) -> bool:
	return nm.contains("glass") or nm.contains("glazing") or nm.contains("window") \
		or nm.contains("挡风") or nm.contains("玻璃")


func _is_paint_name(nm: String) -> bool:
	return nm.contains("carpaint") or nm.contains("paint") or nm.contains("车漆") or nm.contains("coloured")


func _is_factory_wing_name(nm: String) -> bool:
	return PartsLibrary._name_is_wing(nm.to_lower())


func _v3pos(v: Vector3) -> Array:
	return [snappedf(v.x, 0.0001), snappedf(v.y, 0.0001), snappedf(v.z, 0.0001)]


func _pristine_spin_positions(path: String) -> Dictionary:
	var out := {}
	var packed = load(path)
	if not (packed is PackedScene):
		return out
	var inst: Node = (packed as PackedScene).instantiate()
	if inst == null:
		return out
	for suffix in WHEEL_SUFFIXES:
		var spin := inst.find_child("Spin_Wheel_" + suffix, true, false)
		if spin is Node3D:
			out[String((spin as Node3D).name)] = (spin as Node3D).position
	inst.free()
	return out


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
