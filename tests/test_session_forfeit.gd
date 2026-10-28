extends SceneTree
## Real WebSocket regression for lobby departures, forfeit and app restart.
const Network = preload("res://scripts/network_manager.gd")
var failures := 0
var checks := 0
var views: Dictionary = {}
var events: Dictionary = {}
var nodes: Array = []
var counter := 0

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("FAIL: " + message)

func _wait(predicate: Callable, limit: int = 2500) -> void:
	var until := Time.get_ticks_msec() + limit
	while not predicate.call() and Time.get_ticks_msec() < until:
		await create_timer(0.01).timeout

func _node(label: String, path: String = "") -> Node:
	var node = Network.new()
	counter += 1
	node.session_path = path if not path.is_empty() else "user://test-session-%s-%d.save" % [label, counter]
	node.forget_session() if path.is_empty() else null
	nodes.append(node)
	views[label] = {}
	events[label] = []
	node.game_updated.connect(func(view: Dictionary): views[label] = view; events[label].append("win" if int(view.get("winner", -1)) >= 0 else "state"))
	node.connection_changed.connect(func(value: bool): events[label].append("connected" if value else "disconnected"))
	root.add_child(node)
	return node

func _setup(count: int, port: int) -> Array:
	var host := _node("host")
	_check(host.host_room("Hôte", port), "host opens fixture room")
	var players: Array = [host]
	for i in range(1, count):
		var guest := _node("guest%d" % i)
		_check(guest.join_room("127.0.0.1:%d" % port, "Ami%d" % i, host.room_code), "guest starts authentication")
		await _wait(func(): return guest.connected)
		_check(guest.connected and guest.local_player == i, "guest receives authenticated seat")
		players.append(guest)
	return players

func _start(host: Node) -> void:
	_check(host.start_match(), "fixture match starts")
	await _wait(func(): return not views.host.is_empty())
	await create_timer(0.04).timeout

func _cleanup() -> void:
	for node in nodes:
		if is_instance_valid(node):
			node._reset_transport(false)
			node.forget_session()
			node.queue_free()
	nodes.clear()
	await process_frame

func _run() -> void:
	await _lobby_replacement()
	await _guest_abandons()
	await _host_abandons()
	await _restart_recovers_session()
	await _timeout_is_defeat()
	await _three_player_elimination()
	await _host_closes_three_players()
	await _invalid_sessions()
	await _dedicated_restart_and_leave()
	print("SESSION/FORFEIT: %d checks; %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)

func _lobby_replacement() -> void:
	var players := await _setup(3, 17401)
	var host: Node = players[0]
	var departing: Node = players[1]
	var other: Node = players[2]
	departing.leave_room()
	await _wait(func(): return host._players.size() == 2 and other.local_player == 1)
	_check(host._players.size() == 2 and other.local_player == 1, "lobby leave removes ghost and reindexes remaining guest")
	var replacement := _node("replacement")
	replacement.join_room("127.0.0.1:17401", "Nouveau", host.room_code)
	await _wait(func(): return replacement.connected)
	_check(replacement.connected and replacement.local_player == 2, "replacement uses available contiguous seat")
	_check(host.start_match(), "departed lobby guest never prevents start")
	await _wait(func(): return not views.replacement.is_empty())
	_check(views.replacement.get("players", []).size() == 3, "started roster contains only current players")
	await _cleanup()

func _guest_abandons() -> void:
	var players := await _setup(2, 17402)
	var host: Node = players[0]
	var guest: Node = players[1]
	await _start(host)
	_check(guest.has_saved_session(), "authenticated session is saved for restart")
	guest.leave_room()
	await _wait(func(): return int(views.host.get("winner", -1)) == 0)
	_check(int(views.host.get("winner", -1)) == 0, "guest voluntary leave immediately awards host victory")
	_check(not bool(views.host.get("paused", true)), "finished forfeit result is never paused")
	_check(bool(views.host.get("players", [{},{}])[1].get("forfeited", false)), "departing guest is marked forfeited")
	_check(not guest.has_saved_session(), "voluntary departure clears recovery token")
	_check(bool(views.host.get("win_by_forfeit", false)), "opponent sees explicit forfeit outcome")
	await _cleanup()

func _host_abandons() -> void:
	var players := await _setup(2, 17403)
	var host: Node = players[0]
	await _start(host)
	events.guest1.clear()
	host.leave_room()
	await _wait(func(): return int(views.guest1.get("winner", -1)) == 1)
	_check(int(views.guest1.get("winner", -1)) == 1, "Wi-Fi host flushes guest victory before closing")
	await create_timer(0.4).timeout
	_check(not events.guest1.has("disconnected"), "terminal winner view is not replaced by disconnect event")
	_check(not bool(views.guest1.get("paused", true)), "host-abandon winner snapshot is playable-result state")
	await _cleanup()

func _restart_recovers_session() -> void:
	var players := await _setup(2, 17404)
	var host: Node = players[0]
	var guest: Node = players[1]
	await _start(host)
	var previous: Array = views.guest1.hand.duplicate()
	var token: String = guest._session_token
	var path: String = guest.session_path
	guest.queue_free()
	await process_frame
	await _wait(func(): return bool(views.host.get("paused", false)))
	_check(bool(views.host.get("paused", false)), "unexpected app destruction pauses during grace")
	var restored := _node("restored", path)
	_check(restored.has_saved_session(), "fresh application sees saved authenticated session")
	_check(restored.resume_session(), "fresh application attempts saved session")
	await _wait(func(): return restored.connected and not bool(views.host.get("paused", true)))
	_check(restored.connected and restored.local_player == 1 and restored._session_token == token, "restart recovers same authenticated seat")
	_check(views.restored.get("hand", []) == previous, "restart preserves exact private hand")
	_check(not JSON.stringify(host.get_lobby()).contains(token) and not JSON.stringify(views.host).contains(token), "session token is absent from shared lobby and snapshots")
	_check(not bool(views.host.get("paused", true)), "recovery resumes authoritative match")
	await _cleanup()

func _timeout_is_defeat() -> void:
	var players := await _setup(2, 17405)
	var host: Node = players[0]
	var guest: Node = players[1]
	host.reconnect_grace_ms = 80
	await _start(host)
	guest._reset_transport(false)
	await _wait(func(): return int(views.host.get("winner", -1)) == 0)
	_check(int(views.host.get("winner", -1)) == 0 and not bool(views.host.get("paused", true)), "expired reconnect grace awards opponent victory")
	_check(guest.has_saved_session(), "offline client keeps session until server tells final outcome")
	guest.resume_session()
	await _wait(func(): return int(views.guest1.get("winner", -1)) == 0)
	_check(int(views.guest1.get("winner", -1)) == 0, "late reconnect receives authenticated final result")
	await _wait(func(): return not guest.has_saved_session())
	_check(not guest.has_saved_session(), "server rejection removes expired recovery session")
	await _cleanup()

func _three_player_elimination() -> void:
	var players := await _setup(3, 17406)
	var host: Node = players[0]
	await _start(host)
	host.send_action({"type":"draw","source":"deck"})
	host.send_action({"type":"discard","card":host._engine.state.players[0].hand[-1]})
	await _wait(func(): return int(views.guest1.get("turn", -1)) == 1)
	players[1].leave_room()
	await _wait(func(): return bool(views.host.get("players", [{},{},{}])[1].get("forfeited", false)))
	_check(int(views.host.get("winner", -1)) < 0, "one departure does not prematurely end three-player match")
	_check(int(views.host.get("turn", -1)) == 2 and not bool(views.host.get("paused", true)), "forfeited current player is skipped and active players continue")
	await _cleanup()

func _host_closes_three_players() -> void:
	var players := await _setup(3, 17407)
	await _start(players[0])
	players[0].leave_room()
	await _wait(func(): return int(views.guest1.get("winner", -1)) >= 0)
	var result: Dictionary = views.guest1.get("match_result", {})
	_check(result.get("winners", []).map(func(index): return int(index)) == [1,2], "host shutdown declares all other active players co-winners")
	_check(bool(views.guest1.get("win_by_forfeit", false)) and not bool(views.guest1.get("paused", true)), "host shutdown result explains forfeit and clears pause")
	await _cleanup()

func _invalid_sessions() -> void:
	var node := _node("invalid")
	var file := FileAccess.open(node.session_path, FileAccess.WRITE)
	file.store_buffer(PackedByteArray([1,2,3]))
	file.close()
	_check(not node.has_saved_session(), "corrupt session cannot be resumed")
	var saved := {"version":1,"url":"ws://127.0.0.1:7357","name":"A","code":"123456","token":"a".repeat(48),"player":1,"updated_at":int(Time.get_unix_time_from_system())-90000}
	file = FileAccess.open(node.session_path, FileAccess.WRITE)
	file.store_string(JSON.stringify(saved))
	file.close()
	_check(not node.has_saved_session(), "expired session cannot be resumed")
	saved.updated_at = int(Time.get_unix_time_from_system())
	saved.token = "invalid"
	file = FileAccess.open(node.session_path, FileAccess.WRITE)
	file.store_string(JSON.stringify(saved))
	file.close()
	_check(not node.has_saved_session(), "malformed token is rejected without network call")
	await _cleanup()

func _dedicated_restart_and_leave() -> void:
	# Exercise the same app-restart API against the actual dedicated server,
	# including recovery of room ownership (seat zero).
	var port := 22000 + OS.get_process_id() % 12000
	var server_pid := OS.create_process(OS.get_executable_path(), ["--headless", "--path", ProjectSettings.globalize_path("res://"), "--script", "server/server.gd", "--", "--port=%d" % port])
	_check(server_pid > 0, "dedicated server process starts")
	if server_pid <= 0:
		return
	await create_timer(0.2).timeout
	var owner := _node("owner")
	owner.create_remote_room("ws://127.0.0.1:%d" % port, "Propriétaire")
	await _wait(func(): return owner.connected, 4000)
	_check(owner.connected and owner.is_host, "dedicated owner authenticates")
	if not owner.connected:
		await _cleanup()
		OS.kill(server_pid)
		return
	var guest := _node("remote_guest")
	guest.join_room("ws://127.0.0.1:%d" % port, "Invité", owner.room_code)
	await _wait(func(): return guest.connected)
	_check(guest.connected, "dedicated guest authenticates")
	owner.start_match()
	await _wait(func(): return not views.owner.is_empty())
	var previous: Array = views.owner.get("hand", []).duplicate()
	var token: String = owner._session_token
	var path: String = owner.session_path
	owner.queue_free()
	await process_frame
	await _wait(func(): return bool(views.remote_guest.get("paused", false)))
	_check(bool(views.remote_guest.get("paused", false)), "dedicated match waits for disconnected owner")
	var restored := _node("owner_restored", path)
	_check(restored.has_saved_session() and restored.resume_session(), "fresh owner resumes saved dedicated session")
	await _wait(func(): return restored.connected and not bool(views.remote_guest.get("paused", true)))
	_check(restored.connected and restored.is_host and restored.local_player == 0, "dedicated restart preserves owner authority")
	_check(restored._session_token == token and views.owner_restored.get("hand", []) == previous, "dedicated restart preserves exact token and hand")
	guest.leave_room()
	await _wait(func(): return int(views.owner_restored.get("winner", -1)) == 0)
	_check(int(views.owner_restored.get("winner", -1)) == 0 and bool(views.owner_restored.get("win_by_forfeit", false)), "dedicated guest abandon awards owner victory")
	await _cleanup()
	OS.kill(server_pid)
