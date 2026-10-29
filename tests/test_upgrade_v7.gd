extends SceneTree
const Main = preload("res://main.tscn")
const Groups = preload("res://scripts/hand_groups.gd")
const Profile = preload("res://scripts/server_profile.gd")
var checks := 0
func _init() -> void: call_deferred("_run")
func check(value: bool, text: String) -> void:
	checks += 1
	if not value:
		push_error(text)
		quit(1)
		assert(value,text)
func find_button(node: Node, text: String) -> Button:
	if node is Button and node.text==text: return node
	for child in node.get_children():
		var value := find_button(child,text)
		if value != null: return value
	return null
func _run() -> void:
	check(Profile.normalise("https://table.vercel.app")=="wss://table.vercel.app/api/ws","Vercel HTTPS URL becomes WebSocket endpoint")
	check(Profile.normalise("wss://table.vercel.app/")=="wss://table.vercel.app/api/ws","base Vercel WSS URL is completed")
	check(Profile.normalise("wss://jeu.exemple.fr/salon")=="wss://jeu.exemple.fr/salon","custom WS path preserved")
	for invalid in ["", "https://nom:pass@jeu.fr", "ftp://jeu.fr", "https://jeu.fr#token", "https://jeu.fr:99999", "https://jeu.fr/ espace"]:
		check(Profile.normalise(invalid).is_empty(),"invalid public endpoint rejected")
	var hand: Array = ["0:H:7","0:S:8","0:C:9","1:H:7","0:C:8","0:D:9","0:C:7","0:D:8","0:S:9","0:S:1","0:D:2","0:H:3"]
	var result: Dictionary = Groups.arrange(hand,true)
	check(result.cards.size()==hand.size() and result.groups.size()==3 and result.boundaries==[3,6,9],"three groups and free cards separated")
	check(Groups.arrange(hand,false).cards==hand and Groups.arrange(hand,false).boundaries.is_empty(),"manual layout unchanged when grouping disabled")
	for group in result.groups:
		check(group.size()==3,"each physical tri counted exactly once")
	var app = Main.instantiate()
	root.add_child(app)
	await process_frame
	app._start_solo(12)
	app.animations_enabled = false
	app._apply_comfort()
	var pool: Array = app.engine.state.deck + app.engine.state.discard
	for player in app.engine.state.players: pool.append_array(player.hand)
	for id in hand: pool.erase(id)
	app.engine.state.players[0].hand = hand.duplicate()
	app.engine.state.players[1].hand = pool.slice(0,12)
	pool = pool.slice(12)
	app.engine.state.discard = [pool.pop_front()]
	app.engine.state.deck = pool
	app.hand_order.clear()
	app._refresh_snapshot()
	var before: Dictionary = app.engine.export_game()
	find_button(app.action_row,"Regrouper mes tris").pressed.emit()
	check(app.tri_grouping_enabled and app._tri_boundaries==[3,6,9],"real group button groups private cards")
	check(app.engine.export_game()==before and app.snapshot.melds.is_empty(),"grouping leaves engine and table untouched")
	check(app.hand_order.size()==12,"group layout retains every held card")
	for i in [3,6,9]:
		var gap: float = app.hand_cards[i].motion_target.origin.x-app.hand_cards[i-1].motion_target.origin.x
		var normal: float = app.hand_cards[1].motion_target.origin.x-app.hand_cards[0].motion_target.origin.x
		check(gap>normal+0.4,"visible physical separation between groups")
	if DisplayServer.get_name()!="headless":
		app._set_fullscreen(false,false)
		for screen in [Vector2i(1440,900),Vector2i(2400,1080)]:
			root.size = screen
			await create_timer(.2).timeout
			app._layout_hand(false)
			await process_frame
			await physics_frame
			await RenderingServer.frame_post_draw
			for card in app.hand_cards:
				var face: MeshInstance3D = card.get_node("Paper/PrintedFace")
				for x in [-.525,.525]:
					for y in [-.76,.76]:
						var point: Vector2 = app.camera.unproject_position(face.to_global(Vector3(x,y,0)))
						check(root.get_visible_rect().has_point(point),"grouped hand corners fit the screen")
						check(point.y<app.action_row.get_global_rect().position.y,"grouped hand avoids play buttons")
			root.get_texture().get_image().save_png("res://builds/tri-groups-%dx%d.png"%[screen.x,screen.y])
	app._show_comfort_settings()
	var economy = find_button(app.overlay,"Économie de batterie · 30 images/s, sans ombres")
	check(economy is CheckButton,"economy choice available")
	economy.button_pressed = true
	check(app.economy_mode and Engine.max_fps==30 and not app._key_light.shadow_enabled,"economy reduces FPS and shadows")
	economy.button_pressed = false
	check(Engine.max_fps==60 and app._key_light.shadow_enabled,"normal quality restored")
	app._close_overlay()
	app._sort_hand()
	check(not app.tri_grouping_enabled and app._tri_boundaries.is_empty(),"standard sort returns to free layout")
	app._leave_to_menu()
	app.saved_address = "https://table.vercel.app"
	app._show_friends(true)
	check(not app.address_input.visible and app.address_input.text=="wss://table.vercel.app/api/ws","remembered server enables code-only entry")
	find_button(app.overlay,"Changer de serveur").pressed.emit()
	check(app.address_input.visible,"public server can be changed")
	app._close_overlay()
	app.saved_address = ""
	app._show_friends(true)
	check(app.address_input.visible,"no invented public host if none configured")
	app._close_overlay()
	app.tri_choice = 12
	app._show_tri_setup()
	find_button(app.overlay,"Apprendre le Tri pas à pas").pressed.emit()
	check(app.game_mode=="tutorial" and app.content.get_child_count()>0,"tutorial opens from actual Tri setup")
	var tutorial = app.content.get_child(app.content.get_child_count()-1)
	check(tutorial.hand_size==12 and tutorial.engine.state.tri_hand_size==12,"tutorial uses selected twelve-card format")
	tutorial.exit_requested.emit()
	check(app.game_mode=="menu","tutorial returns safely to menu")
	await create_timer(.8).timeout
	app.queue_free()
	await process_frame
	await create_timer(.5).timeout
	print("PASS: %d upgrade UI checks"%checks)
	quit()
