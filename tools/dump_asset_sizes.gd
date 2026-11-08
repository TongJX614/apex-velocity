extends SceneTree
## 打印开放世界用到的真实资产的包围盒尺寸与水平占位半径，
## 用来排查"某根柱子特别大""楼骑在路上"这类比例问题。
##
## 注意：RealAssetKit 以前硬依赖 Settings autoload，在 --script 模式下
## 整个类编译失败，本工具无法运行；现在改成运行时空值查找后可以了。

func _init() -> void:
	var assets := [
		"realtree_fir_full", "realtree_fir", "lowtree_pine", "realtree_pine",
		"realtree_01", "realtree_02", "realtree_03", "realtree_broadleaf", "tree_broadleaf",
		"tree_palm_tall", "tree_palm_bent", "lowtree_palm", "tree_palm",
		"boulder02", "boulder03", "rock_face", "mountain_real",
		"shrub_real", "shrub_real01", "shrub_real02", "shrub_real04", "shrub_coastal",
		"realtree_dead", "realtree_quiver", "realtree_quiver01",
		"downtown_large", "downtown_medium", "downtown_small",
		"colony_tower", "station_tower", "blockchain_tower", "memefactory_tower", "lovedeath_tower",
		"qt_block1_large", "qt_block2_large", "qt_block3", "qt_block4",
		"qt_apt2", "qt_apt3", "qt_apt4_a", "qt_apt4_b", "qt_apt6",
		"factory_facade", "industrial_pipes",
		"qt_house1", "qt_house2", "light_tower", "ship_real", "pier_real",
		"sea_marker_real", "barrel_real", "tyre_real", "power_pole",
	]
	print("=== 资产真实尺寸（Godot 引擎口径）===")
	print("%-24s %-34s %10s %10s" % ["asset", "size(x,y,z)", "占位半径", "顶点半径"])
	for a in assets:
		var s := RealAssetKit.size(String(a))
		var fp := RealAssetKit.footprint_radius(String(a), 1.0)
		var tr := RealAssetKit.true_radius(String(a))
		print("%-24s %-34s %10.2f %10.2f" % [String(a),
			str(s.snapped(Vector3(0.01, 0.01, 0.01))), fp, tr])
	quit()
