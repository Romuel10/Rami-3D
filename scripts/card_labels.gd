extends RefCounted
## Display names match the imported international deck, independently of rules.
const INDEX := ["", "A", "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K"]
const NAMES := ["", "As", "2", "3", "4", "5", "6", "7", "8", "9", "10", "Valet", "Dame", "Roi"]
const SYMBOLS := {"S":"♠", "H":"♥", "D":"♦", "C":"♣"}
const SUITS := {"S":"pique", "H":"cœur", "D":"carreau", "C":"trèfle"}

static func short_label(id: String) -> String:
	var parts := id.split(":")
	if parts.size()==2 and parts[0]=="J": return "Joker"
	if parts.size()!=3 or not SYMBOLS.has(parts[1]): return "Carte inconnue"
	var rank := int(parts[2])
	if rank<1 or rank>13: return "Carte inconnue"
	return INDEX[rank]+SYMBOLS[parts[1]]

static func full_name(id: String) -> String:
	var parts := id.split(":")
	if parts.size()==2 and parts[0]=="J": return "Joker"
	if parts.size()!=3 or not SUITS.has(parts[1]): return "Carte inconnue"
	var rank := int(parts[2])
	if rank<1 or rank>13: return "Carte inconnue"
	return NAMES[rank]+" de "+SUITS[parts[1]]
