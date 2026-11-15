extends SceneTree
## 拆包挂载验证（不加载 3D 场景，headless 安全）：
##   <游戏可执行文件> --headless --script res://tools/verify_split_pack.gd
## 前提：可执行文件同目录有拆分后的 main pck 与 APEX_VELOCITY_data.pck

func _init() -> void:
	var fails := 0
	# 被剔除的 docs .import：仍存在说明用的不是拆分后的 main pck
	if FileAccess.file_exists("res://docs/m10/near-far-lod.png.import"):
		print("FAIL: 主包未拆分（docs 残留）")
		quit(1); return
	print("ok: 主包为拆分版（docs 已剔除）")
	var pack_path := OS.get_executable_path().get_base_dir().path_join("APEX_VELOCITY_data.pck")
	if not FileAccess.file_exists(pack_path):
		print("FAIL: 找不到数据包 ", pack_path)
		quit(1); return
	if not ProjectSettings.load_resource_pack(pack_path):
		print("FAIL: load_resource_pack 返回 false")
		quit(1); return
	print("ok: 数据包已挂载")
	for p in [
		"res://maps/assets/polyhaven/models/jacaranda_tree/jacaranda_tree.gltf",
		"res://maps/assets/polyhaven/models/fir_sapling/fir_sapling.gltf",
		"res://maps/assets/venues/ad_board.glb",
	]:
		if FileAccess.file_exists(p): print("ok: 移动资产 ", p)
		else: print("FAIL: 移动资产缺失 ", p); fails += 1
	for p in [
		"res://docs/m32/menu-car-in-scene-coast.png",
		"res://assets/video/launch.ogv",
		"res://scenes/main.tscn",
		"res://cars/assets/models/bmw_m3_e46_gtr.glb",
		"res://maps/assets/city_ring/city_ring.glb",
	]:
		if FileAccess.file_exists(p): print("ok: 保留资产 ", p)
		else: print("FAIL: 保留资产缺失 ", p); fails += 1
	var data = load("res://data/cars.json")
	if data == null: print("FAIL: cars.json 加载失败"); fails += 1
	else: print("ok: cars.json 加载")
	if fails == 0:
		print("PASS: 拆包挂载验证全部通过")
		quit(0)
	else:
		print("FAIL: %d 项未通过" % fails)
		quit(1)