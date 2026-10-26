extends SceneTree
## Rendered 3D regression: the player's held cards must stay large, readable,
## inside common Android landscape viewports, and selectable through picking.
const Scene = preload("res://main.tscn")
var app
var checks := 0
var failures: Array[String] = []
var tap_signals := 0

func _initialize() -> void:
	call_deferred("_run")

func _frames(count: int = 8) -> void:
	for _i in range(count):
		await process_frame
	await RenderingServer.frame_post_draw

func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error("FAIL: " + message)

func _save(name: String) -> void:
	root.get_texture().get_image().save_png("res://builds/" + name + ".png")
	print("CAPTURE ", name, " physical=", root.size, " logical=", root.get_visible_rect().size)

func _card_rect(card: Node3D) -> Rect2:
	var face: MeshInstance3D = card.get_node("Paper/PrintedFace")
	var points: Array[Vector2] = []
	for x in [-0.525, 0.525]:
		for y in [-0.76, 0.76]:
			points.append(app.camera.unproject_position(face.to_global(Vector3(x, y, 0))))
	var rect := Rect2(points[0], Vector2.ZERO)
	for point in points:
		rect = rect.expand(point)
	return rect

func _union(cards: Array) -> Rect2:
	var rect := _card_rect(cards[0])
	for card in cards.slice(1):
		rect = rect.merge(_card_rect(card))
	return rect

func _fixture() -> void:
	app.engine.start_game(["Vous", "Camille", "Alex", "Charlie"], 42)
	app.snapshot = app.engine.view_for(0)
	app.snapshot.your_index = 0
	app.snapshot.melds = []
	for rank in range(2, 10):
		app.snapshot.melds.append({"cards":["0:S:%d" % rank, "0:D:%d" % rank, "0:C:%d" % rank], "owner":1})
	app._render_snapshot()
	app.toast_time = 0.0
	app.toast_label.hide()

func _measure(label: String) -> void:
	var viewport := root.get_visible_rect()
	var hand: Rect2 = _union(app.hand_cards)
	var shortest := 10000.0
	for card in app.hand_cards:
		var rect: Rect2 = _card_rect(card)
		shortest = minf(shortest, rect.size.y)
		_check(rect.size.y >= 200, label + ": upright card height >=200 logical pixels")
		_check(viewport.encloses(rect), label + ": complete hand card lies inside viewport")
		_check(card.face_up, label + ": held card is face up")
	_check(app.hand_cards.size() == 13, label + ": thirteen independent held cards")
	_check(hand.end.y < app.action_row.get_global_rect().position.y, label + ": hand clears action buttons")
	var stage: Array = []
	for card in app.card_nodes:
		if not card.get_meta("hand_card", false):
			stage.append(card)
	_check(stage.size() == 16, label + ": deck/discard plus only latest four three-card melds rendered")
	for card in stage:
		_check(not _card_rect(card).intersects(hand), label + ": public table cards do not overlap held hand")
	var header: HBoxContainer = app.ui.get_child(0)
	for control in header.get_children():
		if control is Control:
			_check(viewport.encloses(control.get_global_rect()), label + ": header control fits viewport")
	print("MEASURE ", label, " shortest_card=", shortest, " hand=", hand, " actions=", app.action_row.get_global_rect())

func _rank_corners(label: String) -> void:
	for card in app.hand_cards:
		var face: MeshInstance3D = card.get_node("Paper/PrintedFace")
		var logical: Vector2 = app.camera.unproject_position(face.to_global(Vector3(-0.37, 0.50, 0)))
		var origin: Vector3 = app.camera.project_ray_origin(logical)
		var direction: Vector3 = app.camera.project_ray_normal(logical)
		var query := PhysicsRayQueryParameters3D.create(origin, origin + direction * 100)
		query.collide_with_areas = true
		query.collide_with_bodies = false
		var hit: Dictionary = app.get_world_3d().direct_space_state.intersect_ray(query)
		_check(not hit.is_empty() and hit.collider.get_parent() == card, label + ": every top-left rank corner can be picked without another card covering it")

func _physics_tap() -> void:
	tap_signals = 0
	var card: Node3D = app.hand_cards[0]
	card.tapped.connect(func(_card): tap_signals += 1)
	var face: MeshInstance3D = card.get_node("Paper/PrintedFace")
	var local_point := Vector3(-0.37, 0.50, 0.0)
	var logical: Vector2 = app.camera.unproject_position(face.to_global(local_point))
	var physical: Vector2 = root.get_final_transform() * logical
	var before := _card_rect(card)
	var motion := InputEventMouseMotion.new()
	motion.position = physical
	motion.global_position = physical
	Input.parse_input_event(motion)
	await physics_frame
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = physical
	press.global_position = physical
	Input.parse_input_event(press)
	await physics_frame
	await physics_frame
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	release.position = physical
	release.global_position = physical
	Input.parse_input_event(release)
	await _frames(12)
	_check(tap_signals == 1, "actual physics picking emits exactly one card tap")
	_check(app.selected == [card.card_id], "actual physics picking selects the visible corner's exact card")
	var after := _card_rect(card)
	_check(after.position.y < before.position.y - 10, "selected held card lifts upward by >10 logical pixels")
	print("PICK logical=", logical, " physical=", physical, " signals=", tap_signals, " before=", before, " after=", after)

func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("Rendered test requires DISPLAY and a graphics driver")
		quit(2)
		return
	app = Scene.instantiate()
	root.add_child(app)
	app._set_fullscreen(false, false)
	root.size = Vector2i(1440, 900)
	await _frames()
	app._start_solo()
	_fixture()
	await _frames()
	_measure("1440x900")
	_rank_corners("1440x900")
	await _physics_tap()
	_save("game-held-hand")
	app._show_lessons(1)
	await _frames()
	_save("guide-detail")
	app._show_coach()
	await _frames()
	_save("coach")
	app._show_music_settings()
	await _frames()
	_save("music-settings")
	app._close_overlay()
	root.size = Vector2i(2400, 1080)
	await _frames()
	app.selected.clear()
	app._render_snapshot()
	await _frames()
	_measure("2400x1080 20:9")
	_rank_corners("2400x1080 20:9")
	await _physics_tap()
	_save("game-phone-wide")
	app.network.leave_room()
	app.queue_free()
	await create_timer(0.25).timeout
	await process_frame
	print("RESULT ", checks, " checks; ", failures.size(), " failures")
	for failure in failures:
		print("FAILED: ", failure)
	quit(0 if failures.is_empty() else 1)
