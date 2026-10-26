extends SceneTree

const EngineScript = preload("res://scripts/rami_engine.gd")
var checks := 0

func _init() -> void:
	var game = EngineScript.new()
	_check(game.start_game(["Alice", "Bot"], 42).ok, "start")
	_check(game.state.players[0].hand.size() == 13 and game.state.deck.size() == 81, "108 cards / 13 each")
	var all_cards: Array = game.state.deck + game.state.discard + game.state.players[0].hand + game.state.players[1].hand
	_check(game._unique(all_cards) and all_cards.size() == 108, "unique card identities")
	var same = EngineScript.new()
	same.start_game(["Alice", "Bot"], 42)
	_check(same.state == game.state, "deterministic shuffle")
	var before: Dictionary = game.state.duplicate(true)
	_check(not game.apply_action(1, {"type": "draw"}).ok and game.state == before, "wrong turn is immutable")
	_check(not game.apply_action(0, {"type": "discard", "card": game.state.players[0].hand[0]}).ok and game.state == before, "draw before discard")
	var view: Dictionary = game.view_for(0)
	_check(not view.has("deck") and not view.players[1].has("hand") and view.hand.size() == 13, "opponent hand / deck hidden")
	view.hand.clear()
	view.melds.append({"bad": true})
	_check(game.state.players[0].hand.size() == 13 and game.state.melds.is_empty(), "snapshot cannot mutate state")
	_check(game.apply_action(0, {"type": "draw", "source": "deck"}).ok, "draw")
	before = game.state.duplicate(true)
	_check(not game.apply_action(0, {"type": "draw"}).ok and game.state == before, "one draw only")
	_check(not game.apply_action(0, {"type": "meld", "cards": ["0:S:10", "0:H:10", "0:D:10"]}).ok and game.state == before, "cannot invent meld cards")
	_check(game._validate_meld(["0:S:7", "0:H:7", "0:D:7"]).ok, "three of a kind")
	_check(not game._validate_meld(["0:S:7", "1:S:7", "0:D:7"]).ok, "set needs different suits")
	_check(game._validate_meld(["0:H:1", "0:H:2", "0:H:3"]).points == 6, "ace low")
	_check(game._validate_meld(["0:H:12", "0:H:13", "0:H:1"]).points == 31, "ace high")
	_check(not game._validate_meld(["0:H:13", "0:H:1", "0:H:2"]).ok, "ace cannot wrap")
	_check(game._validate_meld(["0:H:5", "J:0", "0:H:7"]).ok, "joker fills run")
	_check(not game._validate_meld(["0:H:5", "J:0", "J:1"]).ok, "joker majority rejected")
	_check(not game._validate_meld(["0:H:5", "0:H:5", "0:H:7"]).ok, "duplicate card rejected")
	_check(game.card_info("2:S:1").is_empty() and game.card_info("0:S:01").is_empty(), "unknown IDs rejected")
	_setup_hand(game, ["0:H:2", "0:H:3", "0:H:4", "0:S:13"])
	before = game.state.duplicate(true)
	_check(not game.apply_action(0, {"type": "meld", "cards": ["0:H:2", "0:H:3", "0:H:4"]}).ok and game.state == before, "opening under 30 rejected")
	_setup_hand(game, ["0:H:7", "0:H:8", "0:H:9", "0:S:2", "0:D:2", "0:C:2", "0:S:13"])
	_check(game.apply_action(0, {"type": "meld", "groups": [["0:H:7", "0:H:8", "0:H:9"], ["0:S:2", "0:D:2", "0:C:2"]]}).ok, "combined opening reaches 30")
	_check(game.state.players[0].opened and game.state.melds.size() == 2, "opening tracked")
	_check(game.apply_action(0, {"type": "discard", "card": "0:S:13"}).ok and game.state.winner == 0, "final discard wins")
	before = game.state.duplicate(true)
	_check(not game.apply_action(0, {"type": "draw"}).ok and game.state == before, "finished game immutable")
	_setup_hand(game, ["0:H:7", "0:H:8", "0:H:9"])
	_check(not game.apply_action(0, {"type": "meld", "cards": game.state.players[0].hand.duplicate()}).ok, "must keep final discard")
	_setup_hand(game, ["0:H:10", "0:S:13"])
	game.state.players[0].opened = true
	game.state.melds = [{"cards": ["0:H:7", "0:H:8", "0:H:9"], "owner": 1, "type": "run"}]
	_check(game.apply_action(0, {"type": "extend", "meld": 0, "cards": ["0:H:10"]}).ok, "extend other player's run")
	_setup_hand(game, ["0:S:9", "0:H:9", "0:D:9", "0:C:9", "0:H:5", "0:H:6", "0:H:7", "0:S:1"])
	var groups: Array = game.suggest_melds(0)
	_check(not groups.is_empty() and game.apply_action(0, {"type": "meld", "groups": groups}).ok, "suggestions form a legal opening")
	game.start_game(["A", "B"], 17)
	game.state.deck.clear()
	game.state.discard = ["0:H:3", "0:H:4", "0:H:5"]
	_check(game.apply_action(0, {"type": "draw", "source": "deck"}).ok and game.state.deck.size() == 1 and game.state.discard == ["0:H:5"], "recycle keeps top discard")
	# Whole-game tests assert card conservation, valid melds, turn progression,
	# and actual victories rather than mirroring the AI's selection algorithm.
	var finished := 0
	for seed_value in range(1, 6):
		game.start_game(["Bot A", "Bot B", "Bot C"], seed_value)
		for turn in range(350):
			var old_turn_count: int = game.state.turn_count
			game.bot_turn(game.state.turn)
			if game.state.winner >= 0:
				finished += 1
				break
			_check(game.state.turn_count == old_turn_count + 1, "bot completes a turn")
			_check(_conserves_cards(game), "card conservation during play")
			for meld in game.state.melds:
				_check(game._validate_meld(meld.cards).ok, "all table melds remain legal")
	_check(finished >= 4, "bots complete whole games (%d/5)" % finished)
	print("PASS: %d engine checks; bots finished %d/5 games" % [checks, finished])
	quit(0)

func _setup_hand(game, cards: Array) -> void:
	game.start_game(["Alice", "Bob"], 1)
	game.state.players[0].hand = cards.duplicate()
	game.state.phase = "play"

func _conserves_cards(game) -> bool:
	var cards: Array = game.state.deck + game.state.discard
	for player in game.state.players:
		cards += player.hand
	for meld in game.state.melds:
		cards += meld.cards
	return cards.size() == 108 and game._unique(cards)

func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		push_error("FAIL: " + message)
		quit(1)
		assert(condition, message)
