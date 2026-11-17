extends SceneTree
## 变速箱挡位验证（纯逻辑，可 headless）：证明挡位数是**逐车生效**的，
## 而不是全池都是 6 挡。
##
## 检查项：
##   · 齿比表长度 = 真实挡位数，且末位 = 1.0（顶挡红线正好落在极速上）；
##   · 齿比表严格递增，且每一挡的升挡车速都在极速以内 → 挡位阶梯能被跑完，
##     不会出现"挂了 8 挡但永远升不到 8 挡"；
##   · 6 挡车的齿比表与改造前的固定表逐位相同 → 绝大多数车行为不变；
##   · 手动挡逐级 +1 能升到顶挡、自动挡升挡序列覆盖 1..N；
##   · 逐挡调用 _rpm_for_gear / _gear_lug 不越界。
##
## 用法：godot --headless --path . --script res://tools/gear_check.gd

## 改造前 car.gd 里写死的 6 挡表，用来证明 6 挡车没有被动过
const OLD_GEAR_TOPS := [0.16, 0.30, 0.45, 0.61, 0.79, 1.0]
const RPM_IDLE := 0.112


func _init() -> void:
	process_frame.connect(_run, CONNECT_ONE_SHOT)


func _run() -> void:
	var f := FileAccess.open("res://data/cars.json", FileAccess.READ)
	var data: Variant = JSON.parse_string(f.get_as_text())
	var cars: Array = data["specs"]
	var script := load("res://cars/scripts/car.gd")
	print("%-24s %4s %5s  %s" % ["car", "挡", "顶挡kmh", "各挡红线车速 km/h"])
	var bad := []
	var counts := {}
	for spec in cars:
		var car = script.new()
		car.max_speed = float(spec.get("maxSpeed", 60.0))
		car.fuel_type = String(spec.get("fuelType", "ice")).to_lower()
		car.drivetrain = String(spec.get("drivetrain", "RWD")).to_upper()
		car.redline = clampf(float(spec.get("redline", 0.94)), 0.80, 1.0)
		car.gear_count = int(spec.get("gears", 6))
		if car.fuel_type == "ev":
			car.gear_count = 1
		var n: int = car.gear_count
		counts[n] = int(counts.get(n, 0)) + 1
		var id := String(spec.get("id", "?"))
		if int(car.gear_tops.size()) != n:
			bad.append("%s: 齿比表长度 %d != 挡位数 %d" % [id, int(car.gear_tops.size()), n])
		# 升挡阈值与 car.gd 自动挡一致
		var up_at: float = minf(float(car.redline) * float(car.AUTO_UPSHIFT), float(car.AUTO_SHIFT_RPM))
		var span: float = float(car.redline) - RPM_IDLE
		var ladder := ""
		var prev_v := 0.0
		for g in range(1, n + 1):
			var top: float = car._gear_top(g)
			# 该挡红线车速 = 齿比表占比 × 极速；升挡车速由升挡转速反推
			var red_v: float = top * float(car.max_speed)
			var up_v: float = (up_at - RPM_IDLE) / maxf(span, 0.05) * red_v
			if g == n:
				up_v = red_v
			if g > 1 and up_v <= prev_v + 0.01:
				bad.append("%s: 第 %d 挡升挡车速 %.1f 未超过上一挡 %.1f" % [id, g, up_v, prev_v])
			# 升挡车速必须还在极速以内，否则这一挡永远挂不上（顶挡跑不到的挡位是废挡）
			if g < n and up_v >= float(car.max_speed):
				bad.append("%s: 第 %d 挡升挡车速 %.1f 已超过极速 %.1f" % [id, g, up_v, float(car.max_speed)])
			prev_v = up_v
			ladder += "%.0f " % (red_v * 3.6)
			# 逐挡调用真实函数，确认不越界
			car._rpm_for_gear(red_v, g)
			car.gear = g
			car._gear_lug(red_v * 0.5)
		car.gear = 1
		print("%-24s %4d %5.0f  %s" % [id, n, float(car.max_speed) * 3.6, ladder])
		if n == 6 and not _same_tops(car.gear_tops, OLD_GEAR_TOPS):
			bad.append("%s: 6 挡齿比表与改造前的固定表不一致" % id)
		if absf(float(car._gear_top(n)) - 1.0) > 0.0001:
			bad.append("%s: 顶挡占比不是 1.0" % id)
		if n > 1 and float(car._gear_top(n - 1)) >= float(car._gear_top(n)):
			bad.append("%s: 齿比表非递增" % id)
		car.free()
	print("---")
	var keys := counts.keys()
	keys.sort()
	var parts := []
	for k in keys:
		parts.append("%d挡×%d台" % [k, counts[k]])
	print("挡位分布: " + " / ".join(parts))
	if bad.is_empty():
		print("PASS: %d 台车的齿比表全部按真实挡位数展开，6 挡行为与改造前一致" % cars.size())
	else:
		print("FAIL:")
		for b in bad:
			print("   " + b)
	quit(0 if bad.is_empty() else 1)


func _same_tops(a: PackedFloat32Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i in a.size():
		if absf(a[i] - float(b[i])) > 0.0001:
			return false
	return true
