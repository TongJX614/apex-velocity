extends Node
## 倒车/护栏脱困审计：撞护栏后按住 S（throttle=-1）应能倒出来。
## 用法：Godot --headless --path . res://tools/reverse_test.tscn

const DT := 1.0 / 120.0


func _ready() -> void:
	var spec: Dictionary = (GameData.cars_specs[0] as Dictionary).duplicate(true)
	for s in GameData.cars_specs:
		if String(s.get("id", "")) == "aventador_lp700":
			spec = (s as Dictionary).duplicate(true)
			break
	for track_id in ["coast", "magma"]:
		var def: Dictionary = GameData.track(track_id)
		if def.is_empty():
			continue
		var path := TrackPath.new()
		path.build_from_def(def, 2.0)
		print("[REV] === %s half=%.1f wall=%.2f ===" % [
			track_id, path.half_width, path.half_width + path.wall_margin])
		_run_case(path, spec, "wall_right", 1.0)
		_run_case(path, spec, "wall_left", -1.0)
		_run_case(path, spec, "open_road", 0.0)
	quit_after()


func quit_after() -> void:
	get_tree().quit(0)


func _make_car(path: TrackPath, spec: Dictionary) -> Car:
	var car := Car.new()
	car.setup(spec, path, 300.0, 0.0, Color.TRANSPARENT, {}, false)
	return car


func _run_case(path: TrackPath, spec: Dictionary, label: String, steer_dir: float) -> void:
	var car := _make_car(path, spec)
	var f := path.frame_at(300.0)
	car.pos = f["pos"] as Vector3
	var tng: Vector3 = f["tangent"]
	car.heading = atan2(tng.x, tng.z)
	var t := 0.0
	# 1) 油门 + 转向撞墙
	while t < 2.6:
		car.update_car(DT, {"steer": steer_dir, "throttle": 1.0, "handbrake": false,
			"nitro": false, "reverse_pressed": false})
		t += DT
	var info := path.nearest(car.pos, car.track_index)
	var lat0 := float(info.get("lateral", 0.0))
	print("[REV] %-10s 撞墙后 lateral=%.2f speed=%.1f wall=%s" % [
		label, lat0, car.speed_kph, str(car.wall_contact)])
	# 2) 松开所有键 0.5s，再按住 S 倒车 4s
	var coast_t := 0.0
	while coast_t < 0.5:
		car.update_car(DT, {"steer": 0.0, "throttle": 0.0, "handbrake": false,
			"nitro": false, "reverse_pressed": false})
		coast_t += DT
		t += DT
	var start_pos: Vector3 = car.pos
	var min_speed := 1.0e9
	var max_back := 0.0
	var stuck_frames := 0
	var sample := 0.0
	var elapsed := 0.0
	var dbg := 0
	while elapsed < 4.0:
		if dbg < 10:
			var pre := path.nearest(car.pos, car.track_index)
			var fw := car.forward()
			var sd: Vector3 = pre.get("side", Vector3.RIGHT)
			var tg: Vector3 = pre.get("tangent", Vector3.FORWARD)
			print("[REV]   %-10s PRE  lat=%.3f wall=%.2f fwd.side=%+.2f fwd.tan=%+.2f vel=%s hdg=%.2f braking=%s" % [
				label, float(pre.get("lateral", 0.0)), float(pre.get("half_width", 0.0)) + 0.55,
				fw.dot(sd), fw.dot(tg), str(car.vel), car.heading, str(car.braking)])
			dbg += 1
		car.update_car(DT, {"steer": 0.0, "throttle": -1.0, "handbrake": false,
			"nitro": false, "reverse_pressed": true})
		if dbg <= 10:
			print("[REV]   %-10s POST speedF=%.3f vel=%s pos-d=%.3f" % [
				label, car.speed_forward, str(car.vel), start_pos.distance_to(car.pos)])
		elapsed += DT
		sample += DT
		min_speed = minf(min_speed, car.speed_forward)
		max_back = maxf(max_back, start_pos.distance_to(car.pos))
		if car.speed_kph < 1.0:
			stuck_frames += 1
		if sample >= 0.5:
			sample = 0.0
			var inf := path.nearest(car.pos, car.track_index)
			print("[REV]   %-10s t=%.1f speedF=%6.2f lateral=%6.2f wall=%s moved=%.2f" % [
				label, elapsed, car.speed_forward, float(inf.get("lateral", 0.0)),
				str(car.wall_contact), start_pos.distance_to(car.pos)])
	# 3) 再踩油门前进 2s，确认没有卡死
	var fwd_start: Vector3 = car.pos
	var fwd_t := 0.0
	while fwd_t < 2.0:
		car.update_car(DT, {"steer": 0.0, "throttle": 1.0, "handbrake": false,
			"nitro": false, "reverse_pressed": false})
		fwd_t += DT
	print("[REV] %-10s 结论：倒车最大位移=%.2fm 倒车最低速度=%.2f 前进2s位移=%.2fm %s" % [
		label, max_back, min_speed, fwd_start.distance_to(car.pos),
		"OK" if max_back > 3.0 and fwd_start.distance_to(car.pos) > 3.0 else "!! 卡住"])
	car.free()
