extends SceneTree
## 开放世界资产占位探针（独立运行，不依赖 autoload）。
## 用法：Godot --headless --path <proj> --script res://tools/probe_openworld_assets.gd
##
## 输出每个建筑 / 楼 / 塔资产在「目标高度」下的实际水平占位，
## 用来核对开放世界里「楼压在路上」「楼与楼重叠」的问题。

func _init() -> void:
	var assets := [
		["downtown_large", 92.0], ["downtown_medium", 52.0], ["downtown_small", 26.0],
		["qt_block1_large", 46.0],
		["qt_apt2", 34.0], ["qt_apt3", 34.0], ["qt_apt4_a", 34.0], ["qt_apt4_b", 34.0],
		["qt_apt6", 34.0], ["qt_block2_large", 34.0], ["qt_block3", 34.0], ["qt_block4", 34.0],
		["colony_tower", 176.0], ["station_tower", 152.0], ["blockchain_tower", 138.0],
		["memefactory_tower", 124.0], ["lovedeath_tower", 118.0],
		["factory_facade", 30.0], ["qt_house1", 8.0], ["qt_house2", 8.0],
	]
	print("--- RealAssetKit.size() / true_radius() 实测 ---")
	for e in assets:
		var a := String(e[0])
		var th := float(e[1])
		var sz := RealAssetKit.size(a)
		var tr := RealAssetKit.true_radius(a)
		var sc := RealAssetKit.scale_for_height(a, th)
		var r := tr * sc
		# 最长轴
		var long_axis := 1
		if sz.x > sz.y and sz.x > sz.z:
			long_axis = 0
		elif sz.z > sz.y and sz.z > sz.x:
			long_axis = 2
		print("  %-20s size=(%7.2f,%7.2f,%7.2f) true_r=%6.2f  H=%6.1f sc=%6.2f 占位半径=%6.1f 长轴=%d"
			% [a, sz.x, sz.y, sz.z, tr, th, sc, r, long_axis])
	quit()
