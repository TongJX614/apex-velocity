class_name SafeJson
extends RefCounted
## 玩家存档的原子写入与损坏回退。
## 写：先写 .tmp 再 rename 替换，旧版本留一份 .bak；
## 读：主文件缺失/为空/JSON 损坏时自动回退 .bak。


## 原子写入文本。失败时不破坏现有存档，返回 false。
static func write(path: String, text: String) -> bool:
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_warning("SafeJson: 无法写入 %s (err=%d)" % [tmp, FileAccess.get_open_error()])
		return false
	f.store_string(text)
	var err := f.get_error()
	f.close()
	if err != OK:
		DirAccess.remove_absolute(tmp)
		push_warning("SafeJson: 写入 %s 失败 (err=%d)" % [tmp, err])
		return false
	var bak := path + ".bak"
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(bak)
		DirAccess.rename_absolute(path, bak)
	var rerr := DirAccess.rename_absolute(tmp, path)
	if rerr != OK:
		DirAccess.remove_absolute(tmp)
		push_warning("SafeJson: 替换 %s 失败 (err=%d)，旧档仍在 .bak" % [path, rerr])
		return false
	return true


## 读取并解析 JSON 字典；主文件坏/缺时回退 .bak。两者都不可用返回 null。
static func read_dict(path: String) -> Variant:
	var candidates: Array[String] = [path, path + ".bak"]
	for i in candidates.size():
		var p := candidates[i]
		if not FileAccess.file_exists(p):
			continue
		var f := FileAccess.open(p, FileAccess.READ)
		if f == null:
			continue
		var text := f.get_as_text()
		f.close()
		if text.strip_edges().is_empty():
			continue
		var parsed: Variant = JSON.parse_string(text)
		if parsed is Dictionary:
			if i > 0:
				push_warning("SafeJson: %s 损坏，已从备份恢复" % path)
			return parsed
	return null