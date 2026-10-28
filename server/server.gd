extends SceneTree
## Authoritative Internet rooms. A voluntary leave is a forfeit; a lost
## transport has a bounded reconnect grace. Optional room files contain secrets.
const EngineScript = preload("res://scripts/rami_engine.gd")
const MAX_PACKET_BYTES := 32768
const MAX_CONNECTIONS := 256
const MAX_ROOMS := 64
const AUTH_TIMEOUT_MS := 8000
const EMPTY_ROOM_TTL_MS := 900000
const ROOM_TTL_MS := 86400000
const MAX_STATE_BYTES := 8388608

var server := TCPServer.new()
var peers: Dictionary = {}
var rooms: Dictionary = {}
var next_id := 1
var port := 7357
var reconnect_grace_ms := 60000
var state_file := ""
var sweep_at := 0
var _replace_invalid_primary := false

func _initialize() -> void:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--port="):
			port = argument.trim_prefix("--port=").to_int()
		elif argument.begins_with("--reconnect-grace-ms="):
			reconnect_grace_ms = argument.trim_prefix("--reconnect-grace-ms=").to_int()
		elif argument.begins_with("--state-file="):
			state_file = argument.trim_prefix("--state-file=")
	if port < 1024 or port > 65535 or reconnect_grace_ms < 100 or reconnect_grace_ms > 300000:
		printerr("Invalid port or reconnect grace (100..300000 ms).")
		quit(2)
		return
	_restore_rooms()
	var error: int = server.listen(port, "0.0.0.0")
	if error != OK:
		printerr("Cannot listen on port %d: %s" % [port, error_string(error)])
		quit(2)
		return
	print("RAMI_SERVER_READY port=%d" % port)

func _process(_delta: float) -> bool:
	while server.is_connection_available():
		var stream := server.take_connection()
		if peers.size() >= MAX_CONNECTIONS:
			stream.disconnect_from_host()
			continue
		var socket := WebSocketPeer.new()
		socket.inbound_buffer_size = MAX_PACKET_BYTES
		socket.outbound_buffer_size = 262144
		if socket.accept_stream(stream) != OK:
			stream.disconnect_from_host()
			continue
		peers[next_id] = {"socket": socket, "room": "", "player": -1,
			"deadline": Time.get_ticks_msec() + AUTH_TIMEOUT_MS, "last_action": -1000,
			"leaving": false, "close_at": 0}
		next_id += 1
	for peer_id: int in peers.keys():
		if not peers.has(peer_id):
			continue
		var entry: Dictionary = peers[peer_id]
		var socket: WebSocketPeer = entry.socket
		socket.poll()
		var status: int = socket.get_ready_state()
		if status == WebSocketPeer.STATE_OPEN:
			var count := 0
			while socket.get_available_packet_count() > 0 and count < 24 and peers.has(peer_id) and not bool(entry.leaving):
				count += 1
				var packet: PackedByteArray = socket.get_packet()
				if packet.size() > MAX_PACKET_BYTES or not socket.was_string_packet():
					socket.close(1009, "Invalid packet")
					break
				var message: Variant = JSON.parse_string(packet.get_string_from_utf8())
				if not message is Dictionary:
					socket.close(1007, "Invalid JSON object")
					break
				_message(peer_id, message)
		if status == WebSocketPeer.STATE_CLOSED:
			_disconnect(peer_id)
		elif bool(entry.leaving) and Time.get_ticks_msec() >= int(entry.close_at):
			socket.close(1000, "Départ du salon")
		elif int(entry.player) < 0 and not bool(entry.leaving) and Time.get_ticks_msec() > int(entry.deadline):
			socket.close(1008, "Authentication required")
	var now := Time.get_ticks_msec()
	if now >= sweep_at:
		sweep_at = now + mini(1000, maxi(20, reconnect_grace_ms / 4))
		_sweep(now)
	return false

func _message(peer_id: int, message: Dictionary) -> void:
	if not peers.has(peer_id) or bool(peers[peer_id].leaving):
		return
	var entry: Dictionary = peers[peer_id]
	var kind := str(message.get("type", ""))
	if int(entry.player) < 0:
		if kind == "create":
			_create_room(peer_id, message)
		elif kind == "join":
			_join_room(peer_id, message)
		else:
			_error(peer_id, "Créez ou rejoignez d’abord un salon.")
		return
	var code := str(entry.room)
	if not rooms.has(code):
		_error(peer_id, "Le salon a expiré.", true)
		return
	var room: Dictionary = rooms[code]
	_touch(room)
	if kind == "leave":
		_leave(peer_id)
	elif kind == "start":
		if int(entry.player) != _owner(room):
			_error(peer_id, "Seul l’hôte peut lancer la partie.")
		elif bool(room.started):
			_error(peer_id, "La partie a déjà commencé.")
		elif room.players.size() < 2:
			_error(peer_id, "Il faut au moins deux joueurs.")
		elif _paused(room):
			_error(peer_id, "Attendez le retour de tous les joueurs.")
		else:
			var names: Array = []
			for player: Dictionary in room.players:
				names.append(player.name)
			room.engine = EngineScript.new()
			if int(room.get("tri_cards",0)) > 0: room.engine.start_tri_game(names,int(room.tri_cards))
			else: room.engine.start_game(names)
			room.started = true
			_persist_rooms()
			_broadcast_lobby(code)
			_broadcast_state(code)
	elif kind == "action":
		if not bool(room.started):
			_error(peer_id, "La partie n’a pas encore commencé.")
			return
		if _forfeited(room, int(entry.player)):
			_error(peer_id, "Vous avez abandonné cette partie.", true)
			return
		if _paused(room):
			_error(peer_id, "La partie attend la reconnexion d’un joueur.")
			return
		var action: Variant = message.get("action")
		if not action is Dictionary:
			_error(peer_id, "Action incorrecte.")
			return
		var now := Time.get_ticks_msec()
		if now - int(entry.last_action) < 40:
			_error(peer_id, "Attendez un instant avant votre prochaine action.")
			return
		entry.last_action = now
		var result: Dictionary = room.engine.apply_action(int(entry.player), action)
		if bool(result.get("ok", false)):
			_persist_rooms()
			_broadcast_state(code)
		else:
			_error(peer_id, str(result.get("error", "Action impossible.")))
	else:
		_error(peer_id, "Message inconnu.")

func _create_room(peer_id: int, message: Dictionary) -> void:
	var tri_value: Variant = message.get("tri_cards",0)
	if not EngineScript.new()._saved_integer(tri_value,0,12) or not int(tri_value) in [0,6,12]:
		_error(peer_id,"Choisissez 6 ou 12 cartes pour le Tri.",true)
		return
	if rooms.size() >= MAX_ROOMS:
		_error(peer_id, "Le serveur est complet. Réessayez plus tard.", true)
		return
	var code := "%06d" % randi_range(0, 999999)
	while rooms.has(code):
		code = "%06d" % randi_range(0, 999999)
	var token := _new_token()
	var now := Time.get_ticks_msec()
	rooms[code] = {"tri_cards":int(tri_value), "players": [{"name": _clean_name(message.get("name", "Joueur")),
		"token": token, "peer": peer_id, "reconnect_at": 0}], "started": false, "engine": null,
		"created": now, "activity": now, "activity_unix": int(Time.get_unix_time_from_system()), "empty_since": 0}
	peers[peer_id].room = code
	peers[peer_id].player = 0
	_welcome(peer_id, code, 0, token)
	_broadcast_lobby(code)

func _join_room(peer_id: int, message: Dictionary) -> void:
	var code := str(message.get("code", ""))
	if code.length() != 6 or not code.is_valid_int() or not rooms.has(code):
		_error(peer_id, "Le code du salon est incorrect.", true)
		return
	var room: Dictionary = rooms[code]
	var token := str(message.get("token", ""))
	var seat := -1
	if not token.is_empty():
		for index: int in range(room.players.size()):
			if str(room.players[index].token) == token:
				seat = index
				break
		if seat < 0:
			_error(peer_id, "Le jeton de reconnexion est incorrect.", true)
			return
		if _forfeited(room, seat):
			_send_rejected_state(peer_id, room, seat)
			_error(peer_id, "Cette place a été perdue par abandon.", true)
			return
		if int(room.players[seat].peer) >= 0:
			_error(peer_id, "Ce joueur est déjà connecté.", true)
			return
		if bool(room.started) and not _finished(room) and int(room.players[seat].get("reconnect_at", 0)) > 0 and Time.get_ticks_msec() >= int(room.players[seat].reconnect_at):
			_expire_players(code, Time.get_ticks_msec())
			_persist_rooms()
			_send_rejected_state(peer_id, room, seat)
			_error(peer_id, "Le délai de reconnexion est dépassé.", true)
			return
	else:
		if bool(room.started):
			_error(peer_id, "Cette partie a déjà commencé.", true)
			return
		if room.players.size() >= (2 if int(room.get("tri_cards",0)) > 0 else 4):
			_error(peer_id, "Le salon est complet.", true)
			return
		seat = room.players.size()
		token = _new_token()
		room.players.append({"name": _clean_name(message.get("name", "Joueur")),
			"token": token, "peer": peer_id, "reconnect_at": 0})
	room.players[seat].peer = peer_id
	room.players[seat].reconnect_at = 0
	_touch(room)
	room.empty_since = 0
	peers[peer_id].room = code
	peers[peer_id].player = seat
	_persist_rooms()
	_welcome(peer_id, code, seat, token)
	_broadcast_lobby(code)
	if bool(room.started):
		_broadcast_state(code)

func _owner(room: Dictionary) -> int:
	for i in range(room.players.size()):
		if not _forfeited(room, i):
			return i
	return 0

func _welcome(peer_id: int, code: String, seat: int, token: String) -> void:
	_send(peer_id, {"type": "welcome", "player": seat, "code": code,
		"token": token, "is_host": seat == _owner(rooms[code])})

func _broadcast_lobby(code: String) -> void:
	if not rooms.has(code): return
	var room: Dictionary = rooms[code]
	var summaries: Array = []
	for i in range(room.players.size()):
		var player: Dictionary = room.players[i]
		summaries.append({"name": player.name, "connected": int(player.peer) >= 0, "forfeited": _forfeited(room, i)})
	for seat: int in range(room.players.size()):
		var id := int(room.players[seat].peer)
		if id >= 0:
			_send(id, {"type": "lobby", "data": {"code": code,
				"players": summaries, "port": port, "started": room.started, "tri_cards":int(room.get("tri_cards",0)),
				"host": seat == _owner(room), "your_index": seat}})

func _broadcast_state(code: String) -> void:
	if not rooms.has(code): return
	var room: Dictionary = rooms[code]
	var paused := _paused(room)
	var remaining := _reconnect_remaining(room)
	for seat: int in range(room.players.size()):
		var id := int(room.players[seat].peer)
		if id >= 0:
			var view: Dictionary = room.engine.view_for(seat)
			view.paused = paused
			view.reconnect_remaining_ms = remaining
			view.your_index = seat
			view.online = true
			_send(id, {"type": "state", "data": view})

func _send_rejected_state(peer_id: int, room: Dictionary, seat: int) -> void:
	if not bool(room.started) or room.engine == null: return
	var view: Dictionary = room.engine.view_for(seat)
	view.paused = _paused(room)
	view.reconnect_remaining_ms = _reconnect_remaining(room)
	view.your_index = seat
	view.online = true
	_send(peer_id, {"type": "state", "data": view})

func _finished(room: Dictionary) -> bool:
	return bool(room.started) and room.engine != null and int(room.engine.state.get("winner", -1)) >= 0

func _forfeited(room: Dictionary, index: int) -> bool:
	return bool(room.started) and room.engine != null and index >= 0 and index < room.engine.state.players.size() and bool(room.engine.state.players[index].get("forfeited", false))

func _paused(room: Dictionary) -> bool:
	if _finished(room): return false
	for i in range(room.players.size()):
		if int(room.players[i].peer) < 0 and not _forfeited(room, i):
			return true
	return false

func _reconnect_remaining(room: Dictionary) -> int:
	if not _paused(room): return 0
	var remaining := reconnect_grace_ms
	for i in range(room.players.size()):
		if int(room.players[i].peer) < 0 and not _forfeited(room, i):
			remaining = mini(remaining, maxi(0, int(room.players[i].get("reconnect_at", 0)) - Time.get_ticks_msec()))
	return remaining

func _leave(peer_id: int) -> void:
	var entry: Dictionary = peers[peer_id]
	var code := str(entry.room)
	if not rooms.has(code): return
	var room: Dictionary = rooms[code]
	var seat := int(entry.player)
	if bool(room.started):
		if not _finished(room) and not _forfeited(room, seat):
			room.engine.forfeit_player(seat, "abandon")
		_persist_rooms()
		# Queue the authoritative result for every current connection, including
		# the leaver, before detaching and beginning the close handshake.
		_broadcast_state(code)
		room.players[seat].peer = -1
		room.players[seat].reconnect_at = 0
		entry.room = ""
		entry.player = -1
		_broadcast_lobby(code)
	else:
		_remove_lobby_seat(code, seat)
	entry.leaving = true
	entry.close_at = Time.get_ticks_msec() + 150

func _remove_lobby_seat(code: String, seat: int) -> void:
	if not rooms.has(code): return
	var room: Dictionary = rooms[code]
	if seat < 0 or seat >= room.players.size(): return
	var removed_peer := int(room.players[seat].peer)
	if peers.has(removed_peer):
		peers[removed_peer].room = ""
		peers[removed_peer].player = -1
	room.players.remove_at(seat)
	if room.players.is_empty():
		rooms.erase(code)
		return
	for i in range(room.players.size()):
		var id := int(room.players[i].peer)
		if peers.has(id):
			peers[id].player = i
			_welcome(id, code, i, str(room.players[i].token))
	_touch(room)
	_broadcast_lobby(code)

func _disconnect(peer_id: int) -> void:
	if not peers.has(peer_id): return
	var entry: Dictionary = peers[peer_id]
	var code := str(entry.room)
	peers.erase(peer_id)
	if not rooms.has(code) or int(entry.player) < 0: return
	var room: Dictionary = rooms[code]
	var seat := int(entry.player)
	if seat >= room.players.size() or int(room.players[seat].peer) != peer_id: return
	if not bool(room.started):
		_remove_lobby_seat(code, seat)
		_persist_rooms()
		return
	room.players[seat].peer = -1
	room.players[seat].reconnect_at = Time.get_ticks_msec() + reconnect_grace_ms if not _forfeited(room, seat) and not _finished(room) else 0
	_touch(room)
	var has_connection := false
	for player: Dictionary in room.players:
		if int(player.peer) >= 0:
			has_connection = true
	if not has_connection:
		room.empty_since = Time.get_ticks_msec()
	_persist_rooms()
	_broadcast_lobby(code)
	_broadcast_state(code)

func _expire_players(code: String, now: int) -> bool:
	if not rooms.has(code): return false
	var room: Dictionary = rooms[code]
	if not bool(room.started) or _finished(room): return false
	var changed := false
	for i in range(room.players.size()):
		var deadline := int(room.players[i].get("reconnect_at", 0))
		if int(room.players[i].peer) < 0 and not _forfeited(room, i) and deadline > 0 and now >= deadline:
			var result: Dictionary = room.engine.forfeit_player(i, "déconnexion prolongée")
			if result.get("ok", false):
				room.players[i].reconnect_at = 0
				changed = true
	if changed:
		_touch(room)
		_persist_rooms()
		_broadcast_lobby(code)
		_broadcast_state(code)
	return changed

func _sweep(now: int) -> void:
	var changed := false
	for code: String in rooms.keys():
		if not rooms.has(code): continue
		var room: Dictionary = rooms[code]
		_expire_players(code, now)
		if (int(room.empty_since) > 0 and now - int(room.empty_since) > EMPTY_ROOM_TTL_MS) or now - int(room.activity) > ROOM_TTL_MS:
			for player: Dictionary in room.players:
				var id := int(player.peer)
				if id >= 0 and peers.has(id):
					_error(id, "Le salon a expiré.", true)
			rooms.erase(code)
			changed = true
	if changed: _persist_rooms()

func _touch(room: Dictionary) -> void:
	room.activity = Time.get_ticks_msec()
	room.activity_unix = int(Time.get_unix_time_from_system())

func _persist_rooms() -> bool:
	if state_file.is_empty(): return true
	var saved: Array = []
	for code: String in rooms:
		var room: Dictionary = rooms[code]
		if not bool(room.started): continue
		var players: Array = []
		for player: Dictionary in room.players:
			players.append({"name": str(player.name), "token": str(player.token)})
		saved.append({"code": code, "players": players, "game": room.engine.export_game(), "activity_unix": int(room.get("activity_unix", Time.get_unix_time_from_system()))})
	var directory := state_file.get_base_dir()
	if not directory.is_empty() and DirAccess.make_dir_recursive_absolute(directory) != OK:
		printerr("Cannot create room state directory.")
		return false
	var file := FileAccess.open(state_file + ".tmp", FileAccess.WRITE)
	if file == null:
		printerr("Cannot write room state file.")
		return false
	# Restrict the empty temporary file before any private hand or token is written.
	FileAccess.set_unix_permissions(state_file + ".tmp", 384)
	file.store_string(JSON.stringify({"version": 1, "rooms": saved}))
	file.flush()
	var error := file.get_error()
	file.close()
	if error != OK:
		printerr("Cannot flush room state file.")
		return false
	if FileAccess.file_exists(state_file):
		if _replace_invalid_primary:
			# Recovery used the backup: never rotate the corrupt primary over it.
			if DirAccess.remove_absolute(state_file) != OK: return false
		else:
			DirAccess.remove_absolute(state_file + ".bak")
			if DirAccess.rename_absolute(state_file, state_file + ".bak") != OK: return false
	var committed := DirAccess.rename_absolute(state_file + ".tmp", state_file) == OK
	if committed:
		_replace_invalid_primary = false
	return committed

func _restore_rooms() -> void:
	if state_file.is_empty(): return
	if not FileAccess.file_exists(state_file) and not FileAccess.file_exists(state_file + ".bak"): return
	for path in [state_file, state_file + ".bak"]:
		var file := FileAccess.open(path, FileAccess.READ)
		if file == null or file.get_length() > MAX_STATE_BYTES: continue
		var value: Variant = JSON.parse_string(file.get_as_text())
		file.close()
		if not value is Dictionary or value.get("version") != 1 or not value.get("rooms") is Array or value.rooms.size() > MAX_ROOMS: continue
		var restored: Dictionary = {}
		var valid := true
		var now := Time.get_ticks_msec()
		var wall_now := int(Time.get_unix_time_from_system())
		for item: Variant in value.rooms:
			if not item is Dictionary or not item.get("code") is String or not item.code.is_valid_int() or item.code.length() != 6 or restored.has(item.code) or not item.get("players") is Array or item.players.size() < 2 or item.players.size() > 4:
				valid = false
				break
			var engine := EngineScript.new()
			if not engine.restore_game(item.get("game", {})) or engine.state.players.size() != item.players.size():
				valid = false
				break
			var players: Array = []
			var tokens: Dictionary = {}
			for i in range(item.players.size()):
				var player: Variant = item.players[i]
				if not player is Dictionary or not player.get("name") is String or not player.get("token") is String or player.token.length() != 48 or not player.token.is_valid_hex_number(false) or tokens.has(player.token) or player.name != engine.state.players[i].name:
					valid = false
					break
				tokens[player.token] = true
				players.append({"name": player.name, "token": player.token, "peer": -1, "reconnect_at": now + reconnect_grace_ms})
			if not valid: break
			var raw_activity: Variant = item.get("activity_unix", 0)
			if not (raw_activity is int or raw_activity is float) or not is_finite(float(raw_activity)) or floor(float(raw_activity)) != float(raw_activity):
				valid = false
				break
			var activity_unix := int(raw_activity)
			if activity_unix <= 0 or activity_unix > wall_now + 300:
				valid = false
				break
			if wall_now - activity_unix > ROOM_TTL_MS / 1000: continue
			restored[item.code] = {"tri_cards":int(engine.state.get("tri_hand_size",0)), "players": players, "started": true, "engine": engine, "created": now, "activity": now, "activity_unix": activity_unix, "empty_since": now}
		if valid:
			rooms = restored
			_replace_invalid_primary = path != state_file
			return
	printerr("No valid room state file could be restored.")

func _send(peer_id: int, message: Dictionary) -> void:
	if peers.has(peer_id):
		var socket: WebSocketPeer = peers[peer_id].socket
		if socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
			socket.send_text(JSON.stringify(message))

func _error(peer_id: int, message: String, fatal: bool = false) -> void:
	_send(peer_id, {"type": "error", "message": message, "fatal": fatal})
	if fatal and peers.has(peer_id):
		var socket: WebSocketPeer = peers[peer_id].socket
		socket.close(1008, "Salon inaccessible")

func _new_token() -> String:
	return Crypto.new().generate_random_bytes(24).hex_encode()

func _clean_name(value: Variant) -> String:
	var text := str(value).strip_edges().replace("\n", " ").replace("\r", " ")
	return text.substr(0, 20) if not text.is_empty() else "Joueur"

func _finalize() -> void:
	for entry: Dictionary in peers.values():
		var socket: WebSocketPeer = entry.socket
		socket.close(1001, "Server stopping")
	server.stop()
