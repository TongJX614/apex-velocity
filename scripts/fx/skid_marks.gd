class_name SkidMarks
extends MultiMeshInstance3D
## 玩家车漂移/重刹时在地面留下的实时胎印。
##
## 全部胎印共用一张 MultiMesh + 一张软边贴图，只占一个 draw call；
## 环形缓冲覆盖旧印，不做逐帧透明度更新，避免漂移时产生额外 CPU/GPU 开销。

const MAX_MARKS := 160
const EMIT_STEP := 0.28
const MARK_WIDTH := 0.42
const MARK_LENGTH := 0.70

var _next := 0
var _last_emit := Vector3(1.0e9, 0.0, 0.0)
var _mm: MultiMesh
var _tex: ImageTexture


func setup() -> void:
	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	var quad := QuadMesh.new()
	quad.size = Vector2(MARK_WIDTH, MARK_LENGTH)
	quad.material = _material()
	_mm.mesh = quad
	_mm.instance_count = MAX_MARKS
	var hidden := Transform3D(Basis().scaled(Vector3.ZERO), Vector3.ZERO)
	for i in MAX_MARKS:
		_mm.set_instance_transform(i, hidden)
	multimesh = _mm
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


## 主循环每帧调用；内部按行驶距离限流，避免高速时把环形缓冲瞬间刷空。
func emit_from_car(car: Car) -> void:
	if car == null:
		return
	if car.pos.distance_to(_last_emit) < EMIT_STEP:
		return
	_last_emit = car.pos
	var fwd := car.forward()
	var side := car.right()
	var base := Vector3(car.pos.x, car.pos.y + 0.032, car.pos.z) - fwd * 1.35
	var yaw := car.heading
	for lane: float in [-0.78, 0.78]:
		_push(base + side * lane, yaw)


func clear() -> void:
	if _mm == null:
		return
	var hidden := Transform3D(Basis().scaled(Vector3.ZERO), Vector3.ZERO)
	for i in MAX_MARKS:
		_mm.set_instance_transform(i, hidden)
	_next = 0
	_last_emit = Vector3(1.0e9, 0.0, 0.0)


func _push(pos: Vector3, yaw: float) -> void:
	# 先绕 X 放平，再绕 Y 对齐车头；印子压在路面上、位于标线下方。
	var basis := Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, -PI * 0.5)
	_mm.set_instance_transform(_next, Transform3D(basis, pos))
	_next = (_next + 1) % MAX_MARKS


func _material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_texture = _mark_texture()
	mat.albedo_color = Color(0.0, 0.0, 0.0, 0.62)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_OPAQUE_ONLY
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	return mat


func _mark_texture() -> ImageTexture:
	if _tex != null:
		return _tex
	var w := 32
	var h := 128
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in h:
		var t := float(y) / float(h - 1)
		var vfade := smoothstep(0.0, 0.10, t) * (1.0 - smoothstep(0.78, 1.0, t))
		for x in w:
			var dx := absf(float(x) - float(w - 1) * 0.5) / (float(w - 1) * 0.5)
			var edge := 1.0 - smoothstep(0.48, 1.0, dx)
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, vfade * edge))
	img.generate_mipmaps()
	_tex = ImageTexture.create_from_image(img)
	return _tex