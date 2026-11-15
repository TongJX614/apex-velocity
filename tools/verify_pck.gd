extends SceneTree
## 校验导出的 PCK 确实包含城市碰撞数据。
## 用法：Godot --headless --path <临时工程> --script res://verify_pck.gd -- --pck=xxx.pck [--file=res://...]
## 必须用临时工程运行，避免本地工程文件遮蔽 PCK 内的同名资源。

const DEFAULT_FILE := "res://maps/assets/city_ring/city_collision.res"


func _init() -> void:
	var pck := ""
	var target := DEFAULT_FILE
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--pck="):
			pck = a.substr(6)
		elif a.begins_with("--file="):
			target = a.substr(7)
	if pck.is_empty():
		printerr("[PCK] missing --pck")
		quit(2)
		return
	if not ProjectSettings.load_resource_pack(pck, true):
		printerr("[PCK] cannot mount %s" % pck)
		quit(1)
		return
	if not FileAccess.file_exists(target):
		printerr("[PCK] MISSING %s" % target)
		quit(1)
		return
	if target.ends_with(".res"):
		var res := ResourceLoader.load(target)
		var data = res.get("data") if res != null else null
		if not (data is PackedByteArray) or (data as PackedByteArray).is_empty():
			printerr("[PCK] BROKEN %s" % target)
			quit(1)
			return
		print("[PCK] OK %s bytes=%d" % [target, (data as PackedByteArray).size()])
	else:
		print("[PCK] OK %s size=%d" % [target, FileAccess.get_file_as_bytes(target).size()])
	quit(0)
