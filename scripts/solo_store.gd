extends RefCounted
## Versioned, object-free local files with atomic replacement and backup recovery.
const Rules = preload("res://scripts/rami_engine.gd")
const SAVE := "user://solo-v1.save"
const STATS := "user://stats-v1.save"

static func write_data(path: String, data: Dictionary) -> bool:
	var file := FileAccess.open(path + ".tmp", FileAccess.WRITE)
	if file == null: return false
	file.store_var(data, false)
	file.flush()
	var error := file.get_error()
	file.close()
	if error != OK: return false
	if FileAccess.file_exists(path):
		if FileAccess.file_exists(path + ".bak"):
			DirAccess.remove_absolute(path + ".bak")
		if DirAccess.rename_absolute(path, path + ".bak") != OK: return false
	return DirAccess.rename_absolute(path + ".tmp", path) == OK

static func read_data(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() > 2000000: return {}
	var data: Variant = file.get_var(false)
	return data if data is Dictionary else {}

static func save_game(engine: RefCounted, difficulty: int, order: Array) -> bool:
	return write_data(SAVE, {"version":1, "game":engine.export_game(), "difficulty":difficulty, "order":order.duplicate()})

static func load_game() -> Dictionary:
	for path in [SAVE, SAVE + ".bak"]:
		var data := read_data(path)
		if data.get("version",0) == 1 and Rules.new().restore_game(data.get("game",{})):
			return data
	return {}

static func statistics() -> Dictionary:
	for path in [STATS, STATS + ".bak"]:
		var data := read_data(path)
		if data.get("seen") is Dictionary and data.get("rounds") is int and data.get("wins") is int and data.get("points") is int:
			return data
	return {"rounds":0,"wins":0,"points":0,"seen":{}}

static func record_round(state: Dictionary) -> void:
	if int(state.get("winner",-1)) < 0: return
	var match_data: Dictionary = state.get("match",{})
	if match_data.get("results",[]).is_empty(): return
	var stats := statistics()
	var key := str(state.get("session_id","")) + ":" + str(match_data.round)
	if stats.seen.has(key): return
	stats.seen[key] = true
	stats.rounds += 1
	stats.wins += 1 if int(state.winner) == 0 else 0
	stats.points += int(match_data.results.back().points[0])
	write_data(STATS, stats)
