extends RefCounted
const Rules = preload("res://scripts/rami_engine.gd")

static func arrange(hand: Array, enabled: bool) -> Dictionary:
	var result := {"cards":hand.duplicate(),"boundaries":[],"groups":[]}
	if not enabled: return result
	var groups: Array = Rules.new().tri_groups(hand)
	var ordered: Array = []
	var boundaries: Array = []
	for group in groups:
		ordered.append_array(group)
		if ordered.size()<hand.size(): boundaries.append(ordered.size())
	for id in hand:
		if not id in ordered: ordered.append(id)
	result.cards = ordered
	result.boundaries = boundaries
	result.groups = groups
	return result
