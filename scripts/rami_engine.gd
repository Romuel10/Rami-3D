class_name RamiEngine
extends RefCounted
## Rami familial : 2 jeux, 4 jokers, 13 cartes, ouverture de 30 points.
## Toute action est validée avant la première mutation de l'état.

const SUITS := ["S", "H", "D", "C"]
const RANK_LABELS := ["", "A", "2", "3", "4", "5", "6", "7", "8", "9", "10", "V", "D", "R"]
var state: Dictionary = {}
var _rng := RandomNumberGenerator.new()

func card_info(id: String) -> Dictionary:
	if id.begins_with("J:") and id.length() == 3 and id.substr(2).is_valid_int() and int(id.substr(2)) in range(4):
		return {"id": id, "rank": 0, "suit": "J", "joker": true, "points": 20, "label": "Joker"}
	var parts := id.split(":")
	if parts.size() != 3 or not parts[0] in ["0", "1"] or not parts[1] in SUITS or not parts[2].is_valid_int():
		return {}
	var rank := int(parts[2])
	if rank < 1 or rank > 13 or str(rank) != parts[2]:
		return {}
	return {"id": id, "rank": rank, "suit": parts[1], "joker": false, "points": 11 if rank == 1 else mini(rank, 10), "label": RANK_LABELS[rank]}

func start_game(names: Array, seed_value: int = 0, rounds: int = 1) -> Dictionary:
	if names.size() < 2 or names.size() > 4:
		return _fail("Une partie accueille de 2 à 4 joueurs.")
	if seed_value == 0:
		_rng.randomize()
	else:
		_rng.seed = seed_value
	var deck: Array = []
	for copy in range(2):
		for suit in SUITS:
			for rank in range(1, 14):
				deck.append("%d:%s:%d" % [copy, suit, rank])
	for j in range(4):
		deck.append("J:%d" % j)
	_shuffle(deck)
	var players: Array = []
	for i in range(names.size()):
		var player_name := str(names[i]).strip_edges().substr(0, 24)
		players.append({"name": player_name if not player_name.is_empty() else "Joueur %d" % (i + 1), "hand": [], "opened": false})
	for _round in range(13):
		for player in players:
			player.hand.append(deck.pop_back())
	var first_discard = deck.pop_back()
	state = {"players": players, "deck": deck, "discard": [first_discard], "melds": [], "turn": 0, "phase": "draw", "winner": -1, "log": "%s commence : piochez une carte." % players[0].name, "turn_count": 1}
	state["session_id"] = "%x%x" % [_rng.randi(), _rng.randi()]
	state["revision"] = 0
	state["last_action"] = {}
	state["match"] = {"round":1, "length":rounds if rounds in [1,3,5] else 1, "totals":[], "results":[]}
	for _name in names:
		state.match.totals.append(0)
	return {"ok": true, "error": ""}

func apply_action(player_index: int, action: Dictionary) -> Dictionary:
	var result := _apply_checked(player_index, action)
	if result.get("ok", false):
		state["revision"] = int(state.get("revision", 0)) + 1
		state["last_action"] = {"type":str(action.get("type", "")), "player":player_index, "source":str(action.get("source", "deck"))}
		if int(state.winner) >= 0:
			_record_round()
	return result

func _apply_checked(player_index: int, action: Dictionary) -> Dictionary:
	if state.is_empty():
		return _fail("Aucune partie en cours.")
	if player_index < 0 or player_index >= state.players.size():
		return _fail("Joueur inconnu.")
	if state.winner >= 0:
		return _fail("La manche est terminée.")
	if state.turn != player_index:
		return _fail("Ce n'est pas votre tour.")
	var kind = action.get("type", "")
	if not kind is String:
		return _fail("Action inconnue.")
	if kind == "draw":
		return _draw(player_index, action)
	if not kind in ["meld", "extend", "discard"]:
		return _fail("Action inconnue.")
	if state.phase != "play":
		return _fail("Piochez d'abord une carte.")
	match kind:
		"meld":
			return _meld(player_index, action)
		"extend":
			return _extend(player_index, action)
		"discard":
			return _discard(player_index, action)
	return _fail("Action inconnue.")

func view_for(player_index: int) -> Dictionary:
	if state.is_empty():
		return {}
	var players: Array = []
	for player in state.players:
		players.append({"name": player.name, "count": player.hand.size(), "opened": player.opened})
	return {"players": players, "hand": state.players[player_index].hand.duplicate() if player_index >= 0 and player_index < state.players.size() else [], "deck_count": state.deck.size(), "discard_top": state.discard.back() if not state.discard.is_empty() else "", "melds": state.melds.duplicate(true), "turn": state.turn, "phase": state.phase, "winner": state.winner, "log": state.log, "turn_count": state.turn_count, "revision":state.get("revision",0), "last_action":state.get("last_action",{}).duplicate(true), "session_id":state.get("session_id",""), "match":state.get("match",{}).duplicate(true)}

func _draw(index: int, action: Dictionary) -> Dictionary:
	if state.phase != "draw":
		return _fail("Vous avez déjà pioché.")
	var source = action.get("source", "deck")
	if not source in ["deck", "discard"]:
		return _fail("Pioche inconnue.")
	if source == "discard" and state.discard.is_empty():
		return _fail("La défausse est vide.")
	if source == "deck" and state.deck.is_empty() and state.discard.size() < 2:
		return _fail("La pioche est vide. Prenez la défausse.")
	if source == "deck" and state.deck.is_empty():
		var top = state.discard.pop_back()
		state.deck = state.discard.duplicate()
		state.discard = [top]
		_shuffle(state.deck)
	var pile: Array = state.deck if source == "deck" else state.discard
	state.players[index].hand.append(pile.pop_back())
	state.phase = "play"
	state.log = "%s a pioché. Posez vos combinaisons ou défaussez une carte." % state.players[index].name
	return _ok()

func _meld(index: int, action: Dictionary) -> Dictionary:
	var groups = action.get("groups", [action.get("cards", [])])
	if not groups is Array or groups.is_empty() or groups.size() > 4:
		return _fail("Sélectionnez une ou plusieurs combinaisons.")
	var used: Array = []
	var checked: Array = []
	var points := 0
	for cards in groups:
		if not cards is Array:
			return _fail("Combinaison invalide.")
		for id in cards:
			if not id is String or not id in state.players[index].hand or id in used:
				return _fail("Ces cartes ne sont pas toutes disponibles dans votre main.")
			used.append(id)
		var result := _validate_meld(cards)
		if not result.ok:
			return _fail(result.error)
		points += result.points
		checked.append(result)
	if used.size() >= state.players[index].hand.size():
		return _fail("Gardez une carte pour la défausse finale.")
	if not state.players[index].opened and points < 30:
		return _fail("La première pose doit totaliser au moins 30 points.")
	for result in checked:
		state.melds.append({"cards": result.cards, "owner": index, "type": result.type})
	for id in used:
		state.players[index].hand.erase(id)
	state.players[index].opened = true
	state.log = "%s pose %d carte%s (%d points)." % [state.players[index].name, used.size(), "s" if used.size() > 1 else "", points]
	return _ok()

func _extend(index: int, action: Dictionary) -> Dictionary:
	if not state.players[index].opened:
		return _fail("Ouvrez d'abord avec au moins 30 points.")
	var meld_index = action.get("meld", -1)
	if not (meld_index is int or meld_index is float) or float(meld_index) != floor(float(meld_index)) or int(meld_index) < 0 or int(meld_index) >= state.melds.size():
		return _fail("Combinaison inconnue.")
	var cards = action.get("cards", [])
	if not cards is Array or cards.is_empty():
		return _fail("Sélectionnez les cartes à ajouter.")
	var used: Array = []
	for id in cards:
		if not id is String or not id in state.players[index].hand or id in used:
			return _fail("Ces cartes ne sont pas disponibles.")
		used.append(id)
	if used.size() >= state.players[index].hand.size():
		return _fail("Gardez une carte pour la défausse finale.")
	var result := _validate_meld(state.melds[int(meld_index)].cards + cards)
	if not result.ok:
		return _fail("Ces cartes ne prolongent pas cette combinaison.")
	state.melds[int(meld_index)].cards = result.cards
	for id in used:
		state.players[index].hand.erase(id)
	state.log = "%s complète une combinaison." % state.players[index].name
	return _ok()

func _discard(index: int, action: Dictionary) -> Dictionary:
	var id = action.get("card", "")
	if not id is String or not id in state.players[index].hand:
		return _fail("Sélectionnez une carte de votre main à défausser.")
	state.players[index].hand.erase(id)
	state.discard.append(id)
	if state.players[index].hand.is_empty():
		state.winner = index
		state.log = "%s remporte la manche !" % state.players[index].name
	else:
		state.turn = (index + 1) % state.players.size()
		state.phase = "draw"
		state.turn_count += 1
		state.log = "Au tour de %s : piochez une carte." % state.players[state.turn].name
	return _ok()

func _validate_meld(cards: Array) -> Dictionary:
	if cards.size() < 3 or cards.size() > 13:
		return _fail("Une combinaison contient au moins 3 cartes.")
	var seen: Array = []
	var naturals: Array = []
	var jokers: Array = []
	for id in cards:
		if not id is String or id in seen:
			return _fail("Une carte ne peut être utilisée deux fois.")
		seen.append(id)
		var info := card_info(id)
		if info.is_empty():
			return _fail("Carte inconnue.")
		if info.joker:
			jokers.append(id)
		else:
			naturals.append(info)
	if jokers.size() * 2 > cards.size():
		return _fail("Une combinaison doit contenir au moins autant de cartes naturelles que de jokers.")
	var same_rank := true
	var same_suit := true
	var suits: Array = []
	var ranks: Array = []
	for info in naturals:
		same_rank = same_rank and info.rank == naturals[0].rank
		same_suit = same_suit and info.suit == naturals[0].suit
		suits.append(info.suit)
		ranks.append(info.rank)
	if same_rank and cards.size() <= 4 and _unique(suits):
		return {"ok": true, "error": "", "cards": cards.duplicate(), "points": cards.size() * int(naturals[0].points), "type": "set"}
	if not same_suit or not _unique(ranks):
		return _fail("Formez un brelan/carré de couleurs différentes ou une suite d'une même couleur.")
	var best: Dictionary = {}
	for high_ace in [false, true]:
		var by_rank: Dictionary = {}
		for info in naturals:
			by_rank[14 if high_ace and info.rank == 1 else info.rank] = info.id
		var lower := 2 if high_ace else 1
		var upper := 14 if high_ace else 13
		for first in range(lower, upper - cards.size() + 2):
			var last: int = first + cards.size() - 1
			var fits := true
			for rank in by_rank:
				if rank < first or rank > last:
					fits = false
			if not fits:
				continue
			var ordered: Array = []
			var joker_index := 0
			var total := 0
			for rank in range(first, last + 1):
				total += 11 if rank == 14 else mini(rank, 10)
				if by_rank.has(rank):
					ordered.append(by_rank[rank])
				else:
					ordered.append(jokers[joker_index])
					joker_index += 1
			if best.is_empty() or total > best.points:
				best = {"ok": true, "error": "", "cards": ordered, "points": total, "type": "run"}
	if best.is_empty():
		return _fail("La suite doit être consécutive ; l'as peut être avant le 2 ou après le roi.")
	return best

func suggest_melds(index: int) -> Array:
	if state.is_empty() or index < 0 or index >= state.players.size():
		return []
	return _suggest_for_hand(state.players[index].hand, state.players[index].opened)

func _suggest_for_hand(hand: Array, opened: bool) -> Array:
	if hand.size() < 4 or hand.size() > 16:
		return []
	var candidates := _candidates(hand)
	if candidates.is_empty():
		return []
	# Reachable masks choose disjoint combinations. For the same cards, retain
	# the arrangement with the highest opening value (ace/joker ambiguity).
	var reachable: Dictionary = {0: {"points": 0, "groups": []}}
	var best_score := 0
	var best_groups: Array = []
	var full_mask: int = (1 << hand.size()) - 1
	for mask in range(full_mask):
		if not reachable.has(mask):
			continue
		var current: Dictionary = reachable[mask]
		for candidate in candidates:
			if mask & candidate.mask:
				continue
			var new_mask: int = mask | candidate.mask
			if new_mask == full_mask:
				continue
			var points: int = current.points + candidate.points
			if reachable.has(new_mask) and reachable[new_mask].points >= points:
				continue
			var groups: Array = current.groups.duplicate()
			groups.append(candidate.cards)
			reachable[new_mask] = {"points": points, "groups": groups}
			if not opened and points < 30:
				continue
			var score := 0
			for i in range(hand.size()):
				if new_mask & (1 << i):
					score += 100 + int(card_info(hand[i]).points)
			if score > best_score:
				best_score = score
				best_groups = groups
	return best_groups

func _candidates(hand: Array) -> Array:
	var candidates: Array = []
	var keys: Dictionary = {}
	var jokers: Array = []
	var by_rank: Dictionary = {}
	var by_suit: Dictionary = {}
	for suit in SUITS:
		by_suit[suit] = {}
	for id in hand:
		var info := card_info(id)
		if info.joker:
			jokers.append(id)
		else:
			if not by_rank.has(info.rank):
				by_rank[info.rank] = {}
			if not by_rank[info.rank].has(info.suit):
				by_rank[info.rank][info.suit] = id
			if not by_suit[info.suit].has(info.rank):
				by_suit[info.suit][info.rank] = id
	for rank in by_rank:
		var natural_ids: Array = by_rank[rank].values()
		for suit_mask in range(1, 1 << natural_ids.size()):
			var group: Array = []
			for i in range(natural_ids.size()):
				if suit_mask & (1 << i):
					group.append(natural_ids[i])
			for joker_count in range(mini(jokers.size(), group.size()) + 1):
				var with_jokers := group + jokers.slice(0, joker_count)
				if with_jokers.size() >= 3 and with_jokers.size() <= 4:
					_add_candidate(with_jokers, hand, keys, candidates)
	for suit in SUITS:
		for high_ace in [false, true]:
			var lower := 2 if high_ace else 1
			var upper := 14 if high_ace else 13
			for first in range(lower, upper - 1):
				for last in range(first + 2, upper + 1):
					if last - first + 1 >= hand.size():
						continue
					var group: Array = []
					var missing := 0
					for rank in range(first, last + 1):
						var actual_rank := 1 if rank == 14 else rank
						if by_suit[suit].has(actual_rank):
							group.append(by_suit[suit][actual_rank])
						else:
							missing += 1
					if missing <= jokers.size() and missing <= group.size():
						_add_candidate(group + jokers.slice(0, missing), hand, keys, candidates)
	return candidates

func _add_candidate(cards: Array, hand: Array, keys: Dictionary, candidates: Array) -> void:
	var sorted := cards.duplicate()
	sorted.sort()
	var key := ",".join(sorted)
	if keys.has(key):
		return
	var checked := _validate_meld(cards)
	if not checked.ok:
		return
	var mask := 0
	for id in cards:
		mask |= 1 << hand.find(id)
	keys[key] = true
	candidates.append({"cards": checked.cards, "points": checked.points, "mask": mask})

func bot_turn(index: int, difficulty: int = 1) -> void:
	# Compatibility entry point for server simulations: play a whole turn.
	for _step in range(32):
		if not bot_step(index, difficulty):
			break
		if state.winner >= 0 or state.turn != index:
			break

func bot_step(index: int, difficulty: int = 1) -> bool:
	if state.is_empty() or state.winner >= 0 or state.turn != index:
		return false
	if state.phase == "draw":
		return apply_action(index, {"type":"draw", "source":_bot_draw_source(index, difficulty)}).ok
	var groups := suggest_melds(index)
	if not groups.is_empty():
		if difficulty == 0 and state.players[index].opened:
			groups = [groups[0]]
		return apply_action(index, {"type":"meld", "groups":groups}).ok
	# Even an easy opponent must be able to finish a one/two-card hand.
	# Difficulty changes planning, never access to legal table extensions.
	if state.players[index].opened:
		for meld_index in range(state.melds.size()):
			for id in state.players[index].hand:
				if state.players[index].hand.size() > 1 and _validate_meld(state.melds[meld_index].cards + [id]).ok:
					return apply_action(index, {"type":"extend", "meld":meld_index, "cards":[id]}).ok
	return apply_action(index, {"type":"discard", "card":_bot_discard(index, difficulty)}).ok

func _bot_draw_source(index: int, difficulty: int) -> String:
	if state.deck.is_empty() and state.discard.size() < 2:
		return "discard"
	if difficulty == 0 or state.discard.is_empty():
		return "deck"
	var top: String = state.discard.back()
	if card_info(top).joker:
		return "discard"
	for group in _suggest_for_hand(state.players[index].hand + [top], state.players[index].opened):
		if top in group:
			return "discard"
	if state.players[index].opened:
		for meld in state.melds:
			if _validate_meld(meld.cards + [top]).ok:
				return "discard"
	if difficulty == 2 and _card_utility(top, state.players[index].hand) >= 5.0:
		return "discard"
	return "deck"

func _bot_discard(index: int, difficulty: int) -> String:
	var hand: Array = state.players[index].hand
	var worst: String = hand[0]
	var lowest := INF
	for id in hand:
		var info := card_info(id)
		var score := _card_utility(id, hand)
		if difficulty == 0:
			score = 100.0 if info.joker else -float(info.points)
		elif difficulty == 2:
			# Count potential partners using only this hand and public cards.
			# The actual deck and opponents' hands never enter this estimate.
			var known: Array = hand + state.discard
			for meld in state.melds:
				known.append_array(meld.cards)
			var outs := 0.0
			for copy in range(2):
				for suit in SUITS:
					for rank in range(1,14):
						var candidate := "%d:%s:%d" % [copy,suit,rank]
						if candidate in known:
							continue
						if rank == info.rank and suit != info.suit:
							outs += 0.18
						if suit == info.suit and (absi(rank-int(info.rank)) <= 2 or rank in [1,13] and int(info.rank) in [1,13]):
							outs += 0.28
			score += outs
		if score < lowest:
			lowest = score
			worst = id
	return worst

func _card_utility(id: String, hand: Array) -> float:
	var info := card_info(id)
	if info.joker:
		return 100.0
	var utility := -float(info.points) / 15.0
	for other_id in hand:
		if other_id == id:
			continue
		var other := card_info(other_id)
		if other.joker:
			continue
		if other.rank == info.rank and other.suit != info.suit:
			utility += 3.0
		if other.suit == info.suit:
			var distance: int = absi(int(other.rank) - int(info.rank))
			if info.rank == 1 or other.rank == 1:
				distance = mini(distance, absi((14 if other.rank == 1 else int(other.rank)) - (14 if info.rank == 1 else int(info.rank))))
			if distance == 1:
				utility += 3.5
			elif distance == 2:
				utility += 1.5
	return utility

func _unique(values: Array) -> bool:
	var seen: Dictionary = {}
	for value in values:
		if seen.has(value):
			return false
		seen[value] = true
	return true

func _shuffle(cards: Array) -> void:
	for i in range(cards.size() - 1, 0, -1):
		var j := _rng.randi_range(0, i)
		var old = cards[i]
		cards[i] = cards[j]
		cards[j] = old

func _ok() -> Dictionary:
	return {"ok": true, "error": ""}

func _fail(message: String) -> Dictionary:
	return {"ok": false, "error": message}

func _record_round() -> void:
	if not state.has("match"):
		state["match"] = {"round":1,"length":1,"totals":[],"results":[]}
		for _p in state.players:
			state.match.totals.append(0)
	var match_data: Dictionary = state.match
	if match_data.results.size() >= int(match_data.round):
		return
	var penalties: Array = []
	for i in range(state.players.size()):
		var points := 0
		for id in state.players[i].hand:
			points += int(card_info(id).points)
		penalties.append(points)
		match_data.totals[i] = int(match_data.totals[i]) + points
	match_data.results.append({"winner":int(state.winner),"points":penalties})

func next_round() -> Dictionary:
	if state.is_empty() or int(state.winner) < 0:
		return _fail("Terminez cette manche avant la suivante.")
	var previous: Dictionary = state.get("match",{}).duplicate(true)
	if previous.is_empty() or int(previous.round) >= int(previous.length):
		return _fail("Ce match est terminé.")
	var names: Array = []
	for player in state.players:
		names.append(player.name)
	var session: String = str(state.get("session_id",""))
	# Continue the saved random sequence, including after an app restart.
	var deal_seed := maxi(1, int(_rng.randi()))
	start_game(names,deal_seed,int(previous.length))
	previous.round = int(previous.round) + 1
	state.match = previous
	state.session_id = session
	state.turn = (int(previous.round)-1) % names.size()
	state.log = "Manche %d : %s commence." % [int(previous.round),state.players[state.turn].name]
	return _ok()

func selection_preview(view: Dictionary, cards: Array, groups: Array = []) -> Dictionary:
	var result := {"points":0,"can_meld":false,"targets":[]}
	var own := int(view.get("your_index",0))
	var players: Array = view.get("players",[])
	var hand: Array = view.get("hand",[])
	if cards.is_empty() or own < 0 or own >= players.size() or cards.size() >= hand.size() or not _unique(cards):
		return result
	for id in cards:
		if not id in hand:
			return result
	var selected_groups: Array = groups if not groups.is_empty() else [cards]
	var used: Array = []
	var valid := true
	for group in selected_groups:
		var checked := _validate_meld(group)
		if not checked.ok:
			valid = false
			break
		used.append_array(group)
		result.points += int(checked.points)
	if not valid or not _unique(used) or used.size() != cards.size():
		result.points = 0
		valid = false
	for id in used:
		valid = valid and id in cards
	var active: bool = int(view.get("turn",-1)) == own and view.get("phase","") == "play" and not view.get("paused",false) and int(view.get("winner",-1)) < 0
	result.can_meld = active and valid and (players[own].get("opened",false) or result.points >= 30)
	if active and players[own].get("opened",false):
		var melds: Array = view.get("melds",[])
		for i in range(melds.size()):
			if _validate_meld(melds[i].cards + cards).ok:
				result.targets.append(i)
	return result

func export_game() -> Dictionary:
	return {"state":state.duplicate(true),"rng":str(_rng.state)}

func restore_game(saved: Variant) -> bool:
	if not saved is Dictionary or not saved.get("state") is Dictionary:
		return false
	var candidate: Dictionary = saved.state.duplicate(true)
	if not candidate.get("players") is Array or candidate.players.size() < 2 or candidate.players.size() > 4:
		return false
	for field in ["deck","discard","melds"]:
		if not candidate.get(field) is Array:
			return false
	var all_cards: Array = candidate.deck + candidate.discard
	for player in candidate.players:
		if not player is Dictionary or not player.get("hand") is Array or not player.get("opened") is bool or not player.get("name") is String:
			return false
		all_cards.append_array(player.hand)
	for meld in candidate.melds:
		if not meld is Dictionary or not meld.get("cards") is Array:
			return false
		if not _saved_integer(meld.get("owner"), 0, candidate.players.size()-1): return false
		var owner := int(meld.get("owner",-1))
		if owner < 0 or owner >= candidate.players.size():
			return false
		meld.owner = owner
		all_cards.append_array(meld.cards)
	if all_cards.size() != 108 or not _unique(all_cards):
		return false
	for id in all_cards:
		if not id is String or card_info(id).is_empty():
			return false
	for meld in candidate.melds:
		var checked := _validate_meld(meld.cards)
		if not checked.ok: return false
		meld.type = checked.type
	if not candidate.get("log") is String or not candidate.get("session_id") is String or candidate.session_id.is_empty(): return false
	if not candidate.get("last_action",{}) is Dictionary: return false
	for field in ["turn","winner","turn_count","revision"]:
		var raw: Variant = candidate.get(field,0 if field != "winner" else -1)
		if not _saved_integer(raw, -1 if field == "winner" else (1 if field == "turn_count" else 0), 1000000000):
			return false
		candidate[field] = int(raw)
	if candidate.turn < 0 or candidate.turn >= candidate.players.size() or candidate.winner < -1 or candidate.winner >= candidate.players.size() or not candidate.get("phase","") in ["draw","play"]:
		return false
	for i in range(candidate.players.size()):
		if candidate.players[i].hand.is_empty() != (i == candidate.winner): return false
	if not candidate.last_action.is_empty():
		if not _saved_integer(candidate.last_action.get("player"),0,candidate.players.size()-1) or not candidate.last_action.get("type","") in ["draw","meld","extend","discard"]: return false
	var match_data: Variant = candidate.get("match",{})
	if not match_data is Dictionary or not match_data.get("totals") is Array or match_data.totals.size() != candidate.players.size() or not match_data.get("results") is Array:
		return false
	if not _saved_integer(match_data.get("length"),1,5) or not int(match_data.length) in [1,3,5]: return false
	if not _saved_integer(match_data.get("round"),1,int(match_data.length)): return false
	var expected := int(match_data.round) - (1 if candidate.winner < 0 else 0)
	if match_data.results.size() != expected: return false
	var sums: Array = []
	for _player in candidate.players: sums.append(0)
	for result in match_data.results:
		if not result is Dictionary or not _saved_integer(result.get("winner"),0,candidate.players.size()-1) or not result.get("points") is Array or result.points.size() != sums.size(): return false
		for i in range(sums.size()):
			if not _saved_integer(result.points[i],0,2000): return false
			sums[i] += int(result.points[i])
		if int(result.points[int(result.winner)]) != 0: return false
	for i in range(sums.size()):
		if not _saved_integer(match_data.totals[i],0,10000) or int(match_data.totals[i]) != sums[i]: return false
	if candidate.winner >= 0 and int(match_data.results.back().winner) != candidate.winner: return false
	state = candidate
	var rng_text := str(saved.get("rng",""))
	if rng_text.is_valid_int():
		_rng.state = int(rng_text)
	return true

func _saved_integer(value: Variant, minimum: int, maximum: int) -> bool:
	return (value is int or value is float) and is_finite(float(value)) and float(value) == floor(float(value)) and float(value) >= minimum and float(value) <= maximum
