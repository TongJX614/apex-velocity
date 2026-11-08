class_name CityWorld
extends Node
## 都会环线的城市地面：从 Blender 模型烘焙的建筑碰撞场。
##
## 数据（city_collision.bin）：
##   · SDF：每 0.1m 一档，到最近建筑轮廓的距离；0 = 在楼里
##   · paved 位图：柏油路 / 人行道 / 铺装广场，用来判定「是不是路」
##
## 城市是平的（路面顶面 y=0），所以这里只做平面碰撞：
## 车可以开进任何街道，只有房屋会把车推出去。

const DATA_PATH := "res://assets/thirdparty/city_ring/city_collision.bin"
const SDF_SCALE := 0.1
const PUSH_GAP := 0.06
## 卡进楼里（SDF=0，梯度失效）时的最大搜救半径（像素，约 120m）。
const ESCAPE_RINGS := 240

var loaded := false
var _blob := PackedByteArray()
var _n := 0
var _span := 1048.0
var _step := 0.51171875
var _sdf_len := 0
var _sdf_off := 32
var _paved_off := 0
var _paved_bits := 0


func load_collision(path: String = DATA_PATH) -> bool:
	loaded = false
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("CityWorld: cannot open %s" % path)
		return false
	var size := f.get_length()
	_blob = f.get_buffer(size)
	f.close()
	if _blob.size() < 32 or _blob.slice(0, 8).get_string_from_ascii() != "CITYCOL1":
		push_error("CityWorld: bad header in %s" % path)
		return false
	var version := _blob.decode_u32(8)
	_n = int(_blob.decode_u32(12))
	_span = _blob.decode_float(16)
	_step = _blob.decode_float(20)
	_sdf_len = int(_blob.decode_u32(24))
	_paved_bits = int(_blob.decode_u32(28)) * 8
	_sdf_off = 32
	_paved_off = _sdf_off + _sdf_len
	if version != 1 or _n <= 1 or _sdf_len != _n * _n \
			or _paved_bits != _n * _n or _blob.size() != _paved_off + _paved_bits / 8:
		push_error("CityWorld: corrupt collision data (%d bytes)" % size)
		return false
	loaded = true
	return true


func height_at(_x: float, _z: float) -> float:
	return 0.0


func normal_at(_x: float, _z: float) -> Vector3:
	return Vector3.UP


func depth_at(_x: float, _z: float) -> float:
	return 0.0


func zone_at(_x: float, _z: float) -> Dictionary:
	return {"id": "city", "cn": "都会环线", "en": "METRO RING"}


## 「路」= 柏油 + 人行道 + 铺装广场。3×3 邻域取或，
## 避免落在三角面光栅缝隙时突然变成草地。
func surface_at(x: float, z: float) -> String:
	if not loaded or not _in_grid(x, z):
		return "grass"
	var gx := int(floor((x + _span) / _step))
	var gy := int(floor((-z + _span) / _step))
	if _paved_near(gx, gy):
		return "road"
	return "grass"


func distance_at(x: float, z: float) -> float:
	if not loaded or not _in_grid(x, z):
		return 999.0
	var gx := clampf((x + _span) / _step - 0.5, 0.0, float(_n - 1))
	var gy := clampf((-z + _span) / _step - 0.5, 0.0, float(_n - 1))
	var x0 := int(floor(gx))
	var y0 := int(floor(gy))
	var x1 := mini(x0 + 1, _n - 1)
	var y1 := mini(y0 + 1, _n - 1)
	var fx := gx - float(x0)
	var fy := gy - float(y0)
	var a := lerpf(_sdf_px(x0, y0), _sdf_px(x1, y0), fx)
	var b := lerpf(_sdf_px(x0, y1), _sdf_px(x1, y1), fx)
	return lerpf(a, b, fy)


## 圆（车身）推出建筑。返回 {pos, hit, normal, depth}，和 OpenWorld.push_out 同形。
func push_out(x: float, z: float, radius: float, _y: float = 0.0) -> Dictionary:
	var out := {"pos": Vector2(x, z), "hit": false, "normal": Vector2.ZERO, "depth": 0.0}
	if not loaded:
		return out
	var px := x
	var pz := z
	var nx := 0.0
	var nz := 0.0
	var depth := 0.0
	var hit := false
	# 两遍：楼与楼贴得很近时，第一遍推出可能又压到隔壁楼。
	for _pass in 2:
		var d := distance_at(px, pz)
		if d >= radius:
			break
		var move := _escape_move(px, pz, radius, d)
		if move.length_squared() < 0.000001:
			break
		px += move.x
		pz += move.y
		nx += move.x
		nz += move.y
		depth += move.length()
		hit = true
	if not hit:
		return out
	px = clampf(px, -_span, _span)
	pz = clampf(pz, -_span, _span)
	var n := Vector2(nx, nz)
	out["pos"] = Vector2(px, pz)
	out["hit"] = true
	out["normal"] = n.normalized() if n.length_squared() > 0.000001 else Vector2.ZERO
	out["depth"] = depth
	return out


func _escape_move(px: float, pz: float, radius: float, d: float) -> Vector2:
	# 楼外：SDF 梯度就是「离楼最远」的方向，直接补足到车身半径。
	var probe := maxf(1.0, radius * 0.9)
	var dx := distance_at(px + probe, pz) - distance_at(px - probe, pz)
	var dz := distance_at(px, pz + probe) - distance_at(px, pz - probe)
	var g := Vector2(dx, dz)
	if g.length_squared() > 0.0001:
		return g.normalized() * (radius - d + PUSH_GAP)
	# 已经在楼体深处（整片 SDF=0）：向外搜最近的可容纳车身的点。
	return _spiral_escape(px, pz, radius)


func _spiral_escape(px: float, pz: float, radius: float) -> Vector2:
	var best := Vector2.ZERO
	var best_d := -1.0
	for ring in range(2, ESCAPE_RINGS + 1, 2):
		var rr := float(ring) * _step
		if rr > 120.0:
			break
		best_d = -1.0
		for k in 24:
			var ang := TAU * float(k) / 24.0
			var qx := px + cos(ang) * rr
			var qz := pz + sin(ang) * rr
			var dq := distance_at(qx, qz)
			if dq >= radius and dq > best_d:
				best_d = dq
				best = Vector2(qx - px, qz - pz)
		if best_d >= 0.0:
			return best
	return Vector2.ZERO


func _in_grid(x: float, z: float) -> bool:
	return x >= -_span and x <= _span and z >= -_span and z <= _span


func _sdf_px(ix: int, iy: int) -> float:
	return float(_blob[_sdf_off + iy * _n + ix]) * SDF_SCALE


func _paved_at(ix: int, iy: int) -> bool:
	if ix < 0 or iy < 0 or ix >= _n or iy >= _n:
		return false
	var idx := iy * _n + ix
	return (_blob[_paved_off + (idx >> 3)] & (1 << (idx & 7))) != 0


func _paved_near(ix: int, iy: int) -> bool:
	for oy in range(-1, 2):
		for ox in range(-1, 2):
			if _paved_at(ix + ox, iy + oy):
				return true
	return false
