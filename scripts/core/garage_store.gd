extends Node
## Autoload `Garage`: per-car garage configuration + performance upgrades.
##
## Ported from the legacy garage.js. Note: the legacy build sets `credits` to
## Infinity ("the tuning works is funded indefinitely"), so cosmetics and
## upgrades are free here too — there is no coin economy to grind.
## Config is persisted to user://garage.json.

const SAVE_PATH := "user://garage.json"
# 真件库：用 preload 显式加载（新 class_name 在全局类缓存刷新前不可用，
# autoload 启动早于缓存扫描，直接写类名会导致整个 Garage 加载失败）
const PartsLibrary := preload("res://scripts/cars/parts_library.gd")
const OPTION_KEYS := ["paint", "rim", "caliper", "wheel", "tire", "wing", "livery"]
const UPGRADE_KEYS := ["engine", "tires", "aero", "nitro",
	"gearbox", "brakes", "weight", "suspension"]

# effectiveSpec calibration constants (legacy garage.js)
const ACCEL_TAPER := 0.8
const STOCK_DRIVE_DRAG := 0.12
const ZERO_TO_100 := 100.0 / 3.6
const ACCEL_STEP := 1.0 / 240.0
const ACCEL_PACE := 1.3

var cars: Dictionary = {}


func _ready() -> void:
	load_from_disk()


func _default_config() -> Dictionary:
	return {
		"paint": 0, "rim": 0, "caliper": 0, "wheel": 0, "tire": 0,
		"wing": 0, "livery": 0,
		"engine": 0, "tires": 0, "aero": 0, "nitro": 0,
		"gearbox": 0, "brakes": 0, "weight": 0, "suspension": 0,
		"spent": {},
	}


func default_cars() -> Dictionary:
	var out := {}
	for spec in GameData.cars_specs:
		out[String(spec.get("id", ""))] = _default_config()
	return out


func _normalize(raw: Dictionary) -> Dictionary:
	var out := default_cars()
	var source: Dictionary = raw.get("cars", {})
	for car_id in out.keys():
		var src: Dictionary = source.get(car_id, {})
		if src.is_empty():
			continue
		var dst: Dictionary = out[car_id]
		for key in OPTION_KEYS:
			dst[key] = int(src.get(key, 0))
		for key in UPGRADE_KEYS:
			dst[key] = clampi(int(src.get(key, 0)), 0, _upgrade_max(key))
		var spent_src = src.get("spent", {})
		var spent := {}
		if typeof(spent_src) == TYPE_DICTIONARY:
			for key in UPGRADE_KEYS:
				spent[key] = clampi(int((spent_src as Dictionary).get(key, 0)),
					0, 1_000_000_000)
		dst["spent"] = spent
	return out


func load_from_disk() -> void:
	if not FileAccess.file_exists(SAVE_PATH):
		cars = default_cars()
		return
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if f == null:
		cars = default_cars()
		return
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		cars = default_cars()
		return
	cars = _normalize(parsed)


func save_to_disk() -> void:
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		push_error("Garage: cannot write %s" % SAVE_PATH)
		return
	f.store_string(JSON.stringify({"cars": cars}, "  "))
	f.close()


func config(car_id: String) -> Dictionary:
	if not cars.has(car_id):
		cars[car_id] = _default_config()
	return cars[car_id]


func option_counts(car_id: String) -> Dictionary:
	return {
		"paint": palette_size(car_id),
		"rim": GameData.garage.get("rim_finishes", []).size(),
		"caliper": GameData.garage.get("calipers", []).size(),
		"wheel": PartsLibrary.wheel_option_count(),
		"tire": GameData.garage.get("tire_styles", []).size(),
		"wing": PartsLibrary.wing_option_count(),
	}


func palette_size(car_id: String) -> int:
	return maxi(1, GameData.palette_for(car_id).size())


func _option_count(car_id: String, key: String) -> int:
	match key:
		"paint":
			return palette_size(car_id)
		"rim":
			return GameData.garage.get("rim_finishes", []).size()
		"caliper":
			return GameData.garage.get("calipers", []).size()
		"wheel":
			return PartsLibrary.wheel_option_count()
		"tire":
			return GameData.garage.get("tire_styles", []).size()
		"wing":
			return PartsLibrary.wing_option_count()
		"livery":
			return GameData.garage.get("liveries", []).size()
	return 1


## 尾翼选项可用性（part_tuner 标记产出）：
##   · 车级禁翼（no_wing）    = 这台车只允许原厂尾翼（index 0）；
##   · 配对禁装（wing_bans）  = 这台车装不了某个指定供体翼（其它车不受影响）。
## index 0（原厂尾翼）永远可用。
func wing_option_usable(car_id: String, index: int) -> bool:
	if PartsLibrary.car_no_wing(car_id):
		return index == 0
	var donor := PartsLibrary.wing_donor_of(index)
	return donor.is_empty() or not PartsLibrary.wing_banned(car_id, donor)


## Changes one cosmetic option with wraparound. Returns the new index.
func cycle_option(car_id: String, key: String, direction: int) -> int:
	var count := _option_count(car_id, key)
	var cfg := config(car_id)
	var value := posmod(int(cfg.get(key, 0)) + direction, maxi(count, 1))
	if key == "wing":
		# 跳过不可装配的尾翼位；全部不可用（理论不可能，0 恒可用）则回原厂
		for _i in count:
			if wing_option_usable(car_id, value):
				break
			value = posmod(value + direction, maxi(count, 1))
		if not wing_option_usable(car_id, value):
			value = 0
	cfg[key] = value
	save_to_disk()
	return value


## Sets one cosmetic option to an absolute index (used by the paint swatch strip).
func set_option(car_id: String, key: String, index: int) -> int:
	var count := _option_count(car_id, key)
	var cfg := config(car_id)
	var value := posmod(index, maxi(count, 1))
	if key == "wing" and not wing_option_usable(car_id, value):
		value = 0
	cfg[key] = value
	save_to_disk()
	return value


func get_option(car_id: String, key: String) -> int:
	return int(config(car_id).get(key, 0))


func option_entry(car_id: String, key: String) -> Dictionary:
	var cfg := config(car_id)
	var index := int(cfg.get(key, 0))
	match key:
		"paint":
			var palette := GameData.palette_for(car_id)
			if palette.is_empty():
				return {}
			return palette[clampi(index, 0, palette.size() - 1)]
		"rim":
			return _table_entry("rim_finishes", index)
		"caliper":
			return _table_entry("calipers", index)
		"wheel":
			return PartsLibrary.wheel_option_entry(index)
		"tire":
			return _table_entry("tire_styles", index)
		"wing":
			return PartsLibrary.wing_option_entry(index)
		"livery":
			return _table_entry("liveries", index)
	return {}


func _table_entry(table: String, index: int) -> Dictionary:
	var arr: Array = GameData.garage.get(table, [])
	if arr.is_empty():
		return {}
	return arr[clampi(index, 0, arr.size() - 1)]


func option_name(car_id: String, key: String) -> String:
	var entry := option_entry(car_id, key)
	return String(entry.get("name", entry.get("id", "-")))


func paint_color(car_id: String) -> Color:
	var entry := option_entry(car_id, "paint")
	return Color.from_string(String(entry.get("color", "#ffffff")), Color.WHITE)


## 原厂漆 = 车漆选项 0。此时车模要保留 Blender 原件里的贴图/拉花，
## 不做纯色覆盖（旧版会统一刷成调色板里的颜色，拉花/细节全丢）。
func paint_is_factory(car_id: String) -> bool:
	return int(config(car_id).get("paint", 0)) == 0


func paint_is_matte(car_id: String) -> bool:
	var entry := option_entry(car_id, "paint")
	return bool(entry.get("matte", false))


func rim_color(car_id: String) -> Color:
	var entry := option_entry(car_id, "rim")
	var hex = entry.get("color")
	if hex == null:
		return Color.TRANSPARENT
	return Color.from_string(String(hex), Color.TRANSPARENT)


func caliper_color(car_id: String) -> Color:
	var entry := option_entry(car_id, "caliper")
	return Color.from_string(String(entry.get("color", "#b01722")), Color(0.69, 0.09, 0.13))


## 轮毂真件供体车 id（"" = 本车原厂轮）
func wheel_donor_id(car_id: String) -> String:
	return PartsLibrary.wheel_donor_of(get_option(car_id, "wheel"))


func tire_style_id(car_id: String) -> String:
	return String(option_entry(car_id, "tire").get("id", "street"))


## 尾翼真件供体车 id（"" = 本车原厂尾翼）
func wing_donor_id(car_id: String) -> String:
	return PartsLibrary.wing_donor_of(get_option(car_id, "wing"))


func tire_tint(car_id: String) -> Color:
	var entry := option_entry(car_id, "tire")
	return Color.from_string(String(entry.get("tint", "#c9d0d8")), Color(0.79, 0.82, 0.85))


# ---------------------------------------------------------------------------
# upgrades
# ---------------------------------------------------------------------------

func _upgrade_def(key: String) -> Dictionary:
	var upgrades: Dictionary = GameData.garage.get("upgrades", {})
	return upgrades.get(key, {})


func _upgrade_max(key: String) -> int:
	var costs: Array = _upgrade_def(key).get("costs", [])
	return costs.size()


func upgrade_level(car_id: String, key: String) -> int:
	return clampi(int(config(car_id).get(key, 0)), 0, _upgrade_max(key))


## 下一级要花多少 XP（costs 数组按当前等级取）；已满级返回 -1。
func upgrade_cost(car_id: String, key: String) -> int:
	var level := upgrade_level(car_id, key)
	if level >= _upgrade_max(key):
		return -1
	var costs: Array = _upgrade_def(key).get("costs", [])
	return maxi(0, int(costs[level]))


## 花 XP 升一级。XP 既是等级经验也是货币，余额不足返回 false。
func add_upgrade_level(car_id: String, key: String) -> bool:
	var cost := upgrade_cost(car_id, key)
	if cost < 0:
		return false
	if not ProfileStore.spend_credits(cost):
		return false
	var level := upgrade_level(car_id, key)
	var cfg := config(car_id)
	var spent: Dictionary = cfg.get("spent", {})
	spent[key] = int(spent.get(key, 0)) + cost
	cfg["spent"] = spent
	cfg[key] = level + 1
	save_to_disk()
	return true


func reset_upgrades(car_id: String) -> void:
	var cfg := config(car_id)
	var spent: Dictionary = cfg.get("spent", {})
	var refund := 0
	for key in UPGRADE_KEYS:
		refund += maxi(0, int(spent.get(key, 0)))
		cfg[key] = 0
	cfg["spent"] = {}
	if refund > 0:
		ProfileStore.refund_credits(refund)
	save_to_disk()


# ---------------------------------------------------------------------------
# effective spec (port of legacy effectiveSpec)
# ---------------------------------------------------------------------------

func _calibration(base: Dictionary) -> Dictionary:
	var accel := maxf(0.1, float(base.get("accel", 10.0)))
	var max_speed := maxf(1.0, float(base.get("maxSpeed", 60.0)))
	var disc := sqrt(STOCK_DRIVE_DRAG * STOCK_DRIVE_DRAG * max_speed * max_speed
		+ 4.0 * ACCEL_TAPER * accel * accel)
	var terminal_ratio := (-STOCK_DRIVE_DRAG * max_speed + disc) / (2.0 * ACCEL_TAPER * accel)
	var v := 0.0
	var t := 0.0
	while v < ZERO_TO_100 and t < 20.0:
		v += (accel * (1.0 - ACCEL_TAPER * pow(v / max_speed, 2.0)) - STOCK_DRIVE_DRAG * v) * ACCEL_STEP
		t += ACCEL_STEP
	return {"terminal_ratio": terminal_ratio, "stock_time": t}


func effective_spec(car_id: String) -> Dictionary:
	var base: Dictionary = GameData.car(car_id)
	if base.is_empty():
		return base
	var cfg := config(car_id)
	var engine := upgrade_level(car_id, "engine")
	var tires := upgrade_level(car_id, "tires")
	var aero := upgrade_level(car_id, "aero")
	var nitro := upgrade_level(car_id, "nitro")
	var gearbox := upgrade_level(car_id, "gearbox")
	var brakes := upgrade_level(car_id, "brakes")
	var weight := upgrade_level(car_id, "weight")
	var suspension := upgrade_level(car_id, "suspension")
	var engine_r := float(engine) / float(maxi(1, _upgrade_max("engine")))
	var tires_r := float(tires) / float(maxi(1, _upgrade_max("tires")))
	var aero_r := float(aero) / float(maxi(1, _upgrade_max("aero")))
	var gearbox_r := float(gearbox) / float(maxi(1, _upgrade_max("gearbox")))
	var weight_r := float(weight) / float(maxi(1, _upgrade_max("weight")))
	var suspension_r := float(suspension) / float(maxi(1, _upgrade_max("suspension")))

	var stock := _calibration(base)
	var stock_zero := float(base.get("zeroTo100", stock["stock_time"])) * ACCEL_PACE
	var max_speed := float(base.get("maxSpeed", 60.0)) + engine * 1.32 * 0.5 + aero * 0.6 * 0.5 \
		+ gearbox * 0.18
	var accel := float(base.get("accel", 10.0)) * (float(stock["stock_time"]) / stock_zero) \
		* (1.0 + engine_r * 0.375 + gearbox_r * 0.12 + weight_r * 0.08)
	var drive_drag := accel * (1.0 - ACCEL_TAPER * pow(float(stock["terminal_ratio"]), 2.0)) \
		/ (float(stock["terminal_ratio"]) * max_speed)
	var spec := base.duplicate(true)
	spec["maxSpeed"] = snappedf(max_speed, 0.01)
	spec["accel"] = snappedf(accel, 0.01)
	spec["driveDrag"] = snappedf(drive_drag, 0.00001)
	spec["grip"] = snappedf(float(base.get("grip", 7.0)) + tires * 0.096 + aero * 0.036
		+ suspension * 0.13 + weight * 0.016, 0.01)
	spec["brake"] = snappedf(float(base.get("brake", 30.0)) * (1.0 + brakes * 0.042), 0.01)
	spec["weightKg"] = snappedf(float(base.get("weightKg", 1500.0)) * (1.0 - weight * 0.015), 0.1)
	spec["topKph"] = int(base.get("topKph", 0)) + engine * 2.5 + aero * 1.0 + gearbox * 1.2
	# 展示值对齐车手实际手感：car.gd 按 realZeroTo100 标定推力，再按引擎/变速箱/轻量化等级加成。
	# 旧版这里用 ×ACCEL_PACE 的模拟时间，0 改装时也会比原厂纸面数据慢 30%。
	spec["zeroTo100"] = snappedf(float(base.get("zeroTo100", stock["stock_time"]))
		/ (1.0 + float(engine) * 0.0375 + float(gearbox) * 0.018 + float(weight) * 0.012), 0.1)
	spec["terminalSpeed"] = snappedf(max_speed * float(stock["terminal_ratio"]), 0.01)
	spec["nitroTime"] = snappedf(3.7 + nitro * 0.35, 0.01)
	spec["nitroLevel"] = nitro
	spec["color"] = "#%s" % paint_color(car_id).to_html(false)
	spec["tune"] = {
		"engine": engine, "tires": tires, "aero": aero, "nitro": nitro,
		"gearbox": gearbox, "brakes": brakes, "weight": weight, "suspension": suspension,
	}
	var stats: Dictionary = base.get("stats", {})
	var caps: Dictionary = base.get("caps", stats)
	spec["stats"] = {
		"speed": _between(int(stats.get("speed", 50)), int(caps.get("speed", 50)), engine_r * 0.7 + aero_r * 0.2 + gearbox_r * 0.1),
		"accel": _between(int(stats.get("accel", 50)), int(caps.get("accel", 50)), engine_r * 0.6 + weight_r * 0.25 + gearbox_r * 0.15),
		"handling": _between(int(stats.get("handling", 50)), int(caps.get("handling", 50)), tires_r * 0.55 + suspension_r * 0.3 + aero_r * 0.15),
	}
	return spec


func _between(from: int, to: int, t: float) -> int:
	return int(round(float(from) + float(to - from) * clampf(t, 0.0, 1.0)))


func summary() -> String:
	return "garage cars=%d" % cars.size()
