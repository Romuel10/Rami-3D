extends SceneTree
## Reproducible offline preview; run with --write-movie builds/animations.avi
## and --fixed-fps 30 using a graphical display.
var app

func _initialize() -> void:
	call_deferred("_capture")

func _capture() -> void:
	app = load("res://main.tscn").instantiate()
	root.add_child(app)
	app._set_fullscreen(false, false)
	app.music.set_enabled(false)
	await create_timer(0.85).timeout
	app.network.local_player = 0
	var view := {
		"your_index":0, "turn":0, "phase":"draw", "winner":-1,
		"players":[{"name":"Vous", "count":13, "opened":true}, {"name":"Camille", "count":13, "opened":false}],
		"hand":["0:H:7", "0:H:8", "0:H:9", "0:S:2", "0:D:2", "0:C:2", "0:S:13", "0:C:13", "0:D:4", "0:D:5", "0:D:6", "0:C:10", "0:S:11"],
		"deck_count":80, "discard_top":"1:D:1", "melds":[]
	}
	app._network_game_updated(view.duplicate(true))
	await create_timer(1.6).timeout
	var chosen: Node3D = app._view_cards["card:0:H:8"]
	chosen.tapped.emit(chosen)
	await create_timer(0.55).timeout
	chosen.tapped.emit(chosen)
	await create_timer(0.40).timeout
	app._sort_hand()
	await create_timer(0.95).timeout
	view.hand.append("1:H:8")
	view.players[0].count = 14
	view.deck_count = 79
	view.phase = "play"
	app._network_game_updated(view.duplicate(true))
	await create_timer(0.95).timeout
	for id in ["0:H:7", "0:H:8", "0:H:9"]:
		app._view_cards["card:" + id].tapped.emit(app._view_cards["card:" + id])
	await create_timer(0.5).timeout
	for id in ["0:H:7", "0:H:8", "0:H:9"]:
		view.hand.erase(id)
	view.melds = [{"cards":["0:H:7", "0:H:8", "0:H:9"], "owner":0}]
	view.players[0].count = 11
	app._network_game_updated(view.duplicate(true))
	await create_timer(1.0).timeout
	view.hand.erase("1:H:8")
	view.discard_top = "1:H:8"
	view.players[0].count = 10
	view.turn = 1
	view.phase = "draw"
	app._network_game_updated(view.duplicate(true))
	await create_timer(1.0).timeout
	view.melds.append({"cards":["1:S:3", "1:S:4", "1:S:5"], "owner":1})
	view.discard_top = "1:C:12"
	view.players[1].count = 10
	view.players[1].opened = true
	view.turn = 0
	app._network_game_updated(view.duplicate(true))
	await create_timer(1.2).timeout
	app._show_music_settings()
	await create_timer(0.65).timeout
	app._close_overlay()
	await create_timer(0.35).timeout
	app.queue_free()
	await process_frame
	quit(0)
