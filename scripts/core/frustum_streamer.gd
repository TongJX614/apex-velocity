extends Node
## 相机朝向驱动的「扇区剔除 + 转向预取 + 视野内画质加权」。
##
## 场景一次性建好，但运行时只把「当前视野 + 即将转入的一侧」的分块打开：
##   · 正背后的 MultiMesh 分块直接 visible=false，GPU 完全不画；
##   · 左/右打方向时，按角速度提前把即将进入视野的那一侧打开（预取扇区），
##     避免转过去之后才弹出；
##   · 视野正前方的分块给更远的可见距离（远景/建筑看得更清楚），边缘递减；
##   · 加滞回，避免分块在扇区边界反复闪烁。
##
## 只管理 MultiMeshInstance3D（树/草/建筑/场地件都是空间分块 MultiMesh）。
## 路面、地形、护栏这类跨全赛道的连续网格交给 Godot 自带视锥剔除，
## 不会被这里关掉，避免画面缺面。

const UPDATE_INTERVAL := 0.09
const ALWAYS_VISIBLE_RADIUS := 280.0
const HYSTERESIS := 0.50
const SIDE_MARGIN := 0.55

var camera: Camera3D
var world: Node3D
var enabled := true
## 开放世界模式：城市分块的包围盒很大（半经 150~350m），默认的朝向余量
## 会让「允许角」接近 180°，扇区剔除基本失效（实测常驻 3500 万面/帧）。
## 收紧侧向余量，让背后的分块真正被关掉。
var tight_sector := false
var prefetch_strength := 1.8
var max_distance := 1500.0
var visible_count := 0
var chunk_count := 0

var _chunks: Array[Dictionary] = []
var _timer := 0.0
var _prev_fwd := Vector3.FORWARD
var _turn := 0.0  # >0 左转，<0 右转（平滑后的角速度）


func setup(cam: Camera3D, world_root: Node3D) -> void:
	camera = cam
	world = world_root
	_turn = 0.0
	_prev_fwd = _forward()
	collect()


func clear() -> void:
	camera = null
	world = null
	_chunks.clear()
	visible_count = 0
	chunk_count = 0


## 场景重建后重新收集分块；也可用于画质档切换后刷新基准距离。
func collect() -> void:
	_chunks.clear()
	visible_count = 0
	if world == null or not is_instance_valid(world):
		return
	for node in world.find_children("*", "MultiMeshInstance3D", true, false):
		var mmi := node as MultiMeshInstance3D
		if mmi == null or mmi.multimesh == null or _is_part_of_car(mmi):
			continue
		var box: AABB = mmi.get_aabb()
		if box.size.length() <= 0.001:
			continue
		_chunks.append({
			"node": mmi,
			"center": mmi.global_transform * box.get_center(),
			"radius": box.size.length() * 0.5,
			"base_end": mmi.visibility_range_end,
			"shown": true,
			"tier": -1,
		})
		mmi.visible = true
	chunk_count = _chunks.size()
	visible_count = chunk_count
	_timer = UPDATE_INTERVAL


## 车辆（含菜单展车）的轮组/改装件不能被扇区调度器关掉
func _is_part_of_car(node: Node) -> bool:
	var p := node.get_parent()
	while p != null:
		var n := String(p.name).to_lower()
		if n.contains("car") or n.contains("garage") or n.contains("wheel"):
			return true
		p = p.get_parent()
	return false


func _forward() -> Vector3:
	if camera == null or not is_instance_valid(camera):
		return Vector3.FORWARD
	return -camera.global_transform.basis.z.normalized()


func _process(dt: float) -> void:
	if not enabled or camera == null or _chunks.is_empty():
		return
	_timer += dt
	if _timer < UPDATE_INTERVAL:
		return
	var step := _timer
	_timer = 0.0
	_update_sectors(step)


func _update_sectors(dt: float) -> void:
	var fwd := _forward()
	# 叉积 y 分量 = 水平转向速率，正为左转
	var rate := _prev_fwd.cross(fwd).y / maxf(dt, 0.001)
	_turn = lerpf(_turn, clampf(rate, -4.0, 4.0), 0.38)
	_prev_fwd = fwd

	var cam_pos: Vector3 = camera.global_position
	var vp_size: Vector2 = Vector2(get_viewport().size)
	var aspect := maxf(vp_size.x / maxf(vp_size.y, 1.0), 1.0)
	var margin := 0.22 if tight_sector else SIDE_MARGIN
	var half: float = atan(tan(deg_to_rad(camera.fov) * 0.5) * aspect) + margin
	var prefetch := clampf(absf(_turn) * 0.19, 0.0, 0.62) * prefetch_strength
	var turn_side := signf(_turn)

	var shown := 0
	for chunk in _chunks:
		var mmi := chunk["node"] as MultiMeshInstance3D
		if mmi == null or not is_instance_valid(mmi):
			continue
		var center: Vector3 = chunk["center"]
		var radius: float = float(chunk["radius"])
		var to := center - cam_pos
		var dist := to.length()
		var dir := to / maxf(dist, 0.001)
		var dot := clampf(dir.dot(fwd), -1.0, 1.0)
		var angle := acos(dot)
		var spread := atan2(radius, maxf(dist, radius + 1.0))
		# 转向侧提前打开：给额外的预取扇区
		var side := signf(fwd.cross(dir).y)
		var extra := prefetch if side * turn_side > 0.0 else 0.0
		var allow: float = half + spread + extra
		if bool(chunk["shown"]):
			allow += HYSTERESIS
		var in_range: bool = dist - radius < max_distance
		# 近处分块永远可见（视野外也不关），避免转头时模型突然消失/出现
		var near: bool = dist - radius < ALWAYS_VISIBLE_RADIUS
		var want: bool = in_range and (near or (angle - spread < allow))
		if want != bool(chunk["shown"]):
			mmi.visible = want
			chunk["shown"] = want
		if not want:
			chunk["tier"] = -1
			continue
		shown += 1

		# 视野中心 = 最远可见距离；转向侧再提前一档
		var alignment: float = clampf((dot - cos(half)) / maxf(1.0 - cos(half), 0.001), 0.0, 1.0)
		var tier := 0
		if alignment > 0.62:
			tier = 2
		elif alignment > 0.26:
			tier = 1
		if side * turn_side > 0.0 and absf(_turn) > 0.25:
			tier = mini(tier + 1, 2)
		if int(chunk["tier"]) == tier:
			continue
		chunk["tier"] = tier
		var base_end: float = float(chunk["base_end"])
		if base_end > 0.0:
			mmi.visibility_range_end = base_end * [1.0, 1.0, 1.25][tier]
	visible_count = shown


func stats() -> String:
	if chunk_count == 0:
		return "分块剔除：未启用"
	return "分块剔除：%d / %d 可见   转向预取：%s" % [
		visible_count, chunk_count,
		("左" if _turn > 0.25 else ("右" if _turn < -0.25 else "直行"))]
