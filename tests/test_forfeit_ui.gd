extends SceneTree
## Real-scene regressions for match/round result text and intentional abandonment.
## Run with an isolated XDG_DATA_HOME to avoid replacing a personal solo game.
const MainScene = preload("res://main.tscn")
const Store = preload("res://scripts/solo_store.gd")
var app
var checks := 0
var failures: Array[String] = []
var originals: Dictionary = {}
const USER_FILES := ["user://preferences.cfg", "user://solo-v1.save", "user://solo-v1.save.bak", "user://solo-v1.save.tmp", "user://stats-v1.save", "user://stats-v1.save.bak", "user://stats-v1.save.tmp"]

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error("FAIL: " + message)

func _run() -> void:
	_backup()
	app = MainScene.instantiate()
	root.add_child(app)
	await process_frame
	if not app.has_method("_winner_result") or not app.has_method("_abandon_to_menu"):
		_check(false, "new result and abandonment callbacks exist")
		await _finish()
		return
	_check(true, "new result and abandonment callbacks exist")

	# The round winner is not necessarily the winner of a three-round match.
	_install_view(_view(0, [100,20], 3, 3, [1], true))
	var result: Dictionary = app._winner_result()
	_check(result.get("finished", false) and result.get("winners", []) == [1], "final result uses cumulative match leader instead of last-round winner")
	_check(not result.get("forfeit", true), "normal cumulative result is not a forfeit")
	_check(str(result.get("body", "")) != "Vous avez gagné !", "losing cumulative match never announces a local match victory")
	app._show_winner()
	_check(app.overlay_kind == "winner" and _find_text(app.overlay, str(result.get("body", ""))) != null, "visible result dialog uses computed match outcome")
	_check(_all_text(app.overlay).contains("20 points") and _all_text(app.overlay).contains("100 points"), "final dialog preserves the cumulative score ranking")
	_check(_find_text(app.overlay, "Manche suivante") == null, "finished match offers no next-round control")

	_install_view(_view(1, [15,70], 3, 3, [0], true))
	result = app._winner_result()
	_check(result.get("winners", []) == [0] and result.get("finished", false), "local cumulative victory is recognized even when opponent won last round")
	app._show_winner()
	_check(_find_text(app.overlay, str(result.get("body", ""))) != null, "local cumulative win appears in actual overlay")

	_install_view(_view(1, [40,40], 3, 3, [0,1], true))
	result = app._winner_result()
	_check(result.get("winners", []) == [0,1] and result.get("finished", false), "equal cumulative penalties retain both tied winners")
	app._show_winner()
	var tie_text := _all_text(app.overlay).to_lower()
	_check("æquo" in tie_text or "aequo" in tie_text or "égalité" in tie_text or "nul" in tie_text, "visible final result explicitly explains a tie")

	_install_view(_view(0, [0,25], 1, 3, [], false))
	result = app._winner_result()
	_check(not result.get("finished", true), "winning an intermediate round does not end the match")
	_check("manche" in (str(result.get("title", "")) + " " + str(result.get("body", ""))).to_lower(), "intermediate result identifies a round victory")
	_check(str(result.get("body", "")) != "Vous avez gagné !", "intermediate round avoids an ambiguous whole-match victory message")

	# Eliminated players never occupy a rank ahead of active match winners.
	var eliminated := _view(1, [0,20,40], 3, 3, [1], true)
	eliminated.players[0].forfeited = true
	eliminated.forfeited = [0]
	_install_view(eliminated, 2)
	app._show_winner()
	_check("1. Camille · 20 points" in _all_text(app.overlay), "active match winner remains rank one when an eliminated player has fewer penalties")
	_check("Vous · éliminé par abandon" in _all_text(app.overlay), "forfeited player is marked eliminated rather than ranked")

	var json_result := _view(1, [15,70], 3, 3, [0.0], true)
	_install_view(json_result)
	_check(app._winner_result().get("winners", []) == [0], "JSON numeric winner indices are normalized for local winner membership")

	# Compatibility with an older public snapshot without match_result metadata.
	var legacy := _view(0, [100,20], 3, 3, [1], true)
	legacy.erase("match_result")
	_install_view(legacy)
	result = app._winner_result()
	_check(result.get("winners", []) == [1], "legacy snapshot derives final leader from cumulative totals")

	# A terminal server result must survive the host closing its connection.
	var loss := _view(1, [35,0], 1, 3, [1], true)
	loss.win_by_forfeit = true
	loss.end_reason = "abandon"
	loss.forfeited = [0]
	loss.players[0].forfeited = true
	loss.match_result.forfeit = true
	loss.match_result.reason = "abandon"
	loss.last_action = {"type":"forfeit", "player":0, "reason":"abandon"}
	_install_view(loss)
	app._show_winner()
	result = app._winner_result()
	_check(result.get("forfeit", false) and result.get("finished", false) and result.get("winners", []) == [1], "server forfeit announces defeat of the departing player")
	_check("forfait" in _all_text(app.overlay).to_lower() or "abandon" in _all_text(app.overlay).to_lower(), "result gives an explicit forfeit or abandonment reason")
	var outcome_text := _all_text(app.overlay)
	app._connection_changed(false)
	_check(app.overlay_kind == "winner", "socket closure after terminal result preserves the winner dialog")
	_check(_all_text(app.overlay) == outcome_text and _find_text(app.overlay, "Connexion interrompue") == null, "terminal victory is not replaced with a reconnect prompt")

	var victory := loss.duplicate(true)
	victory.your_index = 1
	_install_view(victory, 1)
	app._show_winner()
	_check(app._winner_result().get("winners", []) == [1], "remaining opponent receives the automatic forfeit victory")
	app._connection_changed(false)
	_check(app.overlay_kind == "winner", "remaining opponent retains victory after departing host closes")

	# At three players the remaining co-winners of a host departure are explicit.
	var shared := _view(1, [80,10,30], 1, 1, [1,2], true)
	shared.win_by_forfeit = true
	shared.end_reason = "hote_abandon"
	shared.forfeited = [0]
	shared.players[0].forfeited = true
	shared.match_result.forfeit = true
	_install_view(shared, 1)
	result = app._winner_result()
	_check(result.get("forfeit", false) and result.get("winners", []) == [1,2], "LAN-host shutdown preserves all declared remaining winners")
	app._show_winner()
	_check("Camille" in _all_text(app.overlay) and "Alex" in _all_text(app.overlay), "shared forfeit outcome keeps both remaining players visible")

	# A normal return to the menu retains the solo save; explicit abandonment ends it.
	app._leave_to_menu()
	var departed_snapshot: Dictionary = app.snapshot.duplicate(true)
	_check(app.network.local_player == -1, "leaving clears the authenticated local seat")
	app._network_game_updated(shared.duplicate(true))
	_check(app.game_mode == "menu" and app.snapshot == departed_snapshot and app.hand_cards.is_empty() and app.card_nodes.size() == 5, "late game packet cannot reopen the departed match or replace menu cards")
	app.match_length = 3
	app.difficulty = 1
	app.solo_select.select(0)
	_press("Jouer contre l’ordinateur   →")
	_check(app.game_mode == "solo" and int(app.snapshot.winner) < 0, "real solo game begins before leave checks")
	var before_menu: Dictionary = app.engine.export_game()
	app._leave_to_menu()
	_check(app.game_mode == "menu", "ordinary menu navigation returns to the menu")
	var saved: Dictionary = Store.load_game()
	_check(not saved.is_empty() and int(saved.game.state.winner) == -1, "ordinary menu return preserves an unfinished resumable game")
	app._resume_solo()
	_check(app.engine.export_game() == before_menu and int(app.snapshot.winner) == -1, "normal solo resume restores the same active cards and random state")
	app._confirm_leave()
	_check(_find_text(app.overlay, "Abandonner la partie") is Button, "explicit quit dialog labels the forfeiting action")
	_check("abandon" in _all_text(app.overlay).to_lower() or "forfait" in _all_text(app.overlay).to_lower(), "quit confirmation explains the consequence")
	_press("Abandonner la partie")
	_check(app.game_mode == "menu", "abandon callback returns to the menu")
	saved = Store.load_game()
	_check(not saved.is_empty(), "abandoned match remains a valid completed save")
	if not saved.is_empty():
		_check(bool(saved.game.state.get("win_by_forfeit", false)) and bool(saved.game.state.players[0].get("forfeited", false)), "saved state records an actual local forfeit")
		_check(int(saved.game.state.winner) == 1, "solo opponent receives the automatic victory")
	app._resume_solo()
	_check(app.game_mode == "solo" and int(app.snapshot.winner) == 1 and app._winner_result().get("finished", false), "resume cannot revive an abandoned solo match as ongoing")

	# Abandonment during the opponent's delayed turn must cancel that coroutine.
	app._leave_to_menu()
	app.solo_select.select(0)
	_press("Jouer contre l’ordinateur   →")
	app._act({"type":"draw", "source":"deck"})
	app._act({"type":"discard", "card":app.snapshot.hand[0]})
	_check(app.busy, "opponent delay is active before abandonment")
	var old_engine = app.engine
	app._abandon_to_menu()
	var abandoned_state: Dictionary = old_engine.export_game()
	await create_timer(1.2).timeout
	_check(app.game_mode == "menu" and old_engine.export_game() == abandoned_state, "old bot coroutine cannot mutate a completed forfeit after navigation")
	_check(int(old_engine.state.winner) == 1 and bool(old_engine.state.get("win_by_forfeit", false)), "abandonment is final even when it was opponent's turn")
	await _finish()

func _view(round_winner: int, totals: Array, round_index: int, length: int, winners: Array, finished: bool) -> Dictionary:
	var names := ["Vous", "Camille", "Alex", "Charlie"]
	var players: Array = []
	for i in range(totals.size()):
		players.append({"name":names[i], "count":0 if i == round_winner else 13, "opened":true, "forfeited":false})
	return {"players":players,"hand":[] if round_winner == 0 else ["0:S:2","0:H:4"],"your_index":0,"turn":round_winner,"phase":"play","winner":round_winner,"melds":[],"deck_count":70,"discard_top":"1:C:5","turn_count":12,"session_id":"ui-forfeit-%d" % checks,"revision":10,"last_action":{"type":"discard","player":round_winner},"match":{"round":round_index,"length":length,"totals":totals,"results":[]},"match_result":{"finished":finished,"winners":winners,"forfeit":false,"reason":"","round_finished":true,"round_winner":round_winner}}

func _install_view(view: Dictionary, own: int = 0) -> void:
	app._close_overlay()
	app.game_mode = "online"
	app.network.local_player = own
	app.snapshot = view.duplicate(true)
	app.snapshot.your_index = own
	app._winner_key = ""
	app._show_game()

func _press(text: String) -> void:
	var button = _find_text(app.ui, text)
	_check(button is Button and not button.disabled, "button available: " + text)
	if button is Button and not button.disabled:
		button.pressed.emit()

func _find_text(node: Node, text: String):
	if (node is Button or node is Label) and node.text == text:
		return node
	for child in node.get_children():
		var found = _find_text(child, text)
		if found != null: return found
	return null

func _all_text(node: Node) -> String:
	var values := PackedStringArray()
	if node is Button or node is Label: values.append(node.text)
	for child in node.get_children(): values.append(_all_text(child))
	return "\n".join(values)

func _backup() -> void:
	for path in USER_FILES:
		if FileAccess.file_exists(path): originals[path] = FileAccess.get_file_as_bytes(path)

func _finish() -> void:
	if is_instance_valid(app):
		app.game_mode = "menu"
		app.queue_free()
	await create_timer(0.3).timeout
	for path in USER_FILES:
		if originals.has(path):
			var file := FileAccess.open(path, FileAccess.WRITE)
			file.store_buffer(originals[path])
		else:
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	print("RESULT: %d forfeit UI checks; %d failures" % [checks,failures.size()])
	quit(0 if failures.is_empty() else 1)
