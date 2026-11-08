class_name RaceManager
extends RefCounted
## Race state machine for GP (4-car grid, 3 laps) and Time Trial (solo, medals).
## Timing / ranking / medal math ported from the legacy WebGL build:
##   records.js medalTargets/medalFor, main.js computePosition/handleLapProgress.

enum State { COUNTDOWN, RACING, FINISHED, RESULTS }

const COUNTDOWN_SECONDS := 3.0
const FINISH_HOLD := 2.8
const PACE := {"gold": 58.0, "silver": 50.0, "bronze": 42.0}

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
var last_lap_time := -1.0
var best_lap_time := -1.0
var lap_start_time := 0.0
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
	best_lap_time = -1.0
	lap_start_time = 0.0
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
				race_started = false
				start_flash = 1.0
				prev_progress = fposmod(player.progress_dist, maxf(track.total_length, 0.001))
		State.RACING, State.FINISHED:
			if race_started:
				race_time += dt
			if start_flash > 0.0:
				start_flash = maxf(0.0, start_flash - dt)
			_track_player_progress()
			_absorb_ai_laps()
			player_position = compute_position()
			if state == State.FINISHED:
				finish_timer -= dt
				if finish_timer <= 0.0:
					_finish_race()
		State.RESULTS:
			pass


func _track_player_progress() -> void:
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
			prev_progress = p
			return
		player_laps += 1
		player.lap = player_laps
		var lap_time := race_time - lap_start_time
		lap_start_time = race_time
		if lap_time > 3.0:
			last_lap_time = lap_time
			if best_lap_time < 0.0 or lap_time < best_lap_time:
				best_lap_time = lap_time
		if not player_finished and player_laps >= race_laps:
			player_finished = true
			player_finish_time = race_time
			player.player_finished = true
			player.finish_time = race_time
			medal = _medal_for(race_time)
			state = State.FINISHED
			finish_timer = FINISH_HOLD
	prev_progress = p


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
	record_summary = RecordsStore.submit(track.id, mode, player_finish_time, best_lap_time, medal)


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
