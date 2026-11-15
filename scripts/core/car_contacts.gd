class_name CarContacts
extends RefCounted
## 车辆间碰撞解算：玩家-AI 与 AI-AI 的 OBB 接触分离、分离速度、掉速与弹开锁存。
## 从 main.gd 拆出：几何函数为纯静态，resolve() 读写宿主的 car/ais/track_path 等状态。

## 车辆碰撞尺寸：用 manifest 里每台车实测的 contact = [宽, 长]（米），
## 取代原来固定的 r=2.1 圆形碰撞（圆直径 4.2m 比车宽/车长都不匹配，侧向像一堵看不见的墙）。
static func half_extents(car_id: String) -> Vector2:
	var cars: Dictionary = GameData.car_manifest.get("cars", {})
	var entry: Dictionary = cars.get(car_id, {})
	var c: Array = entry.get("contact", [1.9, 4.4])
	var w := float(c[0]) if c.size() > 0 else 1.9
	var l := float(c[1]) if c.size() > 1 else 4.4
	return Vector2(clampf(w * 0.5, 0.80, 1.30), clampf(l * 0.5, 1.80, 2.90))


## 2D 带朝向矩形（OBB）SAT 求最小分离向量。
## 返回 {hit, normal(从 B 指向 A 的单位向量), depth, mtv(世界 xz)}。
static func obb_mtv(pos_a: Vector2, yaw_a: float, half_a: Vector2,
		pos_b: Vector2, yaw_b: float, half_b: Vector2) -> Dictionary:
	var out := {"hit": false, "normal": Vector2.ZERO, "depth": 0.0, "mtv": Vector2.ZERO}
	var ra := Vector2(cos(yaw_a), -sin(yaw_a))
	var fa := Vector2(sin(yaw_a), cos(yaw_a))
	var rb := Vector2(cos(yaw_b), -sin(yaw_b))
	var fb := Vector2(sin(yaw_b), cos(yaw_b))
	var axes: Array[Vector2] = [ra, fa, rb, fb]
	var d := pos_a - pos_b
	var best_depth := 1e30
	var best_axis := Vector2.ZERO
	for axis in axes:
		var proj_a := absf(ra.dot(axis)) * half_a.x + absf(fa.dot(axis)) * half_a.y
		var proj_b := absf(rb.dot(axis)) * half_b.x + absf(fb.dot(axis)) * half_b.y
		var dist := absf(d.dot(axis))
		var overlap := proj_a + proj_b - dist
		if overlap <= 0.0:
			return out
		if overlap < best_depth:
			best_depth = overlap
			best_axis = axis
	out["hit"] = true
	out["depth"] = best_depth
	var normal: Vector2 = best_axis if d.dot(best_axis) >= 0.0 else -best_axis
	out["normal"] = normal
	out["mtv"] = normal * best_depth
	return out


var _main: Node3D


func setup(main: Node3D) -> void:
	_main = main


func resolve() -> float:
	var car: Car = _main.car
	var ais: Array[AICar] = _main.ais
	var track_path: TrackPath = _main.track_path
	if car == null or track_path == null:
		return 0.0
	var player_half := half_extents(_main.current_car_id)
	var player_fwd := car.forward()
	var max_impact := 0.0
	for ai in ais:
		var ai_id := String(ai.spec.get("id", ""))
		var ai_half := half_extents(ai_id) if not ai_id.is_empty() else Vector2(0.95, 2.2)
		var hit := obb_mtv(
			Vector2(car.pos.x, car.pos.z), car.heading, player_half,
			Vector2(ai.pos.x, ai.pos.z), ai.heading, ai_half)
		if not hit["hit"]:
			continue
		var mtv: Vector2 = hit["mtv"]
		var normal: Vector2 = hit["normal"]
		var depth: float = hit["depth"]
		if depth < 0.0005:
			continue
		# ---- 接触解算：小步位置修正 + 接触分离速度，避免「闪现」和「粘上碰」----
		var n3 := Vector3(normal.x, 0.0, normal.y)
		var ai_fwd := Vector3(sin(ai.heading), 0.0, cos(ai.heading))
		var ai_vel := ai_fwd * ai.speed
		var rel := car.vel - ai_vel
		var vn := rel.dot(n3)  # <0：两车还在相互压；>0：正在分开

		# 位置修正每帧限幅，宁可多弹几帧也不瞬移（用户反馈「直接闪到前面去了」）。
		# 上限比旧版放宽：撞上后要较快脱离接触，否则两车会贴着磨蹭（「黏」）。
		var push := minf(depth * 0.75, 0.38)
		var desired_ai := -n3 * push
		var ai_got := Vector3.ZERO
		var frame := track_path.frame_at(ai.dist)
		if not frame.is_empty():
			var side: Vector3 = frame["side"]
			var tangent: Vector3 = frame["tangent"]
			var want_lat := desired_ai.x * side.x + desired_ai.z * side.z
			var want_along := desired_ai.x * tangent.x + desired_ai.z * tangent.z
			var prev_off := ai.offset
			var prev_dist := ai.dist
			var limit := maxf(float(frame.get("half_width", track_path.half_width)) - 1.4, 0.55)
			ai.offset = clampf(ai.offset + want_lat, -limit, limit)
			ai.dist = maxf(ai.dist + want_along, 0.0)
			var got_lat := ai.offset - prev_off
			var got_along := ai.dist - prev_dist
			ai_got = Vector3(side.x * got_lat + tangent.x * got_along, 0.0,
				side.z * got_lat + tangent.z * got_along)
		# AI 被护栏/边界夹住而没让出去的位移，只补一小部分给玩家（限幅，避免闪现）
		var unfulfilled := desired_ai - ai_got
		var car_push := n3 * push - unfulfilled
		var push_cap := push * 1.8
		if car_push.length() > push_cap and push_cap > 0.0001:
			car_push = car_push.normalized() * push_cap
		car.pos.x += car_push.x
		car.pos.z += car_push.z
		# 任何接触都给 AI 一个侧向弹开锁存：撞完先让开，不要下一帧又贴回玩家。
		if not frame.is_empty():
			var ai_side_v: Vector3 = frame["side"]
			ai.bump_lat = clampf(ai.bump_lat - n3.dot(ai_side_v) * minf(0.55 + depth, 1.4), -2.8, 2.8)
			ai.bump_timer = maxf(ai.bump_timer, 0.65)

		# 接触分离速度：低速轻碰也有 1.3m/s 的轻微弹开；高速对撞按 38% 反弹。
		# 单帧速度修正限幅，避免「闪一下窜出去」。
		var target_sep := maxf(1.3, -vn * 0.38)
		var vn_dv := clampf(target_sep - vn, 0.0, 3.0)
		if vn < target_sep:
			var car_share := 0.70
			var ai_share := 0.30
			car.vel += n3 * (vn_dv * car_share)
			var ai_new := ai_vel - n3 * (vn_dv * ai_share)
			ai.speed = clampf(ai_new.dot(ai_fwd), 0.0,
				maxf(ai.speed, ai_new.length()) + 5.0)
			var vf := car.vel.dot(player_fwd)
			if vf < -0.5:
				car.vel -= player_fwd * vf
		if vn < -1.2:
			max_impact = maxf(max_impact, -vn)
			_main.last_hit_pos = ((car.pos + ai.pos) * 0.5) + Vector3(0.0, 0.55, 0.0)
			_main.last_hit_active = true
		# ---- 真实碰撞反馈：撞一下 → 双方掉速 → AI 沿侧向弹开 0.9s ----
		var impact := -vn
		if impact > 0.8:
			# AI 按撞击强度掉速（撞得越狠掉得越多，最少也蹭掉一成）
			ai.speed = maxf(ai.speed * clampf(1.0 - impact * 0.045, 0.70, 1.0), 2.0)
			# 玩家正面撞上时前向速度也按冲量掉（侧面刮蹭不刹车）
			var frontness := absf(n3.dot(player_fwd))
			if frontness > 0.35:
				var fdrop := minf(impact * 0.30 * frontness, 6.0)
				var vf0 := car.vel.dot(player_fwd)
				if vf0 > 0.0:
					car.vel -= player_fwd * minf(fdrop, vf0)
			# AI 弹开冲量：沿赛道侧向被撞开，update_ai 里 0.9s 衰减回走线
			var ai_side: Vector3 = frame["side"]
			ai.bump_lat = clampf(-n3.dot(ai_side), -1.0, 1.0) * minf(1.2 + impact * 0.25, 2.8)
			ai.bump_timer = 0.9
		elif depth > 0.03 and _main.game_feel != null and _main.game_feel.has_method("on_scrape"):
			# 低速贴住/并排磨蹭：给少量火花，避免「撞了但没反馈」。
			_main.game_feel.on_scrape(
				clampf(-vn / 6.0 + depth * 0.4, 0.05, 0.6),
				((car.pos + ai.pos) * 0.5) + Vector3(0.0, 0.45, 0.0))

	# AI 互相分离：OBB 精确求最小分离向量。旧版只用赛道纵横矩形近似，
	# 两车斜着并排时会漏判出可见穿模；这里同时做位置、相对速度、弹开锁存。
	for i in ais.size():
		for j in range(i + 1, ais.size()):
			var a: AICar = ais[i]
			var b: AICar = ais[j]
			var half_a := half_extents(String(a.spec.get("id", "")))
			var half_b := half_extents(String(b.spec.get("id", "")))
			var hit := obb_mtv(
				Vector2(a.pos.x, a.pos.z), a.heading, half_a,
				Vector2(b.pos.x, b.pos.z), b.heading, half_b)
			if not hit["hit"]:
				continue
			var normal: Vector2 = hit["normal"]  # B → A
			var depth: float = hit["depth"]
			if depth < 0.0005:
				continue
			var frame := track_path.frame_at(a.dist)
			if frame.is_empty():
				continue
			var side: Vector3 = frame["side"]
			var tangent: Vector3 = frame["tangent"]
			var n3 := Vector3(normal.x, 0.0, normal.y)
			# 位置分离：A 沿 n3、B 沿 -n3，投影回 offset/dist 并限幅。
			var push := minf(depth * 0.70, 0.36)
			var limit_a := maxf(float(frame.get("half_width", track_path.half_width)) - 1.4, 0.55)
			var frame_b := track_path.frame_at(b.dist)
			var limit_b := limit_a
			if not frame_b.is_empty():
				limit_b = maxf(float(frame_b.get("half_width", track_path.half_width)) - 1.4, 0.55)
			a.offset = clampf(a.offset + n3.dot(side) * push, -limit_a, limit_a)
			a.dist = maxf(a.dist + n3.dot(tangent) * push, 0.0)
			b.offset = clampf(b.offset - n3.dot(side) * push, -limit_b, limit_b)
			b.dist = maxf(b.dist - n3.dot(tangent) * push, 0.0)
			# 分离速度：沿各自车头方向补一点相对速度，避免同速并排被“焊死”。
			var fwd_a := Vector3(sin(a.heading), 0.0, cos(a.heading))
			var fwd_b := Vector3(sin(b.heading), 0.0, cos(b.heading))
			var rel_vn := (fwd_a * a.speed - fwd_b * b.speed).dot(n3)
			var sep := maxf(0.9, -rel_vn * 0.25)
			var dv := clampf(sep - rel_vn, 0.0, 2.0)
			if dv > 0.0:
				a.speed = maxf(a.speed + dv * 0.5 * n3.dot(fwd_a), 0.0)
				b.speed = maxf(b.speed - dv * 0.5 * n3.dot(fwd_b), 0.0)
			# 接触掉速 + 弹开锁存（bump_lat 在 update_ai 里 0.8s 衰减）
			var scrape := clampf(depth * 0.06, 0.0, 0.15)
			a.speed *= 1.0 - scrape
			b.speed *= 1.0 - scrape
			var lateral_bump := n3.dot(side) * minf(0.6 + depth, 1.5)
			a.bump_lat = clampf(a.bump_lat + lateral_bump, -2.8, 2.8)
			b.bump_lat = clampf(b.bump_lat - lateral_bump, -2.8, 2.8)
			a.bump_timer = maxf(a.bump_timer, 0.8)
			b.bump_timer = maxf(b.bump_timer, 0.8)
			max_impact = maxf(max_impact, -rel_vn)
			if _main.game_feel != null and _main.game_feel.has_method("on_scrape"):
				_main.game_feel.on_scrape(
					clampf(-rel_vn / 8.0 + depth * 0.35, 0.04, 0.5),
					((a.pos + b.pos) * 0.5) + Vector3(0.0, 0.45, 0.0))
	return max_impact