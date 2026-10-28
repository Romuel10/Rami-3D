extends SceneTree
const Main = preload("res://main.tscn")
const Store = preload("res://scripts/solo_store.gd")
var checks := 0
func _init() -> void: call_deferred("_run")
func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		push_error(message)
		quit(1)
		assert(value,message)
func button(node: Node, text: String) -> Button:
	if node is Button and node.text == text: return node
	for child in node.get_children():
		var found := button(child,text)
		if found != null: return found
	return null
func _run() -> void:
	var app = Main.instantiate()
	root.add_child(app)
	await process_frame
	check(button(app.ui,"Jouer au Tri   →") != null,"real Tri menu entry exists")
	button(app.ui,"Jouer au Tri   →").pressed.emit()
	check(button(app.overlay,"Tri contre l’ordinateur") != null and button(app.overlay,"Tri avec un ami") != null,"duel setup includes AI and friends")
	for size in [6,12]:
		app.tri_choice = size
		button(app.overlay,"Tri contre l’ordinateur").pressed.emit()
		app.animations_enabled = false
		app._apply_comfort()
		check(app.game_mode=="solo" and app._is_tri() and app.hand_cards.size()==size,"actual Tri solo deal")
		check(app.snapshot.players.size()==2 and app.snapshot.tri_goal==(2 if size==6 else 3),"correct private duel and target")
		check(button(app.action_row,"Poser")==null and button(app.action_row,"Compléter")==null,"no misleading rummy pose controls")
		check(button(app.action_row,"Trier ♠")!=null and button(app.action_row,"Mes tris")!=null,"sorting and own-tris controls available")
		var before: Dictionary = app.engine.export_game()
		button(app.action_row,"Trier ♠").pressed.emit()
		check(app.engine.export_game()==before,"sorting cannot change rules or cards")
		var expected: Array = app.snapshot.hand.duplicate()
		expected.sort_custom(func(a,b): return app._sort_key(a)<app._sort_key(b))
		check(app.hand_order==expected,"real sort button orders hand by selected criterion")
		button(app.action_row,"Trier ♠").pressed.emit()
		check(app.engine.export_game()==before,"second sort preserves complete game")
		app._act({"type":"draw","source":"deck"})
		check(app.snapshot.hand.size()==size+1,"real draw adds a card")
		app._show_coach()
		check(app.overlay_kind=="tri_rules","coach explains Tri instead of rummy opening")
		app._close_overlay()
		button(app.action_row,"Mes tris").pressed.emit()
		check(app.engine.state.melds.is_empty() and app.snapshot.hand.size()==size+1,"highlighting tris never poses or discards")
		if DisplayServer.get_name() != "headless":
			app._set_fullscreen(false,false)
			for screen in [Vector2i(1440,900),Vector2i(2400,1080)]:
				root.size = screen
				await create_timer(.25).timeout
				app._layout_hand(false)
				await process_frame
				for card in app.hand_cards:
					var face: MeshInstance3D = card.get_node("Paper/PrintedFace")
					var rect := Rect2()
					var first := true
					for x in [-.5,.5]:
						for y in [-.75,.75]:
							var point: Vector2 = app.camera.unproject_position(face.to_global(Vector3(x,y,0)))
							if first: rect = Rect2(point,Vector2.ZERO); first=false
							else: rect = rect.expand(point)
					check(root.get_visible_rect().encloses(rect),"all held Tri cards fit the screen")
					check(rect.end.y<app.action_row.get_global_rect().position.y,"Tri hand clears action buttons")
				await process_frame
				root.get_texture().get_image().save_png("res://builds/tri-%d-%dx%d.png"%[size,screen.x,screen.y])
		app._autosave()
		check(not Store.load_game().is_empty(),"Tri autosave is valid")
		app._leave_to_menu()
		app._resume_solo()
		check(app._is_tri() and app.snapshot.phase=="play" and app.snapshot.hand.size()==size+1,"resume preserves Tri mode and midturn")
		app.selected = [app.snapshot.hand[0]]
		app._discard_selected()
		check(app.engine.state.players[0].hand.size()==size,"real discard returns to deal size")
		app._leave_to_menu()
		app._show_tri_setup()
	app._start_solo(6)
	var winning: Array = ["0:H:7","1:H:7","0:C:7","0:S:8","0:C:8","0:D:8"]
	var pool: Array = app.engine.state.deck + app.engine.state.discard
	for player in app.engine.state.players: pool.append_array(player.hand)
	for id in winning: pool.erase(id)
	app.engine.state.players[0].hand = winning
	app.engine.state.players[1].hand = pool.slice(0,6)
	pool = pool.slice(6)
	app.engine.state.discard = [pool.pop_front()]
	app.engine.state.deck = pool
	app._refresh_snapshot()
	app._act({"type":"draw","source":"deck"})
	app.selected = [app.engine.state.players[0].hand.back()]
	app._discard_selected()
	check(app.snapshot.winner==0 and app.overlay_kind=="winner","real discard opens Tri victory modal")
	check(app._winner_result().title=="Tri : victoire !" and app.snapshot.winning_tris.size()==2,"result explains actual Tri victory")
	check(app.hand_cards.size()==6 and app.engine.state.melds.is_empty(),"winner keeps cards in hand")
	button(app.overlay,"Nouvelle partie").pressed.emit()
	check(app._is_tri() and app.snapshot.tri_hand_size==6,"new game keeps Tri format")
	app._leave_to_menu()
	await create_timer(1.0).timeout
	app.queue_free()
	await process_frame
	await create_timer(0.5).timeout
	print("PASS: %d Tri UI checks" % checks)
	quit()
