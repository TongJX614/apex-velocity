class_name RealAssetKit
extends RefCounted
## 高品质 CC0 真实资产的统一接入层（Poly Haven，CC0 1.0）。
##
## 源模型是摄影测量高模，Blender 减面成 LOD 后放在 assets/venues/。
## 这里负责把它们安全地 MultiMesh 化：
##   · 按「每个 surface 一个材质」拆解，避免多材质模型被 material_override
##     覆盖成单张贴图（模块化厂房/围栏有多种材质，必须逐 surface 处理）；
##   · 按 180m 网格分块，与扇区剔除 / 转向预取完全兼容；
##   · 统一可见距离、阴影开关与画质档倍率。
##
## 所有低模手建资产都应该走这里替换，不再用程序化球/圆柱/盒子拼场景。

const ROOT := "res://assets/venues/"
# 真实建筑模型（带完整 PBR + 自发光材质的高模塔楼）放在独立目录。
const EXTRA_ROOTS := ["res://assets/buildings/"]

static var _surfaces: Dictionary = {}
static var _packed: Dictionary = {}
static var _sizes: Dictionary = {}
static var _true_radius: Dictionary = {}

# --- 装饰采集（烘焙用）------------------------------------------------------
# 场景装饰原本是「固定随机种子现场撒出来」的，代码里没有「某一棵树」这种身份，
# 也就无法在编辑器里选中它。开启采集后，place_chunked / place_unique 会把每个
# 摆放实例的 (资产, 变换, 类别) 记下来，供 --bake-decor 导出成
# data/decor/<track>.json。之后渲染就走这份数据，装饰才真正可寻址、可编辑。
#
# 草类不采集：单条赛道 2 万个，手改没有意义，保持程序化。
static var capture_enabled := false
static var captured: Array = []


static func capture_begin() -> void:
	capture_enabled = true
	captured.clear()


static func capture_end() -> Array:
	capture_enabled = false
	return captured


## 资产 → 可编辑类别。返回空字符串表示不采集（草、地面覆盖物）。
static func category_of(asset: String) -> String:
	if asset.begins_with("grass_") or asset.begins_with("weed") or asset == "moss_real":
		return ""
	if asset.begins_with("realtree") or asset == "tree_small_02":
		return "tree"
	if asset.begins_with("shrub"):
		return "shrub"
	if asset.begins_with("boulder") or asset in ["coast_rocks", "rock_face", "mountain_real"]:
		return "rock"
	if asset.contains("facade") or asset == "pit_building" or asset == "grandstand":
		return "building"
	return "prop"


static func _capture(asset: String, xform: Transform3D, label: String = "") -> void:
	if not capture_enabled:
		return
	var cat := category_of(asset)
	if cat.is_empty():
		return
	captured.append({"asset": asset, "cat": cat, "xf": xform, "label": label})



static func clear_cache() -> void:
	_surfaces.clear()
	_packed.clear()
	_sizes.clear()


static func _resolve(asset: String) -> String:
	for root in [ROOT] + EXTRA_ROOTS:
		var p: String = (root as String) + asset + ".glb"
		if ResourceLoader.exists(p) or FileAccess.file_exists(p):
			return p
	return ""


static func has(asset: String) -> bool:
	return _resolve(asset) != ""


static func _packed_scene(asset: String) -> PackedScene:
	if _packed.has(asset):
		return _packed[asset]
	var path := _resolve(asset)
	var packed: PackedScene = null
	if not path.is_empty() and ResourceLoader.exists(path):
		packed = load(path) as PackedScene
	if packed == null:
		# 刚拷进 assets/venues 的 .glb 还没走过 Godot 的导入流水线，
		# load() 拿不到它。现场用 GLTFDocument 解析，下游代码完全无感。
		packed = _pack_via_gltf(path)
	_packed[asset] = packed
	return packed


## 运行时加载未经导入的 glTF/GLB，打包成 PackedScene 以便复用现有拆分逻辑。
static func _pack_via_gltf(path: String) -> PackedScene:
	if not FileAccess.file_exists(path):
		return null
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_file(ProjectSettings.globalize_path(path), state) != OK:
		return null
	var node := doc.generate_scene(state)
	if node == null:
		return null
	var ps := PackedScene.new()
	var err := ps.pack(node)
	node.queue_free()
	return ps if err == OK else null


## 实例化一个资产（已导入走缓存，未导入走运行时解析）。
static func instance(asset: String) -> Node3D:
	var packed := _packed_scene(asset)
	if packed == null:
		return null
	return packed.instantiate() as Node3D


## 当前画质档位（0..N）。
##
## Settings 是 autoload，在 `--script`（SceneTree 工具脚本）模式下不会被实例化。
## 原来这里直接写 `Settings.index`，后果是整个 real_asset_kit.gd 在工具模式下
## 编译失败（"Identifier not found: Settings"），连带 size()/true_radius() 全部不可用，
## 资产尺度只能靠 Python 猜。改成运行时空值查找后，工具脚本也能拿到真实尺寸。
static func _quality_index() -> int:
	var loop := Engine.get_main_loop()
	if loop is SceneTree:
		var st := loop as SceneTree
		if st.root != null and st.root.has_node("Settings"):
			var node := st.root.get_node("Settings")
			if node != null:
				var v: Variant = node.get("index")
				if v != null:
					return int(v)
	return 2


## 画质档对应的可见距离系数（LOW 0.75 → ULTRA 1.5）。
## place_chunked 用它乘 vis_end；开放世界按当前档位归一化，
## 保证各档位拿到一致的实际可见距离。
static func quality_mul() -> float:
	return 0.75 + float(_quality_index()) * 0.25


## 当前档位的模型 LOD 偏移（低档更早切低模，超高档满精度留更远）。
## 与 _quality_index() 同样的运行时空值查找，工具脚本模式下退回 1.0。
static func _lod_bias() -> float:
	var loop := Engine.get_main_loop()
	if loop is SceneTree:
		var st := loop as SceneTree
		if st.root != null and st.root.has_node("Settings"):
			var node := st.root.get_node("Settings")
			if node != null and node.has_method("lod_bias"):
				return float(node.call("lod_bias"))
	return 1.0


## 模型的合并 AABB 尺寸。Poly Haven 资产尺寸差异极大（草 1.7m、
## 礁石地形 59m、厂房立面 78m），摆放必须按实际尺寸归一化。
static func size(asset: String) -> Vector3:
	if _sizes.has(asset):
		return _sizes[asset]
	var result := Vector3.ONE
	var packed := _packed_scene(asset)
	if packed != null:
		var tpl := packed.instantiate() as Node3D
		if tpl != null:
			var box := AABB()
			var first := true
			for node in tpl.find_children("*", "MeshInstance3D", true, false):
				var mi := node as MeshInstance3D
				if mi == null or mi.mesh == null:
					continue
				# 必须用「相对模板根的全相对变换」：部分 GLB 有嵌套中间节点，
				# 只用 mi.transform（局部）会漏掉中间层偏移，量出的包围盒偏小，
				# 按它推的摆放净空会漏树冠。
				var a: AABB = _rel_transform(mi, tpl) * mi.mesh.get_aabb()
				if first:
					box = a
					first = false
				else:
					box = box.merge(a)
			if not first:
				result = box.size
			tpl.free()
	_sizes[asset] = result
	return result


## 目标高度 → 缩放倍率。Poly Haven 的自然资产里很多是「局部扫描」
## （草簇 16cm、苔藓 4cm、灌木枝条 40cm），按包围盒宽度归一化会越缩越小；
## 摆放一律用「想要多高」反推倍率。
static func scale_for_height(asset: String, target_height: float) -> float:
	var h := maxf(size(asset).y, 0.001)
	return target_height / h


## 资产缩放后的「水平占位外接半径」（米）。
##
## 摆放净空必须用它，不能只看「楼心离路多远」：
## 一栋 88m 宽的楼放在离路中心线 30m 的地方，物理上仍然骑在路面上——
## 这正是天际环城"贴脸一整面橙墙"的成因。
## 取 XZ 包围盒对角线的一半：楼是随机偏航摆放的，
## 只有外接圆半径能保证任意朝向下都不会压到路。
static func footprint_radius(asset: String, scale: float) -> float:
	var s := size(asset)
	return 0.5 * Vector2(s.x, s.z).length() * maxf(scale, 0.001)


## 按目标高度反推倍率，并把水平占位半径限制在 max_footprint 之内。
## 返回实际可用的倍率（= 原倍率与占位上限二者取小）。
##
## 很多 Poly Haven 建筑是"躺平"的低模：qt_block1_large 天然只有 4.67m 高、
## 102m 长，按目标高度放大后会变成一块 60m 高、100m 宽的墙板。
## 这里用占位半径兜底，宁可楼矮一点，也不让楼变成一堵横在路中间的墙。
static func scale_for_height_capped(asset: String, target_height: float,
		max_footprint: float) -> float:
	var by_height := scale_for_height(asset, target_height)
	var nat := footprint_radius(asset, 1.0)
	if nat <= 0.001:
		return by_height
	return minf(by_height, max_footprint / nat)


## glTF 里不少材质声明了 alphaMode=BLEND，但贴图是 JPEG、根本没有 alpha
## 通道（例如 Poly Haven 的链网围栏）。这种材质在 Godot 里会退化成半透明
## 深色板，远处糊成一片黑板。这里统一纠正：
##   · 有 alpha → ALPHA_SCISSOR（比 BLEND 便宜，且没有排序问题）
##   · 无 alpha → 直接不透明
static func normalize_material(mat: Material) -> Material:
	if not (mat is StandardMaterial3D):
		return mat
	var src := mat as StandardMaterial3D
	# glTF 的自发光语义是「颜色 × 贴图」，而 Godot 默认 OP_ADD 是「颜色 + 贴图」：
	# 自发光系数非黑的导入材质会把整张贴图当光叠加，白天模型变白墙。
	if src.emission_enabled and src.emission_operator != BaseMaterial3D.EMISSION_OP_MULTIPLY:
		src.emission_operator = BaseMaterial3D.EMISSION_OP_MULTIPLY
	if src.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED:
		_apply_texture_filter(src)
		return src
	var out := src.duplicate() as StandardMaterial3D
	var alpha_ok := false
	if out.albedo_texture != null:
		var img := out.albedo_texture.get_image()
		alpha_ok = img != null and img.detect_alpha() != Image.ALPHA_NONE
	if alpha_ok:
		out.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		out.alpha_scissor_threshold = 0.45
		out.cull_mode = BaseMaterial3D.CULL_DISABLED
	else:
		out.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	_apply_texture_filter(out)
	return out


static func _apply_texture_filter(mat: BaseMaterial3D) -> void:
	if mat.albedo_texture != null:
		mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC


## glTF 建筑资产里名字带 emissive/emission/light 的材质，导入后自发光常是
## 关着的（glTF 里 emissiveFactor 为 0，Godot 原样导入）。夜景里整栋楼
## 只剩黑影——楼里的灯牌/窗光全灭。这里把 albedo 贴图当自发光遮罩重新
## 点亮：MULTIPLY 语义下只有贴图亮部（灯/窗）发光，不会变白墙。
static func _revive_emissive(mat: Material) -> Material:
	if not (mat is StandardMaterial3D):
		return mat
	var sm := mat as StandardMaterial3D
	var n := sm.resource_name.to_lower()
	var emissive_named := n.contains("emissive") or n.contains("emission") \
		or n.contains("light_on") or n.ends_with("light")
	if not emissive_named or sm.albedo_texture == null or sm.emission_enabled:
		return sm
	var out := sm.duplicate() as StandardMaterial3D
	out.emission_enabled = true
	out.emission_operator = BaseMaterial3D.EMISSION_OP_MULTIPLY
	out.emission_texture = out.albedo_texture
	out.emission = Color(1.0, 1.0, 1.0)
	out.emission_energy_multiplier = 2.0
	return out


## 夜景/城市赛道：把建筑立面的漫反射贴图复用到自发光通道，
## 让窗户在夜里亮起来，而不是整条街黑成一片。
static func make_emissive(node: Node3D, energy: float) -> void:
	for child in node.find_children("*", "MeshInstance3D", true, false):
		var mi := child as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		# glTF 导入器常常把材质放在 material_override 上，必须优先取它，
		# 否则 surface 材质为空，整段逻辑会静默失效。
		if mi.material_override != null:
			var base := mi.material_override
			if base is StandardMaterial3D:
				var dup := (base as StandardMaterial3D).duplicate() as StandardMaterial3D
				if dup.albedo_texture != null:
					dup.emission_enabled = true
					# 默认 OP_ADD 会把整张漫反射贴图当作叠加光，白天照片会变成白墙；
					# MULTIPLY 只让贴图里的亮部（窗户）发光
					dup.emission_operator = BaseMaterial3D.EMISSION_OP_MULTIPLY
					dup.emission_texture = dup.albedo_texture
					dup.emission = Color(1.0, 0.94, 0.82)
					dup.emission_energy_multiplier = energy
					mi.material_override = dup
			continue
		for s in mi.mesh.get_surface_count():
			var mat := mi.get_surface_override_material(s)
			if mat == null:
				mat = mi.mesh.surface_get_material(s)
			if not (mat is StandardMaterial3D):
				continue
			var out := (mat as StandardMaterial3D).duplicate() as StandardMaterial3D
			if out.albedo_texture == null:
				continue
			out.emission_enabled = true
			out.emission_operator = BaseMaterial3D.EMISSION_OP_MULTIPLY
			out.emission_texture = out.albedo_texture
			out.emission = Color(1.0, 0.94, 0.82)
			out.emission_energy_multiplier = energy
			mi.set_surface_override_material(s, out)


## 夜景压暗：真实建筑立面是白天拍的贴图，夜里直接摆上去会像一块发光的白墙。
## 乘一个系数让它退回夜色里的剪影，只保留轮廓。
static func darken_albedo(node: Node3D, factor: float) -> void:
	for child in node.find_children("*", "MeshInstance3D", true, false):
		var mi := child as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		if mi.material_override is StandardMaterial3D:
			var om := (mi.material_override as StandardMaterial3D).duplicate() as StandardMaterial3D
			om.albedo_color = Color(
				om.albedo_color.r * factor, om.albedo_color.g * factor,
				om.albedo_color.b * factor, om.albedo_color.a)
			om.emission_energy_multiplier *= factor
			mi.material_override = om
			continue
		for s in mi.mesh.get_surface_count():
			var mat := mi.get_surface_override_material(s)
			if mat == null:
				mat = mi.mesh.surface_get_material(s)
			if not (mat is StandardMaterial3D):
				continue
			var out := (mat as StandardMaterial3D).duplicate() as StandardMaterial3D
			out.albedo_color = Color(
				out.albedo_color.r * factor,
				out.albedo_color.g * factor,
				out.albedo_color.b * factor,
				out.albedo_color.a)
			out.emission_energy_multiplier *= factor
			mi.set_surface_override_material(s, out)


static func _rel_transform(node: Node3D, root: Node3D) -> Transform3D:
	var t := Transform3D.IDENTITY
	var cur: Node = node
	while cur != null and cur != root:
		if cur is Node3D:
			t = (cur as Node3D).transform * t
		cur = cur.get_parent()
	return t


## 把一个 GLB 模板拆成 [{mesh: ArrayMesh, material: Material, rel: Transform3D}]。
## 每个条目只含一个 surface，MultiMesh 时贴图与材质不会串。
static func surfaces(asset: String) -> Array:
	if _surfaces.has(asset):
		return _surfaces[asset]
	var out: Array = []
	var packed := _packed_scene(asset)
	if packed != null:
		var tpl := packed.instantiate() as Node3D
		if tpl != null:
			for node in tpl.find_children("*", "MeshInstance3D", true, false):
				var mi := node as MeshInstance3D
				if mi == null or mi.mesh == null:
					continue
				var src: Mesh = mi.mesh
				var rel := _rel_transform(mi, tpl)
				for s in src.get_surface_count():
					var arrays := src.surface_get_arrays(s)
					if arrays.is_empty():
						continue
					var am := ArrayMesh.new()
					am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
					var mat: Material = mi.material_override
					if mat == null:
						mat = mi.get_surface_override_material(s)
					if mat == null:
						mat = src.surface_get_material(s)
					mat = normalize_material(mat)
					mat = _revive_emissive(mat)
					am.surface_set_material(0, mat)
					out.append({"mesh": am, "material": mat, "rel": rel})
					# 真实渲染半径：对顶点抽样、经 rel 变换后的模板空间水平半径。
					# AABB 会低估（GLB 嵌套变换/压缩 AABB 精度问题，实测可差 1.5~1.9 倍），
					# 摆放净空必须以顶点实测为准。
					var verts := arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array
					if verts != null:
						# 逐顶点实测，不能抽样：建筑脚印的极值顶点就在四角，
						# 抽样漏掉角点会让净空半径低估好几米（楼体压护栏就是这么来的）
						for tv_v in verts:
							var tv := rel * tv_v
							_true_radius[asset] = maxf(float(_true_radius.get(asset, 0.0)),
								Vector2(tv.x, tv.z).length())
			tpl.free()
	_surfaces[asset] = out
	return out


## 模板空间的「顶点实测水平半径」：摆放净空用它乘以实例缩放，
## 保证任何 yaw 旋转下顶点都落在净空圈内。
static func true_radius(asset: String) -> float:
	if not _surfaces.has(asset):
		surfaces(asset)
	return float(_true_radius.get(asset, 0.0))


## 按实例分布自适应分块。
## 以前是写死的 180m 网格并 clamp 到 0..3，一旦赛道范围超过 720m，
## 全赛道的草就会被塞进最后几格，形成「一块覆盖全赛道」的超大分块：
## 扇区剔除按分块中心方向判定，中心在身后时整块（包括脚下这片草）直接消失。
## 现在按实际分布划分 N×N 网格，每块只覆盖一小段路，剔除才真正有效。
static func _groups(transforms: Array[Transform3D]) -> Array:
	var mn := Vector2(1e9, 1e9)
	var mx := Vector2(-1e9, -1e9)
	for xform in transforms:
		var o := xform.origin
		mn.x = minf(mn.x, o.x)
		mn.y = minf(mn.y, o.z)
		mx.x = maxf(mx.x, o.x)
		mx.y = maxf(mx.y, o.z)
	var span := mx - mn
	var cell := clampf(maxf(span.x, span.y) / 6.0, 40.0, 180.0)
	var nx := clampi(int(ceil(span.x / cell)) + 1, 1, 6)
	var nz := clampi(int(ceil(span.y / cell)) + 1, 1, 6)
	var groups: Array = []
	for i in nx * nz:
		groups.append([])
	for xform in transforms:
		var o := xform.origin
		var gx := clampi(int((o.x - mn.x) / cell), 0, nx - 1)
		var gz := clampi(int((o.z - mn.y) / cell), 0, nz - 1)
		(groups[gx * nz + gz] as Array).append(xform)
	return groups


## 植被资产识别：树木/棕榈/灌木/草/蕨类按名字归类，
## 用来开逐实例色差（MultiMesh 实例色）与高清档阴影。
static func is_vegetation(asset: String) -> bool:
	var a := asset.to_lower()
	for key in ["tree", "palm", "pine", "fir", "bush", "shrub", "fern", "grass",
			"quiver", "broadleaf", "cypress", "willow"]:
		if a.contains(key):
			return true
	return false


## 按世界坐标做确定性哈希，给出 0.86~1.08 亮度 + 冷暖偏移的实例色。
## 同一棵树每次生成的颜色一致，截图/回放不会变。
static func vegetation_tint(origin: Vector3) -> Color:
	var h1 := fposmod(sin(origin.x * 12.9898 + origin.z * 78.233) * 43758.5453, 1.0)
	var h2 := fposmod(sin(origin.x * 39.346 + origin.z * 11.135) * 24634.6345, 1.0)
	var bright := 0.86 + h1 * 0.22
	var warm := (h2 - 0.5) * 0.16
	return Color(bright * (1.0 + warm), bright * (1.0 + warm * 0.35),
		bright * (1.0 - warm))


## 分块批量摆放。prefix 用于命名，方便调试；vis_end 为基准可见距离。
## respect_solids=false 用于城市模型/英雄塔：楼群与量块楼 interleaved
## 是城市峡谷设计，间距由楼位规则自己控制，不走已登记实体过滤。
static func place_chunked(container: Node3D, asset: String, transforms: Array[Transform3D],
		prefix: String, vis_end: float, cast_shadow: bool, stats: Dictionary = {},
		respect_solids: bool = true) -> int:
	if transforms.is_empty() or container == null:
		return 0
	var parts := surfaces(asset)
	if parts.is_empty():
		return 0
	var mul: float = quality_mul()
	# 赛道禁入区过滤：几何压进路面的摆放直接丢弃（穿模修复）。
	# 半径用「顶点实测渲染半径」×实例缩放，AABB 半径会低估树冠/悬角。
	var asset_radius := true_radius(asset)
	var is_solid := is_solid_asset(asset)
	# 灯杆/电杆/配电箱也是实体：广告牌/裁判位/后摆的石头都要让开
	# （pass_lamp×广告牌、CityUtilityBoxes×ad_board）
	var solid_reg := is_solid or asset.contains("lamp") or asset.contains("pole") \
		or asset.contains("utility")
	var kept: Array[Transform3D] = []
	var kept_rad: PackedFloat32Array = []
	for xform in transforms:
		var sc: float = maxf(xform.basis.get_scale().x, xform.basis.get_scale().z)
		var r := asset_radius * maxf(sc, 0.01)
		# 场馆保护区（起跑主直道）不放石头，避免砸进看台/维修区/大屏
		if is_solid and Terrain.active and Terrain.in_venue_zone(xform.origin):
			continue
		# 已登记实体互斥（先查后登记）。石头留 50% 搭边带：同族散点靠边、
		# 石块嵌进孤丘基座都是造型，只拦「整只埋进去」；灯杆/电杆与碎石/
		# 油桶/树等非实体件几乎全半径避开。CityModel/英雄塔不走这道过滤
		# （楼群 interleaved 设计，见 respect_solids 参数说明）。
		if respect_solids:
			var clear_r := r * 0.5 if is_solid else (r * 0.9 if solid_reg else maxf(r * 0.8, 1.0))
			if not solid_clear(xform.origin, clear_r):
				continue
		if keepout_clear(xform.origin, r):
			kept.append(xform)
			if solid_reg:
				kept_rad.append(r)
	if kept.is_empty():
		return 0
	transforms = kept
	if solid_reg:
		for i in kept.size():
			register_solid((kept[i] as Transform3D).origin, kept_rad[i])
	var groups := _groups(transforms)
	if capture_enabled:
		for xform in transforms:
			_capture(asset, xform)
	var created := 0
	var s_idx := 0
	var veg := is_vegetation(asset)
	for part in parts:
		var mesh: Mesh = part["mesh"]
		var mat: Material = part["material"]
		if mat == null:
			var fallback := StandardMaterial3D.new()
			fallback.albedo_color = Color(0.6, 0.6, 0.58)
			mat = fallback
		# 植被材质启用实例色作为反照率乘子（同一 GLB 材质的树冠有深浅冷暖差）
		if veg and mat is StandardMaterial3D:
			(mat as StandardMaterial3D).vertex_color_use_as_albedo = true
		var rel: Transform3D = part["rel"]
		for g in groups.size():
			var arr: Array = groups[g]
			if arr.is_empty():
				continue
			var typed: Array[Transform3D] = []
			for xform in arr:
				typed.append(xform as Transform3D)
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.mesh = mesh
			if veg:
				mm.use_colors = true
			mm.instance_count = typed.size()
			for i in typed.size():
				mm.set_instance_transform(i, typed[i] * rel)
				if veg:
					mm.set_instance_color(i, vegetation_tint((typed[i] as Transform3D).origin))
			var mmi := MultiMeshInstance3D.new()
			mmi.multimesh = mm
			mmi.material_override = mat
			mmi.lod_bias = _lod_bias()
			# 名字必须含资产名：同一 prefix 下多个资产（CityModel 摆 qt_block4
			# 再摆 qt_block1_large）的 chunk 序号会撞车，撞名节点被引擎改成
			# @MultiMeshInstance3D@OID 占位名，调试时无法溯源。
			mmi.name = "%s_%s_s%d_g%d" % [prefix, asset, s_idx, g]
			# 标记来源资产，装饰编辑器靠这个认出「这是可以编辑的真实装饰」。
			# 一个资产会被拆成多个 surface 节点（s0/s1/s2），它们装的是同一批实例，
			# 编辑时必须当成一个整体，所以把 group/chunk/surface 也记下来。
			mmi.set_meta("decor_asset", asset)
			# group 里必须带上资产名：place_chunked 的 prefix 是给节点起名用的，
			# 不同资产共用同一个 prefix 时（海边棕榈就是 tree_palm_tall / tree_palm_bent
			# 都用 "CoastPalms" 摆同一批点），只靠 prefix + chunk 会让两组实例的 key
			# 完全撞车 —— 编辑器里只能选中其中一种，另一种点上去毫无反应。
			mmi.set_meta("decor_group", "%s__%s" % [prefix, asset])
			mmi.set_meta("decor_chunk", g)
			mmi.set_meta("decor_surface", s_idx)
			mmi.visibility_range_end = vis_end * mul
			mmi.visibility_range_end_margin = vis_end * 0.12
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if cast_shadow else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			container.add_child(mmi)
			created += 1
		s_idx += 1
	if not stats.is_empty():
		stats["nodes"] = int(stats.get("nodes", 0)) + created
		stats["instances"] = int(stats.get("instances", 0)) + s_idx * transforms.size()
	return created


## 单个摆放（建筑立面、路灯等不需要 MultiMesh 的构件），保留完整节点树与材质。
static func place_unique(container: Node3D, asset: String, xform: Transform3D,
		node_name: String, stats: Dictionary = {}) -> Node3D:
	if container == null:
		return null
	var packed := _packed_scene(asset)
	if packed == null:
		return null
	var inst := packed.instantiate() as Node3D
	if inst == null:
		return null
	inst.name = node_name
	inst.transform = xform
	# 赛道禁入区过滤：按实例实际包围盒半径判断，压到赛道的直接丢弃
	var radius := _scene_radius(inst)
	if not keepout_clear(xform.origin, radius):
		inst.free()
		if not stats.is_empty():
			stats["rejected"] = int(stats.get("rejected", 0)) + 1
		return null
	inst.set_meta("decor_asset", asset)
	var bias := _lod_bias()
	if inst is GeometryInstance3D:
		(inst as GeometryInstance3D).lod_bias = bias
	for node in inst.find_children("*", "GeometryInstance3D", true, false):
		(node as GeometryInstance3D).lod_bias = bias
	if is_solid_asset(asset):
		register_solid(xform.origin, radius)
	container.add_child(inst)
	_capture(asset, xform, node_name)
	if not stats.is_empty():
		stats["nodes"] = int(stats.get("nodes", 0)) + 1
		stats["instances"] = int(stats.get("instances", 0)) + 1
	return inst


# ---------------------------------------------------------------------------
# 赛道禁入区（keepout）：SceneryKit.build 开赛时写入整环赛道采样点，
# 所有摆放入口（place_chunked / place_unique / scenery 的 MultiMesh 帮手）
# 都按「落点 + 物体半径」过滤，杜绝建筑/树/道具压进赛道（穿模）。
# ---------------------------------------------------------------------------
static var keepout_pts: PackedVector3Array = PackedVector3Array()
static var keepout_half: float = 0.0
static var keepout_rejected := 0


static func set_keepout(path: Variant) -> void:
	keepout_pts.clear()
	keepout_rejected = 0
	reset_solids()
	reset_faces()
	reset_face_rects()
	if path == null:
		return
	keepout_half = float(path.half_width) + 0.6
	var d := 0.0
	var step: float = maxf(float(path.total_length) / 320.0, 8.0)
	while d < float(path.total_length):
		var f: Dictionary = path.frame_at(d)
		if not f.is_empty():
			keepout_pts.append(f["pos"] as Vector3)
		d += step


## 落点加物体半径仍在禁入区内 → false（不准摆）。
static func keepout_clear(pos: Vector3, radius: float = 0.0) -> bool:
	if keepout_pts.is_empty():
		return true
	var lim: float = keepout_half + maxf(radius, 0.0) + 0.6
	var lim2 := lim * lim
	for q in keepout_pts:
		var dx := pos.x - q.x
		var dz := pos.z - q.z
		if dx * dx + dz * dz < lim2:
			return false
	return true


# ---------------------------------------------------------------------------
# 实心障碍登记：石头/巨石类散布件先落位（SceneryKit 先于 VenueKit 跑），
# VenueKit 后摆广告牌/灯塔/裁判位时查这张表避开，防止道具互相穿插。
# ---------------------------------------------------------------------------
static var solid_pts: PackedVector3Array = PackedVector3Array()
static var solid_rad: PackedFloat32Array = PackedFloat32Array()


static func reset_solids() -> void:
	solid_pts = PackedVector3Array()
	solid_rad = PackedFloat32Array()


## 石头族资产（boulder*/coast_rocks/rock_face/pass_rock 等）。
static func is_solid_asset(asset: String) -> bool:
	return category_of(asset) == "rock" or asset.contains("rock")


static func register_solid(pos: Vector3, radius: float) -> void:
	solid_pts.append(pos)
	solid_rad.append(maxf(radius, 0.4))


static func solid_clear(pos: Vector3, radius: float) -> bool:
	for i in solid_pts.size():
		var dx := solid_pts[i].x - pos.x
		var dz := solid_pts[i].z - pos.z
		var lim := solid_rad[i] + radius
		if dx * dx + dz * dz < lim * lim:
			return false
	return true


# ---------------------------------------------------------------------------
# 楼面登记：楼体朝路一侧的真实半宽（比互斥用的对角半径小得多）。霓虹招牌、
# 天桥桥墩这类「贴着街面放」的小件按楼面判断贴墙，互斥圆会过度误杀。
# ---------------------------------------------------------------------------
static var face_pts := PackedVector2Array()
static var face_rad := PackedFloat32Array()


static func reset_faces() -> void:
	face_pts = PackedVector2Array()
	face_rad = PackedFloat32Array()


static func register_face(pos: Vector3, rad: float) -> void:
	face_pts.append(Vector2(pos.x, pos.z))
	face_rad.append(maxf(rad, 0.4))


static func face_clear(pos: Vector3, radius: float) -> bool:
	for i in face_pts.size():
		var dx := pos.x - face_pts[i].x
		var dz := pos.z - face_pts[i].y
		var lim := face_rad[i] + radius
		if dx * dx + dz * dz < lim * lim:
			return false
	return true


# 楼面矩形（中心/朝向/半宽半深）：量块楼是矩形足印，圆近似挡不住「沿墙
# 滑到楼角」和「楼角翅伸出对角线」的摆放，矩形 + 外扩余量才贴墙精确。
static var rect_pos := PackedVector3Array()
static var rect_dims := PackedVector3Array()


## dims = (half_w 横向, half_d 纵向, yaw)。half 已含角柱翅/裙楼外扩。
static func register_face_rect(pos: Vector3, half_w: float, half_d: float,
		yaw: float) -> void:
	rect_pos.append(pos)
	rect_dims.append(Vector3(half_w, half_d, yaw))


static func reset_face_rects() -> void:
	rect_pos = PackedVector3Array()
	rect_dims = PackedVector3Array()


static func face_rect_clear(pos: Vector3, margin: float) -> bool:
	for i in rect_pos.size():
		var d := rect_dims[i]
		var dx := pos.x - rect_pos[i].x
		var dz := pos.z - rect_pos[i].z
		var cy := cos(d.z)
		var sy := sin(d.z)
		var lx := dx * cy - dz * sy
		var lz := dx * sy + dz * cy
		if absf(lx) < d.x + margin and absf(lz) < d.y + margin:
			return false
	return true


## 矩形×矩形 SAT（2D OBB 互斥）：量块楼群用这个查楼间净空。对角圆会把
## 「楼身顺路向只差 d/2+d/2」的合法相邻楼判成重叠（近排同侧间距 18-20m，
## 对角半径和 17-27m，圆测会链式拒掉过半楼位）。
static func rect_rect_clear(pos: Vector3, half_w: float, half_d: float,
		yaw: float) -> bool:
	for i in rect_pos.size():
		var d0 := rect_dims[i]
		var rel := d0.z - yaw
		var dx := rect_pos[i].x - pos.x
		var dz := rect_pos[i].z - pos.z
		var cy := cos(yaw)
		var sy := sin(yaw)
		var lx := dx * cy - dz * sy
		var lz := dx * sy + dz * cy
		var cr := absf(cos(rel))
		var sr := absf(sin(rel))
		if absf(lx) > half_w + d0.x * cr + d0.y * sr:
			continue
		if absf(lz) > half_d + d0.x * sr + d0.y * cr:
			continue
		if absf(lx * cr + lz * sr) > half_w * cr + half_d * sr + d0.x:
			continue
		if absf(-lx * sr + lz * cr) > half_w * sr + half_d * cr + d0.y:
			continue
		return false
	return true


static func mesh_radius(mesh: Mesh) -> float:
	if mesh == null:
		return 1.0
	var ab := mesh.get_aabb()
	return maxf(ab.size.x, ab.size.z) * 0.5


static func _scene_radius(node: Node3D) -> float:
	var box := AABB()
	var first := true
	for child in node.find_children("*", "MeshInstance3D", true, false):
		var mi := child as MeshInstance3D
		if mi.mesh == null:
			continue
		var rel := _rel_xform(mi, node)
		var b: AABB = rel * mi.mesh.get_aabb()
		if first:
			box = b
			first = false
		else:
			box = box.merge(b)
	if not first:
		return maxf(box.size.x, box.size.z) * 0.5
	return 2.5


static func _rel_xform(node: Node, ancestor: Node) -> Transform3D:
	var rel := Transform3D.IDENTITY
	var cur: Node = node
	while cur != null and cur != ancestor:
		if cur is Node3D:
			rel = (cur as Node3D).transform * rel
		cur = cur.get_parent()
	return rel
