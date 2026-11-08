class_name TrackPath
extends RefCounted
## Engine-side spline representation of a legacy GP circuit.
##
## The legacy game defines a circuit as a list of 2D control points ([x, z]) plus
## a width. This class expands that into a closed Catmull-Rom centreline with
## tangents/sides/curvature, and offers the same queries the legacy physics used:
## frame_at(distance) for spawns and nearest(pos) for the barrier / offroad test.

const UP := Vector3.UP

var id := ""
var display_name := ""
var width := 20.0
var half_width := 10.0
## 每控制点宽度（实数城市赛道用：同一条路不同路段宽度不同）。
## 为空则整条赛道用 width。
var widths := PackedFloat32Array()
## 采样点半宽（由控制点宽度线性插值）。
var half_widths := PackedFloat32Array()
## 物理墙相对白线的额外余量：wall = 半宽 + wall_margin。
## 常规程序化赛道留 0.55（护栏在白线外），城市实景路把车心限制在真实沥青内。
var wall_margin := 0.55
var offroad_margin := 0.05
var samples := PackedVector3Array()
var tangents := PackedVector3Array()
var sides := PackedVector3Array()
var curvatures := PackedFloat32Array()
var accumulated := PackedFloat32Array()
var total_length := 0.0
var target_step := 2.0


func build_from_def(def: Dictionary, spacing: float = 2.0) -> void:
	id = String(def.get("id", ""))
	display_name = String(def.get("name", id))
	width = float(def.get("width", 20.0))
	half_width = width * 0.5
	wall_margin = float(def.get("wallMargin", 0.55))
	offroad_margin = float(def.get("offroadMargin", 0.05))
	target_step = maxf(0.5, spacing)

	var controls: Array[Vector2] = []
	for p in def.get("points", []):
		if typeof(p) == TYPE_ARRAY and p.size() >= 2:
			controls.append(Vector2(float(p[0]), float(p[1])))
	if controls.size() < 4:
		push_error("TrackPath[%s]: need at least 4 control points, got %d" % [id, controls.size()])
		return

	var n := controls.size()
	widths.clear()
	var raw_widths: Array = def.get("widths", [])
	if raw_widths.size() == n:
		for w in raw_widths:
			widths.append(maxf(float(w), 1.0))
	else:
		widths.resize(n)
		widths.fill(width)
	var seg_of_sample := PackedInt32Array()
	var t_of_sample := PackedFloat32Array()
	var raw := PackedVector3Array()
	for i in n:
		var p0 := controls[(i - 1 + n) % n]
		var p1 := controls[i]
		var p2 := controls[(i + 1) % n]
		var p3 := controls[(i + 2) % n]
		var steps := clampi(int(ceil(p1.distance_to(p2) / target_step)), 4, 64)
		for k in steps:
			var t := float(k) / float(steps)
			var v := _catmull(p0, p1, p2, p3, t)
			raw.append(Vector3(v.x, 0.0, v.y))
			seg_of_sample.append(i)
			t_of_sample.append(t)
	samples = raw
	_recompute_frames()
	half_widths.resize(samples.size())
	var hw_sum := 0.0
	for j in samples.size():
		var i := seg_of_sample[j]
		var hw := lerpf(widths[i], widths[(i + 1) % n], t_of_sample[j]) * 0.5
		half_widths[j] = hw
		hw_sum += hw
	if not samples.is_empty():
		half_width = hw_sum / float(samples.size())


func _recompute_frames() -> void:
	var m := samples.size()
	if m < 4:
		return
	tangents.resize(m)
	sides.resize(m)
	curvatures.resize(m)
	accumulated.resize(m)
	for i in m:
		var prev := samples[(i - 1 + m) % m]
		var next := samples[(i + 1) % m]
		tangents[i] = (next - prev).normalized()
		if tangents[i].length_squared() < 0.0001:
			tangents[i] = Vector3.FORWARD
		sides[i] = Vector3(-tangents[i].z, 0.0, tangents[i].x)
	accumulated[0] = 0.0
	for i in range(1, m):
		accumulated[i] = accumulated[i - 1] + samples[i - 1].distance_to(samples[i])
	total_length = accumulated[m - 1] + samples[m - 1].distance_to(samples[0])
	var avg_step := total_length / float(m)
	for i in m:
		var a := tangents[(i - 1 + m) % m]
		var b := tangents[(i + 1) % m]
		var cross_y := a.z * b.x - a.x * b.z
		curvatures[i] = cross_y / maxf(avg_step * 2.0, 0.001)


## Returns {pos, tangent, side, index, dist} at an arbitrary distance along the loop.
func frame_at(dist: float) -> Dictionary:
	var m := samples.size()
	if m == 0:
		return {}
	var d := fposmod(dist, maxf(total_length, 0.001))
	var idx := _index_for_distance(d)
	var nxt := (idx + 1) % m
	var span := accumulated[nxt] - accumulated[idx]
	if nxt == 0:
		span += total_length
	var t := 0.0 if absf(span) < 0.0001 else clampf((d - accumulated[idx]) / span, 0.0, 1.0)
	var pos := samples[idx].lerp(samples[nxt], t)
	var tangent := tangents[idx].lerp(tangents[nxt], t).normalized()
	var hw := half_width if half_widths.is_empty() else lerpf(half_widths[idx], half_widths[nxt], t)
	return {
		"pos": Vector3(pos.x, 0.0, pos.z),
		"tangent": tangent,
		"side": Vector3(-tangent.z, 0.0, tangent.x),
		"index": idx,
		"dist": d,
		"half_width": hw,
		"curvature": curvatures[idx],
	}


## Local nearest-centreline query. `hint` is the previous sample index; the search
## window is small so a 1-2 km circuit costs almost nothing per physics tick.
func nearest(pos: Vector3, hint: int = -1) -> Dictionary:
	var m := samples.size()
	if m == 0:
		return {}
	var best := 0
	var best_d := INF
	if hint < 0:
		for i in m:
			var d := Vector2(samples[i].x - pos.x, samples[i].z - pos.z).length_squared()
			if d < best_d:
				best_d = d
				best = i
	else:
		var window := 45
		for k in range(-window, window + 1):
			var i := posmod(hint + k, m)
			var d := Vector2(samples[i].x - pos.x, samples[i].z - pos.z).length_squared()
			if d < best_d:
				best_d = d
				best = i
	var tangent := tangents[best]
	var side := sides[best]
	var delta := pos - samples[best]
	var lateral := delta.dot(side)
	var along := delta.dot(tangent)
	return {
		"index": best,
		"dist": accumulated[best] + along,
		"lateral": lateral,
		"tangent": tangent,
		"side": side,
		"half_width": half_width if half_widths.is_empty() else half_widths[best],
		"curvature": curvatures[best],
		"pos": samples[best],
	}


## Largest |curvature| between dist+skip and dist+skip+meters (legacy AI uses this).
func max_curvature_ahead(dist: float, meters: float, skip: float = 0.0) -> float:
	var m := samples.size()
	if m == 0 or total_length <= 0.0:
		return 0.0
	var start := int(fposmod(dist + skip, total_length) / total_length * float(m)) % m
	var steps := maxi(2, int(meters / maxf(total_length / float(m), 0.001)))
	var peak := 0.0
	for k in range(1, steps + 1, 3):
		var c := absf(curvatures[(start + k) % m])
		if c > peak:
			peak = c
	return peak


func side_sign_at(dist: float) -> float:
	var m := samples.size()
	if m == 0 or total_length <= 0.0:
		return 1.0
	var i := int(fposmod(dist, total_length) / total_length * float(m)) % m
	var c := curvatures[i]
	return 1.0 if c >= 0.0 else -1.0


func half_width_at_index(i: int) -> float:
	if half_widths.is_empty():
		return half_width
	return half_widths[posmod(i, half_widths.size())]


func half_width_at_dist(dist: float) -> float:
	if half_widths.is_empty() or samples.is_empty():
		return half_width
	var m := samples.size()
	var d := fposmod(dist, maxf(total_length, 0.001))
	var idx := _index_for_distance(d)
	var nxt := (idx + 1) % m
	var span := accumulated[nxt] - accumulated[idx]
	if nxt == 0:
		span += total_length
	var t := 0.0 if absf(span) < 0.0001 else clampf((d - accumulated[idx]) / span, 0.0, 1.0)
	return lerpf(half_widths[idx], half_widths[nxt], t)


## 最长直道：{start_dist, center_dist, length}。
## 场馆（看台/维修区/大屏）都围绕这条直道布置，海岸地面也需要它来
## 保证「场馆区两侧都是陆地」，所以抽到路径类里共用。
func main_straight() -> Dictionary:
	var m := samples.size()
	var best_i := 0
	var best_score := 0
	for i in range(0, m, 3):
		var t0 := tangents[i]
		var ok := 0
		for k in range(1, 90):
			var idx := (i + k) % m
			if t0.dot(tangents[idx]) < 0.982:
				break
			ok = k
		if ok > best_score:
			best_score = ok
			best_i = i
	var sample_len := total_length / float(maxi(m, 1))
	var center_index := (best_i + best_score / 2) % m
	return {
		"start_dist": accumulated[best_i],
		"center_dist": accumulated[center_index],
		"length": float(best_score) * sample_len,
	}


## 场馆保护区（起跑主直道，含前后余量）：
## {center_dist, half_len, lo, hi}。lo/hi 允许绕圈（hi 可能小于 lo）。
func venue_span(margin: float = 46.0) -> Dictionary:
	var straight := main_straight()
	var center := float(straight.get("center_dist", 0.0))
	var half_len := float(straight.get("length", 0.0)) * 0.5 + margin
	var lo := center - half_len
	var hi := center + half_len
	return {
		"center_dist": center,
		"half_len": half_len,
		"lo": lo,
		"hi": hi,
		"straight": straight,
	}


func _index_for_distance(d: float) -> int:
	var lo := 0
	var hi := samples.size() - 1
	while lo < hi:
		var mid := int((lo + hi + 1) / 2)
		if accumulated[mid] <= d:
			lo = mid
		else:
			hi = mid - 1
	return lo


static func _catmull(p0: Vector2, p1: Vector2, p2: Vector2, p3: Vector2, t: float) -> Vector2:
	var t2 := t * t
	var t3 := t2 * t
	return 0.5 * (
		(2.0 * p1)
		+ (-p0 + p2) * t
		+ (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2
		+ (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3
	)
