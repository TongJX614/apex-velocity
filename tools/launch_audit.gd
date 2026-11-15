extends Node
## 起步/加速离线审计：同一套 Car 物理在指定赛道上模拟全油门起步，
## 逐车对比 Metro（城市碰撞模式）与 Coast（常规赛道模式）的加速表现。
## 用法：Godot --headless --path . res://tools/launch_audit.tscn
## 注意必须走场景（自动加载 GameData/Settings），--script 模式没有 autoload。

const TRACKS := "res://data/tracks.json"
const CARS := "res://data/cars.json"
const HZ := 120.0
const DT := 1.0 / HZ


func _ready() -> void:
	var tracks := _read_json(TRACKS).get("tracks", []) as Array
	var specs := _read_json(CARS).get("specs", []) as Array
	var metro := _track_def(tracks, "metro")
	var coast := _track_def(tracks, "coast")
	if metro.is_empty() or coast.is_empty():
		push_error("launch_audit: missing track defs")
		get_tree().quit(1)
		return
	var city := CityWorld.new()
	city.load_collision()
	var rows: Array = []
	for spec in specs:
		var id := String(spec.get("id", ""))
		var m := _run_car(spec, metro, city, true)
		var c := _run_car(spec, coast, null, false)
		rows.append({"id": id, "name": String(spec.get("name", id)), "metro": m, "coast": c})
	rows.sort_custom(func(x, y): return float(x["metro"]["v6"]) < float(y["metro"]["v6"]))
	print("[LAUNCH] metro v1/v3/v6 kph, dist6, offroad%, block% | coast v1/v3/v6 | ratio")
	for r in rows:
		var m: Dictionary = r["metro"]
		var c: Dictionary = r["coast"]
		var ratio := float(m["v6"]) / maxf(float(c["v6"]), 0.1)
		print("[LAUNCH] %-24s m %6.1f %6.1f %6.1f d=%5.1f off=%3.0f%% blk=%3.0f%% | c %6.1f %6.1f %6.1f | %.2f" % [
			r["id"], m["v1"], m["v3"], m["v6"], m["dist6"],
			m["offroad"] * 100.0, m["blocked"] * 100.0, c["v1"], c["v3"], c["v6"], ratio])
	var bad := rows.filter(func(r): return float(r["metro"]["v6"]) < 25.0)
	print("[LAUNCH] problem cars (metro v6 < 25 kph): %d" % bad.size())
	get_tree().quit(0)


func _run_car(spec: Dictionary, def: Dictionary, city: CityWorld, is_city: bool) -> Dictionary:
	var path := TrackPath.new()
	path.build_from_def(def, 2.0)
	var car := Car.new()
	car.setup(spec, path, -33.0, -2.6, Color.TRANSPARENT, {}, false)
	if is_city:
		car.city = city
	var start := car.pos
	var off_frames := 0
	var block_frames := 0
	var frames := 0
	var v1 := 0.0
	var v3 := 0.0
	var v6 := 0.0
	var dist6 := 0.0
	var t := 0.0
	# 3s 起跑倒数（手刹），随后 6s 全油门
	while t < 3.0:
		car.update_car(DT, {"steer": 0.0, "throttle": 0.0, "handbrake": true,
			"nitro": false, "reverse_pressed": false})
		t += DT
	while t < 9.0:
		car.update_car(DT, {"steer": 0.0, "throttle": 1.0, "handbrake": false,
			"nitro": false, "reverse_pressed": false})
		t += DT
		frames += 1
		if car.offroad:
			off_frames += 1
		# 撞楼/被推：位置被墙体改写过（wall_impact 也行，但持续推挤更准）
		if car.wall_impact > 0.01:
			block_frames += 1
		if v1 == 0.0 and t >= 4.0:
			v1 = car.speed_kph
		if v3 == 0.0 and t >= 6.0:
			v3 = car.speed_kph
		dist6 = start.distance_to(car.pos)
	v6 = car.speed_kph
	car.free()
	return {"v1": v1, "v3": v3, "v6": v6, "dist6": dist6,
		"offroad": float(off_frames) / float(maxi(frames, 1)),
		"blocked": float(block_frames) / float(maxi(frames, 1))}


func _track_def(tracks: Array, id: String) -> Dictionary:
	for t in tracks:
		if String(t.get("id", "")) == id:
			return t
	return {}


func _read_json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	return parsed if parsed is Dictionary else {}
