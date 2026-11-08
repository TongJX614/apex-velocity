extends Node
## 端到端验收：主菜单 → 开放世界。
##
## 复现用户的真实路径（而不是直接调 `_start_race`）：
##   主菜单（选中「无界大陆」→ 大陆沙盘预览）→ 按「开始」→ 开放世界
##
## 验收三件事：
##   1. 菜单沙盘（300m 圆盘 + 8 条辐射支线 + 域标牌）必须被彻底拆掉，
##      否则玩家进场看到的是俯视沙盘，而不是驾驶视角；
##   2. 接管画面的必须是追尾相机（`viewport.get_camera_3d() == cam`）；
##   3. HUD 用的是赛道那一套 `RaceHUD`，右上角多一张无界大陆全域图。
##
## 运行：
##   godot --path . res://tools/ow_menu_flow.tscn
##
## 产出：
##   /tmp/ow_flow_menu.png   菜单里的沙盘（进场前）
##   /tmp/ow_flow_race.png   开放世界实拍（进场后）

const SHOT_MENU := "/tmp/ow_flow_menu.png"
const SHOT_RACE := "/tmp/ow_flow_race.png"


func _ready() -> void:
	_run()


func _run() -> void:
	await get_tree().process_frame
	var packed := load("res://scenes/main.tscn") as PackedScene
	if packed == null:
		print("[OW-FLOW] cannot load main.tscn")
		get_tree().quit(1)
		return
	var main := packed.instantiate()
	add_child(main)

	# 等启动画面走完 → 主菜单
	# 启动片头是按真实时间走的（1.5s + 每个快切 1~1.5s + 2.2s + 0.24s ≈ 11s），
	# 帧率不稳时按帧数等会误判，所以同时看真实时间。
	var t0 := Time.get_ticks_msec()
	for i in 4000:
		await get_tree().process_frame
		if main.menu != null:
			break
		if Time.get_ticks_msec() - t0 > 60000:
			break
	print("[OW-FLOW] boot->menu took %d ms, boot_screen=%s menu=%s" % [
		Time.get_ticks_msec() - t0, str(main.boot_screen != null), str(main.menu != null)])
	if main.menu == null:
		print("[OW-FLOW] menu never appeared")
		get_tree().quit(1)
		return

	# 菜单里切到「无界大陆」：这时菜单预览的是大陆沙盘
	var idx := -1
	for i in GameData.tracks.size():
		if String(GameData.tracks[i].get("id", "")) == "open_world":
			idx = i
			break
	if idx < 0:
		print("[OW-FLOW] open_world track missing")
		get_tree().quit(1)
		return
	main.menu.track_index = idx
	main.menu.refresh()
	main._on_menu_track_changed("open_world")
	for i in 300:
		await get_tree().process_frame
		if main.menu_cam != null:
			break

	var sandbox_cam := main.menu_cam as Camera3D
	print("[OW-FLOW] before start: menu_world=%s  menu_cam=%s  cam_current=%s" % [
		str(main.menu_world != null), str(sandbox_cam != null),
		str(sandbox_cam.current if sandbox_cam != null else false)])
	await RenderingServer.frame_post_draw
	_shot(SHOT_MENU)

	# 走真实入口：菜单「开始」→ main._on_menu_start → _start_race
	main.menu._start()

	# 等开放世界和 HUD 都建好（hud 是最后建的，所以它是完成标志）
	for i in 5400:
		await get_tree().process_frame
		if main.open_world != null and main.hud != null:
			break
	for i in 180:
		await get_tree().process_frame

	var vp_cam := get_viewport().get_camera_3d()
	var chase := main.cam as Camera3D
	var cam_dist := -1.0
	if chase != null and main.car != null:
		cam_dist = chase.global_position.distance_to((main.car as Node3D).global_position)
	print("[OW-FLOW] after start:")
	print("[OW-FLOW]   menu_world freed = %s" % str(main.menu_world == null))
	print("[OW-FLOW]   menu_cam freed   = %s" % str(main.menu_cam == null))
	print("[OW-FLOW]   chase cam        = %s  current=%s" % [
		str(chase != null), str(chase.current if chase != null else false)])
	print("[OW-FLOW]   viewport camera  = %s" % str(vp_cam))
	print("[OW-FLOW]   hud              = %s" % str(main.hud))
	print("[OW-FLOW]   state=%s  open_world_active=%s" % [
		str(int(main.state)), str(main.open_world_active)])
	print("[OW-FLOW]   camera->car dist = %.2f m" % cam_dist)
	await RenderingServer.frame_post_draw
	_shot(SHOT_RACE)
	get_tree().quit(0)


func _shot(path: String) -> void:
	var img := get_viewport().get_texture().get_image()
	if img == null:
		print("[OW-FLOW] shot MISSED ", path)
		return
	var err := img.save_png(path)
	print("[OW-FLOW] shot %s err=%d" % [path, err])
