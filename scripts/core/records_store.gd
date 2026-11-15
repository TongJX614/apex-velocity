class_name RecordsStore
extends RefCounted
## Per-track best times, stored as JSON in user://records.json.
## Structure:
##   { "tracks": { "coast": { "gp": {"total": 00, "lap": 00, "medal": "gold"},
##                            "ta": {...} } } }

const PATH := "user://records.json"

# 菜单每切一次赛道/车就要查 best_total / best_lap / history，
# 全量读盘+解析没必要：进程内缓存一份，save_all 时同步更新。
static var _cache: Dictionary = {}
static var _cache_valid := false


static func load_all() -> Dictionary:
	if _cache_valid:
		return _cache.duplicate(true)
	var parsed: Variant = SafeJson.read_dict(PATH)
	if parsed == null:
		return {"tracks": {}}
	var data: Dictionary = parsed
	if typeof(data.get("tracks")) != TYPE_DICTIONARY:
		data["tracks"] = {}
	_cache = data.duplicate(true)
	_cache_valid = true
	return data


static func save_all(data: Dictionary) -> void:
	if not SafeJson.write(PATH, JSON.stringify(data, "  ")):
		push_error("RecordsStore: cannot write %s" % PATH)
		return
	_cache = data.duplicate(true)
	_cache_valid = true


static func for_track(track_id: String) -> Dictionary:
	var all := load_all()
	var tracks: Dictionary = all.get("tracks", {})
	return tracks.get(track_id, {})


static func best_total(track_id: String, mode: String) -> float:
	var entry: Dictionary = for_track(track_id).get(mode, {})
	return float(entry.get("total", -1.0))


static func best_lap(track_id: String, mode: String) -> float:
	var entry: Dictionary = for_track(track_id).get(mode, {})
	return float(entry.get("lap", -1.0))


static func best_sectors(track_id: String, mode: String) -> Array:
	var entry: Dictionary = for_track(track_id).get(mode, {})
	return _clean_sectors(entry.get("sectors", []))


static func _clean_sectors(raw: Variant) -> Array:
	var out: Array = []
	if typeof(raw) != TYPE_ARRAY:
		return out
	for v in (raw as Array):
		if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
			out.append(float(v))
	return out


## Submits a finished race. Returns {new_total, best_total, new_lap, best_lap, medal, best_sectors}.
static func submit(track_id: String, mode: String, total: float, best_lap: float, medal: String,
		sectors: Array = []) -> Dictionary:
	var all := load_all()
	var tracks: Dictionary = all["tracks"]
	var entry: Dictionary = tracks.get(track_id, {})
	var mode_entry: Dictionary = entry.get(mode, {"total": -1.0, "lap": -1.0, "medal": "none"})
	var out := {
		"new_total": false,
		"best_total": float(mode_entry.get("total", -1.0)),
		"new_lap": false,
		"best_lap": float(mode_entry.get("lap", -1.0)),
		"best_sectors": _clean_sectors(mode_entry.get("sectors", [])),
	}
	if total > 0.0 and (out["best_total"] < 0.0 or total < float(out["best_total"])):
		out["new_total"] = true
		out["best_total"] = total
		mode_entry["total"] = total
		mode_entry["medal"] = medal
	if best_lap > 0.0 and (out["best_lap"] < 0.0 or best_lap < float(out["best_lap"])):
		out["new_lap"] = true
		out["best_lap"] = best_lap
		mode_entry["lap"] = best_lap
	if not sectors.is_empty():
		var merged: Array = []
		var old: Array = out["best_sectors"]
		var count := maxi(old.size(), sectors.size())
		for i in count:
			var a := float(old[i]) if i < old.size() else -1.0
			var b := float(sectors[i]) if i < sectors.size() else -1.0
			if a > 0.0 and b > 0.0:
				merged.append(minf(a, b))
			elif a > 0.0:
				merged.append(a)
			else:
				merged.append(b)
		mode_entry["sectors"] = merged
		out["best_sectors"] = merged
	entry[mode] = mode_entry
	tracks[track_id] = entry
	all["tracks"] = tracks
	save_all(all)
	return out


# ---------------------------------------------------------------------------
# 最近 10 次成绩 + 走线（AI 路线库）
# ---------------------------------------------------------------------------

const MAX_HISTORY := 10
const LINE_BINS := 96


## 追加一次完赛记录。line 形如 {"step": 12.5, "lat": [...], "spd": [...]}，
## 由 main.gd 在比赛过程中采样并在结束时压缩成 LINE_BINS 段。
## 只保留最近 MAX_HISTORY 条；最新一条排在最前，方便 AI 直接取「最近几条走线」。
static func record_run(track_id: String, mode: String, car_id: String,
		total: float, best_lap: float, medal: String, line: Dictionary = {}) -> void:
	if track_id.is_empty() or total <= 0.0:
		return
	var all := load_all()
	var tracks: Dictionary = all["tracks"]
	var entry: Dictionary = tracks.get(track_id, {})
	var history: Array = entry.get("history", [])
	if typeof(history) != TYPE_ARRAY:
		history = []
	var clean_line := {}
	if not line.is_empty():
		var lat = line.get("lat", [])
		var spd = line.get("spd", [])
		if typeof(lat) == TYPE_ARRAY and (lat as Array).size() >= 24:
			clean_line = {
				"step": maxf(1.0, float(line.get("step", 1.0))),
				"lat": lat,
				"spd": spd if typeof(spd) == TYPE_ARRAY else [],
			}
	history.insert(0, {
		"car": car_id,
		"mode": mode,
		"total": total,
		"lap": best_lap,
		"medal": medal,
		"date": int(Time.get_unix_time_from_system()),
		"line": clean_line,
	})
	if history.size() > MAX_HISTORY:
		history.resize(MAX_HISTORY)
	entry["history"] = history
	tracks[track_id] = entry
	all["tracks"] = tracks
	save_all(all)


## 最近成绩（新 → 旧）。
static func history(track_id: String) -> Array:
	var raw = for_track(track_id).get("history", [])
	if typeof(raw) != TYPE_ARRAY:
		return []
	var out: Array = []
	for item in (raw as Array):
		if typeof(item) == TYPE_DICTIONARY:
			out.append(item)
	return out


## AI 路线候选：最近几次带有效走线的成绩，最多 max_lines 条。
static func line_candidates(track_id: String, max_lines: int = 6) -> Array:
	var out: Array = []
	for item in history(track_id):
		var line = item.get("line", {})
		if typeof(line) != TYPE_DICTIONARY or (line as Dictionary).is_empty():
			continue
		var lat = (line as Dictionary).get("lat", [])
		if typeof(lat) != TYPE_ARRAY or (lat as Array).size() < 24:
			continue
		out.append({
			"car": String(item.get("car", "")),
			"lap": float(item.get("lap", item.get("total", 0.0))),
			"line": line,
		})
		if out.size() >= max_lines:
			break
	# 旧档案/新赛道没有走线时，至少给出空数组，调用方回落到默认车线。
	return out


## 赛道档案用：按时间倒序的所有记录（含老版本只有 bests 的情况）。
static func all_results(track_id: String) -> Array:
	return history(track_id)


## 把一段「距离 → 横向偏移 / 速度」采样压缩成定长 LINE_BINS 段。
## samples: [[dist, lateral, speed_kph], ...]；返回 {"step","lat","spd"}。
static func compress_line(samples: Array, total_length: float) -> Dictionary:
	if samples.size() < 8 or total_length <= 1.0:
		return {}
	var lat_sum := PackedFloat32Array()
	var spd_sum := PackedFloat32Array()
	var counts := PackedInt32Array()
	lat_sum.resize(LINE_BINS)
	spd_sum.resize(LINE_BINS)
	counts.resize(LINE_BINS)
	for s in samples:
		if typeof(s) != TYPE_ARRAY or (s as Array).size() < 3:
			continue
		var d := fposmod(float((s as Array)[0]), total_length)
		var bin := clampi(int(floor(d / total_length * float(LINE_BINS))), 0, LINE_BINS - 1)
		lat_sum[bin] += float((s as Array)[1])
		spd_sum[bin] += float((s as Array)[2])
		counts[bin] += 1
	var lat_out: Array = []
	var spd_out: Array = []
	var last_lat := 0.0
	var last_spd := 0.0
	for i in LINE_BINS:
		if counts[i] > 0:
			last_lat = lat_sum[i] / float(counts[i])
			last_spd = spd_sum[i] / float(counts[i])
		lat_out.append(snappedf(last_lat, 0.01))
		spd_out.append(snappedf(last_spd, 0.1))
	return {"step": total_length / float(LINE_BINS), "lat": lat_out, "spd": spd_out}
