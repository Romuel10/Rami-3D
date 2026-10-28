extends SceneTree
## Real scene regression: textured table, opponents seated around it, private
## held backs, and the player's readable cards and picking on two phone formats.
const MainScene = preload("res://main.tscn")
var app
var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures.append(message)
		push_error("FAIL: " + message)

func _settle() -> void:
	var deadline := Time.get_ticks_msec() + 2500
	while app.card_nodes.any(func(card): return card.is_moving()) and Time.get_ticks_msec() < deadline:
		await process_frame
	await process_frame
	await physics_frame
	if DisplayServer.get_name() != "headless":
		await RenderingServer.frame_post_draw

func _view(player_count: int = 4) -> Dictionary:
	var players: Array = []
	for index in range(player_count):
		players.append({"name":["Vous","Camille","Alex","Charlie"][index], "count":13,"opened":false})
	return {
		"your_index":0,"turn":0,"phase":"draw","winner":-1,
		"players":players,"hand":["0:H:7","0:H:8","0:H:9","0:S:2","0:D:2","0:C:2","0:S:13","0:C:13","0:D:4","0:D:5","0:D:6","0:C:10","0:S:11"],
		"deck_count":55,"discard_top":"1:D:1","melds":[],"turn_count":1,"session_id":"table-realism","revision":0
	}

func _card_rect(card: Node3D) -> Rect2:
	var printed: MeshInstance3D = card.get_node("Paper/PrintedFace")
	var points: Array[Vector2] = []
	for x in [-0.525,0.525]:
		for y in [-0.76,0.76]:
			points.append(app.camera.unproject_position(printed.to_global(Vector3(x,y,0))))
	var rect := Rect2(points[0],Vector2.ZERO)
	for point in points: rect = rect.expand(point)
	return rect

func _geometry_contract() -> void:
	var table: Node = app.get_node_or_null("TableScene")
	_check(table is Node3D,"one persistent 3D table environment exists")
	if table == null: return
	for child in ["FeltSurface","WoodBase","LeatherRail"]:
		var mesh: Node = table.get_node_or_null(child)
		_check(mesh is MeshInstance3D,"table has physical " + child + " geometry")
		if not mesh is MeshInstance3D: continue
		var material: Material = mesh.material_override
		_check(material is StandardMaterial3D,"table surface has a mobile-compatible material")
		if material is StandardMaterial3D:
			if child in ["FeltSurface","WoodBase"]:
				_check(material.albedo_texture != null,"table " + child + " has material grain rather than a flat fill")
			_check(material.roughness > 0.15 and material.roughness <= 1.0,"surface roughness stays physically plausible")
	var seating: Node = table.get_node_or_null("Seating")
	_check(seating != null and seating.get_child_count()>0,"seating gives opponents a physical place at the table")
	_check(table.find_children("*","CollisionObject3D",true,false).is_empty(),"decor has no picking collisions that can capture a card tap")
	_check(not app.card_nodes.any(func(card): return table.is_ancestor_of(card)),"decor remains independent from public/private card reconciliation")

func _opponent_contract(label: String) -> void:
	var centers: Dictionary = {}
	var opponents: Array = app.card_nodes.filter(func(card): return card.get_meta("zone","") == "opponent")
	_check(opponents.size() == 39,label + ": all three opponents retain their public card count")
	for player in range(1,4):
		var fan: Array = opponents.filter(func(card): return int(card.get_meta("seat_index",-1)) == player)
		_check(fan.size()==13,label + ": each fan belongs to its player seat")
		if fan.is_empty(): continue
		var center := Vector3.ZERO
		for card in fan:
			_check(not card.face_up,label + ": opponent card exposes its back only")
			_check(card._area.collision_layer == 0 and not card._area.input_ray_pickable,label + ": opponent back cannot intercept input")
			_check(not card.get_meta("hand_card",false),label + ": own-hand gestures are not attached to an opponent")
			center += card.global_position
		centers[player] = center/fan.size()
		var middle: Node3D = fan[int(fan.size()/2)]
		_check(absf(middle.global_basis.y.normalized().dot(Vector3.UP))<0.94,label + ": opponent cards are held at an angle rather than lying flat")
		var projected := _card_rect(middle)
		_check(projected.size.y >= 35,label + ": held opponent fan is visibly upright")
	if centers.size()==3:
		_check(centers[1].distance_to(centers[2])>2 and centers[2].distance_to(centers[3])>2,label + ": opponents occupy distinct places around the table")
		var rows := [centers[1].z,centers[2].z,centers[3].z]
		_check(float(rows.max())-float(rows.min())>0.75,label + ": seating uses table depth rather than a single row")

func _own_hand_contract(label: String) -> void:
	var viewport := root.get_visible_rect()
	_check(app.hand_cards.size()==13,label + ": private hand retains thirteen cards")
	for card in app.hand_cards:
		var rect := _card_rect(card)
		_check(viewport.encloses(rect),label + ": entire held card remains inside viewport")
		_check(rect.size.y>=200,label + ": own cards remain large and readable")
		_check(rect.end.y<app.action_row.get_global_rect().position.y,label + ": held hand clears the play controls")
		var printed: MeshInstance3D = card.get_node("Paper/PrintedFace")
		var corner: Vector2 = app.camera.unproject_position(printed.to_global(Vector3(-0.37,0.50,0)))
		var origin: Vector3 = app.camera.project_ray_origin(corner)
		var query := PhysicsRayQueryParameters3D.create(origin,origin+app.camera.project_ray_normal(corner)*100,1)
		query.collide_with_areas = true
		query.collide_with_bodies = false
		var hit: Dictionary = app.get_world_3d().direct_space_state.intersect_ray(query)
		_check(not hit.is_empty() and hit.collider.get_parent()==card,label + ": visible rank corner picks its exact card")

func _run() -> void:
	app = MainScene.instantiate()
	root.add_child(app)
	await process_frame
	app._set_fullscreen(false,false)
	app.animations_enabled = false
	app.network.local_player = 0
	var view := _view()
	app._network_game_updated(view.duplicate(true))
	await _settle()
	_geometry_contract()
	if DisplayServer.get_name() != "headless":
		for size in [Vector2i(1440,900),Vector2i(2400,1080)]:
			root.size = size
			await process_frame
			app._screen_changed()
			await _settle()
			_opponent_contract(str(size))
			_own_hand_contract(str(size))
			app.toast_label.hide()
			root.get_texture().get_image().save_png("res://builds/table-realism-%dx%d.png" % [size.x,size.y])
	# Repeated snapshots keep meshes and do not allocate a fresh room or fan.
	var table_id: int = app.get_node("TableScene").get_instance_id() if app.has_node("TableScene") else 0
	var ids: Dictionary = {}
	for key in app._view_cards: ids[key] = app._view_cards[key].get_instance_id()
	app._network_game_updated(view.duplicate(true))
	await _settle()
	_check(app.get_node("TableScene").get_instance_id()==table_id if app.has_node("TableScene") else false,"unchanged state retains the same table environment")
	for key in ids:
		_check(app._view_cards[key].get_instance_id()==ids[key],"unchanged state reuses visible card meshes")
	# A remote telephone can be player two while still seeing its own hand in
	# the foreground; fans are associated with public player indices correctly.
	app.network.local_player = 2
	app._network_game_updated(_view())
	await _settle()
	var remote_fans: Array = app.card_nodes.filter(func(card): return card.get_meta("zone","")=="opponent")
	_check(remote_fans.size()==39 and app.hand_cards.size()==13,"a non-host telephone retains its private foreground hand and three opponents")
	_check(not remote_fans.any(func(card): return int(card.get_meta("seat_index",-1))==2),"local player is never duplicated in an opponent seat")
	for player in [0,1,3]:
		_check(remote_fans.filter(func(card): return int(card.get_meta("seat_index",-1))==player).size()==13,"remote seat mapping preserves each other player's public count")
	app.network.local_player = 0
	var departed := _view()
	departed.players[1]["forfeited"] = true
	app._network_game_updated(departed)
	await _settle()
	var remaining_backs: Array = app.card_nodes.filter(func(card): return card.get_meta("zone","")=="opponent")
	_check(not remaining_backs.any(func(card): return int(card.get_meta("seat_index",-1))==1),"a forfeited opponent no longer leaves floating card backs")
	for player in [2,3]:
		_check(remaining_backs.filter(func(card): return int(card.get_meta("seat_index",-1))==player).size()==13,"forfeit leaves the other opponents' card counts intact")
	var sleeves: Node3D = app.get_node("TableScene/Seating/PlayerSeat1/Sleeves")
	_check(not sleeves.visible,"the forfeited opponent's arms are hidden with its card fan")
	# A duel must remove the other seats' card fans without importing private data.
	app._network_game_updated(_view(2))
	await _settle()
	_check(app.card_nodes.filter(func(card): return card.get_meta("zone","")=="opponent").size()==13,"switching to a duel leaves exactly one hidden fan")
	_check(not app.snapshot.players.any(func(player): return player.has("hand")),"opponents are represented by public summaries only")
	app._leave_to_menu()
	app.queue_free()
	await process_frame
	await create_timer(0.5).timeout
	print("RESULT: %d table-realism checks; %d failures" % [checks,failures.size()])
	quit(0 if failures.is_empty() else 1)
