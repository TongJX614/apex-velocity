extends SceneTree
## 开放世界地表着色探针：打印指定点的地表顶点色 / 域 / 坡度，
## 用来查"某片地面为什么是白的"。

func _init() -> void:
	var ow := OpenWorld.new()
	ow.name = "OpenWorld"
	root.add_child(ow)
	ow.build()

	var pts: Array = [
		Vector3(1753.2, 0.0, -1710.8),   # 熔岩域截图里的车
		Vector3(1700.0, 0.0, -1800.0),
		Vector3(1732.0, 0.0, -1732.0),   # 火山口
		Vector3(1732.0, 0.0, -2000.0),
		Vector3(2450.0, 0.0, 0.0),      # 霓虹都市中心
		Vector3(1732.0, 0.0, 1732.0),   # 天际环城中心
	]
	print("=== 地表着色探针 ===")
	for p in pts:
		var v: Vector3 = p
		var h := ow.height_at(v.x, v.z)
		var zi := ow._dominant_zone(v.x, v.z)
		var ki := ow._effect_kind(v.x, v.z)
		var kind := String(OpenWorld.KIND_NAMES[ki])
		var slope := 1.0 - ow.normal_at(v.x, v.z).y
		var c := ow._ground_color(v.x, v.z, h, ki, slope)
		print("  (%8.1f,%8.1f) h=%7.2f zone=%2d kind=%-6s slope=%.3f  color=(%.3f,%.3f,%.3f)" % [
			v.x, v.z, h, zi, kind, slope, c.r, c.g, c.b])
	quit()
