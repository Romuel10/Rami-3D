class_name RamiTutorialPractice
extends Control
## A scripted first turn using the real rules and a complete, restorable deck.
## This exercise never replaces a saved solo game or touches a network room.

signal exit_requested
signal completed

const Rules = preload("res://scripts/rami_engine.gd")
const CardArt = preload("res://scripts/card_3d.gd")
const INK := Color("ecede3")
const MUTED := Color("91aba7")
const GOLD := Color("dfbd78")
const DEEP := Color("0a2428")
const OPENING_GROUPS := [["0:H:7", "0:H:8", "0:H:9"], ["0:C:2", "0:C:3", "0:C:4"]]
const OPENING_CARDS := ["0:H:7", "0:H:8", "0:H:9", "0:C:2", "0:C:3", "0:C:4"]
const DRAW_CARD := "0:H:9"
const INITIAL_HAND := ["0:H:7", "0:H:8", "0:C:2", "0:C:3", "0:C:4", "0:S:1", "0:S:5", "0:S:10", "0:S:13", "0:D:2", "0:D:6", "0:D:11", "0:C:12"]
const SUITS := {"S":"♠", "H":"♥", "D":"♦", "C":"♣"}

var stage: int = 0
var engine: RefCounted
var selected: Array[String] = []
var _built := false
var _completed_emitted := false
var _textures: Dictionary = {}
var _card_buttons: Dictionary = {}
var _progress: Label
var _heading: Label
var _explanation: Label
var _example: Label
var _feedback: Label
var _scroll: ScrollContainer
var _grid: GridContainer
var _action: Button

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_interface()
	resized.connect(_resize_cards)

func start_lesson() -> void:
	if not _built:
		_build_interface()
	engine = Rules.new()
	engine.start_game(["Vous", "Camille"], 137)
	# Move, rather than invent, every physical card in the exercise.
	var remaining: Array = engine.state.deck + engine.state.discard
	for player: Dictionary in engine.state.players:
		remaining.append_array(player.hand)
	for id in INITIAL_HAND:
		remaining.erase(id)
	remaining.erase(DRAW_CARD)
	engine.state.players[0].hand = INITIAL_HAND.duplicate()
	engine.state.players[1].hand = remaining.slice(0, 13)
	remaining = remaining.slice(13)
	engine.state.discard = [remaining.pop_front()]
	engine.state.deck = remaining + [DRAW_CARD]
	stage = 0
	selected.clear()
	_completed_emitted = false
	_refresh()
	_feedback_text("Touchez « Piocher » pour commencer. Les cartes dorées serviront à votre première pose.", MUTED)

func draw_card() -> bool:
	if engine == null or stage != 0:
		_feedback_text("Vous ne pouvez piocher qu’une fois au début de votre tour.", Color("f0a18e"))
		return false
	var result: Dictionary = engine.apply_action(0, {"type":"draw", "source":"deck"})
	if not result.get("ok", false):
		_feedback_text(str(result.get("error", "La pioche est impossible.")), Color("f0a18e"))
		return false
	stage = 1
	_refresh()
	_feedback_text("Vous avez pioché le 9 de cœur. Sélectionnez 7♥, 8♥, 9♥ et 2♣, 3♣, 4♣ : six cartes en tout.", GOLD)
	return true

func toggle_card(card_id: String) -> bool:
	if engine == null or card_id not in engine.state.players[0].hand:
		_feedback_text("Choisissez une carte qui se trouve dans votre main.", Color("f0a18e"))
		return false
	if stage in [1, 2]:
		if card_id not in OPENING_CARDS:
			_feedback_text("Pour cet exercice, préparons les deux suites dorées : 7♥–8♥–9♥ et 2♣–3♣–4♣. Chaque suite garde la même couleur.", Color("f0a18e"))
			return false
		if card_id in selected:
			selected.erase(card_id)
		else:
			selected.append(card_id)
		stage = 2 if selected.size() == OPENING_CARDS.size() else 1
		_refresh()
		_feedback_text("Les deux suites totalisent 24 + 9 = 33 points. Touchez « Poser » pour ouvrir votre jeu." if stage == 2 else "%d / 6 cartes choisies. Complétez les deux suites dorées, puis posez-les ensemble." % selected.size(), GOLD)
		return true
	if stage == 3:
		if selected == [card_id]:
			selected.clear()
		else:
			selected.assign([card_id])
		_refresh()
		_feedback_text("Touchez « Défausser » pour terminer votre tour." if not selected.is_empty() else "Sélectionnez une seule carte dont vous voulez vous séparer, puis défaussez-la.", GOLD)
		return true
	_feedback_text("Piochez avant de sélectionner des cartes." if stage == 0 else "Votre premier tour est terminé. Recommencez l’exercice ou revenez à l’accueil.", MUTED)
	return false

func play_selected() -> bool:
	if engine == null or stage != 2 or selected.size() != OPENING_CARDS.size():
		_feedback_text("Sélectionnez les six cartes dorées avant de poser les deux suites ensemble.", Color("f0a18e"))
		return false
	for id in OPENING_CARDS:
		if id not in selected:
			return false
	var result: Dictionary = engine.apply_action(0, {"type":"meld", "groups":OPENING_GROUPS.duplicate(true)})
	if not result.get("ok", false):
		_feedback_text(str(result.get("error", "Cette pose est impossible.")), Color("f0a18e"))
		return false
	selected.clear()
	stage = 3
	_refresh()
	_feedback_text("Votre ouverture à 33 points est posée. Gardez maintenant les cartes utiles et choisissez une seule carte à défausser.", GOLD)
	return true

func discard_selected() -> bool:
	if engine == null or stage != 3 or selected.size() != 1:
		_feedback_text("Choisissez exactement une carte de votre main, puis touchez « Défausser ».", Color("f0a18e"))
		return false
	var result: Dictionary = engine.apply_action(0, {"type":"discard", "card":selected[0]})
	if not result.get("ok", false):
		_feedback_text(str(result.get("error", "La défausse est impossible.")), Color("f0a18e"))
		return false
	selected.clear()
	stage = 4
	_refresh()
	_feedback_text("Bravo ! Vous avez effectué un vrai tour de rami : piocher, ouvrir à 33 points, puis défausser. Dans une partie, continuez jusqu’à défausser votre dernière carte.", GOLD)
	if not _completed_emitted:
		_completed_emitted = true
		completed.emit()
	return true

func _build_interface() -> void:
	if _built:
		return
	_built = true
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var local_theme := Theme.new()
	var font := load("res://assets/sans.ttf") as FontFile
	var fallbacks: Array[Font] = [load("res://assets/symbols.ttf")]
	font.fallbacks = fallbacks
	local_theme.default_font = font
	local_theme.default_font_size = 19
	local_theme.set_color("font_color", "Label", INK)
	local_theme.set_color("font_color", "Button", INK)
	local_theme.set_color("font_hover_color", "Button", GOLD)
	local_theme.set_color("font_disabled_color", "Button", Color("7f9b95"))
	for style_name in ["normal", "hover", "pressed", "disabled"]:
		local_theme.set_stylebox(style_name, "Button", _style(Color("163b3c"), GOLD if style_name == "hover" else Color("345653"), 12))
	theme = local_theme
	var background := ColorRect.new()
	background.color = Color("071e23")
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
	margin.offset_bottom = -24
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	margin.add_child(box)
	var row := HBoxContainer.new()
	box.add_child(row)
	_heading = _label("Votre premier tour", 30, INK, row)
	_heading.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_progress = _label("", 15, GOLD, row)
	_progress.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_explanation = _label("", 19, INK, box)
	_explanation.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_explanation.custom_minimum_size.y = 54
	var lesson_panel := PanelContainer.new()
	lesson_panel.add_theme_stylebox_override("panel", _style(Color("163c36"), Color("426a52"), 10))
	box.add_child(lesson_panel)
	_example = _label("", 19, GOLD, lesson_panel)
	_example.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(_scroll)
	var center := CenterContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.add_child(center)
	_grid = GridContainer.new()
	_grid.columns = 7
	_grid.add_theme_constant_override("h_separation", 10)
	_grid.add_theme_constant_override("v_separation", 10)
	center.add_child(_grid)
	_feedback = _label("", 17, MUTED, box)
	_feedback.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_feedback.custom_minimum_size.y = 56
	_feedback.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 12)
	box.add_child(actions)
	_action = _button("Piocher", _primary_action, actions, true)
	_button("Recommencer l’exercice", start_lesson, actions)
	_button("Retour", func(): exit_requested.emit(), actions)
	_scroll.resized.connect(_resize_cards)

func _refresh() -> void:
	if not _built or engine == null:
		return
	var headings := ["1 · Piochez une carte", "2 · Préparez deux suites", "3 · Posez les deux suites", "4 · Terminez par une défausse", "Premier tour réussi !"]
	var descriptions := [
		"Au début de chaque tour, prenez une seule carte de la pioche ou de la défausse. Ici, la pioche vous donnera la carte qui manque à une suite.",
		"Une suite contient au moins trois valeurs consécutives de la même couleur. Touchez les six cartes dorées pour préparer deux suites différentes.",
		"La première pose doit atteindre au moins 30 points en une seule action. Vos deux suites valent ensemble 33 points : vous pouvez ouvrir.",
		"Une pose ne termine pas le tour : il faut défausser exactement une carte. Sélectionnez une carte isolée, par exemple le roi de pique, puis défaussez-la.",
		"Vous avez terminé votre premier tour. L’adversaire jouerait maintenant. Le but d’une vraie manche reste de vider votre main en défaussant votre dernière carte."
	]
	_heading.text = headings[stage]
	_progress.text = "PAS À PAS · %d / 4" % [mini(stage + 1, 4)]
	_explanation.text = descriptions[stage]
	_example.text = "Repère : piocher → préparer et poser si possible → défausser. Les cartes dorées servent à l’exercice."
	if stage in [1, 2]:
		_example.text = "7♥ + 8♥ + 9♥ = 24 points ; 2♣ + 3♣ + 4♣ = 9 points. Total : 33 points, donc au moins 30."
	elif stage >= 3:
		_example.text = "SUR LA TABLE : 7♥–8♥–9♥ et 2♣–3♣–4♣. Votre ouverture à 33 points est déjà acquise."
	_action.text = ["Piocher une carte", "Poser les six cartes", "Poser · ouverture à 33 points", "Défausser la carte choisie", "Exercice terminé"][stage]
	_action.disabled = stage == 4 or stage == 1 or (stage == 3 and selected.size() != 1)
	_render_cards()

func _render_cards() -> void:
	for child in _grid.get_children():
		_grid.remove_child(child)
		child.queue_free()
	_card_buttons.clear()
	var hand: Array = engine.state.players[0].hand
	_grid.columns = mini(7, maxi(1, ceili(hand.size() / 2.0)))
	for id_value in hand:
		var id: String = str(id_value)
		var chosen: bool = id in selected
		var expected: bool = (stage in [0, 1, 2] and id in OPENING_CARDS) or (stage == 3 and id == "0:S:13")
		var button := Button.new()
		button.name = "Card_" + id.replace(":", "_")
		button.tooltip_text = _card_label(id) + (" · carte de l’exercice" if expected else "")
		button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		button.disabled = stage in [0, 4]
		var style := _style(Color("285b4d") if chosen else Color("123a36"), GOLD if chosen or expected else Color("4c6b60"), 3)
		style.set_border_width_all(4 if chosen else (2 if expected else 1))
		button.add_theme_stylebox_override("normal", style)
		button.add_theme_stylebox_override("disabled", style)
		button.add_theme_stylebox_override("hover", _style(Color("326b55"), GOLD, 3))
		button.pressed.connect(func(): toggle_card(id))
		_grid.add_child(button)
		var art := TextureRect.new()
		art.texture = _texture(id)
		art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		art.mouse_filter = Control.MOUSE_FILTER_IGNORE
		button.add_child(art)
		art.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		art.offset_left = 5
		art.offset_top = 5
		art.offset_right = -5
		art.offset_bottom = -5
		_card_buttons[id] = button
	call_deferred("_resize_cards")

func _resize_cards() -> void:
	if not _built or _card_buttons.is_empty():
		return
	var available_width := maxf(320, _scroll.size.x - 18)
	var available_height := maxf(200, _scroll.size.y - 16)
	var width := minf(150, (available_width - (_grid.columns - 1) * 10) / _grid.columns)
	width = minf(width, (available_height - 10) / 2.0 * 210.0 / 304.0)
	width = maxf(82, width)
	for button: Button in _card_buttons.values():
		button.custom_minimum_size = Vector2(width, width * 304.0 / 210.0)

func _primary_action() -> void:
	match stage:
		0: draw_card()
		2: play_selected()
		3: discard_selected()

func _card_label(id: String) -> String:
	var info: Dictionary = engine.card_info(id)
	return str(info.get("label", id)) + str(SUITS.get(info.get("suit", ""), ""))

func _texture(id: String) -> Texture2D:
	if not _textures.has(id):
		var image := Image.new()
		if image.load_svg_from_string(CardArt._front_svg(id)) == OK:
			_textures[id] = ImageTexture.create_from_image(image)
	return _textures.get(id)

func _feedback_text(message: String, color: Color) -> void:
	if is_instance_valid(_feedback):
		_feedback.text = message
		_feedback.add_theme_color_override("font_color", color)

func _label(text: String, size_value: int, color: Color, parent: Node) -> Label:
	var label := Label.new()
	label.text = text
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", size_value)
	label.add_theme_color_override("font_color", color)
	parent.add_child(label)
	return label

func _button(text: String, callback: Callable, parent: Node, primary: bool = false) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size.y = 54
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.pressed.connect(callback)
	if primary:
		button.add_theme_stylebox_override("normal", _style(GOLD, GOLD, 14))
		button.add_theme_stylebox_override("hover", _style(Color("f0d395"), GOLD, 14))
		button.add_theme_color_override("font_color", DEEP)
		button.add_theme_color_override("font_hover_color", DEEP)
	parent.add_child(button)
	return button

func _style(background: Color, border: Color, padding: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(10)
	style.content_margin_left = padding
	style.content_margin_right = padding
	style.content_margin_top = padding
	style.content_margin_bottom = padding
	return style
