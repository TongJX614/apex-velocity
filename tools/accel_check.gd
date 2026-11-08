extends SceneTree
## 加速曲线验证（纯逻辑，可 headless）：
##   · 标定收敛：模型 0-100 = 车辆库标注值；
##   · 真实化：100-200 明显慢于 0-100，200-300 更慢（功率限制段）；
##   · 极速：全油门平衡点（推力 = 滚阻 + 风阻）≈ maxSpeed。
## 用法：godot --headless --path <项目> --script res://tools/accel_check.gd

const COAST_ROLL := 0.9
const DRIVE_EFF := 0.82


func _init() -> void:
	# SceneTree._init 早于 autoload 注册，直接 load(car.gd) 会因 GameData
	# 等全局单例不存在而编译失败；推迟到第一帧再跑。
	process_frame.connect(_run, CONNECT_ONE_SHOT)


func _run() -> void:
	var f := FileAccess.open("res://data/cars.json", FileAccess.READ)
	var data: Variant = JSON.parse_string(f.get_as_text())
	var cars: Array = data["specs"]
	var script := load("res://scripts/cars/car.gd")
	print("%-26s %5s %5s %8s %8s %8s" % ["car", "0-100", "标定", "100-200", "200-300", "平衡极速"])
	var calib_bad := 0
	var slow_bad := 0
	var eq_bad := 0
	var t2_count := 0
	var t2_sum := 0.0
	for spec in cars:
		var car = script.new()
		car.max_speed = float(spec.get("maxSpeed", 60.0))
		car.fuel_type = String(spec.get("fuelType", "ice")).to_lower()
		car.engine_profile = String(spec.get("engineProfile", "i6")).to_lower()
		car.drivetrain = String(spec.get("drivetrain", "RWD")).to_upper()
		car.redline = clampf(float(spec.get("redline", 0.94)), 0.80, 1.0)
		car.gear_count = clampi(int(spec.get("gears", 6)), 1, 6)
		if car.fuel_type == "ev":
			car.gear_count = 1
		car.weight_kg = float(spec.get("weightKg", 1500.0))
		car.power_hp = float(spec.get("powerHp", 300.0))
		car.torque_nm = float(spec.get("torqueNm", 400.0))
		var spec_t := float(spec.get("realZeroTo100", spec.get("zeroTo100", 5.0)))
		var p := float(car._calibrate_accel(spec_t))
		var t1 := float(car._model_zero_to_100(p))
		var t2 := float(car._model_zero_to_100(p, 0.0, 200.0 / 3.6))
		var t3 := float(car._model_zero_to_100(p, 0.0, 300.0 / 3.6))
		var d12 := t2 - t1 if t2 < 29.9 else -1.0
		var d23 := t3 - t2 if t3 < 29.9 else -1.0
		# 平衡极速：净加速度（推力 − 滚阻 − 风阻）在 maxSpeed 处应 ≈ 0
		var tq: float = car._torque_curve(car.redline)
		var p_eff: float = car.power_hp * 735.5 * DRIVE_EFF
		var m: float = maxf(car.weight_kg, 800.0)
		var vmax: float = maxf(car.max_speed, 30.0)
		var aero: float = maxf((tq * p_eff / (m * vmax) - COAST_ROLL) / (vmax * vmax), 0.00004)
		var ref: float = clampf(p_eff / (m * maxf(p, 0.5)), 10.0, 45.0)
		var net: float = p * tq * minf(1.0, ref / vmax) - COAST_ROLL - aero * vmax * vmax
		print("%-26s %5.2f %5.2f %8s %8s %8.1f  net=%.3f" % [
			String(spec.get("id", "?")), t1, spec_t,
			"%.2f" % d12 if d12 >= 0.0 else "不可达",
			"%.2f" % d23 if d23 >= 0.0 else "不可达",
			vmax * 3.6, net])
		if absf(t1 - spec_t) > 0.06:
			calib_bad += 1
			print("    !! 标定偏差 %.2fs" % (t1 - spec_t))
		if d12 >= 0.0:
			t2_count += 1
			t2_sum += d12
			if d12 <= t1 * 0.9:
				slow_bad += 1
				print("    !! 100-200 (%.2fs) 没有比 0-100 (%.2fs) 明显变慢" % [d12, t1])
		if d23 >= 0.0 and d23 <= d12:
			slow_bad += 1
			print("    !! 200-300 (%.2fs) 没有比 100-200 (%.2fs) 变慢" % [d23, d12])
		if absf(net) > 0.08:
			eq_bad += 1
			print("    !! 极速平衡点偏离 maxSpeed：net=%.3f m/s²" % net)
		car.free()
	print("---")
	print("共 %d 台：标定偏差 %d，衰减不足 %d，极速平衡异常 %d；能上 200 的车 100-200 平均 %.1fs" % [
		cars.size(), calib_bad, slow_bad, eq_bad, t2_sum / maxf(float(t2_count), 1.0)])
	quit()
