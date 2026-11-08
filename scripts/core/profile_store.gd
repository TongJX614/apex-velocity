class_name ProfileStore
extends RefCounted
## 车手成长 / 成就 / 圈速排行（纯静态，无 autoload）。
##
## 存档：user://profile.json
## 结构：
##   {
##     "xp": 0, "xp_spent": 0, "level": 1, "total_km": 0.0, "races": 0, "wins": 0,
##     "podiums": 0, "achievements": { "first_finish": true, ... },
##     "best_laps": { "coast": { "bmw_m3_e92": [89.532, ...] } },
##     "total_nitro": 0, "total_drift_time": 0.0
##   }
##
## 用法（Lead 直接调用静态方法，不要挂 autoload）：
##   var summary := ProfileStore.format_summary()
##   var report := ProfileStore.submit_race(race, car)
##   var targets := ProfileStore.medal_targets(track_path, laps, "ta")
##
## 升级曲线：Lv.1 → 2 需 1000 XP，之后每级递增 250 XP（Lv.N 需 750 + 250*N）。
## XP 为累计总值；level 始终由 xp 推导，读档时会自动校正。

const PATH := "user://profile.json"
const MAX_BEST_LAPS := 5
const XP_BASE := 1000
const XP_STEP := 250

## 测试期无限积分开关：开启后余额恒为满额、任何消费都成功且不写档。
## 交付正式经济时改回 false 即可。
const DEV_INFINITE_CREDITS := true
const INFINITE_CREDIT_DISPLAY := 9999999

## 单场 XP。名次奖励只在大奖赛（gp）生效，计时赛（ta）固定发车位不参与。
const XP_FINISH := 120
const XP_GP_POSITION := {1: 220, 2: 150, 3: 100}
const XP_GP_OTHER := 40
const XP_MEDAL := {"gold": 300, "silver": 180, "bronze": 90}
const XP_NEW_BEST_LAP := 80
const XP_NEW_TRACK := 120

## 与 scripts/core/race_manager.gd 的 PACE 保持一致（m/s）。
const PACE := {"gold": 58.0, "silver": 50.0, "bronze": 42.0}

## 成就定义。icon 为 UI 可映射的短标识（ASCII），避免字体 emoji 兼容问题。
const ACHIEVEMENTS := [
	{
		"id": "first_finish", "name": "首次完赛", "icon": "flag", "xp": 150,
		"desc": "完成你的第一场比赛。",
	},
	{
		"id": "first_podium", "name": "首次登台", "icon": "podium", "xp": 300,
		"desc": "在大奖赛中首次进入前三名。",
	},
	{
		"id": "first_win", "name": "首次夺冠", "icon": "trophy", "xp": 500,
		"desc": "赢得你的第一场大奖赛。",
	},
	{
		"id": "medal_gold", "name": "金牌车手", "icon": "gold", "xp": 400,
		"desc": "在任意比赛中获得金牌。",
	},
	{
		"id": "medal_silver", "name": "银牌车手", "icon": "silver", "xp": 250,
		"desc": "在任意比赛中获得银牌。",
	},
	{
		"id": "medal_bronze", "name": "铜牌车手", "icon": "bronze", "xp": 150,
		"desc": "在任意比赛中获得铜牌。",
	},
	{
		"id": "speed_250", "name": "极速 250", "icon": "speed", "xp": 200,
		"desc": "驾驶极速达到 250 km/h 的赛车完成比赛。",
	},
	{
		"id": "speed_300", "name": "极速 300", "icon": "speed", "xp": 350,
		"desc": "驾驶极速达到 300 km/h 的赛车完成比赛。",
	},
	{
		"id": "nitro_10", "name": "氮气大师", "icon": "nitro", "xp": 150,
		"desc": "累计使用氮气 10 次。",
	},
	{
		"id": "drift_10", "name": "漂移高手", "icon": "drift", "xp": 150,
		"desc": "累计漂移时间达到 10 秒。",
	},
	{
		"id": "tracks_3", "name": "赛道探索者", "icon": "route", "xp": 250,
		"desc": "在 3 条不同的赛道上完成比赛。",
	},
	{
		"id": "lap_130", "name": "单圈 1:30", "icon": "stopwatch", "xp": 300,
		"desc": "跑出低于 1 分 30 秒的单圈成绩。",
	},
	{
		"id": "distance_100", "name": "百公里俱乐部", "icon": "distance", "xp": 400,
		"desc": "累计行驶里程达到 100 km。",
	},
	{
		"id": "races_10", "name": "十场老将", "icon": "grid", "xp": 300,
		"desc": "完成 10 场比赛。",
	},
	{
		"id": "level_10", "name": "十级车手", "icon": "star", "xp": 500,
		"desc": "车手等级达到 10 级。",
	},
	{
		"id": "drift_combo_5", "name": "连击五连", "icon": "drift", "xp": 250,
		"desc": "单场漂移连击达到 ×5。",
	},
	{
		"id": "drift_score_3000", "name": "漂移大师", "icon": "drift", "xp": 300,
		"desc": "单场漂移得分达到 3000 分。",
	},
	{
		"id": "drift_time_60", "name": "漂移狂人", "icon": "drift", "xp": 350,
		"desc": "累计漂移时间达到 60 秒。",
	},
	{
		"id": "races_25", "name": "二十五场老将", "icon": "grid", "xp": 600,
		"desc": "完成 25 场比赛。",
	},
	{
		"id": "track_sweep", "name": "全赛道征服", "icon": "route", "xp": 800,
		"desc": "在全部 8 条赛道上完成比赛。",
	},
	{
		"id": "level_20", "name": "二十级车手", "icon": "star", "xp": 800,
		"desc": "车手等级达到 20 级。",
	},
	{
		"id": "mastery_silver3", "name": "三线精通", "icon": "route", "xp": 400,
		"desc": "在 3 条赛道达到银牌精通。",
	},
	{
		"id": "mastery_allgold", "name": "全赛道宗师", "icon": "star", "xp": 1200,
		"desc": "在全部 8 条赛道达到金牌精通。",
	},
]

## 赛道精通：按最佳单圈评为铜/银/金，升级时发放一次性 XP。
const MASTERY_XP := {1: 150, 2: 250, 3: 500}
const MASTERY_LABELS := ["未精通", "铜牌", "银牌", "金牌"]

## 每日合约池：每天按日期种子抽 3 条，完成后在「每日合约」界面领 XP。
const DAILY_POOL := [
	{"id": "d_race2", "name": "双场热身", "desc": "完成 2 场比赛", "metric": "races", "goal": 2, "xp": 150},
	{"id": "d_drift12", "name": "烟雾时间", "desc": "累计漂移 12 秒", "metric": "drift", "goal": 12, "xp": 140},
	{"id": "d_nitro5", "name": "氮气五连", "desc": "使用氮气 5 次", "metric": "nitro", "goal": 5, "xp": 120},
	{"id": "d_lap1", "name": "刷新纪录", "desc": "刷新 1 次最佳圈", "metric": "best_lap", "goal": 1, "xp": 180},
	{"id": "d_gold1", "name": "金牌时刻", "desc": "获得 1 枚金牌", "metric": "gold", "goal": 1, "xp": 200},
	{"id": "d_km10", "name": "十公里", "desc": "累计行驶 10 km", "metric": "km", "goal": 10, "xp": 130},
	{"id": "d_podium1", "name": "领奖台", "desc": "进入前三名 1 次", "metric": "podium", "goal": 1, "xp": 160},
]


# ---------------------------------------------------------------------------
# 存档
# ---------------------------------------------------------------------------

static func default_profile() -> Dictionary:
	return {
		"xp": 0,
		"xp_spent": 0,
		"level": 1,
		"total_km": 0.0,
		"races": 0,
		"wins": 0,
		"podiums": 0,
		"achievements": {},
		"best_laps": {},
		"total_nitro": 0,
		"total_drift_time": 0.0,
		"total_drift_score": 0,
		"daily": {"date": "", "progress": {}, "claimed": {}},
		"mastery": {},
	}


## 读档；文件不存在 / 损坏 / 字段缺失时回落到默认值，绝不崩溃。
static func load_profile() -> Dictionary:
	if not FileAccess.file_exists(PATH):
		return default_profile()
	var f := FileAccess.open(PATH, FileAccess.READ)
	if f == null:
		push_warning("ProfileStore: 无法读取 %s，使用默认档案" % PATH)
		return default_profile()
	var text := f.get_as_text()
	f.close()
	if text.strip_edges().is_empty():
		return default_profile()
	var json := JSON.new()
	if json.parse(text) != OK or typeof(json.data) != TYPE_DICTIONARY:
		push_warning("ProfileStore: %s 不是合法档案，使用默认档案" % PATH)
		return default_profile()
	return _normalize(json.data)


## 存档；写入失败只 push_warning，不中断游戏。
static func save_profile(data: Dictionary) -> void:
	var clean := _normalize(data)
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	if f == null:
		push_warning("ProfileStore: 无法写入 %s (err=%d)" % [PATH, FileAccess.get_open_error()])
		return
	f.store_string(JSON.stringify(clean, "  "))
	var err := f.get_error()
	f.close()
	if err != OK:
		push_warning("ProfileStore: 写入 %s 失败 (err=%d)" % [PATH, err])


## 清空成长进度（保留一个全零档案，UI 读到的仍是合法字典）。
static func reset() -> void:
	save_profile(default_profile())


static func _normalize(raw: Dictionary) -> Dictionary:
	var data := default_profile()
	data["xp"] = clampi(_as_int(raw.get("xp"), 0), 0, 1_000_000_000)
	# 旧存档没有 xp_spent：视为一分未花，历史 XP 全部可用。
	data["xp_spent"] = clampi(_as_int(raw.get("xp_spent"), 0), 0, int(data["xp"]))
	data["level"] = level_for_xp(int(data["xp"]))
	data["total_km"] = clampf(_as_float(raw.get("total_km"), 0.0), 0.0, 1_000_000_000.0)
	data["races"] = maxi(0, _as_int(raw.get("races"), 0))
	data["wins"] = clampi(_as_int(raw.get("wins"), 0), 0, int(data["races"]))
	data["podiums"] = clampi(_as_int(raw.get("podiums"), 0), 0, int(data["races"]))
	data["total_nitro"] = maxi(0, _as_int(raw.get("total_nitro"), 0))
	data["total_drift_time"] = clampf(
		_as_float(raw.get("total_drift_time"), 0.0), 0.0, 1_000_000_000.0)
	data["total_drift_score"] = maxi(0, _as_int(raw.get("total_drift_score"), 0))

	var raw_achievements = raw.get("achievements", {})
	var achievements := {}
	if typeof(raw_achievements) == TYPE_DICTIONARY:
		for def in ACHIEVEMENTS:
			var id := String(def["id"])
			if (raw_achievements as Dictionary).has(id):
				achievements[id] = true
	data["achievements"] = achievements

	var raw_daily = raw.get("daily", {})
	if typeof(raw_daily) == TYPE_DICTIONARY:
		var daily: Dictionary = raw_daily
		data["daily"] = {
			"date": String(daily.get("date", "")),
			"progress": _clean_int_map(daily.get("progress", {})),
			"claimed": _clean_bool_map(daily.get("claimed", {})),
		}

	var raw_mastery = raw.get("mastery", {})
	var mastery := {}
	if typeof(raw_mastery) == TYPE_DICTIONARY:
		for track_key in (raw_mastery as Dictionary):
			var tier := clampi(_as_int((raw_mastery as Dictionary)[track_key], 0), 0, 3)
			if tier > 0:
				mastery[String(track_key)] = tier
	data["mastery"] = mastery

	var raw_laps = raw.get("best_laps", {})
	var clean_laps := {}
	if typeof(raw_laps) == TYPE_DICTIONARY:
		for track_key in (raw_laps as Dictionary):
			var raw_cars = (raw_laps as Dictionary)[track_key]
			if typeof(raw_cars) != TYPE_DICTIONARY:
				continue
			var clean_cars := {}
			for car_key in (raw_cars as Dictionary):
				var raw_times = (raw_cars as Dictionary)[car_key]
				var times: Array = []
				if typeof(raw_times) == TYPE_ARRAY:
					for t in (raw_times as Array):
						_push_lap_time(times, _as_float(t, 0.0))
				elif typeof(raw_times) == TYPE_INT or typeof(raw_times) == TYPE_FLOAT:
					_push_lap_time(times, _as_float(raw_times, 0.0))
				if not times.is_empty():
					clean_cars[String(car_key)] = times
			if not clean_cars.is_empty():
				clean_laps[String(track_key)] = clean_cars
	data["best_laps"] = clean_laps
	return data


static func _push_lap_time(times: Array, t: float) -> void:
	if t <= 0.0 or not is_finite(t) or t > 86400.0:
		return
	times.append(t)
	times.sort()
	if times.size() > MAX_BEST_LAPS:
		times.resize(MAX_BEST_LAPS)


# ---------------------------------------------------------------------------
# 等级
# ---------------------------------------------------------------------------

## 从 level 升到 level+1 所需 XP（Lv.1 需要 1000，Lv.2 需要 1250，...）。
static func xp_to_next(level: int) -> int:
	return XP_BASE + XP_STEP * maxi(0, level - 1)


## 累计 XP 对应的等级（Lv.1 起）。
static func level_for_xp(xp: int) -> int:
	var remaining := maxi(0, xp)
	var level := 1
	while true:
		var need := xp_to_next(level)
		if remaining < need:
			break
		remaining -= need
		level += 1
	return level


## 给 UI 用的等级进度：level / 本级已得 / 本级目标 / 0..1 比例。
static func level_progress(xp: int) -> Dictionary:
	var remaining := maxi(0, xp)
	var level := 1
	var need := xp_to_next(level)
	while remaining >= need:
		remaining -= need
		level += 1
		need = xp_to_next(level)
	return {
		"level": level,
		"total_xp": maxi(0, xp),
		"xp_into_level": remaining,
		"xp_needed": need,
		"ratio": clampf(float(remaining) / float(maxi(1, need)), 0.0, 1.0),
	}


# ---------------------------------------------------------------------------
# XP 钱包：经验同时也是货币（花积分不影响等级，等级只看累计 xp）
# ---------------------------------------------------------------------------

## 可花余额 = 累计 XP − 已花 XP。
static func credit_balance(profile: Dictionary = {}) -> int:
	if DEV_INFINITE_CREDITS:
		return INFINITE_CREDIT_DISPLAY
	if profile.is_empty():
		profile = load_profile()
	return maxi(0, _as_int(profile.get("xp"), 0) - _as_int(profile.get("xp_spent"), 0))


## 扣款；余额不足返回 false 且不写档。
static func spend_credits(amount: int) -> bool:
	var cost := maxi(0, amount)
	if cost == 0:
		return true
	if DEV_INFINITE_CREDITS:
		return true
	var profile := load_profile()
	if credit_balance(profile) < cost:
		return false
	profile["xp_spent"] = _as_int(profile.get("xp_spent"), 0) + cost
	save_profile(profile)
	return true


## 退款（不会让已花额度低于 0）。
static func refund_credits(amount: int) -> void:
	var value := maxi(0, amount)
	if value == 0:
		return
	var profile := load_profile()
	profile["xp_spent"] = clampi(_as_int(profile.get("xp_spent"), 0) - value,
		0, _as_int(profile.get("xp"), 0))
	save_profile(profile)


# ---------------------------------------------------------------------------
# 成就
# ---------------------------------------------------------------------------

## 返回全部成就定义（深拷贝，调用方随便改）。
static func achievement_defs() -> Array:
	return ACHIEVEMENTS.duplicate(true)


static func achievements_total() -> int:
	return ACHIEVEMENTS.size()


# ---------------------------------------------------------------------------
# 每日合约
# ---------------------------------------------------------------------------

static func today_key() -> String:
	return Time.get_date_string_from_system()


## 当天抽到的 3 条合约（含进度 / 是否完成 / 是否已领取）。
static func daily_contracts(profile: Dictionary = {}) -> Array:
	if profile.is_empty():
		profile = load_profile()
	var today := today_key()
	var state: Dictionary = profile.get("daily", {})
	if String(state.get("date", "")) != today:
		state = {"date": today, "progress": {}, "claimed": {}}
	var progress: Dictionary = state.get("progress", {})
	var claimed: Dictionary = state.get("claimed", {})
	var picks := _daily_picks(today)
	var out: Array = []
	for idx in picks:
		var def: Dictionary = DAILY_POOL[idx]
		var id := String(def["id"])
		var value := int(progress.get(id, 0))
		var goal := int(def["goal"])
		out.append({
			"id": id,
			"name": String(def["name"]),
			"desc": String(def["desc"]),
			"xp": int(def["xp"]),
			"goal": goal,
			"progress": mini(value, goal),
			"complete": value >= goal,
			"claimed": bool(claimed.get(id, false)),
		})
	return out


## 菜单角标用：{ done, total, claimable, xp_ready }。
static func daily_summary(profile: Dictionary = {}) -> Dictionary:
	var contracts := daily_contracts(profile)
	var done := 0
	var claimable := 0
	var xp_ready := 0
	for c in contracts:
		if bool(c["complete"]):
			done += 1
			if not bool(c["claimed"]):
				claimable += 1
				xp_ready += int(c["xp"])
	return {"done": done, "total": contracts.size(), "claimable": claimable, "xp_ready": xp_ready}


## 领取一条已完成的合约；返回 { ok, xp, name, level_before, level_after, level_up }。
static func claim_daily(id: String) -> Dictionary:
	var profile := load_profile()
	var level_before := int(profile["level"])
	var contracts := daily_contracts(profile)
	for c in contracts:
		if String(c["id"]) != id:
			continue
		if not bool(c["complete"]) or bool(c["claimed"]):
			return {"ok": false, "xp": 0, "name": String(c["name"]),
				"level_before": level_before, "level_after": level_before, "level_up": false}
		var today := today_key()
		var state: Dictionary = profile.get("daily", {})
		if String(state.get("date", "")) != today:
			state = {"date": today, "progress": {}, "claimed": {}}
		(state["claimed"] as Dictionary)[id] = true
		profile["daily"] = state
		profile["xp"] = int(profile["xp"]) + int(c["xp"])
		profile["level"] = level_for_xp(int(profile["xp"]))
		save_profile(profile)
		var level_after := int(profile["level"])
		return {"ok": true, "xp": int(c["xp"]), "name": String(c["name"]),
			"level_before": level_before, "level_after": level_after,
			"level_up": level_after > level_before}
	return {"ok": false, "xp": 0, "name": "", "level_before": level_before,
		"level_after": level_before, "level_up": false}


## 比赛结束后把本场数据累加到今日合约（调用方随后 save_profile）。
static func record_daily(profile: Dictionary, stats: Dictionary) -> void:
	var today := today_key()
	var state: Dictionary = profile.get("daily", {})
	if String(state.get("date", "")) != today:
		state = {"date": today, "progress": {}, "claimed": {}}
	var progress: Dictionary = state.get("progress", {})
	for idx in _daily_picks(today):
		var def: Dictionary = DAILY_POOL[idx]
		var id := String(def["id"])
		var metric := String(def["metric"])
		var amount := maxi(0, _as_int(stats.get(metric), 0))
		if amount > 0:
			progress[id] = int(progress.get(id, 0)) + amount
	state["progress"] = progress
	profile["daily"] = state


## 按日期稳定抽取 3 条（同一天无论重启几次都一样）。
static func _daily_picks(date_key: String) -> Array[int]:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("apex_daily_" + date_key)
	var indices: Array[int] = []
	for i in DAILY_POOL.size():
		indices.append(i)
	for i in mini(3, indices.size()):
		var j := rng.randi_range(i, indices.size() - 1)
		var tmp := indices[i]
		indices[i] = indices[j]
		indices[j] = tmp
	indices.resize(3)
	return indices


# ---------------------------------------------------------------------------
# 比赛提交
# ---------------------------------------------------------------------------

## 结束一场比赛后调用。更新 races / wins / podiums / xp / total_km /
## best_laps / total_nitro / total_drift_time，并结算成就。
##
## 第 3 个参数为可选的「本场氮气次数 / 漂移秒数 / 本场最高时速」：
##   submit_race(race, car, {"nitro_uses": 3, "drift_time": 4.2})
## 不传时数值按 0 处理（也会尝试读取 car / race 上同名字段，方便 Lead 以后加计数器）。
##
## 返回：
##   {
##     "xp_gain": int,
##     "level_before": int, "level_after": int, "level_up": bool,
##     "achievements": [{"id","name","desc","xp"}, ...],
##     "best_laps": [float, ...]   # 该图该车更新后的前 5 快圈
##   }
static func submit_race(race: RaceManager, car: Car,
		session_stats: Dictionary = {}) -> Dictionary:
	var profile := load_profile()
	var level_before := int(profile["level"])
	if race == null or car == null:
		return _empty_result(level_before)

	var finished := bool(race.player_finished) or float(race.player_finish_time) > 0.0
	if not finished:
		return _empty_result(level_before)

	var mode := String(race.mode)
	var laps := maxi(1, int(race.race_laps))
	var track_id := ""
	var track_length := 0.0
	if race.track != null:
		track_id = String(race.track.id)
		track_length = maxf(0.0, float(race.track.total_length))
	if track_id.is_empty():
		track_id = String(race.track_def.get("id", ""))
	if track_id.is_empty():
		track_id = "unknown"

	var car_id := String(car.spec.get("id", ""))
	if car_id.is_empty():
		car_id = String(car.car_id)
	if car_id.is_empty():
		car_id = "unknown"

	var position := clampi(int(race.player_position), 1, maxi(1, int(race.total_cars)))
	var medal := String(race.medal)
	if medal not in ["gold", "silver", "bronze"]:
		medal = "none"

	var nitro_uses := maxi(0, _as_int(
		session_stats.get("nitro_uses", _extra_value(car, race, "nitro_uses")), 0))
	var drift_time := maxf(0.0, _as_float(
		session_stats.get("drift_time", _extra_value(car, race, "drift_time")), 0.0))
	var drift_score := maxi(0, _as_int(
		session_stats.get("drift_score", _extra_value(car, race, "drift_bank")), 0))
	var drift_combo := clampi(_as_int(
		session_stats.get("drift_combo", _extra_value(car, race, "drift_max_combo")), 1), 1, 99)

	var top_speed_kph := 0.0
	var spec: Dictionary = car.spec
	top_speed_kph = maxf(top_speed_kph, _as_float(spec.get("topKph"), 0.0))
	top_speed_kph = maxf(top_speed_kph, float(car.max_speed) * 3.6)
	# 兼容 main.gd 传入的 "top_speed" 以及 "top_speed_kph"。
	for key in ["top_speed_kph", "top_speed"]:
		top_speed_kph = maxf(top_speed_kph, _as_float(session_stats.get(key), 0.0))
		top_speed_kph = maxf(top_speed_kph, _as_float(_extra_value(car, race, key), 0.0))

	# --- 场次 / 名次 / 里程 -------------------------------------------------
	profile["races"] = int(profile["races"]) + 1
	# 计时赛的 player_position 恒为 1，不能计入胜场/登台；只统计 gp。
	if mode == "gp":
		if position == 1:
			profile["wins"] = int(profile["wins"]) + 1
		if position <= 3:
			profile["podiums"] = int(profile["podiums"]) + 1
	var race_km := 0.0
	if track_length > 0.0:
		race_km = track_length * float(laps) / 1000.0
		profile["total_km"] = float(profile["total_km"]) + race_km
	profile["total_nitro"] = int(profile["total_nitro"]) + nitro_uses
	profile["total_drift_time"] = float(profile["total_drift_time"]) + drift_time
	profile["total_drift_score"] = int(profile["total_drift_score"]) + drift_score

	# --- 该图该车的最佳圈 ------------------------------------------------
	var best_lap := float(race.best_lap_time)
	var all_best_laps: Dictionary = profile["best_laps"]
	var track_laps: Dictionary = all_best_laps.get(track_id, {})
	var first_track := true
	for existing_car in track_laps:
		var existing_times = track_laps[existing_car]
		if typeof(existing_times) == TYPE_ARRAY and not (existing_times as Array).is_empty():
			first_track = false
			break

	var car_laps: Array = []
	if track_laps.has(car_id) and typeof(track_laps[car_id]) == TYPE_ARRAY:
		car_laps = (track_laps[car_id] as Array).duplicate()
	var previous_best := -1.0
	if not car_laps.is_empty():
		previous_best = float(car_laps[0])
	var new_best_lap := false
	if best_lap > 0.0 and is_finite(best_lap) and best_lap <= 86400.0:
		if previous_best < 0.0 or best_lap < previous_best:
			new_best_lap = true
		car_laps.append(best_lap)
		car_laps.sort()
		if car_laps.size() > MAX_BEST_LAPS:
			car_laps.resize(MAX_BEST_LAPS)
		track_laps[car_id] = car_laps
		all_best_laps[track_id] = track_laps
		profile["best_laps"] = all_best_laps

	# --- 赛道精通（按全车最快单圈评定，升段一次性发 XP） --------------------
	var difficulty := 2
	if race.track_def is Dictionary:
		difficulty = clampi(int((race.track_def as Dictionary).get("difficulty", 2)), 1, 5)
	var mastery_before := 0
	var mastery_after := 0
	var mastery_xp := 0
	var mastery_map: Dictionary = profile["mastery"]
	if track_length > 0.0 and track_id != "unknown":
		mastery_before = clampi(int(mastery_map.get(track_id, 0)), 0, 3)
		mastery_after = mastery_tier_for(
			track_best_lap(profile, track_id), track_length, difficulty)
		if mastery_after > mastery_before:
			for step in range(mastery_before + 1, mastery_after + 1):
				mastery_xp += int(MASTERY_XP.get(step, 0))
			mastery_map[track_id] = mastery_after
			profile["mastery"] = mastery_map
		else:
			mastery_after = mastery_before

	# --- 本场 XP -----------------------------------------------------------
	var race_xp := XP_FINISH
	if mode == "gp":
		race_xp += int(XP_GP_POSITION.get(position, XP_GP_OTHER))
	race_xp += int(XP_MEDAL.get(medal, 0))
	if new_best_lap:
		race_xp += XP_NEW_BEST_LAP
	if first_track:
		race_xp += XP_NEW_TRACK
	# 漂移技巧奖励：每 500 分 25 XP，单场最多 200
	race_xp += clampi(int(drift_score / 500.0) * 25, 0, 200)
	race_xp += mastery_xp

	# --- 成就结算（等级类成就可能需要两轮：成就 XP 先升级再解锁） ----------
	var xp_before := int(profile["xp"])
	profile["xp"] = xp_before + race_xp
	profile["level"] = level_for_xp(int(profile["xp"]))

	var context := {
		"profile": profile,
		"mode": mode,
		"position": position,
		"medal": medal,
		"best_lap": best_lap,
		"top_speed_kph": top_speed_kph,
		"track_count": _completed_track_count(profile),
		"drift_score": drift_score,
		"drift_combo": drift_combo,
		"mastery_silver": mastery_count(profile, 2),
		"mastery_gold": mastery_count(profile, 3),
	}
	var unlocked: Array = []
	var achievement_xp := 0
	for _pass in 4:
		var found := false
		for def in ACHIEVEMENTS:
			var id := String(def["id"])
			if (profile["achievements"] as Dictionary).has(id):
				continue
			if not _meets(id, context):
				continue
			(profile["achievements"] as Dictionary)[id] = true
			achievement_xp += int(def["xp"])
			unlocked.append({
				"id": id,
				"name": String(def["name"]),
				"desc": String(def["desc"]),
				"xp": int(def["xp"]),
			})
			found = true
		if not found:
			break
		profile["xp"] = xp_before + race_xp + achievement_xp
		profile["level"] = level_for_xp(int(profile["xp"]))

	profile["xp"] = xp_before + race_xp + achievement_xp
	profile["level"] = level_for_xp(int(profile["xp"]))

	record_daily(profile, {
		"races": 1,
		"drift": int(floor(drift_time)),
		"nitro": nitro_uses,
		"best_lap": 1 if new_best_lap else 0,
		"gold": 1 if medal == "gold" else 0,
		"km": int(floor(race_km)),
		"podium": 1 if mode == "gp" and position <= 3 else 0,
	})

	save_profile(profile)

	var level_after := int(profile["level"])
	return {
		"xp_gain": int(profile["xp"]) - xp_before,
		"credit_balance": credit_balance(profile),
		"level_before": level_before,
		"level_after": level_after,
		"level_up": level_after > level_before,
		"achievements": unlocked,
		"best_laps": car_laps.duplicate(),
		"mastery": {
			"track": track_id,
			"before": mastery_before,
			"after": mastery_after,
			"xp": mastery_xp,
			"before_label": mastery_label(mastery_before),
			"label": mastery_label(mastery_after),
		},
	}


static func _empty_result(level: int) -> Dictionary:
	return {
		"xp_gain": 0,
		"credit_balance": credit_balance(),
		"level_before": level,
		"level_after": level,
		"level_up": false,
		"achievements": [],
		"best_laps": [],
		"mastery": {},
	}


static func _completed_track_count(profile: Dictionary) -> int:
	var count := 0
	var all_best_laps: Dictionary = profile.get("best_laps", {})
	for track_id in all_best_laps:
		var by_car = all_best_laps[track_id]
		if typeof(by_car) != TYPE_DICTIONARY:
			continue
		for car_id in (by_car as Dictionary):
			var times = (by_car as Dictionary)[car_id]
			if typeof(times) == TYPE_ARRAY and not (times as Array).is_empty():
				count += 1
				break
	return count


static func _meets(id: String, ctx: Dictionary) -> bool:
	var profile: Dictionary = ctx["profile"]
	match id:
		"first_finish":
			return int(profile["races"]) >= 1
		"first_podium":
			return int(profile["podiums"]) >= 1
		"first_win":
			return int(profile["wins"]) >= 1
		"medal_gold":
			return String(ctx["medal"]) == "gold"
		"medal_silver":
			return String(ctx["medal"]) == "silver"
		"medal_bronze":
			return String(ctx["medal"]) == "bronze"
		"speed_250":
			return float(ctx["top_speed_kph"]) >= 250.0
		"speed_300":
			return float(ctx["top_speed_kph"]) >= 300.0
		"nitro_10":
			return int(profile["total_nitro"]) >= 10
		"drift_10":
			return float(profile["total_drift_time"]) >= 10.0
		"tracks_3":
			return int(ctx["track_count"]) >= 3
		"lap_130":
			var lap := float(ctx["best_lap"])
			return lap > 0.0 and lap < 90.0
		"distance_100":
			return float(profile["total_km"]) >= 100.0
		"races_10":
			return int(profile["races"]) >= 10
		"level_10":
			return int(profile["level"]) >= 10
		"drift_combo_5":
			return int(ctx["drift_combo"]) >= 5
		"drift_score_3000":
			return int(ctx["drift_score"]) >= 3000
		"drift_time_60":
			return float(profile["total_drift_time"]) >= 60.0
		"races_25":
			return int(profile["races"]) >= 25
		"track_sweep":
			return int(ctx["track_count"]) >= 8
		"level_20":
			return int(profile["level"]) >= 20
		"mastery_silver3":
			return mastery_count(profile, 2) >= 3
		"mastery_allgold":
			return mastery_count(profile, 3) >= 8
	return false


static func _extra_value(car: Car, race: RaceManager, key: String) -> Variant:
	if car != null:
		var from_car = car.get(key)
		if from_car != null:
			return from_car
	if race != null:
		var from_race = race.get(key)
		if from_race != null:
			return from_race
	return null


# ---------------------------------------------------------------------------
# 奖牌目标 / 排行 / 摘要
# ---------------------------------------------------------------------------

## 奖牌目标秒数。公式与 RaceManager 一致：
##   目标 = max(600, 总长) / (PACE * 难度缩放) * 圈数
## TA 模式只算单圈；laps 对 TA 无效。
## difficulty 可选（默认 2）；传入 track_def.difficulty 时与 RaceManager 完全一致。
static func medal_targets(track: TrackPath, laps: int, mode: String,
		difficulty: int = 2) -> Dictionary:
	if track == null:
		return {"gold": 0.0, "silver": 0.0, "bronze": 0.0}
	var length := maxf(600.0, float(track.total_length))
	var count := 1.0 if String(mode).to_lower() == "ta" else float(maxi(1, laps))
	var scale := 1.0 - (float(clampi(difficulty, 1, 5)) - 2.0) * 0.07
	return {
		"gold": length / (float(PACE["gold"]) * scale) * count,
		"silver": length / (float(PACE["silver"]) * scale) * count,
		"bronze": length / (float(PACE["bronze"]) * scale) * count,
	}


## 赛道精通目标（单圈秒数）。与 TA 金牌目标同一套配速，保证「精通金牌 = 计时赛金牌」。
static func mastery_targets(track_length: float, difficulty: int = 2) -> Dictionary:
	var length := maxf(600.0, track_length)
	var scale := 1.0 - (float(clampi(difficulty, 1, 5)) - 2.0) * 0.07
	return {
		"gold": length / (float(PACE["gold"]) * scale),
		"silver": length / (float(PACE["silver"]) * scale),
		"bronze": length / (float(PACE["bronze"]) * scale),
	}


## 单圈成绩对应的精通段位：0 未达标 / 1 铜 / 2 银 / 3 金。
static func mastery_tier_for(lap: float, track_length: float, difficulty: int = 2) -> int:
	if lap <= 0.0 or not is_finite(lap):
		return 0
	var targets := mastery_targets(track_length, difficulty)
	if lap <= float(targets["gold"]):
		return 3
	if lap <= float(targets["silver"]):
		return 2
	if lap <= float(targets["bronze"]):
		return 1
	return 0


static func mastery_label(tier: int) -> String:
	return String(MASTERY_LABELS[clampi(tier, 0, 3)])


## 该赛道所有车辆里的最快单圈（精通按车手整体水平评定，不绑车型）。
static func track_best_lap(profile: Dictionary, track_id: String) -> float:
	var best := -1.0
	var all_laps = profile.get("best_laps", {})
	if typeof(all_laps) != TYPE_DICTIONARY:
		return best
	var by_car = (all_laps as Dictionary).get(track_id, {})
	if typeof(by_car) != TYPE_DICTIONARY:
		return best
	for car_id in (by_car as Dictionary):
		var times = (by_car as Dictionary)[car_id]
		if typeof(times) != TYPE_ARRAY:
			continue
		for t in (times as Array):
			var value := _as_float(t, 0.0)
			if value > 0.0 and (best < 0.0 or value < best):
				best = value
	return best


## 达到 min_tier 及以上的赛道数量。
static func mastery_count(profile: Dictionary, min_tier: int = 1) -> int:
	var count := 0
	var mastery = profile.get("mastery", {})
	if typeof(mastery) != TYPE_DICTIONARY:
		return count
	for track_id in (mastery as Dictionary):
		if _as_int((mastery as Dictionary)[track_id], 0) >= min_tier:
			count += 1
	return count


## 给菜单/结算用的赛道精通快照。
static func mastery_state(profile: Dictionary, track_id: String,
		track_length: float, difficulty: int = 2) -> Dictionary:
	var mastery = profile.get("mastery", {})
	var tier := 0
	if typeof(mastery) == TYPE_DICTIONARY:
		tier = clampi(_as_int((mastery as Dictionary).get(track_id, 0), 0), 0, 3)
	var best := track_best_lap(profile, track_id)
	var targets := mastery_targets(track_length, difficulty)
	# 老档案可能已有达标圈速但还没写入 mastery：显示按实际圈速补算，
	# 下次结算时会补发一次性精通 XP。
	tier = maxi(tier, mastery_tier_for(best, track_length, difficulty))
	var next_tier := tier + 1
	var next_target := 0.0
	if next_tier <= 3:
		next_target = float(targets[["bronze", "silver", "gold"][next_tier - 1]])
	return {
		"track": track_id,
		"tier": tier,
		"label": mastery_label(tier),
		"best_lap": best,
		"targets": targets,
		"next_tier": next_tier if next_tier <= 3 else 0,
		"next_target": next_target,
	}


## 该赛道该车的最快圈前 5（升序，float 数组）。无记录返回 []。
static func leaderboard(track_id: String, car_id: String) -> Array:
	var profile := load_profile()
	var all_best_laps: Dictionary = profile.get("best_laps", {})
	var by_car = all_best_laps.get(track_id, {})
	if typeof(by_car) != TYPE_DICTIONARY:
		return []
	var times = (by_car as Dictionary).get(car_id, [])
	if typeof(times) != TYPE_ARRAY:
		return []
	var out: Array = []
	for t in (times as Array):
		var value := _as_float(t, 0.0)
		if value > 0.0:
			out.append(value)
	out.sort()
	if out.size() > MAX_BEST_LAPS:
		out.resize(MAX_BEST_LAPS)
	return out


## 给 UI 的多行摘要（等级 / XP / 战绩 / 成就 / 里程 / 氮气漂移 / 最佳单圈）。
static func format_summary() -> Array[String]:
	var profile := load_profile()
	var progress := level_progress(int(profile["xp"]))
	var unlocked := (profile["achievements"] as Dictionary).size()
	var best := _best_overall_lap(profile)
	var lines: Array[String] = []
	lines.append("车手等级  Lv.%d  ·  总经验 %d XP" % [int(profile["level"]), int(profile["xp"])])
	lines.append("升级进度  %d / %d XP  (%d%%)  ·  可用积分 %d XP" % [
		int(progress["xp_into_level"]), int(progress["xp_needed"]),
		int(round(float(progress["ratio"]) * 100.0)), credit_balance(profile)])
	lines.append("完赛 %d  ·  胜场 %d  ·  登台 %d" % [
		int(profile["races"]), int(profile["wins"]), int(profile["podiums"])])
	lines.append("成就 %d / %d  ·  累计 %.1f km" % [
		unlocked, ACHIEVEMENTS.size(), float(profile["total_km"])])
	lines.append("氮气 %d 次  ·  漂移 %.1f s  ·  漂移分 %d  ·  最佳单圈 %s" % [
		int(profile["total_nitro"]), float(profile["total_drift_time"]),
		int(profile["total_drift_score"]), _format_lap(best)])
	return lines


static func _best_overall_lap(profile: Dictionary) -> float:
	var best := -1.0
	var all_best_laps: Dictionary = profile.get("best_laps", {})
	for track_id in all_best_laps:
		var by_car = all_best_laps[track_id]
		if typeof(by_car) != TYPE_DICTIONARY:
			continue
		for car_id in (by_car as Dictionary):
			var times = (by_car as Dictionary)[car_id]
			if typeof(times) != TYPE_ARRAY:
				continue
			for t in (times as Array):
				var value := _as_float(t, 0.0)
				if value > 0.0 and (best < 0.0 or value < best):
					best = value
	return best


static func _format_lap(t: float) -> String:
	if t <= 0.0 or not is_finite(t):
		return "--:--.---"
	var total_ms := int(round(t * 1000.0))
	var m := int(total_ms / 60000)
	var s := int(total_ms / 1000) % 60
	var ms := total_ms % 1000
	return "%02d:%02d.%03d" % [m, s, ms]


# ---------------------------------------------------------------------------
# 类型兜底（JSON / 老档案 / 手工改档都可能给出奇怪类型）
# ---------------------------------------------------------------------------

static func _clean_int_map(value: Variant) -> Dictionary:
	var out := {}
	if typeof(value) != TYPE_DICTIONARY:
		return out
	for key in (value as Dictionary):
		var n := _as_int((value as Dictionary)[key], 0)
		if n > 0:
			out[String(key)] = n
	return out


static func _clean_bool_map(value: Variant) -> Dictionary:
	var out := {}
	if typeof(value) != TYPE_DICTIONARY:
		return out
	for key in (value as Dictionary):
		if bool((value as Dictionary)[key]):
			out[String(key)] = true
	return out


static func _as_int(value: Variant, fallback: int = 0) -> int:
	if value == null:
		return fallback
	match typeof(value):
		TYPE_INT:
			return int(value)
		TYPE_FLOAT:
			var f := float(value)
			if not is_finite(f):
				return fallback
			return int(f)
		TYPE_BOOL:
			return 1 if bool(value) else 0
		TYPE_STRING, TYPE_STRING_NAME:
			var s := float(String(value))
			return int(s) if is_finite(s) else fallback
	return fallback


static func _as_float(value: Variant, fallback: float = 0.0) -> float:
	if value == null:
		return fallback
	match typeof(value):
		TYPE_INT, TYPE_FLOAT:
			var f := float(value)
			return f if is_finite(f) else fallback
		TYPE_BOOL:
			return 1.0 if bool(value) else 0.0
		TYPE_STRING, TYPE_STRING_NAME:
			var f := float(String(value))
			return f if is_finite(f) else fallback
	return fallback
