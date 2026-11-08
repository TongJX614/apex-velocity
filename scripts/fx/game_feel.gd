class_name GameFeel
extends Node
## Game-feel 特效模块：hit-stop、碰撞碎片/火花、镜头冲击、音频 ducking、
## 换挡顿挫、后轮轮胎烟、氮气全屏蓝光冲刺。
##
## 设计为 main.gd 的一个持久子节点（不要改本文件以外的东西）：
##   _start_race():   game_feel = GameFeel.new(); add_child(game_feel); game_feel.setup(self)
##   _physics_process(): game_feel.update_state(dt, car, race.state)
##                       换挡时 game_feel.on_shift()
##                       撞击时 game_feel.on_impact(strength, world_pos)
##   _clear_race():   game_feel.clear()
##
## Headless 安全：只用 CPUParticles3D + StandardMaterial3D，不加载 shader、
## 不依赖 GPU 粒子。Engine.time_scale 的恢复由真实时间驱动，_process 在
## 暂停/慢放下仍然运行（PROCESS_MODE_ALWAYS），并且 _exit_tree / clear 兜底，
## 不会因为 race 结束或节点被释放而永久卡在慢动作。

const VFX := preload("res://scripts/fx/vfx_library.gd")

const HITSTOP_TIME_SCALE := 0.35
const HITSTOP_MIN_SEC := 0.05
const HITSTOP_MAX_SEC := 0.10
const IMPACT_FX_LIFETIME_MS := 900
const SMOKE_BASE_AMOUNT := 34
const SKID_MAX := 260
const SHIFT_MIN_INTERVAL_MS := 70
const SCRAPE_MIN_INTERVAL_MS := 90

var _main_ref: Node
var race_root: Node3D
var cam: Node
var audio: Node
var car_ref: Car

var _hitstop_active := false
var _hitstop_saved_scale := 1.0
var _hitstop_deadline_ms := 0
var _last_shift_ms := -1000
var _last_scrape_ms := -1000
var _nitro_was_active := false

var _smoke_left: CPUParticles3D
var _smoke_right: CPUParticles3D
var _smoke_fl: CPUParticles3D
var _smoke_fr: CPUParticles3D
var _nitro_layer: CanvasLayer
var _nitro_glow: TextureRect
var _nitro_streaks: TextureRect
var _nitro_tint: ColorRect
var _nitro_flash: TextureRect
var _nitro_vis := 0.0
var _nitro_pulse_clock := 0.0
var _launch_was_active := false
var _skid_mm: MultiMeshInstance3D
var _skid_index := 0
var _skid_timer := 0.0
var _transient: Array[Dictionary] = []


func _ready() -> void:
	# 游戏暂停时也要把 hit-stop 的计时器/粒子清理跑完。
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(true)


func _exit_tree() -> void:
	# 最后一道保险：无论 main 是否调用 clear()，退出场景都不能留下慢动作。
	_restore_time_scale()
	for p in [_smoke_left, _smoke_right, _smoke_fl, _smoke_fr]:
		if p != null and is_instance_valid(p):
			p.emitting = false
	_free_nitro_overlay()
	_transient.clear()


# ---------------------------------------------------------------------------
# 对外 API
# ---------------------------------------------------------------------------

func setup(main_ref: Node) -> void:
	_main_ref = main_ref
	if _main_ref == null or not is_instance_valid(_main_ref):
		race_root = null
		cam = null
		audio = null
		car_ref = null
		_free_car_particles()
		return
	race_root = _read_ref(_main_ref, "race_root") as Node3D
	cam = _read_ref(_main_ref, "cam") as Node
	audio = _read_ref(_main_ref, "audio") as Node
	car_ref = _read_ref(_main_ref, "car") as Car
	_rebuild_car_particles()
	_build_nitro_overlay()


## 每物理帧调用（建议放在 car.update_car() 之后、cam.follow_update() 之前）。
## race_state 直接用 RaceManager.State 的整数值：0=COUNTDOWN 1=RACING 2=FINISHED 3=RESULTS。
func update_state(dt: float, car: Car, race_state: int) -> void:
	if car == null:
		return
	if car != car_ref:
		car_ref = car
		_rebuild_car_particles()
	var active := race_state == 1 or race_state == 2
	_update_car_particles(car, active, dt)
	_update_nitro_fov(car, active, dt)


## 撞击：strength 0..1，world_pos 为碰撞世界坐标。
## 触发 hit-stop / 碎片+火花 / 镜头 shake+FOV kick+镜头顿挫 / 音乐 ducking。
func on_impact(strength: float, world_pos: Vector3) -> void:
	var s := clampf(strength, 0.0, 1.0)
	_start_hitstop(lerpf(HITSTOP_MIN_SEC, HITSTOP_MAX_SEC, s))
	_spawn_impact_burst(world_pos, s)
	# 镜头：shake + 压缩 FOV + 一次俯仰/侧倾 kick
	_cam_call(&"add_shake", [lerpf(0.08, 0.62, s)])
	_cam_call(&"add_fov_boost", [-lerpf(0.8, 4.5, s)])
	_cam_call(&"add_kick", [lerpf(0.10, 0.85, s)])
	if audio != null and is_instance_valid(audio) and audio.has_method("duck_music"):
		audio.call("duck_music", s)


## 持续刮蹭：只出少量火花 + 轻微震动，不触发 hit-stop。
## world_pos 建议传两车接触点（车身高度），冷却 90ms 防止每帧刷粒子。
func on_scrape(strength: float, world_pos: Vector3) -> void:
	var now := Time.get_ticks_msec()
	if now - _last_scrape_ms < SCRAPE_MIN_INTERVAL_MS:
		return
	_last_scrape_ms = now
	var s := clampf(strength, 0.0, 1.0)
	var parent := _fx_parent()
	if parent == null:
		return
	var burst := Node3D.new()
	burst.name = "GameFeelScrape"
	parent.add_child(burst)
	burst.global_position = world_pos
	_add_sparks(burst, 0.12 + s * 0.30)
	_transient.append({
		"node": burst,
		"deadline_ms": now + 520,
	})
	_cam_call(&"add_shake", [lerpf(0.02, 0.10, s)])


## 换挡：轻微镜头 shake / 短促 FOV 回弹 / 小 kick。
func on_shift() -> void:
	var now := Time.get_ticks_msec()
	if now - _last_shift_ms < SHIFT_MIN_INTERVAL_MS:
		return
	_last_shift_ms = now
	_cam_call(&"add_shake", [0.06])
	_cam_call(&"add_fov_boost", [-1.6])
	_cam_call(&"add_kick", [0.08])


## 清场：恢复 time_scale，释放自己创建的所有粒子，断开 main 引用。
func clear() -> void:
	_restore_time_scale()
	_free_transient_fx()
	_free_car_particles()
	_free_nitro_overlay()
	_main_ref = null
	race_root = null
	cam = null
	audio = null
	car_ref = null
	_nitro_was_active = false
	_launch_was_active = false
	_last_scrape_ms = -1000


# ---------------------------------------------------------------------------
# hit-stop
# ---------------------------------------------------------------------------

func _start_hitstop(duration: float) -> void:
	var now := Time.get_ticks_msec()
	var deadline := now + maxi(1, int(round(duration * 1000.0)))
	if _hitstop_active:
		# 连续撞击只延长，不重复保存/覆盖原始 time_scale。
		_hitstop_deadline_ms = maxi(_hitstop_deadline_ms, deadline)
		return
	_hitstop_saved_scale = Engine.time_scale
	Engine.time_scale = minf(Engine.time_scale, HITSTOP_TIME_SCALE)
	_hitstop_active = true
	_hitstop_deadline_ms = deadline


func _restore_time_scale() -> void:
	if not _hitstop_active:
		return
	_hitstop_active = false
	Engine.time_scale = _hitstop_saved_scale


func _tick_hitstop() -> void:
	if not _hitstop_active:
		return
	if Time.get_ticks_msec() >= _hitstop_deadline_ms:
		_restore_time_scale()


# ---------------------------------------------------------------------------
# 每帧内部维护（真实时间；不受 Engine.time_scale / pause 影响）
# ---------------------------------------------------------------------------

func _process(_delta: float) -> void:
	_tick_hitstop()
	_tick_transient_fx()


func _tick_transient_fx() -> void:
	if _transient.is_empty():
		return
	var now := Time.get_ticks_msec()
	var keep: Array[Dictionary] = []
	for entry in _transient:
		var raw = entry.get("node")
		if raw == null or not is_instance_valid(raw):
			continue
		var node: Node = raw
		if now >= int(entry.get("deadline_ms", 0)):
			node.queue_free()
		else:
			keep.append(entry)
	_transient = keep


func _free_transient_fx() -> void:
	for entry in _transient:
		var raw = entry.get("node")
		if raw != null and is_instance_valid(raw):
			(raw as Node).queue_free()
	_transient.clear()


# ---------------------------------------------------------------------------
# 碰撞碎片 / 火花
# ---------------------------------------------------------------------------

func _spawn_impact_burst(world_pos: Vector3, strength: float) -> void:
	var parent := _fx_parent()
	if parent == null:
		return
	var burst := Node3D.new()
	burst.name = "GameFeelImpactBurst"
	parent.add_child(burst)
	if burst.is_inside_tree():
		burst.global_position = world_pos
	else:
		burst.position = world_pos

	_add_debris(burst, strength)
	_add_sparks(burst, strength)
	_transient.append({
		"node": burst,
		"deadline_ms": Time.get_ticks_msec() + IMPACT_FX_LIFETIME_MS,
	})


func _add_debris(parent: Node3D, strength: float) -> void:
	var debris := CPUParticles3D.new()
	debris.name = "Debris"
	debris.amount = clampi(int(round(lerpf(5.0, 16.0, strength) * _particle_scale())), 4, 22)
	debris.lifetime = 0.75
	debris.one_shot = true
	debris.explosiveness = 1.0
	debris.local_coords = false
	debris.direction = Vector3.UP
	debris.spread = 78.0
	debris.gravity = Vector3(0.0, -13.0, 0.0)
	debris.initial_velocity_min = lerpf(2.0, 4.0, strength)
	debris.initial_velocity_max = lerpf(5.0, 9.0, strength)
	debris.scale_amount_min = 0.5
	debris.scale_amount_max = 1.25

	var rock := SphereMesh.new()
	rock.radius = 0.035
	rock.height = 0.06
	rock.radial_segments = 5
	rock.rings = 2
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.26, 0.25, 0.24)
	mat.roughness = 0.98
	mat.metallic = 0.05
	rock.material = mat
	debris.mesh = rock
	debris.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(debris)
	debris.emitting = true


func _add_sparks(parent: Node3D, strength: float) -> void:
	var sparks := CPUParticles3D.new()
	sparks.name = "Sparks"
	sparks.amount = clampi(int(round(lerpf(8.0, 20.0, strength) * _particle_scale())), 6, 28)
	sparks.lifetime = 0.32
	sparks.one_shot = true
	sparks.explosiveness = 1.0
	sparks.local_coords = false
	sparks.direction = Vector3.UP
	sparks.spread = 72.0
	sparks.gravity = Vector3(0.0, -9.8, 0.0)
	sparks.initial_velocity_min = lerpf(4.5, 8.0, strength)
	sparks.initial_velocity_max = lerpf(9.0, 16.0, strength)
	sparks.scale_amount_min = 0.45
	sparks.scale_amount_max = 1.15

	var spark_mesh := QuadMesh.new()
	spark_mesh.size = Vector2(0.075, 0.075)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.billboard_keep_scale = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.disable_receive_shadows = true
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	mat.albedo_texture = VfxLibrary.spark_texture()
	mat.albedo_color = Color(1.0, 0.72, 0.30, 0.95)
	spark_mesh.material = mat
	sparks.mesh = spark_mesh
	sparks.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(sparks)
	sparks.emitting = true


func _fx_parent() -> Node:
	if race_root != null and is_instance_valid(race_root):
		return race_root
	if _main_ref != null and is_instance_valid(_main_ref):
		return _main_ref
	var parent := get_parent()
	return parent if parent != null else self


# ---------------------------------------------------------------------------
# 轮胎烟 / 氮气尾焰
# ---------------------------------------------------------------------------

func _rebuild_car_particles() -> void:
	_free_car_particles()
	if car_ref == null or not is_instance_valid(car_ref):
		return
	_smoke_left = _make_smoke("GameFeelSmokeRL", _rear_wheel_offset(-1.0))
	_smoke_right = _make_smoke("GameFeelSmokeRR", _rear_wheel_offset(1.0))
	# 四驱车起步/漂移四轮同时打滑：前轮也补一路更淡的烟，后驱保持只有后轮。
	if String(car_ref.drivetrain).to_upper() == "AWD":
		_smoke_fl = _make_smoke("GameFeelSmokeFL", _front_wheel_offset(-1.0))
		_smoke_fr = _make_smoke("GameFeelSmokeFR", _front_wheel_offset(1.0))
		for p in [_smoke_fl, _smoke_fr]:
			p.amount = maxi(int(round(float(p.amount) * 0.55)), 12)
			p.lifetime = 0.95
			p.scale_amount_max *= 0.8
	_build_skid_marks()


func _update_car_particles(car: Car, active: bool, dt: float) -> void:
	var speed := absf(car.speed_kph)
	# 起步/漂移起雾：手刹、漂移、打滑都直接起烟；起步油门到底时给一段
	# 轮胎摩擦烟（不再只依赖 wheelspin 在 10m/s 内衰减掉的短暂窗口）。
	var slipping := car.wheelspin > 0.28 or absf(car.lat_slip) > 3.0 \
		or car.drift_active or car.handbrake or (car.offroad and speed > 16.0)
	var smoke_on := active and speed > 4.0 and slipping
	_set_emitting(_smoke_left, smoke_on)
	_set_emitting(_smoke_right, smoke_on)
	_set_emitting(_smoke_fl, smoke_on)
	_set_emitting(_smoke_fr, smoke_on)

	# 起步瞬间额外补一团离合/轮胎摩擦烟，贴地爆开，弥补连续发射器的淡入。
	if active and car.launch and not _launch_was_active and speed < 30.0:
		_spawn_launch_smoke(car)
	_launch_was_active = active and car.launch

	_update_nitro_screen(car, active, dt)
	_update_skid_marks(car, active and slipping and speed > 12.0, dt)


func _update_nitro_fov(car: Car, active: bool, dt: float) -> void:
	var nitro_on := active and car.nitro_active and absf(car.speed_kph) > 2.0
	if nitro_on:
		if not _nitro_was_active:
			_cam_call(&"add_fov_boost", [2.2])
		# 与全屏脉冲同步的 FOV 呼吸：蓄力 → 猛推一下 → 回落，制造冲刺节奏。
		var pulse := pow(maxf(0.0, sin(_nitro_pulse_clock * TAU * 3.3)), 8.0)
		_cam_call(&"add_fov_boost", [(5.0 + 10.0 * pulse) * dt])
	elif _nitro_was_active:
		_cam_call(&"add_fov_boost", [-0.8])
	_nitro_was_active = nitro_on


func _make_smoke(node_name: String, local_pos: Vector3) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.name = node_name
	# 烟团更小、更密、更贴地：旧版单团最大近 3.6m，飘出去像一团云。
	p.amount = clampi(int(round(SMOKE_BASE_AMOUNT * 1.7 * _particle_scale())), 18, 88)
	p.lifetime = 1.26
	p.one_shot = false
	p.explosiveness = 0.0
	p.local_coords = false
	p.direction = Vector3(0.0, 0.52, -0.66)
	p.spread = 26.0
	p.gravity = Vector3(0.0, 0.55, 0.0)
	p.initial_velocity_min = 0.40
	p.initial_velocity_max = 1.50
	p.damping_min = 1.2
	p.damping_max = 3.0
	p.angle_min = -180.0
	p.angle_max = 180.0
	p.scale_amount_min = 0.50
	p.scale_amount_max = 1.60
	p.visibility_aabb = AABB(Vector3(-9.0, -2.0, -34.0), Vector3(18.0, 12.0, 38.0))

	var ramp := Gradient.new()
	ramp.offsets = PackedFloat32Array([0.0, 0.06, 0.46, 1.0])
	ramp.colors = PackedColorArray([
		Color(0.92, 0.94, 0.98, 0.0),
		Color(0.96, 0.97, 1.00, 0.96),
		Color(0.86, 0.88, 0.92, 0.54),
		Color(0.74, 0.75, 0.78, 0.0),
	])
	p.color_ramp = ramp

	var quad := QuadMesh.new()
	quad.size = Vector2(1.02, 1.02)
	quad.material = VfxLibrary.smoke_material(false)
	p.mesh = quad
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.position = local_pos
	p.position.y = 0.18
	p.emitting = false
	if car_ref != null and is_instance_valid(car_ref):
		car_ref.add_child(p)
	else:
		add_child(p)
	return p


## 起步瞬间的一团贴地摩擦烟（四驱四轮、后驱后轮，一次性爆开）。
func _spawn_launch_smoke(car: Car) -> void:
	var puffs: Array = [
		[_rear_wheel_offset(-1.0), 1.0],
		[_rear_wheel_offset(1.0), 1.0],
	]
	if String(car.drivetrain).to_upper() == "AWD":
		puffs.append([_front_wheel_offset(-1.0), 0.55])
		puffs.append([_front_wheel_offset(1.0), 0.55])
	for entry in puffs:
		var local: Vector3 = entry[0]
		var k: float = entry[1]
		var p := CPUParticles3D.new()
		p.name = "GameFeelLaunchSmoke"
		p.amount = clampi(int(round(40.0 * k * _particle_scale())), 12, 48)
		p.lifetime = 1.15
		p.one_shot = true
		p.explosiveness = 0.90
		p.local_coords = false
		p.direction = Vector3(0.0, 0.50, -0.55)
		p.spread = 30.0
		p.gravity = Vector3(0.0, 0.45, 0.0)
		p.initial_velocity_min = 0.60
		p.initial_velocity_max = 2.00
		p.damping_min = 1.2
		p.damping_max = 3.0
		p.angle_min = -180.0
		p.angle_max = 180.0
		p.scale_amount_min = 0.55
		p.scale_amount_max = 1.70
		p.visibility_aabb = AABB(Vector3(-8.0, -2.0, -18.0), Vector3(16.0, 10.0, 22.0))
		var ramp := Gradient.new()
		ramp.offsets = PackedFloat32Array([0.0, 0.06, 0.46, 1.0])
		ramp.colors = PackedColorArray([
			Color(0.94, 0.95, 0.98, 0.0),
			Color(0.98, 0.99, 1.00, 1.0),
			Color(0.88, 0.89, 0.92, 0.56),
			Color(0.76, 0.77, 0.80, 0.0),
		])
		p.color_ramp = ramp
		var quad := QuadMesh.new()
		quad.size = Vector2(1.15, 1.15) * lerpf(0.82, 1.0, k)
		quad.material = VfxLibrary.smoke_material(false)
		p.mesh = quad
		p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		local.y = 0.24
		p.position = local
		car.add_child(p)
		p.emitting = true
		_transient.append({
			"node": p,
			"deadline_ms": Time.get_ticks_msec() + 1800,
		})


## 氮气不再从排气管喷火（逐车排气位对齐成本高、观感参差），
## 改成屏幕空间的全屏蓝光冲刺：边缘渐晕 + 放射速度线 + 中心脉冲光斑。
func _build_nitro_overlay() -> void:
	if _nitro_layer != null and is_instance_valid(_nitro_layer):
		return
	var layer := CanvasLayer.new()
	layer.name = "GameFeelNitroLayer"
	layer.layer = 6
	layer.visible = false
	add_child(layer)
	var root := Control.new()
	root.name = "NitroRoot"
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(root)
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_nitro_glow = _make_screen_rect("NitroGlow", VfxLibrary.nitro_vignette_texture(), root, false)
	_nitro_streaks = _make_screen_rect("NitroStreaks", VfxLibrary.nitro_streak_texture(), root, true)
	# 全屏底色：亮场景里单靠边缘晕影不够，整屏轻染蓝让「噗」的一下更有冲击。
	_nitro_tint = ColorRect.new()
	_nitro_tint.name = "NitroTint"
	_nitro_tint.color = Color(0.18, 0.50, 1.0, 0.0)
	_nitro_tint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_nitro_tint)
	_nitro_tint.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_nitro_flash = _make_screen_rect("NitroFlash", VfxLibrary.nitro_flash_texture(), root, true)
	_nitro_glow.modulate.a = 0.0
	_nitro_streaks.modulate.a = 0.0
	_nitro_flash.modulate.a = 0.0
	_nitro_layer = layer


func _make_screen_rect(node_name: String, tex: Texture2D, parent: Control, additive: bool) -> TextureRect:
	var rect := TextureRect.new()
	rect.name = node_name
	rect.texture = tex
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_SCALE
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if additive:
		var mat := CanvasItemMaterial.new()
		mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
		rect.material = mat
	parent.add_child(rect)
	rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	return rect


func _update_nitro_screen(car: Car, active: bool, dt: float) -> void:
	if car == null:
		return
	var on := active and car.nitro_active and absf(car.speed_kph) > 2.0
	_nitro_vis = move_toward(_nitro_vis, 1.0 if on else 0.0, dt * (7.0 if on else 5.0))
	if _nitro_layer == null or not is_instance_valid(_nitro_layer):
		return
	if _nitro_vis <= 0.01:
		_nitro_layer.visible = false
		return
	_nitro_layer.visible = true
	_nitro_pulse_clock += dt
	# 3.3Hz 的正弦脉冲 → “噗、噗、噗”往前推的节奏感；白天也要能看见，峰值留宽一点。
	var pulse := pow(maxf(0.0, sin(_nitro_pulse_clock * TAU * 3.3)), 4.0)
	var speed_k := clampf(absf(car.speed_kph) / 200.0, 0.45, 1.0)
	# 常驻蓝光保持存在感，脉冲再猛推一把；否则白天截图/驾驶时几乎看不见。
	if _nitro_glow != null:
		_nitro_glow.modulate.a = _nitro_vis * (0.62 + 0.38 * pulse) * speed_k
	if _nitro_streaks != null:
		_nitro_streaks.modulate.a = _nitro_vis * (0.48 + 0.52 * pulse) * speed_k
		_nitro_streaks.pivot_offset = _nitro_streaks.size * 0.5
		_nitro_streaks.scale = Vector2.ONE * (1.0 + 0.12 * pulse)
	if _nitro_tint != null:
		_nitro_tint.color.a = _nitro_vis * speed_k * (0.085 + 0.20 * pulse)
	if _nitro_flash != null:
		_nitro_flash.modulate.a = _nitro_vis * (0.10 + 0.40 * pulse) * speed_k
		_nitro_flash.pivot_offset = _nitro_flash.size * 0.5
		_nitro_flash.scale = Vector2.ONE * (1.0 + 0.05 * pulse)


func _free_nitro_overlay() -> void:
	if _nitro_layer != null and is_instance_valid(_nitro_layer):
		_nitro_layer.queue_free()
	_nitro_layer = null
	_nitro_glow = null
	_nitro_streaks = null
	_nitro_tint = null
	_nitro_flash = null
	_nitro_vis = 0.0
	_nitro_pulse_clock = 0.0


func _build_skid_marks() -> void:
	if race_root == null or not is_instance_valid(race_root):
		return
	if _skid_mm != null and is_instance_valid(_skid_mm):
		_skid_mm.queue_free()
	var quad := QuadMesh.new()
	quad.size = Vector2(0.26, 0.34)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.015, 0.012, 0.01, 0.42)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	mat.disable_receive_shadows = true
	quad.material = mat
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = quad
	mm.instance_count = SKID_MAX
	for i in SKID_MAX:
		mm.set_instance_transform(i, Transform3D(Basis().scaled(Vector3.ZERO), Vector3.ZERO))
	_skid_mm = MultiMeshInstance3D.new()
	_skid_mm.name = "GameFeelSkidMarks"
	_skid_mm.multimesh = mm
	_skid_mm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	race_root.add_child(_skid_mm)
	_skid_index = 0
	_skid_timer = 0.0


func _update_skid_marks(car: Car, active: bool, dt: float) -> void:
	if not active or _skid_mm == null or not is_instance_valid(_skid_mm) or car == null:
		return
	_skid_timer -= dt
	if _skid_timer > 0.0:
		return
	_skid_timer = 0.035
	var heading := car.heading
	var gbasis := Basis(Vector3.UP, heading) * Basis(Vector3.RIGHT, -PI * 0.5)
	for side in [-1.0, 1.0]:
		var local := _rear_wheel_offset(side)
		var wp := car.to_global(local)
		wp.y = maxf(car.global_position.y, Terrain.height_at(wp)) + 0.022
		var xf := Transform3D(gbasis.scaled(Vector3(1.0, 1.0, 1.0)), wp)
		(_skid_mm.multimesh as MultiMesh).set_instance_transform(_skid_index % SKID_MAX, xf)
		_skid_index += 1


func _make_billboard_material(use_vertex_color: bool, additive: bool) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.billboard_keep_scale = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.disable_receive_shadows = true
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	mat.vertex_color_use_as_albedo = use_vertex_color
	mat.albedo_color = Color(1.0, 1.0, 1.0, 1.0)
	if additive:
		mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	return mat


func _rear_wheel_offset(side: float) -> Vector3:
	return _wheel_offset("RL" if side < 0.0 else "RR",
		Vector3(-0.76 * side, 0.08, -1.42))


func _front_wheel_offset(side: float) -> Vector3:
	return _wheel_offset("FL" if side < 0.0 else "FR",
		Vector3(-0.76 * side, 0.08, 1.42))


func _wheel_offset(suffix: String, fallback: Vector3) -> Vector3:
	# 贴近接地面：y 只比地面高 8cm，前后只比轮心后移 4cm，
	# 烟一冒出来就包住轮胎，而不是飘在车后一米外。
	if car_ref != null and is_instance_valid(car_ref):
		var wheel := car_ref.find_child("Spin_Wheel_" + suffix, true, false) as Node3D
		if wheel == null:
			wheel = car_ref.find_child("Wheel_" + suffix, true, false) as Node3D
		if wheel != null:
			var local := car_ref.to_local(wheel.global_position)
			local.y = 0.08
			local.z -= 0.04
			return local
	return fallback


# ---------------------------------------------------------------------------
# 清理 / 小工具
# ---------------------------------------------------------------------------

func _free_car_particles() -> void:
	for p in [_smoke_left, _smoke_right, _smoke_fl, _smoke_fr]:
		if p != null and is_instance_valid(p):
			p.emitting = false
			p.queue_free()
	_smoke_left = null
	_smoke_right = null
	_smoke_fl = null
	_smoke_fr = null
	if _skid_mm != null and is_instance_valid(_skid_mm):
		_skid_mm.queue_free()
	_skid_mm = null


func _set_emitting(p: CPUParticles3D, enabled: bool) -> void:
	if p == null or not is_instance_valid(p):
		return
	if p.emitting != enabled:
		p.emitting = enabled


func _cam_call(method: StringName, args: Array) -> void:
	if cam == null or not is_instance_valid(cam):
		return
	if not cam.has_method(method):
		return
	cam.callv(method, args)


func _particle_scale() -> float:
	var settings := get_node_or_null("/root/Settings")
	if settings != null and settings.has_method("particle_scale"):
		return clampf(float(settings.call("particle_scale")), 0.35, 1.6)
	return 1.0


func _read_ref(source: Node, property: String) -> Variant:
	if source == null or not is_instance_valid(source):
		return null
	for entry in source.get_property_list():
		if String(entry.get("name", "")) == property:
			return source.get(property)
	return null
