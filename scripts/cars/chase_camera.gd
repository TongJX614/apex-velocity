class_name ChaseCamera
extends Camera3D
## 三个比赛视角：追尾 / 近身 / 车头。
## 车头视角机位在车头前方（看不到车身），鼠标拖动可左右、上下环视。

enum Mode { CHASE, CLOSE, NOSE }

const MODE_LABELS := ["追尾", "近身", "车头"]
const FOV_BOOST_DECAY := 3.1
const KICK_DECAY := 7.5

const NOSE_DRAG_SENS := 0.0032
const NOSE_YAW_LIMIT := 1.35
const NOSE_PITCH_MIN := -0.42
const NOSE_PITCH_MAX := 0.62
## 松开鼠标后先保持 2s，再缓慢回正（纯环视太久会看不见路）。
const NOSE_HOLD_TIME := 2.0
const NOSE_RECENTER_RATE := 0.9

var target: Car
var track: TrackPath
var world: Node = null          # 开放世界：相机不能低于地形
var mode: Mode = Mode.CHASE
var shake := 0.0
## 氮气 / 换挡 / 碰撞叠加的瞬时 FOV 偏移（度），在 _follow_rig 里指数衰减。
var fov_boost := 0.0
## 碰撞 / 换挡的短促镜头顿挫（0..1.6），在 _follow_rig 里指数衰减。
var kick := 0.0
## 车头视角的鼠标环视偏移（弧度）与保持计时。
var nose_yaw := 0.0
var nose_pitch := 0.0
var _nose_dragging := false
var _nose_hold := 0.0


func follow(car_node: Car, track_path: TrackPath = null) -> void:
	target = car_node
	track = track_path
	near = 0.08
	far = 7000.0
	snap()


func add_shake(amount: float) -> void:
	if Settings.get("camera_shake") != null and not bool(Settings.get("camera_shake")):
		return
	shake = clampf(shake + amount, 0.0, 1.4)


## 氮气 / 换挡 / 碰撞的 FOV 冲量（单位：度，可正可负）。
## 在 _follow_rig 中叠加到目标 FOV，并随帧指数衰减，最终回到正常速度 FOV。
func add_fov_boost(amount: float) -> void:
	fov_boost = clampf(fov_boost + amount, -22.0, 32.0)


## 撞击 / 换挡的镜头顿挫：短促俯仰 + 微侧倾，纯旋转偏移，结束时自动回正。
func add_kick(amount: float) -> void:
	if Settings.get("camera_shake") != null and not bool(Settings.get("camera_shake")):
		return
	kick = clampf(kick + amount, 0.0, 1.6)


func _rig_params() -> Dictionary:
	var speed01 := 0.0
	if target != null:
		speed01 = clampf(target.speed_kph / 300.0, 0.0, 1.0)
	if mode == Mode.CLOSE:
		var close_push := smoothstep(0.05, 0.85, speed01) * 2.2
		return {
			"distance": 3.55 + close_push, "height": 1.92 + close_push * 0.06,
			"look_ahead": 6.0, "base_fov": 64.0, "speed01": speed01,
		}
	# 低速：贴车尾的常规追尾视角（车屁股往前看）；
	# 速度上来后机位缓慢升高、视线越过头顶看远，但不往后退太多——
	# 用户反馈「跑起来别拉太远，车太小」：distance 只增加 ~1.2m，FOV 只加 ~5°，
	# 让车在高速时仍占画面足够大。
	# 用户定稿：现在这个升高后的机位就是「初始/基础视角」，全速段都用它；
	# 高速时镜头再向车后方向退一个车身长度（≈4.5m），速度感更强。
	var push_back := smoothstep(0.05, 0.85, speed01) * 4.5
	var distance := 5.75 + push_back
	var height := 2.60 + push_back * 0.10
	var look_ahead := 7.0
	var base_fov := 58.5
	return {
		"distance": distance, "height": height, "look_ahead": look_ahead,
		"base_fov": base_fov, "speed01": speed01,
	}


func snap() -> void:
	fov_boost = 0.0
	kick = 0.0
	nose_yaw = 0.0
	nose_pitch = 0.0
	_nose_hold = 0.0
	if target == null:
		return
	if mode == Mode.NOSE:
		_follow_nose(1.0)
		fov = 74.0
		return
	var rig := _rig_params()
	var fwd := target.forward()
	global_position = target.global_position - fwd * float(rig["distance"]) + Vector3(0.0, float(rig["height"]), 0.0)
	look_at(target.global_position + fwd * float(rig["look_ahead"]) + Vector3(0.0, 1.0, 0.0), Vector3.UP)
	fov = float(rig["base_fov"])


## 切换镜头：追尾 → 近身 → 车头，循环。
func cycle_mode() -> String:
	mode = ((int(mode) + 1) % MODE_LABELS.size()) as Mode
	snap()
	return mode_label()


func mode_label() -> String:
	return MODE_LABELS[int(mode)]


func follow_update(dt: float) -> void:
	if target == null:
		return
	if mode == Mode.NOSE:
		_follow_nose(dt)
		return
	var rig := _rig_params()
	var speed01 := float(rig["speed01"])
	var fwd := target.forward()
	# 速度前馈：指数平滑本身会随车速产生 v/平滑系数 的滞后（280kph 约 6m），
	# 不补偿的话高速下车会被「甩远」显得很小。把车辆速度按同一时间常数补到目标点上，
	# 稳态时相机正好停在想要的 distance/height 上。
	# 贴墙滑行时提高跟随率：车被护栏挡住后仍会沿墙滑动，
	# 镜头必须跟着这段纵向位移走，否则会被甩在后面/卡在墙外。
	var follow_rate := 14.0
	if target.wall_contact:
		follow_rate = 23.0
	var lead := target.vel / follow_rate
	var desired := target.global_position - fwd * float(rig["distance"]) \
		+ Vector3(0.0, float(rig["height"]), 0.0) + lead
	global_position = global_position.lerp(desired, 1.0 - exp(-follow_rate * dt))
	_keep_camera_on_track(dt)
	shake *= exp(-5.0 * dt)
	kick *= exp(-KICK_DECAY * dt)
	fov_boost *= exp(-FOV_BOOST_DECAY * dt)
	var speed_shake := pow(speed01, 2.4) * 0.012
	if Settings.get("camera_shake") != null and not bool(Settings.get("camera_shake")):
		speed_shake = 0.0
		shake = 0.0
		kick = 0.0
	var total_shake := shake * 0.24 + speed_shake
	if total_shake > 0.0005:
		global_position += Vector3(randf_range(-1.0, 1.0), randf_range(-0.6, 0.6), randf_range(-1.0, 1.0)) * total_shake
	var look := target.global_position + fwd * float(rig["look_ahead"]) + Vector3(0.0, 1.0, 0.0)
	# 贴墙滑行：视线略偏向实际行进方向，镜头不会被车头的「顶墙角度」带歪。
	if target.wall_contact:
		var flat_vel := Vector3(target.vel.x, 0.0, target.vel.z)
		if flat_vel.length() > 5.0:
			look += (flat_vel.normalized() - fwd) * float(rig["look_ahead"]) * 0.55
	# 过弯视线：按转向 + 横向滑移把注视点向弯内带一点，高速时更明显。
	# 车身 right() 在 heading=0 时为 -X，正转向正朝这个方向入弯，所以直接乘 steer。
	var steer01 := clampf(target.steer, -1.0, 1.0)
	var slip01 := clampf(absf(target.lat_slip) / 9.0, 0.0, 1.0)
	var corner_look := steer01 * (0.55 + slip01 * 0.70) * (0.35 + speed01 * 0.65)
	look += target.right() * clampf(corner_look * 1.30, -1.15, 1.15)
	look_at(look, Vector3.UP)
	if kick > 0.0005:
		rotate_object_local(Vector3.RIGHT, -kick * 0.055)
		rotate_object_local(Vector3.FORWARD, kick * 0.040)
	fov = lerpf(fov, float(rig["base_fov"]) + fov_boost, 1.0 - exp(-4.5 * dt))


func _keep_camera_on_track(dt: float = 1.0 / 60.0) -> void:
	if world != null and target != null:
		# 开放世界：镜头不能插进地形里
		var ground := float(world.call("height_at", global_position.x, global_position.z))
		global_position.y = maxf(global_position.y, ground + 1.4)
		return
	if track == null or target == null:
		return
	global_position.y = maxf(global_position.y, 0.55)
	var hint := target.track_index
	var info := track.nearest(global_position, hint)
	if info.is_empty():
		return
	var lateral := float(info["lateral"])
	var limit := float(info.get("half_width", track.half_width)) + 1.1
	if absf(lateral) > limit:
		# 直接夹回走廊边界，不做指数逼近。
		# 指数逼近一帧只拉回 12%~35%，要 5~8 帧才收敛，
		# 那几帧镜头停在护栏外面，观众会直接看到护栏另一侧的景物（穿帮），
		# 「相机不许越过护栏」这条验收也过不了。
		var side: Vector3 = info["side"]
		global_position -= side * (lateral - signf(lateral) * limit)


## 车头视角：机位在车头前方，车身完全在身后（看不见车），
## 鼠标拖动叠加 yaw/pitch 环视；松开一段时间后缓慢回正。
func _follow_nose(dt: float) -> void:
	var length := 4.5
	if not target.car_id.is_empty():
		length = float(CarVisual.car_dims(target.car_id).get("length", 4.5))
	var basis := Basis(Vector3.UP, target.heading)
	var desired := target.global_position + basis * Vector3(0.0, 0.76, length * 0.5 + 0.22)
	# 刚性挂载：指数平滑在高速下会产生 v/速率 的滞后（264kph≈2.4m），
	# 把机位拖回座舱里。用户拍板车头视角固定死，直接赋值不平滑。
	global_position = desired
	_keep_camera_on_track(dt)

	if not _nose_dragging:
		_nose_hold += dt
		if _nose_hold > NOSE_HOLD_TIME:
			var k := 1.0 - exp(-NOSE_RECENTER_RATE * dt)
			nose_yaw = lerpf(nose_yaw, 0.0, k)
			nose_pitch = lerpf(nose_pitch, 0.0, k)

	var look_basis := Basis(Vector3.UP, target.heading + nose_yaw)
	var dir := look_basis * Vector3(0.0, sin(nose_pitch), cos(nose_pitch))
	look_at(global_position + dir * 32.0, Vector3.UP)
	kick *= exp(-KICK_DECAY * dt)
	fov_boost *= exp(-FOV_BOOST_DECAY * dt)
	shake *= exp(-5.0 * dt)
	if kick > 0.0005:
		rotate_object_local(Vector3.RIGHT, -kick * 0.050)
		rotate_object_local(Vector3.FORWARD, kick * 0.030)
	# 用户定稿：车头视角固定死——FOV 不随速度变、不加速度抖动、不吃氮气 FOV 冲量，
	# 只保留碰撞瞬间的顿挫反馈。
	var total_shake := shake * 0.22
	if total_shake > 0.0005:
		global_position += Vector3(randf_range(-1.0, 1.0), randf_range(-0.6, 0.6),
			randf_range(-1.0, 1.0)) * total_shake
	fov = lerpf(fov, 74.0, 1.0 - exp(-4.5 * dt))


func _unhandled_input(event: InputEvent) -> void:
	if mode != Mode.NOSE or target == null:
		return
	if event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		_nose_dragging = (event as InputEventMouseButton).pressed
		if _nose_dragging:
			_nose_hold = 0.0
	elif event is InputEventMouseMotion and _nose_dragging:
		var rel := (event as InputEventMouseMotion).relative
		nose_yaw = clampf(nose_yaw + rel.x * NOSE_DRAG_SENS, -NOSE_YAW_LIMIT, NOSE_YAW_LIMIT)
		nose_pitch = clampf(nose_pitch - rel.y * NOSE_DRAG_SENS, NOSE_PITCH_MIN, NOSE_PITCH_MAX)
		_nose_hold = 0.0
