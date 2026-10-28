class_name RamiNetwork
extends Node
## Authoritative WebSocket room. The hosting telephone is player zero.
## A persistent session token lets a dropped client recover its own seat only.

signal lobby_updated(data: Dictionary)
signal game_updated(view: Dictionary)
signal notice(message: String)
signal connection_changed(connected: bool)

const PORT := 7357
const MAX_PLAYERS := 4
const MAX_PACKET_BYTES := 32768
const AUTH_TIMEOUT_MS := 8000
const RECONNECT_DELAY_MS := 1800
const RECONNECT_GRACE_MS := 60000
const SESSION_TTL_SECONDS := 86400
const SESSION_FILE := "user://network-session.save"
const LEAVE_FLUSH_MS := 250
const EngineScript = preload("res://scripts/rami_engine.gd")

var room_code: String = ""
var local_player: int = -1
var is_host: bool = false
var local_address: String = ""
var server_port: int = PORT
var match_started: bool = false
var connected: bool = false
var reconnect_grace_ms: int = RECONNECT_GRACE_MS
var session_path: String = SESSION_FILE
var _match_finished: bool = false
var _leaving: bool = false
var _draining: Array = []

var _hosting_locally: bool = false
var _client_mode: String = "join"
var _server: TCPServer
var _peers: Dictionary = {}
var _next_peer: int = 1
var _players: Array = []
var _engine: RefCounted
var _client: WebSocketPeer
var _client_url: String = ""
var _client_name: String = ""
var _session_token: String = ""
var _auth_sent: bool = false
var _wants_connection: bool = false
var _retry_at: int = 0
var _last_client_state: int = WebSocketPeer.STATE_CLOSED
var _last_action_at: Dictionary = {}
var _known_lobby: Dictionary = {}

func _ready() -> void:
	set_process(true)

func host_room(player_name: String, port: int = PORT) -> bool:
	leave_room()
	if port < 1024 or port > 65535:
		notice.emit("Choisissez un port compris entre 1024 et 65535.")
		return false
	_server = TCPServer.new()
	var error: int = _server.listen(port, "0.0.0.0")
	if error != OK:
		_server = null
		notice.emit("Impossible d’ouvrir le salon. Le port est peut-être déjà utilisé.")
		return false
	is_host = true
	_hosting_locally = true
	connected = true
	local_player = 0
	server_port = port
	room_code = "%06d" % randi_range(0, 999999)
	local_address = _lan_address()
	_players = [{"name": _clean_name(player_name), "connected": true, "token": _new_token(), "forfeited": false, "disconnect_at": 0}]
	connection_changed.emit(true)
	_broadcast_lobby()
	return true

func join_room(address: String, player_name: String, code: String = "") -> bool:
	leave_room()
	var url := _normalise_address(address)
	if url.is_empty():
		notice.emit("Indiquez l’adresse IP de l’hôte, par exemple 192.168.1.20.")
		return false
	if code.length() != 6 or not code.is_valid_int():
		notice.emit("Saisissez le code de salon à six chiffres.")
		return false
	room_code = code
	_client_url = url
	_client_name = _clean_name(player_name)
	_wants_connection = true
	local_address = address.strip_edges()
	return _connect_client()

func create_remote_room(address: String, player_name: String) -> bool:
	leave_room()
	var url := _normalise_address(address)
	if url.is_empty():
		notice.emit("Indiquez l’adresse du serveur Internet.")
		return false
	_client_mode = "create"
	_client_url = url
	_client_name = _clean_name(player_name)
	_wants_connection = true
	local_address = address.strip_edges()
	return _connect_client()

func start_match() -> bool:
	if not is_host:
		notice.emit("Seul l’hôte peut lancer la partie.")
		return false
	if match_started:
		notice.emit("La partie a déjà commencé.")
		return false
	if not _hosting_locally:
		if connected and _client != null:
			_send(_client, {"type": "start"})
			return true
		return false
	if _players.size() < 2:
		notice.emit("Il faut au moins deux joueurs pour commencer.")
		return false
	if _has_missing_players():
		notice.emit("Attendez que tous les joueurs soient reconnectés.")
		return false
	_engine = EngineScript.new()
	var names: Array = []
	for player: Dictionary in _players:
		names.append(player.name)
	_engine.start_game(names)
	match_started = true
	_broadcast_lobby()
	_broadcast_game()
	return true

func send_action(action: Dictionary) -> void:
	if _hosting_locally:
		_apply_action(0, action)
	elif connected and _client != null and _client.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_send(_client, {"type": "action", "action": action})
	else:
		notice.emit("La connexion au salon est interrompue.")

func reconnect() -> bool:
	if _hosting_locally:
		return connected
	if connected:
		return true
	if _client_url.is_empty() or (room_code.is_empty() and _client_mode != "create"):
		notice.emit("Aucun salon à reconnecter. Rejoignez ou créez un salon.")
		return false
	_wants_connection = true
	if _client != null:
		var state := _client.get_ready_state()
		if state == WebSocketPeer.STATE_CONNECTING or state == WebSocketPeer.STATE_OPEN:
			return true
		_client.close(1000, "Reconnexion")
		_client = null
	_retry_at = 0
	return _connect_client()

func leave_room() -> void:
	# A menu departure is an authenticated abandon, unlike losing transport.
	_leaving = true
	_wants_connection = false
	forget_session()
	if _hosting_locally and match_started and _engine != null and int(_engine.state.get("winner", -1)) < 0:
		# This telephone owns the Wi-Fi server. Closing it ends the table and
		# declares the other active players winners before sockets are closed.
		_engine.forfeit_player(0, "hote_abandon", true)
		_players[0].forfeited = true
		_broadcast_game()
	elif _client != null and _client.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_send(_client, {"type": "leave"})
		_client.poll()
	# Keep old sockets alive for a bounded flush. A new connection uses distinct
	# objects, so completion of this drain cannot close a replacement room.
	_drain_current()
	_clear_current(true)
	_leaving = false

func has_saved_session() -> bool:
	return not _read_session().is_empty()

func resume_session() -> bool:
	if connected:
		return true
	var saved := _read_session()
	if saved.is_empty():
		notice.emit("Aucune session multijoueur à reprendre.")
		return false
	_reset_transport(false)
	_client_url = str(saved.url)
	_client_name = str(saved.name)
	room_code = str(saved.code)
	_session_token = str(saved.token)
	local_player = int(saved.player)
	local_address = _client_url
	_client_mode = "join"
	_wants_connection = true
	_match_finished = false
	return _connect_client()

func forget_session() -> void:
	if FileAccess.file_exists(session_path):
		DirAccess.remove_absolute(session_path)
	if FileAccess.file_exists(session_path + ".tmp"):
		DirAccess.remove_absolute(session_path + ".tmp")

func _read_session() -> Dictionary:
	var file := FileAccess.open(session_path, FileAccess.READ)
	if file == null:
		return {}
	if file.get_length() > 8192:
		return {}
	var text := file.get_as_text()
	file.close()
	var parser := JSON.new()
	if parser.parse(text) != OK:
		return {}
	var value: Variant = parser.data
	if not value is Dictionary or value.get("version") != 1:
		return {}
	for field in ["url", "name", "code", "token"]:
		if not value.get(field) is String:
			return {}
	var url: String = value.url
	if url.length() > 512 or not (url.begins_with("ws://") or url.begins_with("wss://")) or _normalise_address(url) != url:
		return {}
	for character in url:
		if character.unicode_at(0) <= 32:
			return {}
	if value.name.is_empty() or value.name.length() > 20 or value.code.length() != 6 or not value.code.is_valid_int() or value.token.length() != 48:
		return {}
	for digit in value.token:
		if not digit in "0123456789abcdef":
			return {}
	for field in ["player", "updated_at"]:
		var number: Variant = value.get(field)
		if not (number is int or number is float) or not is_finite(float(number)) or floor(float(number)) != float(number):
			return {}
	if int(value.player) < 0 or int(value.player) > 3:
		return {}
	value.player = int(value.player)
	value.updated_at = int(value.updated_at)
	var age := int(Time.get_unix_time_from_system()) - int(value.updated_at)
	if age < -300 or age > SESSION_TTL_SECONDS:
		return {}
	return value

func _persist_session() -> void:
	if _hosting_locally or _match_finished or _session_token.is_empty() or _client_url.is_empty() or room_code.length() != 6 or local_player < 0:
		return
	var saved := {"version": 1, "url": _client_url, "name": _client_name, "code": room_code, "token": _session_token, "player": local_player, "updated_at": int(Time.get_unix_time_from_system())}
	var file := FileAccess.open(session_path + ".tmp", FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify(saved))
	file.flush()
	var result := file.get_error()
	file.close()
	if result == OK:
		DirAccess.rename_absolute(session_path + ".tmp", session_path)

func _clear_current(emit_change: bool) -> void:
	var was_connected := connected
	is_host = false
	_hosting_locally = false
	_client_mode = "join"
	connected = false
	local_player = -1
	room_code = ""
	local_address = ""
	match_started = false
	_match_finished = false
	_engine = null
	_players.clear()
	_session_token = ""
	_client_url = ""
	_client_name = ""
	_auth_sent = false
	_known_lobby.clear()
	_last_action_at.clear()
	if emit_change and was_connected:
		connection_changed.emit(false)

func _drain_current() -> void:
	var sockets: Array = []
	if _client != null:
		sockets.append(_client)
		_client = null
	for entry: Dictionary in _peers.values():
		sockets.append(entry.peer)
	_peers.clear()
	if _server != null:
		_server.stop()
		_server = null
	if not sockets.is_empty():
		_draining.append({"sockets": sockets, "until": Time.get_ticks_msec() + LEAVE_FLUSH_MS})

func _poll_draining() -> void:
	for i in range(_draining.size()-1, -1, -1):
		var entry: Dictionary = _draining[i]
		for peer: WebSocketPeer in entry.sockets:
			peer.poll()
		if Time.get_ticks_msec() >= int(entry.until):
			for peer: WebSocketPeer in entry.sockets:
				peer.close(1000, "Départ du salon")
				peer.poll()
			_draining.remove_at(i)

func _reset_transport(emit_change: bool) -> void:
	_wants_connection = false
	if _client != null:
		_client.close(1001, "Connexion interrompue")
		_client.poll()
		_client = null
	for entry: Dictionary in _peers.values():
		var peer: WebSocketPeer = entry.peer
		peer.close(1001, "Connexion interrompue")
		peer.poll()
	_peers.clear()
	if _server != null:
		_server.stop()
		_server = null
	_clear_current(emit_change)

func get_lobby() -> Dictionary:
	return _known_lobby.duplicate(true)

func _process(_delta: float) -> void:
	_poll_draining()
	if _hosting_locally:
		_poll_server()
		_expire_disconnected()
	elif _wants_connection:
		_poll_client()

func _exit_tree() -> void:
	# App destruction is transport loss: keep the authenticated session on disk.
	_reset_transport(false)
	for entry: Dictionary in _draining:
		for peer: WebSocketPeer in entry.sockets:
			peer.close(1000, "Départ du salon")
			peer.poll()
	_draining.clear()

func _poll_server() -> void:
	while _server.is_connection_available():
		var stream := _server.take_connection()
		if _peers.size() >= 12:
			stream.disconnect_from_host()
			continue
		var peer := WebSocketPeer.new()
		peer.inbound_buffer_size = MAX_PACKET_BYTES
		peer.outbound_buffer_size = 262144
		var error := peer.accept_stream(stream)
		if error != OK:
			stream.disconnect_from_host()
			continue
		_peers[_next_peer] = {"peer": peer, "player": -1, "deadline": Time.get_ticks_msec() + AUTH_TIMEOUT_MS}
		_next_peer += 1
	for peer_id: int in _peers.keys():
		if not _peers.has(peer_id):
			continue
		var entry: Dictionary = _peers[peer_id]
		var peer: WebSocketPeer = entry.peer
		peer.poll()
		var state := peer.get_ready_state()
		if state == WebSocketPeer.STATE_OPEN:
			while peer.get_available_packet_count() > 0:
				var packet := peer.get_packet()
				if packet.size() > MAX_PACKET_BYTES:
					peer.close(1009, "Paquet trop volumineux")
					break
				var value: Variant = JSON.parse_string(packet.get_string_from_utf8())
				if value is Dictionary:
					_server_message(peer_id, value)
					if not _peers.has(peer_id):
						break
				else:
					peer.close(1007, "Message incorrect")
					break
		if state == WebSocketPeer.STATE_CLOSED:
			_remove_peer(peer_id)
		elif int(entry.player) < 0 and Time.get_ticks_msec() > int(entry.deadline):
			peer.close(1008, "Authentification requise")

func _server_message(peer_id: int, message: Dictionary) -> void:
	if not _peers.has(peer_id):
		return
	var entry: Dictionary = _peers[peer_id]
	var peer: WebSocketPeer = entry.peer
	var kind: String = str(message.get("type", ""))
	if int(entry.player) < 0:
		if kind != "join":
			return
		_accept_join(peer_id, message)
		return
	if kind == "leave":
		_remove_peer(peer_id, true)
		return
	if kind == "action":
		var action: Variant = message.get("action")
		if not action is Dictionary:
			return
		var now := Time.get_ticks_msec()
		var previous: int = int(_last_action_at.get(peer_id, 0))
		if now - previous < 80:
			return
		_last_action_at[peer_id] = now
		_apply_action(int(entry.player), action, peer)

func _accept_join(peer_id: int, message: Dictionary) -> void:
	var entry: Dictionary = _peers[peer_id]
	var peer: WebSocketPeer = entry.peer
	if str(message.get("code", "")) != room_code:
		_reject(peer, "Le code du salon est incorrect.")
		return
	var token: String = str(message.get("token", ""))
	var seat := -1
	if not token.is_empty():
		for index in range(1, _players.size()):
			if _players[index].token == token:
				seat = index
				break
		if seat < 0:
			_reject(peer, "La session a expiré. Rejoignez à nouveau le salon.")
			return
		if bool(_players[seat].get("forfeited", false)):
			if _engine != null:
				_send(peer, {"type":"state", "data":_snapshot_for(seat)})
			_reject(peer, "Cette place a perdu par abandon.")
			return
		if bool(_players[seat].connected):
			_reject(peer, "Cette place est déjà connectée.")
			return
	else:
		if match_started:
			_reject(peer, "La partie a commencé. Seuls les joueurs de cette partie peuvent se reconnecter.")
			return
		if _players.size() >= MAX_PLAYERS:
			_reject(peer, "Ce salon est complet (quatre joueurs maximum).")
			return
		seat = _players.size()
		_players.append({"name": _clean_name(str(message.get("name", "Joueur"))), "connected": true, "token": _new_token(), "forfeited": false, "disconnect_at": 0})
	_players[seat].connected = true
	_players[seat].disconnect_at = 0
	entry.player = seat
	_peers[peer_id] = entry
	_send(peer, {"type": "welcome", "player": seat, "token": _players[seat].token, "code": room_code, "is_host": false})
	_broadcast_lobby()
	if match_started:
		_broadcast_game()

func _reject(peer: WebSocketPeer, message: String) -> void:
	_send(peer, {"type": "error", "message": message, "fatal": true})
	# Keep the socket open long enough to deliver the error. The client closes it.

func _remove_peer(peer_id: int, voluntary: bool = false) -> void:
	if not _peers.has(peer_id):
		return
	var entry: Dictionary = _peers[peer_id]
	var index: int = int(entry.player)
	if index >= 1 and index < _players.size():
		if match_started:
			_players[index].connected = false
			if voluntary:
				_forfeit_seat(index, "abandon")
			else:
				_players[index].disconnect_at = Time.get_ticks_msec() + reconnect_grace_ms
				notice.emit("%s s’est déconnecté. Reconnexion possible pendant %d secondes." % [_players[index].name, ceili(reconnect_grace_ms/1000.0)])
		else:
			# Lobby seats are not permanent: a missing guest must not block start.
			_players.remove_at(index)
			for other_id: int in _peers.keys():
				if other_id == peer_id:
					continue
				var other: Dictionary = _peers[other_id]
				if int(other.player) > index:
					other.player = int(other.player) - 1
					var seat := int(other.player)
					_send(other.peer, {"type":"welcome", "player":seat, "token":_players[seat].token, "code":room_code, "is_host":false})
	_peers.erase(peer_id)
	_last_action_at.erase(peer_id)
	if voluntary:
		var peer: WebSocketPeer = entry.peer
		_draining.append({"sockets":[peer], "until":Time.get_ticks_msec()+LEAVE_FLUSH_MS})
	_broadcast_lobby()
	if match_started:
		_broadcast_game()

func _forfeit_seat(index: int, reason: String) -> void:
	if _engine == null or int(_engine.state.get("winner", -1)) >= 0 or bool(_players[index].get("forfeited", false)):
		return
	var result: Dictionary = _engine.forfeit_player(index, reason)
	if result.get("ok", false):
		_players[index].forfeited = true
		_players[index].disconnect_at = 0
		notice.emit("%s a perdu par abandon." % _players[index].name)

func _expire_disconnected() -> void:
	if not match_started or _engine == null or int(_engine.state.get("winner", -1)) >= 0:
		return
	var changed := false
	var now := Time.get_ticks_msec()
	for index in range(1, _players.size()):
		var player: Dictionary = _players[index]
		if not bool(player.connected) and not bool(player.get("forfeited", false)) and int(player.get("disconnect_at", 0)) > 0 and now >= int(player.disconnect_at):
			_forfeit_seat(index, "déconnexion")
			changed = true
	if changed:
		_broadcast_lobby()
		_broadcast_game()

func _apply_action(player: int, action: Dictionary, reply_peer: WebSocketPeer = null) -> void:
	var error := ""
	if not match_started or _engine == null:
		error = "La partie n’a pas encore commencé."
	elif _has_missing_players():
		error = "Partie en pause : un joueur doit se reconnecter."
	else:
		var result: Dictionary = _engine.apply_action(player, action)
		if not bool(result.get("ok", false)):
			error = str(result.get("error", "Action impossible."))
	if not error.is_empty():
		if reply_peer != null:
			_send(reply_peer, {"type": "error", "message": error})
		else:
			notice.emit(error)
		return
	_broadcast_game()

func _broadcast_lobby() -> void:
	var players: Array = []
	for player: Dictionary in _players:
		players.append({"name": player.name, "connected": player.connected, "forfeited": player.get("forfeited", false)})
	var lobby := {"code": room_code, "players": players, "address": local_address, "port": server_port, "started": match_started, "host": true, "your_index": 0}
	_known_lobby = lobby
	lobby_updated.emit(lobby)
	for entry: Dictionary in _peers.values():
		if int(entry.player) >= 1:
			var remote_lobby: Dictionary = lobby.duplicate(true)
			remote_lobby.host = false
			remote_lobby.your_index = int(entry.player)
			_send(entry.peer, {"type": "lobby", "data": remote_lobby})

func _broadcast_game() -> void:
	if _engine == null:
		return
	var mine: Dictionary = _snapshot_for(0)
	if not _leaving:
		game_updated.emit(mine)
	for entry: Dictionary in _peers.values():
		if int(entry.player) >= 1:
			_send(entry.peer, {"type": "state", "data": _snapshot_for(int(entry.player))})

func _snapshot_for(index: int) -> Dictionary:
	var snapshot: Dictionary = _engine.view_for(index)
	snapshot["paused"] = _has_missing_players()
	snapshot["your_index"] = index
	snapshot["online"] = true
	var remaining := 0
	if snapshot["paused"]:
		for player: Dictionary in _players:
			if not bool(player.connected) and not bool(player.get("forfeited", false)):
				var until := maxi(0, int(player.get("disconnect_at", 0)) - Time.get_ticks_msec())
				remaining = until if remaining == 0 else mini(remaining, until)
	snapshot["reconnect_remaining_ms"] = remaining
	return snapshot

func _has_missing_players() -> bool:
	if _engine != null and int(_engine.state.get("winner", -1)) >= 0:
		return false
	for player: Dictionary in _players:
		if not bool(player.connected) and not bool(player.get("forfeited", false)):
			return true
	return false

func _connect_client() -> bool:
	_client = WebSocketPeer.new()
	_client.inbound_buffer_size = 262144
	_client.outbound_buffer_size = MAX_PACKET_BYTES
	_auth_sent = false
	_last_client_state = WebSocketPeer.STATE_CONNECTING
	var error := _client.connect_to_url(_client_url)
	if error != OK:
		_client = null
		_retry_at = Time.get_ticks_msec() + RECONNECT_DELAY_MS
		notice.emit("Connexion impossible. Vérifiez l’adresse et le réseau Wi-Fi.")
		return false
	return true

func _poll_client() -> void:
	if _client == null:
		if Time.get_ticks_msec() >= _retry_at:
			_connect_client()
		return
	_client.poll()
	var state := _client.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN:
		if not _auth_sent:
			if _client_mode == "create":
				_send(_client, {"type": "create", "name": _client_name})
			else:
				_send(_client, {"type": "join", "name": _client_name, "code": room_code, "token": _session_token})
			_auth_sent = true
		while _client != null and _client.get_available_packet_count() > 0:
			var packet := _client.get_packet()
			if packet.size() > 262144:
				continue
			var value: Variant = JSON.parse_string(packet.get_string_from_utf8())
			if value is Dictionary:
				_client_message(value)
	elif state == WebSocketPeer.STATE_CLOSED:
		_client = null
		if connected and not _match_finished:
			connected = false
			connection_changed.emit(false)
			notice.emit("Connexion interrompue. Reconnexion en cours…")
		if _match_finished:
			connected = false
			_wants_connection = false
		else:
			_retry_at = Time.get_ticks_msec() + RECONNECT_DELAY_MS
	_last_client_state = state

func _client_message(message: Dictionary) -> void:
	var kind: String = str(message.get("type", ""))
	match kind:
		"welcome":
			local_player = int(message.get("player", -1))
			_session_token = str(message.get("token", ""))
			room_code = str(message.get("code", room_code))
			is_host = bool(message.get("is_host", false))
			_client_mode = "join"
			connected = true
			_match_finished = false
			_persist_session()
			connection_changed.emit(true)
		"lobby":
			var data: Variant = message.get("data")
			if data is Dictionary:
				_known_lobby = data
				is_host = bool(data.get("host", is_host))
				match_started = bool(data.get("started", false))
				local_player = int(data.get("your_index", local_player))
				_persist_session()
				lobby_updated.emit(data)
		"state", "game":
			var data: Variant = message.get("data")
			if data is Dictionary:
				match_started = true
				var summaries: Array = data.get("players", [])
				var own_forfeit: bool = local_player >= 0 and local_player < summaries.size() and bool(summaries[local_player].get("forfeited", false))
				_match_finished = int(data.get("winner", -1)) >= 0 or own_forfeit
				if _match_finished:
					forget_session()
				else:
					_persist_session()
				game_updated.emit(data)
		"error":
			notice.emit(str(message.get("message", "Connexion impossible.")))
			if bool(message.get("fatal", false)):
				_wants_connection = false
				forget_session()
				if _client != null:
					_client.close(1000, "Connexion refusée")
				connected = false
				if not _match_finished:
					connection_changed.emit(false)

func _send(peer: WebSocketPeer, message: Dictionary) -> void:
	if peer != null and peer.get_ready_state() == WebSocketPeer.STATE_OPEN:
		peer.send_text(JSON.stringify(message))

func _new_token() -> String:
	return Crypto.new().generate_random_bytes(24).hex_encode()

func _clean_name(value: String) -> String:
	var name_text := value.strip_edges().left(20)
	if name_text.is_empty():
		return "Joueur"
	return name_text.replace("\n", " ").replace("\r", " ").replace("\t", " ")

func _normalise_address(value: String) -> String:
	var address := value.strip_edges()
	if address.is_empty() or address.contains(" "):
		return ""
	var explicit_scheme := address.begins_with("ws://") or address.begins_with("wss://")
	if not explicit_scheme:
		address = "ws://" + address
	var scheme_end := address.find("://") + 3
	var host_part := address.substr(scheme_end).get_slice("/", 0)
	if host_part.is_empty():
		return ""
	if not explicit_scheme and not host_part.contains(":"):
		var slash := address.find("/", scheme_end)
		if slash < 0:
			address += ":" + str(PORT)
		else:
			address = address.insert(slash, ":" + str(PORT))
	return address

func _lan_address() -> String:
	var fallback := "127.0.0.1"
	for address: String in IP.get_local_addresses():
		if address.contains(":") or address.begins_with("127.") or address.begins_with("169.254."):
			continue
		if address.begins_with("192.168.") or address.begins_with("10.") or address.begins_with("172."):
			return address
		fallback = address
	return fallback
