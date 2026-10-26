class_name RamiSortingChallenge
extends Control
## A separate, untimed practice game. The player swaps two cards by tapping
## them, then checks the result; no rummy hand or network state is touched.

signal exit_requested

const CardArt = preload("res://scripts/card_3d.gd")
const INK := Color("ecede3")
const MUTED := Color("91aba7")
const GOLD := Color("dfbd78")
const DEEP := Color("0a2428")
const SUITS := ["C", "D", "H", "S"]
const SUIT_SYMBOLS := {"C": "♣", "D": "♦", "H": "♥", "S": "♠"}
const SUIT_NAMES := {"C": "trèfle", "D": "carreau", "H": "cœur", "S": "pique"}
const RANK_NAMES := ["", "As", "2", "3", "4", "5", "6", "7", "8", "9", "10", "Valet", "Dame", "Roi"]
const ROUND_SIZES := [8, 10, 12]

var cards: Array[String] = []
var current_round: int = 0
var selected_index: int = -1
var finished: bool = false
var round_solved: bool = false
var score: int = 0
var mistakes: int = 0
var hints: int = 0
var rounds_completed: int = 0

var _rng := RandomNumberGenerator.new()
var _started_at: int = 0
var _elapsed_at_finish: int = 0
var _round_mistakes: int = 0
var _round_hints: int = 0
var _bad_indices: Array[int] = []
var _texture_cache: Dictionary = {}
var _card_buttons: Array[Button] = []
var _title: Label
var _progress: Label
var _instruction: Label
var _criterion: Label
var _feedback: Label
var _card_scroll: ScrollContainer
var _card_center: CenterContainer
var _grid: GridContainer
var _verify_button: Button
var _hint_button: Button
var _built: bool = false

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_interface()
	resized.connect(_resize_cards)

func start_challenge(seed_value: int = 0) -> void:
	if not _built:
		_build_interface()
	if seed_value == 0:
		_rng.randomize()
	else:
		_rng.seed = seed_value
	score = 0
	mistakes = 0
	hints = 0
	rounds_completed = 0
	_started_at = Time.get_ticks_msec()
	_elapsed_at_finish = 0
	finished = false
	new_round(0)

func new_round(index: int = -1) -> void:
	var next := current_round + 1 if index < 0 else index
	if next >= ROUND_SIZES.size():
		_finish_challenge()
		return
	current_round = clampi(next, 0, ROUND_SIZES.size() - 1)
	selected_index = -1
	_bad_indices.clear()
	round_solved = false
	finished = false
	_round_mistakes = 0
	_round_hints = 0
	cards.clear()
	var pool: Array[String] = []
	for suit in SUITS:
		for rank in range(1, 14):
			pool.append("0:%s:%d" % [suit, rank])
	for i in range(pool.size() - 1, 0, -1):
		var j := _rng.randi_range(0, i)
		var saved := pool[i]
		pool[i] = pool[j]
		pool[j] = saved
	for i in range(ROUND_SIZES[current_round]):
		cards.append(pool[i])
	# A new round must require an action, even for an unusually lucky shuffle.
	if _is_sorted():
		cards.reverse()
	_render_round()

func swap_cards(first: int, second: int) -> bool:
	if finished or round_solved or first < 0 or second < 0 or first >= cards.size() or second >= cards.size():
		return false
	if first == second:
		return false
	var saved := cards[first]
	cards[first] = cards[second]
	cards[second] = saved
	selected_index = -1
	_bad_indices.clear()
	_render_cards()
	_set_feedback("Échange effectué. Continuez à ranger les cartes, puis touchez « Vérifier ».", MUTED)
	return true

func sort_key(card_id: String) -> int:
	var parts := card_id.split(":")
	if parts.size() != 3 or parts[1] not in SUITS:
		return 10000
	var rank := int(parts[2])
	return SUITS.find(parts[1]) * 100 + rank if current_round == 1 else rank

func check_order() -> bool:
	if finished or round_solved:
		return true
	_bad_indices.clear()
	for i in range(1, cards.size()):
		if sort_key(cards[i - 1]) > sort_key(cards[i]):
			if not _bad_indices.has(i - 1):
				_bad_indices.append(i - 1)
			if not _bad_indices.has(i):
				_bad_indices.append(i)
	if not _bad_indices.is_empty():
		mistakes += 1
		_round_mistakes += 1
		selected_index = -1
		_render_cards()
		var left := _bad_indices[0]
		_set_feedback("Presque ! %s doit venir avant %s. Les cartes en rouge demandent encore un échange." % [_card_name(cards[left + 1]), _card_name(cards[left])], Color("f0a18e"))
		return false
	round_solved = true
	rounds_completed += 1
	var earned := maxi(30, 100 - _round_mistakes * 10 - _round_hints * 5)
	score += earned
	_progress.text = "MANCHE %d / 3  ·  %d CARTES  ·  %d PTS" % [current_round + 1, cards.size(), score]
	selected_index = -1
	_render_cards()
	if current_round == ROUND_SIZES.size() - 1:
		_finish_challenge()
	else:
		_verify_button.text = "Manche suivante →"
		_hint_button.disabled = true
		_set_feedback("Bien joué ! L’ordre est correct : +%d points. Passez à la manche suivante quand vous êtes prêt." % earned, GOLD)
	return true

func give_hint() -> String:
	if finished or round_solved:
		return "Cette manche est déjà réussie."
	hints += 1
	_round_hints += 1
	var sorted_cards := cards.duplicate()
	sorted_cards.sort_custom(func(a, b): return sort_key(a) < sort_key(b))
	var position := -1
	for i in range(cards.size()):
		if sort_key(cards[i]) != sort_key(sorted_cards[i]):
			position = i
			break
	if position < 0:
		var ready_message := "Tout semble déjà bien rangé. Touchez « Vérifier » pour valider la manche."
		_set_feedback(ready_message, GOLD)
		return ready_message
	var expected: String = sorted_cards[position]
	var explanation := "L’as est le plus petit ; viennent ensuite 2 à 10, Valet, Dame et Roi."
	if current_round == 1:
		explanation = "Rassemblez d’abord les trèfles, puis carreaux, cœurs et piques ; dans chaque couleur, partez de l’as."
	var message := "À la place %d, cherchez %s. %s" % [position + 1, _card_name(expected), explanation]
	_set_feedback(message, GOLD)
	return message

func get_results() -> Dictionary:
	var elapsed: int = _elapsed_at_finish if finished else maxi(0, Time.get_ticks_msec() - _started_at)
	return {"score": score, "max_score": 300, "elapsed_seconds": int(elapsed / 1000), "mistakes": mistakes, "hints": hints, "rounds_completed": rounds_completed, "finished": finished}

func _build_interface() -> void:
	if _built:
		return
	_built = true
	var theme := Theme.new()
	theme.default_font = load("res://assets/sans.ttf")
	theme.default_font_size = 19
	theme.set_color("font_color", "Label", INK)
	theme.set_color("font_color", "Button", INK)
	theme.set_color("font_hover_color", "Button", GOLD)
	theme.set_color("font_disabled_color", "Button", Color("627c78"))
	theme.set_stylebox("normal", "Button", _style(Color("163b3c"), Color("345653"), 10, 14))
	theme.set_stylebox("hover", "Button", _style(Color("245653"), GOLD, 10, 14))
	theme.set_stylebox("pressed", "Button", _style(Color("32685d"), GOLD, 10, 14))
	theme.set_stylebox("disabled", "Button", _style(Color("152e31"), Color("27413f"), 10, 14))
	self.theme = theme
	var background := ColorRect.new()
	background.color = Color(0.025, 0.09, 0.10, 0.97)
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(background)
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	background.offset_top = 96
	var margin := MarginContainer.new()
	add_child(margin)
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.offset_left = 36
	margin.offset_right = -36
	margin.offset_top = 108
	margin.offset_bottom = -20
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 9)
	margin.add_child(box)
	var heading := HBoxContainer.new()
	box.add_child(heading)
	_title = _label("Le défi du tri", 31, INK, heading)
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_progress = _label("", 16, GOLD, heading)
	_progress.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_instruction = _label("Touchez deux cartes pour les échanger. Lisez de gauche à droite, puis de haut en bas.", 17, MUTED, box)
	_instruction.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var criterion_panel := PanelContainer.new()
	criterion_panel.add_theme_stylebox_override("panel", _style(Color("163c36"), Color("426a52"), 10, 10))
	box.add_child(criterion_panel)
	_criterion = _label("", 18, GOLD, criterion_panel)
	_criterion.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_card_scroll = ScrollContainer.new()
	_card_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_card_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_card_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(_card_scroll)
	_card_center = CenterContainer.new()
	_card_center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_card_center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_card_scroll.add_child(_card_center)
	_grid = GridContainer.new()
	_grid.add_theme_constant_override("h_separation", 12)
	_grid.add_theme_constant_override("v_separation", 12)
	_card_center.add_child(_grid)
	_feedback = _label("", 16, MUTED, box)
	_feedback.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_feedback.custom_minimum_size.y = 48
	_feedback.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 12)
	box.add_child(actions)
	_verify_button = _button("Vérifier", _verify_or_continue, actions, true)
	_hint_button = _button("Indice", func(): give_hint(), actions)
	_button("Recommencer", func(): start_challenge(), actions)
	_button("Retour", func(): exit_requested.emit(), actions)
	_card_scroll.resized.connect(_resize_cards)

func _render_round() -> void:
	if not _built:
		return
	_title.text = "Le défi du tri"
	_progress.text = "MANCHE %d / 3  ·  %d CARTES  ·  %d PTS" % [current_round + 1, cards.size(), score]
	_instruction.text = "Touchez deux cartes pour les échanger. Lisez de gauche à droite, puis de haut en bas."
	_criterion.text = "Par couleur, puis par valeur : ♣ TRÈFLES → ♦ CARREAUX → ♥ CŒURS → ♠ PIQUES · as vers roi" if current_round == 1 else "Par valeur croissante : AS → 2 → 3 → … → 10 → VALET → DAME → ROI · couleurs libres"
	_verify_button.text = "Vérifier"
	_hint_button.disabled = false
	_set_feedback("Les valeurs identiques peuvent rester dans n’importe quel ordre. Aucun chronomètre ne vous presse.", MUTED)
	_render_cards()

func _render_cards() -> void:
	if not _built:
		return
	_clear_children(_grid)
	_card_buttons.clear()
	_grid.columns = ceili(cards.size() / 2.0)
	for i in range(cards.size()):
		var index := i
		var button := Button.new()
		button.tooltip_text = "Place %d : %s. Touchez une autre carte pour échanger." % [i + 1, _card_name(cards[i])]
		button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		button.focus_mode = Control.FOCUS_ALL
		button.disabled = round_solved
		var border := GOLD if i == selected_index else (Color("d97764") if _bad_indices.has(i) else Color("608374"))
		var normal := _style(Color("174139"), border, 9, 3)
		normal.set_border_width_all(3 if i == selected_index or _bad_indices.has(i) else 1)
		normal.shadow_color = Color(0, 0, 0, 0.30)
		normal.shadow_size = 5
		normal.shadow_offset = Vector2(0, 4)
		button.add_theme_stylebox_override("normal", normal)
		button.add_theme_stylebox_override("disabled", normal)
		button.add_theme_stylebox_override("hover", _style(Color("245b4d"), GOLD, 9, 3))
		button.add_theme_stylebox_override("pressed", _style(Color("326b55"), GOLD, 9, 3))
		button.pressed.connect(func(): _card_pressed(index))
		_grid.add_child(button)
		var art := TextureRect.new()
		art.texture = _texture_for(cards[i])
		art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		art.mouse_filter = Control.MOUSE_FILTER_IGNORE
		button.add_child(art)
		art.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		art.offset_left = 4
		art.offset_right = -4
		art.offset_top = 4
		art.offset_bottom = -4
		_card_buttons.append(button)
	call_deferred("_resize_cards")

func _resize_cards() -> void:
	if not _built or not is_instance_valid(_grid) or _card_buttons.is_empty():
		return
	var cols := maxi(1, _grid.columns)
	var available_width := maxf(320, _card_scroll.size.x - 20)
	var available_height := maxf(210, _card_scroll.size.y - 18)
	var width := minf(174, (available_width - (cols - 1) * 12) / cols)
	width = minf(width, ((available_height - 12) / 2.0) * 210.0 / 304.0)
	width = maxf(88, width)
	for button in _card_buttons:
		button.custom_minimum_size = Vector2(width, width * 304.0 / 210.0)

func _card_pressed(index: int) -> void:
	if finished or round_solved:
		return
	if selected_index == index:
		selected_index = -1
		_render_cards()
		_set_feedback("Sélection annulée. Touchez une carte pour commencer un échange.", MUTED)
	elif selected_index < 0:
		selected_index = index
		_render_cards()
		_set_feedback("%s sélectionnée. Touchez la carte avec laquelle vous voulez échanger sa place." % _card_name(cards[index]), GOLD)
	else:
		swap_cards(selected_index, index)

func _verify_or_continue() -> void:
	if finished:
		start_challenge()
	elif round_solved:
		new_round()
	else:
		check_order()

func _finish_challenge() -> void:
	finished = true
	round_solved = true
	_elapsed_at_finish = maxi(0, Time.get_ticks_msec() - _started_at)
	selected_index = -1
	_bad_indices.clear()
	_title.text = "Bien joué !"
	_progress.text = "3 MANCHES TERMINÉES"
	_instruction.text = "Vous avez travaillé les deux façons de ranger une main de cartes. Ces repères vous aideront aussi au rami."
	_criterion.text = "VOTRE SCORE : %d / 300 POINTS" % score
	_clear_children(_grid)
	_card_buttons.clear()
	_grid.columns = 1
	var result_box := VBoxContainer.new()
	result_box.add_theme_constant_override("separation", 14)
	_grid.add_child(result_box)
	var headline := _label("Un peu d’ordre, beaucoup de progrès.", 28, INK, result_box)
	headline.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var result: Dictionary = get_results()
	var elapsed: int = result.elapsed_seconds
	var detail := _label("Temps total : %d min %02d s\nVérifications à reprendre : %d  ·  Indices utilisés : %d" % [int(elapsed / 60), elapsed % 60, mistakes, hints], 19, MUTED, result_box)
	detail.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_set_feedback("Chaque manche vaut jusqu’à 100 points : −10 par vérification à reprendre et −5 par indice. Le temps ne retire aucun point.", MUTED)
	_verify_button.text = "Rejouer le défi"
	_hint_button.disabled = true

func _is_sorted() -> bool:
	for i in range(1, cards.size()):
		if sort_key(cards[i - 1]) > sort_key(cards[i]):
			return false
	return true

func _card_name(card_id: String) -> String:
	var parts := card_id.split(":")
	if parts.size() != 3:
		return card_id
	var rank := int(parts[2])
	if rank < 1 or rank > 13:
		return card_id
	return "%s de %s" % [RANK_NAMES[rank], SUIT_NAMES.get(parts[1], parts[1])]

func _texture_for(card_id: String) -> Texture2D:
	if not _texture_cache.has(card_id):
		var image := Image.new()
		if image.load_svg_from_string(CardArt._front_svg(card_id)) != OK:
			return null
		_texture_cache[card_id] = ImageTexture.create_from_image(image)
	return _texture_cache[card_id]

func _set_feedback(text: String, color: Color) -> void:
	if is_instance_valid(_feedback):
		_feedback.text = text
		_feedback.add_theme_color_override("font_color", color)

func _label(text: String, font_size: int, color: Color, parent: Node) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	parent.add_child(label)
	return label

func _button(text: String, callback: Callable, parent: Node, primary: bool = false) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size.y = 52
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	if primary:
		button.add_theme_stylebox_override("normal", _style(GOLD, GOLD, 10, 14))
		button.add_theme_stylebox_override("hover", _style(Color("f0d395"), GOLD, 10, 14))
		button.add_theme_color_override("font_color", DEEP)
		button.add_theme_color_override("font_hover_color", DEEP)
	button.pressed.connect(callback)
	parent.add_child(button)
	return button

func _style(background: Color, border: Color, radius: int = 12, padding: int = 12) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(radius)
	style.content_margin_left = padding
	style.content_margin_right = padding
	style.content_margin_top = padding
	style.content_margin_bottom = padding
	return style

func _clear_children(parent: Node) -> void:
	for child in parent.get_children():
		parent.remove_child(child)
		child.queue_free()
