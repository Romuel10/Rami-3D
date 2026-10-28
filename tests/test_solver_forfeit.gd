extends SceneTree
## Regression coverage for physical duplicate/joker planning and departures.
const Rules = preload("res://scripts/rami_engine.gd")
var checks := 0
var failures: Array[String] = []

func _initialize() -> void:
	_solver_checks()
	_forfeit_checks()
	_match_checks()
	print("RESULT: %d solver/forfeit checks; %d failures" % [checks,failures.size()])
	quit(0 if failures.is_empty() else 1)

func _check(value: bool, description: String) -> void:
	checks += 1
	if not value:
		failures.append(description)
		push_error("FAIL: " + description)

func _full_deck() -> Array:
	var cards: Array = []
	for copy in range(2):
		for suit in Rules.SUITS:
			for rank in range(1,14): cards.append("%d:%s:%d" % [copy,suit,rank])
	for i in range(4): cards.append("J:%d" % i)
	return cards

func _set_hand(game, cards: Array, owner: int = 0) -> void:
	var pool := _full_deck()
	for id in cards: pool.erase(id)
	game.state.melds = []
	for i in range(game.state.players.size()):
		if i == owner:
			game.state.players[i].hand = cards.duplicate()
		else:
			game.state.players[i].hand = pool.slice(0,13)
			pool = pool.slice(13)
	game.state.discard = [pool.pop_back()]
	game.state.deck = pool
	game.state.phase = "play"
	game.state.turn = owner

func _conserves(game) -> bool:
	var cards: Array = game.state.deck + game.state.discard
	for player in game.state.players: cards.append_array(player.hand)
	for meld in game.state.melds: cards.append_array(meld.cards)
	return cards.size() == 108 and game._unique(cards)

func _json_restore(game) -> bool:
	return Rules.new().restore_game(JSON.parse_string(JSON.stringify(game.export_game())))

func _solver_checks() -> void:
	var game := Rules.new()
	game.start_game(["Alice","Bob"],42)
	var hand := ["0:H:6","0:H:7","0:H:8","1:H:7","0:C:7","0:D:7","0:S:2","0:S:4","0:S:9","0:S:12","0:D:2","0:D:10","0:C:3","0:C:11"]
	_set_hand(game,hand)
	_check(_conserves(game) and Rules.new().restore_game(game.export_game()),"duplicate regression is a valid108-card saved position")
	var before := game.export_game()
	var groups: Array = game.suggest_melds(0)
	_check(game.export_game() == before,"planning does not mutate a real game")
	_check(groups.size() == 2,"physical copies allow two separate opening groups")
	var total := 0
	var used: Array = []
	for group in groups:
		var checked: Dictionary = game._validate_meld(group)
		_check(checked.ok,"every duplicate suggestion is a legal meld")
		total += checked.points
		used.append_array(group)
	_check(total == 42 and used.size() == 6 and game._unique(used),"42point opening uses six distinct physical cards")
	_check(game.apply_action(0,{"type":"meld","groups":groups}).ok,"42point suggestion actually opens")
	_check(_conserves(game) and game.state.players[0].opened,"duplicate opening preserves cards and opening state")
	game.start_game(["Alice","Bob"],42)
	_set_hand(game,["0:H:7","0:H:8","0:C:7","0:C:8","J:0","J:1","0:S:2"])
	groups = game.suggest_melds(0)
	used.clear()
	for group in groups: used.append_array(group)
	_check(groups.size() == 2 and used.size() == 6 and "J:0" in used and "J:1" in used,"separate joker identities can serve separate runs")
	_check(game.apply_action(0,{"type":"meld","groups":groups}).ok,"multi-joker opening is playable")
	# Compare the fast generator with all legal physical subsets on small
	# adversarial hands. This also checks joker substitution when a natural
	# card at the same rank should remain available to another meld.
	for cards in [["0:H:6","0:H:7","1:H:7","0:H:8","0:C:7","J:0","0:S:2"], ["0:H:7","0:H:8","0:C:7","0:C:8","J:0","J:1","0:S:2"]]:
		var actual: Dictionary = {}
		for candidate in game._candidates(cards): actual[int(candidate.mask)] = true
		for mask in range(1,(1 << cards.size())-1):
			var subset: Array = []
			for i in range(cards.size()):
				if mask & (1 << i): subset.append(cards[i])
			_check(actual.has(mask) == bool(game._validate_meld(subset).ok),"candidate completeness mask%d" % mask)
	var rich: Array = []
	for rank in range(1,11): rich.append("0:H:%d" % rank)
	rich.append_array(["J:0","J:1","J:2","J:3"])
	var start := Time.get_ticks_msec()
	groups = game._suggest_for_hand(rich,false)
	used.clear()
	for group in groups: used.append_array(group)
	_check(Time.get_ticks_msec()-start < 5000,"four-joker worst-case planning stays bounded")
	_check(used.size() == 13 and not "0:H:2" in used,"joker-rich planner reaches provable best used-card score")

func _forfeit_checks() -> void:
	var game := Rules.new()
	game.start_game(["Alice","Bob"],8,3)
	var original := game.export_game()
	_check(not game.forfeit_player(-1).ok and not game.forfeit_player(2).ok and game.export_game() == original,"invalid departure indices leave an active match untouched")
	var cards_before: Array = game.state.players[0].hand.duplicate()
	_check(game.forfeit_player(0).ok,"player may abandon immediately")
	_check(game.state.winner == 1 and game.state.win_by_forfeit,"opponent immediately wins by forfeit")
	_check(game.state.players[0].hand == cards_before and _conserves(game),"forfeit keeps all physical cards in place")
	_check(game.match_result().finished and game.match_result().winners == [1] and game.match_result().forfeit,"forfeit ends a whole multi-round match")
	_check(game.state.match.results.size() == 1 and game.state.match.results[0].points[1] == 0,"forfeit winner has zero penalty without fake discard")
	_check(Rules.new().restore_game(game.export_game()) and _json_restore(game),"binary and JSON forfeit round trips remain valid")
	var before := game.export_game()
	_check(not game.forfeit_player(0).ok and not game.next_round().ok and game.export_game() == before,"duplicate forfeit and next round cannot change ended match")
	_check(not game.apply_action(1,{"type":"draw"}).ok,"no game action follows forfeit victory")
	var broken: Dictionary = game.export_game()
	broken.state.forfeit_winners = [0]
	_check(not Rules.new().restore_game(broken),"a forfeited player cannot be restored as winner")
	broken = game.export_game()
	broken.state.win_by_forfeit = false
	_check(not Rules.new().restore_game(broken),"nonempty-hand victory cannot masquerade as normal discard win")
	game.start_game(["Alice","Bob","Camille","Dani"],9,3)
	game.apply_action(0,{"type":"draw"})
	_check(game.forfeit_player(2,"abandon").ok and game.state.turn == 0 and game.state.phase == "play","out-of-turn departure preserves current active turn")
	_check(not game.apply_action(2,{"type":"draw"}).ok,"eliminated player cannot act")
	_check(game.forfeit_player(0,"deconnexion").ok and game.state.turn == 1 and game.state.phase == "draw","current player departure passes turn and resets draw phase")
	_check(game.state.winner == -1 and _conserves(game),"multiple active opponents continue with108 cards")
	var view: Dictionary = game.view_for(1)
	_check(view.forfeited == [0,2] and view.players[0].forfeited and not view.players[0].has("hand"),"forfeit markers are public while opponent hands stay private")
	_check(_json_restore(game),"ongoing eliminated game survives JSON server save")
	_check(game.apply_action(1,{"type":"draw"}).ok,"remaining active player can continue")
	_check(game.apply_action(1,{"type":"discard","card":game.state.players[1].hand[0]}).ok and game.state.turn == 3,"normal turns skip all eliminated players")
	_check(game.forfeit_player(3,"abandon").ok and game.state.winner == 1,"last remaining active player wins automatically")
	_check(_conserves(game) and _json_restore(game),"several eliminations conserve and restore all cards")
	game.start_game(["Hôte","Bob","Camille"],10)
	_check(game.forfeit_player(0,"hote_abandon",true).ok,"LAN host can end authority by abandonment")
	_check(game.match_result().winners == [1,2] and game.match_result().finished,"all remaining LAN opponents become co-winners")
	_check(game.state.match.results[0].points[1] == 0 and game.state.match.results[0].points[2] == 0,"co-winners have zero forfeit penalty")
	_check(_conserves(game) and _json_restore(game),"LAN host-departure outcome remains fully restorable")
	game.start_game(["Alice","Bob","Camille","Dani"],11,3)
	game.forfeit_player(1)
	_set_hand(game,["0:S:2"],2)
	_check(game.apply_action(2,{"type":"discard","card":"0:S:2"}).ok,"remaining player ends a round after an elimination")
	var restored := Rules.new()
	_check(restored.restore_game(JSON.parse_string(JSON.stringify(game.export_game()))),"completed round with an eliminated player survives JSON")
	_check(game.next_round().ok and restored.next_round().ok and restored.state.players == game.state.players and restored.state.deck == game.state.deck and restored.state.discard == game.state.discard and restored._rng.state == game._rng.state,"next deal after elimination remains reproducible across restart")
	_check(game.state.players[1].forfeited and game.state.turn == 2 and game.state.phase == "draw","next round preserves elimination and skips eliminated opening player")
	_check(not game.bot_step(1) and _conserves(game) and _json_restore(game),"eliminated bot cannot act after a fresh deal")

func _match_checks() -> void:
	var game := Rules.new()
	game.start_game(["Alice","Bob"],15,3)
	# Alice loses two equal-penalty rounds, then wins the third. Final ranking
	# must name Bob, even though state.winner names latest-round winner Alice.
	for round_index in range(3):
		var winner := 1 if round_index < 2 else 0
		_set_hand(game,["0:S:2"],winner)
		_check(game.apply_action(winner,{"type":"discard","card":"0:S:2"}).ok,"controlled round ends legally")
		_check(_conserves(game) and _json_restore(game),"completed normal round conserves and restores")
		if round_index < 2:
			_check(not game.match_result().finished and game.match_result().round_finished,"round victory is distinct from unfinished match")
			_check(game.next_round().ok,"normal multi-round match advances")
	_check(game.state.winner == 0 and game.match_result().winners == [1],"last-round winner is not automatically match winner")
	_check(game.match_result().finished and not game.match_result().forfeit,"normal cumulative match reports finished without forfeit")
	game.state.match.totals = [20,20]
	_check(game.match_result().winners == [0,1],"tied cumulative totals report both match winners")
	game.state.players[0].forfeited = true
	_check(game.match_result().winners == [1],"a previously eliminated player cannot win final ranking")
