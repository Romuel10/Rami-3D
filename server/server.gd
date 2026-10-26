extends SceneTree
## Headless Internet server. Every socket has one authenticated seat.
## Run: godot --headless --path . --script server/server.gd -- --port=7357
const EngineScript = preload("res://scripts/rami_engine.gd")
const MAX_PACKET_BYTES := 32768
const MAX_CONNECTIONS := 256
const MAX_ROOMS := 64
const AUTH_TIMEOUT_MS := 8000
const EMPTY_ROOM_TTL_MS := 900000
const ROOM_TTL_MS := 86400000

var server := TCPServer.new()
var peers: Dictionary = {}
var rooms: Dictionary = {}
var next_id := 1
var port := 7357
var sweep_at := 0

func _initialize() -> void:
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--port="):
			port = argument.trim_prefix("--port=").to_int()
	if port < 1024 or port > 65535:
		printerr("Port must be between 1024 and 65535.")
		quit(2)
		return
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
			"deadline": Time.get_ticks_msec() + AUTH_TIMEOUT_MS, "last_action": -1000}
		next_id += 1
	for peer_id: int in peers.keys():
		if not peers.has(peer_id):
			continue
		var entry: Dictionary = peers[peer_id]
		var socket: WebSocketPeer = entry.socket
		socket.poll()
		var state: int = socket.get_ready_state()
		if state == WebSocketPeer.STATE_OPEN:
			var count := 0
			while socket.get_available_packet_count() > 0 and count < 24:
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
		if state == WebSocketPeer.STATE_CLOSED:
			_disconnect(peer_id)
		elif int(entry.player) < 0 and Time.get_ticks_msec() > int(entry.deadline):
			socket.close(1008, "Authentication required")
	var now: int = Time.get_ticks_msec()
	if now > sweep_at:
		sweep_at = now + 10000
		_sweep(now)
	return false

func _message(peer_id: int, message: Dictionary) -> void:
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
	room.activity = Time.get_ticks_msec()
	if kind == "start":
		if int(entry.player) != 0:
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
			room.engine.start_game(names)
			room.started = true
			_broadcast_lobby(code)
			_broadcast_state(code)
	elif kind == "action":
		if not bool(room.started):
			_error(peer_id, "La partie n’a pas encore commencé.")
			return
		if _paused(room):
			_error(peer_id, "La partie attend la reconnexion d’un joueur.")
			return
		var action: Variant = message.get("action")
		if not action is Dictionary:
			_error(peer_id, "Action incorrecte.")
			return
		var now: int = Time.get_ticks_msec()
		if now - int(entry.last_action) < 40:
			_error(peer_id, "Attendez un instant avant votre prochaine action.")
			return
		entry.last_action = now
		var result: Dictionary = room.engine.apply_action(int(entry.player), action)
		if bool(result.get("ok", false)):
			_broadcast_state(code)
		else:
			_error(peer_id, str(result.get("error", "Action impossible.")))
	else:
		_error(peer_id, "Message inconnu.")

func _create_room(peer_id: int, message: Dictionary) -> void:
	if rooms.size() >= MAX_ROOMS:
		_error(peer_id, "Le serveur est complet. Réessayez plus tard.", true)
		return
	var code := "%06d" % randi_range(0, 999999)
	while rooms.has(code):
		code = "%06d" % randi_range(0, 999999)
	var token := _new_token()
	var now: int = Time.get_ticks_msec()
	rooms[code] = {"players": [{"name": _clean_name(message.get("name", "Joueur")),
		"token": token, "peer": peer_id}], "started": false, "engine": null,
		"created": now, "activity": now, "empty_since": 0}
	peers[peer_id].room = code
	peers[peer_id].player = 0
	_welcome(peer_id, code, 0, token)
	_broadcast_lobby(code)

func _join_room(peer_id: int, message: Dictionary) -> void:
	var code := str(message.get("code", ""))
	if code.length() != 6 or not rooms.has(code):
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
		if int(room.players[seat].peer) >= 0:
			_error(peer_id, "Ce joueur est déjà connecté.", true)
			return
	else:
		if bool(room.started):
			_error(peer_id, "Cette partie a déjà commencé.", true)
			return
		if room.players.size() >= 4:
			_error(peer_id, "Le salon est complet.", true)
			return
		seat = room.players.size()
		token = _new_token()
		room.players.append({"name": _clean_name(message.get("name", "Joueur")),
			"token": token, "peer": peer_id})
	room.players[seat].peer = peer_id
	room.activity = Time.get_ticks_msec()
	room.empty_since = 0
	peers[peer_id].room = code
	peers[peer_id].player = seat
	_welcome(peer_id, code, seat, token)
	_broadcast_lobby(code)
	if bool(room.started):
		_broadcast_state(code)

func _welcome(peer_id: int, code: String, seat: int, token: String) -> void:
	_send(peer_id, {"type": "welcome", "player": seat, "code": code,
		"token": token, "is_host": seat == 0})

func _broadcast_lobby(code: String) -> void:
	var room: Dictionary = rooms[code]
	var summaries: Array = []
	for player: Dictionary in room.players:
		summaries.append({"name": player.name, "connected": int(player.peer) >= 0})
	for seat: int in range(room.players.size()):
		var id := int(room.players[seat].peer)
		if id >= 0:
			_send(id, {"type": "lobby", "data": {"code": code,
				"players": summaries, "port": port, "started": room.started,
				"host": seat == 0, "your_index": seat}})

func _broadcast_state(code: String) -> void:
	var room: Dictionary = rooms[code]
	var paused := _paused(room)
	for seat: int in range(room.players.size()):
		var id := int(room.players[seat].peer)
		if id >= 0:
			var view: Dictionary = room.engine.view_for(seat)
			view.paused = paused
			view.your_index = seat
			view.online = true
			_send(id, {"type": "state", "data": view})

func _paused(room: Dictionary) -> bool:
	for player: Dictionary in room.players:
		if int(player.peer) < 0:
			return true
	return false

func _disconnect(peer_id: int) -> void:
	if not peers.has(peer_id):
		return
	var entry: Dictionary = peers[peer_id]
	var code := str(entry.room)
	peers.erase(peer_id)
	if not rooms.has(code) or int(entry.player) < 0:
		return
	var room: Dictionary = rooms[code]
	var seat := int(entry.player)
	if seat < room.players.size() and int(room.players[seat].peer) == peer_id:
		room.players[seat].peer = -1
	room.activity = Time.get_ticks_msec()
	var has_connection := false
	for player: Dictionary in room.players:
		if int(player.peer) >= 0:
			has_connection = true
	if not has_connection:
		room.empty_since = Time.get_ticks_msec()
	_broadcast_lobby(code)
	if bool(room.started):
		_broadcast_state(code)

func _sweep(now: int) -> void:
	for code: String in rooms.keys():
		var room: Dictionary = rooms[code]
		if (int(room.empty_since) > 0 and now - int(room.empty_since) > EMPTY_ROOM_TTL_MS) or now - int(room.activity) > ROOM_TTL_MS:
			for player: Dictionary in room.players:
				var id := int(player.peer)
				if id >= 0 and peers.has(id):
					_error(id, "Le salon a expiré.", true)
			rooms.erase(code)

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
	if text.is_empty():
		text = "Joueur"
	return text.substr(0, 20)

func _finalize() -> void:
	for entry: Dictionary in peers.values():
		var socket: WebSocketPeer = entry.socket
		socket.close(1001, "Server stopping")
	server.stop()
