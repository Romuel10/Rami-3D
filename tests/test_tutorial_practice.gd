extends SceneTree

const Practice = preload("res://scripts/tutorial_practice.gd")
const Rules = preload("res://scripts/rami_engine.gd")
var checks := 0
var failures: Array[String] = []
var practice

func _initialize() -> void:
	call_deferred("_run")

func _check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures.append(message)
		push_error("FAIL: " + message)

func _conserves_and_restores(label: String) -> void:
	var game = practice.engine
	var all: Array = game.state.deck + game.state.discard
	for player in game.state.players:
		all.append_array(player.hand)
	for meld in game.state.melds:
		all.append_array(meld.cards)
	var unique: Dictionary = {}
	for id in all:
		unique[id] = true
	_check(all.size() == 108 and unique.size() == 108, label + " conserves all physical cards")
	_check(Rules.new().restore_game(game.export_game()), label + " is a valid restorable game")

func _run() -> void:
	practice = Practice.new()
	root.add_child(practice)
	practice.start_lesson()
	await process_frame
	await _rendered_check("tutorial-start")
	_check(practice.stage == 0 and practice.engine.state.phase == "draw", "exercise starts before the first draw")
	_check(practice.engine.state.players[0].hand.size() == 13 and practice.engine.state.turn == 0, "first player holds thirteen cards")
	_check(practice.engine.state.deck.back() == Practice.DRAW_CARD and Practice.DRAW_CARD not in practice.engine.state.players[0].hand, "scripted ninth heart must actually be drawn")
	_check(practice.selected.is_empty() and practice._card_buttons.size() == 13, "hand is rendered without preselection")
	_conserves_and_restores("start")
	var before: Dictionary = practice.engine.export_game()
	_check(not practice.toggle_card("0:H:7"), "cards cannot be selected before drawing")
	_check(not practice.play_selected() and not practice.discard_selected(), "playing and discarding cannot skip the lesson stages")
	_check(practice.engine.export_game() == before, "incorrect initial actions leave the real engine unchanged")
	var completed_events: Array = []
	practice.completed.connect(func(): completed_events.append(true))
	practice._action.pressed.emit()
	_check(practice.stage == 1 and practice.engine.state.phase == "play", "real draw button advances to selection")
	_check(practice.engine.state.players[0].hand.size() == 14 and Practice.DRAW_CARD in practice.engine.state.players[0].hand, "draw adds the exact physical ninth heart")
	_conserves_and_restores("draw")
	await _rendered_check("tutorial-selection")
	before = practice.engine.export_game()
	_check(not practice.draw_card() and practice.engine.export_game() == before, "second draw is rejected without changing state")
	_check(not practice.toggle_card("0:S:13") and practice.selected.is_empty(), "wrong lesson card explains the guided groups without selecting it")
	_check(not practice.toggle_card("invalid") and practice.selected.is_empty(), "unknown card cannot enter the selection")
	var opening: Array = Practice.OPENING_CARDS
	for i in range(5):
		_check(practice.toggle_card(opening[i]), "each of the first five intended cards can be selected")
	_check(practice.stage == 1 and practice.selected.size() == 5 and practice._action.disabled, "partial opening does not enable a premature pose")
	_check(not practice.play_selected() and practice.engine.state.melds.is_empty(), "partial opening is rejected by the lesson")
	practice._card_buttons[opening[5]].pressed.emit()
	_check(practice.stage == 2 and practice.selected.size() == 6 and not practice._action.disabled, "sixth card button completes the opening")
	_check(practice.toggle_card(opening[0]) and practice.stage == 1 and practice.selected.size() == 5, "a prepared opening can still be adjusted")
	_check(practice.toggle_card(opening[0]) and practice.stage == 2, "reselecting restores the complete opening")
	var points := 0
	for group in Practice.OPENING_GROUPS:
		points += practice.engine._validate_meld(group).points
	_check(points == 33, "two real legal runs total thirty-three opening points")
	practice._action.pressed.emit()
	_check(practice.stage == 3 and practice.engine.state.players[0].opened, "pose button opens through the real engine")
	_check(practice.engine.state.melds.size() == 2 and practice.engine.state.players[0].hand.size() == 8, "six cards moved from hand to two table groups")
	_check(practice.selected.is_empty() and practice._action.disabled, "a single final discard must still be chosen")
	_conserves_and_restores("opening")
	await _rendered_check("tutorial-discard")
	_check(not practice.play_selected() and not practice.draw_card(), "completed opening cannot be replayed or followed by another draw")
	_check(not practice.discard_selected(), "empty selection cannot finish the turn")
	_check(not practice.toggle_card(Practice.OPENING_CARDS[0]), "a card already on the table cannot be discarded")
	_check(practice.toggle_card("0:S:13") and practice.selected == ["0:S:13"], "an isolated card can be selected for discard")
	_check(practice.toggle_card("0:S:5") and practice.selected == ["0:S:5"], "choosing another discard replaces rather than extends selection")
	_check(practice.toggle_card("0:S:5") and practice.selected.is_empty(), "discard selection can be canceled")
	_check(practice.toggle_card("0:S:13"), "discard can be selected again")
	practice._action.pressed.emit()
	_check(practice.stage == 4 and completed_events.size() == 1, "discard button completes the exercise once")
	_check(practice.engine.state.turn == 1 and practice.engine.state.phase == "draw", "a legal final discard passes the actual turn to the opponent")
	_check(practice.engine.state.players[0].hand.size() == 7 and practice.engine.state.discard.back() == "0:S:13", "one precise card left the hand")
	_check(practice.engine.state.winner == -1, "first-turn practice completion does not falsely declare a game winner")
	_check(practice._action.disabled, "completion has no action that can advance the game again")
	_conserves_and_restores("discard")
	before = practice.engine.export_game()
	_check(not practice.discard_selected() and not practice.toggle_card("0:S:5"), "finished exercise rejects further card play")
	_check(completed_events.size() == 1 and practice.engine.export_game() == before, "completion cannot fire twice or mutate finished state")
	var back_events: Array = []
	practice.exit_requested.connect(func(): back_events.append(true))
	_find_button(practice, "Retour").pressed.emit()
	_check(back_events.size() == 1, "return button requests exit")
	_find_button(practice, "Recommencer l’exercice").pressed.emit()
	_check(practice.stage == 0 and practice.selected.is_empty() and practice.engine.state.players[0].hand.size() == 13, "restart resets the complete real exercise")
	_conserves_and_restores("restart")
	if DisplayServer.get_name() != "headless":
		root.size = Vector2i(2400,1080)
		await _rendered_check("tutorial-phone-wide")
	practice.queue_free()
	await process_frame
	print("RESULT: %d tutorial-practice checks; %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)

func _find_button(node: Node, title: String) -> Button:
	if node is Button and node.text == title:
		return node
	for child in node.get_children():
		var found := _find_button(child, title)
		if found != null:
			return found
	return null

func _rendered_check(label: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	if label == "tutorial-start":
		root.size = Vector2i(1440,900)
	for _frame in range(20):
		await process_frame
	await RenderingServer.frame_post_draw
	var viewport := root.get_visible_rect()
	_check(viewport.encloses(practice._action.get_global_rect()), label + " primary action remains in the viewport")
	for button: Button in practice._card_buttons.values():
		_check(viewport.encloses(button.get_global_rect()), label + " complete card stays in the viewport")
		_check(button.get_global_rect().position.y >= 104, label + " cards leave the app header accessible")
		_check(button.size.y >= 140, label + " cards remain large enough for the exercise")
	if "--capture" in OS.get_cmdline_user_args():
		DirAccess.make_dir_recursive_absolute("res://builds")
		root.get_texture().get_image().save_png("res://builds/" + label + ".png")
