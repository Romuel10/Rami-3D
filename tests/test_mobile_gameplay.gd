extends SceneTree
## Behavior checks for recoverable solo games, match scoring, hints and invitations.
const Rules = preload("res://scripts/rami_engine.gd")
const Store = preload("res://scripts/solo_store.gd")
const Invite = preload("res://scripts/invitation.gd")
const Room = preload("res://scripts/network_manager.gd")
var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func _check(value: bool, description: String) -> void:
	checks += 1
	if not value:
		failures.append(description)
		push_error("FAIL: " + description)

func _run() -> void:
	var game := Rules.new()
	game.start_game(["Vous","Camille","Alex"], 341, 3)
	var before: Dictionary = game.export_game()
	_check(Store.save_game(game,2,game.state.players[0].hand),"save a complete game before drawing")
	var saved: Dictionary = Store.load_game()
	var restored := Rules.new()
	_check(restored.restore_game(saved.game) and restored.state == game.state,"disk round trip retains every card and turn")
	_check(restored._rng.state == game._rng.state and saved.difficulty == 2,"random generator and difficulty survive restart")
	game.apply_action(0,{"type":"draw","source":"deck"})
	_check(Store.save_game(game,2,game.state.players[0].hand),"save after drawing")
	_check(restored.restore_game(Store.load_game().game) and restored.state.phase == "play" and restored.state.players[0].hand.size() == 14,"resume after draw cannot draw twice")
	var snapshot: Dictionary = restored.state.duplicate(true)
	_check(not restored.apply_action(0,{"type":"draw"}).ok and restored.state == snapshot,"resumed draw phase remains authoritative")
	# A torn or unknown primary file falls back to the last valid backup.
	Store.write_data(Store.SAVE,{"version":999})
	_check(restored.restore_game(Store.load_game().game) and restored.state == game.state,"invalid primary recovers backup")
	_check(not restored.restore_game({}) and restored.state == game.state,"invalid restore does not mutate running game")
	for field in ["turn","winner","revision","match","players","melds"]:
		var broken: Dictionary = before.duplicate(true)
		broken.state[field] = "broken"
		_check(not Rules.new().restore_game(broken),"corrupt field is rejected: " + field)
	var broken: Dictionary = before.duplicate(true)
	broken.state.deck[0] = broken.state.deck[1]
	_check(not Rules.new().restore_game(broken),"duplicate card identities are rejected")
	broken = before.duplicate(true)
	broken.state.match.results = [{"points":"wrong"}]
	_check(not Rules.new().restore_game(broken),"corrupt score history is rejected")

	# Preview uses only the viewer's own hand and visible combinations.
	var view := {"your_index":0,"players":[{"opened":false},{"opened":true}],"turn":0,"phase":"play","winner":-1,"hand":["0:H:7","0:H:8","0:H:9","0:S:2","0:D:2","0:C:2","0:S:13"],"melds":[]}
	var first := ["0:H:7","0:H:8","0:H:9"]
	var second := ["0:S:2","0:D:2","0:C:2"]
	var preview: Dictionary = game.selection_preview(view,first)
	_check(preview.points == 24 and not preview.can_meld,"opening preview counts 24 but blocks opening under 30")
	preview = game.selection_preview(view,first+second,[first,second])
	_check(preview.points == 30 and preview.can_meld,"several selected combinations can open together at 30")
	view.players[0].opened = true
	view.hand = ["0:H:10","0:S:13"]
	view.melds = [{"cards":first,"owner":1}]
	preview = game.selection_preview(view,["0:H:10"])
	_check(preview.targets == [0],"matching public combination is highlighted")
	view.paused = true
	_check(game.selection_preview(view,["0:H:10"]).targets.is_empty(),"paused games show no legal drop target")
	view.paused = false
	view.players[0].opened = false
	_check(game.selection_preview(view,["0:H:10"]).targets.is_empty(),"unopened player cannot extend a table group")

	var completed := 0
	for difficulty in range(3):
		game.start_game(["Vous","Camille","Alex"],40+difficulty,3)
		game.state.session_id += str(Time.get_ticks_usec())
		var session: String = game.state.session_id
		for round_number in range(1,4):
			for _turn in range(500):
				if game.state.winner >= 0: break
				game.bot_turn(game.state.turn,difficulty)
			_check(game.state.winner >= 0,"difficulty %d completes round %d" % [difficulty,round_number])
			if game.state.winner < 0: break
			completed += 1
			_check(_conserves(game),"all 108 cards conserved at round end")
			_check(game.state.match.results.size() == round_number,"score recorded exactly once per round")
			var result: Dictionary = game.state.match.results.back()
			for i in range(3):
				var penalty := 0
				for id in game.state.players[i].hand: penalty += int(game.card_info(id).points)
				_check(result.points[i] == penalty,"penalty equals cards actually held")
			var stats: Dictionary = Store.statistics()
			Store.record_round(game.state)
			Store.record_round(game.state)
			_check(Store.statistics().rounds == stats.rounds+1,"reopening winner does not count twice")
			_check(Rules.new().restore_game(game.export_game()),"completed match round is resumable")
			if round_number < 3:
				var totals: Array = game.state.match.totals.duplicate()
				_check(game.next_round().ok and game.state.match.totals == totals,"next deal keeps cumulative scores")
				_check(game.state.session_id == session and game.state.turn == round_number%3,"next round rotates dealer and retains match identity")
				_check(Rules.new().restore_game(game.export_game()),"new round state is resumable")
			else:
				_check(not game.next_round().ok,"three-round match stops after third round")
	_check(completed == 9,"all three difficulties finish three-round matches")
	# Changing unknown deck order has no influence on hard AI's decisions.
	game.start_game(["Vous","Camille"],23)
	var other := Rules.new()
	other.restore_game(game.export_game())
	other.state.deck.reverse()
	other.state.players[1].hand.reverse()
	_check(game._bot_draw_source(0,2) == other._bot_draw_source(0,2) and game._bot_discard(0,2) == other._bot_discard(0,2),"hard AI decisions ignore hidden order and opponent hands")

	var link := Invite.make("wss://example.test/rami?version=1","001234")
	var invitation: Dictionary = Invite.parse(link)
	_check(invitation.get("server") == "wss://example.test/rami?version=1" and invitation.code == "001234","invitation preserves full endpoint and leading zeroes")
	for invalid in ["", "https://example.test", "rami3d://join?server=file%3A%2F%2Ftmp&code=123456", "rami3d://join?server=ws%3A%2F%2Fhost&code=-12345", "rami3d://join?server=ws%3A%2F%2Fuser%40host&code=123456", link+"&code=999999"]:
		_check(Invite.parse(invalid).is_empty(),"malformed invitation rejected")
	# Real WebSocket handshake from a parsed invitation, without typing endpoint.
	var host := Room.new()
	var guest := Room.new()
	root.add_child(host)
	root.add_child(guest)
	_check(host.host_room("Hôte",17359),"invitation test opens local room")
	invitation = Invite.parse(Invite.make("ws://127.0.0.1:17359",host.room_code))
	_check(guest.join_room(invitation.server,"Ami",invitation.code),"parsed invitation starts connection")
	var deadline := Time.get_ticks_msec()+5000
	while not guest.connected and Time.get_ticks_msec() < deadline: await process_frame
	_check(guest.connected and guest.local_player == 1,"invitation connects to correct private seat")
	host.leave_room()
	guest.leave_room()
	host.queue_free()
	guest.queue_free()
	await process_frame
	print("RESULT: %d mobile gameplay checks; %d failures" % [checks,failures.size()])
	quit(0 if failures.is_empty() else 1)

func _conserves(game) -> bool:
	var cards: Array = game.state.deck + game.state.discard
	for player in game.state.players: cards.append_array(player.hand)
	for meld in game.state.melds: cards.append_array(meld.cards)
	return cards.size() == 108 and game._unique(cards)
