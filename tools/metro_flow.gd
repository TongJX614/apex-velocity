extends Node
## 端到端验收：主菜单 → 都会环线（实景城市）→ 比赛。
## 产出 /tmp/city_inspect/menu_metro.png 与 race_metro.png，并打印贴图覆盖率与帧率。

const SHOT_MENU := "/tmp/city_inspect/menu_metro.png"
const SHOT_RACE := "/tmp/city_inspect/race_metro.png"


func _ready() -> void:
	_run()


func _count_facades(root: Node) -> int:
	if root == null:
		return -1
	var n := 0
	for node in root.find_children("*", "MeshInstance3D", true, false):
		if node.has_meta("city_facades_applied"):
			n += 1
	return n


func _run() -> void:
	await get_tree().process_frame
	var packed := load("res://scenes/main.tscn") as PackedScene
	if packed == null:
		print("[METRO-FLOW] cannot load main.tscn")
		get_tree().quit(1)
		return
	var main := packed.instantiate()
	add_child(main)
	var t0 := Time.get_ticks_msec()
	for i in 4000:
		await get_tree().process_frame
		if main.menu != null:
			break
		if Time.get_ticks_msec() - t0 > 60000:
			break
	print("[METRO-FLOW] boot->menu %d ms menu=%s" % [
		Time.get_ticks_msec() - t0, str(main.menu != null)])
	if main.menu == null:
		get_tree().quit(1)
		return

	var idx := -1
	for i in GameData.tracks.size():
		if String(GameData.tracks[i].get("id", "")) == "metro":
			idx = i
			break
	if idx < 0:
		print("[METRO-FLOW] metro track missing")
		get_tree().quit(1)
		return
	main.menu.track_index = idx
	main.menu.refresh()
	main._on_menu_track_changed("metro")
	var tw := Time.get_ticks_msec()
	for i in 900:
		await get_tree().process_frame
		if main.menu_world != null and main.menu_cam != null:
			break
	for i in 60:
		await get_tree().process_frame
	print("[METRO-FLOW] menu world=%s cam=%s city_facade_meshes=%d build=%dms" % [
		str(main.menu_world != null), str(main.menu_cam != null),
		_count_facades(main.menu_world), Time.get_ticks_msec() - tw])
	await RenderingServer.frame_post_draw
	_shot(SHOT_MENU)

	main.menu._start()
	for i in 5400:
		await get_tree().process_frame
		if main.hud != null and main.car != null:
			break
	for i in 180:
		await get_tree().process_frame
	var vp_cam := get_viewport().get_camera_3d()
	print("[METRO-FLOW] race: city=%s car.city=%s cam.world=%s vp_cam=%s hud=%s" % [
		str(main._city_world != null), str(main.car.city != null if main.car != null else false),
		str(main.cam.world if main.cam != null else false), str(vp_cam), str(main.hud != null)])
	var race_root: Node = main.race_root
	print("[METRO-FLOW] race facades=%d root=%s" % [
		_count_facades(race_root), str(race_root)])
	var fps_sum := 0.0
	for i in 120:
		await get_tree().process_frame
		fps_sum += Engine.get_frames_per_second()
	print("[METRO-FLOW] fps=%.1f" % (fps_sum / 120.0))
	await RenderingServer.frame_post_draw
	_shot(SHOT_RACE)
	get_tree().quit(0)


func _shot(path: String) -> void:
	var img := get_viewport().get_texture().get_image()
	if img == null:
		print("[METRO-FLOW] shot MISSED ", path)
		return
	var err := img.save_png(path)
	print("[METRO-FLOW] shot %s err=%d" % [path, err])
