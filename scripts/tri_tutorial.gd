class_name TriTutorial
extends Control
## A guided, fully valid Tri duel: every card stays private until the final
## discard produces a real win. No saved game or network room is touched here.

signal exit_requested
signal completed

const Rules = preload("res://scripts/rami_engine.gd")
const CardArt = preload("res://scripts/card_3d.gd")
const INK := Color("ecede3")
const MUTED := Color("91aba7")
const GOLD := Color("dfbd78")
const DEEP := Color("0a2428")
const DRAW_CARD := "0:D:8"
const DISCARD_CARD := "0:S:13"
const INITIAL_SIX := ["0:H:7", "1:H:7", "0:C:7", "0:S:8", "0:C:8", DISCARD_CARD]
const EXTRA_SIX := ["0:S:9", "0:C:9", "0:D:9", "0:H:1", "0:S:3", "0:D:4"]
const SUITS := {"S":"♠", "H":"♥", "D":"♦", "C":"♣"}

var stage := 0
var hand_size := 6
var engine: RefCounted
var selected: Array[String] = []
var hand_order: Array = []
var _highlighted: Array = []
var _sort_by_rank := false
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

func start_lesson(size_value: int = 6) -> void:
	if not _built: _build_interface()
	hand_size = size_value if size_value in [6,12] else 6
	engine = Rules.new()
	engine.start_tri_game(["Vous", "Camille"], hand_size, 713)
	# Deal this exercise from the complete physical deck, without duplicates.
	var remaining: Array = engine.state.deck + engine.state.discard
	for player in engine.state.players: remaining.append_array(player.hand)
	var hand: Array = INITIAL_SIX.duplicate()
	if hand_size == 12: hand.append_array(EXTRA_SIX)
	for id in hand: remaining.erase(id)
	remaining.erase(DRAW_CARD)
	engine.state.players[0].hand = hand
	engine.state.players[1].hand = remaining.slice(0,hand_size)
	remaining = remaining.slice(hand_size)
	engine.state.discard = [remaining.pop_front()]
	engine.state.deck = remaining + [DRAW_CARD]
	stage = 0
	selected.clear()
	_highlighted.clear()
	hand_order = hand.duplicate()
	_sort_by_rank = false
	_completed_emitted = false
	_refresh()
	_feedback_text("Vous avez déjà un tri de 7 et deux 8. Touchez « Piocher » : le troisième 8 est dans la pioche.", MUTED)

func draw_card() -> bool:
	if engine == null or stage != 0:
		_feedback_text("Vous ne pouvez piocher qu’une fois au début du tour. Il faut ensuite choisir une défausse.", Color("f0a18e"))
		return false
	var result: Dictionary = engine.apply_action(0,{"type":"draw","source":"deck"})
	if not result.ok:
		_feedback_text(str(result.error), Color("f0a18e"))
		return false
	hand_order.append(DRAW_CARD)
	stage = 1
	_refresh()
	_feedback_text("Le 8♦ complète votre tri de 8. Touchez « Mes tris » pour les repérer. Même avec assez de tris, il faut encore défausser !", GOLD)
	return true

func show_tris() -> bool:
	if engine == null or stage != 1:
		_feedback_text("Piochez d’abord. Ensuite, repérez vos tris avant de choisir la défausse.", Color("f0a18e"))
		return false
	_highlighted.clear()
	for group in engine.tri_groups(engine.state.players[0].hand): _highlighted.append_array(group)
	stage = 2
	_refresh()
	_feedback_text("Vos tris sont surlignés uniquement dans votre main. Gardez-les et sélectionnez le roi de pique isolé" + (", ou une autre carte libre" if hand_size == 12 else "") + ", puis défaussez.", GOLD)
	return true

func toggle_card(card_id: String) -> bool:
	if engine == null or card_id not in engine.state.players[0].hand:
		_feedback_text("Choisissez une carte de votre main.", Color("f0a18e"))
		return false
	if stage != 2:
		_feedback_text("Piochez puis touchez « Mes tris » avant de choisir une défausse." if stage < 2 else "La victoire est acquise. Vous pouvez recommencer ou revenir à l’accueil.", MUTED)
		return false
	if card_id in _highlighted:
		_feedback_text("Cette carte fait partie d’un tri utile. Gardez les cartes dorées et choisissez une carte libre, par exemple le roi de pique.", Color("f0a18e"))
		return false
	if selected == [card_id]: selected.clear()
	else: selected.assign([card_id])
	_refresh()
	_feedback_text("Touchez « Défausser » : la victoire sera vérifiée après que cette carte aura quitté votre main." if not selected.is_empty() else "Sélectionnez une seule carte libre à défausser.", GOLD)
	return true

func discard_selected() -> bool:
	if engine == null or stage != 2 or selected.size() != 1:
		_feedback_text("Piochez, repérez vos tris, puis sélectionnez exactement une carte libre avant de défausser.", Color("f0a18e"))
		return false
	var rest: Array = engine.state.players[0].hand.duplicate()
	rest.erase(selected[0])
	if engine.tri_groups(rest).size() < int(engine.state.tri_goal):
		_feedback_text("Cette défausse casserait un tri. Choisissez une carte libre pour garder assez de tris.", Color("f0a18e"))
		return false
	var result: Dictionary = engine.apply_action(0,{"type":"discard","card":selected[0]})
	if not result.ok:
		_feedback_text(str(result.error), Color("f0a18e"))
		return false
	hand_order.erase(selected[0])
	selected.clear()
	stage = 3
	_refresh()
	_feedback_text("Victoire ! Vos %d tris sont toujours dans votre main." % int(engine.state.tri_goal) + (" Les trois autres cartes restent libres : elles n’ont pas besoin de former un quatrième tri." if hand_size == 12 else " Vous avez gardé les six cartes de vos deux tris."), GOLD)
	if not _completed_emitted:
		_completed_emitted = true
		completed.emit()
	return true

func sort_hand() -> void:
	if engine == null: return
	_sort_by_rank = not _sort_by_rank
	hand_order.sort_custom(func(a,b):
		var first: Dictionary = engine.card_info(a)
		var second: Dictionary = engine.card_info(b)
		var key_a: int = int(first.rank)*10 + "CDHS".find(first.suit) if _sort_by_rank else "CDHS".find(first.suit)*100 + int(first.rank)
		var key_b: int = int(second.rank)*10 + "CDHS".find(second.suit) if _sort_by_rank else "CDHS".find(second.suit)*100 + int(second.rank)
		return key_a < key_b)
	_render_cards()
	_feedback_text("Cartes rangées par " + ("valeur : les mêmes chiffres se retrouvent ensemble." if _sort_by_rank else "couleur, puis par valeur.") + " Trier ne pose aucune carte et ne montre rien à l’adversaire.", MUTED)

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
	_heading = _label("Votre première victoire au Tri", 30, INK, row)
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
	_button("Trier", sort_hand, actions)
	_button("Recommencer", func(): start_lesson(hand_size), actions)
	_button("Retour", func(): exit_requested.emit(), actions)
	_scroll.resized.connect(_resize_cards)

func _refresh() -> void:
	if not _built or engine == null: return
	var goal := int(engine.state.tri_goal)
	var headings := ["1 · Piochez avant de défausser", "2 · Repérez vos tris cachés", "3 · Choisissez une défausse", "Victoire au Tri !"]
	var descriptions := [
		"Au Tri, on gagne avec %d tris parmi %d cartes. Piocher ajoute une carte ; défausser en enlève une. Commencez ici par la pioche." % [goal,hand_size],
		"Un tri contient exactement trois cartes de même valeur, au maximum deux de la même couleur (♣ ♦ ♥ ♠). Une carte physique ne compte que dans un tri. Les suites ne comptent pas.",
		"Les tris restent cachés en main jusqu’à la victoire. Ne posez rien sur la table. Choisissez une carte qui n’est pas surlignée : le roi de pique est libre.",
		"Le jeu vérifie votre victoire après la défausse. Vous gagnez avec %d tris distincts, tout en gardant vos %d cartes en main." % [goal,hand_size]
	]
	_heading.text = headings[stage]
	_progress.text = "%d CARTES · OBJECTIF %d TRIS" % [hand_size,goal]
	_explanation.text = descriptions[stage]
	_example.text = "7♥ + 7♥ + 7♣ : un tri valable. Les deux 7♥ sont deux cartes physiques différentes."
	if stage >= 1:
		_example.text = "VOS TRIS : 7♥–7♥–7♣ et 8♠–8♣–8♦" + (", ainsi que 9♠–9♣–9♦." if hand_size == 12 else ".")
	if hand_size == 12:
		_example.text += " Avec 12 cartes, 3 tris utilisent 9 cartes ; les 3 autres cartes restent libres."
	_action.text = ["Piocher une carte", "Mes tris", "Défausser la carte choisie", "Exercice terminé"][stage]
	_action.disabled = stage == 3 or (stage == 2 and selected.size() != 1)
	_render_cards()

func _render_cards() -> void:
	for child in _grid.get_children():
		_grid.remove_child(child)
		child.queue_free()
	_card_buttons.clear()
	var hand: Array = engine.state.players[0].hand
	_grid.columns = mini(7,maxi(1,ceili(hand.size()/2.0)))
	for id_value in hand_order:
		var id: String = str(id_value)
		if id not in hand: continue
		var chosen: bool = id in selected
		var grouped: bool = id in _highlighted
		var button := Button.new()
		button.name = "Card_" + id.replace(":","_")
		button.tooltip_text = _card_label(id) + (" · fait partie d’un tri" if grouped else "")
		button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		button.disabled = stage != 2
		var style := _style(Color("285b4d") if chosen else Color("123a36"), GOLD if chosen or grouped else Color("4c6b60"),3)
		style.set_border_width_all(4 if chosen else (2 if grouped else 1))
		button.add_theme_stylebox_override("normal",style)
		button.add_theme_stylebox_override("disabled",style)
		button.add_theme_stylebox_override("hover",_style(Color("326b55"),GOLD,3))
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
		1: show_tris()
		2: discard_selected()

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
