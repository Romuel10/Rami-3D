extends RefCounted

const PROVINCES := ["Antananarivo", "Antsiranana", "Fianarantsoa", "Mahajanga", "Toamasina", "Toliara"]
const Store = preload("res://scripts/solo_store.gd")
const Rules = preload("res://scripts/rami_engine.gd")
const PREFERENCES := "user://preferences.cfg"
const RESTORE := "user://profile-restore.save"
const BACKUP_LIMIT := 512000

static func clean_name(value: String) -> String:
	return value.replace("\n", " ").replace("\r", " ").replace("\t", " ").strip_edges().left(20)

static func backup_text(name: String, province: String) -> String:
	return JSON.stringify({"format": "rami-salon", "version": 1, "name": name, "province": province, "solo": Store.load_game(), "stats": Store.statistics()})

static func parse_backup(text: String) -> Dictionary:
	if text.length() > BACKUP_LIMIT: return {}
	var data: Variant = JSON.parse_string(text)
	if not data is Dictionary or data.get("format") != "rami-salon" or data.get("version") != 1: return {}
	if not data.get("name") is String or not data.get("province") in PROVINCES: return {}
	var name := clean_name(data.name)
	if name.is_empty() or not data.get("solo") is Dictionary or not data.get("stats") is Dictionary: return {}
	var solo: Dictionary = data.solo
	if not solo.is_empty():
		var rules := Rules.new()
		if solo.get("version") != 1 or not rules.restore_game(solo.get("game")): return {}
		if not _count(solo.get("difficulty"), 2) or not solo.get("order") is Array or solo.order.size() > 108: return {}
		for id in solo.order:
			if not id is String or rules.card_info(id).is_empty(): return {}
		solo = {"version": 1, "game": rules.export_game(), "difficulty": int(solo.difficulty), "order": solo.order}
	var stats: Dictionary = data.stats
	for field in ["rounds", "wins", "points"]:
		if not _count(stats.get(field), 2147483647): return {}
	if stats.wins > stats.rounds or not stats.get("seen") is Dictionary: return {}
	for key in stats.seen:
		if not key is String or key.length() > 100 or stats.seen[key] != true: return {}
	return {"name": name, "province": data.province, "solo": solo, "stats": {"rounds": int(stats.rounds), "wins": int(stats.wins), "points": int(stats.points), "seen": stats.seen}}

static func _count(value: Variant, maximum: int) -> bool:
	return (value is int or value is float) and value >= 0 and value <= maximum and floorf(float(value)) == float(value)

static func save_preferences(cfg: ConfigFile) -> bool:
	return cfg.save(PREFERENCES + ".tmp") == OK and DirAccess.rename_absolute(PREFERENCES + ".tmp", PREFERENCES) == OK

static func finish_restore() -> bool:
	# The journal survives a process restart between the three local writes.
	if not FileAccess.file_exists(RESTORE): return true
	var data := Store.read_data(RESTORE)
	if data.is_empty(): return false
	var cfg := ConfigFile.new()
	cfg.load(PREFERENCES)
	cfg.set_value("player", "name", data.name)
	cfg.set_value("player", "province", data.province)
	var solo: Dictionary = data.solo if not data.solo.is_empty() else {"version": 1, "empty": true}
	return Store.write_data(Store.SAVE, solo) and Store.write_data(Store.STATS, data.stats) and save_preferences(cfg) and DirAccess.remove_absolute(RESTORE) == OK
