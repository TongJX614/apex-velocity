class_name CityCollisionData
extends Resource
## 都会环线碰撞数据的资源封装：PackedByteArray 是原生资源，
## 导出时一定会被包含；直接 FileAccess 打开裸 .bin 在发布包里会丢
## （见 CityWorld.load_collision 的注释）。

@export var data := PackedByteArray()
