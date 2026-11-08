extends Node
## 断油（限速器）可达性探针 —— 验证"断油之后是什么声音"在真实玩法里听得到。
##
## 背景
## ----
## 用户明确要求"断油之后是什么声音"。这条声音由 EngineAudio 的限速器分支
## 产生，而限速器状态来自 car.gd 的 limiter_active。
##
## 之前 car.gd 的断油阈值是 redline × 1.002，而：
##   · 顶挡的极速占比 GEAR_TOPS 末位 = 1.0 → 车跑到极速时正好是红线；
##   · 车速被 _speed_cap() 硬钳在 max_speed，永远超不过去；
##   · 默认是自动挡（var manual := false）。
## 三个条件叠在一起 → rpm > redline × 1.002 在自动挡下永远不成立，
## 于是断油声一次都听不到。这不是"没做"，是"做了但触发不到"。
##
## 本探针直接驱动真实的 car.gd（不是复刻一份模型），统计每台车在
## 自动挡/手动挡下全油门到底时，limiter_active 的触发帧数与持续时长。
##
## 用法：
##   "$GODOT" --headless --path . res://tools/limiter_probe.tscn
##
## 注意：必须以**场景**方式运行，不能用 --script。
## car.gd 引用了 autoload 单例 GameData，--script 模式不注册 autoload 的
## 全局标识符，编译 car.gd 会直接失败（"Identifier not found: GameData"）。
##
## 输出：控制台表格 + /tmp/limiter_probe.json

const CAR := preload("res://scripts/cars/car.gd")
const CARS_JSON := "res://data/cars.json"

## 仿真步长（秒）与总时长
const DT := 1.0 / 60.0
const SIM_SECONDS := 45.0

## 统计用的最小断油持续时间：单帧的毛刺不算"听得到"
const MIN_BURST_FRAMES := 3


func _ready() -> void:
	var specs := _load_specs()
	if specs.is_empty():
		push_error("读不到 %s" % CARS_JSON)
		get_tree().quit(1)
		return

	var results := []
	var rows := []
	print("=".repeat(96))
	print("断油（限速器）可达性探针 —— 全油门直线加速")
	print("=".repeat(96))
	print(_row(["车型", "挡位", "燃料", "红线", "极速m/s", "终速m/s", "断油帧", "最长连续"],
		[24, 6, 7, 8, 10, 10, 9, 10]))
	print("-".repeat(96))

	for spec in specs:
		# EV 没有内燃机，不存在断油
		if String(spec.get("fuelType", "ice")).to_lower() == "ev":
			continue
		for manual in [false, true]:
			var r := _simulate(spec, manual)
			if r.is_empty():
				continue
			results.append(r)
			rows.append(_row([
				String(spec.get("id", "?")), ("手动" if manual else "自动"),
				String(spec.get("fuelType", "ice")).to_upper(),
				"%.3f" % r["redline"], "%.2f" % r["max_speed"],
				"%.2f" % r["final_speed"], "%d" % r["cut_frames"],
				"%d" % r["max_burst"]], [24, 6, 7, 8, 10, 10, 9, 10]))

	for line in rows:
		print(line)
	print("-".repeat(96))

	# ---- 汇总 ----
	var auto_hit := 0
	var auto_total := 0
	var manual_hit := 0
	var manual_total := 0
	var worst_auto := 0.0
	for r in results:
		if r["manual"]:
			manual_total += 1
			if r["cut_frames"] > 0:
				manual_hit += 1
		else:
			auto_total += 1
			if r["cut_frames"] > 0:
				auto_hit += 1
				worst_auto = maxf(worst_auto, float(r["final_speed"]) / float(r["max_speed"]))
	print("")
	print("自动挡: %d/%d 台车能触发断油" % [auto_hit, auto_total])
	print("手动挡: %d/%d 台车能触发断油" % [manual_hit, manual_total])
	if auto_hit < auto_total:
		print("!! 自动挡仍有 %d 台触发不到 —— 断油声在默认挡位下听不到" % (auto_total - auto_hit))
	else:
		print("自动挡触发时终速保持在极速的 %.2f%%~100%%（限速器弹跳，不会把车按住）"
			% (worst_auto * 100.0))

	# 听感判定：断油必须是"连续一段"（能听见断断续续的顿挫），
	# 而不是只闪一帧。
	var weak := 0
	for r in results:
		if r["cut_frames"] > 0 and r["max_burst"] < MIN_BURST_FRAMES:
			weak += 1
	var min_burst := _min_max_burst(results)
	print("断油持续时间: 最长连续段最短 %d 帧（判定门槛 %d 帧）" % [min_burst, MIN_BURST_FRAMES])
	if weak > 0:
		print("!! %d 个样本的断油只闪了不到 %d 帧，听感上等于没有" % [weak, MIN_BURST_FRAMES])

	var f := FileAccess.open("/tmp/limiter_probe.json", FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({"results": results}))
		f.close()
		print("明细: /tmp/limiter_probe.json")

	get_tree().quit(0)



## GDScript 的 % 不支持 %-22s 这种宽度格式，表格统一走这个助手。
func _row(cells: Array, widths: Array) -> String:
	var parts := PackedStringArray()
	for i in cells.size():
		var w: int = widths[i] if i < widths.size() else 8
		parts.append(_lpad(str(cells[i]), w))
	return " ".join(parts)


func _lpad(s: String, w: int) -> String:
	var t := s
	while t.length() < w:
		t = " " + t
	return t


func _min_max_burst(results: Array) -> int:
	var m := 999999
	for r in results:
		if r["cut_frames"] > 0:
			m = mini(m, int(r["max_burst"]))
	return 0 if m == 999999 else m


## 驱动真实的 car.gd 跑一段直线加速，返回统计。
func _simulate(spec: Dictionary, manual: bool) -> Dictionary:
	var car = CAR.new()
	add_child(car)
	car.setup_open_world(spec, null, {"pos": Vector3.ZERO, "heading": 0.0})
	car.manual = manual

	var total_frames := int(SIM_SECONDS / DT)
	var cut_frames := 0
	var burst := 0
	var max_burst := 0
	var final_speed := 0.0
	var top_speed := 0.0
	for i in total_frames:
		car.update_car(DT, {"throttle": 1.0, "steer": 0.0})
		if car.limiter_active:
			cut_frames += 1
			burst += 1
			if burst > max_burst:
				max_burst = burst
		else:
			burst = 0
		final_speed = car.speed_forward
		top_speed = maxf(top_speed, car.speed_forward)
	# 先把要用的字段取出来，再释放节点（free 之后再访问会报
	# "Invalid access to property ... previously freed"）
	var out := {
		"car_id": String(spec.get("id", "?")),
		"manual": manual,
		"redline": car.redline,
		"max_speed": car.max_speed,
		"final_speed": final_speed,
		"top_speed": top_speed,
		"cut_frames": cut_frames,
		"max_burst": max_burst,
	}
	car.free()
	return out


func _load_specs() -> Array:
	if not FileAccess.file_exists(CARS_JSON):
		return []
	var f := FileAccess.open(CARS_JSON, FileAccess.READ)
	if f == null:
		return []
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		return []
	return parsed.get("specs", [])
