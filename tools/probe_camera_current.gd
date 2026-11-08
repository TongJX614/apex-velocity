extends SceneTree
## 相机接管行为探针：后加入的 Camera3D 会不会自动接管 current？
## 场景：先建 A（current=true），再加 B（不设 current），看 Viewport 最终用谁。

func _init() -> void:
	var root_3d := Node3D.new()
	root.add_child(root_3d)

	var a := Camera3D.new()
	a.name = "A"
	root_3d.add_child(a)
	a.current = true
	print("[PROBE] A added, A.current = ", a.current)

	var b := Camera3D.new()
	b.name = "B"
	root_3d.add_child(b)
	print("[PROBE] B added (no explicit current)")
	print("[PROBE]   A.current = ", a.current)
	print("[PROBE]   B.current = ", b.current)
	var vp := root
	print("[PROBE] viewport.get_camera_3d() = ", vp.get_camera_3d())
	if vp.get_camera_3d() != null:
		print("[PROBE]   active camera name = ", vp.get_camera_3d().name)

	# 再测：把 A 释放掉，看 B 会不会顶上来
	a.queue_free()
	await process_frame
	print("[PROBE] after freeing A:")
	print("[PROBE]   B.current = ", b.current)
	print("[PROBE] viewport camera = ", vp.get_camera_3d())
	if vp.get_camera_3d() != null:
		print("[PROBE]   active camera name = ", vp.get_camera_3d().name)
	quit()
