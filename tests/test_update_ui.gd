extends SceneTree
## Actual application integration for lessons, contextual advice, music
## preferences and sorting practice. Run with an isolated XDG_DATA_HOME.

const MainScene = preload("res://main.tscn")
const SortingScript = preload("res://scripts/sorting_challenge.gd")
var app
var checks := 0
var _original_preferences: PackedByteArray
var _had_preferences := false

func _init() -> void:
	call_deferred("_run")

func _run() -> void:
	_had_preferences = FileAccess.file_exists("user://preferences.cfg")
	if _had_preferences:
		_original_preferences = FileAccess.get_file_as_bytes("user://preferences.cfg")
	var baseline := ConfigFile.new()
	baseline.set_value("player", "name", "Test Nouveautés")
	baseline.set_value("help", "beginner", true)
	baseline.set_value("music", "settings", {"enabled": true, "volume": 0.28, "track_index": 0})
	_check(baseline.save("user://preferences.cfg") == OK, "test preferences available")
	app = MainScene.instantiate()
	root.add_child(app)
	await process_frame
	_check(app.game_mode == "menu" and app.music.enabled and is_equal_approx(app.music.volume, 0.28), "application starts with configured music")

	_press("Apprendre")
	_check(app.lesson_index == -1 and _find_text(app.overlay, "Apprendre le rami") != null, "header opens lesson overview")
	var first_chapter = _find_button_prefix(app.overlay, "1. ")
	_check(first_chapter is Button, "first chapter is actionable")
	first_chapter.pressed.emit()
	_check(app.lesson_index == 0 and _find_text(app.overlay, "EXEMPLE EXPLIQUÉ") != null, "chapter button opens explained example")
	_press("Étape suivante →")
	_check(app.lesson_index == 1, "next chapter advances one lesson")
	_press("Toutes les étapes")
	_check(app.lesson_index == -1, "chapter returns to overview")
	var beginner_toggle = _find_type(app.overlay, "CheckButton")
	beginner_toggle.button_pressed = false
	_check(not app.beginner_enabled, "beginner setting updates through actual control")
	_press("C’est compris")
	_check(app.overlay.get_child_count() == 0 and app.game_mode == "menu", "lesson closes without changing screen")
	_press("Je débute : apprendre le rami")
	_check(not _find_type(app.overlay, "CheckButton").button_pressed, "lesson overview reflects saved beginner choice")
	_press("C’est compris")

	app.solo_select.select(0)
	_press("Jouer contre l’ordinateur   →")
	_check(app.hand_cards.size() == 13 and app.hand_root.get_parent() == app.camera, "own hand lives under camera")
	var own_nodes_valid := true
	for card in app.hand_cards:
		own_nodes_valid = own_nodes_valid and card.get_parent() == app.hand_root and card.get_meta("hand_card", false) and is_equal_approx(card.scale.x, app.HAND_SCALE)
	_check(own_nodes_valid, "all large fan cards are marked as private hand cards")
	var untouched: Dictionary = app.snapshot.duplicate(true)
	_press("Conseils pas à pas")
	_check(_find_text(app.overlay, "PAS À PAS") != null and _find_text(app.overlay, "PROCHAINE ACTION") != null, "live advice includes steps and next action")
	_check(app.snapshot == untouched, "advice reads current turn without playing it")
	_press("Revenir à ma main")
	_press_draw()
	var selected_id: String = app.hand_cards[0].card_id
	app.hand_cards[0].tapped.emit(app.hand_cards[0])
	var selected_y: float = app.hand_cards[0].position.y
	_press("Conseils pas à pas")
	_check(app.selected == [selected_id] and _find_text(app.overlay, "Une carte est sélectionnée") != null, "coach explains selected card without clearing selection")
	_press("Ouvrir le guide complet")
	_press("Expliquer mon tour actuel")
	_check(app.selected == [selected_id], "guide and advice navigation retains player choice")
	_press("Revenir à ma main")
	_check(is_equal_approx(app.hand_cards[0].position.y, selected_y), "closing help preserves raised hand card")

	var music_before: Dictionary = app.snapshot.duplicate(true)
	_press("Musique")
	var toggle = _find_type(app.overlay, "CheckButton")
	var tracks = _find_type(app.overlay, "OptionButton")
	var volume = _find_type(app.overlay, "HSlider")
	_check(toggle != null and tracks != null and volume != null and tracks.item_count == 3, "music dialog exposes enabled state, three tracks and volume")
	toggle.button_pressed = false
	_check(not app.music.enabled and app.music_button.text == "Musique coupée", "mute updates live player and header")
	tracks.select(2)
	tracks.item_selected.emit(2)
	volume.value = 61
	_check(app.music.track_index == 2 and is_equal_approx(app.music.volume, 0.61), "track and slider update live music")
	_check(_find_text(app.overlay, "Volume · 61 %") != null, "volume label follows slider")
	var saved := ConfigFile.new()
	_check(saved.load("user://preferences.cfg") == OK, "preferences were written")
	var saved_music: Dictionary = saved.get_value("music", "settings", {})
	_check(saved_music == {"enabled": false, "volume": 0.61, "track_index": 2} and not saved.get_value("help", "beginner", true), "music and beginner controls persist together")
	_press("Revenir au jeu")
	_check(app.snapshot == music_before and app.selected == [selected_id], "music settings preserve the active game and selection")

	root.remove_child(app)
	app.queue_free()
	await process_frame
	app = MainScene.instantiate()
	root.add_child(app)
	await process_frame
	_check(not app.music.enabled and app.music.track_index == 2 and is_equal_approx(app.music.volume, 0.61), "new application instance restores music preferences")
	_check(not app.beginner_enabled and app.music_button.text == "Musique coupée", "reopened application reflects restored toggles")
	_press("Musique coupée")
	_check(not _find_type(app.overlay, "CheckButton").button_pressed and _find_type(app.overlay, "OptionButton").selected == 2 and is_equal_approx(_find_type(app.overlay, "HSlider").value, 61), "reopened music controls reflect persisted settings")
	_press("Revenir au jeu")
	_press("Plein écran")
	_check(app.fullscreen_enabled and app.fullscreen_button.text == "Fenêtre", "fullscreen button changes application state safely in headless mode")
	_press("Fenêtre")
	_check(not app.fullscreen_enabled, "fullscreen can return to windowed state")

	# A real online update arrives while readers have guides/settings open.
	# Exercise that signal handler with a public-only snapshot and no sockets.
	app.network.local_player = 0
	var remote_view := {
		"players": [{"name": "Test Nouveautés", "count": 8, "opened": false}, {"name": "Ami", "count": 13, "opened": false}],
		"hand": ["0:H:7", "0:H:8", "0:H:9", "0:S:2", "0:D:2", "0:C:2", "0:S:13", "0:C:13"],
		"turn": 0, "phase": "draw", "winner": -1, "melds": [], "deck_count": 80, "discard_top": "1:D:1", "turn_count": 1
	}
	app._network_game_updated(remote_view.duplicate(true))
	_check(app.game_mode == "online" and app.engine == null, "online integration uses public snapshot without local rules state")
	_press("Apprendre")
	_find_button_prefix(app.overlay, "1. ").pressed.emit()
	var lesson_panel_id: int = app.overlay.get_child(1).get_instance_id()
	app._network_game_updated(remote_view.duplicate(true))
	_check(app.overlay_kind == "lessons" and app.lesson_index == 0 and app.overlay.get_child(1).get_instance_id() == lesson_panel_id, "online update preserves opened chapter and panel")
	_press("C’est compris")
	_press("Musique coupée")
	var music_panel_id: int = app.overlay.get_child(1).get_instance_id()
	remote_view.turn = 1
	app._network_game_updated(remote_view.duplicate(true))
	_check(app.overlay_kind == "music" and app.overlay.get_child(1).get_instance_id() == music_panel_id, "online update preserves music settings panel")
	_press("Revenir au jeu")
	_press("Conseils pas à pas")
	_check(_find_text(app.overlay, "Préparez votre prochain tour") != null, "online coach explains opponent's active turn")
	remote_view.turn = 0
	app._network_game_updated(remote_view.duplicate(true))
	_check(app.overlay_kind == "coach" and _find_text(app.overlay, "Étape 1 : choisissez votre carte") != null, "open online coach refreshes to player's new turn")
	_press("Revenir à ma main")
	app._connection_changed(false)
	_check(app.overlay_kind == "connection" and app.snapshot.paused, "connection loss exposes reconnect dialog and pauses view")
	app._network_game_updated(remote_view.duplicate(true))
	_check(app.overlay.get_child_count() == 0 and not app.snapshot.get("paused", false), "fresh online state closes reconnect dialog")
	_press("Accueil")
	_press("Quitter la partie")

	_press("Défi de tri   →")
	var challenge = _find_sorting()
	_check(app.game_mode == "sorting" and challenge != null and challenge.cards.size() == 8, "menu launches first sorting round")
	_check(app.snapshot.is_empty() and app.hand_cards.is_empty() and app.card_nodes.is_empty(), "sorting mode clears the rummy table")
	_press("Retour")
	_check(app.game_mode == "menu" and app.card_nodes.size() == 5 and _find_sorting() == null, "sorting return signal restores menu")

	# Real navigation while the opponent is thinking must invalidate that
	# coroutine before the separate sorting practice is mounted.
	app.solo_select.select(0)
	_press("Jouer contre l’ordinateur   →")
	_press_draw()
	app.hand_cards[0].tapped.emit(app.hand_cards[0])
	_press("Défausser →")
	_check(app.busy, "opponent thinking delay is pending")
	_press("Accueil")
	_press("Quitter la partie")
	_press("Défi de tri   →")
	challenge = _find_sorting()
	var sorting_hand: Array = challenge.cards.duplicate()
	await create_timer(1.15).timeout
	_check(app.game_mode == "sorting" and not app.busy and app.snapshot.is_empty() and challenge.cards == sorting_hand, "canceled bot cannot mutate sorting practice")
	_press("Retour")
	_check(app.game_mode == "menu", "sorting remains closable after old bot timer expires")
	root.remove_child(app)
	app.queue_free()
	await process_frame
	await create_timer(0.25).timeout
	_restore_preferences()
	print("PASS: %d update integration UI checks" % checks)
	quit(0)

func _press_draw() -> void:
	var button = _find_button_prefix(app.ui, "↓  Piocher")
	_check(button is Button and not button.disabled, "draw button available and enabled")
	button.pressed.emit()

func _press(text: String) -> void:
	var node = _find_text(app.ui, text)
	_check(node is Button and not node.disabled, "button available and enabled: " + text)
	if node is Button:
		node.pressed.emit()

func _find_text(node: Node, text: String):
	if (node is Button or node is Label) and node.text == text:
		return node
	for child in node.get_children():
		var found = _find_text(child, text)
		if found != null:
			return found
	return null

func _find_button_prefix(node: Node, prefix: String):
	if node is Button and node.text.begins_with(prefix):
		return node
	for child in node.get_children():
		var found = _find_button_prefix(child, prefix)
		if found != null:
			return found
	return null

func _find_type(node: Node, type_name: String):
	if node.is_class(type_name):
		return node
	for child in node.get_children():
		var found = _find_type(child, type_name)
		if found != null:
			return found
	return null

func _find_sorting():
	for child in app.content.get_children():
		if child.get_script() == SortingScript:
			return child
	return null

func _restore_preferences() -> void:
	if _had_preferences:
		var previous := FileAccess.open("user://preferences.cfg", FileAccess.WRITE)
		previous.store_buffer(_original_preferences)
	else:
		DirAccess.remove_absolute(ProjectSettings.globalize_path("user://preferences.cfg"))

func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		_restore_preferences()
		push_error("FAIL: " + message)
		quit(1)
		assert(condition, message)
