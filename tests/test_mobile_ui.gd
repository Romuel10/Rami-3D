extends SceneTree
## Rendered input and lifecycle checks, using real touch dispatch and physics picking.
const Scene = preload("res://main.tscn")
const Rules = preload("res://scripts/rami_engine.gd")
const Store = preload("res://scripts/solo_store.gd")
var app
var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func _check(value: bool, description: String) -> void:
	checks += 1
	if not value:
		failures.append(description)
		push_error("FAIL: " + description)

func _settle() -> void:
	await process_frame
	var deadline := Time.get_ticks_msec()+2500
	while app.card_nodes.any(func(card): return card.is_moving()) and Time.get_ticks_msec()<deadline: await process_frame
	await physics_frame
	await RenderingServer.frame_post_draw

func _touch(point: Vector2, pressed: bool, index: int = 0, canceled: bool = false) -> void:
	var event := InputEventScreenTouch.new()
	event.index = index
	event.position = root.get_final_transform()*point
	event.pressed = pressed
	event.canceled = canceled
	Input.parse_input_event(event)

func _move(point: Vector2, index: int = 0) -> void:
	var event := InputEventScreenDrag.new()
	event.index = index
	event.position = root.get_final_transform()*point
	Input.parse_input_event(event)

func _corner(card: Node3D) -> Vector2:
	return app.camera.unproject_position(card.get_node("Paper/PrintedFace").to_global(Vector3(-0.37,0.50,0)))

func _drag(card: Node3D, target: Vector2) -> void:
	_touch(_corner(card),true)
	await process_frame
	_check(app._drag_card == card,"touch captures the exact visible hand card")
	_move(target)
	await process_frame
	_check(app._drag_active,"finger motion starts drag after threshold")
	_touch(target,false)
	await _settle()
	_check(not is_instance_valid(app._drag_card),"release clears gesture state")

func _fixture(hand: Array, opened: bool = false, melds: Array = []) -> void:
	app.turn_token += 1
	app.busy = false
	app.game_mode = "solo"
	app.engine = Rules.new()
	app.engine.start_game(["Vous","Camille"],99,3)
	var remaining: Array = app.engine.state.deck + app.engine.state.discard
	for player in app.engine.state.players: remaining.append_array(player.hand)
	for id in hand: remaining.erase(id)
	for meld in melds:
		for id in meld.cards: remaining.erase(id)
	app.engine.state.players[0].hand = hand.duplicate()
	app.engine.state.players[0].opened = opened
	app.engine.state.players[1].hand = remaining.slice(0,13)
	app.engine.state.discard = [remaining[13]]
	app.engine.state.deck = remaining.slice(14)
	app.engine.state.melds = melds.duplicate(true)
	app.engine.state.phase = "play"
	app.hand_order.clear()
	app._close_overlay()
	app._show_game()
	app._refresh_snapshot()
	await _settle()

func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("Rendered mobile UI test requires a graphics display")
		quit(2)
		return
	app = Scene.instantiate()
	root.add_child(app)
	app._set_fullscreen(false,false)
	root.size = Vector2i(1440,900)
	await process_frame
	app.difficulty = 2
	app.match_length = 3
	app._start_solo()
	await _settle()
	var original: Dictionary = app.engine.export_game()
	app._act({"type":"draw"})
	await _settle()
	var after_draw: Dictionary = app.engine.export_game()
	app._leave_to_menu()
	app._resume_solo()
	await _settle()
	_check(app.engine.export_game() == after_draw and app.difficulty == 2,"scene resume preserves cards, phase, random state and chosen difficulty")
	_check(app.snapshot.phase == "play" and app.hand_cards.size() == 14,"resumed table is playable after drawing")
	var cursor: int = app.effects._cursor
	app._render_snapshot()
	_check(app.effects._cursor == cursor,"identical snapshots do not repeat action sound")
	app.effects.enabled = false
	app.effects.play("draw")
	_check(app.effects._cursor == cursor,"muted effects do not start an audio voice")
	app.effects.enabled = true
	app.music.set_enabled(false)
	app.effects.play("draw")
	_check(app.effects._cursor == cursor+1 and not app.music.enabled,"effects remain available with music off")

	for screen in [Vector2i(1440,900),Vector2i(2400,1080)]:
		root.size = screen
		await process_frame
		await _fixture(["0:H:7","0:H:8","0:H:9","0:S:2","0:D:2","0:C:2","0:S:13"])
		var card: Node3D = app.hand_cards[0]
		var id: String = card.card_id
		var logical: Vector2 = root.get_visible_rect().size
		await _drag(card,Vector2(logical.x-60,640))
		_check(app.hand_order.back() == id and app.hand_cards.back().card_id == id,"hand reorders to the right on " + str(screen))
		var ordered: Array = app.hand_order.duplicate()
		app._leave_to_menu()
		app._resume_solo()
		await _settle()
		_check(app.hand_order == ordered,"manual order survives application resume")
		# A cancelled touch and another finger never execute a game action.
		card = app.hand_cards[0]
		var unchanged: Dictionary = app.engine.export_game()
		var start := _corner(card)
		_touch(start,true)
		await process_frame
		_touch(_corner(app.hand_cards[1]),true,1)
		_move(start+Vector2(60,-60),1)
		_touch(start,false,1)
		await process_frame
		_check(app._drag_card == card and not app._drag_active,"second finger cannot replace or move the first gesture")
		_move(start+Vector2(60,-60))
		await process_frame
		_touch(start,false,0,true)
		await _settle()
		_check(not is_instance_valid(app._drag_card) and app.engine.export_game() == unchanged,"cancelled drag leaves rules and cards intact")
		# Dropping one invalid card on the empty table returns it to the hand.
		card = app.hand_cards[0]
		await _drag(card,Vector2(logical.x*0.25,365))
		_check(app.engine.export_game() == unchanged and app.hand_cards.size() == 7,"invalid meld cannot remove or duplicate a card")
		# Existing multi-selection is respected when one member is dragged.
		app._suggest()
		_check(app.selected.size() == 6 and "30 / 30" in app.hand_status.text,"opening preview shows selected groups total")
		card = app._view_cards["card:0:H:7"]
		await _settle()
		await _drag(card,Vector2(logical.x*0.25,365))
		_check(app.snapshot.melds.size() == 2 and app.snapshot.hand.size() == 1 and app.snapshot.players[0].opened,"drag opens both selected groups legally")
		# A discard goes to the exact projected pile and opens round scores.
		card = app.hand_cards[0]
		await _drag(card,app.camera.unproject_position(Vector3(0.85,0.19,-0.8)))
		_check(app.snapshot.winner == 0 and app.overlay_kind == "winner","drag final discard opens score dialog")
		var stats: Dictionary = Store.statistics()
		app._render_snapshot()
		_check(Store.statistics() == stats,"duplicate winner update cannot duplicate statistics")
		app._next_round()
		_check(app.snapshot.match.round == 2 and app.snapshot.match.results.size() == 1,"next-round button retains previous result")
		app._leave_to_menu()
		await _fixture(["0:H:10","0:S:13"],true,[{"cards":["0:H:7","0:H:8","0:H:9"],"owner":1,"type":"run"}])
		card = app._view_cards["card:0:H:10"]
		card.tapped.emit(card)
		await _settle()
		_check(app._view_cards["card:0:H:7"].selected,"eligible meld has visible highlight")
		var meld_card: Node3D = app._view_cards["card:0:H:9"]
		var center: Vector2 = app.camera.unproject_position(meld_card.get_node("Paper/PrintedFace").global_position)
		await _drag(card,center)
		_check(app.snapshot.melds[0].cards.size() == 4 and app.snapshot.hand == ["0:S:13"],"drag can extend an opponent combination")
		# A snapshot invalidates a pending gesture; its late release is harmless.
		card = app.hand_cards[0]
		_touch(_corner(card),true)
		await process_frame
		_move(Vector2(logical.x*0.4,370))
		await process_frame
		app._render_snapshot()
		_touch(Vector2(logical.x*0.4,370),false)
		await _settle()
		_check(app.snapshot.hand == ["0:S:13"] and not is_instance_valid(app._drag_card),"new snapshot cancels obsolete gesture safely")
		root.get_texture().get_image().save_png("res://builds/mobile-ui-%dx%d.png" % [screen.x,screen.y])
	app._leave_to_menu()
	app.queue_free()
	await process_frame
	await create_timer(0.5).timeout
	print("RESULT: %d rendered mobile UI checks; %d failures" % [checks,failures.size()])
	quit(0 if failures.is_empty() else 1)
