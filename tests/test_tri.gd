extends SceneTree
const Rules = preload("res://scripts/rami_engine.gd")
var checks := 0
func _init() -> void: call_deferred("_run")
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		push_error(message)
		quit(1)
		assert(ok,message)
func rig(cards: Array, size: int, draw: String) -> RefCounted:
	var game := Rules.new()
	game.start_tri_game(["Vous","Ami"],size,71)
	var pool: Array = game.state.deck + game.state.discard
	for player in game.state.players: pool.append_array(player.hand)
	for id in cards: pool.erase(id)
	pool.erase(draw)
	game.state.players[0].hand = cards.duplicate()
	game.state.players[1].hand = pool.slice(0,size)
	pool = pool.slice(size)
	game.state.discard = [pool.pop_front()]
	game.state.deck = pool + [draw]
	return game
func inventory(game) -> void:
	var cards: Array = game.state.deck + game.state.discard
	for player in game.state.players: cards.append_array(player.hand)
	check(cards.size() == 104 and Rules.new()._unique(cards),"104 unique physical cards conserved")
	check(game.state.melds.is_empty(),"tris never leave the hand")
func _run() -> void:
	var game := Rules.new()
	check(not game.start_tri_game(["A","B","C"],6).ok,"duel only")
	check(not game.start_tri_game(["A","B"],9).ok,"only6or12")
	check(game.tri_groups(["0:H:7","1:H:7","0:C:7"]).size()==1,"double suit legal")
	check(game.tri_groups(["0:H:7","0:H:7","0:C:7"]).is_empty(),"same physical card not reused")
	check(game.tri_groups(["0:H:7","0:H:8","0:H:9"]).is_empty(),"runs do not count")
	check(game.tri_groups(["J:0","0:H:7","0:C:7"]).is_empty(),"jokers do not complete tris")
	check(game.tri_groups(["0:H:7","1:H:7","0:C:7","1:C:7","0:D:7","0:S:7"]).size()==2,"six of same rank form two disjoint tris")
	for size in [6,12]:
		var hand: Array = ["0:H:7","1:H:7","0:C:7","0:S:8","0:C:8","0:D:2"]
		if size==12: hand.append_array(["0:S:9","0:C:9","0:D:9","0:H:1","0:S:3","0:D:4"])
		game = rig(hand,size,"0:D:8")
		inventory(game)
		check(game.view_for(1).hand==game.state.players[1].hand,"own hand only")
		check(not game.view_for(1).players[0].has("hand") and game.view_for(1).winning_tris.is_empty(),"opponent tris hidden before victory")
		var before: Dictionary = game.export_game()
		check(not game.apply_action(0,{"type":"discard","card":"0:D:2"}).ok,"must draw before discard")
		check(not game.apply_action(1,{"type":"draw"}).ok,"wrong turn rejected")
		check(game.export_game()==before,"rejected actions do not mutate")
		check(game.apply_action(0,{"type":"draw"}).ok,"draw accepted")
		check(game.state.players[0].hand.size()==size+1 and game.state.winner==-1,"draw does not declare premature victory")
		check(not game.apply_action(0,{"type":"draw"}).ok,"no double draw")
		check(not game.apply_action(0,{"type":"meld","cards":hand.slice(0,3)}).ok,"no public pose")
		check(not game.apply_action(0,{"type":"extend","meld":0,"cards":hand.slice(0,3)}).ok,"no public extension")
		check(game.apply_action(0,{"type":"discard","card":"0:D:2"}).ok,"discard accepted")
		check(game.state.winner==0 and game.state.players[0].hand.size()==size,"win with cards still in hand")
		check(game.view_for(1).winning_tris.size()==(2 if size==6 else 3),"winner groups revealed only after discard")
		check(game.match_result().winners==[0],"winner correctly scored despite nonempty hand")
		var restored := Rules.new()
		check(restored.restore_game(JSON.parse_string(JSON.stringify(game.export_game()))),"finished Tri restores from JSON")
		check(restored.view_for(1).winning_tris==game.view_for(1).winning_tris,"restored winner groups identical")
		inventory(restored)
		check(not game.apply_action(1,{"type":"draw"}).ok,"finished match immutable")
		var invalid := game.export_game()
		invalid.state.tri_goal = 4
		check(not restored.restore_game(invalid),"invalid goal rejected")
		game = rig(hand,size,"0:D:8")
		game.apply_action(0,{"type":"draw"})
		check(restored.restore_game(JSON.parse_string(JSON.stringify(game.export_game()))),"midturn Tri restores")
		check(restored.state.phase=="play" and restored.state.players[0].hand.size()==size+1,"resume cannot draw twice")
		check(game.forfeit_player(0).ok and game.match_result().winners==[1],"abandon loses Tri duel")
		check(restored.restore_game(JSON.parse_string(JSON.stringify(game.export_game()))),"forfeit Tri restores")
	for size in [6,12]:
		for seed_value in range(1,5):
			game = Rules.new()
			game.start_tri_game(["A","B"],size,seed_value)
			for step in range(600):
				if game.state.winner>=0: break
				check(game.bot_step(game.state.turn),"AI makes a legal draw/discard")
				inventory(game)
			check(game.state.winner>=0,"Tri AI duel terminates")
	print("PASS: %d Tri checks" % checks)
	quit()
