extends SceneTree
const Network = preload("res://scripts/network_manager.gd")
var view: Dictionary = {}
var checks := 0
func _init() -> void: call_deferred("_run")
func check(ok: bool, label: String) -> void:
	checks+=1
	if not ok:
		push_error(label)
		quit(1)
		assert(ok,label)
func until(predicate: Callable) -> void:
	var deadline := Time.get_ticks_msec()+4000
	while not predicate.call() and Time.get_ticks_msec()<deadline: await create_timer(.01).timeout
	check(predicate.call(),"bounded LAN delivery")
func _run() -> void:
	for size in [6,12]:
		var host := Network.new()
		var guest := Network.new()
		host.session_path = "user://host-tri-session"
		guest.session_path = "user://guest-tri-session"
		root.add_child(host)
		root.add_child(guest)
		view = {}
		guest.game_updated.connect(func(data): view=data)
		var port: int = 18300 + size
		check(host.host_room("A",port,size),"LAN host creates Tri")
		check(guest.join_room("127.0.0.1:%d"%port,"B",host.room_code),"LAN guest joins")
		await until(func(): return guest.connected)
		check(guest.get_lobby().tri_cards==size,"room advertises authoritative Tri format")
		check(host.start_match(),"host starts Tri duel")
		await until(func(): return not view.is_empty())
		check(view.variant=="tri" and view.hand.size()==size,"guest receives own Tri hand")
		check(not view.players[0].has("hand") and view.winning_tris.is_empty(),"LAN opponent remains private")
		var game: RefCounted = host._engine
		var hand := ["0:H:9","1:H:9","0:C:9","0:S:8","0:C:8","0:D:2"]
		if size == 12: hand.append_array(["0:S:7","0:C:7","0:D:7","0:H:1","0:S:3","0:D:4"])
		var pool: Array = game.state.deck + game.state.discard + game.state.players[0].hand + game.state.players[1].hand
		for card in hand + ["0:D:8"]: pool.erase(card)
		game.state.players[0].hand = hand
		game.state.players[1].hand = pool.slice(0, size)
		game.state.discard = [pool[size]]
		game.state.deck = pool.slice(size + 1) + ["0:D:8"]
		host.send_action({"type":"draw","source":"deck"})
		await until(func(): return view.phase=="play")
		check(host._engine.state.players[0].hand.size()==size+1,"LAN authoritative draw")
		host.send_action({"type":"discard","card":"0:D:2"})
		await until(func(): return int(view.turn)==1 or int(view.winner)>=0)
		check(view.winner == -1 and view.winning_tris.is_empty(),"the Wi-Fi host cannot award a win for two hearts and a club")
		guest.leave_room()
		await until(func(): return host._engine.state.winner>=0)
		check(host._engine.match_result().winners==[0],"Tri guest abandonment gives host victory")
		host.leave_room()
		host.queue_free()
		guest.queue_free()
		await process_frame
	print("PASS: %d Tri LAN checks"%checks)
	quit()
