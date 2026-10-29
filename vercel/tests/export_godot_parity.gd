extends SceneTree
## Export deterministic rule observations. No live room or saved user data.
const Rules = preload("res://scripts/rami_engine.gd")
var output := {"melds":[],"scenarios":[]}

func _init() -> void: call_deferred("_run")

func add_meld(cards: Array) -> void:
	output.melds.append({"cards":cards,"expected":Rules.new()._validate_meld(cards)})

func rig(hand: Array, tri_size: int = 0, melds: Array = [], opened: bool = false, draw: String = "", phase: String = "play") -> RefCounted:
	var game := Rules.new()
	if tri_size > 0: game.start_tri_game(["Alice","Bob"],tri_size,17)
	else: game.start_game(["Alice","Bob"],17)
	var pool: Array = game.state.deck + game.state.discard
	for player in game.state.players: pool.append_array(player.hand)
	for id in hand: pool.erase(id)
	for group in melds:
		for id in group.cards: pool.erase(id)
	if not draw.is_empty(): pool.erase(draw)
	game.state.players[0].hand = hand.duplicate()
	game.state.players[0].opened = opened
	game.state.players[1].hand = pool.slice(0,tri_size if tri_size > 0 else 13)
	pool = pool.slice(tri_size if tri_size > 0 else 13)
	game.state.discard = [pool.pop_front()]
	game.state.deck = pool + ([draw] if not draw.is_empty() else [])
	game.state.melds = melds.duplicate(true)
	game.state.phase = phase
	return game

func scenario(name: String, game: RefCounted, steps: Array) -> void:
	var record := {"name":name,"initial":game.state.duplicate(true),"steps":[]}
	for step: Dictionary in steps:
		var result: Dictionary
		if step.get("forfeit",false): result = game.forfeit_player(int(step.index),str(step.get("reason","abandon")),bool(step.get("finish",false)))
		else: result = game.apply_action(int(step.index),step.action)
		var row: Dictionary = step.duplicate(true)
		row.result = result
		row.state = game.state.duplicate(true)
		row.views = []
		for i in range(game.state.players.size()): row.views.append(game.view_for(i))
		record.steps.append(row)
	output.scenarios.append(record)

func action(index: int, type: String, fields: Dictionary = {}) -> Dictionary:
	var payload := fields.duplicate(true)
	payload.type = type
	return {"index":index,"action":payload}

func _run() -> void:
	# All natural three/four-card sets, including duplicate physical colours.
	for rank in range(1,14):
		for a in range(4):
			for b in range(a+1,4):
				for c in range(b+1,4):
					add_meld(["0:%s:%d"%[Rules.SUITS[a],rank],"0:%s:%d"%[Rules.SUITS[b],rank],"0:%s:%d"%[Rules.SUITS[c],rank]])
			for b in range(a+1,4):
				add_meld(["0:%s:%d"%[Rules.SUITS[a],rank],"0:%s:%d"%[Rules.SUITS[b],rank],"J:0"])
				add_meld(["0:%s:%d"%[Rules.SUITS[a],rank],"0:%s:%d"%[Rules.SUITS[b],rank],"J:0","J:1"])
			add_meld(["0:%s:%d"%[Rules.SUITS[a],rank],"1:%s:%d"%[Rules.SUITS[a],rank],"J:0"])
		add_meld(["0:S:%d"%rank,"0:H:%d"%rank,"0:D:%d"%rank,"0:C:%d"%rank])
	# Runs of every length/start/suit, with every single-joker replacement.
	for suit in Rules.SUITS:
		for length in range(3,14):
			for first in range(1,15-length):
				var cards: Array = []
				for rank in range(first,first+length): cards.append("0:%s:%d"%[suit,rank])
				add_meld(cards.duplicate())
				for missing in range(length):
					var joker_run := cards.duplicate()
					joker_run[missing] = "J:0"
					add_meld(joker_run)
		add_meld(["0:%s:12"%suit,"0:%s:13"%suit,"0:%s:1"%suit])
		add_meld(["0:%s:13"%suit,"0:%s:1"%suit,"0:%s:2"%suit])
		add_meld(["0:%s:1"%suit,"0:%s:2"%suit,"J:0"])
	for cards in [[],["0:H:7"],["0:H:7","0:C:7"],["0:H:7","J:0","J:1"],["J:0","J:1","J:2"],["0:H:7","0:H:7","0:C:7"],["invalid","0:H:7","0:C:7"],["0:H:7","0:H:9","0:H:11"],["0:H:7","0:C:8","0:D:9"]]: add_meld(cards)
	var hand: Array = ["0:H:6","0:H:7","0:H:8","1:H:7","0:C:7","0:D:7","0:S:2","0:S:4","0:S:9","0:S:12","0:D:2","0:D:10","0:C:3","0:C:11"]
	scenario("atomic opening and duplicate copies",rig(hand),[
		action(1,"draw"),action(0,"draw"),action(0,"meld",{"cards":hand.slice(0,3)}),
		action(0,"meld",{"groups":[hand.slice(0,3),hand.slice(0,3)]}),
		action(0,"meld",{"groups":[hand.slice(0,3),hand.slice(3,6)]}),
		action(0,"discard",{"card":"0:S:2"}),action(1,"draw"),
	])
	scenario("extension and final discard",rig(["0:H:10","0:C:2"],0,[{"owner":1,"type":"run","cards":["0:H:7","0:H:8","0:H:9"]}],true),[
		action(0,"extend",{"meld":.5,"cards":["0:H:10"]}),
		action(0,"extend",{"meld":0,"cards":["0:H:10","0:C:2"]}),
		action(0,"extend",{"meld":0,"cards":["0:H:10"]}),
		action(0,"discard",{"card":"0:C:2"}),action(1,"draw"),
	])
	for size in [6,12]:
		var tri_hand: Array = ["0:H:7","1:H:7","0:C:7","0:S:8","0:C:8","0:D:2"]
		if size==12: tri_hand.append_array(["0:S:9","0:C:9","0:D:9","0:H:1","0:S:3","0:D:4"])
		scenario("Tri %d win after discard"%size,rig(tri_hand,size,[],false,"0:D:8","draw"),[
			action(0,"discard",{"card":"0:D:2"}),action(0,"draw"),action(0,"draw"),
			action(0,"meld",{"cards":tri_hand.slice(0,3)}),action(0,"extend",{"meld":0,"cards":tri_hand.slice(0,3)}),
			action(0,"discard",{"card":"0:D:2"}),action(1,"draw"),
		])
		var tri_game := Rules.new()
		tri_game.start_tri_game(["A","B"],size,17)
		scenario("Tri %d forfeit"%size,tri_game,[{"index":0,"forfeit":true,"reason":"abandon"}])
	var game := Rules.new()
	game.start_game(["A","B","C","D"],42)
	scenario("four player eliminations",game,[
		{"index":1,"forfeit":true,"reason":"abandon"},action(0,"draw"),
		{"index":0,"forfeit":true,"reason":"abandon"},
		{"index":3,"forfeit":true,"reason":"déconnexion prolongée"},
	])
	game = Rules.new()
	game.start_game(["A","B","C","D"],42)
	scenario("phone host leaves",game,[{"index":0,"forfeit":true,"reason":"hote_abandon","finish":true}])
	var path := "/tmp/rami-godot-parity.json"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="): path=arg.trim_prefix("--out=")
	var file := FileAccess.open(path,FileAccess.WRITE)
	if file==null:
		printerr("Could not write parity fixture")
		quit(1)
		return
	file.store_string(JSON.stringify(output))
	file.close()
	print("PASS: exported %d Godot meld observations and %d gameplay scenarios"%[output.melds.size(),output.scenarios.size()])
	quit()
