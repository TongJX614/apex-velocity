extends Node
## 临时探针：逐车实测「车轮转动」。模拟 car.gd 的 spin.rotation.x 滚转一圈，量：
##   · 胎体径向跳动（滚动半径变化 %）与轮心漂移 —— 非正圆/偏心
##   · 轮毂 PCA 最薄轴 vs 滚转轴夹角（全顶点，不抽样）—— 轮辐歪着转
##   · 轮毂外缘摆动幅度（轮缘半径带内 X 的一次谐波峰峰值）—— 转起来左右摆多少米
##   · 轮毂/胎体同心度（AABB 几何中心，不用顶点质心）
##   · 滚转轴 vs 车体 X 轴夹角 —— 整轮 tumble
##   · 滚动方向：rotation.x 增大时胎顶顶点应向 +Z（车头）移动
## 用法: Godot --path <abs> res://tools/car_audit/wheel_spin_check.tscn -- --out=/tmp/wheelchk/spin.txt

const STEPS := 12
const SAMPLE_BUDGET := 2000

const RADIAL_VAR_WARN := 2.0    # %
const DRIFT_WARN := 0.005       # m
const RIM_TILT_WARN := 3.0      # deg
const RIM_WOBBLE_WARN := 0.008  # m 峰峰值
const CONCENTRIC_WARN := 0.012  # m
const AXLE_TILT_WARN := 3.0     # deg

var _out := "/tmp/wheel_spin_check.txt"
var _only: Array[String] = []


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			_out = arg.substr(6)
		elif arg.begins_with("--cars="):
			for c in arg.substr(7).split(",", false):
				_only.append(String(c).strip_edges())
	DirAccess.make_dir_recursive_absolute(_out.get_base_dir())
	var cars: Dictionary = GameData.car_manifest.get("cars", {})
	var ids: Array[String] = []
	for k in cars.keys():
		if _only.is_empty() or _only.has(String(k)):
			ids.append(String(k))
	ids.sort()

	var lines: PackedStringArray = []
	var bad: Array[String] = []
	var rebuilt_cars: Array[String] = []
	lines.append("车轮转动实测（模拟 spin.rotation.x 滚转 %d 步）  %s" % [STEPS, Time.get_datetime_string_from_system()])
	lines.append("阈值: 胎体径向变化>%.1f%%  胎体轮心漂移>%.3fm  轮毂轴倾角>%.1f°  轮缘摆动>%.3fm  不同心>%.3fm  滚转轴倾角>%.1f°  滚动反向" % [
		RADIAL_VAR_WARN, DRIFT_WARN, RIM_TILT_WARN, RIM_WOBBLE_WARN, CONCENTRIC_WARN, AXLE_TILT_WARN])
	lines.append("")
	for id in ids:
		var entry: Dictionary = cars.get(id, {})
		var holder := Node3D.new()
		add_child(holder)
		var built := CarVisual.build({"id": id, "model": String(entry.get("model", ""))}, holder)
		var model: Node3D = built.get("model", null)
		if model == null:
			lines.append("[SPIN] %-24s LOAD FAIL" % id)
			bad.append(id)
			holder.free()
			continue
		var car_warn: Array[String] = []
		for suffix in ["FL", "FR", "RL", "RR"]:
			var spin := model.find_child("Spin_Wheel_" + suffix, true, false) as Node3D
			if spin == null:
				car_warn.append(suffix + " 无 Spin 节点")
				continue
			var r := _measure(spin, holder, float(entry.get("wheelRadius", 0.34)))
			var w: Array[String] = r["warn"]
			lines.append("[SPIN] %-24s %s tyre[var=%.2f%% drift=%.4f r=%.3f/%.3f] rim[tilt=%.2f° wobble=%.4f ecc=%.4f] axle=%.2f° dir=%s%s" % [
				id, suffix,
				float(r["tyre_var"]), float(r["tyre_drift"]), float(r["r_meas"]), float(r["r_man"]),
				float(r["rim_tilt"]), float(r["rim_wobble"]), float(r["ecc"]),
				float(r["axle"]), String(r["dir"]),
				(" REBUILT" if bool(r["rebuilt"]) else "") + (("  WARN: " + "; ".join(w)) if w.size() > 0 else "")])
			if bool(r["rebuilt"]):
				rebuilt_cars.append(id + "/" + suffix)
			for x in w:
				car_warn.append(suffix + " " + x)
		if car_warn.size() > 0:
			bad.append(id)
			lines.append("[CAR] %-24s %d 项异常: %s" % [id, car_warn.size(), "; ".join(car_warn)])
		lines.append("")
		holder.free()
	lines.append("汇总: 车辆=%d  异常车=%d %s" % [ids.size(), bad.size(), str(bad)])
	lines.append("胎体被重建(Tyre_Rebuilt)的轮: %s" % str(rebuilt_cars))
	var f := FileAccess.open(_out, FileAccess.WRITE)
	f.store_string("\n".join(lines))
	f.close()
	print("\n".join(lines))
	get_tree().quit(0)


func _measure(spin: Node3D, holder: Node3D, r_man: float) -> Dictionary:
	var tyre: Array[MeshInstance3D] = []
	var rim: Array[MeshInstance3D] = []
	for node in spin.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			continue
		var nm := String(mi.name).to_lower()
		if nm.contains("brake") or nm.contains("disc") or nm.contains("caliper"):
			continue
		if nm.contains("tyre") or nm.contains("tire") or nm.contains("胎"):
			tyre.append(mi)
		elif nm.contains("rim") or nm.contains("spoke") or nm.contains("轮") or nm.contains("毂"):
			rim.append(mi)
	var tp := _points(tyre, spin)
	var rp := _points(rim, spin)
	var authored := spin.rotation
	var rel0 := _rel(spin, holder)
	var warn: Array[String] = []

	# 滚动方向：胎顶（Y 最大）顶点在 rotation.x 增大后应向 +Z（车头）移动
	var dir := "n/a"
	var top_dz := 0.0
	if tp.size() > 0:
		var best := 0
		var best_y := -INF
		for i in tp.size():
			var q := rel0 * tp[i]
			if q.y > best_y:
				best_y = q.y
				best = i
		var q0 := rel0 * tp[best]
		spin.rotation.x = authored.x + 0.12
		var q1 := _rel(spin, holder) * tp[best]
		spin.rotation.x = authored.x
		top_dz = q1.z - q0.z
		dir = "OK" if top_dz > 0.001 else ("REVERSED" if top_dz < -0.001 else "STATIC")
	if dir == "REVERSED":
		warn.append("滚动反向（胎顶 dz=%.4f，应向前 +Z）" % top_dz)
	elif dir == "STATIC":
		warn.append("滚转时胎顶几乎不动（dz=%.4f）" % top_dz)

	# 滚转轴 vs 车体 X 轴
	var axle := rad_to_deg(acos(clampf(absf(rel0.basis.x.normalized().x), 0.0, 1.0)))
	if axle > AXLE_TILT_WARN:
		warn.append("滚转轴偏车体X %.2f°（整轮 tumble）" % axle)

	# 胎体动态滚动
	var tm := _roll_stats(_sample(tp), spin, holder, authored)
	if tm["n"] == 0:
		warn.append("无胎体网格")
	else:
		if float(tm["var"]) > RADIAL_VAR_WARN:
			warn.append("胎体径向变化 %.2f%%（非正圆）" % float(tm["var"]))
		if float(tm["drift"]) > DRIFT_WARN:
			warn.append("胎体轮心漂移 %.4f m" % float(tm["drift"]))

	# 轮毂：全顶点 PCA 倾角 + 轮缘摆动幅度（静态，spin 局部坐标）
	var rim_tilt := -1.0
	var rim_wobble := 0.0
	if rp.size() >= 16:
		var ax := _pca_thinnest(rp)
		rim_tilt = rad_to_deg(acos(clampf(absf(ax.normalized().x), 0.0, 1.0)))
		if rim_tilt > RIM_TILT_WARN:
			warn.append("轮毂轴倾角 %.2f°（轮辐歪着转）" % rim_tilt)
		rim_wobble = _rim_wobble(rp)
		if rim_wobble > RIM_WOBBLE_WARN:
			warn.append("轮缘摆动 %.4f m 峰峰值" % rim_wobble)

	var ecc := 0.0
	if tp.size() > 0 and rp.size() > 0:
		var tc := _aabb_center(tp)
		var rc := _aabb_center(rp)
		ecc = Vector2(tc.y - rc.y, tc.z - rc.z).length()
		if ecc > CONCENTRIC_WARN:
			warn.append("轮毂/胎体不同心 %.4f m" % ecc)
	var r_meas := 0.0
	var rebuilt := spin.find_child("Tyre_Rebuilt", true, false) != null
	if tp.size() > 0:
		var c := _aabb_center(tp)
		for p in tp:
			var d := p - c
			r_meas = maxf(r_meas, Vector2(d.y, d.z).length())
		if r_man > 0.05 and absf(r_meas / r_man - 1.0) > 0.05:
			warn.append("实测胎径 %.3f vs manifest %.3f（转速比 %.2f，轮子打滑感）" % [r_meas, r_man, r_meas / r_man])
	spin.rotation = authored
	return {
		"tyre_var": tm["var"], "tyre_drift": tm["drift"],
		"rim_tilt": rim_tilt, "rim_wobble": rim_wobble, "ecc": ecc,
		"axle": axle, "dir": dir, "warn": warn, "r_meas": r_meas, "r_man": r_man,
		"rebuilt": rebuilt,
	}


## 滚转一圈：胎体采样点在车体坐标系里的 AABB 中心漂移与 Y/Z 外径变化。
func _roll_stats(pts: PackedVector3Array, spin: Node3D, holder: Node3D, authored: Vector3) -> Dictionary:
	if pts.size() == 0:
		return {"var": 0.0, "drift": 0.0, "n": 0}
	var centers: Array[Vector3] = []
	var extents: Array[float] = []
	for k in STEPS:
		spin.rotation.x = authored.x + TAU * float(k) / float(STEPS)
		var xf := _rel(spin, holder)
		var b := xf.basis
		var o := xf.origin
		var mny := INF; var mxy := -INF; var mnz := INF; var mxz := -INF
		var mnx := INF; var mxx := -INF
		for p in pts:
			var qx := o.x + b.x.x * p.x + b.y.x * p.y + b.z.x * p.z
			var qy := o.y + b.x.y * p.x + b.y.y * p.y + b.z.y * p.z
			var qz := o.z + b.x.z * p.x + b.y.z * p.y + b.z.z * p.z
			if qy < mny: mny = qy
			if qy > mxy: mxy = qy
			if qz < mnz: mnz = qz
			if qz > mxz: mxz = qz
			if qx < mnx: mnx = qx
			if qx > mxx: mxx = qx
		centers.append(Vector3((mnx + mxx) * 0.5, (mny + mxy) * 0.5, (mnz + mxz) * 0.5))
		extents.append(maxf(mxy - mny, mxz - mnz))
	spin.rotation = authored
	var mean := Vector3.ZERO
	for c in centers:
		mean += c
	mean /= float(centers.size())
	var drift := 0.0
	for c in centers:
		drift = maxf(drift, c.distance_to(mean))
	var emin := INF; var emax := 0.0; var esum := 0.0
	for e in extents:
		emin = minf(emin, e)
		emax = maxf(emax, e)
		esum += e
	var var_pct := (emax - emin) / maxf(esum / float(extents.size()), 0.0001) * 100.0
	return {"var": var_pct, "drift": drift, "n": pts.size()}


## 轮缘摆动：取离轴最外 15% 半径带的顶点，把 X 对角位置 φ 做一次谐波拟合
## X ≈ a0 + a1·cosφ + a2·sinφ，峰峰值 2·√(a1²+a2²) 就是轮子转一圈时轮缘
## 沿轴向往复摆动的幅度（轮缘面垂直于轮轴时应≈0）。中心用 AABB 几何中心。
func _rim_wobble(pts: PackedVector3Array) -> float:
	var c := _aabb_center(pts)
	var rmax := 0.0
	for p in pts:
		var d := p - c
		rmax = maxf(rmax, Vector2(d.y, d.z).length())
	if rmax <= 0.0001:
		return 0.0
	var n := 0.0
	var sx := 0.0; var sc := 0.0; var ss := 0.0
	var sxc := 0.0; var sxs := 0.0
	for p in pts:
		var d := p - c
		var r := Vector2(d.y, d.z).length()
		if r < rmax * 0.85:
			continue
		var phi := atan2(d.z, d.y)
		var co := cos(phi)
		var si := sin(phi)
		n += 1.0
		sx += p.x
		sc += co
		ss += si
		sxc += p.x * co
		sxs += p.x * si
	if n < 24.0:
		return 0.0
	# 均匀 angular 覆盖下的一次谐波系数（最小二乘的近似解）
	var a1 := 2.0 * (sxc - sx * sc / n) / n
	var a2 := 2.0 * (sxs - sx * ss / n) / n
	return 2.0 * Vector2(a1, a2).length()


func _aabb_center(pts: PackedVector3Array) -> Vector3:
	var mn := Vector3(INF, INF, INF)
	var mx := Vector3(-INF, -INF, -INF)
	for p in pts:
		mn = Vector3(minf(mn.x, p.x), minf(mn.y, p.y), minf(mn.z, p.z))
		mx = Vector3(maxf(mx.x, p.x), maxf(mx.y, p.y), maxf(mx.z, p.z))
	return (mn + mx) * 0.5


func _points(meshes: Array[MeshInstance3D], spin: Node3D) -> PackedVector3Array:
	var out := PackedVector3Array()
	for mi in meshes:
		var rel := _rel(mi, spin)
		for s in mi.mesh.get_surface_count():
			var verts: PackedVector3Array = mi.mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]
			for v in verts:
				out.append(rel * v)
	return out


func _sample(pts: PackedVector3Array) -> PackedVector3Array:
	if pts.size() <= SAMPLE_BUDGET:
		return pts
	var out := PackedVector3Array()
	var stride := float(pts.size()) / float(SAMPLE_BUDGET)
	for i in SAMPLE_BUDGET:
		out.append(pts[int(float(i) * stride)])
	return out


func _points_center(pts: PackedVector3Array) -> Vector3:
	var c := Vector3.ZERO
	for p in pts:
		c += p
	return c / float(maxi(pts.size(), 1))


func _pca_thinnest(points: PackedVector3Array) -> Vector3:
	var n := float(points.size())
	var mean := _points_center(points)
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


func _rel(node: Node3D, ancestor: Node) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var n: Node = node
	while n != null and n != ancestor:
		if n is Node3D:
			xf = (n as Node3D).transform * xf
		n = n.get_parent()
	return xf