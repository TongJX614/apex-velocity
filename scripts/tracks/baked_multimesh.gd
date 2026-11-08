class_name BakedMultiMesh
extends MultiMeshInstance3D
## 预烘焙菜单场景里的 MultiMesh：Godot 的 PackedScene 不会保存 MultiMesh 的实例变换，
## 所以烘焙时把 mesh / material / 变换数组存到节点导出变量里，运行时 _ready 重建。

@export var baked_mesh: Mesh
@export var baked_material: Material
@export var baked_transforms: Array[Transform3D] = []
@export var baked_colors: Array[Color] = []


func _ready() -> void:
	rebuild()


func rebuild() -> void:
	if baked_mesh == null or baked_transforms.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = baked_mesh
	# use_colors 只能在 instance_count 仍为 0 时切换，否则引擎报
	# "Instance count must be 0 to toggle whether colors are used" 并丢弃全部顶点色。
	var colored := not baked_colors.is_empty()
	if colored:
		mm.use_colors = true
	mm.instance_count = baked_transforms.size()
	for i in baked_transforms.size():
		mm.set_instance_transform(i, baked_transforms[i])
		if colored and i < baked_colors.size():
			mm.set_instance_color(i, baked_colors[i])
	multimesh = mm
	if baked_material != null:
		material_override = baked_material
	# 这些实例远离节点原点，必须显式给包围盒，否则整批会被视锥剔除掉
	var mesh_aabb := baked_mesh.get_aabb()
	var box := AABB()
	var first := true
	for xf in baked_transforms:
		var world_aabb: AABB = xf * mesh_aabb
		if first:
			box = world_aabb
			first = false
		else:
			box = box.merge(world_aabb)
	if not first:
		custom_aabb = box.grow(4.0)
