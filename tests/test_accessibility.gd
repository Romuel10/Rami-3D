extends SceneTree
## Exercise the actual comfort controls, saved preferences and card layout.
## Optional rendered checks measure the largest and smallest hand on phones.
const MainScene = preload("res://main.tscn")
const Practice = preload("res://scripts/tutorial_practice.gd")
const USER_FILES := ["user://preferences.cfg", "user://solo-v1.save", "user://solo-v1.save.bak", "user://solo-v1.save.tmp", "user://stats-v1.save", "user://stats-v1.save.bak", "user://stats-v1.save.tmp"]
var app
var checks := 0
var failures: Array[String] = []
var originals: Dictionary = {}

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error("FAIL: " + message)

func _run() -> void:
	for path in USER_FILES:
		if FileAccess.file_exists(path): originals[path] = FileAccess.get_file_as_bytes(path)
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://preferences.cfg"))
	app = MainScene.instantiate()
	root.add_child(app)
	await process_frame
	_check(app.animations_enabled and not app.left_handed and is_equal_approx(app.hand_scale_factor,1.0), "first launch uses the readable standard hand and normal motion")
	app._start_solo()
	_check(app.hand_cards.size() == 13 and app.card_nodes.any(func(card): return card.is_moving()), "initial deal is moving before the comfort switch")
	var initial_cards: Dictionary = app._view_cards.duplicate()
	var state_before: Dictionary = app.engine.export_game()
	app._show_comfort_settings()
	var motion = _find_text(app.overlay,"Animations des cartes et transitions")
	var handed = _find_text(app.overlay,"Mode gaucher · actions principales à gauche")
	var slider = _find_type(app.overlay,"HSlider")
	_check(motion is CheckButton and handed is CheckButton and slider is HSlider, "comfort modal exposes working motion, handedness and hand-size controls")
	if motion == null or handed == null or slider == null:
		await _finish()
		return
	_check(slider.min_value == 85 and slider.max_value == 105, "hand-size slider stays within its verified readable range")
	motion.button_pressed = false
	_check(not app.animations_enabled and not app.card_nodes.any(func(card): return card.is_moving()), "motion switch immediately settles every current card flight")
	for key in initial_cards:
		_check(app._view_cards.get(key) == initial_cards[key] and bool(initial_cards[key].get_meta("reduced_motion",false)), "motion preference updates each retained card without replacing it")
	var base: Array = app.action_buttons_base.duplicate()
	handed.button_pressed = true
	var reverse: Array = base.duplicate()
	reverse.reverse()
	_check(app.left_handed and app.action_row.get_children() == reverse, "left-handed switch reverses the actual action buttons")
	handed.button_pressed = false
	_check(app.action_row.get_children() == base, "switching back restores the original action order")
	handed.button_pressed = true
	slider.value = 105
	_check(is_equal_approx(app.hand_scale_factor,1.05), "largest hand choice applies immediately")
	_check(app.engine.export_game() == state_before, "comfort controls preserve the cards, random state and game rules")
	for card in app.hand_cards:
		_check(is_equal_approx(card.scale.x,app.HAND_SCALE*1.05) and not card.is_moving(), "largest hand uses the requested scale without a transition")
	app._close_overlay()
	app._render_snapshot()
	_check(app.play_buttons.all(func(button): return button.disabled), "draw phase disables play controls even after reversing the button order")
	_check(not _find_text(app.action_row,"Trier ♠").disabled, "sorting remains available in draw phase for a left-handed player")
	app._act({"type":"draw","source":"deck"})
	_check(app.snapshot.hand.size() == 14 and not app.card_nodes.any(func(card): return card.is_moving()), "newly drawn card also respects reduced motion")
	_check(app.play_buttons.all(func(button): return not button.disabled), "play phase enables the correct controls with reversed actions")
	var chosen: Node3D = app.hand_cards[0]
	chosen.tapped.emit(chosen)
	_check(app.selected == [chosen.card_id] and not chosen.is_moving() and chosen.transform.is_equal_approx(chosen.motion_target), "card selection remains immediate and exact with reduced motion")
	chosen.tapped.emit(chosen)
	_check(app.selected.is_empty() and not chosen.is_moving(), "deselection also completes without movement")

	if DisplayServer.get_name() != "headless":
		app._set_fullscreen(false,false)
		for screen in [Vector2i(1440,900),Vector2i(2400,1080)]:
			root.size = screen
			await _frames()
			for factor in [0.85,1.05]:
				app.hand_scale_factor = factor
				app._apply_comfort()
				await _frames()
				_measure_hand(str(screen) + " at " + str(factor))
			if screen == Vector2i(2400,1080):
				root.get_texture().get_image().save_png("res://builds/accessibility-phone-wide.png")
				app._show_comfort_settings()
				await _frames()
				root.get_texture().get_image().save_png("res://builds/accessibility-comfort.png")
				app._close_overlay()
	app.hand_scale_factor = 1.05
	app._save_preferences()
	app._leave_to_menu()
	app.queue_free()
	await create_timer(0.5).timeout
	app = MainScene.instantiate()
	root.add_child(app)
	await process_frame
	_check(not app.animations_enabled and app.left_handed and is_equal_approx(app.hand_scale_factor,1.05), "all three comfort preferences survive a fresh scene launch")
	app._start_solo()
	_check(not app.card_nodes.any(func(card): return card.is_moving()), "fresh scene honors reduced motion from the initial deal")
	var restored_order: Array = app.action_buttons_base.duplicate()
	restored_order.reverse()
	_check(app.action_row.get_children() == restored_order, "fresh scene restores the left-handed action order")
	app._leave_to_menu()
	var tutorial_button = _find_text(app.ui,"Je débute : jouer mon premier tour")
	_check(tutorial_button is Button, "menu exposes the playable first-turn tutorial")
	if tutorial_button is Button:
		tutorial_button.pressed.emit()
		_check(app.game_mode == "tutorial" and app.content.get_child_count() == 1 and app.content.get_child(0) is Practice, "first-turn menu button opens the real guided exercise")
		var practice = app.content.get_child(0)
		_check(practice.stage == 0 and practice.engine.state.phase == "draw", "integrated tutorial starts at the actual first draw")
		practice.exit_requested.emit()
		_check(app.game_mode == "menu", "integrated tutorial return signal reaches the menu")
	var cfg := ConfigFile.new()
	cfg.load("user://preferences.cfg")
	cfg.set_value("comfort","hand_scale",100)
	cfg.save("user://preferences.cfg")
	app._load_preferences()
	_check(is_equal_approx(app.hand_scale_factor,1.05), "oversized saved hand preference is safely clamped on load")
	cfg.set_value("comfort","hand_scale",-100)
	cfg.save("user://preferences.cfg")
	app._load_preferences()
	_check(is_equal_approx(app.hand_scale_factor,0.85), "undersized saved hand preference is safely clamped on load")
	await _finish()

func _frames() -> void:
	for _i in range(6): await process_frame
	await RenderingServer.frame_post_draw

func _measure_hand(label: String) -> void:
	var viewport := root.get_visible_rect()
	var lowest := -INF
	for card in app.hand_cards:
		var face: MeshInstance3D = card.get_node("Paper/PrintedFace")
		var rect := Rect2(app.camera.unproject_position(face.to_global(Vector3(-0.525,-0.76,0))),Vector2.ZERO)
		for x in [-0.525,0.525]:
			for y in [-0.76,0.76]: rect = rect.expand(app.camera.unproject_position(face.to_global(Vector3(x,y,0))))
		_check(viewport.encloses(rect),label + ": entire card stays within the viewport")
		_check(rect.size.y >= 170,label + ": even the smallest hand remains readable")
		lowest = maxf(lowest,rect.end.y)
	_check(lowest < app.action_row.get_global_rect().position.y,label + ": hand clears the action buttons")
	for button in app.action_row.get_children():
		_check(viewport.encloses(button.get_global_rect()),label + ": every action button remains visible")

func _find_type(node: Node, kind: String):
	if node.is_class(kind): return node
	for child in node.get_children():
		var found = _find_type(child,kind)
		if found != null: return found
	return null

func _find_text(node: Node, value: String):
	if (node is Button or node is Label) and node.text == value: return node
	for child in node.get_children():
		var found = _find_text(child,value)
		if found != null: return found
	return null

func _finish() -> void:
	if is_instance_valid(app):
		app.game_mode = "menu"
		app.queue_free()
	await create_timer(0.5).timeout
	for path in USER_FILES:
		if originals.has(path):
			var file := FileAccess.open(path,FileAccess.WRITE)
			file.store_buffer(originals[path])
		else: DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	print("RESULT: %d accessibility checks; %d failures" % [checks,failures.size()])
	quit(0 if failures.is_empty() else 1)
