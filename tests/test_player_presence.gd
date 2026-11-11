extends SceneTree
## Visible portraits, live public gestures and motion controls on the real table.
const Main = preload("res://main.tscn")
const Profile = preload("res://scripts/player_profile.gd")
var app
var checks := 0

func _initialize() -> void: call_deferred("_run")

func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		push_error(message)
		quit(1)
		assert(value, message)

func _frames() -> void:
	for frame in range(8): await process_frame
	await physics_frame
	if DisplayServer.get_name() != "headless": await RenderingServer.frame_post_draw

func _button(node: Node, text: String) -> Button:
	if node is Button and node.text == text: return node
	for child in node.get_children():
		var found := _button(child, text)
		if found != null: return found
	return null

func _mesh_rect(mesh: MeshInstance3D) -> Rect2:
	var vertices := mesh.mesh.get_faces()
	var rect := Rect2(app.camera.unproject_position(mesh.to_global(vertices[0])),Vector2.ZERO)
	for vertex in vertices: rect = rect.expand(app.camera.unproject_position(mesh.to_global(vertex)))
	return rect

func _view(count: int, own: int) -> Dictionary:
	var players: Array = []
	for index in range(count): players.append({"name":["Mika","Aina","Hery","Soa"][index],"count":13,"opened":false})
	return {"players":players,"your_index":own,"turn":own,"phase":"draw","winner":-1,"hand":["0:H:7","0:H:8","0:H:9","0:S:2","0:D:2","0:C:2","0:S:13","0:C:13","0:D:4","0:D:5","0:D:6","0:C:10","0:S:11"],"melds":[],"deck_count":50,"discard_top":"1:D:1","session_id":"players-geometry","revision":0}

func _run() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("player","name","Mika")
	cfg.set_value("player","province","Antananarivo")
	cfg.set_value("comfort","animations",false)
	cfg.set_value("music","settings",{"enabled":false,"volume":0.0,"track_index":0})
	check(Profile.save_preferences(cfg),"isolated player preferences created")
	app = Main.instantiate()
	root.add_child(app)
	await process_frame
	app.animations_enabled = true
	app.bot_count = 3
	app._start_solo()
	var table: Node3D = app.table_scene
	check(table._seats.size() == 3 and table.is_processing(),"three seated opponents are animated by default")
	for seat in table._seats.values():
		var head: Node3D = seat.get_node("Sleeves/HeadRig")
		check(head.get_node("Skin") is MeshInstance3D and head.get_node("Eyes/Pupils") is MeshInstance3D,"each opponent has a real face and eyes")
	var state_before: Dictionary = app.engine.export_game()
	var meshes: Array = table.find_children("*","MeshInstance3D",true,false).map(func(mesh): return mesh.get_instance_id())
	var head: Node3D = table._seats[1].get_node("Sleeves/HeadRig")
	var pose_before := head.transform
	await create_timer(.35).timeout
	check(not head.transform.is_equal_approx(pose_before),"waiting players move their gaze instead of freezing")
	check(app.engine.export_game() == state_before,"idle animation leaves the complete match unchanged")
	check(table.find_children("*","MeshInstance3D",true,false).map(func(mesh): return mesh.get_instance_id()) == meshes,"idle movement reuses the existing meshes")
	table.set_animation_paused(true)
	check(not table.is_processing() and table._gestures.is_empty() and head.rotation == Vector3.ZERO,"background pause cancels gestures and restores the rig")
	await create_timer(.12).timeout
	check(head.rotation == Vector3.ZERO,"a suspended table remains still")
	table.set_animation_paused(false)
	check(table.is_processing(),"returning to the game resumes waiting movement")
	app.economy_mode = true
	app._apply_performance()
	check(not table.motion_enabled and not table.is_processing(),"battery saver stops all player movement")
	app.economy_mode = false
	app._apply_performance()
	check(table.motion_enabled and table.is_processing(),"normal rendering restores the user's movement preference")
	app._show_comfort_settings()
	var people := _button(app.overlay,"Joueurs animés autour de la table") as CheckButton
	check(people != null and people.button_pressed,"player movement has a separate accessible setting")
	people.button_pressed = false
	check(not app.player_animations_enabled and not table.is_processing(),"the real setting immobilizes the portraits immediately")
	people.button_pressed = true
	app._close_overlay()
	app.engine.state.turn = 1
	app.engine.state.phase = "draw"
	check(app.engine.apply_action(1,{"type":"draw","source":"deck"}).ok,"an opponent performs a real legal draw")
	app.snapshot = app.engine.view_for(0)
	app._render_snapshot()
	check(table._gesture_kinds.get(1) == "draw:deck","a public draw reaches the avatar animation")
	var serial: int = table._gesture_serials[1]
	app._render_snapshot()
	check(table._gesture_serials[1] == serial,"a repeated snapshot does not replay the draw")
	app.snapshot["winner"] = 1
	app.snapshot.players[1].count = 0
	app.snapshot["match_result"] = {"finished":true,"winners":[1],"forfeit":false}
	app.snapshot.revision += 1
	app._render_snapshot()
	check(table._gesture_kinds.get(1) == "celebrate:deck" and table._gesture_kinds.get(2) == "react:deck","the authoritative result starts distinct winner and opponent reactions")
	var result_serial: int = table._gesture_serials[1]
	app._render_snapshot()
	check(table._gesture_serials[1] == result_serial,"result refreshes do not restart the celebration")
	await create_timer(1.2).timeout
	check(table._gestures.is_empty(),"end-of-round reactions finish without looping")
	app._leave_to_menu()
	check(not table.is_processing() and table._seats.is_empty(),"leaving removes the portraits and stops their animation")
	app.animations_enabled = false
	app._apply_comfort()
	app.game_mode = "online"
	for screen in [Vector2i(1440,900),Vector2i(2400,1080)]:
		root.size = screen
		for count in [2,3,4]:
			for own in range(count):
				app.snapshot = _view(count,own)
				app._show_game()
				app._render_snapshot()
				await _frames()
				for player in table._seats:
					var face: Node3D = table._seats[player].get_node("Sleeves/HeadRig")
					var portrait := _mesh_rect(face.get_node("Skin")).merge(_mesh_rect(face.get_node("Hair")))
					var eyes := _mesh_rect(face.get_node("Eyes/EyeWhite"))
					check(root.get_visible_rect().encloses(portrait),"the complete portrait fits " + str([screen,count,own,player]))
					check(portrait.position.y > app._header.get_global_rect().end.y,"the header leaves the portrait visible " + str([screen,count,own,player,portrait,app._header.get_global_rect()]))
					check(portrait.size.y >= 35,"opponent portraits stay readable")
					check(not eyes.intersects(app.players_row.get_global_rect()),"the player chips leave the face visible")
					for card in app.card_nodes:
						if card.get_meta("zone","") == "opponent" and card.get_meta("seat_index",-1) == player:
							check(not card.face_up,"animation keeps each opponent card private")
							var card_rect := _mesh_rect(card.get_node("Paper/PrintedFace"))
							check(not eyes.intersects(card_rect),"the held cards leave the eyes visible " + str([screen,count,own,player,eyes,card_rect]))
				if own == 0 and DisplayServer.get_name() != "headless":
					DirAccess.make_dir_recursive_absolute("res://builds")
					root.get_texture().get_image().save_png("res://builds/players-%d-%dx%d.png" % [count,screen.x,screen.y])
	app.game_mode = "menu"
	app.player_animations_enabled = false
	app._save_preferences()
	app.queue_free()
	await process_frame
	app = Main.instantiate()
	root.add_child(app)
	await process_frame
	check(not app.player_animations_enabled,"the player's animation preference survives a fresh launch")
	app.queue_free()
	await process_frame
	print("PASS: %d player presence checks" % checks)
	quit(0)
