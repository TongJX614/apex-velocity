extends Node
## 把 city_collision.bin 烘成 city_collision.res（PackedByteArray 资源）。
## 用法：Godot --headless --path . res://tools/bake_city_collision.tscn

const CollisionData := preload("res://maps/scripts/openworld/city_collision_data.gd")


func _ready() -> void:
	var src := "res://maps/assets/city_ring/city_collision.bin"
	var dst := "res://maps/assets/city_ring/city_collision.res"
	var bytes := FileAccess.get_file_as_bytes(src)
	if bytes.is_empty():
		push_error("bake_city_collision: cannot read %s" % src)
		get_tree().quit(1)
		return
	var res: Resource = CollisionData.new()
	res.data = bytes
	var err := ResourceSaver.save(res, dst)
	print("[BAKE] %s → %s  bytes=%d err=%d" % [src, dst, bytes.size(), err])
	get_tree().quit(0 if err == OK else 1)
