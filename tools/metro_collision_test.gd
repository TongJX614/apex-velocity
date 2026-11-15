extends Node
## 都会环线建筑碰撞验证：把车对准楼体直冲，检查是否被 SDF 推出。
## 用法：Godot --headless --path . res://tools/metro_collision_test.tscn

const DT := 1.0 / 120.0

# x, z, dir_x, dir_z, label  (起点 → 楼体)
const CASES := [
	[-259.4, 171.4, -0.9995, 0.0319, "未覆盖大块A"],
	[273.8, -103.9, -0.9991, -0.0427, "未覆盖大块B"],
	[-11.8, -79.3, -0.9990, 0.0438, "未覆盖条状C"],
	[-158.1, -21.0, -0.9975, 0.0706, "未覆盖D"],
	[88.5, -74.2, -1.0, 0.0, "未覆盖E"],
	[231.8, -249.2, -0.9982, 0.0600, "未覆盖F"],
	[-14.8, -5.6, 0.9350, 0.3547, "已覆盖G"],
	[115.1, 57.8, 0.9128, 0.4084, "已覆盖H"],
]


func _ready() -> void:
	var spec: Dictionary = (GameData.cars_specs[0] as Dictionary).duplicate(true)
	for s in GameData.cars_specs:
		if String(s.get("id", "")) == "aventador_lp700":
			spec = (s as Dictionary).duplicate(true)
			break
	var def: Dictionary = GameData.track("metro")
	var path := TrackPath.new()
	path.build_from_def(def, 2.0)
	var city := CityWorld.new()
	add_child(city)
	print("[METRO] collision loaded=%s" % str(city.load_collision()))
	for c in CASES:
		_run(path, city, spec, c)
	quit_after()


func quit_after() -> void:
	get_tree().quit(0)


func _run(path: TrackPath, city: CityWorld, spec: Dictionary, c: Array) -> void:
	var car := Car.new()
	car.setup(spec, path, 0.0, 0.0, Color.TRANSPARENT, {}, false)
	car.city = city
	car.pos = Vector3(float(c[0]), 0.0, float(c[1]))
	var dir := Vector2(float(c[2]), float(c[3])).normalized()
	car.heading = atan2(dir.x, dir.y)
	car.vel = Vector3.ZERO
	car.track_index = 0
	var min_d := 1.0e9
	var min_at := Vector3.ZERO
	var t := 0.0
	var reached_wall := 1.0e9
	while t < 5.0:
		car.update_car(DT, {"steer": 0.0, "throttle": 1.0, "handbrake": false,
			"nitro": false, "reverse_pressed": false})
		var d := city.distance_at(car.pos.x, car.pos.z)
		if d < min_d:
			min_d = d
			min_at = car.pos
		reached_wall = minf(reached_wall, d)
		t += DT
	var end := car.pos
	var moved := Vector2(end.x - float(c[0]), end.z - float(c[1])).length()
	print("[METRO] %-12s 终点=(%.1f, %.1f) 行进=%.1fm 最近SDF=%.2f @ (%.1f, %.1f) %s" % [
		String(c[4]), end.x, end.z, moved, min_d, min_at.x, min_at.z,
		# 只有真的贴到墙面（SDF≈车半径）才算挡住；一路无阻开出去时
		# min_d 始终很大，不能反过来当成「被楼挡住」。
		"OK 被楼挡住" if min_d <= 2.2 and moved > 1.0 else "!! 没碰到楼/穿墙"])
	car.free()
