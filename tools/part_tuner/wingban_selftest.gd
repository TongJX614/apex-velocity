extends SceneTree
## 装配禁用标记的自动化验证（车+翼配对语义）：
##   1. 配对禁装：甲车禁装翼X后，甲车 cycle 必须跳过 X；乙车不受影响仍可选到 X；
##   2. 车级禁翼：标记后该车 cycle 左右都锁死在原厂(0)。
## 测试前后自动还原 garage.json 与标记现场，不污染真实存档。
## 注：--script 主循环脚本编译早于 autoload 注册，GameData/Garage 用运行时节点获取。

var _step := 0
var _frames := 0
var _gd: Node          # GameData autoload
var _garage: Node      # Garage autoload
var _car := ""         # 甲车（被禁装的车）
var _car2 := ""        # 乙车（对照，不受影响）
var _donor := ""       # 被禁装的翼
var _orig_json := ""
var _orig_nowing := false
var _orig_banned := false
var _fail := ""

var PL: GDScript   # 运行时 load（主脚本编译早于 autoload，preload 会连带编译失败）


func _initialize() -> void:
	pass   # 树激活前取不到 autoload 节点，统一延迟到 _process 里解析


func _ready_ok() -> bool:
	if _gd == null:
		_gd = root.get_node_or_null("/root/GameData")
	if _garage == null:
		_garage = root.get_node_or_null("/root/Garage")
	return _gd != null and _garage != null


func _fail_quit(msg: String) -> bool:
	_fail = msg
	print("FAIL: " + msg)
	return true


func _finish() -> bool:
	PL.set_wing_banned(_car, _donor, _orig_banned)
	PL.set_car_no_wing(_car, _orig_nowing)
	if _orig_json.is_empty():
		DirAccess.remove_absolute("user://garage.json")
	else:
		var f := FileAccess.open("user://garage.json", FileAccess.WRITE)
		f.store_string(_orig_json)
		f.close()
	print("ALL PASS" if _fail.is_empty() else "DONE WITH FAIL")
	return true


func _process(_d: float) -> bool:
	_frames += 1
	if _frames < 5:
		return false
	if not _ready_ok():
		return _fail_quit("autoload 一直没就绪")
	if PL == null:
		PL = load("res://scripts/cars/parts_library.gd")
	match _step:
		0:
			if _car.is_empty():
				_car = String(_gd.cars_specs[0].get("id", ""))
				if _gd.cars_specs.size() > 1:
					_car2 = String(_gd.cars_specs[1].get("id", ""))
				var donors: Array = PL.wing_donor_ids()
				_donor = String(donors[0]) if donors.size() > 0 else ""
				_orig_nowing = PL.car_no_wing(_car)
				_orig_banned = PL.wing_banned(_car, _donor)
				var f := FileAccess.open("user://garage.json", FileAccess.READ)
				_orig_json = f.get_as_text() if f != null else ""
			if _donor.is_empty() or _car2.is_empty():
				print("SKIP: 目录里没有足够的供体翼/车可测")
				return _finish()
			# 找到该供体翼的选项 index
			var idx := -1
			for i in PL.wing_option_count():
				if PL.wing_donor_of(i) == _donor:
					idx = i
					break
			if idx <= 0:
				print("SKIP: 供体翼 index 异常(%d)" % idx)
				return _finish()
			# 1) 配对禁装：甲车从 X 前一个位置 cycle(+1) 不得落在 X 上
			PL.set_wing_banned(_car, _donor, true)
			_garage.config(_car)["wing"] = idx - 1
			var v: int = _garage.cycle_option(_car, "wing", 1)
			if v == idx:
				return _fail_quit("cycle(+1) 落到了禁装翼 index=%d" % idx)
			print("OK 配对禁装: 甲车禁了 index=%d，cycle(+1) 从 %d 跳到 %d" % [idx, idx - 1, v])
			# 乙车不受影响：同样从 idx-1 出发 cycle(+1) 应落在 idx（X 可装）
			_garage.config(_car2)["wing"] = idx - 1
			var v2: int = _garage.cycle_option(_car2, "wing", 1)
			if v2 != idx:
				return _fail_quit("乙车应仍可选到 index=%d, 实际 %d" % [idx, v2])
			print("OK 其它车不受影响: 乙车 cycle(+1) → %d（正是被甲车禁掉的翼）" % v2)
			# 2) 车级禁翼：甲车无论从哪个位置、哪个方向，都锁死在原厂(0)
			PL.set_car_no_wing(_car, true)
			_garage.config(_car)["wing"] = 2
			if _garage.cycle_option(_car, "wing", 1) != 0:
				return _fail_quit("车级禁翼后 cycle(+1) 应为 0")
			_garage.config(_car)["wing"] = 2
			if _garage.cycle_option(_car, "wing", -1) != 0:
				return _fail_quit("车级禁翼后 cycle(-1) 应为 0")
			print("OK 车级禁翼: 左右 cycle 都锁在原厂(0)")
			# 3) 可用性查询自检
			if not _garage.wing_option_usable(_car, 0):
				return _fail_quit("index 0 原厂应恒可用")
			_step = 1
		1:
			return _finish()
	return false
