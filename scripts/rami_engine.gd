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

func start_game(names: Array, seed_value: int = 0) -> Dictionary:
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
	return {"ok": true, "error": ""}

func apply_action(player_index: int, action: Dictionary) -> Dictionary:
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
	return {"players": players, "hand": state.players[player_index].hand.duplicate() if player_index >= 0 and player_index < state.players.size() else [], "deck_count": state.deck.size(), "discard_top": state.discard.back() if not state.discard.is_empty() else "", "melds": state.melds.duplicate(true), "turn": state.turn, "phase": state.phase, "winner": state.winner, "log": state.log, "turn_count": state.turn_count}

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

func bot_turn(index: int) -> void:
	if state.is_empty() or state.winner >= 0 or state.turn != index:
		return
	if state.phase == "draw":
		var source := "deck"
		if not state.discard.is_empty():
			var top: String = state.discard.back()
			if card_info(top).joker:
				source = "discard"
			else:
				var possible := _suggest_for_hand(state.players[index].hand + [top], state.players[index].opened)
				for group in possible:
					if top in group:
						source = "discard"
				if state.players[index].opened:
					for meld in state.melds:
						if _validate_meld(meld.cards + [top]).ok:
							source = "discard"
		if state.deck.is_empty() and state.discard.size() < 2:
			source = "discard"
		if not apply_action(index, {"type": "draw", "source": source}).ok:
			return
	var groups := suggest_melds(index)
	if not groups.is_empty():
		apply_action(index, {"type": "meld", "groups": groups})
	if state.players[index].opened:
		var changed := true
		while changed and state.players[index].hand.size() > 1:
			changed = false
			for meld_index in range(state.melds.size()):
				for id in state.players[index].hand.duplicate():
					if _validate_meld(state.melds[meld_index].cards + [id]).ok:
						if apply_action(index, {"type": "extend", "meld": meld_index, "cards": [id]}).ok:
							changed = true
							break
				if changed:
					break
	var worst: String = state.players[index].hand[0]
	var worst_score := INF
	for id in state.players[index].hand:
		var score := _card_utility(id, state.players[index].hand)
		if score < worst_score:
			worst_score = score
			worst = id
	apply_action(index, {"type": "discard", "card": worst})

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
