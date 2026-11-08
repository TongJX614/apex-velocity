extends SceneTree
func _initialize() -> void:
	var ow := OpenWorld.new()
	root.add_child(ow)
	var t0 := Time.get_ticks_msec()
	ow._generate_heightfield()
	var t1 := Time.get_ticks_msec()
	ow._build_road_network()
	var t2 := Time.get_ticks_msec()
	ow._splat_roads_into_heightfield()
	var t3 := Time.get_ticks_msec()
	ow._generate_road_meshes()
	var t4 := Time.get_ticks_msec()
	ow._build_terrain()
	var t5 := Time.get_ticks_msec()
	print("TIMING heightfield=%d ms  roads=%d ms  splat=%d ms  meshes=%d ms  terrain=%d ms  TOTAL=%d ms" % [
		t1-t0, t2-t1, t3-t2, t4-t3, t5-t4, t5-t0])
	quit()
