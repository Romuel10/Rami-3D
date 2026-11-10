extends Node

signal changed

const Store = preload("res://scripts/solo_store.gd")
const PATH := "user://tselis-v1.save"
const UNIT := "Kirobo"
const INITIAL := 500
const REWARDS := [25, 60, 120]
const STAKES := [0, 25, 50, 100, 200, 500]
const BATCH_SIZE := 24

var server_url := ""
var _data: Dictionary = {}
var _socket: WebSocketPeer
var _sent := false
var _again := false
var _deadline := 0
var _batch: Array = []

static func amount(value: int, signed_amount: bool = false) -> String:
	return ("%+d %s" if signed_amount else "%d %s") % [value, UNIT]

func _ready() -> void:
	reload()

func reload() -> void:
	_end_sync()
	_again = false
	_data = load_wallet()
	changed.emit()

static func valid_hex(value: Variant, minimum: int, maximum: int) -> bool:
	if not value is String or value.length() < minimum or value.length() > maximum: return false
	for digit in value:
		if not digit in "0123456789abcdef": return false
	return true

static func checked_data(value: Variant) -> Dictionary:
	if not value is Dictionary or not valid_hex(value.get("key"), 48, 48): return {}
	var balance: Variant = value.get("balance")
	if not (balance is int or balance is float) or balance < 0 or balance > 9007199254740991 or floorf(balance) != balance: return {}
	if not value.get("wins") is Dictionary: return {}
	var wins: Dictionary = {}
	for id in value.wins:
		var level: Variant = value.wins[id]
		if not valid_hex(id, 2, 16) or not (level is int or level is float) or level < -1 or level > 2 or int(level) != level: return {}
		wins[id] = int(level)
	return {"key":value.key, "balance":int(balance), "wins":wins}

static func load_wallet() -> Dictionary:
	for path in [PATH, PATH + ".bak"]:
		var data := checked_data(Store.read_data(path))
		if not data.is_empty(): return data
	return {}

static func restore_wallet(data: Dictionary) -> bool:
	var existing := load_wallet()
	if existing.get("key") == data.key:
		for id in existing.wins:
			if not data.wins.has(id) or existing.wins[id] == -1: data.wins[id] = existing.wins[id]
		data.balance = existing.balance
	return Store.write_data(PATH, data)

func key() -> String:
	if _data.is_empty():
		var secret := Crypto.new().generate_random_bytes(24).hex_encode()
		if not valid_hex(secret, 48, 48): return ""
		var data := {"key":secret, "balance":INITIAL, "wins":{}}
		if not Store.write_data(PATH, data): return ""
		_data = data
	return _data.key

func balance() -> int:
	var total := int(_data.get("balance", INITIAL))
	for level in _data.get("wins", {}).values():
		if level >= 0: total += REWARDS[level]
	return total

func record_victory(match_id: String, level: int) -> bool:
	if not valid_hex(match_id, 2, 16) or not level in [0, 1, 2] or key().is_empty(): return false
	if _data.wins.has(match_id): return true
	var updated := _data.duplicate(true)
	updated.wins[match_id] = level
	if not Store.write_data(PATH, updated): return false
	_data = updated
	changed.emit()
	sync(true)
	return true

func sync(force: bool = false) -> void:
	if server_url.is_empty() or not server_url.begins_with("wss://") or key().is_empty(): return
	if _socket != null:
		_again = _again or force
		return
	for id in _data.wins:
		if _data.wins[id] >= 0:
			_batch.append({"id":id, "level":_data.wins[id]})
			if _batch.size() == BATCH_SIZE: break
	_socket = WebSocketPeer.new()
	_deadline = Time.get_ticks_msec() + 8000
	if _socket.connect_to_url(server_url) != OK:
		_end_sync()

func _process(_delta: float) -> void:
	if _socket == null: return
	if Time.get_ticks_msec() >= _deadline:
		_end_sync()
		return
	_socket.poll()
	if _socket.get_available_packet_count() > 0:
		var message: Variant = JSON.parse_string(_socket.get_packet().get_string_from_utf8())
		if message is Dictionary and message.get("type") == "wallet":
			_confirm(message.get("balance"))
		else:
			_end_sync()
		return
	if _socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		if not _sent:
			if _socket.send_text(JSON.stringify({"type":"wallet_sync", "wallet_key":_data.key, "wins":_batch})) != OK:
				_end_sync()
				return
			_sent = true
	elif _socket.get_ready_state() == WebSocketPeer.STATE_CLOSED:
		_end_sync()

func _confirm(value: Variant) -> void:
	var updated := _data.duplicate(true)
	updated.balance = value
	for claim in _batch: updated.wins[claim.id] = -1
	var checked := checked_data(updated)
	var more := _batch.size() == BATCH_SIZE or _again
	_end_sync()
	_again = false
	if checked.is_empty(): return
	if checked != _data:
		if not Store.write_data(PATH, checked): return
		_data = checked
		changed.emit()
	if more: sync()

func _end_sync() -> void:
	if _socket != null: _socket.close()
	_socket = null
	_sent = false
	_batch.clear()
