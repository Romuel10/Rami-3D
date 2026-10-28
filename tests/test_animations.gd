extends SceneTree
## Exercise real time-based motion and public snapshot reconciliation.
const Scene = preload("res://main.tscn")
var app
var checks := 0

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	app = Scene.instantiate()
	root.add_child(app)
	await process_frame
	app.network.local_player = 0
	var view := {
		"your_index": 0, "turn": 0, "phase": "draw", "winner": -1,
		"players": [{"name":"Vous", "count":13, "opened":true}, {"name":"Ami", "count":13, "opened":true}],
		"hand": ["0:H:7", "0:H:8", "0:H:9", "0:S:2", "0:D:2", "0:C:2", "0:S:13", "0:C:13", "0:D:4", "0:D:5", "0:D:6", "0:C:10", "0:S:11"],
		"deck_count": 80, "discard_top": "1:D:1", "melds": [], "turn_count": 1
	}
	app._network_game_updated(view.duplicate(true))
	_check(app.hand_cards.size() == 13 and app.card_nodes.size() == 30, "deal mounts all logical cards immediately")
	var last: Node3D = app.hand_cards.back()
	var last_start: Transform3D = last.transform
	_check(last.is_moving() and not last.transform.is_equal_approx(last.motion_target), "deal begins at deck rather than final fan")
	_check(last.has_node("Paper/PrintedBack"), "turnover has artwork on the underside")
	await create_timer(0.15).timeout
	_check(last.transform.is_equal_approx(last_start), "later deal cards wait their turn")
	_check(not app.hand_cards[0].transform.is_equal_approx(last_start), "first card moves while later cards wait")
	await _settled()
	var nodes := _ids()
	app._network_game_updated(view.duplicate(true))
	_check(_ids() == nodes and not _moving(), "unchanged snapshot retains every mesh without restarting motion")

	var chosen: Node3D = app.hand_cards[3]
	var before: Transform3D = chosen.transform
	chosen.tapped.emit(chosen)
	_check(app.selected == [chosen.card_id] and chosen.transform.is_equal_approx(before), "selection starts without teleporting")
	await create_timer(0.06).timeout
	_check(chosen.position.y > before.origin.y and chosen.position.y < chosen.motion_target.origin.y, "selection travels through an intermediate pose")
	chosen.tapped.emit(chosen)
	chosen.tapped.emit(chosen)
	chosen.tapped.emit(chosen)
	await _settled()
	_check(app.selected.is_empty() and chosen.transform.is_equal_approx(before), "rapid selection reversals settle without drift")
	_check(is_equal_approx(chosen.get_node("Paper").position.y, chosen.get_node("TouchTarget").position.y), "hand hitbox stays aligned with paper")

	var poses: Dictionary = {}
	for card in app.hand_cards:
		poses[card.card_id] = card.transform
	app._sort_hand()
	var changed := false
	for card in app.hand_cards:
		_check(card.transform.is_equal_approx(poses[card.card_id]), "sorting starts from visible pose")
		changed = changed or not card.transform.is_equal_approx(card.motion_target)
	_check(changed and _ids() == nodes, "sorting reorders the existing meshes")
	await _settled()

	# Deck draw: existing hand cards slide apart; just one new card turns over.
	view.hand.append("1:H:8")
	view.players[0].count = 14
	view.phase = "play"
	view.deck_count = 79
	app._network_game_updated(view.duplicate(true))
	var drawn: Node3D = app._view_cards["card:1:H:8"]
	_check(drawn.global_position.is_equal_approx(app.DECK_POSITION), "new deck card starts at the draw pile")
	for id in nodes:
		_check(app._view_cards[id].get_instance_id() == nodes[id], "drawing preserves the previous visible meshes")
	await _settled()

	# Discard the very same mesh across the camera/world boundary.
	var world_before: Transform3D = drawn.global_transform
	view.hand.erase("1:H:8")
	view.players[0].count = 13
	view.discard_top = "1:H:8"
	view.turn = 1
	view.phase = "draw"
	app._network_game_updated(view.duplicate(true))
	_check(app._view_cards["card:1:H:8"] == drawn and drawn.get_parent() == app, "discard reuses hand card on table")
	_check(drawn.global_transform.is_equal_approx(world_before), "reparenting preserves the exact visible pose")
	_check(drawn.get_meta("zone") == "discard" and not drawn.get_meta("hand_card"), "discard callback now addresses its current pile")
	await _settled()
	_check(drawn.position.is_equal_approx(Vector3(0.85, 0.19, -0.8)), "discard settles on its pile")

	# Drawing that discard preserves its face and starts at its actual location.
	world_before = drawn.global_transform
	view.hand.append("1:H:8")
	view.players[0].count = 14
	view.discard_top = "1:C:1"
	view.turn = 0
	view.phase = "play"
	app._network_game_updated(view.duplicate(true))
	_check(drawn.get_parent() == app.hand_root and drawn.global_transform.is_equal_approx(world_before), "discard draw starts from the existing face-up mesh")
	_check(app._view_cards["card:1:C:1"].position.is_equal_approx(Vector3(0.85, 0.19, -0.8)), "revealed discard stays in its pile instead of flying in from an opponent")
	await _settled()

	# A hand meld flies onto the table. Subsequent public groups can change
	# its visible index without leaving a captured callback pointing elsewhere.
	var seven: Node3D = app._view_cards["card:0:H:7"]
	world_before = seven.global_transform
	for id in ["0:H:7", "0:H:8", "0:H:9"]:
		view.hand.erase(id)
	view.melds = [{"cards":["0:H:7", "0:H:8", "0:H:9"], "owner":0}]
	app._network_game_updated(view.duplicate(true))
	_check(seven.get_parent() == app and seven.global_transform.is_equal_approx(world_before), "meld preserves hand pose before flying to table")
	await _settled()
	view.melds.push_front({"cards":["1:S:3", "1:S:4", "1:S:5"], "owner":1})
	app._network_game_updated(view.duplicate(true))
	_check(seven.get_meta("meld_index") == 1 and seven.tapped.get_connections().size() == 1, "reused meld updates its index with exactly one input connection")
	_check(app._view_cards["card:1:S:3"].position.is_equal_approx(app._opponent_position(1)), "new public opponent card enters from its owner’s seat")
	await _settled()

	# Rapid network updates interrupt an in-flight draw with a discard.
	view.hand.append("1:D:12")
	app._network_game_updated(view.duplicate(true))
	var rapid: Node3D = app._view_cards["card:1:D:12"]
	await create_timer(0.07).timeout
	world_before = rapid.global_transform
	view.hand.erase("1:D:12")
	view.discard_top = "1:D:12"
	app._network_game_updated(view.duplicate(true))
	_check(rapid.global_transform.is_equal_approx(world_before), "interrupted draw continues from its in-flight position")
	await _settled()
	_check(rapid.transform.is_equal_approx(rapid.motion_target), "latest network destination wins")

	# A resize cancels obsolete coordinates; leaving cancels all old flights.
	app._sort_hand()
	app._screen_changed()
	_check(not app.hand_cards.any(func(card): return card.is_moving()), "resize settles hand in the current viewport immediately")
	app._sort_hand()
	var old_cards: Array = app.card_nodes.duplicate()
	app._leave_to_menu()
	await process_frame
	await process_frame
	_check(old_cards.all(func(card): return not is_instance_valid(card)), "leaving frees every old card and its bound motion")
	_check(app.hand_cards.is_empty() and app._view_cards.is_empty() and app.card_nodes.size() == 5, "menu has no stale game card state")
	app.queue_free()
	await process_frame
	await create_timer(0.25).timeout
	print("PASS: %d animation checks" % checks)
	quit(0)

func _ids() -> Dictionary:
	var result: Dictionary = {}
	for key in app._view_cards:
		result[key] = app._view_cards[key].get_instance_id()
	return result

func _moving() -> bool:
	return app.card_nodes.any(func(card): return card.is_moving())

func _settled() -> void:
	var deadline := Time.get_ticks_msec() + 2000
	while _moving() and Time.get_ticks_msec() < deadline:
		await process_frame
	_check(not _moving(), "card motions finish within two seconds")
	for card in app.card_nodes:
		_check(card.transform.is_equal_approx(card.motion_target), "motion finishes at its precise destination")

func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		push_error("FAIL: " + message)
		quit(1)
		assert(condition, message)
