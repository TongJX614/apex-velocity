class_name ConeField
extends Node3D
## 漂移练习场的锥桶世界：橙身+白带锥桶（共享网格/材质，每锥一对 MeshInstance），
## 用车体 OBB 与锥桶小方盒做 SAT 判定撞倒（只倒不挡车），倒地后保持直到扶正或重摆。

const CONE_HALF := Vector2(0.35, 0.35)
const BODY_CENTER_Y := 0.36
const BAND_LOCAL_Y := 0.08
const FALL_CENTER_Y := 0.30

var positions: Array = []
var knocked: Array = []

var _bodies: Array = []
var _bands: Array = []
var _fallen: Array = []

static var _body_mesh: CylinderMesh = null
static var _band_mesh: CylinderMesh = null


func _ready() -> void:
	_ensure_meshes()


static func _ensure_meshes() -> void:
	if _body_mesh == null:
		_body_mesh = _cone_mesh(0.05, 0.30, 0.72, Color(0.92, 0.28, 0.04), 0.55)
		_band_mesh = _cone_mesh(0.17, 0.21, 0.12, Color(0.95, 0.95, 0.93), 0.5)


func set_layout(pts: Array) -> void:
	positions = pts.duplicate()
	knocked.resize(positions.size())
	_fallen.resize(positions.size())
	for i in positions.size():
		knocked[i] = false
		_fallen[i] = Transform3D()
	_rebuild()


func get_layout() -> Array:
	return positions.duplicate()


func add_cone(p: Vector2) -> void:
	if positions.size() >= ConeStore.MAX_CONES:
		return
	positions.append(p)
	knocked.append(false)
	_fallen.append(Transform3D())
	_rebuild()


func remove_cone(index: int) -> void:
	if index < 0 or index >= positions.size():
		return
	positions.remove_at(index)
	knocked.remove_at(index)
	_fallen.remove_at(index)
	_rebuild()


func knocked_count() -> int:
	var n := 0
	for k in knocked:
		if k:
			n += 1
	return n


func stand_all() -> void:
	for i in knocked.size():
		knocked[i] = false
		_fallen[i] = Transform3D()
	_apply_all()


## 返回本次调用新撞倒的锥桶数。cone_pos/cone_yaw/half 为玩家车的平面位置、朝向与半尺寸。
func update_knock(cone_pos: Vector2, cone_yaw: float, half: Vector2) -> int:
	var hit := 0
	for i in positions.size():
		if knocked[i]:
			continue
		var res: Dictionary = CarContacts.obb_mtv(cone_pos, cone_yaw, half, positions[i], 0.0, CONE_HALF)
		if not bool(res.get("hit", false)):
			continue
		knocked[i] = true
		_fallen[i] = _fallen_transform(cone_yaw)
		_set_instance(i)
		hit += 1
	return hit


func _fallen_transform(yaw: float) -> Transform3D:
	var fwd := Vector3(sin(yaw), 0.0, cos(yaw))
	var axis := Vector3(-fwd.z, 0.0, fwd.x)
	var basis := Basis(axis, deg_to_rad(82.0))
	return Transform3D(basis, fwd * 0.45 + Vector3(0.0, FALL_CENTER_Y, 0.0))


func _rebuild() -> void:
	_ensure_meshes()
	for n in _bodies:
		if is_instance_valid(n):
			n.queue_free()
	for n in _bands:
		if is_instance_valid(n):
			n.queue_free()
	_bodies.clear()
	_bands.clear()
	for i in positions.size():
		var body := MeshInstance3D.new()
		body.mesh = _body_mesh
		body.name = "Cone%d" % i
		add_child(body)
		var band := MeshInstance3D.new()
		band.mesh = _band_mesh
		band.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(band)
		_bodies.append(body)
		_bands.append(band)
	_apply_all()


func _apply_all() -> void:
	for i in positions.size():
		_set_instance(i)


func _set_instance(i: int) -> void:
	if i >= _bodies.size() or not is_instance_valid(_bodies[i]):
		return
	var p: Vector2 = positions[i]
	var base := Transform3D(Basis.IDENTITY, Vector3(p.x, BODY_CENTER_Y, p.y))
	if knocked[i]:
		var f: Transform3D = _fallen[i]
		base = Transform3D(f.basis, Vector3(p.x, 0.0, p.y) + f.origin)
	_bodies[i].transform = base
	_bands[i].transform = base * Transform3D(Basis.IDENTITY, Vector3(0.0, BAND_LOCAL_Y, 0.0))


static func _cone_mesh(top_r: float, bottom_r: float, height: float, albedo: Color, rough: float) -> CylinderMesh:
	var m := CylinderMesh.new()
	m.top_radius = top_r
	m.bottom_radius = bottom_r
	m.height = height
	m.radial_segments = 12
	m.rings = 2
	var mat := StandardMaterial3D.new()
	mat.albedo_color = albedo
	mat.roughness = rough
	m.material = mat
	return m
