extends Node
## 尾翼替换目视验证场景（一次性工具）：
##   按用户真实存档改装配置构建指定车辆，把相机摆在车尾 3/4 视角，
##   渲染几帧后把截图存到 --out 指定的 png。
## 用法（必须非 headless，才有真实渲染）：
##   Godot --path . res://tools/car_audit/wing_check.tscn -- \
##       --car=bmw_m4_gt4 --out=/tmp/wing_fix/after.png

var _car := "bmw_m4_gt4"
var _out := "/tmp/wing_check.png"
var _frames := 0


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--car="):
			_car = arg.substr(6)
		elif arg.begins_with("--out="):
			_out = arg.substr(6)
	# --analyze-donors：量全部供体翼的几何（端板底/立柱底/翼面底/供体原车行李箱面）
	for arg in OS.get_cmdline_user_args():
		if arg == "--analyze-donors":
			_analyze_donors()
			get_tree().quit(0)
			return
	# 环境：中性灰背景 + 平行光，保证看得清
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.18, 0.19, 0.21)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.55, 0.57, 0.6)
	e.ambient_light_energy = 0.7
	env.environment = e
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-42.0, 32.0, 0.0)
	sun.light_energy = 1.25
	add_child(sun)

	var holder := Node3D.new()
	add_child(holder)
	var spec := {"id": _car, "model": _car + ".glb"}
	var vis := CarVisual.build(spec, holder)
	var model := vis["model"] as Node3D
	if model == null:
		push_error("wing_check: 模型加载失败 " + _car)
		get_tree().quit(1)
		return
	# 走真实改装路径：GarageLook 内部经 Garage.wing_donor_id 读「仓内」配置，
	# 所以直接改内存里的仓配置（不调 set_option，不触发写盘）；--wing= 强制指定档位
	var forced := -1
	for arg2 in OS.get_cmdline_user_args():
		if arg2.begins_with("--wing="):
			forced = int(arg2.substr(7))
	if forced >= 0:
		Garage.config(_car)["wing"] = forced
	for arg2 in OS.get_cmdline_user_args():
		if arg2.begins_with("--wheel="):
			Garage.config(_car)["wheel"] = int(arg2.substr(8))
	# --apply-times=N：模拟 part_tuner 在同一模型上反复 apply（切换翼/轮选项时的真实路径）
	var apply_times := 1
	for arg2 in OS.get_cmdline_user_args():
		if arg2.begins_with("--apply-times="):
			apply_times = maxi(1, int(arg2.substr(14)))
	var cfg: Dictionary = Garage.config(_car)
	var applied: Dictionary = {}
	for it in apply_times:
		applied = GarageLook.apply(model, _car, cfg)
	print("[wing_check] car=%s cfg=%s wing_donor=%s applied=%s" % [
		_car, cfg, Garage.wing_donor_id(_car), applied])
	# 供体轮人工偏移诊断（part_tuner 分桶数据是否生效）+ 四角挂装体检
	var dw := model.find_child("ProceduralPartWheel_FL", true, false) as Node3D
	if dw != null:
		print("[wing_check] wheel_donor=%s donor_wheel_FL pos=%s" % [
			Garage.wheel_donor_id(_car), dw.position])
	for suf2 in ["FL", "FR", "RL", "RR"]:
		var sp2 := model.find_child("Spin_Wheel_" + suf2, true, false) as Node3D
		var wh2 := model.find_child("Wheel_" + suf2, true, false) as Node3D
		var dn2 := model.find_child("ProceduralPartWheel_" + suf2, true, false) as Node3D
		var lines: Array[String] = []
		if wh2 != null:
			for nd in wh2.find_children("*", "MeshInstance3D", true, false):
				var m2 := nd as MeshInstance3D
				if m2.mesh == null or m2.get_meta("ProceduralPart", false):
					continue
				lines.append("%s%s vis=%s" % [m2.name, "(外)" if not String(m2.name).ends_with(suf2) and not wh2.is_ancestor_of(m2) else "", m2.visible])
		print("[wheel_diag] %s spin=%s host=%s donor=%s pos=%s 原轮可见明细: %s" % [
			suf2, sp2 != null, wh2 != null, dn2 != null,
			str(dn2.position) if dn2 != null else "-", " | ".join(lines)])
	# 焊死翼手术验收：Ducktail_* 节点在装翼时应隐藏、原厂档应显示
	for dn in ["Ducktail_01", "Ducktail_02", "Ducktail_03", "Ducktail_04"]:
		var dt := model.find_child(dn, true, false) as Node3D
		if dt != null:
			print("[wing_check] %s visible=%s (装翼时应为false, 原厂档应为true)" % [dn, dt.visible])
	var boot := model.find_child("m4_gt4_LOD_A_BOOT_mm_ext", true, false) as MeshInstance3D
	if boot != null:
		print("[wing_check] boot surfaces=%d visible=%s" % [boot.mesh.get_surface_count(), boot.visible])
	for sn in ["Spoiler_01", "Spoiler_02"]:
		var sp := model.find_child(sn, true, false) as MeshInstance3D
		if sp != null:
			print("[wing_check] %s visible=%s tagged=%s surfaces=%d" % [sn, sp.visible, sp.get_meta("ProceduralPart", false), sp.mesh.get_surface_count()])
	# 调试：--hide=<节点名> 强制隐藏某节点；--show=<节点名> 只显示该节点（隔离定位焊死几何）
	for arg2 in OS.get_cmdline_user_args():
		if arg2.begins_with("--hide="):
			var h := model.find_child(arg2.substr(7), true, false) as Node3D
			if h != null:
				h.visible = false
				print("[wing_check] forced hide -> ", h.name)
		elif arg2.begins_with("--show="):
			for mi2 in model.find_children("*", "MeshInstance3D", true, false):
				(mi2 as MeshInstance3D).visible = false
			var sh := model.find_child(arg2.substr(7), true, false) as Node3D
			if sh != null:
				sh.visible = true
				print("[wing_check] isolated -> ", sh.name)
		elif arg2 == "--cut-selftest":
			# 空间删除闭环自测：对某网格 surface0 的前 100 个三角形记录切除 → 应用 → 看变化
			var target := model.find_child("b_Kit4_Paint_Geo_lodA_Kit4_Paint_Geo_lodA_BMW_VarisM4GT_ce",
				true, false) as MeshInstance3D
			if target == null:
				target = (model.find_children("*", "MeshInstance3D", true, false).front()
					as MeshInstance3D)
			var am := target.mesh as ArrayMesh
			var idx: PackedInt32Array = am.surface_get_arrays(0)[Mesh.ARRAY_INDEX]
			var tris: Array = []
			for k in mini(100, idx.size() / 3):
				tris.append(k)
			var np := String(model.get_path_to(target))
			PartsLibrary.add_mesh_cut(_car, np, 0, tris)
			var removed := PartsLibrary.apply_mesh_cuts(model, _car)
			var after: PackedInt32Array = (target.mesh as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_INDEX]
			print("[cut_selftest] node=%s 记录=%d 应用删除=%d tri %d -> %d (meta=%s)" % [
				target.name, tris.size(), removed, idx.size() / 3, after.size() / 3,
				str(model.has_meta("ProceduralCuts"))])
		elif arg2 == "--list-meshes":
			# 列出全部可见网格的全局包围盒（定位游离残件用；渲染前节点已入树，用 global_transform）
			for node3 in model.find_children("*", "MeshInstance3D", true, false):
				var mi3 := node3 as MeshInstance3D
				if mi3.mesh == null or not mi3.visible:
					continue
				var wab: AABB = mi3.global_transform * mi3.mesh.get_aabb()
				print("[mesh] %s%s  center=(%.2f, %.2f, %.2f) size=(%.2f, %.2f, %.2f)" % [
					mi3.name, " [自制]" if mi3.get_meta("ProceduralPart", false) else "",
					wab.get_center().x, wab.get_center().y, wab.get_center().z,
					wab.size.x, wab.size.y, wab.size.z])

	# 相机：车尾在 -z，摆后 3/4 高位视角
	var cam := Camera3D.new()
	add_child(cam)
	cam.position = Vector3(3.1, 1.55, -4.6)
	cam.look_at(Vector3(0.0, 0.75, -1.4))
	cam.current = true
	# --closeup：特写镜头，对准车尾翼身连接处放大查看（--closeupplus：车尾朝 +z 的旋转车）
	var closeup := false
	for arg2 in OS.get_cmdline_user_args():
		if arg2 == "--closeup":
			closeup = true
	if closeup:
		var plus := false
		for arg2 in OS.get_cmdline_user_args():
			if arg2 == "--closeupplus":
				plus = true
		cam.position = Vector3(1.5, 1.25, 3.1) if plus else Vector3(1.5, 1.25, -3.1)
		cam.look_at(Vector3(0.0, 0.95, 1.9) if plus else Vector3(0.0, 0.95, -1.9))
	# --right / --left：车身正侧视角（+x 为右），检查两侧车轮换装是否一致
	for arg2 in OS.get_cmdline_user_args():
		if arg2 == "--right":
			cam.position = Vector3(5.2, 1.35, 0.2)
			cam.look_at(Vector3(0.0, 0.62, 0.0))
		elif arg2 == "--left":
			cam.position = Vector3(-5.2, 1.35, 0.2)
			cam.look_at(Vector3(0.0, 0.62, 0.0))

	# 诊断数值：车体 AABB、实测行李箱面、翼组世界 AABB 底部
	var box := PartsLibrary._subtree_aabb(model)
	var donor := Garage.wing_donor_id(_car)
	var show_debug := false
	for arg2 in OS.get_cmdline_user_args():
		if arg2 == "--debug-geo":
			show_debug = true
	if not donor.is_empty():
		var tpl := PartsLibrary._wing_template(donor)
		var rear_is_min := float(tpl.get("fz", 0.5)) < 0.5
		var deck_y := PartsLibrary._rear_deck_y(model, box, rear_is_min)
		print("[wing_check] box pos=%s size=%s" % [box.position, box.size])
		print("[wing_check] deck_y=%.3f  (H=%.3f, 占比=%.2f)" % [deck_y, box.size.y, (deck_y - box.position.y) / box.size.y])
		var wing := model.find_child("ProceduralPartWing", true, false) as Node3D
		if wing != null:
			var wbox := PartsLibrary._subtree_aabb(wing)
			var xform := Transform3D.IDENTITY
			var cur: Node = wing
			while cur != null and cur != model:
				if cur is Node3D:
					xform = (cur as Node3D).transform * xform
				cur = cur.get_parent()
			var wworld: AABB = xform * wbox
			print("[wing_check] wing world pos=%s size=%s bottom_y=%.3f 与deck间隙=%.3f" % [
				wworld.position, wworld.size, wworld.position.y, wworld.position.y - deck_y])
			if show_debug:
				_draw_debug(model, box, deck_y, wworld)

# --debug-geo：把 deck 平面（红）和翼组包围盒（绿线框）画进画面
func _draw_debug(model: Node3D, box: AABB, deck_y: float, wbox: AABB) -> void:
	var dbg := Node3D.new()
	model.add_child(dbg)
	# deck 平面：车尾 40% 长度的半透明红板
	var panel := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(box.size.z * 0.4, box.size.x * 0.96)
	panel.mesh = pm
	var pmat := StandardMaterial3D.new()
	pmat.albedo_color = Color(1, 0.1, 0.1, 0.45)
	pmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	pmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	panel.material_override = pmat
	panel.rotation_degrees = Vector3(0, 90, 0)
	panel.position = Vector3(box.get_center().x, deck_y, box.get_center().z)
	dbg.add_child(panel)
	# 翼组包围盒线框（绿）
	var wire := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = wbox.size
	wire.mesh = bm
	var wmat := StandardMaterial3D.new()
	wmat.albedo_color = Color(0.1, 1, 0.2, 0.22)
	wmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	wmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	wire.material_override = wmat
	wire.position = wbox.get_center()
	dbg.add_child(wire)
	print("[wing_check] debug geo drawn: deck plane red, wing box green")


func _process(_d: float) -> void:
	_frames += 1
	if _frames == 12:
		var img := get_viewport().get_texture().get_image()
		img.save_png(_out)
		print("[wing_check] saved -> " + _out)
		get_tree().quit(0)


## 量供体翼几何：找连接底面（立柱/支座底）与端板底的差值，
## 以及供体原车上翼底与行李箱面的关系 —— 用于定放置公式。
func _analyze_donors() -> void:
	for d in PartsLibrary.wing_donor_ids():
		var tpl := PartsLibrary._wing_template(d)
		print("[donor] %s  模板rel=%+.3f" % [d, float(tpl.get("rel", 0.0))])
		var inst := PartsLibrary._instantiate(d)
		if inst == null:
			print("[donor] %s 实例化失败" % d)
			continue
		var car_box := PartsLibrary._subtree_aabb(inst)
		# 收翼组顶点（车模局部坐标）
		var verts := PackedVector3Array()
		for node in inst.find_children("*", "MeshInstance3D", true, false):
			var mi := node as MeshInstance3D
			if mi.mesh == null or not mi.visible:
				continue
			var nm := String(mi.name).to_lower()
			if not (nm.contains("spoiler") or nm.contains("wing") or nm.contains("尾翼")):
				continue
			var rel := PartsLibrary._relative_to(mi, inst)
			for s in mi.mesh.get_surface_count():
				var arrays := mi.mesh.surface_get_arrays(s)
				if arrays.size() <= Mesh.ARRAY_VERTEX or arrays[Mesh.ARRAY_VERTEX] == null:
					continue
				for v in arrays[Mesh.ARRAY_VERTEX]:
					verts.append(rel * v)
		if verts.is_empty():
			print("[donor] %s 无翼顶点" % d)
			inst.free()
			continue
		var lo := Vector3(1e9, 1e9, 1e9)
		var hi := Vector3(-1e9, -1e9, -1e9)
		for v in verts:
			lo = lo.min(v)
			hi = hi.max(v)
		var half_w := (hi.x - lo.x) * 0.5
		var cx := (hi.x + lo.x) * 0.5
		var bottom_90 := 1e9   # 排除两侧各 10%（端板区）后的最低点
		var bottom_80 := 1e9
		var plane_y := 1e9     # 翼面底：y 的 90 分位附近视为翼面
		var ys := []
		for v in verts:
			ys.append(v.y)
			if absf(v.x - cx) <= half_w * 0.9:
				bottom_90 = minf(bottom_90, v.y)
			if absf(v.x - cx) <= half_w * 0.8:
				bottom_80 = minf(bottom_80, v.y)
		ys.sort()
		plane_y = ys[mini(ys.size() - 1, int(ys.size() * 0.85))]
		# 供体原车行李箱面
		var rear_is_min := false
		var wing_cz := (lo.z + hi.z) * 0.5
		rear_is_min = absf(wing_cz - car_box.position.z) < absf(wing_cz - (car_box.position.z + car_box.size.z))
		var deck := PartsLibrary._rear_deck_y(inst, car_box, rear_is_min)
		print("[donor] %s" % d)
		print("   翼AABB底=%.3f  立柱底(排10%%)=%.3f  排20%%=%.3f  翼面底(85分位)=%.3f" % [
			lo.y, bottom_90, bottom_80, plane_y])
		print("   供体deck=%.3f  翼底-deck=%+.3f  立柱底-deck=%+.3f  翼组高=%.3f 宽=%.3f" % [
			deck, lo.y - deck, bottom_90 - deck, hi.y - lo.y, hi.x - lo.x])
		inst.free()
