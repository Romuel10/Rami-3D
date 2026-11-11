extends SceneTree
## Palette changes must preserve the live match, private cards and selection.
const Main = preload("res://main.tscn")
const Appearance = preload("res://scripts/salon_appearance.gd")
const Profile = preload("res://scripts/player_profile.gd")
const Table = preload("res://scripts/table_scene.gd")
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
	for index in range(8): await process_frame
	if DisplayServer.get_name() != "headless": await RenderingServer.frame_post_draw

func _button(node: Node, text: String) -> Button:
	if node is Button and node.text == text: return node
	for child in node.get_children():
		var found := _button(child, text)
		if found != null: return found
	return null

func _capture(name: String) -> void:
	if DisplayServer.get_name() == "headless": return
	DirAccess.make_dir_recursive_absolute("res://builds")
	root.get_texture().get_image().save_png("res://builds/salon-" + name + ".png")

func _run() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("player", "name", "Mika")
	cfg.set_value("player", "province", "Antananarivo")
	cfg.set_value("comfort", "animations", false)
	cfg.set_value("music", "settings", {"enabled":false, "volume":0.0, "track_index":0})
	check(Profile.save_preferences(cfg), "legacy preferences are prepared without an appearance key")
	app = Main.instantiate()
	root.add_child(app)
	await _frames()
	check(app.palette_id == Appearance.DEFAULT, "an existing installation gets the default palette")
	check(Appearance.checked_id("unknown") == Appearance.DEFAULT and Appearance.checked_id(9) == Appearance.DEFAULT, "invalid saved palettes fall back safely")
	check(_button(app.content, "Apparence") != null, "appearance is reachable from the home screen")
	_button(app.content, "Apparence").pressed.emit()
	check(app._palette_picker.item_count == 3, "all three selected palettes are available")
	app._close_overlay()
	app._start_solo(6)
	app.engine.state.turn = 0
	app._refresh_snapshot()
	app._act({"type":"draw", "source":"deck"})
	app._select_card(app.hand_cards[0])
	check(not app._discard_button.disabled, "one selected card enables discard after drawing")
	app._select_card(app.hand_cards[1])
	check(app.selected.size() == 1 and app.selected[0] == app.hand_cards[1].card_id, "tapping another Tri card replaces the previous selection")
	var game_before: Dictionary = app.engine.export_game()
	var snapshot_before: Dictionary = app.snapshot.duplicate(true)
	var order_before: Array = app.hand_order.duplicate()
	var selection_before: Array = app.selected.duplicate()
	var hand_nodes: Array = app.hand_cards.duplicate()
	var separate_table := Table.new()
	app.add_child(separate_table)
	var separate_felt: Color = separate_table.get_node("FeltSurface").material_override.albedo_color
	app._show_options()
	_button(app.overlay, "Apparence du salon").pressed.emit()
	check(app.overlay_kind == "appearance", "appearance can be opened from an active match")
	for index in range(Appearance.IDS.size()):
		app._palette_picker.select(index)
		app._palette_picker.item_selected.emit(index)
		await _frames()
		var id: String = Appearance.IDS[index]
		var colors := Appearance.colors(id)
		check(app.palette_id == id, "the real picker applies " + id)
		check(app.engine.export_game() == game_before and app.snapshot == snapshot_before, "switching colors preserves the live game: " + id)
		check(app.hand_order == order_before and app.selected == selection_before and app.hand_cards == hand_nodes, "private meshes, selection and order survive: " + id)
		check(app._discard_button.get_theme_stylebox("normal").bg_color.is_equal_approx(colors.accent), "the main action follows the palette: " + id)
		check(app.game_status.get_theme_color("font_color").is_equal_approx(colors.ink), "existing status text follows the palette: " + id)
		check(app.table_scene.get_node("FeltSurface").material_override.albedo_color.is_equal_approx(colors.felt), "the physical felt follows the palette: " + id)
		check(separate_table.get_node("FeltSurface").material_override.albedo_color == separate_felt, "shared textures do not recolor another salon: " + id)
		var saved := ConfigFile.new()
		saved.load(Profile.PREFERENCES)
		check(saved.get_value("appearance", "palette") == id, "the selected palette is saved: " + id)
	app._close_overlay()
	separate_table.queue_free()
	app._select_card(app.hand_cards[1])
	check(app.selected.is_empty() and app._discard_button.disabled, "deselecting disables discard")
	app._select_card(app.hand_cards[0])
	var held_before: int = app.snapshot.hand.size()
	app._discard_button.pressed.emit()
	check(app.engine.state.players[0].hand.size() == held_before - 1, "the same match continues after changing palettes")
	app._leave_to_menu()
	await create_timer(0.6).timeout
	await _frames()
	app._set_fullscreen(false, false)
	for screen in [Vector2i(1440,900), Vector2i(2400,1080)]:
		root.size = screen
		for id in Appearance.IDS:
			app._set_palette(id)
			await _frames()
			for control in app.content.find_children("*", "Button", true, false):
				check(app.ui.get_global_rect().encloses(control.get_global_rect()), "home button fits " + id + " at " + str(screen))
			_capture(id + "-accueil-%dx%d" % [screen.x,screen.y])
			app._start_solo(6)
			await _frames()
			check(app.ui.get_global_rect().encloses(app.action_row.get_global_rect()), "actions fit " + id + " at " + str(screen))
			_capture(id + "-partie-%dx%d" % [screen.x,screen.y])
			app._show_appearance()
			await _frames()
			_capture(id + "-apparence-%dx%d" % [screen.x,screen.y])
			app._close_overlay()
			app._leave_to_menu()
	app._set_palette("terre")
	app.queue_free()
	await process_frame
	app = Main.instantiate()
	root.add_child(app)
	await _frames()
	check(app.palette_id == "terre", "the palette survives a fresh application instance")
	check(app.saved_name == "Mika" and app.player_province == "Antananarivo", "saving appearance preserves the player profile")
	app.queue_free()
	await process_frame
	await create_timer(0.2).timeout
	print("PASS: %d salon appearance checks" % checks)
	quit(0)
