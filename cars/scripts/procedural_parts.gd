class_name ProceduralParts
extends RefCounted
## 程序化车辆改装件（弃用旧版 GLB parts）：
##   · 轮毂 5 种设计（由 garage.json 的 wheel_styles id 映射）
##   · 轮胎 3 种（街胎/半热熔/热熔，wet 归入半热熔）
##   · 尾翼 3 种（GT 大尾翼/鸭尾/无）
## 全部按 wheelRadius / 原厂轮距生成，挂到原厂 Wheel_（转向/静态）与 Spin_Wheel_（滚转）节点上。

const WHEEL_STYLE_MAP := {
	"split5": "split5", "dish6": "dish6", "turbine": "turbine",
	"mesh": "mesh", "aero": "aero", "star5": "star5",
	"wire": "wire", "deepdish": "deepdish", "factory": "mesh",
}
const TIRE_STYLE_MAP := {
	"street": "street", "semi": "semi", "race": "race", "wet": "semi",
}
const WING_STYLE_MAP := {
	"gt": "gt", "swan": "gt", "storm": "gt", "blade": "duck",
	"duck": "duck", "none": "none", "stock": "none",
}

static var _mat_rim: StandardMaterial3D
static var _mat_rim_bright: StandardMaterial3D
static var _mat_tire: StandardMaterial3D
static var _mat_tire_wall: StandardMaterial3D
static var _mat_white: StandardMaterial3D
static var _mat_brake: StandardMaterial3D
static var _mat_carbon: StandardMaterial3D
static var _mat_accent: StandardMaterial3D
static var _mesh_cache: Dictionary = {}


# ---------------------------------------------------------------------------
# 材质
# ---------------------------------------------------------------------------
static func _materials(rim_color: Color, caliper_color: Color, accent: Color) -> void:
	_mat_tire = StandardMaterial3D.new()
	_mat_tire.albedo_color = Color(0.018, 0.018, 0.02)
	_mat_tire.roughness = 0.94
	_mat_tire.metallic = 0.0

	_mat_tire_wall = StandardMaterial3D.new()
	_mat_tire_wall.albedo_color = Color(0.035, 0.035, 0.04)
	_mat_tire_wall.roughness = 0.86

	_mat_white = StandardMaterial3D.new()
	_mat_white.albedo_color = Color(0.82, 0.83, 0.85)
	_mat_white.roughness = 0.55

	_mat_rim = StandardMaterial3D.new()
	_mat_rim.albedo_color = rim_color
	_mat_rim.metallic = 0.92
	_mat_rim.roughness = 0.24

	_mat_rim_bright = StandardMaterial3D.new()
	_mat_rim_bright.albedo_color = rim_color.lightened(0.18)
	_mat_rim_bright.metallic = 1.0
	_mat_rim_bright.roughness = 0.12

	_mat_brake = StandardMaterial3D.new()
	_mat_brake.albedo_color = Color(0.30, 0.31, 0.33)
	_mat_brake.metallic = 0.85
	_mat_brake.roughness = 0.38

	_mat_carbon = StandardMaterial3D.new()
	_mat_carbon.albedo_color = Color(0.035, 0.037, 0.042)
	_mat_carbon.metallic = 0.25
	_mat_carbon.roughness = 0.32

	_mat_accent = StandardMaterial3D.new()
	_mat_accent.albedo_color = accent if accent.a > 0.001 else caliper_color
	_mat_accent.metallic = 0.3
	_mat_accent.roughness = 0.35


static func _add_mesh(parent: Node3D, mesh: Mesh, mat: Material, xform: Transform3D) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.transform = xform
	parent.add_child(mi)
	return mi


static func _cyl(radius: float, height: float, segs: int = 28) -> CylinderMesh:
	var m := CylinderMesh.new()
	m.top_radius = radius
	m.bottom_radius = radius
	m.height = height
	m.radial_segments = segs
	m.rings = 1
	return m


static func _axis_x(xform: Transform3D) -> Transform3D:
	return xform * Transform3D(Basis(Vector3.BACK, PI * 0.5), Vector3.ZERO)


# ---------------------------------------------------------------------------
# 轮毂 + 轮胎（挂 Spin_Wheel_XX，绕 X 滚转）
# ---------------------------------------------------------------------------
static func build_wheel(wheel_id: String, tire_id: String, radius: float, width: float,
		rim_color: Color, caliper_color: Color, accent: Color) -> Node3D:
	_materials(rim_color, caliper_color, accent)
	var root := Node3D.new()
	root.name = "ProceduralWheel"
	var style := String(WHEEL_STYLE_MAP.get(wheel_id, "mesh"))
	var tire_style := String(TIRE_STYLE_MAP.get(tire_id, "street"))

	var r := radius * 0.985
	var half_w := maxf(width, radius * 0.62) * 0.5
	var tire_w := half_w * 2.0 * (1.02 if tire_style == "race" else 1.0)

	# 胎体（圆环）+ 两侧胎壁 + 胎面
	var torus := TorusMesh.new()
	torus.inner_radius = r * 0.70
	torus.outer_radius = r
	torus.rings = 20
	torus.ring_segments = 30
	_add_mesh(root, torus, _mat_tire, _axis_x(Transform3D(Basis(), Vector3.ZERO)))
	# 胎壁做成圆环（不要实心圆盘，否则会挡住轮辋辐条）
	var wall := TorusMesh.new()
	wall.inner_radius = r * 0.69
	wall.outer_radius = r * 0.80
	wall.rings = 8
	wall.ring_segments = 28
	for sx in [-1.0, 1.0]:
		_add_mesh(root, wall, _mat_tire_wall,
			_axis_x(Transform3D(Basis(), Vector3(sx * tire_w * 0.35, 0, 0))))
	# 胎面块（street/semi 有，race 光头）
	var tread_count := 20 if tire_style == "street" else (14 if tire_style == "semi" else 0)
	var tread_w := 0.055 if tire_style == "street" else 0.10
	for i in tread_count:
		var ang := TAU * float(i) / float(tread_count)
		var pivot := Node3D.new()
		pivot.rotation.x = ang
		root.add_child(pivot)
		var block := BoxMesh.new()
		block.size = Vector3(tire_w * 0.88, r * 0.16, tread_w)
		_add_mesh(pivot, block, _mat_tire, Transform3D(Basis(), Vector3(0, r * 0.90, 0)))
	# 胎壁白字/白圈
	if tire_style == "race":
		var ring := TorusMesh.new()
		ring.inner_radius = r * 0.73
		ring.outer_radius = r * 0.79
		ring.rings = 12
		ring.ring_segments = 28
		for sx in [-1.0, 1.0]:
			_add_mesh(root, ring, _mat_white, _axis_x(Transform3D(Basis(), Vector3(sx * tire_w * 0.40, 0, 0))))
	elif tire_style == "semi":
		for i in 6:
			var ang := TAU * float(i) / 6.0 + 0.1
			var pivot := Node3D.new()
			pivot.rotation.x = ang
			root.add_child(pivot)
			var block := BoxMesh.new()
			block.size = Vector3(tire_w * 0.06, r * 0.09, 0.03)
			_add_mesh(pivot, block, _mat_white, Transform3D(Basis(), Vector3(0, r * 0.84, 0)))

	# 轮辋（只保留外圈与辐条，不做实心圆柱，否则会挡住辐条）
	var rim_r := r * 0.72
	# 外圈抛边
	var lip := TorusMesh.new()
	lip.inner_radius = rim_r * 0.94
	lip.outer_radius = rim_r * 1.04
	lip.rings = 10
	lip.ring_segments = 30
	for sx in [-1.0, 1.0]:
		_add_mesh(root, lip, _mat_rim_bright, _axis_x(Transform3D(Basis(), Vector3(sx * tire_w * 0.42, 0, 0))))

	# 辐条设计
	var spokes := 5
	var spoke_w := 0.085
	var dish := 0.0
	match style:
		"split5":
			spokes = 5
			spoke_w = 0.11
		"dish6":
			spokes = 6
			spoke_w = 0.13
			dish = 0.18
		"turbine":
			spokes = 12
			spoke_w = 0.055
		"mesh":
			spokes = 16
			spoke_w = 0.035
		"aero":
			spokes = 5
			spoke_w = 0.19
		"star5":
			spokes = 5
			spoke_w = 0.15
		"wire":
			spokes = 20
			spoke_w = 0.022
		"deepdish":
			spokes = 6
			spoke_w = 0.10
			dish = 0.30
	for i in spokes:
		var ang := TAU * float(i) / float(spokes)
		if style == "split5":
			# 双辐（每根分叉成两根）
			for off in [-0.055, 0.055]:
				var pivot := Node3D.new()
				pivot.rotation.x = ang + off
				root.add_child(pivot)
				var spoke := BoxMesh.new()
				spoke.size = Vector3(tire_w * 0.46, rim_r * 0.78, spoke_w * 0.55)
				_add_mesh(pivot, spoke, _mat_rim, Transform3D(Basis(), Vector3(0, rim_r * 0.46, 0)))
			continue
		var pivot := Node3D.new()
		pivot.rotation.x = ang
		root.add_child(pivot)
		var spoke := BoxMesh.new()
		spoke.size = Vector3(tire_w * (0.52 if style == "aero" else 0.42), rim_r * 0.84, spoke_w)
		_add_mesh(pivot, spoke, _mat_rim_bright if style == "star5" else _mat_rim,
			Transform3D(Basis(), Vector3(0, rim_r * 0.46, 0)))
	# 气动盘
	if style == "aero":
		_add_mesh(root, _cyl(rim_r * 0.90, tire_w * 0.18, 30), _mat_rim, _axis_x(Transform3D(Basis(), Vector3(-tire_w * 0.18, 0, 0))))
	# 轮毂盖 + 中心螺丝
	_add_mesh(root, _cyl(rim_r * 0.20, tire_w * 1.02, 20), _mat_rim_bright, _axis_x(Transform3D(Basis(), Vector3.ZERO)))
	for sx in [-1.0, 1.0]:
		_add_mesh(root, _cyl(rim_r * 0.10, 0.012, 16), _mat_accent, _axis_x(Transform3D(Basis(), Vector3(sx * tire_w * 0.53, 0, 0))))
	return root


## 制动盘 + 卡钳（挂 Wheel_XX 静态节点，不随轮子滚转）
static func build_brake(radius: float, width: float, caliper_color: Color) -> Node3D:
	_materials(Color(0.6, 0.6, 0.6), caliper_color, caliper_color)
	var root := Node3D.new()
	root.name = "ProceduralBrake"
	_add_mesh(root, _cyl(radius * 0.80, 0.028, 30), _mat_brake, _axis_x(Transform3D(Basis(), Vector3.ZERO)))
	var caliper := BoxMesh.new()
	caliper.size = Vector3(maxf(width * 0.28, 0.06), radius * 0.34, radius * 0.16)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = caliper_color
	mat.metallic = 0.35
	mat.roughness = 0.35
	_add_mesh(root, caliper, mat, Transform3D(Basis(), Vector3(0.0, radius * 0.66, 0.0)))
	return root


# ---------------------------------------------------------------------------
# 尾翼（挂每台车现成 WingMount）
# ---------------------------------------------------------------------------
static func build_wing(wing_id: String, width: float, car_length: float) -> Node3D:
	_materials(Color(0.6, 0.6, 0.6), Color(0.6, 0.6, 0.6), Color(0.6, 0.6, 0.6))
	var style := String(WING_STYLE_MAP.get(wing_id, "none"))
	var root := Node3D.new()
	root.name = "ProceduralWing"
	if style == "none":
		return root
	var w := clampf(width * 0.82, 1.10, 2.05)
	if style == "duck":
		var lip := BoxMesh.new()
		lip.size = Vector3(w, 0.05, 0.20)
		var xf := Transform3D(Basis(Vector3.RIGHT, -0.10), Vector3(0, 0.03, -0.04))
		_add_mesh(root, lip, _mat_carbon, xf)
		var edge := BoxMesh.new()
		edge.size = Vector3(w, 0.012, 0.02)
		_add_mesh(root, edge, _mat_accent, Transform3D(Basis(Vector3.RIGHT, -0.10), Vector3(0, 0.058, -0.135)))
		return root
	# GT 大尾翼：主翼 + 端板 + 双立柱
	var main_wing := BoxMesh.new()
	main_wing.size = Vector3(w, 0.035, 0.34)
	# 主翼直接坐在基座上方，立柱从基座顶到翼面，避免看起来悬空
	for sx in [-1.0, 1.0]:
		_add_mesh(root, main_wing, _mat_carbon,
			Transform3D(Basis(Vector3.RIGHT, sx * 0.10), Vector3(0, 0.24, -0.04)))
	var flap := BoxMesh.new()
	flap.size = Vector3(w, 0.022, 0.16)
	_add_mesh(root, flap, _mat_carbon, Transform3D(Basis(Vector3.RIGHT, 0.24), Vector3(0, 0.30, -0.16)))
	for sx in [-1.0, 1.0]:
		var plate := BoxMesh.new()
		plate.size = Vector3(0.025, 0.22, 0.44)
		_add_mesh(root, plate, _mat_carbon,
			Transform3D(Basis(), Vector3(sx * w * 0.5, 0.19, -0.06)))
	for sx in [-1.0, 1.0]:
		var pylon := BoxMesh.new()
		pylon.size = Vector3(0.06, 0.22, 0.16)
		_add_mesh(root, pylon, _mat_carbon,
			Transform3D(Basis(Vector3.RIGHT, -0.10), Vector3(sx * w * 0.26, 0.11, 0.0)))
	var accent := BoxMesh.new()
	accent.size = Vector3(w * 0.92, 0.012, 0.03)
	_add_mesh(root, accent, _mat_accent, Transform3D(Basis(), Vector3(0, 0.26, -0.20)))
	return root
