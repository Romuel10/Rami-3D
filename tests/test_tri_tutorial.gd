extends SceneTree
## Use an isolated XDG_DATA_HOME. Optional --capture writes real rendered screens.
const Practice = preload("res://scripts/tri_tutorial.gd")
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
	var cards: Array = game.state.deck + game.state.discard
	for player in game.state.players: cards.append_array(player.hand)
	_check(cards.size() == 104 and game._unique(cards),label + ": all104 physical cards conserved")
	_check(game.state.melds.is_empty(),label + ": tris never posed publicly")
	var restored := Rules.new()
	_check(restored.restore_game(JSON.parse_string(JSON.stringify(game.export_game()))),label + ": real duel can restore from JSON")
	_check(game.view_for(1).players.all(func(player): return not player.has("hand")),label + ": opponent receives no private hand")
	if game.state.winner == -1:
		_check(game.view_for(1).winning_tris.is_empty(),label + ": no tris revealed before victory")

func _run() -> void:
	practice = Practice.new()
	root.add_child(practice)
	var completion_events: Array = []
	practice.completed.connect(func(): completion_events.append(true))
	var exit_events: Array = []
	practice.exit_requested.connect(func(): exit_events.append(true))
	for size in [6,12]:
		practice.start_lesson(size)
		await process_frame
		_check(practice.hand_size==size and practice.stage==0,"format starts at draw")
		_check(practice.engine.state.players[0].hand.size()==size,"exact initial deal size")
		_check(practice.engine.state.tri_goal==(2 if size==6 else 3),"format follows user's exact goal")
		_check(practice.engine.state.deck.back()==Practice.DRAW_CARD,"completion card is still in the draw pile")
		_check(not practice._action.disabled and practice._action.text=="Piocher une carte","real first action is available")
		_conserves_and_restores("start%d"%size)
		await _rendered_check("tri-tutorial-%d-start"%size)
		var before: Dictionary = practice.engine.export_game()
		_check(not practice.toggle_card(Practice.DISCARD_CARD),"select cannot skip drawing")
		_check(not practice.show_tris() and not practice.discard_selected(),"cannot highlight or discard before drawing")
		_check(practice.engine.export_game()==before,"out-of-order actions do not change the duel")
		_find_button(practice,"Trier").pressed.emit()
		_check(practice.engine.export_game()==before,"sorting is display-only")
		var by_rank: Array = practice.hand_order.duplicate()
		var previous_rank := 0
		for id in by_rank:
			var rank: int = practice.engine.card_info(id).rank
			_check(rank>=previous_rank,"first sort groups equal values")
			previous_rank=rank
		_find_button(practice,"Trier").pressed.emit()
		_check(practice.engine.export_game()==before and practice.hand_order!=by_rank,"second sort changes criterion without touching cards")
		practice._action.pressed.emit()
		_check(practice.stage==1 and practice.engine.state.phase=="play","draw action advances the real engine")
		_check(practice.engine.state.players[0].hand.size()==size+1,"one card was really drawn")
		_check(practice.engine.state.winner==-1,"enough tris before discard is not yet victory")
		_check(practice.engine.tri_groups(practice.engine.state.players[0].hand).size()==int(practice.engine.state.tri_goal),"draw completes the exact target")
		_check(practice.selected.is_empty() and practice._highlighted.is_empty(),"tris are not automatically selected or played")
		_conserves_and_restores("draw%d"%size)
		await _rendered_check("tri-tutorial-%d-draw"%size)
		before = practice.engine.export_game()
		_check(not practice.draw_card() and not practice.toggle_card(Practice.DISCARD_CARD),"one draw only and explicit group-review step")
		_check(practice.engine.export_game()==before,"invalid play remains nonmutating")
		practice._action.pressed.emit()
		_check(practice.stage==2 and practice._highlighted.size()==int(practice.engine.state.tri_goal)*3,"Mes tris highlights distinct private groups")
		_check(practice.engine.export_game()==before,"highlighting never poses or changes any card")
		_check(practice._action.disabled and practice.selected.is_empty(),"one free discard must be chosen")
		_check(not practice.toggle_card("missing"),"unknown card rejected")
		_check(not practice.toggle_card("0:H:7") and practice.selected.is_empty(),"guided lesson explains why to keep a tri card")
		practice.selected.assign(["0:H:7"])
		_check(not practice.discard_selected() and practice.engine.export_game()==before,"even direct invalid selection cannot break a tri or win falsely")
		practice.selected.clear()
		if size==12:
			_check(practice._example.text.contains("3 autres cartes restent libres"),"12-card explanation explicitly leaves three cards free")
			_check(practice.toggle_card("0:H:1") and practice.selected==["0:H:1"],"any free card may be chosen in12-card mode")
			_check(practice.toggle_card(Practice.DISCARD_CARD) and practice.selected==[Practice.DISCARD_CARD],"choosing another discard replaces selection")
		else:
			practice._card_buttons[Practice.DISCARD_CARD].pressed.emit()
			_check(practice.selected==[Practice.DISCARD_CARD],"actual card control chooses the isolated king")
		_check(practice.toggle_card(Practice.DISCARD_CARD) and practice.selected.is_empty(),"discard selection can be cancelled")
		_check(practice.toggle_card(Practice.DISCARD_CARD) and not practice._action.disabled,"free card enables final discard")
		await _rendered_check("tri-tutorial-%d-discard"%size)
		before = practice.engine.export_game()
		_check(practice.engine.state.winner==-1 and completion_events.size()==(0 if size==6 else 1),"exercise still waits for user's final action")
		practice._action.pressed.emit()
		_check(practice.stage==3 and practice.engine.state.winner==0,"real discard wins the real duel")
		_check(practice.engine.state.players[0].hand.size()==size and practice.engine.state.discard.back()==Practice.DISCARD_CARD,"winner keeps all Tri cards in hand")
		_check(practice.engine.view_for(1).winning_tris.size()==(2 if size==6 else 3),"winning tris become public only now")
		_check(completion_events.size()==(1 if size==6 else 2),"completion emits once per explicit success")
		_check(practice._action.disabled,"finished exercise cannot accidentally advance")
		_conserves_and_restores("win%d"%size)
		await _rendered_check("tri-tutorial-%d-win"%size)
		before=practice.engine.export_game()
		_check(not practice.discard_selected() and not practice.draw_card() and not practice.toggle_card("0:H:7"),"finished exercise rejects further play")
		_check(practice.engine.export_game()==before,"finished duel remains unchanged")
		_find_button(practice,"Recommencer").pressed.emit()
		_check(practice.stage==0 and practice.hand_size==size and practice._highlighted.is_empty(),"restart preserves selected format and resets all lesson stages")
		_conserves_and_restores("restart%d"%size)
	_find_button(practice,"Retour").pressed.emit()
	_check(exit_events.size()==1,"return asks the parent to leave")
	practice.start_lesson(9)
	_check(practice.hand_size==6,"unsupported format safely falls back to six")
	practice.queue_free()
	await process_frame
	print("RESULT: %d Tri tutorial checks; %d failures"%[checks,failures.size()])
	quit(0 if failures.is_empty() else 1)

func _find_button(node: Node, text_value: String) -> Button:
	if node is Button and node.text==text_value: return node
	for child in node.get_children():
		var result := _find_button(child,text_value)
		if result != null: return result
	return null

func _rendered_check(label: String) -> void:
	if DisplayServer.get_name()=="headless": return
	for size in [Vector2i(1440,900),Vector2i(2400,1080)]:
		root.size=size
		for _frame in range(8): await process_frame
		await RenderingServer.frame_post_draw
		var viewport := root.get_visible_rect()
		for text in [practice._heading,practice._explanation,practice._example,practice._feedback]:
			_check(viewport.encloses(text.get_global_rect()),label+": explanation stays visible")
		_check(viewport.encloses(practice._action.get_global_rect()),label+": final action accessible")
		for button: Button in practice._card_buttons.values():
			_check(viewport.encloses(button.get_global_rect()),label+": complete card visible")
			_check(button.get_global_rect().position.y>=104,label+": app header remains accessible")
			_check(button.size.y>=140,label+": teaching cards are large enough")
		if "--capture" in OS.get_cmdline_user_args():
			root.get_texture().get_image().save_png("res://builds/%s-%dx%d.png"%[label,size.x,size.y])
