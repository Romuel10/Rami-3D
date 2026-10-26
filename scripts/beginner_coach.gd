class_name RamiBeginnerCoach
extends RefCounted
## Detailed, private-hand-only coaching. No live game engine or hidden state is read.

const Rules = preload("res://scripts/rami_engine.gd")
const SUIT_SYMBOLS := {"S": "♠", "H": "♥", "D": "♦", "C": "♣", "J": ""}
var _rules := Rules.new()
var _plan_key := ""
var _plan_cache: Array = []

func advice(snapshot: Dictionary, selected: Array = []) -> Dictionary:
	if snapshot.is_empty():
		return _pack("Bienvenue au rami", "Votre objectif est de vider votre main en posant des combinaisons, puis en défaussant votre dernière carte.", ["Commencez une partie solo pour apprendre sans pression.", "Ouvrez le guide débutant pour voir des exemples de brelans, de suites et de première pose."], "Un tour : piocher → poser ou compléter si possible → défausser une carte.", "Commencer une partie")
	var own := int(snapshot.get("your_index", 0))
	var players: Array = snapshot.get("players", [])
	var opened := own >= 0 and own < players.size() and bool(players[own].get("opened", false))
	var winner := int(snapshot.get("winner", -1))
	if winner >= 0:
		var name_text := "Un joueur"
		if winner < players.size():
			name_text = str(players[winner].get("name", "Un joueur"))
		return _pack("Vous avez gagné !" if winner == own else "La manche est terminée", "La victoire arrive lorsque la dernière carte de la main est défaussée. " + ("Vous avez réussi cette dernière étape." if winner == own else name_text + " a vidé sa main."), ["Repérez les combinaisons qui vous ont été utiles.", "Rejouez une manche pour essayer de repérer les mêmes formes plus rapidement."], "Même pour finir, gardez une carte à défausser : poser toutes ses cartes directement ne termine pas la manche.", "Nouvelle partie")
	if bool(snapshot.get("paused", false)):
		return _pack("La partie attend une connexion", "Un téléphone est déconnecté. Les cartes et les tours sont conservés pendant la reconnexion ; aucune action ne peut être jouée pendant cette pause.", ["Gardez l’application ouverte.", "Attendez la reconnexion ou utilisez « Se reconnecter » si ce bouton apparaît.", "Profitez de cette pause pour regarder vos suites et vos cartes de même valeur."], "Se reconnecter retrouve votre place tant que l’application conserve votre session.", "Attendre la reconnexion")
	var hand := _valid_hand(snapshot.get("hand", []))
	if int(snapshot.get("turn", own)) != own:
		return _pack("Préparez votre prochain tour", "C’est au tour de votre adversaire. Vous pouvez déjà repérer les cartes qui vont ensemble, mais vous devrez attendre votre tour et piocher avant de jouer.", ["Cherchez trois valeurs identiques de couleurs différentes, ou trois cartes qui se suivent dans la même couleur.", "Regardez la carte visible de la défausse ; elle pourra changer avant votre tour.", "Après votre ouverture, observez aussi les combinaisons posées sur la table."], "7♥ et 8♥ attendent notamment un 6♥ ou un 9♥. Cela reste une possibilité, pas une carte garantie dans la pioche.", "Attendre votre tour")
	if str(snapshot.get("phase", "draw")) == "draw":
		return _draw_advice(snapshot, hand, opened)
	if hand.size() == 1:
		return _pack("Votre dernière carte peut gagner", "Vous avez une seule carte en main et vous avez déjà pioché. Sélectionnez-la, puis défaussez-la : votre main sera vide et vous remporterez la manche.", ["Touchez votre dernière carte pour la sélectionner.", "Touchez « Défausser » pour terminer la manche."], "Une main vide après la défausse signifie la victoire.", "Défausser votre dernière carte")
	if not selected.is_empty():
		return _selection_advice(snapshot, hand, opened, selected)
	var groups := _plan(hand, opened)
	if not groups.is_empty():
		var points := _groups_points(groups)
		var body := "Votre main contient " + str(groups.size()) + " combinaison(s) jouable(s), pour " + str(points) + " points. "
		body += "Cela suffit pour votre première pose : elle doit atteindre 30 points au total dans la même action." if not opened else "Vous avez déjà ouvert : le minimum de 30 points ne s’applique plus à vos nouvelles poses."
		return _pack("Vous pouvez " + ("ouvrir votre jeu" if not opened else "poser des cartes"), body, ["Touchez « Suggestion » pour sélectionner les combinaisons repérées.", "Vérifiez les cartes sélectionnées, puis touchez « Poser ».", "Vous pourrez ensuite compléter d’autres combinaisons, puis terminer par une seule défausse."], _groups_text(groups), "Suggestion → Poser")
	if opened:
		var extension := _find_extension(hand, snapshot.get("melds", []), [])
		if not extension.is_empty():
			return _extension_advice(extension)
	return _discard_advice(hand, opened)

func _draw_advice(snapshot: Dictionary, hand: Array, opened: bool) -> Dictionary:
	var top := str(snapshot.get("discard_top", ""))
	var info: Dictionary = _rules.card_info(top)
	var body := "Commencez votre tour en prenant exactement une carte : celle de la pioche face cachée, ou la carte visible de la défausse. Vous pourrez ensuite poser des combinaisons et terminer par une défausse."
	var example := "La pioche est inconnue. La défausse vous montre exactement la carte que vous recevrez."
	var action := "Piocher une carte"
	if not info.is_empty():
		var augmented := hand.duplicate()
		if not augmented.has(top):
			augmented.append(top)
		var groups := _plan(augmented, opened)
		var uses_top := false
		for group: Array in groups:
			if group.has(top):
				uses_top = true
		if uses_top:
			body += " La carte visible, " + card_label(top) + ", participe à une pose possible avec votre main actuelle."
			example = "Après avoir pris " + card_label(top) + " : " + _groups_text(groups)
			action = "Envisager la défausse visible"
		elif opened and hand.size() > 0:
			var extension := _find_extension(augmented, snapshot.get("melds", []), [top])
			if not extension.is_empty():
				body += " La carte visible " + card_label(top) + " pourrait compléter une combinaison de la table puisque vous avez déjà ouvert."
				example = card_label(top) + " s’ajoute à " + _cards_text(extension.get("before", [])) + "."
				action = "Envisager la défausse visible"
			elif _has_link(top, hand):
				example = card_label(top) + " se rapproche de certaines cartes de votre main. Une paire ou deux cartes voisines ne suffisent toutefois pas encore à poser."
		elif _has_link(top, hand):
			example = card_label(top) + " peut aider à préparer une suite ou un brelan. Vérifiez ensuite si votre première pose atteint bien 30 points."
		else:
			example = "Aucune pose immédiate utilisant " + card_label(top) + " n’a été trouvée dans votre main. Vous pouvez tenter la pioche ; son contenu reste inconnu."
	if int(snapshot.get("deck_count", 1)) == 0:
		body += " La pioche épuisée sera reformée avec la défausse, en laissant sa carte visible sur la table, si assez de cartes sont disponibles."
	return _pack("Étape 1 : choisissez votre carte", body, ["Comparez la carte visible avec vos valeurs identiques et vos suites proches.", "Touchez « Piocher » ou « Défausse » une seule fois.", "Après avoir pioché, l’aide pourra vous proposer une pose adaptée à votre main."], example, action)

func _selection_advice(snapshot: Dictionary, hand: Array, opened: bool, selected: Array) -> Dictionary:
	var seen: Array = []
	for id in selected:
		if not id is String or not hand.has(id) or seen.has(id):
			return _pack("Sélectionnez des cartes de votre main", "Une pose utilise uniquement les cartes que vous possédez encore. Désélectionnez les anciennes cartes et choisissez celles qui sont visibles dans votre main.", ["Touchez à nouveau une carte sélectionnée pour l’enlever de la sélection."], "Chaque carte physique ne peut être utilisée qu’une seule fois.", "Revoir la sélection")
		seen.append(id)
	if selected.size() >= hand.size():
		return _pack("Gardez une carte pour finir le tour", "Vous avez sélectionné toute votre main. Une pose ou un complément doit vous laisser au moins une carte pour la défausse finale.", ["Désélectionnez une carte que vous pourrez défausser.", "Posez les combinaisons restantes si elles sont valides.", "Sélectionnez ensuite votre dernière carte, puis touchez « Défausser »."], "La victoire vient de la dernière défausse, pas d’une pose qui vide directement la main.", "Conserver une carte")
	if opened:
		var extension := _find_extension(hand, snapshot.get("melds", []), selected)
		if not extension.is_empty():
			return _extension_advice(extension)
	if selected.size() == 1:
		return _pack("Une carte est sélectionnée", card_label(str(selected[0])) + " peut être défaussée pour terminer votre tour. Avant de la jeter, regardez si elle peut encore aider votre jeu. Un joker est souvent utile pour combler un manque.", ["Si vous souhaitez la garder, touchez-la à nouveau pour la désélectionner.", "Pour la jeter, touchez « Défausser ».", "Pour poser une combinaison, sélectionnez au moins trois cartes compatibles."], "Une seule carte se défausse à la fois. La défausse fait passer le tour au joueur suivant.", "Choisir de garder ou défausser")
	if selected.size() < 3:
		return _pack("Il manque une carte à la combinaison", "Deux cartes ne forment pas encore une nouvelle combinaison. Il faut au moins trois cartes pour un brelan ou une suite.", ["Cherchez une troisième valeur identique d’une autre couleur, ou une carte qui prolonge la suite.", "Vous pouvez aussi désélectionner une carte pour n’en défausser qu’une."], "7♥ + 8♥ attendent 6♥ ou 9♥. 9♣ + 9♦ attendent 9♥ ou 9♠.", "Compléter la sélection")
	var checked: Dictionary = _rules._validate_meld(selected)
	if not checked.get("ok", false):
		var available_groups := _plan(hand, opened)
		var planned_cards: Array = []
		for group: Array in available_groups:
			planned_cards.append_array(group)
		var selected_sorted := selected.duplicate()
		selected_sorted.sort()
		planned_cards.sort()
		if available_groups.size() > 1 and selected_sorted == planned_cards:
			return _pack("Votre sélection contient plusieurs groupes", "Ces cartes forment " + str(available_groups.size()) + " combinaisons distinctes, soit " + str(_groups_points(available_groups)) + " points au total. " + ("Leur total permet votre ouverture à 30 points." if not opened else "Vous pouvez les poser ensemble après votre ouverture."), ["Si ces cartes viennent de « Suggestion », touchez directement « Poser ».", "Si vous les avez sélectionnées à la main, touchez d’abord « Suggestion » : le jeu séparera les groupes correctement.", "Après la pose, gardez une carte pour terminer par une défausse."], _groups_text(available_groups), "Suggestion → Poser")
		return _pack("Vérifiez la forme de votre pose", str(checked.get("error", "Ces cartes ne forment pas une seule combinaison valide.")) + " Si vous avez sélectionné plusieurs groupes distincts, utilisez « Suggestion » pour que le jeu les sépare correctement avant de poser.", ["Un brelan réunit trois valeurs identiques de couleurs différentes.", "Une suite réunit au moins trois cartes consécutives de la même couleur.", "Touchez « Suggestion » pour remplacer la sélection par les groupes que le jeu peut poser."], _groups_text(available_groups) if not available_groups.is_empty() else "Valides : 8♣ 8♦ 8♥, ou 5♠ 6♠ 7♠. Invalide : 5♠ 6♥ 7♠.", "Corriger la sélection")
	var points := int(checked.get("points", 0))
	if not opened and points < 30:
		return _pack("Bonne combinaison, ouverture encore trop faible", "Votre sélection est une combinaison valide de " + str(points) + " points. Votre première pose doit atteindre au moins 30 points ; vous pouvez additionner plusieurs combinaisons dans la même pose.", ["Gardez cette combinaison en tête.", "Cherchez une autre suite ou un autre brelan pour atteindre 30 points.", "Utilisez « Suggestion », puis « Poser », pour jouer ensemble les groupes qui suffisent à ouvrir."], _cards_text(checked.get("cards", selected)) + " = " + str(points) + " points. Exemple d’ouverture : 7♥ 8♥ 9♥ (24) + 2♣ 3♣ 4♣ (9) = 33.", "Atteindre au moins 30 points")
	return _pack("Votre sélection peut être posée", "Cette " + ("suite" if checked.get("type", "") == "run" else "combinaison de même valeur") + " vaut " + str(points) + " points. " + ("Elle permet d’ouvrir votre jeu." if not opened else "Vous avez déjà ouvert ; aucun minimum de points n’est nécessaire."), ["Touchez « Poser » pour placer ces cartes sur la table.", "Si d’autres cartes peuvent compléter des combinaisons, jouez-les ensuite.", "Terminez votre tour par une défausse."], _cards_text(checked.get("cards", selected)) + " = " + str(points) + " points. Un joker prend la valeur de la carte qu’il remplace ; l’as vaut 1 en suite basse et 11 en suite haute ou en brelan.", "Poser cette combinaison")

func _discard_advice(hand: Array, opened: bool) -> Dictionary:
	var candidate := _discard_candidate(hand)
	var example := "Gardez les paires et les cartes proches : elles pourront former vos prochaines combinaisons."
	if not candidate.is_empty():
		example = "Carte à envisager pour la défausse : " + card_label(candidate) + ". Elle est parmi les moins reliées au reste de votre main actuelle ; ce conseil ne prédit pas les cartes à venir."
	return _pack("Préparez votre prochaine combinaison", "Aucune nouvelle pose " + ("immédiate n’a été trouvée." if opened else "atteignant l’ouverture de 30 points n’a été trouvée. Une petite combinaison peut être valide sans suffire à ouvrir.") + " Vous n’êtes pas obligé de poser : piocher puis défausser une carte est un tour normal.", ["Gardez de préférence les valeurs en double et les cartes proches dans la même couleur.", "Conservez généralement vos jokers : ils peuvent remplacer une carte manquante.", "Sélectionnez une carte moins utile, puis touchez « Défausser » pour laisser jouer le suivant."], example, "Choisir une carte à défausser")

func _extension_advice(extension: Dictionary) -> Dictionary:
	var cards: Array = extension.get("cards", [])
	var index := int(extension.get("index", 0))
	return _pack("Vous pouvez compléter la table", "Vous avez déjà ouvert votre jeu. " + _cards_text(cards) + " peut compléter la combinaison n°" + str(index + 1) + ", même si elle appartient à un autre joueur.", ["Sélectionnez " + _cards_text(cards) + " dans votre main.", "Touchez « Compléter », puis choisissez la bonne combinaison ; vous pouvez aussi toucher les cartes correspondantes sur la table.", "Gardez au moins une carte pour terminer par une défausse."], _cards_text(extension.get("before", [])) + " → " + _cards_text(extension.get("after", [])), "Compléter la combinaison n°" + str(index + 1))

func _plan(hand: Array, opened: bool) -> Array:
	var sorted := hand.duplicate()
	sorted.sort()
	var key := str(opened) + ":" + ",".join(sorted)
	if key == _plan_key:
		return _plan_cache.duplicate(true)
	var helper := Rules.new()
	helper.state = {"players": [{"hand": hand.duplicate(), "opened": opened}]}
	_plan_cache = helper.suggest_melds(0)
	_plan_key = key
	return _plan_cache.duplicate(true)

func _find_extension(hand: Array, melds: Array, required: Array) -> Dictionary:
	var candidates: Array = []
	if not required.is_empty():
		candidates.append(required.duplicate())
	else:
		for id in hand:
			candidates.append([id])
	for cards: Array in candidates:
		if cards.is_empty() or cards.size() >= hand.size():
			continue
		var all_owned := true
		for id in cards:
			if not hand.has(id): all_owned = false
		if not all_owned: continue
		for i in range(melds.size()):
			if not melds[i] is Dictionary: continue
			var before: Array = melds[i].get("cards", [])
			var checked: Dictionary = _rules._validate_meld(before + cards)
			if checked.get("ok", false):
				return {"index": i, "cards": cards.duplicate(), "before": before.duplicate(), "after": checked.get("cards", [])}
	return {}

func _groups_points(groups: Array) -> int:
	var total := 0
	for group: Array in groups:
		var checked: Dictionary = _rules._validate_meld(group)
		if checked.get("ok", false): total += int(checked.get("points", 0))
	return total

func _groups_text(groups: Array) -> String:
	var descriptions: Array[String] = []
	for group: Array in groups:
		var checked: Dictionary = _rules._validate_meld(group)
		descriptions.append(_cards_text(checked.get("cards", group)) + " (" + str(checked.get("points", 0)) + " pts)")
	return " + ".join(descriptions)

func card_label(id: String) -> String:
	var info: Dictionary = _rules.card_info(id)
	if info.is_empty(): return "carte inconnue"
	return str(info.get("label", "")) + str(SUIT_SYMBOLS.get(info.get("suit", "J"), ""))

func _cards_text(cards: Array) -> String:
	var labels: Array[String] = []
	for id in cards:
		labels.append(card_label(str(id)))
	return "  ".join(labels)

func _valid_hand(value: Variant) -> Array:
	var hand: Array = []
	if not value is Array: return hand
	for id in value:
		if id is String and not _rules.card_info(id).is_empty() and not hand.has(id):
			hand.append(id)
	return hand

func _has_link(id: String, hand: Array) -> bool:
	var info: Dictionary = _rules.card_info(id)
	if info.is_empty(): return false
	if info.get("joker", false): return true
	for other_id in hand:
		var other: Dictionary = _rules.card_info(other_id)
		if other.get("joker", false): return true
		if info.get("rank") == other.get("rank") and info.get("suit") != other.get("suit"):
			return true
		if info.get("suit") == other.get("suit"):
			var difference := absi(int(info.get("rank", 0)) - int(other.get("rank", 0)))
			if difference >= 1 and difference <= 2: return true
			if int(info.get("rank", 0)) == 1 and int(other.get("rank", 0)) >= 12: return true
			if int(other.get("rank", 0)) == 1 and int(info.get("rank", 0)) >= 12: return true
	return false

func _discard_candidate(hand: Array) -> String:
	var candidate := ""
	var lowest := 100000
	for id in hand:
		var info: Dictionary = _rules.card_info(id)
		if info.get("joker", false): continue
		var score := 0
		for other_id in hand:
			if id == other_id: continue
			var other: Dictionary = _rules.card_info(other_id)
			if other.get("joker", false): continue
			if info.get("rank") == other.get("rank") and info.get("suit") != other.get("suit"):
				score += 8
			if info.get("suit") == other.get("suit"):
				var distance := absi(int(info.get("rank", 0)) - int(other.get("rank", 0)))
				if distance == 1: score += 7
				elif distance == 2: score += 4
				elif distance >= 11 and (int(info.get("rank", 0)) == 1 or int(other.get("rank", 0)) == 1): score += 5
		var weight := score * 100 - int(info.get("points", 0))
		if weight < lowest:
			lowest = weight
			candidate = str(id)
	return candidate

func _pack(title: String, body: String, steps: Array, example: String = "", action: String = "") -> Dictionary:
	return {"title": title, "body": body, "steps": steps, "example": example, "action": action}

func lessons() -> Array[Dictionary]:
	return [
		{"title": "1 · Le but du rami", "body": "Vous recevez 13 cartes. Votre objectif est de les jouer en combinaisons valides et de terminer par une dernière défausse. Le premier dont la main est vide après cette défausse gagne la manche. Une partie réunit de 2 à 4 joueurs, avec deux jeux de 52 cartes et quatre jokers.", "example": "Vous avez 4 cartes : une suite de 3 cartes et une carte isolée. Si vous êtes autorisé à poser la suite, vous pouvez ensuite défausser la carte isolée pour gagner.", "tips": ["Votre main reste privée, même quand chacun joue sur son téléphone.", "Les règles présentées ici sont celles de ce salon ; d’autres variantes de rami utilisent d’autres nombres de cartes ou d’autres seuils."]},
		{"title": "2 · Comprendre les couleurs et les figures", "body": "En rami, une « couleur » désigne une famille de cartes : trèfle ♣, carreau ♦, cœur ♥ ou pique ♠. Cela ne signifie pas simplement rouge ou noir. V est le valet, D la dame, R le roi et A l’as.", "example": "5♥ et 6♦ sont toutes les deux rouges, mais elles n’ont pas la même couleur de jeu : elles ne peuvent pas former une suite ensemble.", "tips": ["Le bouton de tri aide à rapprocher les valeurs ou les couleurs.", "Deux copies d’une même carte existent dans les deux jeux. Ce sont bien deux cartes physiques, mais elles ne remplacent pas deux couleurs différentes dans un brelan."]},
		{"title": "3 · Un tour en trois étapes", "body": "Chaque tour commence par une pioche. Ensuite, vous pouvez poser une ou plusieurs combinaisons, puis compléter la table si vous avez ouvert. Enfin, vous défaussez exactement une carte pour faire passer le tour au joueur suivant. Vous pouvez aussi ne rien poser et simplement piocher puis défausser.", "example": "Piochez le 9♥ visible → posez 7♥ 8♥ 9♥ si les conditions d’ouverture sont remplies → défaussez une carte isolée.", "tips": ["On ne pose pas avant d’avoir pioché.", "On ne pioche qu’une seule fois par tour.", "La pioche face cachée est inconnue ; la défausse montre la carte qui sera prise."]},
		{"title": "4 · Former un brelan ou un carré", "body": "Un brelan contient trois cartes de même valeur et de couleurs différentes. Un carré en contient quatre. Les deux jeux ne permettent pas de doubler une couleur dans le même brelan : deux 8♥ restent de même couleur.", "example": "Valide : 8♣ 8♦ 8♥ = un brelan. Valide : 8♣ 8♦ 8♥ 8♠ = un carré. Invalide : 8♥ 8♥ 8♠.", "tips": ["Repérez les valeurs que vous avez déjà dans deux couleurs : une troisième couleur pourrait former un brelan.", "Un carré est limité à quatre cartes."]},
		{"title": "5 · Former une suite", "body": "Une suite contient au moins trois cartes de valeurs consécutives, toutes dans la même couleur. Un trou dans les valeurs n’est pas permis, sauf s’il est rempli par un joker.", "example": "Valide : 5♠ 6♠ 7♠. Invalide : 5♠ 7♠ 8♠, car le 6 manque. Invalide : 5♠ 6♥ 7♠, car les couleurs sont mélangées.", "tips": ["Deux cartes voisines ne suffisent pas à poser.", "5♠ et 6♠ peuvent attendre 4♠ ou 7♠ ; cela ne garantit pas qu’une de ces cartes arrivera."]},
		{"title": "6 · Ouvrir avec au moins 30 points", "body": "Votre première pose doit atteindre 30 points au total. Vous pouvez additionner plusieurs combinaisons dans la même action d’ouverture, mais vous ne pouvez pas poser une petite combinaison maintenant et garder son total pour un tour suivant. Les nombres valent leur valeur ; V, D et R valent 10. L’as vaut 1 en suite basse, 11 en suite haute ou dans un brelan.", "example": "7♥ 8♥ 9♥ valent 24 points ; 2♣ 3♣ 4♣ valent 9 points. Ensemble : 24 + 9 = 33 points, donc l’ouverture est possible. V♠ D♠ R♠ valent exactement 30 points.", "tips": ["« Suggestion » peut repérer plusieurs groupes qui atteignent ensemble le seuil ; « Poser » les joue dans une seule action.", "Après votre ouverture, vos nouvelles poses n’ont plus de minimum de points.", "Une carte défaussée n’ajoute aucun point à l’ouverture."]},
		{"title": "7 · Bien utiliser l’as", "body": "L’as peut commencer une suite basse avant le 2 ou terminer une suite haute après le roi. Il ne sert pas de pont entre le roi et le 2. Son nombre de points dépend de sa place dans la combinaison.", "example": "A♥ 2♥ 3♥ = 1 + 2 + 3 = 6 points. D♥ R♥ A♥ = 10 + 10 + 11 = 31 points. R♥ A♥ 2♥ est invalide.", "tips": ["Un brelan de trois as de couleurs différentes vaut 33 points.", "A-2-3 est une vraie suite, mais ne suffit pas seule pour ouvrir à 30 points."]},
		{"title": "8 · Utiliser les jokers", "body": "Un joker remplace une carte manquante et prend sa valeur pour compter les points de la pose. Une combinaison doit contenir au moins autant de cartes naturelles que de jokers. Dans trois cartes, un seul joker est donc autorisé ; dans quatre cartes, deux peuvent être autorisés si le groupe reste valide.", "example": "5♥ Joker 7♥ représente 5♥ 6♥ 7♥, soit 18 points. 5♥ Joker Joker est interdit : les jokers sont majoritaires.", "tips": ["Gardez souvent vos jokers pour compléter un manque utile.", "Les jokers ne valent pas automatiquement 20 points pour l’ouverture.", "Le jeu vérifie automatiquement la valeur remplacée et la validité de chaque combinaison."]},
		{"title": "9 · Compléter les combinaisons de la table", "body": "Une fois votre jeu ouvert, vous pouvez ajouter des cartes à vos combinaisons ou à celles de vos adversaires. Le groupe obtenu doit toujours être une suite ou un brelan/carré valide. Ce salon ne propose pas de reprendre un joker posé pour le remplacer.", "example": "La table contient 7♥ 8♥ 9♥. Après votre ouverture, vous pouvez y ajouter 6♥ ou 10♥. Sur 8♣ 8♦ 8♥, vous pouvez ajouter 8♠.", "tips": ["Sélectionnez votre carte, touchez « Compléter », puis choisissez la combinaison.", "Vous pouvez aussi toucher directement une combinaison visible sur la table.", "Le menu « Compléter » donne accès aux groupes plus anciens qui ne sont plus affichés sur la table."]},
		{"title": "10 · Jouer avec les commandes du téléphone", "body": "Touchez une carte de votre main pour la sélectionner ; touchez-la encore pour la désélectionner. Les cartes sélectionnées se soulèvent. « Suggestion » sélectionne des combinaisons jouables ; « Poser » les dépose. « Compléter » ajoute des cartes à un groupe existant. « Défausser » termine votre tour avec une seule carte sélectionnée.", "example": "Après la pioche : Suggestion → regardez les cartes soulevées → Poser → sélectionnez une carte restante → Défausser.", "tips": ["« Suggestion » vous aide mais ne joue aucune carte sans que vous touchiez « Poser ».", "Pour défausser, sélectionnez une seule carte.", "Si une commande est indisponible, vérifiez si vous avez pioché et si c’est bien votre tour."]},
		{"title": "11 · Choisir ce que l’on garde", "body": "Les cartes déjà proches d’un groupe sont souvent plus utiles que les cartes isolées. Gardez de préférence les paires de valeurs et les cartes voisines d’une même couleur. Les conseils se fondent sur votre main visible et la table ; ils ne connaissent ni les cartes de vos adversaires ni la prochaine pioche.", "example": "Avec 7♥ 8♥ et un R♣ isolé, garder 7♥ 8♥ peut préparer une suite. Cela reste un choix stratégique, pas une promesse de recevoir le 6♥ ou le 9♥.", "tips": ["Ne jetez pas automatiquement votre joker.", "Après l’ouverture, vérifiez la table avant de jeter une carte qui pourrait compléter un groupe.", "Vous pouvez prendre le temps de réfléchir ; aucun chronomètre ne vous oblige à jouer dans une partie de rami."]},
		{"title": "12 · Finir la manche et gérer la pioche", "body": "Gardez toujours une carte pour la dernière défausse : poser ou ajouter toutes les cartes d’un coup est refusé. Lorsque la pioche est vide, le jeu mélange les anciennes cartes de la défausse pour reformer une pioche, tout en conservant la carte visible. Si trop peu de cartes restent pour cela, prenez la défausse visible.", "example": "Il vous reste 4 cartes : posez une combinaison valide de 3, puis défaussez la quatrième. Votre main est vide : vous gagnez.", "tips": ["Après avoir pioché, une seule carte restante peut être défaussée pour gagner.", "En multijoueur, gardez l’application ouverte pour conserver votre session de reconnexion."]}
	]
