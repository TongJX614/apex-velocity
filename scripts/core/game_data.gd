extends Node
## Autoload: loads the engine-agnostic data extracted from the legacy project.
## Every other script reads content through this singleton.

const DATA_DIR := "res://data"

var cars_specs: Array = []
var cars: Dictionary = {}
var palettes: Dictionary = {}
var engine_for: Dictionary = {}
var tracks: Array = []
var tracks_by_id: Dictionary = {}
var garage: Dictionary = {}
var ai: Dictionary = {}
var records: Dictionary = {}
var car_manifest: Dictionary = {}
var bgm: Array = []
var load_errors: PackedStringArray = []


func _ready() -> void:
	_reload()


func _reload() -> void:
	var cars_doc: Dictionary = _read_json("cars.json")
	if not cars_doc.is_empty():
		cars_specs = cars_doc.get("specs", [])
		palettes = cars_doc.get("palettes", {})
		engine_for = cars_doc.get("engine_for", {})
		for spec in cars_specs:
			if typeof(spec) == TYPE_DICTIONARY and spec.has("id"):
				cars[String(spec["id"])] = spec
	var tracks_doc: Dictionary = _read_json("tracks.json")
	if not tracks_doc.is_empty():
		tracks = tracks_doc.get("tracks", [])
		for t in tracks:
			if typeof(t) == TYPE_DICTIONARY and t.has("id"):
				tracks_by_id[String(t["id"])] = t
	garage = _read_json("garage.json")
	ai = _read_json("ai.json")
	records = _read_json("records.json")
	car_manifest = _read_json("car_manifest.json")
	bgm = _read_json_array("bgm_manifest.json")
	if load_errors.size() > 0:
		push_error("GameData failed to load: " + " | ".join(load_errors))


func _read_json(file_name: String) -> Dictionary:
	var res_path := DATA_DIR.path_join(file_name)
	if not FileAccess.file_exists(res_path):
		load_errors.append("missing " + res_path)
		return {}
	var f := FileAccess.open(res_path, FileAccess.READ)
	if f == null:
		load_errors.append("cannot open " + res_path)
		return {}
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		load_errors.append("bad json: " + res_path)
		return {}
	return parsed


func _read_json_array(file_name: String) -> Array:
	var res_path := DATA_DIR.path_join(file_name)
	if not FileAccess.file_exists(res_path):
		load_errors.append("missing " + res_path)
		return []
	var f := FileAccess.open(res_path, FileAccess.READ)
	if f == null:
		load_errors.append("cannot open " + res_path)
		return []
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_ARRAY:
		load_errors.append("expected array json: " + res_path)
		return []
	return parsed


func car(id: String) -> Dictionary:
	return cars.get(id, {})


func track(id: String) -> Dictionary:
	return tracks_by_id.get(id, {})


func first_track_id() -> String:
	return String(tracks[0]["id"]) if tracks.size() > 0 else ""


func palette_for(car_id: String) -> Array:
	return palettes.get(car_id, [])


func summary() -> String:
	return "cars=%d tracks=%d ai=%d" % [cars.size(), tracks.size(), int(ai.get("defs", []).size())]
