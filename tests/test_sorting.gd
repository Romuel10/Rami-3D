extends SceneTree

const Challenge = preload("res://scripts/sorting_challenge.gd")
var checks := 0
var challenge

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	challenge = Challenge.new()
	root.add_child(challenge)
	challenge.start_challenge(98765)
	await process_frame
	_check(challenge.cards.size() == 8 and challenge.current_round == 0, "first round has eight cards")
	_check(not challenge.finished and challenge.score == 0, "session starts with no score")
	_unique_cards()
	var initial: Array = challenge.cards.duplicate()
	_check(not challenge.check_order(), "shuffled round must reject unsorted cards")
	_check(challenge.cards == initial and challenge.mistakes == 1, "wrong verification preserves card order and records retry")
	_check(not challenge._bad_indices.is_empty(), "wrong neighbors are highlighted")
	var before_invalid: Array = challenge.cards.duplicate()
	_check(not challenge.swap_cards(-1, 3) and not challenge.swap_cards(0, 99) and not challenge.swap_cards(1,1), "invalid swaps rejected")
	_check(challenge.cards == before_invalid, "invalid swaps leave the round untouched")
	var first: String = challenge.cards[0]
	var second: String = challenge.cards[1]
	challenge._card_buttons[0].pressed.emit()
	_check(challenge.selected_index == 0, "tap selects card")
	challenge._card_buttons[1].pressed.emit()
	_check(challenge.cards[0] == second and challenge.cards[1] == first and challenge.selected_index == -1, "second tap exchanges exact cards")
	_check(challenge._bad_indices.is_empty(), "exchange clears stale error highlights")
	var hint: String = challenge.give_hint()
	_check("place" in hint and "as" in hint and challenge.hints == 1, "hint explains a position and ace ordering")
	_sort_by_swaps()
	_check(challenge.check_order(), "legal rank sorting succeeds")
	_check(challenge.round_solved and challenge.score == 85 and challenge.rounds_completed == 1, "round scoring includes one retry and hint")
	var score_before: int = challenge.score
	_check(challenge.check_order() and challenge.score == score_before, "repeated verification cannot award points twice")
	_check(not challenge.swap_cards(0,1), "solved round cannot be edited")
	challenge._verify_button.pressed.emit()
	_check(challenge.current_round == 1 and challenge.cards.size() == 10 and not challenge.round_solved, "next button starts the ten-card round")
	_unique_cards()
	_check(challenge.sort_key("0:C:13") < challenge.sort_key("0:D:1") and challenge.sort_key("0:D:13") < challenge.sort_key("0:H:1") and challenge.sort_key("0:H:13") < challenge.sort_key("0:S:1"), "suit ordering is clubs diamonds hearts spades")
	_check(challenge.sort_key("0:C:1") < challenge.sort_key("0:C:13"), "ace is low inside each suit")
	var before_hint: Array = challenge.cards.duplicate()
	var suit_hint: String = challenge.give_hint()
	_check("trèfles" in suit_hint and "piques" in suit_hint and challenge.cards == before_hint, "suit hint teaches without moving cards")
	_sort_by_swaps()
	_check(challenge.check_order() and challenge.score == 180, "suit round scores ninety-five points after hint")
	challenge.new_round()
	_check(challenge.current_round == 2 and challenge.cards.size() == 12, "third round has twelve cards")
	_unique_cards()
	_check(challenge.sort_key("0:H:1") == challenge.sort_key("0:C:1") and challenge.sort_key("0:S:13") > challenge.sort_key("0:D:12"), "rank-only rounds accept equal-valued suits")
	# Deliberately include adjacent equal values in reverse suit order to prove
	# that matching ranks do not need an arbitrary extra tie-breaker.
	challenge.cards.assign(["0:S:1", "0:C:1", "0:H:2", "0:D:2", "0:S:3", "0:C:4", "0:D:5", "0:H:6", "0:S:7", "0:C:11", "0:H:12", "0:D:13"])
	_check(challenge.check_order(), "ties in a rank-only round are valid in either suit order")
	var results: Dictionary = challenge.get_results()
	_check(results.finished and results.rounds_completed == 3 and results.score == 280 and results.max_score == 300, "final result combines three completed rounds")
	_check(results.mistakes == 1 and results.hints == 2 and results.elapsed_seconds >= 0, "results retain retries hints and elapsed time")
	_check(challenge._verify_button.text == "Rejouer le défi" and challenge._hint_button.disabled, "finished screen offers replay")
	var finished_cards: Array = challenge.cards.duplicate()
	_check(not challenge.swap_cards(0,1) and challenge.cards == finished_cards, "finished challenge cannot be edited")
	challenge._verify_button.pressed.emit()
	_check(challenge.current_round == 0 and challenge.score == 0 and challenge.mistakes == 0 and challenge.hints == 0 and not challenge.finished, "replay resets complete session")
	challenge.start_challenge(98765)
	_check(challenge.cards == initial, "seeded shuffle is reproducible")
	var exited: Array = []
	challenge.exit_requested.connect(func(): exited.append(true))
	var back := _find_button(challenge, "Retour")
	_check(back != null, "return control exists")
	back.pressed.emit()
	_check(exited.size() == 1, "return control emits exit request")
	await process_frame
	challenge.queue_free()
	await process_frame
	print("PASS: %d sorting-challenge checks" % checks)
	quit(0)

func _sort_by_swaps() -> void:
	for i in range(challenge.cards.size()):
		var smallest := i
		for j in range(i + 1, challenge.cards.size()):
			if challenge.sort_key(challenge.cards[j]) < challenge.sort_key(challenge.cards[smallest]):
				smallest = j
		if smallest != i:
			_check(challenge.swap_cards(i, smallest), "player swaps can produce sorted order")

func _unique_cards() -> void:
	var unique: Dictionary = {}
	for id in challenge.cards:
		unique[id] = true
	_check(unique.size() == challenge.cards.size(), "round has unique physical cards")

func _find_button(node: Node, title: String) -> Button:
	if node is Button and node.text == title:
		return node
	for child in node.get_children():
		var found := _find_button(child, title)
		if found != null:
			return found
	return null

func _check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		push_error("FAIL: " + message)
		quit(1)
		assert(value, message)
