extends SceneTree

const Coach = preload("res://scripts/beginner_coach.gd")
const Rules = preload("res://scripts/rami_engine.gd")
var checks := 0

func _initialize() -> void:
	var coach = Coach.new()
	_check(coach.lessons().size() >= 10, "detailed beginner chapters")
	var all_lessons := ""
	for lesson: Dictionary in coach.lessons():
		_check(not str(lesson.get("title", "")).is_empty() and not str(lesson.get("body", "")).is_empty() and not str(lesson.get("example", "")).is_empty() and not lesson.get("tips", []).is_empty(), "complete lesson")
		all_lessons += str(lesson)
	_check(all_lessons.contains("33") and all_lessons.contains("R♥ A♥ 2♥") and all_lessons.contains("couleur"), "practical opening, ace and suit examples")
	_check(_complete(coach.advice({})), "welcome response schema")
	var snapshot := _snapshot(["0:H:7", "0:H:8", "0:H:9", "0:C:2", "0:C:3", "0:C:4", "0:S:13"])
	var before := snapshot.duplicate(true)
	var advice: Dictionary = coach.advice(snapshot)
	_check(advice.title.contains("ouvrir") and advice.body.contains("33") and advice.example.contains("7♥") and advice.example.contains("2♣"), "opening totals actual visible combinations")
	_check(snapshot == before, "coaching cannot mutate snapshot")
	var selected_groups: Array = snapshot.hand.slice(0, 6)
	var grouped_advice: Dictionary = coach.advice(snapshot, selected_groups)
	_check(grouped_advice.title.contains("plusieurs groupes") and grouped_advice.body.contains("33 points") and grouped_advice.action.contains("Poser"), "multi-group selection is explained rather than called invalid")
	var hidden := snapshot.duplicate(true)
	hidden.players[1]["hand"] = ["0:S:1", "0:S:2", "0:S:3"]
	_check(coach.advice(hidden) == advice, "opponent hand data is never consulted")
	var short_opening := _snapshot(["0:H:2", "0:H:3", "0:H:4", "0:S:13"])
	advice = coach.advice(short_opening, ["0:H:2", "0:H:3", "0:H:4"])
	_check(advice.body.contains("9 points") and advice.action.contains("30"), "valid meld below opening explained")
	advice = coach.advice(snapshot, ["0:H:7", "0:C:3", "0:S:13"])
	_check(advice.title.contains("Vérifiez") and advice.steps.size() >= 3, "invalid shape explained")
	advice = coach.advice(snapshot, ["0:H:7", "0:H:8"])
	_check(advice.title.contains("manque") and advice.example.contains("7♥"), "pair not enough for meld")
	advice = coach.advice(snapshot, snapshot.hand)
	_check(advice.title.contains("Gardez") and advice.action.contains("Conserver"), "final discard preserved")
	var ace_low := _snapshot(["0:H:1", "0:H:2", "0:H:3", "0:S:13"], true)
	advice = coach.advice(ace_low, ["0:H:1", "0:H:2", "0:H:3"])
	_check(advice.body.contains("6 points"), "ace low score is engine validated")
	var ace_high := _snapshot(["0:H:12", "0:H:13", "0:H:1", "0:S:2"])
	advice = coach.advice(ace_high, ["0:H:12", "0:H:13", "0:H:1"])
	_check(advice.body.contains("31 points") and advice.action.contains("Poser"), "ace high can open")
	var joker := _snapshot(["0:H:5", "J:0", "0:H:7", "0:S:13"], true)
	advice = coach.advice(joker, ["0:H:5", "J:0", "0:H:7"])
	_check(advice.body.contains("18 points") and advice.example.contains("joker"), "joker replacement value, not its penalty")
	var extend := _snapshot(["0:H:10", "0:S:13"], true)
	extend.melds = [{"cards": ["0:H:7", "0:H:8", "0:H:9"], "owner":1}]
	advice = coach.advice(extend)
	_check(advice.title.contains("compléter") and advice.example.contains("10♥"), "actual table extension found")
	advice = coach.advice(extend, ["0:H:10"])
	_check(advice.action.contains("n°1"), "selected extension identifies table group")
	var draw := _snapshot(["0:H:7", "0:H:8", "0:C:10", "0:D:10", "0:S:10", "0:S:13"])
	draw.phase = "draw"
	draw.discard_top = "0:H:9"
	advice = coach.advice(draw)
	_check(advice.body.contains("9♥") and advice.action.contains("défausse"), "visible discard recommended only through actual legal opening")
	var under_draw := _snapshot(["0:H:7", "0:H:8", "0:C:2", "0:S:13"])
	under_draw.phase = "draw"
	under_draw.discard_top = "0:H:9"
	advice = coach.advice(under_draw)
	_check(not advice.body.contains("participe à une pose possible"), "small run does not falsely satisfy opening")
	var inactive := snapshot.duplicate(true)
	inactive.turn = 1
	_check(coach.advice(inactive).title.contains("prochain tour"), "opponent turn advice")
	inactive.paused = true
	_check(coach.advice(inactive).action.contains("reconnexion"), "pause overrides turn instructions")
	inactive.winner = 1
	_check(coach.advice(inactive).title.contains("terminée"), "win overrides pause")
	var last := _snapshot(["0:S:13"], true)
	_check(coach.advice(last).action.contains("dernière"), "last card can win by discard")
	var isolated := _snapshot(["0:H:7", "0:H:8", "0:C:13", "J:0"])
	advice = coach.advice(isolated)
	_check(advice.title.contains("Préparez") and advice.example.contains("R♣") and not advice.example.begins_with("Carte à envisager pour la défausse : Joker"), "isolated discard considered without sacrificing joker")
	for case in [snapshot, short_opening, ace_low, ace_high, joker, extend, draw, under_draw, inactive, last, isolated]:
		_check(_complete(coach.advice(case)), "all situations return useful structured advice")
	print("PASS: %d beginner-coach checks" % checks)
	quit(0)

func _snapshot(cards: Array, opened: bool = false) -> Dictionary:
	return {"your_index":0, "players":[{"name":"Vous", "count":cards.size(), "opened":opened}, {"name":"Camille", "count":13, "opened":false}], "hand":cards.duplicate(), "turn":0, "phase":"play", "winner":-1, "paused":false, "melds":[], "discard_top":"0:D:12", "deck_count":50}

func _complete(value: Dictionary) -> bool:
	return value.has_all(["title", "body", "steps", "example", "action"]) and not str(value.title).is_empty() and not str(value.body).is_empty() and not value.steps.is_empty() and not str(value.action).is_empty()

func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		push_error("FAIL: " + message)
		quit(1)
		assert(ok, message)
