extends RefCounted
## 最佳圈幽灵车存档（每条赛道 + 每台车一份）。
##
## 文件：user://ghost_<track>_<car>.json
## 结构：
##   {
##     "track": "coast", "car": "bmw_m3_e92", "lap_time": 89.53,
##     "samples": [[t, x, y, z, heading, progress], ...]
##   }
## 采样 20Hz，单圈最多存 MAX_SAMPLES 个点；读档时逐项校验，坏文件返回 {}。

const MAX_SAMPLES := 1600
const MIN_SAMPLES := 8

static func path_for(track_id: String, car_id: String) -> String:
	return "user://ghost_%s_%s.json" % [_safe(track_id), _safe(car_id)]


## 赛道最快幽灵（不分车型）：刷圈领跑用，任何车进场都导入同一台最快虚拟车。
static func best_path_for(track_id: String) -> String:
	return "user://ghost_best_%s.json" % _safe(track_id)


static func has_ghost(track_id: String, car_id: String) -> bool:
	return FileAccess.file_exists(path_for(track_id, car_id))


static func load_best(track_id: String) -> Dictionary:
	return _load_path(best_path_for(track_id), track_id)


## 只在更快时覆盖赛道最佳幽灵；返回是否写入。
static func save_best_if_faster(track_id: String, car_id: String, lap_time: float,
		samples: Array) -> bool:
	if samples.size() < MIN_SAMPLES or lap_time <= 0.0:
		return false
	var existing := load_best(track_id)
	var best_time := float(existing.get("lap_time", 0.0))
	if best_time > 0.0 and lap_time >= best_time:
		return false
	var payload := {
		"track": track_id,
		"car": car_id,
		"lap_time": lap_time,
		"samples": _decimate(samples),
	}
	return _write_path(best_path_for(track_id), payload)


static func load_for(track_id: String, car_id: String) -> Dictionary:
	return _load_path(path_for(track_id, car_id), track_id)


static func _load_path(path: String, track_id: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var text := f.get_as_text()
	f.close()
	var json := JSON.new()
	if json.parse(text) != OK or typeof(json.data) != TYPE_DICTIONARY:
		return {}
	var data: Dictionary = json.data
	var raw = data.get("samples", [])
	if typeof(raw) != TYPE_ARRAY:
		return {}
	var samples: Array = []
	for item in (raw as Array):
		if typeof(item) != TYPE_ARRAY:
			continue
		var arr: Array = item
		if arr.size() < 6:
			continue
		samples.append([
			float(arr[0]), float(arr[1]), float(arr[2]),
			float(arr[3]), float(arr[4]), float(arr[5]),
		])
	if samples.size() < MIN_SAMPLES:
		return {}
	return {
		"track": String(data.get("track", track_id)),
		"car": String(data.get("car", "")),
		"lap_time": clampf(float(data.get("lap_time", 0.0)), 0.0, 86400.0),
		"samples": samples,
	}


static func save_for(track_id: String, car_id: String, lap_time: float, samples: Array) -> bool:
	if samples.size() < MIN_SAMPLES or lap_time <= 0.0:
		return false
	return _write_path(path_for(track_id, car_id), {
		"track": track_id,
		"car": car_id,
		"lap_time": lap_time,
		"samples": _decimate(samples),
	})


static func _write_path(path: String, payload: Dictionary) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("GhostStore: cannot write %s" % path)
		return false
	f.store_string(JSON.stringify(payload))
	var err := f.get_error()
	f.close()
	return err == OK


static func _decimate(samples: Array) -> Array:
	if samples.size() <= MAX_SAMPLES:
		return samples
	var step := float(samples.size()) / float(MAX_SAMPLES)
	var out: Array = []
	for i in MAX_SAMPLES:
		out.append(samples[mini(int(float(i) * step), samples.size() - 1)])
	if out.is_empty() or out[out.size() - 1] != samples[samples.size() - 1]:
		out[out.size() - 1] = samples[samples.size() - 1]
	return out


static func _safe(id: String) -> String:
	var out := ""
	for ch in id.to_lower():
		if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9") or ch == "_" or ch == "-":
			out += ch
		else:
			out += "_"
	return out if not out.is_empty() else "unknown"
