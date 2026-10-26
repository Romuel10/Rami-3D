extends SceneTree
## Run: godot --headless --path . --script tests/test_network.gd
const NetworkScript = preload("res://scripts/network_manager.gd")
var host: Node
var guest: Node
var outsider: Node
var host_view: Dictionary = {}
var guest_view: Dictionary = {}
var host_lobby: Dictionary = {}
var guest_errors: Array = []
var outsider_errors: Array = []
var failures := 0

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	if OS.get_cmdline_user_args().has("--remote"):
		await _run_remote()
		return
	host = NetworkScript.new()
	guest = NetworkScript.new()
	outsider = NetworkScript.new()
	root.add_child(host)
	root.add_child(guest)
	root.add_child(outsider)
	host.game_updated.connect(func(view: Dictionary): host_view = view)
	guest.game_updated.connect(func(view: Dictionary): guest_view = view)
	host.lobby_updated.connect(func(lobby: Dictionary): host_lobby = lobby)
	guest.notice.connect(func(message: String): guest_errors.append(message))
	outsider.notice.connect(func(message: String): outsider_errors.append(message))
	_expect(host.host_room("Alice", 17357), "host opens TCP room")
	_expect(host.room_code.length() == 6, "six digit code")
	_expect(guest.join_room("127.0.0.1:17357", "Benoît", host.room_code), "guest begins join")
	await _wait_until(func(): return guest.connected, 4000)
	_expect(guest.connected and guest.local_player == 1, "guest has authenticated own seat")
	_expect(host_lobby.get("players", []).size() == 2, "host lobby has two players")
	_expect(outsider.join_room("127.0.0.1:17357", "Intrus", "999999" if host.room_code != "999999" else "000000"), "bad code connection starts")
	await _wait_until(func(): return not outsider_errors.is_empty(), 3000)
	_expect(not outsider_errors.is_empty() and not outsider.connected, "bad room code rejected")
	outsider.leave_room()
	_expect(host.start_match(), "host starts match")
	await _wait_until(func(): return not guest_view.is_empty(), 3000)
	_expect(host_view.get("hand", []).size() == 13 and guest_view.get("hand", []).size() == 13, "both players receive their own 13 cards")
	_expect(host_view.get("hand", []) != guest_view.get("hand", []), "private hands differ")
	var summaries: Array = guest_view.get("players", [])
	var hidden := true
	for summary: Dictionary in summaries:
		if summary.has("hand"):
			hidden = false
	_expect(hidden, "opponent hands never sent")
	host.send_action({"type": "draw", "source": "deck"})
	await _wait_until(func(): return guest_view.get("phase") == "play", 3000)
	_expect(host_view.get("hand", []).size() == 14, "host draws authoritatively")
	guest.send_action({"type": "discard", "card": guest_view.get("hand", [""])[0], "player": 0})
	await _wait_until(func(): return not guest_errors.is_empty(), 3000)
	_expect(not guest_errors.is_empty() and int(guest_view.get("turn", -1)) == 0, "client cannot impersonate host or play out of turn")
	var host_hand: Array = host_view.get("hand", [])
	if not host_hand.is_empty():
		host.send_action({"type": "discard", "card": host_hand[-1]})
	await _wait_until(func(): return int(guest_view.get("turn", -1)) == 1, 3000)
	_expect(int(guest_view.get("turn", -1)) == 1, "discard advances turn")
	await create_timer(0.12).timeout
	guest.send_action({"type": "draw", "source": "deck"})
	await _wait_until(func(): return guest_view.get("hand", []).size() == 14, 3000)
	_expect(guest_view.get("hand", []).size() == 14, "guest action accepted for own seat")
	var previous_token: String = guest._session_token
	guest._client.close(1001, "Test interruption")
	await _wait_until(func(): return bool(host_view.get("paused", false)), 3000)
	_expect(bool(host_view.get("paused", false)), "disconnect pauses match")
	await _wait_until(func(): return guest.connected and not bool(host_view.get("paused", true)), 6000)
	_expect(guest.connected and guest._session_token == previous_token and guest.local_player == 1, "automatic reconnect recovers same seat with token")
	_expect(not bool(host_view.get("paused", true)), "reconnect resumes match")
	outsider.join_room("127.0.0.1:17357", "Nouveau", host.room_code)
	await _wait_until(func(): return not outsider_errors.is_empty(), 3000)
	_expect(not outsider.connected, "new player cannot enter running match")
	_expect(guest._normalise_address("192.168.1.5") == "ws://192.168.1.5:7357", "bare LAN address gets game port")
	_expect(guest._normalise_address("wss://example.com/rami") == "wss://example.com/rami", "secure endpoint keeps standard port")
	host.leave_room()
	guest.leave_room()
	outsider.leave_room()
	host.queue_free()
	guest.queue_free()
	outsider.queue_free()
	await process_frame
	print("NETWORK TESTS: ", "PASS" if failures == 0 else "FAIL (%d)" % failures)
	quit(0 if failures == 0 else 1)

func _wait_until(predicate: Callable, timeout_ms: int) -> void:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while not bool(predicate.call()) and Time.get_ticks_msec() < deadline:
		await create_timer(0.01).timeout

func _expect(condition: bool, label: String) -> void:
	if condition:
		print("PASS ", label)
	else:
		failures += 1
		push_error("FAIL " + label)

func _run_remote() -> void:
	host = NetworkScript.new()
	guest = NetworkScript.new()
	root.add_child(host)
	root.add_child(guest)
	host.game_updated.connect(func(view: Dictionary): host_view = view)
	guest.game_updated.connect(func(view: Dictionary): guest_view = view)
	host.lobby_updated.connect(func(lobby: Dictionary): host_lobby = lobby)
	guest.notice.connect(func(message: String): guest_errors.append(message))
	_expect(host.create_remote_room("ws://127.0.0.1:17358", "Alice distante"), "remote room creation starts")
	await _wait_until(func(): return host.connected, 4000)
	_expect(host.connected and host.is_host and not host._hosting_locally, "creator owns remote room without local TCP host")
	_expect(host.room_code.length() == 6 and host.local_player == 0, "remote creator receives code and seat zero")
	_expect(guest.join_room("ws://127.0.0.1:17358", "Benoît distant", host.room_code), "remote guest joins")
	await _wait_until(func(): return guest.connected, 4000)
	_expect(guest.connected and not guest.is_host and guest.local_player == 1, "remote guest receives seat one")
	_expect(host.start_match(), "remote owner requests start")
	await _wait_until(func(): return not guest_view.is_empty(), 3000)
	_expect(host_view.get("hand", []).size() == 13 and guest_view.get("hand", []).size() == 13, "dedicated server sends each client's hand")
	host.send_action({"type": "draw", "source": "deck"})
	await _wait_until(func(): return host_view.get("hand", []).size() == 14, 3000)
	_expect(host_view.get("hand", []).size() == 14, "remote host action reaches dedicated server")
	await create_timer(0.12).timeout
	var hand: Array = host_view.get("hand", [])
	if not hand.is_empty():
		host.send_action({"type": "discard", "card": hand[-1]})
	await _wait_until(func(): return int(guest_view.get("turn", -1)) == 1, 3000)
	_expect(int(guest_view.get("turn", -1)) == 1, "dedicated game advances turn")
	var previous_token: String = host._session_token
	host._client.close(1001, "Test Internet interruption")
	await _wait_until(func(): return bool(guest_view.get("paused", false)), 3000)
	_expect(bool(guest_view.get("paused", false)), "dedicated game pauses if room owner disconnects")
	_expect(host.reconnect(), "manual reconnect keeps existing remote session")
	await _wait_until(func(): return host.connected and not bool(guest_view.get("paused", true)), 6000)
	_expect(host.connected and host.is_host and host._session_token == previous_token, "remote owner reconnects with same token and authority")
	_expect(not bool(guest_view.get("paused", true)), "dedicated game resumes after reconnect")
	host.leave_room()
	guest.leave_room()
	host.queue_free()
	guest.queue_free()
	await process_frame
	print("REMOTE CLIENT TESTS: ", "PASS" if failures == 0 else "FAIL (%d)" % failures)
	quit(0 if failures == 0 else 1)
