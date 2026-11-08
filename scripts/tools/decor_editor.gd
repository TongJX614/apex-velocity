extends Node3D
## 场景装饰编辑器 —— 在 Godot 里直接点选、拖动、删除树木/建筑/道具。
##
## 启动：
##   Godot --path . -- --decor-edit --track=coast
##   Godot --path . -- --decor-edit --track=coast --decor-shot=/tmp/editor.png
##
## 工作方式：
##   装饰本来就是「固定种子程序化撒出来」的，同一条赛道每次生成顺序完全一致。
##   所以不需要把两万个实例全部烘焙成数据 —— 只要记下**用户改动过的那几条**：
##   (MultiMesh 节点名, 实例序号) → 新变换。游戏加载完场景后按同样的键找回去覆盖。
##
##   好处：没动过的装饰继续走程序化生成，零额外数据；动过的才进 override。
##   代价：改了 tracks.json 的赛道形状后，实例数量会变，旧 override 可能对不上，
##        这时需要重新编辑（编辑器会提示）。
##
## 操作：
##   左键        点选装饰
##   拖动        沿地面移动选中项
##   R / Shift+R 绕 Y 轴转 15°
##   [ / ]       缩小 / 放大 10%
##   Delete      删除（缩到 0 隐藏）
##   Ctrl+S      保存
##   WASD        移动相机，Q/E 升降
##   右键拖动    旋转视角
##   滚轮        推拉相机
##   Tab         切换「只看可编辑对象」

const OVERRIDE_DIR := "res://data/decor/overrides"
## 模型缩略图缓存目录。v1 是渲染参数版本号 —— 以后改了灯光/构图就改成 v2，
## 旧的缓存自然失效，不用手动清理。
const THUMB_DIR := "user://decor_thumbs/v1"
## 拾取最远距离：避免在近处点空时，误选中几百米外的树。
const PICK_MAX_DIST := 420.0
## 包围盒外扩容差（米）。树冠/树干在屏幕上很窄，不留容差几乎点不中。
const PICK_PAD := 0.45

var track_id := "coast"
var track_def: Dictionary = {}
var path: TrackPath
var cam: Camera3D

## 可编辑实例：{node: MultiMeshInstance3D, idx: int, xf: Transform3D, aabb: AABB, key: String}
var items: Array = []
## 同步组名 -> 该组下的全部 MultiMesh 节点（同一批实例的各个 surface）。
## 拖动时只查这张表，不再每帧遍历整棵场景树里的 200+ 个 MultiMesh 节点。
var _sync_index: Dictionary = {}
## override 表：key -> {p, q, s} ；不在表里 = 保持程序化原始位置
var edits: Dictionary = {}
## 被删除的 key 集合
var removed: Dictionary = {}
## 用户从项目库手动摆放的模型：id -> {id, asset, p, q, s}
var _added: Dictionary = {}
var _next_add_id := 1
var sel := -1

## 撤销 / 重做用整盘状态快照，而不是「反向命令」。
## 原因：删除是「记 removed + 把实例缩到 0.0001」，摆放是「新建节点树」，
## 这两种改动的逆操作形态完全不同；直接快照 edits/removed/added + 每个实例的变换，
## 还原时一次性对齐场景，既简单又不会漏掉某一类。
const UNDO_LIMIT := 80
var _undo: Array = []
var _redo: Array = []
## 上一次入栈的动作标签与时刻，用来把「按住 R 连转」「拖一下鼠标」合并成一步。
var _last_push_tag := ""
var _last_push_ms := 0
## 拖动是否已经入栈（避免「只点一下没拖动」也占掉一格撤销）
var _drag_pushed := false
## 内存状态是否和磁盘不一致（决定 Esc 退出要不要二次确认）
var _dirty := false
var _esc_armed := false
## HUD 最下面那行提示：撤销了什么、存了多少条
var _note := ""

## Tab 控制：是否显示「可编辑对象」的黄色标记点。
## 默认开着 —— 场景里绝大多数东西是程序化生成、不可选中的，
## 不把可编辑的那些标出来，用户会以为「什么都没有、根本没法编辑」。
var only_editable := true
var _hud: Label
var _markers: MultiMeshInstance3D
## 项目库模型浏览器
var _asset_list: ItemList
var _asset_names := PackedStringArray()
var _pending_asset := ""
# 缩略图：一次只渲染一个模型，逐帧跑完 74 个，不阻塞主线程
var _preview_tex: TextureRect
var _preview_name: Label
var _preview_info: Label
## asset -> ImageTexture（已渲染好的）
var _thumb_cache: Dictionary = {}
## asset -> [世界尺寸 Vector3]（渲染时顺手量出来，显示在预览下方）
var _thumb_size: Dictionary = {}
var _thumb_queue: Array = []
var _thumb_busy := false
var _thumb_vp: SubViewport
var _thumb_cam: Camera3D
var _thumb_subject: Node3D
## 列表索引 -> asset 名（搜索过滤后行号会变，不能靠行号反查）
var _list_assets: Array = []
## 预览区当前显示的是哪个模型
var _preview_asset := ""
## 鼠标是否正停在模型列表上（避免场景选中把预览抢回去）
var _list_hovering := false
## 导入模型
var _import_dlg: FileDialog
var _import_msg: Label
var _shot_path := ""
var _shot_frames := 0
var _selftest := false
var _addtest := false
var _applytest := false
var _rotest := false
var _importtest := false
var _undotest := false
var _diag := false


func _ready() -> void:
	_parse_args()
	_build_world()
	_setup_environment()
	_setup_camera()
	_setup_hud()
	_setup_asset_browser()
	# 顺序要点：先把用户之前摆过的模型重建出来，再统一收集索引，
	# 否则重开编辑器时自己放的东西会"消失"（程序化生成里本来就没有它们）。
	_load_overrides()
	_spawn_added_nodes()
	_collect_items()
	_apply_overrides()
	_ensure_markers()
	_update_hud()
	print("[EDITOR] track=%s items=%d edits=%d removed=%d" % [
		track_id, items.size(), edits.size(), removed.size()])
	if _diag:
		# 场景里每个 MultiMesh 资产的节点数/实例数，以及是否带可编辑标记。
		# 用来定位「我明明看得见这棵树却点不中」到底是因为没标记，还是因为不在索引里。
		var all_mm := {}
		var no_meta := 0
		for node in find_children("*", "MultiMeshInstance3D", true, false):
			var mmi := node as MultiMeshInstance3D
			if mmi == null or mmi.multimesh == null:
				continue
			var an := String(mmi.get_meta("decor_asset", "<NO-META>"))
			if an == "<NO-META>":
				no_meta += 1
				an = "? " + String(mmi.name).split("@")[0]
			var row: Array = all_mm.get(an, [0, 0])
			row[0] = int(row[0]) + 1
			row[1] = int(row[1]) + mmi.multimesh.instance_count
			all_mm[an] = row
		var keys: Array = all_mm.keys()
		keys.sort()
		for k in keys:
			var r: Array = all_mm[k]
			print("[MM] %-30s nodes=%3d instances=%5d" % [String(k), int(r[0]), int(r[1])])
		print("[MM] unmarked nodes=%d" % no_meta)
		var by_asset := {}
		for it in items:
			var a := _asset_of_item(it)
			by_asset[a] = int(by_asset.get(a, 0)) + 1
		print("[MM] editable items by asset: ", by_asset)
		# 某些资产明明有标记却没进索引，这里直接把它揪出来
		var indexed := {}
		for it in items:
			indexed[String(it["key"])] = true
		for node in find_children("*", "MultiMeshInstance3D", true, false):
			var mmi2 := node as MultiMeshInstance3D
			if mmi2 == null or not mmi2.has_meta("decor_asset"):
				continue
			var grp2 := "%s_g%d" % [String(mmi2.get_meta("decor_group", String(mmi2.name))),
				int(mmi2.get_meta("decor_chunk", 0))]
			if not indexed.has("MM:%s#0" % grp2):
				print("[MM] NOT-INDEXED %-42s grp=%s count=%d mesh=%s" % [
					String(mmi2.name), grp2,
					mmi2.multimesh.instance_count if mmi2.multimesh != null else -1,
					str(mmi2.multimesh.mesh != null) if mmi2.multimesh != null else "?"])

		for i in mini(items.size(), 12):
			var b: AABB = items[i]["aabb"]
			print("[DIAG] %-34s origin=%.1f,%.1f,%.1f  size=%.2f,%.2f,%.2f" % [
				String(items[i]["label"]), (items[i]["xf"] as Transform3D).origin.x,
				(items[i]["xf"] as Transform3D).origin.y, (items[i]["xf"] as Transform3D).origin.z,
				b.size.x, b.size.y, b.size.z])
		# 直接对比「节点全局变换」「实例局部变换」「合成结果」，定位坐标系断在哪一层
		var probe: Dictionary = items[0]
		var pnode: MultiMeshInstance3D = probe.get("node")
		if pnode != null and pnode.multimesh != null:
			print("[PROBE] node=%s count=%d" % [String(pnode.name), pnode.multimesh.instance_count])
			print("[PROBE] node.global_transform=", pnode.global_transform)
			print("[PROBE] instance[0]=", pnode.multimesh.get_instance_transform(0))
		print("[PROBE] item[0].xf=", probe.get("xf"))
		get_tree().quit(0)
		return

	if _selftest:
		_run_selftest()
		return
	if _addtest:
		_run_addtest()
		return
	if _applytest:
		_run_applytest()
		return
	if _rotest:
		_run_rotest()
		return
	if _importtest:
		_run_importtest()
		return
	if _undotest:
		_run_undotest()
		return
	if not _shot_path.is_empty():
		# 截图自检：跳到第一个可编辑对象，验证「聚焦 + 高亮框 + HUD」这条链路
		_cycle_item(1)


# ---------------------------------------------------------------------------
# 启动
# ---------------------------------------------------------------------------
func _parse_args() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--track="):
			track_id = arg.substr(8)
		elif arg.begins_with("--decor-shot="):
			_shot_path = arg.substr(13)
		elif arg == "--decor-selftest":
			_selftest = true
		elif arg == "--decor-diag":
			_diag = true
		elif arg == "--decor-addtest":
			_addtest = true
		elif arg == "--decor-applytest":
			_applytest = true
		elif arg == "--decor-rotest":
			_rotest = true
		elif arg == "--decor-importtest":
			_importtest = true
		elif arg == "--decor-undotest":
			_undotest = true


func _build_world() -> void:
	track_def = GameData.track(track_id)
	if track_def.is_empty():
		push_error("decor-editor: unknown track '%s'" % track_id)
		return
	path = TrackPath.new()
	path.build_from_def(track_def, 2.0)
	TrackBuilder.configure_terrain(path)

	var builder := TrackBuilder.new()
	builder.name = "TrackBuilder"
	add_child(builder)
	builder.build(track_def)

	SceneryKit.build(self, path, track_def)
	VenueKit.build(self, path, track_def, track_def.get("theme", {}))


func _setup_environment() -> void:
	var theme: Dictionary = track_def.get("theme", {})
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = _c(theme.get("skyTop", "#2a6bb8"))
	sky_mat.sky_horizon_color = _c(theme.get("skyHorizon", "#cfe6ea"))
	sky_mat.ground_bottom_color = _c(theme.get("skyBottom", "#8fc8d2"))
	sky_mat.ground_horizon_color = sky_mat.sky_horizon_color
	var sky := Sky.new()
	sky.sky_material = sky_mat

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = _c(theme.get("hemiSky", "#b4d8f8"))
	env.ambient_light_energy = 0.66
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 0.75
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.light_color = _c(theme.get("sunColor", "#fff2da"))
	sun.light_energy = 2.4
	sun.rotation_degrees = Vector3(-48, -35, 0)
	sun.shadow_enabled = false
	add_child(sun)


func _setup_camera() -> void:
	cam = Camera3D.new()
	cam.name = "EditorCamera"
	cam.fov = 62.0
	cam.far = 6000.0
	add_child(cam)
	cam.current = true
	_focus_on_start()


## 起始视角落在起跑线旁的路面上方。
## 以前是「俯视整条赛道」（海岸赛道跨度 710m，相机被抬到 440m 高空），
## 一棵 8m 高的树在 1600×900 的画面上只有十来个像素，鼠标根本压不中 ——
## 这是用户反馈「无法编辑」的直接原因。
func _focus_on_start() -> void:
	var anchor := Vector3.ZERO
	if path.samples.size() > 0:
		anchor = path.samples[0]
	var fwd := Vector3(0.0, 0.0, -1.0)
	if path.samples.size() > 4:
		var raw: Vector3 = path.samples[4] - path.samples[0]
		raw.y = 0.0
		if raw.length_squared() > 0.0001:
			fwd = raw.normalized()
	cam.position = anchor - fwd * 38.0 + Vector3(0.0, 17.0, 0.0)
	cam.look_at(anchor + Vector3(0.0, 3.0, 0.0), Vector3.UP)


func _bounds() -> Dictionary:
	var mn := Vector2(INF, INF)
	var mx := Vector2(-INF, -INF)
	for p in path.samples:
		mn.x = minf(mn.x, p.x); mn.y = minf(mn.y, p.z)
		mx.x = maxf(mx.x, p.x); mx.y = maxf(mx.y, p.z)
	return {
		"center": Vector3((mn.x + mx.x) * 0.5, 0.0, (mn.y + mx.y) * 0.5),
		"size": Vector3(mx.x - mn.x, 0.0, mx.y - mn.y),
	}


## 自检：移动一条装饰 → 保存 → 重新读回 → 校验落盘结果。
## 验证的是 override 链路（记录 / 序列化 / 反序列化），不涉及交互。
func _run_selftest() -> void:
	sel = _nearest_item_to(path.samples[0] if path.samples.size() > 0 else Vector3.ZERO)
	if sel < 0:
		print("[SELFTEST] FAIL: 没有可编辑装饰")
		get_tree().quit(1)
		return
	var it: Dictionary = items[sel]
	var key := String(it["key"])
	var before: Vector3 = (it["xf"] as Transform3D).origin
	var xf: Transform3D = it["xf"]
	# 挪到起跑线正前方 30m、离地 6m —— 一定在游戏首发视角的画面里
	xf.origin.x += 8.0
	xf.origin.y += 6.0
	xf.origin.z -= 30.0
	_write_xf(it, xf)
	_record(it, xf)
	print("[SELFTEST] moved '%s' %s -> %s" % [String(it["label"]), str(before), str(xf.origin)])
	print("[SELFTEST] save: ", _save_overrides())

	# 重新读回
	edits.clear()
	removed.clear()
	_load_overrides()
	if not edits.has(key):
		print("[SELFTEST] FAIL: 读回的 override 里找不到 key=", key)
		get_tree().quit(1)
		return
	var e: Dictionary = edits[key]
	var p: Array = e["p"]
	print("[SELFTEST] reloaded p=", p, "  expect x=%.2f" % xf.origin.x)
	var ok: bool = absf(float(p[0]) - xf.origin.x) < 0.02
	print("[SELFTEST] ", "PASS" if ok else "FAIL")
	get_tree().quit(0 if ok else 1)


## 自检：旋转是否真的累积、摆正是否真能归正。
## 用户反馈「按 R 转不正」，这里用可量化的角度断言把它锁住，
## 免得以后改动手感时又退化成「按 6 次只转 15°」。
func _run_rotest() -> void:
	if items.is_empty():
		print("[ROTEST] FAIL: 没有可编辑装饰")
		get_tree().quit(1)
		return
	sel = 0
	var it: Dictionary = items[0]
	var y0: float = rad_to_deg((it["xf"] as Transform3D).basis.orthonormalized().get_euler().y)
	for i in 6:
		_rotate_sel(15.0)
	var y1: float = rad_to_deg((items[0]["xf"] as Transform3D).basis.orthonormalized().get_euler().y)
	var delta := fposmod(y1 - y0, 360.0)
	print("[ROTEST] yaw %.2f -> %.2f  delta=%.2f  (expect 90)" % [y0, y1, delta])
	var ok_rot: bool = absf(delta - 90.0) < 0.5

	# 缩放也要累积：连按 3 次 1.1 应该是 1.331，而不是一直停在 1.1
	var s0: Vector3 = (items[0]["xf"] as Transform3D).basis.get_scale()
	for i in 3:
		_scale_sel(1.1)
	var s1: Vector3 = (items[0]["xf"] as Transform3D).basis.get_scale()
	print("[ROTEST] scale %.3f -> %.3f  (expect %.3f)" % [s0.x, s1.x, s0.x * 1.331])
	var ok_scale: bool = absf(s1.x - s0.x * 1.331) < 0.01

	# 人为把模型转歪（绕世界 X 轴 25°），再按 G 摆正。
	# 判据用「物体本地 UP 轴与世界 UP 的夹角」，比欧拉角分解稳健 ——
	# 欧拉角在 yaw 接近 90° 时会把倾斜摊到别的轴上，看起来像没歪。
	var xf2: Transform3D = items[0]["xf"]
	xf2.basis = Basis(Vector3.RIGHT, deg_to_rad(25.0)) * xf2.basis
	_write_xf(items[0], xf2)
	var tilt_before: float = rad_to_deg(
		(items[0]["xf"] as Transform3D).basis.orthonormalized().y.angle_to(Vector3.UP))
	_upright_sel()
	var tilt_after: float = rad_to_deg(
		(items[0]["xf"] as Transform3D).basis.orthonormalized().y.angle_to(Vector3.UP))
	print("[ROTEST] upright: tilt %.2f -> %.2f (expect 25 -> 0)" % [tilt_before, tilt_after])
	var ok_up: bool = tilt_before > 20.0 and tilt_after < 0.5

	print("[ROTEST] ", "PASS" if (ok_rot and ok_scale and ok_up) else "FAIL")
	get_tree().quit(0 if (ok_rot and ok_scale and ok_up) else 1)


## 自检：撤销 / 重做。四条路径都要能还原 —— 移动、旋转、删除、摆放。
## 任何一条只改了「内存里的表」而没同步到场景，这里就会炸出来。
func _run_undotest() -> void:
	if items.is_empty():
		print("[UNDOTEST] FAIL: 没有可编辑装饰")
		get_tree().quit(1)
		return
	var ok := true

	# ---- 1) 移动 → 撤销 → 重做 ----
	var key := String(items[0]["key"])
	var p0: Vector3 = (items[0]["xf"] as Transform3D).origin
	sel = 0
	_push_undo("")
	var it = items[0]
	var xf: Transform3D = it["xf"]
	xf.origin += Vector3(9.0, 0.0, 0.0)
	_write_xf(it, xf)
	_record(it, xf)
	var p1: Vector3 = (_find_item(key)["xf"] as Transform3D).origin
	_undo_step()
	var pa: Vector3 = (_find_item(key)["xf"] as Transform3D).origin
	_redo_step()
	var pb: Vector3 = (_find_item(key)["xf"] as Transform3D).origin
	var ok_move: bool = p1.distance_to(p0) > 8.0 and pa.distance_to(p0) < 0.02 \
		and pb.distance_to(p0 + Vector3(9.0, 0.0, 0.0)) < 0.05
	print("[UNDOTEST] move  x: %.2f -> %.2f -> undo %.2f -> redo %.2f  %s" % [
		p0.x, p1.x, pa.x, pb.x, "OK" if ok_move else "FAIL"])
	ok = ok and ok_move

	# ---- 2) 连续旋转三次只算一步，一次撤销要全退回去 ----
	var yaw0: float = rad_to_deg(
		(_find_item(key)["xf"] as Transform3D).basis.orthonormalized().get_euler().y)
	sel = _index_of(key)
	for i in 3:
		_rotate_sel(15.0)
	var yaw_mid: float = rad_to_deg(
		(_find_item(key)["xf"] as Transform3D).basis.orthonormalized().get_euler().y)
	_undo_step()
	var yaw1: float = rad_to_deg(
		(_find_item(key)["xf"] as Transform3D).basis.orthonormalized().get_euler().y)
	var ok_rot: bool = absf(fposmod(yaw1 - yaw0, 360.0)) < 0.5 \
		and absf(fposmod(yaw_mid - yaw0, 360.0) - 45.0) < 1.0
	print("[UNDOTEST] rotate yaw %.2f -> %.2f -> undo %.2f  (expect +45 then 回原样)  %s" % [
		yaw0, yaw_mid, yaw1, "OK" if ok_rot else "FAIL"])
	ok = ok and ok_rot

	# ---- 3) 删掉一个程序化装饰 → 撤销后必须回到原位 ----
	sel = _index_of(key)
	var before_p: Vector3 = (_find_item(key)["xf"] as Transform3D).origin
	_delete_sel()
	var marked: bool = removed.has(key)
	_undo_step()
	var back_it := _find_item(key)
	var ok_del: bool = marked and not removed.has(key) and not back_it.is_empty()
	if ok_del:
		var after_p: Vector3 = (back_it["xf"] as Transform3D).origin
		ok_del = after_p.distance_to(before_p) < 0.02
	print("[UNDOTEST] delete  marked=%s restored=%s  %s" % [
		str(marked), str(not back_it.is_empty() and not removed.has(key)),
		"OK" if ok_del else "FAIL"])
	ok = ok and ok_del

	# ---- 4) 摆放模型 → 撤销（节点要消失）→ 重做（节点要回来）----
	var id := _place_asset_at("buoy_real", Vector3(6.0, 4.0, -18.0))
	var node_name := "Added_" + id
	if id.is_empty():
		print("[UNDOTEST] place FAIL: 放不上去")
		ok = false
	else:
		var live := not find_children(node_name, "Node3D", true, false).is_empty()
		_undo_step()
		var gone := find_children(node_name, "Node3D", true, false).is_empty() \
			and not _added.has(id)
		_redo_step()
		var again := not find_children(node_name, "Node3D", true, false).is_empty() \
			and _added.has(id)
		var ok_add: bool = live and gone and again
		print("[UNDOTEST] place   live=%s undo_gone=%s redo_back=%s  %s" % [
			str(live), str(gone), str(again), "OK" if ok_add else "FAIL"])
		ok = ok and ok_add

	# ---- 5) 按键路由：Ctrl/Cmd+Z 撤销、再加 Shift 重做 ----
	sel = _index_of(key)
	var kp0: Vector3 = (_find_item(key)["xf"] as Transform3D).origin
	_push_undo("")
	var k_it = items[sel]
	var k_xf: Transform3D = k_it["xf"]
	k_xf.origin += Vector3(0.0, 5.0, 0.0)
	_write_xf(k_it, k_xf)
	_record(k_it, k_xf)
	_send_key(KEY_Z, false)
	var y_undo: float = (_find_item(key)["xf"] as Transform3D).origin.y
	_send_key(KEY_Z, true)
	var y_redo: float = (_find_item(key)["xf"] as Transform3D).origin.y
	var ok_key: bool = absf(y_undo - kp0.y) < 0.02 and absf(y_redo - (kp0.y + 5.0)) < 0.05
	print("[UNDOTEST] hotkey  undo_y=%.2f redo_y=%.2f (expect %.2f / %.2f)  %s" % [
		y_undo, y_redo, kp0.y, kp0.y + 5.0, "OK" if ok_key else "FAIL"])
	ok = ok and ok_key

	print("[UNDOTEST] ", "PASS" if ok else "FAIL")
	get_tree().quit(0 if ok else 1)


## 造一个按键事件直接喂给 _input —— 用来验证「Cmd/Ctrl+Z」这条路由没接反。
func _send_key(code: Key, shift: bool) -> void:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.physical_keycode = code
	ev.pressed = true
	ev.ctrl_pressed = true
	ev.meta_pressed = true
	ev.shift_pressed = shift
	_input(ev)


## 自检：导入外部 .glb 的完整链路
##   拷文件 → 刷新列表 → GLTFDocument 运行时解析 → 量尺寸 → 摆放 → 清理
func _run_importtest() -> void:
	var src_asset := "realtree_02"
	var probe_asset := "zz_import_probe"
	var src := ProjectSettings.globalize_path(RealAssetKit.ROOT + src_asset + ".glb")
	var tmp := "/tmp/zz_import_probe.glb"
	var bytes := FileAccess.get_file_as_bytes(src)
	if bytes.is_empty():
		print("[IMPTEST] FAIL: 读不到源模型 ", src)
		get_tree().quit(1)
		return
	var w := FileAccess.open(tmp, FileAccess.WRITE)
	if w == null:
		print("[IMPTEST] FAIL: 无法写 /tmp")
		get_tree().quit(1)
		return
	w.store_buffer(bytes)
	w.close()

	_import_model(tmp)
	var in_list := _asset_names.has(probe_asset)
	var has_file := FileAccess.file_exists(RealAssetKit.ROOT + probe_asset + ".glb")
	var dim := RealAssetKit.size(probe_asset)
	var dim_ok := dim.length() > 0.01
	print("[IMPTEST] list=%s file=%s size=%.2f,%.2f,%.2f" % [
		str(in_list), str(has_file), dim.x, dim.y, dim.z])

	# 真的摆一个出来，确认能实例化、能被编辑器重新收集
	var node := RealAssetKit.place_unique(self, probe_asset,
		Transform3D(Basis(), Vector3(20.0, 0.0, 20.0)), "Added_probe")
	var placed := node != null
	print("[IMPTEST] place_unique -> %s" % str(placed))

	# 清理现场
	if node != null:
		node.get_parent().remove_child(node)
		node.queue_free()
	var abs_dst := ProjectSettings.globalize_path(RealAssetKit.ROOT + probe_asset + ".glb")
	DirAccess.remove_absolute(abs_dst)
	var abs_png := ProjectSettings.globalize_path(_thumb_path(probe_asset))
	DirAccess.remove_absolute(abs_png)
	DirAccess.remove_absolute(tmp)
	RealAssetKit.clear_cache()
	_scan_assets()
	print("[IMPTEST] cleaned up")

	var ok := in_list and has_file and dim_ok and placed
	print("[IMPTEST] ", "PASS" if ok else "FAIL")
	get_tree().quit(0 if ok else 1)


## 自检：从项目库放一个模型 → 保存 → 重新读回 → 确认能被重新收集到。
## 验证「新增模型」这条完整链路（实例化 / 记录 / 序列化 / 反序列化 / 再索引）。
func _run_addtest() -> void:
	var asset := "realtree_01"
	if not RealAssetKit.has(asset):
		print("[ADDTEST] FAIL: 项目库里没有 ", asset)
		get_tree().quit(1)
		return
	var p := Vector3(12.0, 0.0, 8.0)
	if Terrain.active:
		p.y = Terrain.height_at(p)
	var id := "a%d" % _next_add_id
	_next_add_id += 1
	var node := RealAssetKit.place_unique(self, asset, Transform3D(Basis(), p), "Added_" + id)
	if node == null:
		print("[ADDTEST] FAIL: 实例化失败 ", asset)
		get_tree().quit(1)
		return
	_added[id] = {
		"id": id,
		"asset": asset,
		"p": [snappedf(p.x, 0.01), snappedf(p.y, 0.01), snappedf(p.z, 0.01)],
		"q": [0.0, 0.0, 0.0, 1.0],
		"s": [1.0, 1.0, 1.0],
	}
	print("[ADDTEST] placed %s as %s at %s" % [asset, id, str(p)])
	print("[ADDTEST] save: ", _save_overrides())

	# 从磁盘重新读回，模拟下次启动
	_added.clear()
	_next_add_id = 1
	_load_overrides()
	if not _added.has(id):
		print("[ADDTEST] FAIL: 读回后找不到 ", id)
		get_tree().quit(1)
		return
	print("[ADDTEST] reloaded ids=%s next=%d" % [str(_added.keys()), _next_add_id])

	# 再确认场景索引里确实能收到它
	_rescan()
	var found := false
	for it in items:
		if String(it["key"]).ends_with("Added_" + id):
			found = true
			break
	print("[ADDTEST] items=%d found_in_scene=%s" % [items.size(), str(found)])
	print("[ADDTEST] ", "PASS" if found else "FAIL")
	get_tree().quit(0 if found else 1)


## 自检：验证游戏端走的 DecorOverrides.apply 能真正把新增模型重建出来。
## 编辑器自己用的是私有 _apply_overrides，测不到共用层，所以单独测一次。
func _run_applytest() -> void:
	# 先清掉场景里已存在的 Added_* 节点，模拟「游戏刚启动、什么都没摆」
	for node in find_children("Added_*", "Node3D", true, false):
		var parent := node.get_parent()
		if parent != null:
			parent.remove_child(node)
		node.free()
	var before := find_children("Added_*", "Node3D", true, false).size()
	var applied := DecorOverrides.apply(self, track_id)
	var after := find_children("Added_*", "Node3D", true, false).size()
	print("[APPLYTEST] applied=%d  Added nodes %d -> %d" % [applied, before, after])
	var ok := after >= 1
	print("[APPLYTEST] ", "PASS" if ok else "FAIL")
	get_tree().quit(0 if ok else 1)


## 找离某个世界坐标最近的装饰（截图自检用）
func _nearest_item_to(p: Vector3) -> int:
	var best := -1
	var bestd := INF
	for i in items.size():
		var box: AABB = items[i]["aabb"]
		var o: Vector3 = box.position + box.size * 0.5
		var d := o.distance_squared_to(p)
		if d < bestd:
			bestd = d
			best = i
	return best


func _c(v: Variant, fallback: Color = Color.WHITE) -> Color:
	if v is Color:
		return v
	if v is String and (v as String).begins_with("#"):
		return Color(v)
	return fallback


# ---------------------------------------------------------------------------
# 收集可编辑实例
# ---------------------------------------------------------------------------
## 草是两万个实例、且不需要手改，直接跳过。剩下的树 / 灌木 / 建筑 / 道具
## 加起来通常在 300~900 之间，这个量级才适合手点。
func _is_grass(n: String) -> bool:
	return n.begins_with("RealGrass") or n.begins_with("Grass")


## 地形基面、海、起跑格、胎痕：这些是赛道的组成部分，不是可以搬走的装饰。
func _is_base_terrain(n: String) -> bool:
	for bad in ["Ground", "Beach", "Sea", "Water", "StartGrid", "TireMarks",
			"FarGround", "Hills", "Track", "Road", "CenterLine", "Kerb", "Curb",
			"LaneMark", "Marking", "Line", "Grid", "Skid"]:
		if n.begins_with(bad):
			return true
	return false


func _collect_items() -> void:
	items.clear()
	_sync_index.clear()

	# 唯一可靠的识别方式：RealAssetKit 摆放时打的 decor_asset 标记。
	# 靠节点名猜（Ground / LaneMarking / @MeshInstance3D@82…）会一直误收基面构件。
	# 1) MultiMesh 实例（树、灌木、海滩道具…）
	for node in find_children("*", "MultiMeshInstance3D", true, false):
		var mmi := node as MultiMeshInstance3D
		if mmi == null or mmi.multimesh == null or mmi.multimesh.mesh == null:
			continue
		if not mmi.has_meta("decor_asset"):
			continue
		var asset := String(mmi.get_meta("decor_asset"))
		if RealAssetKit.category_of(asset).is_empty():
			continue   # 草：两万个，不参与手改
		var n := mmi.multimesh.instance_count
		var mesh_aabb := mmi.multimesh.mesh.get_aabb()
		# 同一资产的 s0/s1/s2 是三个节点、装同一批实例；key 只按 (group, chunk) 区分，
		# 编辑时把同一 key 的所有 surface 一起改，否则树会「只有一个面飞走」。
		var grp := "%s_g%d" % [String(mmi.get_meta("decor_group", String(mmi.name))),
			int(mmi.get_meta("decor_chunk", 0))]
		if not _sync_index.has(grp):
			_sync_index[grp] = []
		(_sync_index[grp] as Array).append(mmi)
		var node_xf := mmi.global_transform
		for i in n:
			# MultiMesh 的实例变换是局部坐标，统一换算成世界坐标再参与拾取/编辑
			var xf := node_xf * mmi.multimesh.get_instance_transform(i)
			items.append({
				"node": mmi,
				"idx": i,
				"xf": xf,
				"aabb": xf * mesh_aabb,
				"key": "MM:%s#%d" % [grp, i],
				"label": "%s (%s)" % [asset, grp],
				"group": grp,
			})

	# 同一 key 只保留一条（多个 surface 共享同一批实例）
	var seen := {}
	var dedup: Array = []
	for it in items:
		var k := String(it["key"])
		if seen.has(k):
			continue
		seen[k] = true
		dedup.append(it)
	items = dedup

	# 2) 独立节点（楼体、看台、广告牌…）
	var roots := {}
	for node in find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		var root := _decor_root(mi)
		if root == null or not root.has_meta("decor_asset"):
			continue
		roots[root.get_instance_id()] = root

	for id in roots.keys():
		var r: Node3D = roots[id]
		var merged := _merged_aabb(r)
		items.append({
			"node": r,
			"idx": -1,
			"xf": r.global_transform,
			"aabb": merged,
			"key": "ND:%s" % String(r.name),
			"label": "%s (%s)" % [String(r.get_meta("decor_asset")), String(r.name)],
		})

	print("[EDITOR] collected %d editable instances (%d multimesh nodes, %d unique nodes)" % [
		items.size(), find_children("*", "MultiMeshInstance3D", true, false).size(), roots.size()])
	# 记下自己在 items 里的下标，方便同步头顶标记
	for i in items.size():
		items[i]["i"] = i


## 往上找到最近的、带 decor_asset 标记的祖先 —— 那就是一个完整的装饰实例。
func _decor_root(mi: Node) -> Node3D:
	var cur: Node = mi
	var guard := 0
	while cur != null and guard < 24:
		if cur.has_meta("decor_asset"):
			return cur as Node3D
		cur = cur.get_parent()
		guard += 1
	return null


## 装饰根下所有表面合并成的世界包围盒。
func _merged_aabb(root: Node3D) -> AABB:
	var box := AABB()
	var first := true
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		var a := mi.global_transform * mi.mesh.get_aabb()
		if first:
			box = a
			first = false
		else:
			box = box.merge(a)
	if first:
		return AABB(root.global_position - Vector3.ONE, Vector3.ONE * 2.0)
	return box


# ---------------------------------------------------------------------------
# override 读写
# ---------------------------------------------------------------------------
func _override_file() -> String:
	return "%s/%s.json" % [OVERRIDE_DIR, track_id]


func _load_overrides() -> void:
	edits.clear()
	removed.clear()
	_added.clear()
	_next_add_id = 1
	var f := FileAccess.open(_override_file(), FileAccess.READ)
	if f == null:
		return
	var doc = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(doc) != TYPE_DICTIONARY:
		return
	for e in doc.get("edits", []):
		var key := String(e.get("key", ""))
		if key.is_empty():
			continue
		edits[key] = e
	for k in doc.get("removed", []):
		removed[String(k)] = true
	for a in doc.get("added", []):
		var id := String(a.get("id", ""))
		if id.is_empty():
			continue
		_added[id] = a
		# id 形如 a1 / a2，确保新分配的编号不会撞上已有的
		_next_add_id = maxi(_next_add_id, int(id.substr(1)) + 1)


func _save_overrides() -> String:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OVERRIDE_DIR))
	var arr: Array = []
	for key in edits.keys():
		arr.append(edits[key])
	var del: Array = []
	for k in removed.keys():
		del.append(k)
	var add: Array = []
	for k in _added.keys():
		add.append(_added[k])
	var doc := {"track": track_id, "edits": arr, "removed": del, "added": add}
	var f := FileAccess.open(_override_file(), FileAccess.WRITE)
	if f == null:
		return "写入失败: " + _override_file()
	f.store_string(JSON.stringify(doc, "  "))
	f.close()
	return "已保存 %d 处修改 / %d 处删除 / %d 个新增 → %s" % [
		arr.size(), del.size(), add.size(), _override_file()]


## 把 override 应用到已生成的实例上。游戏里也调用这个函数。
func _apply_overrides() -> void:
	for key in edits.keys():
		var e: Dictionary = edits[key]
		var it := _find_item(key)
		if it.is_empty():
			continue
		var xf: Transform3D = _xf_from(e, it["xf"] as Transform3D)
		_write_xf(it, xf)
	for key in removed.keys():
		var it := _find_item(key)
		if it.is_empty():
			continue
		var xf: Transform3D = it["xf"]
		_write_xf(it, Transform3D(xf.basis.scaled(Vector3.ONE * 0.0001), xf.origin))


func _find_item(key: String) -> Dictionary:
	for it in items:
		if String(it["key"]) == key:
			return it
	return {}


func _index_of(key: String) -> int:
	for i in items.size():
		if String(items[i]["key"]) == key:
			return i
	return -1


## 把 override 里记录的「手动摆放的模型」重建到场景里。
func _spawn_added_nodes() -> void:
	for id in _added.keys():
		var node_name := "Added_" + String(id)
		if not find_children(node_name, "Node3D", true, false).is_empty():
			continue
		DecorOverrides.spawn_added(self, _added[id])


func _write_xf(it: Dictionary, xf: Transform3D) -> void:
	it["xf"] = xf
	it["aabb"] = xf * _mesh_aabb(it)
	var node = it["node"]
	if node is MultiMeshInstance3D and int(it["idx"]) >= 0:
		# 同一 group 的所有 surface 都要改，否则模型只剩一个面跟着动
		var idx := int(it["idx"])
		var peers: Array = _sync_index.get(String(it.get("group", "")), [])
		for peer in peers:
			var mmi := peer as MultiMeshInstance3D
			if mmi == null or mmi.multimesh == null or idx >= mmi.multimesh.instance_count:
				continue
			mmi.multimesh.set_instance_transform(idx, mmi.global_transform.affine_inverse() * xf)
	elif node is Node3D:
		(node as Node3D).global_transform = xf

	# 头顶标记跟着一起走，否则按 Tab 看到的分布图会和实际位置对不上
	if _markers != null:
		var mi_idx := int(it.get("i", -1))
		if mi_idx >= 0 and mi_idx < _markers.multimesh.instance_count:
			_markers.multimesh.set_instance_transform(mi_idx, _marker_xf(it["aabb"]))


func _mesh_aabb(it: Dictionary) -> AABB:
	var node = it["node"]
	if node is MultiMeshInstance3D:
		return (node as MultiMeshInstance3D).multimesh.mesh.get_aabb()
	if node is MeshInstance3D:
		return (node as MeshInstance3D).mesh.get_aabb()
	return AABB(Vector3(-0.5, 0, -0.5), Vector3.ONE)


func _xf_from(e: Dictionary, base: Transform3D) -> Transform3D:
	var p: Array = e.get("p", [])
	var q: Array = e.get("q", [])
	var s: Array = e.get("s", [])
	var origin := base.origin
	var basis := base.basis
	if p.size() == 3:
		origin = Vector3(float(p[0]), float(p[1]), float(p[2]))
	if q.size() == 4:
		basis = Basis(Quaternion(float(q[0]), float(q[1]), float(q[2]), float(q[3])))
		if s.size() == 3:
			basis = basis.scaled(Vector3(float(s[0]), float(s[1]), float(s[2])))
	elif s.size() == 3:
		basis = basis.scaled(Vector3(float(s[0]), float(s[1]), float(s[2])))
	return Transform3D(basis, origin)


func _record(it: Dictionary, xf: Transform3D) -> void:
	var key := String(it["key"])
	var q := xf.basis.get_rotation_quaternion()
	var s := xf.basis.get_scale()
	edits[key] = {
		"key": key,
		"label": String(it["label"]),
		"p": [snappedf(xf.origin.x, 0.01), snappedf(xf.origin.y, 0.01), snappedf(xf.origin.z, 0.01)],
		"q": [snappedf(q.x, 0.0001), snappedf(q.y, 0.0001), snappedf(q.z, 0.0001), snappedf(q.w, 0.0001)],
		"s": [snappedf(s.x, 0.0001), snappedf(s.y, 0.0001), snappedf(s.z, 0.0001)],
	}
	removed.erase(key)


# ---------------------------------------------------------------------------
# 撤销 / 重做
# ---------------------------------------------------------------------------
## 整盘状态快照。items 里每个实例的变换直接存世界坐标 —— 还原时不用再推
## 「这个位置是程序化原始的还是我改过的」，照着快照写一遍就行。
func _snapshot() -> Dictionary:
	var xf_map := {}
	for it in items:
		xf_map[String(it["key"])] = it["xf"] as Transform3D
	var sel_key := ""
	if sel >= 0 and sel < items.size():
		sel_key = String(items[sel]["key"])
	return {
		"edits": edits.duplicate(true),
		"removed": removed.duplicate(true),
		"added": _added.duplicate(true),
		"next": _next_add_id,
		"xf": xf_map,
		"sel": sel_key,
	}


## 在改动之前调用。tag 相同且间隔 < 900ms 视为同一次连续手势
## （按住 R 连转、鼠标拖一下），不重复入栈 —— 否则一次连转能塞进几十步撤销，
## 用户按 Ctrl+Z 得按到手软。
func _push_undo(tag: String) -> void:
	_note = ""
	_dirty = true
	_esc_armed = false
	var now := Time.get_ticks_msec()
	if not tag.is_empty() and tag == _last_push_tag and now - _last_push_ms < 900:
		_last_push_ms = now
		return
	_undo.append(_snapshot())
	if _undo.size() > UNDO_LIMIT:
		_undo.pop_front()
	_redo.clear()
	_last_push_tag = tag
	_last_push_ms = now


func _undo_step() -> void:
	if _undo.is_empty():
		_note = "没有可撤销的操作了"
		_update_hud()
		return
	_redo.append(_snapshot())
	_restore(_undo.pop_back())
	_last_push_tag = ""
	_note = "已撤销 · 还可撤销 %d 步 / 可重做 %d 步" % [_undo.size(), _redo.size()]
	_update_hud()


func _redo_step() -> void:
	if _redo.is_empty():
		_note = "没有可重做的操作"
		_update_hud()
		return
	_undo.append(_snapshot())
	_restore(_redo.pop_back())
	_last_push_tag = ""
	_note = "已重做 · 还可撤销 %d 步 / 可重做 %d 步" % [_undo.size(), _redo.size()]
	_update_hud()


## 把快照灌回场景：先对齐「手动摆放的模型」的节点，再重收索引，最后逐个写变换。
## 顺序不能反 —— 新增节点变了，items 的下标会整体位移。
func _restore(snap: Dictionary) -> void:
	edits = (snap["edits"] as Dictionary).duplicate(true)
	removed = (snap["removed"] as Dictionary).duplicate(true)
	_added = (snap["added"] as Dictionary).duplicate(true)
	_next_add_id = int(snap["next"])

	_reconcile_added_nodes()
	_collect_items()
	if _markers != null:
		_markers.queue_free()
		_markers = null
	_ensure_markers()

	var xf_map: Dictionary = snap["xf"]
	for it in items:
		var k := String(it["key"])
		if xf_map.has(k):
			_write_xf(it, xf_map[k])

	sel = -1
	var want := String(snap["sel"])
	if not want.is_empty():
		for i in items.size():
			if String(items[i]["key"]) == want:
				sel = i
				break
	_dirty = true


## 让场景里的 Added_* 节点和 _added 记录对齐：
## 记录里没有的销毁（撤销一次「摆放」），记录里有但场景没有的重建（撤销一次「删除」）。
func _reconcile_added_nodes() -> void:
	for node in find_children("Added_*", "Node3D", true, false):
		var id := String(node.name).substr(6)
		if _added.has(id):
			continue
		var par := node.get_parent()
		if par != null:
			par.remove_child(node)
		node.queue_free()
	for id in _added.keys():
		if find_children("Added_" + String(id), "Node3D", true, false).is_empty():
			DecorOverrides.spawn_added(self, _added[id])


# ---------------------------------------------------------------------------
# HUD
# ---------------------------------------------------------------------------
func _setup_hud() -> void:
	var layer := CanvasLayer.new()
	layer.name = "EditorHUD"
	add_child(layer)
	var panel := PanelContainer.new()
	panel.position = Vector2(16, 16)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.04, 0.06, 0.08, 0.86)
	sb.border_color = Color(0.12, 0.2, 0.25)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(12)
	panel.add_theme_stylebox_override("panel", sb)
	layer.add_child(panel)
	_hud = Label.new()
	_hud.add_theme_font_size_override("font_size", 13)
	_hud.add_theme_color_override("font_color", Color(0.86, 0.91, 0.93))
	panel.add_child(_hud)


# ---------------------------------------------------------------------------
# 项目库模型浏览器
# ---------------------------------------------------------------------------
## 右侧列出 res://assets/venues 下的全部 .glb。选中一个 → 进入放置模式，
## 在地面点一下就把它摆上去；摆上去的模型和程序化装饰一样能被选中、移动、缩放、删除。
func _setup_asset_browser() -> void:
	var layer := CanvasLayer.new()
	layer.name = "AssetBrowser"
	layer.layer = 2
	add_child(layer)

	var panel := PanelContainer.new()
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.anchor_top = 0.0
	panel.anchor_bottom = 1.0
	panel.offset_left = -300.0
	panel.offset_right = -14.0
	panel.offset_top = 14.0
	panel.offset_bottom = -14.0
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.04, 0.06, 0.08, 0.9)
	sb.border_color = Color(0.12, 0.2, 0.25)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(10)
	panel.add_theme_stylebox_override("panel", sb)
	layer.add_child(panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	panel.add_child(vb)

	var title := Label.new()
	title.text = "项目库模型"
	title.add_theme_font_size_override("font_size", 14)
	title.add_theme_color_override("font_color", Color(0.86, 0.91, 0.93))
	vb.add_child(title)

	var search := LineEdit.new()
	search.placeholder_text = "搜索模型名…"
	search.text_changed.connect(_on_search_changed)
	vb.add_child(search)

	# 导入自己的模型：选一个 .glb 拷进 assets/venues，立刻出现在列表里可用。
	var import_btn := Button.new()
	import_btn.text = "＋ 导入模型（.glb）"
	import_btn.tooltip_text = "把本机的 .glb 拷进项目 assets/venues，马上就能摆放"
	import_btn.pressed.connect(_on_import_pressed)
	vb.add_child(import_btn)

	_import_msg = Label.new()
	_import_msg.add_theme_font_size_override("font_size", 10)
	_import_msg.add_theme_color_override("font_color", Color(0.55, 0.78, 0.62))
	_import_msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_import_msg.visible = false
	vb.add_child(_import_msg)

	# —— 预览区：鼠标在列表里划过哪个就显示哪个，选中的也一直挂着 ——
	# 只有名字根本认不出东西（74 个 glb 里一堆 facade_a / facade_b），
	# 所以这里用离屏渲染把每个模型拍成缩略图，缓存在 user:// 下。
	var pv_frame := PanelContainer.new()
	var pv_sb := StyleBoxFlat.new()
	pv_sb.bg_color = Color(0.07, 0.1, 0.13, 0.9)
	pv_sb.border_color = Color(0.16, 0.24, 0.3)
	pv_sb.set_border_width_all(1)
	pv_sb.set_corner_radius_all(4)
	pv_frame.add_theme_stylebox_override("panel", pv_sb)
	vb.add_child(pv_frame)

	var pv_box := VBoxContainer.new()
	pv_box.add_theme_constant_override("separation", 4)
	pv_frame.add_child(pv_box)

	_preview_tex = TextureRect.new()
	_preview_tex.custom_minimum_size = Vector2(0, 156)
	_preview_tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_preview_tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	pv_box.add_child(_preview_tex)

	_preview_name = Label.new()
	_preview_name.text = "—"
	_preview_name.add_theme_font_size_override("font_size", 12)
	_preview_name.add_theme_color_override("font_color", Color(0.86, 0.91, 0.93))
	_preview_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_preview_name.clip_text = true
	pv_box.add_child(_preview_name)

	_preview_info = Label.new()
	_preview_info.text = "把鼠标移到模型名上看样子"
	_preview_info.add_theme_font_size_override("font_size", 10)
	_preview_info.add_theme_color_override("font_color", Color(0.55, 0.63, 0.68))
	_preview_info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	pv_box.add_child(_preview_info)

	_asset_list = ItemList.new()
	_asset_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_asset_list.add_theme_font_size_override("font_size", 12)
	_asset_list.fixed_icon_size = Vector2i(36, 36)
	_asset_list.icon_mode = ItemList.ICON_MODE_LEFT
	_asset_list.item_selected.connect(_on_asset_selected)
	# 悬停就换预览图 —— 不用先选中再去别处看
	if _asset_list.has_signal("item_mouse_entered"):
		_asset_list.item_mouse_entered.connect(_on_asset_hovered)
	_asset_list.mouse_exited.connect(_on_list_mouse_exited)
	vb.add_child(_asset_list)

	var hint := Label.new()
	hint.text = "选中后在地面点击放置，可连续摆放；Esc 取消"
	hint.add_theme_font_size_override("font_size", 11)
	hint.add_theme_color_override("font_color", Color(0.58, 0.66, 0.7))
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vb.add_child(hint)

	_scan_assets()
	_setup_thumb_rig()
	_fill_asset_list("")


func _scan_assets() -> void:
	_asset_names = PackedStringArray()
	var files := DirAccess.get_files_at(RealAssetKit.ROOT)
	for f in files:
		if f.get_extension().to_lower() == "glb":
			_asset_names.append(f.get_basename())
	var sorted: Array = Array(_asset_names)
	sorted.sort()
	_asset_names = PackedStringArray(sorted)
	print("[EDITOR] scanned %d models under %s" % [_asset_names.size(), RealAssetKit.ROOT])


func _fill_asset_list(filter: String) -> void:
	if _asset_list == null:
		return
	_asset_list.clear()
	_list_assets.clear()
	var needle := filter.strip_edges().to_lower()
	for n in _asset_names:
		var asset := String(n)
		if not needle.is_empty() and not asset.to_lower().contains(needle):
			continue
		var icon: Texture2D = _thumb_cache.get(asset)
		_asset_list.add_item(asset, icon)
		_list_assets.append(asset)


func _on_search_changed(text: String) -> void:
	_fill_asset_list(text)


# ---------------------------------------------------------------------------
# 导入自己的模型
# ---------------------------------------------------------------------------
## 把本机的 .glb 拷进 assets/venues/，立刻进列表可用。
## 关键点：Godot 的导入流水线只在编辑器进程里跑，运行时新拷进来的 glb
## 用 load() 是拿不到的 —— 所以 RealAssetKit 那边加了 GLTFDocument 现场解析的兜底。
func _on_import_pressed() -> void:
	if _import_dlg == null:
		_import_dlg = FileDialog.new()
		_import_dlg.title = "选择要导入的模型（.glb 单文件）"
		_import_dlg.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		_import_dlg.access = FileDialog.ACCESS_FILESYSTEM
		_import_dlg.filters = PackedStringArray(["*.glb ; glTF 二进制模型"])
		_import_dlg.use_native_dialog = true
		_import_dlg.file_selected.connect(_import_model)
		# FileDialog 是 Window，必须挂在 CanvasLayer 下，否则在 3D 场景里弹不出来
		var layer := CanvasLayer.new()
		layer.name = "ImportLayer"
		layer.layer = 3
		add_child(layer)
		layer.add_child(_import_dlg)
	_import_dlg.popup_centered(Vector2i(980, 620))


func _import_model(src: String) -> void:
	var fname := src.get_file()
	if fname.get_extension().to_lower() != "glb":
		_import_notify("只支持 .glb（自包含单文件）；.gltf 请先在 Blender 里导出成 glb。", false)
		return
	var base := _safe_asset_name(fname.get_basename())
	var dst_res := RealAssetKit.ROOT + base + ".glb"
	var n := 2
	while FileAccess.file_exists(dst_res) and not _same_file(src, dst_res):
		base = "%s_%d" % [_safe_asset_name(fname.get_basename()), n]
		dst_res = RealAssetKit.ROOT + base + ".glb"
		n += 1
	if _same_file(src, dst_res):
		_import_notify("%s 已经在项目库里了。" % base, true)
		_select_asset(base)
		return
	var bytes := FileAccess.get_file_as_bytes(src)
	if bytes.is_empty():
		_import_notify("读不到文件：%s" % src, false)
		return
	var w := FileAccess.open(dst_res, FileAccess.WRITE)
	if w == null:
		_import_notify("写入失败（项目目录不可写？）：%s" % dst_res, false)
		return
	w.store_buffer(bytes)
	w.close()

	# 清掉资产缓存，让新文件走「运行时 glTF 解析」这条路
	RealAssetKit.clear_cache()
	_thumb_cache.erase(base)
	_thumb_size.erase(base)
	var old_png := _thumb_path(base)
	if FileAccess.file_exists(old_png):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(old_png))
	_scan_assets()
	_fill_asset_list("")
	_thumb_queue.append(base)
	_select_asset(base)
	_import_notify("已导入 %s → assets/venues/%s.glb（%s KB）" % [
		fname, base, str(maxi(1, bytes.size() / 1024))], true)
	print("[IMPORT] %s -> %s (%d bytes)" % [src, dst_res, bytes.size()])


func _safe_asset_name(raw: String) -> String:
	var out := raw.strip_edges().to_lower().replace(" ", "_")
	for bad in ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]:
		out = out.replace(bad, "_")
	return out if not out.is_empty() else "imported_model"


func _same_file(a: String, b: String) -> bool:
	return a.simplify_path() == ProjectSettings.globalize_path(b).simplify_path()


## 导入后在列表里定位并选中它，省得用户自己翻。
func _select_asset(asset: String) -> void:
	_fill_asset_list("")
	var idx := _list_assets.find(asset)
	if idx >= 0:
		_asset_list.select(idx)
		_asset_list.ensure_current_is_visible()
	_pending_asset = asset
	_show_preview(asset)
	_update_hud()


func _import_notify(msg: String, ok: bool) -> void:
	if _import_msg == null:
		return
	_import_msg.text = msg
	_import_msg.visible = true
	_import_msg.add_theme_color_override("font_color",
		Color(0.55, 0.82, 0.62) if ok else Color(0.95, 0.55, 0.5))
	print("[IMPORT] ", msg)


func _on_asset_selected(index: int) -> void:
	if _asset_list == null or index < 0 or index >= _list_assets.size():
		return
	_pending_asset = String(_list_assets[index])
	_show_preview(_pending_asset)
	_update_hud()
	print("[EDITOR] pending asset: ", _pending_asset)


## 鼠标划过列表项 → 立刻把预览图换成它。这是「哪个是哪个」最快的答案。
func _on_asset_hovered(index: int) -> void:
	if index < 0 or index >= _list_assets.size():
		return
	_list_hovering = true
	_show_preview(String(_list_assets[index]))


func _on_list_mouse_exited() -> void:
	_list_hovering = false
	# 鼠标离开列表时回到已选中的模型；没选中就保持最后悬停的那个
	_show_preview(_pending_asset if not _pending_asset.is_empty() else _preview_asset)


# ---------------------------------------------------------------------------
# 缩略图：离屏把每个 GLB 拍成一张小图
# ---------------------------------------------------------------------------
## 一个独立的 SubViewport 当作"摄影棚"：自己一套环境光 + 平行光 + 相机，
## 每帧拍一个模型，74 个模型约 1 秒拍完，拍完缓存成 PNG，下次启动直接读图。
func _setup_thumb_rig() -> void:
	if DisplayServer.get_name() == "headless":
		return   # headless 下没有真实渲染，拍了也是黑的
	_thumb_vp = SubViewport.new()
	_thumb_vp.name = "ThumbStudio"
	_thumb_vp.size = Vector2i(256, 256)
	_thumb_vp.transparent_bg = true
	_thumb_vp.own_world_3d = true
	_thumb_vp.msaa_3d = Viewport.MSAA_4X
	_thumb_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_thumb_vp)

	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.72, 0.78, 0.86)
	env.ambient_light_energy = 1.15
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var we := WorldEnvironment.new()
	we.environment = env
	_thumb_vp.add_child(we)

	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-42.0, 38.0, 0.0)
	key.light_energy = 2.1
	_thumb_vp.add_child(key)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-18.0, -125.0, 0.0)
	fill.light_energy = 0.55
	fill.light_color = Color(0.78, 0.86, 1.0)
	_thumb_vp.add_child(fill)

	_thumb_cam = Camera3D.new()
	_thumb_cam.fov = 38.0
	_thumb_vp.add_child(_thumb_cam)

	_thumb_queue = Array(_asset_names)
	# 先把磁盘上已有的缓存读进来，能立刻显示的全部到位，剩下的排队拍
	_load_thumb_sizes()
	for asset in _asset_names:
		var p := _thumb_path(String(asset))
		if FileAccess.file_exists(p):
			var img := Image.load_from_file(ProjectSettings.globalize_path(p))
			if img != null and not img.is_empty():
				_thumb_cache[String(asset)] = ImageTexture.create_from_image(img)
				_thumb_queue.erase(String(asset))
	print("[EDITOR] thumbs cached=%d queued=%d" % [_thumb_cache.size(), _thumb_queue.size()])


func _thumb_path(asset: String) -> String:
	return THUMB_DIR + "/%s.png" % asset


func _process_thumb_queue() -> void:
	if _thumb_busy or _thumb_queue.is_empty() or _thumb_vp == null:
		return
	_thumb_busy = true
	var asset := String(_thumb_queue.pop_front())
	_render_thumb(asset)


func _render_thumb(asset: String) -> void:
	var inst := RealAssetKit.instance(asset)
	if inst == null:
		_thumb_busy = false
		return
	_thumb_subject = inst
	_thumb_vp.add_child(_thumb_subject)

	var box := _union_mesh_aabb(_thumb_subject)
	var size3 := box.size
	if size3.length() < 0.001:
		size3 = Vector3.ONE
	var c := box.position + size3 * 0.5
	var radius: float = maxf(size3.length() * 0.5, 0.05)
	# 按包围球半径推视距，保证任何尺寸的模型都刚好占满画面
	var dist: float = radius / tan(deg_to_rad(_thumb_cam.fov * 0.5)) * 0.82
	_thumb_cam.near = maxf(dist * 0.02, 0.01)
	_thumb_cam.far = dist * 12.0
	_thumb_cam.position = c + Vector3(dist * 0.66, dist * 0.5, dist * 0.66)
	_thumb_cam.look_at(c, Vector3.UP)

	_thumb_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw

	var img := _thumb_vp.get_texture().get_image()
	_thumb_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_thumb_subject.queue_free()
	_thumb_subject = null

	if img != null and not img.is_empty():
		img.flip_y()
		var tex := ImageTexture.create_from_image(img)
		_thumb_cache[asset] = tex
		_thumb_size[asset] = size3
		DirAccess.make_dir_recursive_absolute(
			ProjectSettings.globalize_path(THUMB_DIR))
		img.save_png(_thumb_path(asset))
		_apply_icon_to_row(asset)
		# 尺寸表每拍一张就落盘：否则中途关掉编辑器，下次虽然读到了 PNG
		# 却显示不出「实际多大」
		_save_thumb_sizes()
		if asset == _preview_asset:
			_show_preview(asset)
	_thumb_busy = false


## 尺寸信息单独存一份 —— 缩略图是 PNG，体积不代表实际米数。
func _save_thumb_sizes() -> void:
	var doc: Dictionary = {}
	for k in _thumb_size.keys():
		var s: Vector3 = _thumb_size[k]
		doc[String(k)] = [s.x, s.y, s.z]
	var f := FileAccess.open(THUMB_DIR + "/sizes.json", FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(doc))
	f.close()


func _load_thumb_sizes() -> void:
	var f := FileAccess.open(THUMB_DIR + "/sizes.json", FileAccess.READ)
	if f == null:
		return
	var doc = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(doc) != TYPE_DICTIONARY:
		return
	for k in doc.keys():
		var a: Array = doc[k]
		if a.size() == 3:
			_thumb_size[String(k)] = Vector3(float(a[0]), float(a[1]), float(a[2]))


## 合并节点下所有网格的世界包围盒。GLB 常常是"一个根 + 几十个 MeshInstance3D"，
## 只取第一个会把相机怼到某个零件上。
func _union_mesh_aabb(root: Node3D) -> AABB:
	var out := AABB()
	var first := true
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		var b: AABB = mi.global_transform * mi.mesh.get_aabb()
		if first:
			out = b
			first = false
		else:
			out = out.merge(b)
	if first:
		out = AABB(root.global_position - Vector3.ONE * 0.5, Vector3.ONE)
	return out


func _apply_icon_to_row(asset: String) -> void:
	if _asset_list == null:
		return
	var idx := _list_assets.find(asset)
	var tex: Texture2D = _thumb_cache.get(asset)
	if idx < 0 or tex == null or idx >= _asset_list.item_count:
		return
	_asset_list.set_item_icon(idx, tex)


func _show_preview(asset: String) -> void:
	if _preview_tex == null:
		return
	if asset.is_empty():
		_preview_tex.texture = null
		_preview_name.text = "—"
		_preview_info.text = "把鼠标移到模型名上看样子"
		_preview_asset = ""
		return
	_preview_asset = asset
	_preview_name.text = asset
	# 手搓道具（护栏柱、海滩伞…）不在 assets/venues 里，拍不出缩略图，直接说明
	if not _asset_names.has(asset):
		_preview_tex.texture = null
		_preview_info.text = "程序化道具 · 无模型预览"
		return
	var tex: Texture2D = _thumb_cache.get(asset)
	_preview_tex.texture = tex
	if tex == null:
		# 还没拍到：插到队首优先拍，鼠标划到哪个就先出哪个
		var at := _thumb_queue.find(asset)
		if at > 0:
			_thumb_queue.remove_at(at)
			_thumb_queue.push_front(asset)
	if tex != null:
		if _thumb_size.has(asset):
			var s: Vector3 = _thumb_size[asset]
			_preview_info.text = "尺寸 %.1f × %.1f × %.1f m" % [s.x, s.y, s.z]
		else:
			_preview_info.text = "已缓存缩略图"
	else:
		_preview_info.text = "正在生成预览…"


## 从可编辑条目的 label（形如 "buoy_real (CoastBuoys_g5)"）里取出资产名，
## 这样在场景里点中一棵树，右边也能看到这棵树到底长什么样。
func _asset_of_item(it: Dictionary) -> String:
	var label := String(it.get("label", ""))
	var p := label.find(" (")
	return label.substr(0, p) if p > 0 else label


## 把待放置的模型摆到鼠标所指的地面位置。
func _place_pending_at(screen: Vector2) -> void:
	if _pending_asset.is_empty():
		return
	var p := _screen_to_ground_at(screen, 0.0)
	if Terrain.active:
		p.y = Terrain.height_at(p)
	_place_asset_at(_pending_asset, p)


## 把某个资产摆到世界坐标 p，返回新增记录的 id（失败返回空串）。
## 单独拆出来是为了让自检能不经鼠标、直接在指定坐标上测「摆放 / 撤销」。
func _place_asset_at(asset: String, p: Vector3) -> String:
	if asset.is_empty():
		return ""
	_push_undo("")
	var id := "a%d" % _next_add_id
	_next_add_id += 1
	var node := RealAssetKit.place_unique(self, asset,
		Transform3D(Basis(), p), "Added_" + id)
	if node == null:
		_note = "放置失败: %s" % asset
		_update_hud()
		print("[EDITOR] 放置失败: ", asset)
		return ""
	_added[id] = {
		"id": id,
		"asset": asset,
		"p": [snappedf(p.x, 0.01), snappedf(p.y, 0.01), snappedf(p.z, 0.01)],
		"q": [0.0, 0.0, 0.0, 1.0],
		"s": [1.0, 1.0, 1.0],
	}
	_rescan()
	var want := "ND:Added_" + id
	for i in items.size():
		if String(items[i]["key"]) == want:
			sel = i
			break
	_update_hud()
	print("[EDITOR] added %s as %s at %s" % [asset, id, str(p)])
	return id


## 增删对象后重建索引（items / 标记 / 同步表都依赖它）。
func _rescan() -> void:
	var keep := ""
	if sel >= 0 and sel < items.size():
		keep = String(items[sel]["key"])
	_collect_items()
	_apply_overrides()
	if _markers != null:
		_markers.queue_free()
		_markers = null
	_ensure_markers()
	sel = -1
	if not keep.is_empty():
		for i in items.size():
			if String(items[i]["key"]) == keep:
				sel = i
				break


func _update_hud() -> void:
	var info := "场景装饰编辑器 · %s\n" % track_id
	info += "可编辑 %d · 已改 %d · 已删 %d · 已加 %d\n" % [
		items.size(), edits.size(), removed.size(), _added.size()]
	info += "可撤销 %d 步 · 可重做 %d 步%s\n" % [
		_undo.size(), _redo.size(), "" if not _dirty else "   ● 未保存"]
	info += "——————————————————————\n"
	if not _pending_asset.is_empty():
		info += "放置模式: %s\n在地面点击摆放 · Esc 取消\n" % _pending_asset
		info += "——————————————————————\n"
	if sel >= 0 and sel < items.size():
		var it: Dictionary = items[sel]
		var o: Vector3 = (it["xf"] as Transform3D).origin
		info += "选中: %s\n" % String(it["label"])
		info += "位置: X %.1f  Y %.1f  Z %.1f\n" % [o.x, o.y, o.z]
		info += "类型: %s\n" % ("MultiMesh 实例 #%d" % int(it["idx"]) if int(it["idx"]) >= 0 else "独立节点")
		# 朝向与缩放必须显式报出来，否则用户按 R 转了 15° 也看不出到底动了没动
		var sb: Basis = (it["xf"] as Transform3D).basis
		var scl: Vector3 = sb.get_scale()
		var yaw_deg: float = rad_to_deg(sb.orthonormalized().get_euler().y)
		info += "朝向 %.0f° · 缩放 %.2f×\n" % [fposmod(yaw_deg, 360.0), scl.x]
		# 场景里选中的东西，右侧预览也跟着换 —— 点中一棵树能立刻看清它长什么样
		if not _list_hovering and _pending_asset.is_empty():
			var sel_asset := _asset_of_item(it)
			if not sel_asset.is_empty() and sel_asset != _preview_asset:
				_show_preview(sel_asset)
	else:
		info += "未选中 —— 鼠标移到物体上会出黄框，左键即可选中\n"
	if _hover >= 0 and _hover < items.size() and _hover != sel:
		var hit: Dictionary = items[_hover]
		var ho: Vector3 = (hit["xf"] as Transform3D).origin
		info += "悬停: %s\n" % String(hit["label"])
		info += "      (%.0f, %.0f, %.0f)  ← 左键选中 / F 靠近\n" % [ho.x, ho.y, ho.z]
	info += "——————————————————————\n"
	info += "左键 选/拖 · F 靠近 · R 旋转 · G 摆正 · [ ] 缩放 · Del 删除\n"
	info += "Ctrl+Z 撤销 · Ctrl+Shift+Z 重做 · Ctrl+S 保存\n"
	info += "WASD 移动 · Q/E 升降 · 右键拖动 转视角 · 滚轮 推拉\n"
	info += "N 下一个可编辑对象 · Tab %s" % (
		"隐藏标记" if only_editable else "显示可编辑标记")
	if not _note.is_empty():
		info += "\n\n" + _note
	_hud.text = info


# ---------------------------------------------------------------------------
# 拾取
# ---------------------------------------------------------------------------
func _ray_from(screen: Vector2) -> Array:
	return [cam.project_ray_origin(screen), cam.project_ray_normal(screen)]


func _pick(screen: Vector2) -> int:
	var ray := _ray_from(screen)
	var from: Vector3 = ray[0]
	var dir: Vector3 = ray[1]
	var best := -1
	var best_t := PICK_MAX_DIST
	for i in items.size():
		var box: AABB = items[i]["aabb"]
		# 包围盒按模型轮廓算，细长的树干/树冠在屏幕上很窄，点击容差需要外扩一点，
		# 否则鼠标明明压在树上却判定未命中。
		var t := _ray_aabb(from, dir, box.grow(PICK_PAD))
		if t >= 0.0 and t < best_t:
			best_t = t
			best = i
	return best


## 射线与 AABB 求交，返回进入距离；不相交返回 -1。
func _ray_aabb(o: Vector3, d: Vector3, box: AABB) -> float:
	var tmin := -INF
	var tmax := INF
	for axis in 3:
		var oa: float = o[axis]
		var da: float = d[axis]
		var lo: float = box.position[axis]
		var hi: float = box.position[axis] + box.size[axis]
		if absf(da) < 1e-8:
			if oa < lo or oa > hi:
				return -1.0
		else:
			var t1 := (lo - oa) / da
			var t2 := (hi - oa) / da
			if t1 > t2:
				var tmp := t1; t1 = t2; t2 = tmp
			tmin = maxf(tmin, t1)
			tmax = minf(tmax, t2)
			if tmin > tmax:
				return -1.0
	return tmin if tmin >= 0.0 else (tmax if tmax >= 0.0 else -1.0)


## 屏幕坐标 → 地面(y=0)平面上的点
func _screen_to_ground(screen: Vector2) -> Vector3:
	var ray := _ray_from(screen)
	var from: Vector3 = ray[0]
	var dir: Vector3 = ray[1]
	if absf(dir.y) < 1e-5:
		return Vector3.ZERO
	var t := -from.y / dir.y
	return from + dir * t


# ---------------------------------------------------------------------------
# 输入
# ---------------------------------------------------------------------------
var _drag := false
var _drag_plane_y := 0.0
var _drag_offset := Vector3.ZERO
var _orbit := false
var _last_mouse := Vector2.ZERO
var _cam_speed := 60.0
## 旋转/缩放的按键重复节流（毫秒）。key echo 一秒能发 30 次，不限流会一按就转飞。
var _last_rot_ms := 0
var _last_scale_ms := 0
## 鼠标正压在哪个可编辑对象上（-1 = 没有）
var _hover := -1


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			if not _pending_asset.is_empty():
				# 放置模式：左键点地面直接摆模型，不参与点选
				_place_pending_at(mb.position)
			else:
				var hit := _pick(mb.position)
				sel = hit
				if hit >= 0:
					var xf: Transform3D = items[hit]["xf"]
					_drag_plane_y = xf.origin.y
					_drag_offset = xf.origin - _screen_to_ground_at(mb.position, _drag_plane_y)
					_drag = true
					# 真正开始移动时才入栈（见 _process 里的拖动分支），
					# 否则「只点一下」也会占掉一格撤销，撤起来像没反应
					_drag_pushed = false
				_update_hud()
		elif mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed:
			_drag = false
			_drag_pushed = false
			_last_push_tag = ""
		elif mb.button_index == MOUSE_BUTTON_RIGHT:
			_orbit = mb.pressed
			_last_mouse = mb.position
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			cam.position += -cam.global_transform.basis.z * -_cam_speed * 0.35
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			cam.position += -cam.global_transform.basis.z * _cam_speed * 0.35

	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _orbit:
			var d := mm.position - _last_mouse
			_last_mouse = mm.position
			cam.rotate_y(-d.x * 0.004)
			cam.rotate_object_local(Vector3.RIGHT, -d.y * 0.004)
		elif _drag and sel >= 0:
			var target := _screen_to_ground_at(mm.position, _drag_plane_y) + _drag_offset
			var it: Dictionary = items[sel]
			if not _drag_pushed:
				_push_undo("drag:%s" % String(it["key"]))
				_drag_pushed = true
			var xf: Transform3D = it["xf"]
			xf.origin = target
			_write_xf(it, xf)
			_record(it, xf)
			_update_hud()

	elif event is InputEventKey and event.pressed:
		var k := event as InputEventKey
		match k.keycode:
			KEY_R:
				# 15° 一步；按住不放持续旋转。但 key repeat 一秒能发 30 次，
				# 不限流会一按就转飞，所以 echo 事件按 110ms 节流。
				if (not k.echo) or (Time.get_ticks_msec() - _last_rot_ms >= 110):
					_last_rot_ms = Time.get_ticks_msec()
					_rotate_sel(-15.0 if k.shift_pressed else 15.0)
			KEY_G:
				# 摆正：清掉倾斜，只留绕 Y 的朝向。模型被转歪了、或导入时自带倾角，按它归正。
				_upright_sel()
			KEY_BRACKETLEFT:
				if sel >= 0 and ((not k.echo) or (Time.get_ticks_msec() - _last_scale_ms >= 110)):
					_last_scale_ms = Time.get_ticks_msec()
					_scale_sel(0.9)
			KEY_BRACKETRIGHT:
				if sel >= 0 and ((not k.echo) or (Time.get_ticks_msec() - _last_scale_ms >= 110)):
					_last_scale_ms = Time.get_ticks_msec()
					_scale_sel(1.1)
			KEY_DELETE, KEY_BACKSPACE:
				_delete_sel()
			KEY_S:
				if k.ctrl_pressed or k.meta_pressed:
					_note = _save_overrides()
					_dirty = false
					_esc_armed = false
					print("[EDITOR] ", _note)
					_update_hud()
			KEY_Z:
				# Ctrl/Cmd+Z 撤销，加 Shift 重做（macOS 用户习惯 Cmd，两个都认）。
				# 忽略 key echo —— 一步可能是一大片改动，按住不放一路倒带太吓人。
				if (k.ctrl_pressed or k.meta_pressed) and not k.echo:
					if k.shift_pressed:
						_redo_step()
					else:
						_undo_step()
			KEY_Y:
				if (k.ctrl_pressed or k.meta_pressed) and not k.echo:
					_redo_step()
			KEY_TAB:
				only_editable = not only_editable
				_ensure_markers()
				if _markers != null:
					_markers.visible = only_editable
				_update_hud()
			KEY_F:
				# 一键把镜头拉到选中项（或鼠标下的对象）旁边 —— 远看时找不到目标就靠它
				if sel < 0 and _hover >= 0:
					sel = _hover
				if sel >= 0:
					_focus_item(sel)
					_update_hud()
			KEY_N:
				# 逐个巡览全部可编辑对象。整条赛道装饰稀疏（海岸只有 46 个），
				# 用鼠标在 710m 的场景里找太费劲，直接按 N 一个个跳过去。
				_cycle_item(-1 if k.shift_pressed else 1)
			KEY_ESCAPE:
				if not _pending_asset.is_empty():
					_pending_asset = ""
					if _asset_list != null:
						_asset_list.deselect_all()
					_update_hud()
				elif _dirty and not _esc_armed:
					# 有没保存的改动时 Esc 不直接退出，先给一次提醒 —— 编了半天一脚踩空太亏
					_esc_armed = true
					_note = "有未保存的修改：Ctrl+S 保存，或再按一次 Esc 放弃并退出"
					_update_hud()
				else:
					get_tree().quit(0)


## 绕世界 Y 轴（垂直轴）旋转。场景装饰必须始终「立着」，所以只用 Y 轴，
## 不会越转越歪。角度是从当前状态累加的，连按 6 次就是 90°。
func _rotate_sel(deg: float) -> void:
	if sel < 0 or sel >= items.size():
		return
	var it: Dictionary = items[sel]
	_push_undo("rot:%s" % String(it["key"]))
	var xf: Transform3D = it["xf"]
	xf.basis = Basis(Vector3.UP, deg_to_rad(deg)) * xf.basis
	_write_xf(it, xf)
	_record(it, xf)
	_update_hud()


## 摆正：丢掉倾斜，只保留绕 Y 轴的朝向。
## 用途：GLB 导入时自带倾角、或者多次绕世界轴旋转后模型看起来「躺下了」，
## 按一下立刻回到直立状态，朝向不变。
func _upright_sel() -> void:
	if sel < 0 or sel >= items.size():
		return
	var it: Dictionary = items[sel]
	_push_undo("")
	var xf: Transform3D = it["xf"]
	var s := xf.basis.get_scale()
	var yaw := xf.basis.orthonormalized().get_euler().y
	xf.basis = Basis(Vector3.UP, yaw).scaled(s)
	_write_xf(it, xf)
	_record(it, xf)
	_update_hud()


func _scale_sel(f: float) -> void:
	if sel < 0 or sel >= items.size():
		return
	var it: Dictionary = items[sel]
	_push_undo("scale:%s" % String(it["key"]))
	var xf: Transform3D = it["xf"]
	xf.basis = xf.basis.scaled(Vector3.ONE * f)
	_write_xf(it, xf); _record(it, xf); _update_hud()


## 把镜头推到某个可编辑实例旁边。
## 距离按包围盒尺度估算，但设上下限 —— 有些 GLB 的 AABB 比模型本体大得多，
## 直接按 size.length() 拉距离会把镜头推到几十米外，反而看不清。
func _focus_item(i: int) -> void:
	if i < 0 or i >= items.size():
		return
	var it: Dictionary = items[i]
	var o: Vector3 = (it["xf"] as Transform3D).origin
	var span: float = (it["aabb"] as AABB).size.length()
	var d := clampf(span * 0.55, 5.0, 40.0)
	cam.position = o + Vector3(d * 0.82, d * 0.52, d * 0.82)
	cam.look_at(o + Vector3(0.0, clampf(span * 0.3, 0.8, 6.0), 0.0), Vector3.UP)


## 沿 items 循环切换选中项，并把镜头带过去。
func _cycle_item(step: int) -> void:
	if items.is_empty():
		return
	var n := items.size()
	if sel < 0:
		sel = 0 if step > 0 else n - 1
	else:
		sel = (sel + step) % n
		if sel < 0:
			sel += n
	_focus_item(sel)
	_update_hud()


## 删除选中项。分两种：
##   · 用户手动摆放的模型 → 直接销毁节点并抹掉记录，真正消失；
##   · 程序化装饰 → 只能在 override 里登记「删掉」并把它缩到不可见，
##     因为下次启动时它还会被同样的种子重新生成出来。
func _delete_sel() -> void:
	if sel < 0 or sel >= items.size():
		return
	var it: Dictionary = items[sel]
	var key := String(it["key"])
	_push_undo("")
	if key.begins_with("ND:Added_"):
		var id := key.substr(9)
		_added.erase(id)
		edits.erase(key)
		removed.erase(key)
		var node = it["node"]
		if node is Node3D and is_instance_valid(node):
			(node as Node3D).get_parent().remove_child(node)
			(node as Node3D).queue_free()
		_rescan()
		print("[EDITOR] removed added model %s" % id)
	else:
		removed[key] = true
		edits.erase(key)
		var xf3: Transform3D = it["xf"]
		_write_xf(it, Transform3D(xf3.basis.scaled(Vector3.ONE * 0.0001), xf3.origin))
		sel = -1
	_update_hud()


func _marker_xf(box: AABB) -> Transform3D:
	var top := box.position + Vector3(0.0, box.size.y, 0.0)
	return Transform3D(Basis(), top + Vector3(0.0, 0.45, 0.0))


## 给每个可编辑实例头顶放一个小箭头，按 Tab 显示 —— 用来一眼扫出「这条赛道哪儿有东西可改」。
func _ensure_markers() -> void:
	if _markers != null or items.is_empty():
		return
	var cone := CylinderMesh.new()
	cone.top_radius = 0.0
	cone.bottom_radius = 0.26
	cone.height = 0.8
	cone.radial_segments = 6
	cone.rings = 1
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = cone
	mm.instance_count = items.size()
	for i in items.size():
		mm.set_instance_transform(i, _marker_xf(items[i]["aabb"]))
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.82, 0.2, 0.9)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_markers = MultiMeshInstance3D.new()
	_markers.name = "EditableMarkers"
	_markers.multimesh = mm
	_markers.material_override = mat
	_markers.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_markers.visible = only_editable
	add_child(_markers)
	print("[EDITOR] markers=%d visible=%s" % [mm.instance_count, str(_markers.visible)])


func _screen_to_ground_at(screen: Vector2, plane_y: float) -> Vector3:
	var ray := _ray_from(screen)
	var from: Vector3 = ray[0]
	var dir: Vector3 = ray[1]
	if absf(dir.y) < 1e-5:
		return Vector3.ZERO
	var t := (plane_y - from.y) / dir.y
	return from + dir * t


func _process(delta: float) -> void:
	# WASD 相机平移
	var mv := Vector3.ZERO
	if Input.is_key_pressed(KEY_W): mv -= cam.global_transform.basis.z
	if Input.is_key_pressed(KEY_S): mv += cam.global_transform.basis.z
	if Input.is_key_pressed(KEY_A): mv -= cam.global_transform.basis.x
	if Input.is_key_pressed(KEY_D): mv += cam.global_transform.basis.x
	if Input.is_key_pressed(KEY_Q): mv -= Vector3.UP
	if Input.is_key_pressed(KEY_E): mv += Vector3.UP
	if mv.length_squared() > 0.0:
		cam.position += mv.normalized() * _cam_speed * delta

	# 悬停预览：不按键也实时判断鼠标下有没有可编辑对象。
	# 否则整屏都是程序化生成的景物，用户无法分辨哪些是能点的。
	var prev_hover := _hover
	if _drag or _orbit:
		_hover = -1
	else:
		_hover = _pick(get_viewport().get_mouse_position())
	if _hover != prev_hover:
		_update_hud()

	# 选中项高亮框
	_draw_selection()

	# 缩略图一张一张拍，不阻塞操作
	_process_thumb_queue()

	if not _shot_path.is_empty():
		_shot_frames += 1
		# 等 40 帧：缩略图是逐帧拍的，截早了右侧列表还是空的
		if _shot_frames == 40:
			var img := get_viewport().get_texture().get_image()
			img.save_png(_shot_path)
			print("[EDITOR] shot saved -> %s (thumbs=%d)" % [_shot_path, _thumb_cache.size()])
			get_tree().quit(0)


var _sel_box: MeshInstance3D


func _ensure_sel_box() -> void:
	if _sel_box != null:
		return
	_sel_box = MeshInstance3D.new()
	_sel_box.mesh = BoxMesh.new()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.31, 0.91, 1.0, 0.26)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.no_depth_test = true
	_sel_box.material_override = mat
	_sel_box.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_sel_box)


## 选中项画青色框；没有选中但鼠标压着某个可编辑对象时，画黄色框提示「这个能点」。
func _draw_selection() -> void:
	_ensure_sel_box()
	var target := sel
	var hovering := false
	if target < 0:
		target = _hover
		hovering = true
	if target < 0 or target >= items.size():
		_sel_box.visible = false
		return
	var box: AABB = items[target]["aabb"]
	_sel_box.visible = true
	_sel_box.global_position = box.position + box.size * 0.5
	(_sel_box.mesh as BoxMesh).size = box.size.max(Vector3(0.4, 0.4, 0.4))
	var mat := _sel_box.material_override as StandardMaterial3D
	if mat != null:
		mat.albedo_color = Color(1.0, 0.78, 0.18, 0.20) if hovering \
			else Color(0.31, 0.91, 1.0, 0.16)
