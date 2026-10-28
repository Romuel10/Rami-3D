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
		players.append({"name": player_name if not player_name.is_empty() else "Joueur %d" % (i + 1), "hand": [], "opened": false, "forfeited": false})
	for _round in range(13):
		for player in players:
			player.hand.append(deck.pop_back())
	var first_discard = deck.pop_back()
	state = {"players": players, "deck": deck, "discard": [first_discard], "melds": [], "turn": 0, "phase": "draw", "winner": -1, "log": "%s commence : piochez une carte." % players[0].name, "turn_count": 1}
	state["session_id"] = "%x%x" % [_rng.randi(), _rng.randi()]
	state["revision"] = 0
	state["last_action"] = {}
	state["win_by_forfeit"] = false
	state["end_reason"] = ""
	state["forfeit_winners"] = []
	state["match"] = {"round":1, "length":rounds if rounds in [1,3,5] else 1, "totals":[], "results":[]}
	for _name in names:
		state.match.totals.append(0)
	return {"ok": true, "error": ""}

func start_tri_game(names: Array, hand_size: int = 6, seed_value: int = 0) -> Dictionary:
	if names.size() != 2 or not hand_size in [6,12]:
		return _fail("Le Tri se joue en duel, avec 6 ou 12 cartes par joueur.")
	start_game(names, seed_value, 1)
	var cards: Array = state.deck + state.discard
	for player in state.players:
		cards.append_array(player.hand)
		player.hand = []
	cards = cards.filter(func(id): return not card_info(id).joker)
	_shuffle(cards)
	for _deal in range(hand_size):
		for player in state.players: player.hand.append(cards.pop_back())
	state.deck = cards
	state.discard = [state.deck.pop_back()]
	state["variant"] = "tri"
	state["tri_hand_size"] = hand_size
	state["tri_goal"] = 2 if hand_size == 6 else 3
	state.log = "Tri : gardez vos combinaisons en main. Piochez, puis défaussez."
	return _ok()

func tri_groups(cards: Array) -> Array:
	# Per-rank search prevents a physical card from belonging to two tris.
	var ranks: Dictionary = {}
	for id in cards:
		if not id is String: return []
		var info := card_info(id)
		if info.is_empty() or info.joker: continue
		if not ranks.has(info.rank): ranks[info.rank] = []
		if id in ranks[info.rank]: return []
		ranks[info.rank].append(id)
	var result: Array = []
	for rank in ranks: result.append_array(_tri_rank_groups(ranks[rank]))
	return result

func _tri_rank_groups(cards: Array) -> Array:
	var best: Array = []
	for a in range(cards.size()-2):
		for b in range(a+1,cards.size()-1):
			for c in range(b+1,cards.size()):
				if card_info(cards[a]).suit == card_info(cards[b]).suit and card_info(cards[b]).suit == card_info(cards[c]).suit: continue
				var group: Array = [cards[a],cards[b],cards[c]]
				var rest: Array = cards.duplicate()
				for id in group: rest.erase(id)
				var found: Array = [group] + _tri_rank_groups(rest)
				if found.size() > best.size(): best = found
				if best.size() == cards.size()/3: return best
	return best

func _tri_score(cards: Array) -> int:
	var groups := tri_groups(cards)
	var rest := cards.duplicate()
	for group in groups:
		for id in group: rest.erase(id)
	var counts: Dictionary = {}
	for id in rest:
		var rank: int = card_info(id).rank
		counts[rank] = int(counts.get(rank,0)) + 1
	var score: int = groups.size()*1000
	for count in counts.values(): score += 30 * (int(count)/2)
	return score

func _tri_discard(cards: Array) -> String:
	var best: String = cards[0]
	var best_score := -1
	for id in cards:
		var rest := cards.duplicate()
		rest.erase(id)
		var score := _tri_score(rest)
		if score > best_score:
			best_score = score
			best = id
	return best

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
	if bool(state.players[player_index].get("forfeited", false)):
		return _fail("Vous avez abandonné cette partie.")
	if state.turn != player_index:
		return _fail("Ce n'est pas votre tour.")
	var kind = action.get("type", "")
	if not kind is String:
		return _fail("Action inconnue.")
	if kind == "draw":
		return _draw(player_index, action)
	if state.get("variant", "rami") == "tri" and kind in ["meld","extend"]:
		return _fail("Au Tri, les combinaisons restent en main jusqu’à la victoire.")
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
		players.append({"name": player.name, "count": player.hand.size(), "opened": player.opened, "forfeited":bool(player.get("forfeited",false))})
	return {"players": players, "hand": state.players[player_index].hand.duplicate() if player_index >= 0 and player_index < state.players.size() else [], "deck_count": state.deck.size(), "discard_top": state.discard.back() if not state.discard.is_empty() else "", "melds": state.melds.duplicate(true), "turn": state.turn, "phase": state.phase, "winner": state.winner, "log": state.log, "turn_count": state.turn_count, "revision":state.get("revision",0), "last_action":state.get("last_action",{}).duplicate(true), "session_id":state.get("session_id",""), "match":state.get("match",{}).duplicate(true), "forfeited":_forfeited_indices(), "end_reason":state.get("end_reason",""), "win_by_forfeit":state.get("win_by_forfeit",false), "match_result":match_result(), "variant":state.get("variant","rami"), "tri_hand_size":state.get("tri_hand_size",0), "tri_goal":state.get("tri_goal",0), "winning_tris":tri_groups(state.players[state.winner].hand).slice(0,int(state.get("tri_goal",0))) if state.get("variant", "rami") == "tri" and state.winner >= 0 and not state.get("win_by_forfeit",false) else []}

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
	if state.players[index].hand.is_empty() or (state.get("variant","rami") == "tri" and tri_groups(state.players[index].hand).size() >= int(state.tri_goal)):
		state.winner = index
		state.log = "%s remporte la manche !" % state.players[index].name
	else:
		state.turn = _next_active_player(index)
		state.phase = "draw"
		state.turn_count += 1
		state.log = "Au tour de %s : piochez une carte." % state.players[state.turn].name
	return _ok()

func forfeit_player(index: int, reason: String = "abandon", finish_match: bool = false) -> Dictionary:
	if state.is_empty(): return _fail("Aucune partie en cours.")
	if index < 0 or index >= state.players.size(): return _fail("Joueur inconnu.")
	if int(state.winner) >= 0: return _fail("La manche est déjà terminée.")
	if bool(state.players[index].get("forfeited",false)): return _fail("Ce joueur a déjà abandonné.")
	state.players[index]["forfeited"] = true
	var remaining: Array = []
	for i in range(state.players.size()):
		if not bool(state.players[i].get("forfeited",false)): remaining.append(i)
	state["revision"] = int(state.get("revision",0)) + 1
	state["last_action"] = {"type":"forfeit","player":index,"reason":reason}
	if remaining.size() == 1 or finish_match:
		state["winner"] = int(remaining[0])
		state["win_by_forfeit"] = true
		state["end_reason"] = reason if not reason.is_empty() else "abandon"
		state["forfeit_winners"] = remaining.duplicate()
		state.log = "%s abandonne. %s remporte le match par forfait." % [state.players[index].name, state.players[state.winner].name] if remaining.size() == 1 else "%s abandonne. Les autres joueurs gagnent par forfait." % state.players[index].name
		_record_round()
	else:
		if int(state.turn) == index:
			state.turn = _next_active_player(index)
			state.phase = "draw"
			state.turn_count += 1
		state.log = "%s abandonne ; les autres joueurs continuent." % state.players[index].name
	return _ok()

func _forfeited_indices() -> Array:
	var result: Array = []
	if state.is_empty(): return result
	for i in range(state.players.size()):
		if bool(state.players[i].get("forfeited",false)): result.append(i)
	return result

func _next_active_player(after: int) -> int:
	for offset in range(1,state.players.size()+1):
		var index: int = (after+offset) % state.players.size()
		if not bool(state.players[index].get("forfeited",false)): return index
	return after

func match_result() -> Dictionary:
	var result := {"finished":false,"winners":[],"forfeit":false,"reason":"","round_finished":false,"round_winner":-1}
	if state.is_empty(): return result
	result.round_finished = int(state.get("winner",-1)) >= 0
	result.round_winner = int(state.get("winner",-1))
	if bool(state.get("win_by_forfeit",false)):
		result.finished = true
		result.forfeit = true
		result.reason = str(state.get("end_reason","abandon"))
		result.winners = state.get("forfeit_winners",[state.winner]).duplicate()
		return result
	var scores: Dictionary = state.get("match",{})
	if not result.round_finished or int(scores.get("round",1)) < int(scores.get("length",1)):
		return result
	result.finished = true
	var totals: Array = scores.get("totals",[])
	var best := 2147483647
	for i in range(state.players.size()):
		if state.players[i].get("forfeited",false): continue
		var total: int = int(totals[i]) if i < totals.size() else 0
		if total < best:
			best = total
			result.winners = [i]
		elif total == best:
			result.winners.append(i)
	return result

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
	# Partition a used-card mask around its lowest card. Every partition has
	# exactly one group containing that card, so this avoids exploring every
	# permutation of the same disjoint groups.
	var full_mask: int = (1 << hand.size()) - 1
	var by_lowest: Dictionary = {}
	var by_mask: Dictionary = {}
	var card_weights: Array = []
	var all_score := 0
	var minimum_weight := 2147483647
	for id in hand:
		var weight := 100 + int(card_info(id).points)
		card_weights.append(weight)
		all_score += weight
		minimum_weight = mini(minimum_weight,weight)
	var usable_mask := 0
	for candidate in candidates: usable_mask |= int(candidate.mask)
	var upper_score := 0
	for i in range(hand.size()):
		if usable_mask & (1 << i): upper_score += int(card_weights[i])
	if usable_mask == full_mask: upper_score = all_score-minimum_weight
	# A single long run can already attain the provable optimum, especially
	# joker-rich hands. Return it before attempting any group partitions.
	for candidate in candidates:
		if not opened and int(candidate.points) < 30: continue
		var score := 0
		for i in range(hand.size()):
			if candidate.mask & (1 << i): score += int(card_weights[i])
		if score == upper_score: return [candidate.cards]
	for candidate in candidates:
		by_mask[candidate.mask] = candidate
		for i in range(hand.size()):
			var bit := 1 << i
			if candidate.mask & bit:
				if not by_lowest.has(bit): by_lowest[bit] = []
				by_lowest[bit].append(candidate)
	for bucket in by_lowest.values():
		bucket.sort_custom(func(a,b): return int(a.mask) < int(b.mask))
	var points := PackedInt32Array()
	var chosen := PackedInt32Array()
	var group_count := PackedInt32Array()
	var scores := PackedInt32Array()
	points.resize(full_mask+1)
	points.fill(-1)
	points[0] = 0
	chosen.resize(full_mask+1)
	group_count.resize(full_mask+1)
	scores.resize(full_mask+1)
	var bit_scores: Dictionary = {}
	for i in range(hand.size()):
		bit_scores[1 << i] = card_weights[i]
	var best_score := 0
	var best_mask := 0
	for mask in range(1,full_mask):
		var bit: int = mask & -mask
		scores[mask] = scores[mask ^ bit] + int(bit_scores[bit])
		if mask & usable_mask != mask: continue
		for candidate in by_lowest.get(bit,[]):
			var candidate_mask: int = candidate.mask
			if candidate_mask > mask: break
			if candidate_mask & mask != candidate_mask: continue
			var rest: int = mask ^ candidate_mask
			if points[rest] < 0 or group_count[rest] >= 4: continue
			var total: int = points[rest] + int(candidate.points)
			if total > points[mask] or total == points[mask] and group_count[rest]+1 < group_count[mask]:
				points[mask] = total
				chosen[mask] = candidate_mask
				group_count[mask] = group_count[rest]+1
		if points[mask] >= (0 if opened else 30) and scores[mask] > best_score:
			best_score = scores[mask]
			best_mask = mask
			if best_score == upper_score: break
	var groups: Array = []
	while best_mask != 0:
		var selected_mask: int = chosen[best_mask]
		groups.append(by_mask[selected_mask].cards)
		best_mask ^= selected_mask
	return groups

func _candidates(hand: Array) -> Array:
	# A physical-card bitmask represents every duplicate copy and every joker
	# independently. There are at most 16,384 subsets in a real 14-card hand.
	# Incremental bit fields reject impossible groups before allocating arrays
	# or calling the complete meld validator; there is no Cartesian expansion.
	var size := hand.size()
	if size < 3 or size > 16:
		return []
	var card_ranks := PackedInt32Array()
	var card_suits := PackedInt32Array()
	var bit_indices: Dictionary = {}
	for i in range(size):
		var info := card_info(str(hand[i]))
		if info.is_empty():
			return []
		card_ranks.append(0 if info.joker else (1 << (int(info.rank)-1)))
		card_suits.append(0 if info.joker else (1 << SUITS.find(info.suit)))
		bit_indices[1 << i] = i
	var limit := 1 << size
	var counts := PackedInt32Array()
	var jokers := PackedInt32Array()
	var ranks := PackedInt32Array()
	var suits := PackedInt32Array()
	var distinct_ranks := PackedInt32Array()
	var distinct_suits := PackedInt32Array()
	counts.resize(limit)
	jokers.resize(limit)
	ranks.resize(limit)
	suits.resize(limit)
	distinct_ranks.resize(limit)
	distinct_suits.resize(limit)
	var candidates: Array = []
	for mask in range(1, limit):
		var rest: int = mask & (mask-1)
		var index: int = int(bit_indices[mask ^ rest])
		var rank_bit: int = card_ranks[index]
		var suit_bit: int = card_suits[index]
		counts[mask] = counts[rest] + 1
		jokers[mask] = jokers[rest] + (1 if rank_bit == 0 else 0)
		ranks[mask] = ranks[rest] | rank_bit
		suits[mask] = suits[rest] | suit_bit
		distinct_ranks[mask] = distinct_ranks[rest] + (1 if rank_bit != 0 and not (ranks[rest] & rank_bit) else 0)
		distinct_suits[mask] = distinct_suits[rest] + (1 if suit_bit != 0 and not (suits[rest] & suit_bit) else 0)
		var length: int = counts[mask]
		if length < 3 or length >= size or length > 13 or jokers[mask]*2 > length:
			continue
		var natural_count: int = length-jokers[mask]
		var is_set: bool = length <= 4 and distinct_ranks[mask] == 1 and distinct_suits[mask] == natural_count
		var is_run: bool = distinct_suits[mask] == 1 and distinct_ranks[mask] == natural_count and _run_span_fits(ranks[mask], length)
		if not is_set and not is_run:
			continue
		var cards: Array = []
		for i in range(size):
			if mask & (1 << i):
				cards.append(hand[i])
		var checked := _validate_meld(cards)
		if checked.ok:
			candidates.append({"cards":checked.cards,"points":checked.points,"mask":mask})
	return candidates

func _run_span_fits(rank_bits: int, length: int) -> bool:
	var first := 14
	var last := 0
	var high_first := 14
	var high_last := 0
	for rank in range(1,14):
		if rank_bits & (1 << (rank-1)):
			first = mini(first,rank)
			last = maxi(last,rank)
			var high_rank := 14 if rank == 1 else rank
			high_first = mini(high_first,high_rank)
			high_last = maxi(high_last,high_rank)
	return last-first+1 <= length or high_last-high_first+1 <= length

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
	if state.is_empty() or state.winner >= 0 or state.turn != index or index < 0 or index >= state.players.size() or state.players[index].get("forfeited",false):
		return false
	if state.get("variant","rami") == "tri":
		var hand: Array = state.players[index].hand
		if state.phase == "draw":
			var source := "deck"
			if not state.discard.is_empty():
				var with_top: Array = hand + [state.discard.back()]
				var drop := _tri_discard(with_top)
				with_top.erase(drop)
				if _tri_score(with_top) > _tri_score(hand) or state.deck.is_empty(): source = "discard" if state.discard.size() < 2 or not state.deck.is_empty() else "deck"
			return apply_action(index, {"type":"draw","source":source}).ok
		return apply_action(index, {"type":"discard","card":_tri_discard(hand)}).ok
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
		if (bool(state.get("win_by_forfeit",false)) and i in state.get("forfeit_winners",[])) or (state.get("variant","rami") == "tri" and i == int(state.winner)):
			points = 0
		penalties.append(points)
		match_data.totals[i] = int(match_data.totals[i]) + points
	var result := {"winner":int(state.winner),"points":penalties}
	if bool(state.get("win_by_forfeit",false)):
		result["forfeit"] = true
		result["reason"] = str(state.get("end_reason","abandon"))
		result["winners"] = state.get("forfeit_winners",[]).duplicate()
	match_data.results.append(result)

func next_round() -> Dictionary:
	if not state.is_empty() and bool(state.get("win_by_forfeit",false)):
		return _fail("Ce match est terminé par abandon.")
	if state.is_empty() or int(state.winner) < 0:
		return _fail("Terminez cette manche avant la suivante.")
	var previous: Dictionary = state.get("match",{}).duplicate(true)
	if previous.is_empty() or int(previous.round) >= int(previous.length):
		return _fail("Ce match est terminé.")
	var names: Array = []
	var eliminated := _forfeited_indices()
	for player in state.players:
		names.append(player.name)
	var session: String = str(state.get("session_id",""))
	# Continue the saved random sequence, including after an app restart.
	var deal_seed := maxi(1, int(_rng.randi()))
	start_game(names,deal_seed,int(previous.length))
	previous.round = int(previous.round) + 1
	state.match = previous
	state.session_id = session
	for index in eliminated:
		state.players[index].forfeited = true
	state.turn = (int(previous.round)-1) % names.size()
	if state.players[state.turn].get("forfeited",false):
		state.turn = _next_active_player(state.turn)
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
		if not player.get("forfeited",false) is bool: return false
		player["forfeited"] = bool(player.get("forfeited",false))
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
	var tri: bool = candidate.get("variant","rami") == "tri"
	if not candidate.get("variant","rami") in ["rami","tri"]: return false
	if tri:
		if candidate.players.size() != 2 or not _saved_integer(candidate.get("tri_hand_size"),6,12) or not int(candidate.tri_hand_size) in [6,12]: return false
		candidate.tri_hand_size = int(candidate.tri_hand_size)
		if candidate.get("tri_goal") != (2 if candidate.tri_hand_size == 6 else 3) or not candidate.melds.is_empty(): return false
		candidate.tri_goal = int(candidate.tri_goal)
		for i in range(candidate.players.size()):
			if candidate.players[i].opened: return false
			var expected_count: int = candidate.tri_hand_size + (1 if i == candidate.get("turn") and candidate.get("phase") == "play" and candidate.get("winner") == -1 else 0)
			if candidate.players[i].hand.size() != expected_count and not candidate.get("win_by_forfeit",false): return false
	if all_cards.size() != (104 if tri else 108) or not _unique(all_cards):
		return false
	for id in all_cards:
		if not id is String or card_info(id).is_empty() or (tri and card_info(id).joker):
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
	if not candidate.get("win_by_forfeit",false) is bool or not candidate.get("end_reason","") is String:
		return false
	candidate["win_by_forfeit"] = bool(candidate.get("win_by_forfeit",false))
	candidate["end_reason"] = str(candidate.get("end_reason",""))
	var forfeit_winners: Variant = candidate.get("forfeit_winners",[])
	if not forfeit_winners is Array or not _unique(forfeit_winners): return false
	var normalized_winners: Array = []
	for index in forfeit_winners:
		if not _saved_integer(index,0,candidate.players.size()-1) or candidate.players[int(index)].forfeited: return false
		normalized_winners.append(int(index))
	forfeit_winners = normalized_winners
	candidate["forfeit_winners"] = normalized_winners
	if candidate.win_by_forfeit:
		if candidate.winner < 0 or forfeit_winners.is_empty() or not candidate.winner in forfeit_winners or candidate.end_reason.is_empty(): return false
		var eliminated := 0
		for player in candidate.players:
			if player.forfeited: eliminated += 1
		if eliminated == 0: return false
		for i in range(candidate.players.size()):
			if not candidate.players[i].forfeited and not i in forfeit_winners: return false
	else:
		if not forfeit_winners.is_empty(): return false
		if tri:
			if candidate.winner >= 0 and tri_groups(candidate.players[candidate.winner].hand).size() < candidate.tri_goal: return false
		else:
			for i in range(candidate.players.size()):
				if candidate.players[i].hand.is_empty() != (i == candidate.winner): return false
	if candidate.winner >= 0 and candidate.players[candidate.winner].forfeited: return false
	if candidate.winner < 0 and candidate.players[candidate.turn].forfeited: return false
	if not candidate.last_action.is_empty():
		if not _saved_integer(candidate.last_action.get("player"),0,candidate.players.size()-1) or not candidate.last_action.get("type","") in ["draw","meld","extend","discard","forfeit"]: return false
	var match_data: Variant = candidate.get("match",{})
	if not match_data is Dictionary or not match_data.get("totals") is Array or match_data.totals.size() != candidate.players.size() or not match_data.get("results") is Array:
		return false
	if tri and (match_data.get("length") != 1 or match_data.get("round") != 1): return false
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
