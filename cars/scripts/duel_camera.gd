class_name DuelCamera
extends ChaseCamera
## 本地双人同屏镜头：始终看向两台车的中间，按两车距离自动拉远，保证两人都在画面里。
## 继承 ChaseCamera 以复用 add_shake / mode_label 等接口。

var other: Car


func follow_duo(a: Car, b: Car, path: TrackPath = null) -> void:
	other = b
	follow(a, path)
	current = true
	snap_duo()


func snap_duo() -> void:
	if target == null:
		return
	var focus := _focus_pos()
	var fwd := _focus_fwd()
	var sep := _separation()
	var speed01 := _focus_speed01()
	var distance := lerpf(7.0, 9.0, speed01) + sep * 0.55
	var height := lerpf(3.2, 4.1, speed01) + sep * 0.22
	global_position = focus - fwd * distance + Vector3(0.0, height, 0.0)
	look_at(focus + fwd * (5.5 + sep * 0.28) + Vector3(0.0, 0.9, 0.0), Vector3.UP)
	fov = lerpf(62.0, 68.0, speed01)


func _separation() -> float:
	if target == null or other == null or not is_instance_valid(other):
		return 0.0
	return target.global_position.distance_to(other.global_position)


func _focus_pos() -> Vector3:
	if target == null:
		return global_position
	if other == null or not is_instance_valid(other):
		return target.global_position
	return (target.global_position + other.global_position) * 0.5


func _focus_fwd() -> Vector3:
	if target == null:
		return -global_transform.basis.z
	if other == null or not is_instance_valid(other):
		return target.forward()
	return (target.forward() + other.forward()).normalized()


func _focus_speed01() -> float:
	if target == null:
		return 0.0
	var s := absf(target.speed_kph)
	if other != null and is_instance_valid(other):
		s = maxf(s, absf(other.speed_kph))
	return clampf(s / 300.0, 0.0, 1.0)


var _dbg := 0


func follow_update(dt: float) -> void:
	if target == null:
		return
	if _dbg < 3:
		_dbg += 1
		print("[DUELCAM] other=", other, " p1=", target.global_position, " sep=", _separation(), " cam=", global_position, " focus=", _focus_pos())
	if other == null or not is_instance_valid(other):
		super(dt)
		return
	_dbg += 1
	if _dbg % 60 == 0 or (_dbg > 150 and _dbg < 160):
		print("[DUELCAM2] t=", _dbg, " cam=", global_position, " focus=", _focus_pos(), " desired=", _focus_pos() - _focus_fwd() * 8.0 + Vector3(0,4,0))
	var focus := _focus_pos()
	var fwd := _focus_fwd()
	var sep := _separation()
	var speed01 := _focus_speed01()
	var distance := lerpf(7.0, 9.0, speed01) + sep * 0.55
	var height := lerpf(3.2, 4.1, speed01) + sep * 0.22
	var desired := focus - fwd * distance + Vector3(0.0, height, 0.0)
	global_position = global_position.lerp(desired, 1.0 - exp(-4.2 * dt))
	_keep_camera_on_track()
	shake *= exp(-5.0 * dt)
	var total_shake := shake * 0.26 + pow(speed01, 2.4) * 0.010
	if Settings.get("camera_shake") != null and not bool(Settings.get("camera_shake")):
		total_shake = 0.0
		shake = 0.0
	if total_shake > 0.0005:
		global_position += Vector3(randf_range(-1, 1), randf_range(-0.6, 0.6), randf_range(-1, 1)) * total_shake
	look_at(focus + fwd * (5.5 + sep * 0.28) + Vector3(0.0, 0.95, 0.0), Vector3.UP)
	fov = lerpf(fov, 62.0 + speed01 * 7.0, 1.0 - exp(-4.0 * dt))
