class_name CarReflectionProbe
extends ReflectionProbe
## 跟随玩家车的环境反射探针：让车漆反射街道/霓虹/建筑，而不是只反射天空。
##
## 只拍环境层（车体在层 2、天气粒子在层 4，都被 cull_mask=1 排除），
## 每隔 3s 用 UPDATE_ALWAYS 渲染一帧再切回 UPDATE_ONCE，避免每帧 6 面重绘。
## top_level=true 让探头保持世界朝向，转弯时反射不会跟着车一起旋转。

const UPDATE_INTERVAL := 3.0
const HEIGHT := 1.0

var _timer := 0.0
var _hold := 0
var _captured := false


func setup() -> void:
	top_level = true
	box_projection = true
	interior = false
	enable_shadows = false
	cull_mask = 1
	max_distance = 160.0
	size = Vector3(16.0, 8.0, 16.0)
	update_mode = ReflectionProbe.UPDATE_ONCE


func _ready() -> void:
	_snap_to_follow()


func _process(dt: float) -> void:
	_snap_to_follow()
	if _hold > 0:
		_hold -= 1
		if _hold == 0:
			update_mode = ReflectionProbe.UPDATE_ONCE
			_captured = true
		return
	# 静止（起跑线/暂停/展厅）时环境不变，不重绘 cubemap。
	var follow := get_parent()
	if _captured and follow != null:
		var spd: Variant = follow.get("speed_kph")
		if spd != null and float(spd) < 3.0:
			return
	_timer += dt
	if _timer >= UPDATE_INTERVAL:
		_timer = 0.0
		update_mode = ReflectionProbe.UPDATE_ALWAYS
		_hold = 2


func _snap_to_follow() -> void:
	var follow := get_parent() as Node3D
	if follow != null and is_instance_valid(follow):
		global_position = follow.global_position + Vector3(0.0, HEIGHT, 0.0)
		global_rotation = Vector3.ZERO