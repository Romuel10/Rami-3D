extends SceneTree
## Offline footage of the real rigs; no account, voice input or room connection.
var app

func _initialize() -> void: call_deferred("_capture")

func _shot(label: String) -> void:
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://builds/players-" + label + ".png")

func _capture() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("This capture needs a graphical display.")
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute("res://builds")
	root.size = Vector2i(1440,900)
	var cfg := ConfigFile.new()
	cfg.set_value("player","name","Mika")
	cfg.set_value("player","province","Antananarivo")
	cfg.set_value("comfort","animations",false)
	cfg.set_value("music","settings",{"enabled":false,"volume":0.0,"track_index":0})
	cfg.save("user://preferences.cfg")
	app = load("res://main.tscn").instantiate()
	root.add_child(app)
	app.animations_enabled = true
	app._set_fullscreen(false,false)
	app.network.local_player = 0
	var view := {
		"your_index":0,"turn":1,"phase":"draw","winner":-1,
		"players":[{"name":"Mika","count":13,"opened":true},{"name":"Aina","count":13},{"name":"Hery","count":13},{"name":"Soa","count":13}],
		"hand":["0:H:7","0:H:8","0:H:9","0:S:2","0:D:2","0:C:2","0:S:13","0:C:13","0:D:4","0:D:5","0:D:6","0:C:10","0:S:11"],
		"deck_count":76,"discard_top":"1:D:1","melds":[],"session_id":"players-preview","revision":0,"last_action":{}
	}
	app._network_game_updated(view.duplicate(true))
	await create_timer(1.4).timeout
	await _shot("attente")
	view.players[1].count = 14
	view.deck_count = 75
	view.phase = "play"
	view.revision += 1
	view.last_action = {"type":"draw","player":1,"source":"deck"}
	app._network_game_updated(view.duplicate(true))
	await create_timer(.22).timeout
	await _shot("pioche")
	await create_timer(.95).timeout
	view.players[1].count = 13
	view.discard_top = "1:C:12"
	view.turn = 2
	view.phase = "draw"
	view.revision += 1
	view.last_action = {"type":"discard","player":1}
	app._network_game_updated(view.duplicate(true))
	await create_timer(.22).timeout
	await _shot("defausse")
	await create_timer(.95).timeout
	view.players[2].count = 14
	view.discard_top = "1:D:1"
	view.phase = "play"
	view.revision += 1
	view.last_action = {"type":"draw","player":2,"source":"discard"}
	app._network_game_updated(view.duplicate(true))
	await create_timer(1.15).timeout
	view.players[2].count = 11
	view.melds = [{"cards":["1:H:3","1:H:4","1:H:5"],"owner":2}]
	view.revision += 1
	view.last_action = {"type":"meld","player":2}
	app._network_game_updated(view.duplicate(true))
	await create_timer(.22).timeout
	await _shot("pose")
	await create_timer(.95).timeout
	app.header_status.text = "Aperçu · réactions des joueurs"
	app.table_scene.react_to_result([1],"preview-result")
	await create_timer(.35).timeout
	await _shot("reaction")
	await create_timer(1.25).timeout
	app.queue_free()
	await process_frame
	quit(0)
