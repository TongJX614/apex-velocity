class_name RaceManager
extends RefCounted
## Race state machine for GP (4-car grid, 3 laps) and Time Trial (solo, medals).
## Timing / ranking / medal math ported from the legacy WebGL build:
##   records.js medalTargets/medalFor, main.js computePosition/handleLapProgress.

enum State { COUNTDOWN, RACING, FINISHED, RESULTS }

const COUNTDOWN_SECONDS := 3.0
const FINISH_HOLD := 2.8
const PACE := {"gold": 58.0, "silver": 50.0, "bronze": 42.0}
const SECTOR_COUNT := 3

var state := State.COUNTDOWN
var track: TrackPath
var track_def: Dictionary = {}
var race_laps := 3
var mode := "gp"
var total_cars := 4

var countdown := COUNTDOWN_SECONDS
var race_time := 0.0
var finish_timer := FINISH_HOLD
var race_started := false
var start_flash := 0.0

var player: Car
var ais: Array[AICar] = []

var player_laps := 0
var player_race_dist := 0.0
var prev_progress := 0.0
## 逆向行驶：沿赛道进度持续倒退约 0.45s 置真，恢复前进后快速清除。
var wrong_way := false
var _wrong_accum := 0.0
var last_lap_time := -1.0
var best_lap_time := -1.0
var lap_start_time := 0.0
var sector_times: Array = []
var last_sector_times: Array = []
var best_sector_times: Array = []
var sector_deltas: Array = []
var sector_new_best: Array = []
var sector_index := 0
var sector_start_time := 0.0
var lap_valid := true
var player_finished := false
var player_finish_time := -1.0
var player_position := 1
var player_pace := 0.0
var medal := "none"
var results: Array = []
var record_summary: Dictionary = {}
var ai_fastest_lap := -1.0
var ai_fastest_name := ""


func setup(track_path: TrackPath, def: Dictionary, laps: int, race_mode: String,
		player_car: Car, ai_cars: Array[AICar]) -> void:
	track = track_path
	track_def = def
	race_laps = maxi(1, laps)
	mode = race_mode
	player = player_car
	ais = ai_cars
	total_cars = 1 if mode == "ta" else 1 + ais.size()
	state = State.COUNTDOWN
	countdown = COUNTDOWN_SECONDS
	race_time = 0.0
	finish_timer = FINISH_HOLD
	start_flash = 0.0
	player_laps = 0
	player_race_dist = player.race_dist
	prev_progress = fposmod(player.progress_dist, maxf(track.total_length, 0.001))
	last_lap_time = -1.0
	wrong_way = false
	_wrong_accum = 0.0
	best_lap_time = -1.0
	lap_start_time = 0.0
	sector_times = _empty_sectors()
	last_sector_times = _empty_sectors()
	sector_deltas = [0.0, 0.0, 0.0]
	sector_new_best = [false, false, false]
	best_sector_times = _empty_sectors()
	var stored_sectors := RecordsStore.best_sectors(track.id, mode)
	for i in mini(stored_sectors.size(), SECTOR_COUNT):
		best_sector_times[i] = float(stored_sectors[i])
	sector_index = 0
	sector_start_time = 0.0
	lap_valid = true
	player_finished = false
	player_finish_time = -1.0
	race_started = false
	player_position = total_cars
	player_pace = 0.0
	medal = "none"
	results = []
	record_summary = {}
	ai_fastest_lap = -1.0
	ai_fastest_name = ""
	player.lap = 0
	player.player_finished = false
	player.finish_time = -1.0
	player.race_dist = player_race_dist


func update(dt: float) -> void:
	match state:
		State.COUNTDOWN:
			countdown = maxf(0.0, countdown - dt)
			if countdown <= 0.0:
				state = State.RACING
				race_time = 0.0
				lap_start_time = 0.0
				sector_index = 0
				sector_start_time = 0.0
				sector_times = _empty_sectors()
				sector_deltas = [0.0, 0.0, 0.0]
				sector_new_best = [false, false, false]
				lap_valid = true
				# 开放漂移场地是自由练习：GO 即开始计时，没有起跑线越线判定。
				race_started = track != null and track.open_field
				start_flash = 1.0
				prev_progress = fposmod(player.progress_dist, maxf(track.total_length, 0.001))
		State.RACING, State.FINISHED:
			if race_started:
				race_time += dt
			if start_flash > 0.0:
				start_flash = maxf(0.0, start_flash - dt)
			# 场地没有圈数/分段/逆行/完赛：漂移甩尾时进度乱跳，整套赛程判定都跳过。
			if track == null or not track.open_field:
				_track_player_progress(dt)
			_absorb_ai_laps()
			player_position = compute_position()
			if state == State.FINISHED:
				finish_timer -= dt
				if finish_timer <= 0.0:
					_finish_race()
		State.RESULTS:
			pass


func _track_player_progress(dt: float) -> void:
	var length := maxf(track.total_length, 0.001)
	var p := fposmod(player.progress_dist, length)
	var prev := fposmod(prev_progress, length)
	var delta := p - prev
	var half := length * 0.5
	if delta > half:
		delta -= length
	elif delta < -half:
		delta += length
	# 城市实景允许离开主环自由驾驶，离开期间 progress 冻结；回到环上时
	# 最近点可能一次跳很远。这种跳变只用来重新锚定，不计入赛程，
	# 否则在城里绕一圈再从远端回到环上就能白刷一大段距离。
	if absf(delta) > 40.0:
		if race_started:
			# 跳变期间不累积赛程，也不产生分段成绩；本圈标记无效。
			lap_valid = false
			sector_index = clampi(int(floor(p / length * float(SECTOR_COUNT))), 0, SECTOR_COUNT - 1)
			sector_start_time = race_time
		prev_progress = p
		return
	player_race_dist += delta
	player.race_dist = player_race_dist

	if delta > 0.0 and prev > length * 0.7 and p < length * 0.3:
		# 发车格在起跑线之后：第一次越线只是「正式开始计时」，不算一圈
		if not race_started:
			race_started = true
			race_time = 0.0
			lap_start_time = 0.0
			sector_index = 0
			sector_start_time = 0.0
			sector_times = _empty_sectors()
			sector_deltas = [0.0, 0.0, 0.0]
			sector_new_best = [false, false, false]
			lap_valid = true
			prev_progress = p
			return
		player_laps += 1
		player.lap = player_laps
		var lap_time := race_time - lap_start_time
		if sector_index == SECTOR_COUNT - 1:
			_record_sector(SECTOR_COUNT - 1, race_time - sector_start_time)
			last_sector_times = sector_times.duplicate()
		else:
			lap_valid = false
			last_sector_times = _empty_sectors()
		lap_start_time = race_time
		sector_times = _empty_sectors()
		sector_deltas = [0.0, 0.0, 0.0]
		sector_new_best = [false, false, false]
		sector_index = 0
		sector_start_time = race_time
		if lap_time > 3.0:
			last_lap_time = lap_time
			if lap_valid and (best_lap_time < 0.0 or lap_time < best_lap_time):
				best_lap_time = lap_time
		lap_valid = true
		if not player_finished and player_laps >= race_laps:
			player_finished = true
			player_finish_time = race_time
			player.player_finished = true
			player.finish_time = race_time
			medal = _medal_for(race_time)
			state = State.FINISHED
			finish_timer = FINISH_HOLD
	_update_wrong_way(dt, delta)
	prev_progress = p
	if race_started:
		_track_sectors(p, length, delta)


## 逆向判定：进度以 >2.5 m/s 倒退且车速 >12 km/h 才累计，
## 原地掉头/甩尾的进度抖动不会误报；恢复前进按 4 倍速清除。
func _update_wrong_way(dt: float, delta: float) -> void:
	if state != State.RACING or player_finished or not race_started:
		_wrong_accum = 0.0
		wrong_way = false
		return
	if delta / maxf(dt, 0.001) < -2.5 and player.speed_kph > 12.0:
		_wrong_accum += dt
	elif delta > 0.0:
		_wrong_accum = maxf(0.0, _wrong_accum - dt * 4.0)
	wrong_way = _wrong_accum >= 0.45


func _track_sectors(p: float, length: float, delta: float) -> void:
	var idx := clampi(int(floor(p / length * float(SECTOR_COUNT))), 0, SECTOR_COUNT - 1)
	if delta <= 0.0:
		if idx < sector_index:
			# 倒车退回上一段：撤销该段成绩，从当前时刻重新起算。
			for i in range(idx, SECTOR_COUNT):
				sector_times[i] = -1.0
				sector_deltas[i] = 0.0
				sector_new_best[i] = false
			sector_index = idx
			sector_start_time = race_time
		return
	while sector_index < idx and sector_index < SECTOR_COUNT - 1:
		_record_sector(sector_index, race_time - sector_start_time)
		sector_index += 1
		sector_start_time = race_time


func _record_sector(i: int, t: float) -> void:
	if i < 0 or i >= SECTOR_COUNT or t <= 0.0:
		return
	sector_times[i] = t
	var best := float(best_sector_times[i])
	var delta := 0.0
	var new_best := false
	if best > 0.0:
		delta = t - best
		if t < best:
			best_sector_times[i] = t
			new_best = true
	else:
		best_sector_times[i] = t
		new_best = true
	sector_deltas[i] = delta
	sector_new_best[i] = new_best


func _empty_sectors() -> Array:
	return [-1.0, -1.0, -1.0]


func _absorb_ai_laps() -> void:
	for ai in ais:
		var lap_time := ai.consume_new_lap_time()
		if lap_time > 0.0:
			if ai_fastest_lap < 0.0 or lap_time < ai_fastest_lap:
				ai_fastest_lap = lap_time
				ai_fastest_name = ai.display_name
		if ai.finished and ai.finish_time < 0.0:
			ai.finish_time = race_time


func compute_position() -> int:
	if mode == "ta" or player == null:
		return 1
	var ahead := 0
	for ai in ais:
		if player_finished:
			if ai.finished and ai.finish_time > 0.0 and ai.finish_time < player_finish_time - 0.0001:
				ahead += 1
		elif ai.finished:
			ahead += 1
		elif ai.race_dist > player_race_dist:
			ahead += 1
	return ahead + 1


func _finish_race() -> void:
	state = State.RESULTS
	results = build_standings()
	record_summary = RecordsStore.submit(track.id, mode, player_finish_time, best_lap_time, medal, best_sector_times)


func build_standings() -> Array:
	var entries: Array = []
	if player != null:
		entries.append({
			"is_player": true,
			"name": String(player.spec.get("name", "PLAYER")),
			"number": int(player.spec.get("number", 7)),
			"color": Color.from_string(String(player.spec.get("color", "#42b7ff")), Color(0.3, 0.7, 1.0)),
			"finished": player_finished,
			"finish_time": player_finish_time,
			"dist": player_race_dist,
			"lap": player_laps,
			"best_lap": best_lap_time,
		})
	for ai in ais:
		entries.append({
			"is_player": false,
			"name": ai.display_name,
			"number": ai.number,
			"color": ai.car_color,
			"finished": ai.finished,
			"finish_time": ai.finish_time,
			"dist": ai.race_dist,
			"lap": ai.lap,
			"best_lap": ai.best_lap,
		})
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if bool(a["finished"]) and bool(b["finished"]):
			return float(a["finish_time"]) < float(b["finish_time"])
		if bool(a["finished"]) != bool(b["finished"]):
			return bool(a["finished"])
		return float(a["dist"]) > float(b["dist"])
	)
	var out: Array = []
	for i in entries.size():
		var entry: Dictionary = entries[i]
		var time_text := ""
		if bool(entry["finished"]) and float(entry["finish_time"]) > 0.0:
			time_text = format_time(float(entry["finish_time"]))
		else:
			time_text = "LAP %d/%d" % [mini(race_laps, int(entry["lap"]) + 1), race_laps]
		out.append({
			"rank": i + 1,
			"is_player": bool(entry["is_player"]),
			"name": String(entry["name"]),
			"number": int(entry["number"]),
			"color": entry["color"],
			"time_text": time_text,
			"finished": bool(entry["finished"]),
			"best_lap": float(entry["best_lap"]),
		})
	return out


func _medal_for(total: float) -> String:
	var length := maxf(600.0, track.total_length)
	var difficulty := clampi(int(track_def.get("difficulty", 2)), 1, 5)
	var scale := 1.0 - (float(difficulty) - 2.0) * 0.07
	var count := float(maxi(1, race_laps))
	var gold := length / (float(PACE["gold"]) * scale) * count
	var silver := length / (float(PACE["silver"]) * scale) * count
	var bronze := length / (float(PACE["bronze"]) * scale) * count
	if total <= gold:
		return "gold"
	if total <= silver:
		return "silver"
	if total <= bronze:
		return "bronze"
	return "none"


func medal_targets() -> Dictionary:
	var length := maxf(600.0, track.total_length)
	var difficulty := clampi(int(track_def.get("difficulty", 2)), 1, 5)
	var scale := 1.0 - (float(difficulty) - 2.0) * 0.07
	var count := float(maxi(1, race_laps))
	return {
		"gold": length / (float(PACE["gold"]) * scale) * count,
		"silver": length / (float(PACE["silver"]) * scale) * count,
		"bronze": length / (float(PACE["bronze"]) * scale) * count,
	}


func countdown_text() -> String:
	if state == State.COUNTDOWN:
		return str(int(ceil(countdown)))
	if state == State.RACING and start_flash > 0.0:
		return "GO!"
	return ""


static func format_time(t: float, with_minutes: bool = true) -> String:
	if t < 0.0 or is_nan(t) or is_inf(t):
		return "--:--.---" if with_minutes else "--.---"
	var total_ms := int(round(t * 1000.0))
	var m := int(total_ms / 60000)
	var s := int(total_ms / 1000) % 60
	var ms := total_ms % 1000
	if not with_minutes:
		return "%02d.%03d" % [s, ms]
	return "%02d:%02d.%03d" % [m, s, ms]
