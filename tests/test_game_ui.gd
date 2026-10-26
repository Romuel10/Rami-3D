extends SceneTree
## Exercises real scene callbacks and asynchronous bot turns, using only
## controlled hands where a specific player interaction must be available.

const MainScene = preload("res://main.tscn")
const Rules = preload("res://scripts/rami_engine.gd")
var app
var checks := 0

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	app = MainScene.instantiate()
	root.add_child(app)
	await process_frame
	_check(app.game_mode == "menu" and app.card_nodes.size() == 5, "menu starts with decorative cards")
	app.name_input.text = "Test UI"
	app.solo_select.select(0)
	_press("Jouer contre l’ordinateur   →")
	_check(app.game_mode == "solo" and app.snapshot.hand.size() == 13 and app.snapshot.players.size() == 2, "menu button starts a solo match")
	_check(app.snapshot.phase == "draw" and app.snapshot.turn == 0 and app._my_turn(), "player starts at draw phase")
	_press("↓  Piocher")
	_check(app.snapshot.phase == "play" and app.snapshot.hand.size() == 14, "draw button updates visible hand")
	var drawn_state: Dictionary = app.engine.state.duplicate(true)
	_check(app.draw_buttons[0].disabled and app.draw_buttons[1].disabled, "draw controls disable after drawing")
	_tap_deck()
	_check(app.engine.state == drawn_state and "déjà pioché" in app.toast_label.text, "repeated 3D-pile draw is rejected")

	_fixture(["0:H:7", "0:H:8", "0:H:9", "0:S:2", "0:D:2", "0:C:2", "0:S:13", "0:C:13"])
	var old_sort: bool = app.sort_suit
	_press("Trier ♠")
	_check(app.sort_suit != old_sort, "sort button switches ordering")
	var previous_key := -1
	for node in app.hand_cards:
		var key: int = app._sort_key(node.card_id)
		_check(key >= previous_key, "hand meshes follow active sort order")
		previous_key = key
	_press("Suggestion")
	_check(app.suggested.size() == 2 and app.selected.size() == 6, "suggestion combines two groups for opening")
	_press("Poser")
	_check(app.snapshot.melds.size() == 2 and app.snapshot.players[0].opened and app.snapshot.hand.size() == 2, "pose button sends multi-group opening")
	_check(app.selected.is_empty() and app.suggested.is_empty(), "snapshot refresh clears played selection")
	_tap_hand("0:S:13")
	_check(app.selected == ["0:S:13"], "hand mesh tap selects exact card")
	_press("Défausser →")
	_check(app.snapshot.turn == 1 and app.busy and app.snapshot.players[0].count == 1, "discard starts opponent turn")
	await create_timer(1.15).timeout
	_check(app.snapshot.turn == 0 and app.snapshot.phase == "draw" and not app.busy, "bot returns control after its timed turn")
	_check(app.snapshot.turn_count == 3 and app.snapshot.hand == app.engine.state.players[0].hand, "bot and visible player state stay synchronized")

	# Internet suggestions must operate with the same information available to
	# a real client: its own hand and public opponent summaries, no live engine.
	app.game_mode = "online"
	app.engine = null
	app.snapshot = {
		"your_index": 1, "turn": 1, "phase": "play", "winner": -1,
		"players": [{"name": "Adversaire", "count": 13, "opened": false}, {"name": "Test UI", "count": 8, "opened": false}],
		"hand": ["0:H:7", "0:H:8", "0:H:9", "0:S:2", "0:D:2", "0:C:2", "0:S:13", "0:C:13"],
		"deck_count": 80, "discard_top": "1:D:1", "melds": [], "log": "À vous", "turn_count": 1
	}
	app._render_snapshot()
	_press("Suggestion")
	_check(app.engine == null and app.suggested.size() == 2 and app.selected.size() == 6, "online helper needs no opponent hands or engine")
	_check(not app.snapshot.players[0].has("hand"), "online suggestion preserves opponent privacy")
	app.snapshot.paused = true
	_check(not app._my_turn(false), "disconnected match blocks player actions")

	# A legal extension leaves the final discard, which must expose the win
	# dialog and a working new-game callback rather than an inert end state.
	app.game_mode = "solo"
	app.engine = Rules.new()
	var older_melds: Array = [{"cards": ["0:H:7", "0:H:8", "0:H:9"], "owner": 1, "type": "run"}]
	for rank in range(2, 10):
		older_melds.append({"cards": ["0:S:%d" % rank, "0:D:%d" % rank, "0:C:%d" % rank], "owner": 1, "type": "set"})
	_fixture(["0:H:10", "0:S:13"], older_melds)
	app.engine.state.players[0].opened = true
	app._refresh_snapshot()
	_tap_hand("0:H:10")
	_press("Compléter")
	var older_choice = _find_button_prefix(app.overlay, "1 · ")
	_check(older_choice is Button, "extension modal retains older table combinations")
	older_choice.pressed.emit()
	_check(app.snapshot.melds[0].cards.size() == 4 and app.snapshot.hand == ["0:S:13"], "modal extends correct older combination")
	_check(app.overlay.get_child_count() == 0, "extension choice closes modal")

	_fixture(["0:H:10", "0:S:13"], [{"cards": ["0:H:7", "0:H:8", "0:H:9"], "owner": 1, "type": "run"}])
	app.engine.state.players[0].opened = true
	app._refresh_snapshot()
	_tap_hand("0:H:10")
	_tap_table_meld("0:H:7")
	_check(app.snapshot.melds[0].cards.size() == 4 and app.snapshot.hand == ["0:S:13"], "table extension updates hand and public meld")
	_tap_hand("0:S:13")
	_press("Défausser →")
	_check(app.snapshot.winner == 0 and app.overlay.get_child_count() > 0, "final discard opens victory dialog")
	_check(_find_text(app.overlay, "Vous avez gagné !") != null, "victory dialog identifies local winner")
	_press("Nouvelle partie")
	_check(app.game_mode == "solo" and app.snapshot.winner == -1 and app.snapshot.phase == "draw" and app.snapshot.hand.size() == 13, "new game button creates fresh playable state")
	_check(app.overlay.get_child_count() == 0 and app.snapshot.players[0].name == "Test UI", "new game closes victory and preserves profile")

	# Leaving during the artificial thinking delay must cancel that old turn.
	_tap_deck()
	_tap_hand(str(app.snapshot.hand[0]))
	_press("Défausser →")
	_check(app.busy, "bot is pending before leave")
	app._leave_to_menu()
	_press("Jouer contre l’ordinateur   →")
	var fresh_hand: Array = app.snapshot.hand.duplicate()
	await create_timer(1.15).timeout
	_check(app.snapshot.turn == 0 and app.snapshot.phase == "draw" and app.snapshot.hand == fresh_hand, "old bot timer cannot play in a new game")
	app._leave_to_menu()
	app.queue_free()
	await process_frame
	await create_timer(0.25).timeout
	print("PASS: %d real-scene UI checks" % checks)
	quit(0)

func _fixture(hand: Array, melds: Array = []) -> void:
	app.engine.start_game(["Test UI", "Camille"], 1)
	var remaining: Array = app.engine.state.deck + app.engine.state.discard
	for player in app.engine.state.players:
		remaining.append_array(player.hand)
	for id in hand:
		remaining.erase(id)
	for meld in melds:
		for id in meld.cards:
			remaining.erase(id)
	app.engine.state.players[0].hand = hand.duplicate()
	app.engine.state.players[1].hand = remaining.slice(0, 13)
	app.engine.state.discard = [remaining[13]]
	app.engine.state.deck = remaining.slice(14)
	app.engine.state.melds = melds.duplicate(true)
	app.engine.state.phase = "play"
	app._refresh_snapshot()

func _tap_hand(id: String) -> void:
	for card in app.hand_cards:
		if card.card_id == id and card.get_meta("hand_card", false):
			card.tapped.emit(card)
			return
	_check(false, "hand card not found: " + id)

func _tap_table_meld(id: String) -> void:
	for card in app.card_nodes:
		if card.card_id == id and card.face_up and not card.get_meta("hand_card", false) and card.position.z < -1.0:
			card.tapped.emit(card)
			return
	_check(false, "table meld card not found: " + id)

func _tap_deck() -> void:
	for card in app.card_nodes:
		if not card.face_up:
			card.tapped.emit(card)
			return
	_check(false, "deck card not found")

func _press(text: String) -> void:
	var node = _find_text(app.ui, text)
	if node == null and text == "↓  Piocher":
		node = _find_button_prefix(app.ui, text)
	_check(node is Button, "button available: " + text)
	if node is Button:
		_check(not node.disabled, "button enabled: " + text)
		node.pressed.emit()

func _find_text(node: Node, text: String):
	if (node is Button or node is Label) and node.text == text:
		return node
	for child in node.get_children():
		var found = _find_text(child, text)
		if found != null:
			return found
	return null

func _find_button_prefix(node: Node, prefix: String):
	if node is Button and node.text.begins_with(prefix):
		return node
	for child in node.get_children():
		var found = _find_button_prefix(child, prefix)
		if found != null:
			return found
	return null

func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		push_error("FAIL: " + message)
		quit(1)
		assert(condition, message)
