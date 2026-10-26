extends Node3D

const EngineRules = preload("res://scripts/rami_engine.gd")
const CardView = preload("res://scripts/card_3d.gd")
const NetworkRoom = preload("res://scripts/network_manager.gd")
const MusicPlayer = preload("res://scripts/music_manager.gd")
const Coach = preload("res://scripts/beginner_coach.gd")
const SortingChallenge = preload("res://scripts/sorting_challenge.gd")
const SoloStore = preload("res://scripts/solo_store.gd")
const SoundEffects = preload("res://scripts/sound_effects.gd")
const Invitation = preload("res://scripts/invitation.gd")
const HAND_SCALE := 2.15
const DECK_POSITION := Vector3(-0.8, 0.28, -0.8)
const INK = Color("ecede3")
const MUTED = Color("91aba7")
const GOLD = Color("dfbd78")
const TEAL = Color("123c3a")
const DEEP = Color("0a2428")

var engine: RefCounted
var network: Node
var snapshot: Dictionary = {}
var selected: Array = []
var card_nodes: Array = []
var suggested: Array = []
var game_mode := "menu"
var sort_suit := true
var busy := false
var player_name := "Vous"
var bot_count := 1
var camera: Camera3D
var ui: Control
var content: Control
var overlay: Control
var toast_label: Label
var toast_time := 0.0
var header_status: Label
var game_status: Label
var hand_status: Label
var players_row: HBoxContainer
var draw_buttons: Array = []
var action_row: HBoxContainer
var lobby_box: VBoxContainer
var lobby_start: Button
var current_lobby: Dictionary = {}
var name_input: LineEdit
var address_input: LineEdit
var code_input: LineEdit
var solo_select: OptionButton
var online_tab := false
var last_click := 0
var music: Node
var music_settings: Dictionary = {"enabled":true, "volume":0.28, "track_index":0}
var music_button: Button
var fullscreen_button: Button
var fullscreen_enabled := false
var beginner_enabled := true
var coach := Coach.new()
var hand_root: Node3D
var hand_cards: Array = []
var coach_button: Button
var lesson_index := -1
var overlay_kind := ""
var saved_address := ""
var saved_name := "Vous"
var turn_token := 0
# Public card IDs stay attached to one mesh as it moves between hand/table.
# Deck backs use separate keys: their placeholder ID is not a physical card.
var _view_cards: Dictionary = {}
var _previous_cards: Dictionary = {}
var _rendered_turn := -1
var difficulty := 1
var match_length := 1
var hand_order: Array = []
var effects: Node
var effects_volume := 0.55
var effects_enabled := true
var _sound_revision := ""
var _winner_key := ""
var _drag_card: Node3D
var _drag_start := Vector2.ZERO
var _drag_pointer := -2
var _drag_active := false
var _drag_selection: Array = []
var _drag_offset := Vector3.ZERO
var _last_touch_ms := -1000
var invitation_input: LineEdit

func _ready() -> void:
	get_viewport().physics_object_picking = true
	Input.emulate_touch_from_mouse = false
	_load_preferences()
	_make_world()
	_make_interface()
	effects = SoundEffects.new()
	effects.volume = effects_volume
	effects.enabled = effects_enabled
	add_child(effects)
	music = MusicPlayer.new()
	music.apply_settings(music_settings)
	add_child(music)
	music.settings_changed.connect(_music_settings_changed)
	music_button.text = "Musique" if music.enabled else "Musique coupée"
	get_viewport().size_changed.connect(_screen_changed)
	_screen_changed()
	if OS.has_feature("android"):
		_set_fullscreen(true, false)
	network = NetworkRoom.new()
	add_child(network)
	network.lobby_updated.connect(_lobby_updated)
	network.game_updated.connect(_network_game_updated)
	network.notice.connect(_toast)
	network.connection_changed.connect(_connection_changed)
	_show_menu()
	# Reproducible visual checks can start an offline table without network access.
	if "--demo" in OS.get_cmdline_user_args():
		_start_solo()

func _process(delta: float) -> void:
	if toast_time > 0:
		toast_time -= delta
		toast_label.modulate.a = minf(1.0, toast_time * 2.0)
		if toast_time <= 0:
			toast_label.hide()

func _notification(what: int) -> void:
	if what in [NOTIFICATION_APPLICATION_PAUSED, NOTIFICATION_WM_CLOSE_REQUEST, NOTIFICATION_APPLICATION_FOCUS_OUT]:
		_autosave()
		_cancel_drag()
	if what == NOTIFICATION_APPLICATION_RESUMED and OS.has_feature("android") and fullscreen_enabled:
		_set_fullscreen(true, false)
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		if overlay and overlay.get_child_count() > 0:
			_close_overlay()
		elif game_mode != "menu":
			_confirm_leave()
		else:
			get_tree().quit()

func _make_world() -> void:
	var world := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("07191e")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("c5e1d5")
	env.ambient_light_energy = 0.32
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	world.environment = env
	add_child(world)
	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 11.8
	camera.keep_aspect = Camera3D.KEEP_HEIGHT
	camera.position = Vector3(0, 14, 10.5)
	add_child(camera)
	camera.look_at(Vector3(0, 0, 0.35))
	camera.current = true
	hand_root = Node3D.new()
	hand_root.name = "VotreMain"
	camera.add_child(hand_root)
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-58, -30, 0)
	key.light_color = Color("fff1d4")
	key.light_energy = 0.65
	key.shadow_enabled = true
	add_child(key)
	var light := OmniLight3D.new()
	light.position = Vector3(0, 7, -3)
	light.light_color = Color("6bb8a5")
	light.light_energy = 0.35
	light.omni_range = 18
	add_child(light)
	_cylinder(9.7, 0.60, -0.55, Color("241e19"), Vector3(1, 1, 0.68))
	_cylinder(9.62, 0.11, -0.20, Color("a17f4a"), Vector3(1, 1, 0.68))
	_cylinder(9.47, 0.16, -0.12, Color("1d3937"), Vector3(1, 1, 0.68))
	_cylinder(9.10, 0.12, -0.02, Color("14564c"), Vector3(1, 1, 0.68))
	# An inset edge creates a quiet, physical table with no downloaded assets.
	var ring := TorusMesh.new()
	ring.inner_radius = 8.88
	ring.outer_radius = 8.91
	ring.rings = 96
	ring.ring_segments = 12
	var stitch := MeshInstance3D.new()
	stitch.mesh = ring
	stitch.scale = Vector3(1, 0.14, 0.68)
	stitch.position.y = 0.051
	stitch.material_override = _material(Color("638b6e"))
	add_child(stitch)
	var floor_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(200, 200)
	floor_mesh.mesh = plane
	floor_mesh.position.y = -1.1
	floor_mesh.material_override = _material(Color("071b20"))
	add_child(floor_mesh)
	var brand := Label3D.new()
	brand.text = "R A M I   S A L O N"
	brand.font = load("res://assets/serif.ttf")
	brand.font_size = 90
	brand.pixel_size = 0.009
	brand.modulate = Color(0.60, 0.77, 0.62, 0.32)
	brand.outline_size = 0
	brand.no_depth_test = false
	brand.rotation_degrees.x = -90
	brand.position = Vector3(0, 0.065, -2.15)
	add_child(brand)

func _cylinder(radius: float, height: float, y: float, color: Color, scl: Vector3) -> void:
	var node := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = height
	mesh.radial_segments = 96
	node.mesh = mesh
	node.position.y = y
	node.scale = scl
	node.material_override = _material(color)
	add_child(node)

func _material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.82
	return mat

func _make_interface() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	ui = Control.new()
	ui.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(ui)
	var theme := Theme.new()
	var text_font := load("res://assets/sans.ttf") as FontFile
	var symbol_fallbacks: Array[Font] = [load("res://assets/symbols.ttf")]
	text_font.fallbacks = symbol_fallbacks
	theme.default_font = text_font
	theme.default_font_size = 19
	theme.set_color("font_color", "Label", INK)
	theme.set_color("font_color", "Button", INK)
	theme.set_color("font_hover_color", "Button", GOLD)
	theme.set_color("font_disabled_color", "Button", Color("627c78"))
	theme.set_stylebox("normal", "Button", _style(Color("163b3c"), Color("345653"), 12, 18))
	theme.set_stylebox("hover", "Button", _style(Color("245653"), GOLD, 12, 18))
	theme.set_stylebox("pressed", "Button", _style(Color("32685d"), GOLD, 12, 18))
	theme.set_stylebox("disabled", "Button", _style(Color("152e31"), Color("27413f"), 12, 18))
	theme.set_stylebox("normal", "LineEdit", _style(Color("0c282c"), Color("365956"), 10, 16))
	theme.set_stylebox("focus", "LineEdit", _style(Color("123b3c"), GOLD, 10, 16))
	theme.set_color("font_color", "LineEdit", INK)
	theme.set_color("font_placeholder_color", "LineEdit", MUTED)
	theme.set_stylebox("panel", "PopupMenu", _style(DEEP, Color("365956"), 8, 10))
	ui.theme = theme
	var header := HBoxContainer.new()
	_place(header, ui, Vector2(36, 22), Vector2(-36, 78), Vector2(0,0), Vector2(1,0))
	header.add_theme_constant_override("separation", 12)
	var logo := TextureRect.new()
	logo.texture = load("res://assets/icon.svg")
	logo.custom_minimum_size = Vector2(46, 46)
	logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	header.add_child(logo)
	var brand := VBoxContainer.new()
	brand.add_theme_constant_override("separation", -3)
	header.add_child(brand)
	_label("RAMI SALON", 24, INK, brand)
	_label("L E   P L A I S I R   D E   J O U E R", 10, GOLD, brand)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)
	header_status = _label("HORS LIGNE · SANS COMPTE", 13, MUTED, header)
	header_status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_button("Apprendre", _show_rules, header)
	music_button = _button("Musique", _show_music_settings, header)
	fullscreen_button = _button("Plein écran", _toggle_fullscreen, header)
	_button("Accueil", _confirm_leave, header)
	content = Control.new()
	_place(content, ui, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ONE)
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay = Control.new()
	_place(overlay, ui, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ONE)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	toast_label = _label("", 19, INK, ui)
	_place(toast_label, ui, Vector2(-400,-192), Vector2(400,-140), Vector2(0.5,1), Vector2(0.5,1))
	toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	toast_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	toast_label.add_theme_stylebox_override("normal", _style(Color("183d3b"), GOLD, 12, 14))
	toast_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	toast_label.hide()

func _style(bg: Color, border: Color = Color.TRANSPARENT, radius: int = 16, pad: int = 24) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = bg
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(radius)
	style.content_margin_left = pad
	style.content_margin_right = pad
	style.content_margin_top = pad
	style.content_margin_bottom = pad
	return style

func _place(node: Control, parent: Node, a: Vector2, b: Vector2, anchor_a: Vector2 = Vector2.ZERO, anchor_b: Vector2 = Vector2.ZERO) -> void:
	if node.get_parent() != parent:
		parent.add_child(node)
	node.anchor_left = anchor_a.x
	node.anchor_top = anchor_a.y
	node.anchor_right = anchor_b.x
	node.anchor_bottom = anchor_b.y
	node.offset_left = a.x
	node.offset_top = a.y
	node.offset_right = b.x
	node.offset_bottom = b.y

func _label(text: String, size: int, color: Color, parent: Node) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(label)
	return label

func _button(text: String, callback: Callable, parent: Node, primary: bool = false) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size.y = 52
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	if primary:
		button.add_theme_stylebox_override("normal", _style(GOLD, GOLD, 10, 16))
		button.add_theme_stylebox_override("hover", _style(Color("f0d395"), Color("f0d395"), 10, 16))
		button.add_theme_stylebox_override("pressed", _style(Color("bd9958"), GOLD, 10, 16))
		button.add_theme_color_override("font_color", DEEP)
		button.add_theme_color_override("font_hover_color", DEEP)
		button.add_theme_color_override("font_pressed_color", DEEP)
	button.pressed.connect(callback)
	parent.add_child(button)
	return button

func _field(placeholder: String, value: String, parent: Node) -> LineEdit:
	var input := LineEdit.new()
	input.placeholder_text = placeholder
	input.text = value
	input.custom_minimum_size.y = 54
	input.max_length = 120
	parent.add_child(input)
	return input

func _clear_content() -> void:
	for node in content.get_children():
		node.get_parent().remove_child(node)
		node.queue_free()
	selected.clear()
	suggested.clear()
	_clear_cards()

func _clear_cards() -> void:
	_cancel_drag(false)
	for card in card_nodes:
		if is_instance_valid(card):
			card.get_parent().remove_child(card)
			card.queue_free()
	card_nodes.clear()
	hand_cards.clear()
	_view_cards.clear()
	_previous_cards.clear()
	_rendered_turn = -1

func _show_menu() -> void:
	turn_token += 1
	busy = false
	game_mode = "menu"
	snapshot = {}
	_clear_content()
	header_status.text = "HORS LIGNE · SANS COMPTE"
	var shade := ColorRect.new()
	shade.color = Color(0.015, 0.06, 0.07, 0.36)
	_place(shade, content, Vector2(0, 96), Vector2.ZERO, Vector2.ZERO, Vector2.ONE)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var hero := VBoxContainer.new()
	_place(hero, content, Vector2(68, 148), Vector2(670, 460))
	hero.add_theme_constant_override("separation", 12)
	_label("VOTRE TABLE VOUS ATTEND", 15, GOLD, hero)
	var title := _label("À vous\nde jouer.", 76, INK, hero)
	title.add_theme_font_override("font", load("res://assets/serif.ttf"))
	title.add_theme_constant_override("line_spacing", -14)
	_label("Un beau jeu. Une bonne main.\nLe plaisir du rami, où que vous soyez.", 23, Color("bdd0c7"), hero)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _style(Color(0.035, 0.13, 0.15, 0.96), Color("3a5b51"), 22, 30))
	_place(panel, content, Vector2(-470, 120), Vector2(-48, -40), Vector2(1,0), Vector2(1,1))
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	var menu_scroll := ScrollContainer.new()
	menu_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(menu_scroll)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	menu_scroll.add_child(box)
	_label("Installez-vous", 29, INK, box)
	_label("Comment voulez-vous jouer ?", 17, MUTED, box)
	name_input = _field("Votre prénom", saved_name, box)
	name_input.max_length = 18
	var divider := HSeparator.new()
	box.add_child(divider)
	_label("01  ·  EN SOLO", 13, GOLD, box)
	solo_select = OptionButton.new()
	solo_select.custom_minimum_size.y = 45
	solo_select.add_item("Face à 1 ordinateur", 1)
	solo_select.add_item("Face à 2 ordinateurs", 2)
	solo_select.add_item("Face à 3 ordinateurs", 3)
	box.add_child(solo_select)
	if not SoloStore.load_game().is_empty():
		_button("Reprendre ma partie solo", _resume_solo, box, true)
	_button("Jouer contre l’ordinateur   →", _start_solo, box, true)
	_label("02  ·  EN BONNE COMPAGNIE", 13, GOLD, box)
	_button("Jouer avec des amis   ↗", _open_friends, box)
	_label("2 à 4 joueurs · un téléphone par personne", 12, MUTED, box)
	_label("03  ·  POUR LE PLAISIR DE RANGER", 13, GOLD, box)
	_button("Défi de tri   →", _start_sorting, box)
	_label("3 manches · grandes cartes · à votre rythme", 12, MUTED, box)
	_button("Je débute : apprendre le rami", _show_rules, hero)
	_button("Difficulté, manches et statistiques", _show_solo_settings, hero)
	var footer := HBoxContainer.new()
	_place(footer, content, Vector2(68,-72), Vector2(-68,-30), Vector2(0,1), Vector2(1,1))
	footer.add_theme_constant_override("separation", 32)
	_label("♠   UNE VRAIE TABLE EN 3D", 12, MUTED, footer)
	_label("♣   WI-FI & INTERNET", 12, MUTED, footer)
	_label("♦   SANS PUBLICITÉ", 12, MUTED, footer)
	var menu_ids := ["0:H:1", "0:S:13", "0:D:12", "0:C:11", "0:H:10"]
	for i in range(menu_ids.size()):
		var card = _card(menu_ids[i], true, Vector3(-4.3 + i * 1.0, 0.22 + i * 0.035, 3.85 - absf(i - 2) * 0.1))
		card.rotation_degrees.y = (i - 2) * -9.0
		card.scale = Vector3.ONE * 1.8
		var target: Transform3D = card.transform
		card.position += Vector3(-0.65, -0.4, 0.7)
		card.rotation_degrees.y -= 12.0
		card.move_to(target, 0.50, i * 0.055, 0.16)

func _save_profile() -> void:
	if is_instance_valid(name_input):
		player_name = name_input.text.strip_edges().left(18)
	if player_name.is_empty():
		player_name = "Vous"
	saved_name = player_name
	_save_preferences()

func _start_solo() -> void:
	turn_token += 1
	busy = false
	_save_profile()
	bot_count = solo_select.selected + 1 if is_instance_valid(solo_select) else bot_count
	network.leave_room()
	_close_overlay()
	engine = EngineRules.new()
	var names: Array = [player_name]
	var bots := ["Camille", "Alex", "Charlie"]
	for i in range(bot_count):
		names.append(bots[i])
	hand_order.clear()
	_winner_key = ""
	_sound_revision = ""
	engine.start_game(names, 0, match_length)
	game_mode = "solo"
	_show_game()
	_refresh_snapshot()
	_toast("Piochez pour commencer. « Conseils pas à pas » vous accompagne." if beginner_enabled else "Piochez une carte pour commencer.")

func _show_game() -> void:
	_clear_content()
	header_status.text = "SOLO · " + ["FACILE","NORMAL","DIFFICILE"][difficulty] if game_mode == "solo" else "TABLE PRIVÉE · " + network.room_code
	players_row = HBoxContainer.new()
	players_row.alignment = BoxContainer.ALIGNMENT_CENTER
	players_row.add_theme_constant_override("separation", 18)
	_place(players_row, content, Vector2(0,103), Vector2(0,178), Vector2(0,0), Vector2(1,0))
	game_status = _label("", 21, INK, content)
	_place(game_status, content, Vector2(-420,194), Vector2(420,238), Vector2(0.5,0), Vector2(0.5,0))
	game_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	game_status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var draw_row := HBoxContainer.new()
	draw_row.alignment = BoxContainer.ALIGNMENT_CENTER
	draw_row.add_theme_constant_override("separation", 16)
	_place(draw_row, content, Vector2(-270,420), Vector2(270,470), Vector2(0.5,0), Vector2(0.5,0))
	draw_buttons = []
	draw_buttons.append(_button("↓  Piocher", func(): _act({"type":"draw", "source":"deck"}), draw_row))
	draw_buttons.append(_button("↙  Défausse", func(): _act({"type":"draw", "source":"discard"}), draw_row))
	hand_status = _label("VOTRE MAIN", 14, GOLD, content)
	_place(hand_status, content, Vector2(38,424), Vector2(410,470))
	hand_status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	coach_button = _button("Conseils pas à pas", _show_coach, content, true)
	_place(coach_button, content, Vector2(-300,420), Vector2(-38,472), Vector2(1,0), Vector2(1,0))
	action_row = HBoxContainer.new()
	action_row.alignment = BoxContainer.ALIGNMENT_CENTER
	action_row.add_theme_constant_override("separation", 12)
	_place(action_row, content, Vector2(24,-94), Vector2(-24,-35), Vector2(0,1), Vector2(1,1))
	_button("Trier ♠", _sort_hand, action_row)
	_button("Suggestion", _suggest, action_row)
	_button("Poser", _meld_selected, action_row, true)
	_button("Compléter", _extend_selected, action_row)
	_button("Défausser →", _discard_selected, action_row)

func _refresh_snapshot() -> void:
	if game_mode == "solo":
		snapshot = engine.view_for(0)
		snapshot["your_index"] = 0
	_render_snapshot()
	_autosave()
	if game_mode == "solo" and int(snapshot.get("winner", -1)) < 0 and int(snapshot.get("turn", 0)) != 0 and not busy:
		_run_bots()

func _render_snapshot() -> void:
	if not is_instance_valid(players_row):
		return
	_cancel_drag(false)
	var initial_deal := _view_cards.is_empty()
	_play_snapshot_sound(initial_deal)
	_previous_cards = _view_cards.duplicate()
	_view_cards.clear()
	card_nodes.clear()
	hand_cards.clear()
	selected.clear()
	suggested.clear()
	for node in players_row.get_children():
		node.get_parent().remove_child(node)
		node.queue_free()
	var own := int(snapshot.get("your_index", 0))
	var turn := int(snapshot.get("turn", 0))
	var players: Array = snapshot.get("players", [])
	if game_mode == "solo":
		header_status.text = "SOLO · %s · %d/%d" % [["FACILE","NORMAL","DIFFICILE"][difficulty],int(snapshot.get("match",{}).get("round",1)),int(snapshot.get("match",{}).get("length",1))]
	for i in range(players.size()):
		var panel := PanelContainer.new()
		panel.custom_minimum_size = Vector2(210, 65)
		panel.add_theme_stylebox_override("panel", _style(Color("123c38") if i == turn else Color("0c292d"), GOLD if i == turn else Color("30504b"), 12, 10))
		players_row.add_child(panel)
		var column := VBoxContainer.new()
		column.add_theme_constant_override("separation", 2)
		panel.add_child(column)
		var p: Dictionary = players[i]
		var name_text := str(p.get("name", "Joueur")) + (" · vous" if i == own and p.get("name", "") != "Vous" else "")
		var l := _label(("●  " if i == turn else "○  ") + name_text, 17, GOLD if i == turn else INK, column)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		var count := int(p.get("count", p.get("hand_count", 13)))
		l = _label(str(count) + " cartes  ·  " + ("ouvert" if p.get("opened", false) else "à ouvrir : 30 pts"), 12, MUTED, column)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var phase: String = snapshot.get("phase", "draw")
	var can_act: bool = turn == own and not snapshot.get("paused", false) and int(snapshot.get("winner", -1)) < 0
	for button in draw_buttons:
		button.disabled = not can_act or phase != "draw"
	if not draw_buttons.is_empty():
		draw_buttons[0].text = "↓  Piocher · " + str(snapshot.get("deck_count", 0))
	for i in range(1, action_row.get_child_count()):
		action_row.get_child(i).disabled = not can_act or phase != "play"
	if snapshot.get("paused", false):
		game_status.text = "Partie en pause · en attente d’un joueur"
	elif turn == own:
		game_status.text = ("Étape 1/3 · prenez une carte" if phase == "draw" else "Étapes 2–3 · posez si possible, puis défaussez") if beginner_enabled else "À vous · " + ("piochez une carte" if phase == "draw" else "posez vos combinaisons, puis défaussez")
	else:
		game_status.text = str(players[turn].get("name", "L’adversaire")) + " joue…" if turn < players.size() else "En attente…"
	var hand: Array = snapshot.get("hand", []).duplicate()
	if hand_order.is_empty():
		hand.sort_custom(func(a, b): return _sort_key(str(a)) < _sort_key(str(b)))
	else:
		var ordered: Array = []
		for id in hand_order:
			if id in hand and not id in ordered: ordered.append(id)
		for id in hand:
			if not id in ordered: ordered.append(id)
		hand = ordered
	hand_order = hand.duplicate()
	var revealed_discard := false
	for id in hand:
		var key := "card:" + str(id)
		if _previous_cards.has(key) and _previous_cards[key].get_meta("zone", "") == "discard":
			revealed_discard = true
		var card = _view_card(str(id), true, hand_root, "card:" + str(id), "hand")
		if card.get_meta("new_in_view", false):
			# Turn over the back while the card leaves the deck. Only this
			# player's already-authorized hand IDs ever reach this view.
			card.global_transform = Transform3D(Basis(Vector3.RIGHT, PI), DECK_POSITION)
		hand_cards.append(card)
	_layout_hand(true, initial_deal)
	_update_hand_status()
	var deck_count := int(snapshot.get("deck_count", 0))
	for i in range(3 if deck_count > 0 else 0):
		var back = _view_card("0:S:1", false, self, "deck:" + str(i), "deck")
		var target := Transform3D(Basis.IDENTITY, Vector3(-0.8 + i * 0.018, 0.14 + i * 0.045, -0.8))
		back.move_to(target, 0.0)
	var discard_top = snapshot.get("discard_top", "")
	if discard_top != null and str(discard_top) != "":
		var face = _view_card(str(discard_top), true, self, "card:" + str(discard_top), "discard")
		_place_table_card(face, Transform3D(Basis(Vector3.UP, deg_to_rad(-5)), Vector3(0.85, 0.19, -0.8)), initial_deal or revealed_discard)
	var melds: Array = snapshot.get("melds", [])
	var first_visible := maxi(0, melds.size() - 4)
	for i in range(first_visible, melds.size()):
		var cards: Array = melds[i].get("cards", [])
		var col := (i - first_visible) % 4
		for j in range(cards.size()):
			var gap := minf(0.4, 2.25 / maxf(1, cards.size() - 1))
			var position_card := Vector3(-5.3 + col * 3.5 + (j - (cards.size()-1)/2.0) * gap, 0.12 + j * 0.005, -2.5)
			var card = _view_card(str(cards[j]), true, self, "card:" + str(cards[j]), "meld")
			card.set_meta("meld_index", i)
			_place_table_card(card, Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * 0.70), position_card), initial_deal, j * 0.035)
	_render_opponents(initial_deal)
	_update_hand_status()
	# Cards no longer present in the visible snapshot cannot retain callbacks
	# or keep an animation alive after leaving this table.
	for card in _previous_cards.values():
		card.get_parent().remove_child(card)
		card.queue_free()
	_previous_cards.clear()
	if _rendered_turn != turn:
		game_status.modulate.a = 0.45
		game_status.create_tween().tween_property(game_status, "modulate:a", 1.0, 0.24)
	_rendered_turn = turn
	if int(snapshot.get("winner", -1)) >= 0:
		_show_winner()
	elif overlay_kind == "coach":
		_show_coach()

func _view_card(id: String, face: bool, parent: Node3D, key: String, zone: String) -> Node3D:
	var card: Node3D
	var existing := _previous_cards.has(key)
	if existing:
		card = _previous_cards[key]
		_previous_cards.erase(key)
		if card.get_parent() != parent:
			# Preserve the visible pose across the camera-relative hand and
			# world-space table, then start the next flight in the new space.
			card.cancel_motion()
			card.reparent(parent, true)
		card_nodes.append(card)
	else:
		card = _card(id, face, Vector3.ZERO, parent)
		card.tapped.connect(_view_card_tapped)
	card.set_meta("new_in_view", not existing)
	card.set_meta("arriving", not existing or card.get_meta("zone", "") != zone)
	card.set_meta("zone", zone)
	card.set_meta("hand_card", zone == "hand")
	card.set_selected(false, zone != "hand")
	_view_cards[key] = card
	return card

func _place_table_card(card: Node3D, target: Transform3D, initial: bool, delay: float = 0.0) -> void:
	if card.get_meta("new_in_view", false):
		if initial:
			card.move_to(target, 0.0)
			return
		# A newly public opponent card starts at the far side of the table.
		# This uses no hidden opponent hand data.
		card.transform = Transform3D(Basis.IDENTITY, _opponent_position(int(snapshot.get("last_action",{}).get("player",1))))
	card.move_to(target, 0.38, delay if card.get_meta("arriving", false) else 0.0, 0.35)

func _view_card_tapped(card: Node3D) -> void:
	match str(card.get_meta("zone", "")):
		"hand": _select_card(card)
		"deck": _act({"type":"draw", "source":"deck"})
		"discard": _act({"type":"draw", "source":"discard"})
		"meld": _extend_at(int(card.get_meta("meld_index", -1)))

func _sort_key(id: String) -> int:
	var info: Dictionary = engine.card_info(id) if game_mode == "solo" else EngineRules.new().card_info(id)
	var suit := "CDHS".find(str(info.get("suit", "J")))
	var rank := int(info.get("rank", 0))
	if info.get("joker", false):
		return 10000
	return suit * 100 + rank if sort_suit else rank * 10 + suit

func _card(id: String, face: bool, pos: Vector3, parent: Node = null) -> Node3D:
	var card = CardView.new()
	if parent == null:
		parent = self
	parent.add_child(card)
	card.setup(id, face)
	card.position = pos
	card_nodes.append(card)
	return card

func _select_card(card) -> void:
	if not _my_turn(false):
		return
	effects.play("select")
	var id: String = card.card_id
	if selected.has(id):
		selected.erase(id)
		_set_hand_selection(card, false)
	else:
		selected.append(id)
		_set_hand_selection(card, true)
	suggested.clear()
	_update_hand_status()

func _update_hand_status() -> void:
	if is_instance_valid(hand_status):
		var opening := ""
		var own := int(snapshot.get("your_index", 0))
		var players: Array = snapshot.get("players", [])
		if own < players.size() and not players[own].get("opened", false):
			var preview: Dictionary = EngineRules.new().selection_preview(snapshot, selected, suggested)
			opening = "\nOUVERTURE : %d / 30 POINTS" % int(preview.points)
		hand_status.text = "VOTRE MAIN · " + str(snapshot.get("hand", []).size()) + " CARTES" + opening
		if not selected.is_empty():
			hand_status.text = "VOTRE MAIN · " + str(snapshot.get("hand", []).size()) + " CARTES · " + str(selected.size()) + " CHOISIE(S)" + opening

	var preview: Dictionary = EngineRules.new().selection_preview(snapshot, selected, suggested)
	for card in card_nodes:
		if card.get_meta("zone","") == "meld":
			card.set_selected(int(card.get_meta("meld_index",-1)) in preview.targets, false)

func _my_turn(show_error: bool = true) -> bool:
	if snapshot.is_empty() or int(snapshot.get("winner", -1)) >= 0:
		return false
	if snapshot.get("paused", false):
		if show_error: _toast("Un joueur doit se reconnecter pour continuer.")
		return false
	if int(snapshot.get("turn", -1)) != int(snapshot.get("your_index", 0)):
		if show_error: _toast("C’est au tour de votre adversaire.")
		return false
	return true

func _act(action: Dictionary) -> void:
	if not _my_turn():
		return
	if game_mode == "solo":
		var result: Dictionary = engine.apply_action(0, action)
		if not result.get("ok", false):
			_toast(str(result.get("error", "Action impossible.")))
			return
		_refresh_snapshot()
	else:
		network.send_action(action)

func _sort_hand() -> void:
	sort_suit = not sort_suit
	hand_order.clear()
	_render_snapshot()
	_autosave()
	_toast("Cartes triées par " + ("couleur." if sort_suit else "valeur."))

func _suggest() -> void:
	if not _my_turn(): return
	if snapshot.get("phase", "draw") != "play":
		_toast("Piochez d’abord une carte.")
		return
	var helper = engine if game_mode == "solo" else EngineRules.new()
	if game_mode != "solo":
		# Reconstruct only this player's visible data; no opponent hand is needed.
		var players: Array = []
		for p in snapshot.get("players", []):
			players.append({"name":p.get("name", ""), "hand":[], "opened":p.get("opened", false)})
		players[int(snapshot.get("your_index",0))]["hand"] = snapshot.get("hand", []).duplicate()
		helper.state = {"players":players}
	suggested = helper.suggest_melds(int(snapshot.get("your_index", 0)))
	selected.clear()
	for group in suggested:
		selected.append_array(group)
	for card in hand_cards:
		_set_hand_selection(card, selected.has(card.card_id))
	_update_hand_status()
	_toast("Touchez « Poser » pour jouer les cartes proposées." if not selected.is_empty() else "Aucune combinaison à poser pour le moment.")

func _meld_selected() -> void:
	if selected.is_empty():
		_toast("Sélectionnez au moins 3 cartes ou utilisez Suggestion.")
		return
	_act({"type":"meld", "groups":suggested.duplicate(true)} if not suggested.is_empty() else {"type":"meld", "cards":selected.duplicate()})

func _discard_selected() -> void:
	if selected.size() != 1:
		_toast("Sélectionnez une seule carte à défausser.")
		return
	_act({"type":"discard", "card":selected[0]})

func _extend_selected() -> void:
	if selected.is_empty():
		_toast("Sélectionnez les cartes à ajouter, puis touchez une combinaison sur la table.")
		return
	var melds: Array = snapshot.get("melds", [])
	if melds.is_empty():
		_toast("Il n’y a pas encore de combinaison sur la table.")
		return
	var box := _modal("Compléter une combinaison", "Choisissez la combinaison qui recevra vos cartes.")
	for i in range(melds.size()):
		var names: Array = []
		for id in melds[i].get("cards", []):
			var info: Dictionary = EngineRules.new().card_info(str(id))
			var suits := {"S":"♠", "H":"♥", "D":"♦", "C":"♣", "J":""}
			names.append(str(info.get("label", id)) + str(suits.get(info.get("suit", ""), "")))
		var idx := i
		var preview: Dictionary = EngineRules.new().selection_preview(snapshot, selected, suggested)
		var button := _button(str(i+1) + " · " + "  ".join(names), func(): _close_overlay(); _extend_at(idx), box, i in preview.targets)
		button.disabled = not i in preview.targets
	_button("Annuler", _close_overlay, box)

func _extend_at(index: int) -> void:
	if selected.is_empty():
		_toast("Sélectionnez d’abord une carte de votre main.")
		return
	_act({"type":"extend", "meld":index, "cards":selected.duplicate()})

func _run_bots() -> void:
	busy = true
	var token := turn_token
	while game_mode == "solo" and int(snapshot.get("winner", -1)) < 0 and int(snapshot.get("turn", 0)) != 0:
		await get_tree().create_timer(0.42).timeout
		if token != turn_token or game_mode != "solo":
			return
		engine.bot_step(int(snapshot.get("turn", 0)), difficulty)
		snapshot = engine.view_for(0)
		snapshot["your_index"] = 0
		_render_snapshot()
		_autosave()
	busy = false

func _show_winner() -> void:
	var winner := int(snapshot.get("winner", -1))
	var players: Array = snapshot.get("players", [])
	if winner < 0 or winner >= players.size(): return
	var key := str(snapshot.get("session_id","")) + ":" + str(snapshot.get("match",{}).get("round",1))
	if _winner_key == key and overlay_kind == "winner": return
	_winner_key = key
	var own := int(snapshot.get("your_index", 0))
	var box := _modal("Belle partie !" if winner == own else "La manche est terminée", "Vous avez gagné !" if winner == own else str(players[winner].get("name", "L’adversaire")) + " remporte cette manche.")
	overlay_kind = "winner"
	var celebration := _label("✦  ✦  ✦",40,GOLD,box)
	celebration.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var sparkle := celebration.create_tween().set_loops(3)
	sparkle.tween_property(celebration,"modulate:a",0.35,0.32)
	sparkle.tween_property(celebration,"modulate:a",1.0,0.32)
	var scores: Dictionary = snapshot.get("match",{})
	if not scores.is_empty():
		_label("Manche %d / %d · le plus petit total gagne" % [int(scores.round),int(scores.length)], 17, INK, box)
		var ranking := range(players.size())
		ranking.sort_custom(func(a,b): return int(scores.totals[a]) < int(scores.totals[b]))
		var rank := 1
		for place in range(ranking.size()):
			var index: int = ranking[place]
			if place > 0 and int(scores.totals[index]) != int(scores.totals[ranking[place-1]]): rank = place+1
			_label("%d. %s · %d points" % [rank, players[index].name, int(scores.totals[index])], 19, GOLD if rank == 1 else INK, box)
	for i in range(players.size()):
		_label(str(players[i].get("name", "")) + "  ·  " + str(players[i].get("count",0)) + " cartes restantes", 17, GOLD if i == winner else MUTED, box)
	if game_mode == "solo":
		SoloStore.record_round(engine.state)
		if int(scores.get("round",1)) < int(scores.get("length",1)):
			_button("Manche suivante", _next_round, box, true)
		_button("Nouvelle partie", _start_solo, box, true)
	_button("Retour à l’accueil", _leave_to_menu, box)

func _open_friends() -> void:
	_save_profile()
	_show_friends(false)

func _show_friends(internet: bool) -> void:
	online_tab = internet
	var box := _modal("Une table entre amis", "Chacun joue avec son téléphone et garde sa main privée.")
	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 12)
	box.add_child(tabs)
	_button("Même Wi-Fi", func(): _show_friends(false), tabs, not internet)
	_button("Internet", func(): _show_friends(true), tabs, internet)
	if internet:
		_label("ADRESSE DU SERVEUR", 13, GOLD, box)
		address_input = _field("wss://votre-serveur.fr", saved_address, box)
		var info := _label("Un serveur Internet doit être disponible pour héberger le salon.", 14, MUTED, box)
		info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	else:
		var info := _label("Connectez tous les téléphones au même Wi-Fi.\nL’un crée le salon ; les autres le rejoignent.", 16, MUTED, box)
		info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_button("Créer un salon", _create_room, box, true)
	var sep := HSeparator.new()
	box.add_child(sep)
	if not internet:
		_label("ADRESSE DU TÉLÉPHONE HÔTE", 13, GOLD, box)
		address_input = _field("192.168.1.20:7357", "", box)
	_label("INVITATION D’UN AMI", 13, GOLD, box)
	invitation_input = _field("Collez ici l’invitation rami3d://…", "", box)
	invitation_input.max_length = 2048
	_button("Rejoindre avec l’invitation", _join_invitation, box, true)
	_label("CODE DU SALON", 13, GOLD, box)
	code_input = _field("Code à 6 chiffres", "", box)
	code_input.max_length = 6
	code_input.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_NUMBER
	_button("Rejoindre le salon   →", _join_room, box)
	_button("Retour", _close_overlay, box)

func _create_room() -> void:
	if online_tab:
		var address := address_input.text.strip_edges()
		if address.is_empty():
			_toast("Saisissez l’adresse de votre serveur Internet.")
			return
		saved_address = address
		_save_preferences()
		network.create_remote_room(address, player_name)
		_toast("Connexion au serveur…")
	else:
		network.host_room(player_name)

func _join_room() -> void:
	var address := address_input.text.strip_edges()
	var code := code_input.text.strip_edges()
	if address.is_empty() or code.length() != 6 or not code.is_valid_int():
		_toast("Renseignez l’adresse de l’hôte et le code à 6 chiffres.")
		return
	if online_tab:
		saved_address = address
		_save_preferences()
	network.join_room(address, player_name, code)
	_toast("Connexion au salon…")

func _lobby_updated(data: Dictionary) -> void:
	current_lobby = data
	if game_mode == "online" and not snapshot.is_empty():
		return
	game_mode = "lobby"
	_close_overlay()
	_clear_content()
	header_status.text = "SALON PRIVÉ · " + str(data.get("code", network.room_code))
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _style(Color("0b292d"), Color("456551"), 22, 30))
	_place(panel, content, Vector2(-330,160), Vector2(330,760), Vector2(0.5,0), Vector2(0.5,0))
	lobby_box = VBoxContainer.new()
	lobby_box.add_theme_constant_override("separation", 16)
	panel.add_child(lobby_box)
	_label("Votre salon est prêt", 30, INK, lobby_box)
	_label("PARTAGEZ CE CODE AVEC VOS AMIS", 12, GOLD, lobby_box)
	var code := _label(str(data.get("code", network.room_code)), 52, GOLD, lobby_box)
	code.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	if network.is_host:
		var addr := str(data.get("address", network.local_address))
		if not addr.is_empty():
			var txt := _label("Adresse de l’hôte : " + addr + ":" + str(data.get("port",7357)), 16, MUTED, lobby_box)
			txt.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_button("Copier l’invitation", _copy_invitation, lobby_box)
	var players: Array = data.get("players", [])
	for i in range(players.size()):
		var p: Dictionary = players[i]
		_label(("●  " if p.get("connected",true) else "○  ") + str(p.get("name","Joueur")) + (" · hôte" if i == 0 else ""), 21, INK, lobby_box)
	if players.size() < 4:
		_label("+  En attente d’un ami…", 18, MUTED, lobby_box)
	_label("2 à 4 joueurs · la partie commence quand l’hôte est prêt.", 14, MUTED, lobby_box)
	if network.is_host:
		lobby_start = _button("Commencer la partie   →", func(): network.start_match(), lobby_box, true)
		lobby_start.disabled = players.size() < 2
	else:
		_label("L’hôte lancera la partie.", 18, GOLD, lobby_box)
	_button("Quitter le salon", _leave_to_menu, lobby_box)

func _network_game_updated(data: Dictionary) -> void:
	if overlay_kind == "connection" or game_mode != "online":
		_close_overlay()
	if game_mode != "online":
		game_mode = "online"
		_show_game()
	snapshot = data
	snapshot["your_index"] = network.local_player
	_render_snapshot()

func _connection_changed(connected: bool) -> void:
	if not connected and (game_mode == "lobby" or game_mode == "online"):
		if not snapshot.is_empty():
			snapshot["paused"] = true
			_render_snapshot()
		var box := _modal("Connexion interrompue", "Votre main reste privée. Retrouvez le salon ou revenez à l’accueil.")
		overlay_kind = "connection"
		_button("Se reconnecter", func(): _close_overlay(); network.reconnect(), box, true)
		_button("Retour à l’accueil", _leave_to_menu, box)

func _modal(title: String, subtitle: String) -> VBoxContainer:
	_cancel_drag()
	_close_overlay()
	toast_label.hide()
	toast_time = 0.0
	overlay_kind = "general"
	var dim := ColorRect.new()
	dim.color = Color(0.005, 0.025, 0.03, 0.84)
	_place(dim, overlay, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ONE)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _style(Color("0e2e31"), Color("4a6658"), 22, 28))
	_place(panel, overlay, Vector2(-340,105), Vector2(340,-38), Vector2(0.5,0), Vector2(0.5,1))
	dim.modulate.a = 0.0
	dim.create_tween().tween_property(dim, "modulate:a", 1.0, 0.16)
	panel.modulate.a = 0.0
	panel.create_tween().tween_property(panel, "modulate:a", 1.0, 0.20)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 15)
	scroll.add_child(box)
	_label(title, 30, INK, box)
	var sub := _label(subtitle, 17, MUTED, box)
	sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return box

func _close_overlay() -> void:
	overlay_kind = ""
	if not is_instance_valid(overlay): return
	for node in overlay.get_children():
		node.get_parent().remove_child(node)
		node.queue_free()

func _show_rules() -> void:
	_show_lessons(-1)

func _show_lessons(chapter: int = -1) -> void:
	lesson_index = chapter
	var lessons: Array = coach.lessons()
	var box := _modal("Apprendre le rami", "Un guide pour votre première partie, avec des exemples expliqués.")
	overlay_kind = "lessons"
	var setting := CheckButton.new()
	setting.text = "Mode débutant · conseils pendant la partie"
	setting.button_pressed = beginner_enabled
	setting.custom_minimum_size.y = 48
	setting.toggled.connect(func(value: bool): beginner_enabled = value; _save_preferences())
	box.add_child(setting)
	if chapter < 0:
		var intro := _label("Le but : vider votre main en formant des groupes de cartes. Prenez le temps de découvrir une étape, puis essayez-la en solo.", 18, INK, box)
		intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		for i in range(lessons.size()):
			var idx := i
			var button := _button(str(i+1) + ". " + str(lessons[i].get("title", "")), func(): _show_lessons(idx), box)
			button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		if game_mode in ["solo", "online"]:
			_button("Expliquer mon tour actuel", _show_coach, box, true)
	else:
		var lesson: Dictionary = lessons[clampi(chapter, 0, lessons.size()-1)]
		_label(str(chapter+1) + " / " + str(lessons.size()) + " · " + str(lesson.get("title", "")), 23, GOLD, box).autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_long_text(str(lesson.get("body", "")), box)
		_label("EXEMPLE EXPLIQUÉ", 13, GOLD, box)
		_long_text(str(lesson.get("example", "")), box)
		for tip in lesson.get("tips", []):
			_long_text("• " + str(tip), box)
		if chapter < lessons.size()-1:
			_button("Étape suivante →", func(): _show_lessons(chapter+1), box, true)
		_button("Toutes les étapes", func(): _show_lessons(-1), box)
	_button("C’est compris", _close_overlay, box)

func _long_text(text: String, parent: Node) -> Label:
	var label := _label(text, 19, INK, parent)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_constant_override("line_spacing", 5)
	return label

func _show_coach() -> void:
	var advice: Dictionary = coach.advice(snapshot, selected)
	var box := _modal(str(advice.get("title", "Votre prochain tour")), str(advice.get("body", "")))
	overlay_kind = "coach"
	_label("PAS À PAS", 13, GOLD, box)
	var steps: Array = advice.get("steps", [])
	for i in range(steps.size()):
		_long_text(str(i+1) + ". " + str(steps[i]), box)
	_label("AVEC VOS CARTES", 13, GOLD, box)
	_long_text(str(advice.get("example", "")), box)
	_label("PROCHAINE ACTION", 13, GOLD, box)
	_long_text(str(advice.get("action", "")), box)
	_button("Revenir à ma main", _close_overlay, box, true)
	_button("Ouvrir le guide complet", _show_rules, box)

func _start_sorting() -> void:
	_save_profile()
	turn_token += 1
	busy = false
	game_mode = "sorting"
	network.leave_room()
	_close_overlay()
	snapshot = {}
	_clear_content()
	header_status.text = "DÉFI DE TRI · 3 MANCHES"
	var challenge := SortingChallenge.new()
	_place(challenge, content, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ONE)
	challenge.exit_requested.connect(_leave_to_menu)
	challenge.start_challenge()

func _show_music_settings() -> void:
	var box := _modal("Votre ambiance musicale", "Trois morceaux instrumentaux originaux, joués en boucle pendant vos parties.")
	overlay_kind = "music"
	var toggle := CheckButton.new()
	toggle.text = "Écouter la musique"
	toggle.custom_minimum_size.y = 54
	toggle.button_pressed = music.enabled
	toggle.toggled.connect(func(value: bool): music.set_enabled(value))
	box.add_child(toggle)
	_label("CHOISIR UN MORCEAU", 13, GOLD, box)
	var choice := OptionButton.new()
	choice.custom_minimum_size.y = 54
	for name_text in music.track_names():
		choice.add_item(str(name_text))
	choice.selected = music.track_index
	choice.item_selected.connect(func(index: int): music.set_track(index))
	box.add_child(choice)
	var level := _label("Volume · " + str(roundi(music.volume * 100)) + " %", 20, INK, box)
	var slider := HSlider.new()
	slider.min_value = 0
	slider.max_value = 100
	slider.step = 1
	slider.value = music.volume * 100
	slider.custom_minimum_size.y = 56
	slider.value_changed.connect(func(value: float): music.set_volume(value/100.0); level.text = "Volume · " + str(roundi(value)) + " %")
	box.add_child(slider)
	_label("EFFETS SONORES · INDÉPENDANTS DE LA MUSIQUE", 13, GOLD, box)
	var effects_toggle := CheckButton.new()
	effects_toggle.text = "Sons des cartes et de la victoire"
	effects_toggle.button_pressed = effects_enabled
	effects_toggle.toggled.connect(func(value: bool): effects_enabled = value; effects.enabled = value; _save_preferences())
	box.add_child(effects_toggle)
	_label("Volume des effets",17,INK,box)
	var sound_slider := HSlider.new()
	sound_slider.min_value = 0
	sound_slider.max_value = 100
	sound_slider.value = effects_volume * 100
	sound_slider.custom_minimum_size.y = 50
	sound_slider.value_changed.connect(func(value: float): effects_volume = value / 100; effects.volume = effects_volume; _save_preferences())
	box.add_child(sound_slider)
	_long_text("Votre choix et le volume sont mémorisés. La musique se met en pause quand vous quittez l’application.", box)
	_button("Revenir au jeu", _close_overlay, box, true)

func _music_settings_changed() -> void:
	music_settings = music.get_settings()
	music_button.text = "Musique" if music.enabled else "Musique coupée"
	_save_preferences()

func _toggle_fullscreen() -> void:
	_set_fullscreen(not fullscreen_enabled)

func _set_fullscreen(value: bool, save: bool = true) -> void:
	fullscreen_enabled = value
	if DisplayServer.get_name() != "headless":
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN if value else DisplayServer.WINDOW_MODE_WINDOWED)
	if is_instance_valid(fullscreen_button):
		fullscreen_button.text = "Fenêtre" if value else "Plein écran"
	if save:
		_save_preferences()
	_screen_changed()

func _screen_changed() -> void:
	if is_instance_valid(ui) and OS.has_feature("android"):
		var safe := DisplayServer.get_display_safe_area()
		if safe.size.x > 0 and safe.size.y > 0:
			var inverse := get_viewport().get_final_transform().affine_inverse()
			var start := inverse * Vector2(safe.position)
			var end := inverse * Vector2(safe.end)
			var size := get_viewport().get_visible_rect().size
			ui.offset_left = maxf(0, start.x)
			ui.offset_top = maxf(0, start.y)
			ui.offset_right = minf(0, end.x-size.x)
			ui.offset_bottom = minf(0, end.y-size.y)
	_layout_hand(false)

func _layout_hand(animate: bool = true, deal: bool = false) -> void:
	if hand_cards.is_empty() or not is_instance_valid(camera):
		return
	var size := get_viewport().get_visible_rect().size
	var ratio := size.x / maxf(1, size.y)
	var available := camera.size * ratio * 0.90
	var gap := minf(1.60, (available - 1.05*HAND_SCALE) / maxf(1, hand_cards.size()-1))
	var center_y := -camera.size/2.0 + 1.95 + 1.52*HAND_SCALE/2.0
	for i in range(hand_cards.size()):
		var card = hand_cards[i]
		var norm: float = (i - (hand_cards.size()-1)/2.0) / maxf(1, (hand_cards.size()-1)/2.0)
		var y: float = center_y + 0.28*(1.0-norm*norm)
		card.set_meta("rest_y", y)
		var pos := Vector3((i-(hand_cards.size()-1)/2.0)*gap, y + (0.32 if selected.has(card.card_id) else 0.0), -10.0+i*0.018)
		var basis := (Basis(Vector3.BACK, -norm*0.25) * Basis(Vector3.RIGHT, PI/2.0)).scaled(Vector3.ONE*HAND_SCALE)
		var arriving: bool = card.get_meta("arriving", false)
		card.move_to(Transform3D(basis, pos), (0.42 if arriving else 0.28) if animate else 0.0, i * 0.045 if deal else 0.0, 0.35 if arriving else 0.08)
		card.set_meta("arriving", false)

func _set_hand_selection(card: Node3D, value: bool) -> void:
	card.set_selected(value, false)
	if card.get_meta("hand_card", false):
		var target: Transform3D = card.motion_target
		target.origin.y = float(card.get_meta("rest_y", target.origin.y)) + (0.32 if value else 0.0)
		card.move_to(target, 0.18)

func _confirm_leave() -> void:
	if game_mode == "menu":
		_close_overlay()
		return
	var box := _modal("Quitter cette table ?", "Votre partie solo est sauvegardée automatiquement. Si vous hébergez un salon Wi-Fi, il sera fermé.")
	_button("Rester à la table", _close_overlay, box, true)
	_button("Quitter la partie", _leave_to_menu, box)

func _leave_to_menu() -> void:
	_autosave()
	game_mode = "menu"
	network.leave_room()
	_close_overlay()
	_show_menu()

func _toast(message: String) -> void:
	if not is_instance_valid(toast_label): return
	toast_label.text = message
	toast_label.modulate.a = 1
	toast_label.show()
	toast_time = 4.0

func _load_preferences() -> void:
	var cfg := ConfigFile.new()
	if cfg.load("user://preferences.cfg") == OK:
		saved_name = str(cfg.get_value("player", "name", "Vous"))
		saved_address = str(cfg.get_value("network", "server", ""))
		difficulty = clampi(int(cfg.get_value("solo","difficulty",1)),0,2)
		match_length = int(cfg.get_value("solo","rounds",1))
		if not match_length in [1,3,5]: match_length = 1
		effects_volume = clampf(float(cfg.get_value("effects","volume",0.55)),0,1)
		effects_enabled = bool(cfg.get_value("effects","enabled",true))
		beginner_enabled = bool(cfg.get_value("help", "beginner", true))
		var saved_music: Variant = cfg.get_value("music", "settings", music_settings)
		if saved_music is Dictionary:
			music_settings = saved_music
	player_name = saved_name

func _save_preferences() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("player", "name", saved_name)
	cfg.set_value("network", "server", saved_address)
	cfg.set_value("help", "beginner", beginner_enabled)
	cfg.set_value("music", "settings", music_settings)
	cfg.set_value("solo","difficulty",difficulty)
	cfg.set_value("solo","rounds",match_length)
	cfg.set_value("effects","volume",effects_volume)
	cfg.set_value("effects","enabled",effects_enabled)
	cfg.save("user://preferences.cfg")

func _autosave() -> void:
	if game_mode == "solo" and engine != null and not engine.state.is_empty():
		if not SoloStore.save_game(engine, difficulty, hand_order):
			_toast("La sauvegarde a échoué. Vérifiez l’espace disponible.")

func _resume_solo() -> void:
	var saved: Dictionary = SoloStore.load_game()
	var restored := EngineRules.new()
	if saved.is_empty() or not restored.restore_game(saved.game):
		_toast("Aucune sauvegarde valide à reprendre.")
		return
	turn_token += 1
	busy = false
	network.leave_room()
	_close_overlay()
	engine = restored
	difficulty = clampi(int(saved.get("difficulty",1)),0,2)
	match_length = int(engine.state.match.length)
	bot_count = engine.state.players.size() - 1
	player_name = str(engine.state.players[0].name)
	hand_order = saved.get("order",[]).duplicate() if saved.get("order") is Array else []
	_winner_key = ""
	_sound_revision = ""
	game_mode = "solo"
	_show_game()
	_refresh_snapshot()
	_toast("Votre partie a repris là où vous l’aviez laissée.")

func _show_solo_settings() -> void:
	var box := _modal("Votre partie solo", "Ces réglages s’appliquent à la prochaine partie. Une reprise conserve sa difficulté.")
	_label("DIFFICULTÉ", 13, GOLD, box)
	var choice := OptionButton.new()
	for title in ["Facile · pour apprendre", "Normal · équilibré", "Difficile · anticipe les combinaisons"]:
		choice.add_item(title)
	choice.selected = difficulty
	choice.custom_minimum_size.y = 52
	choice.item_selected.connect(func(index: int): difficulty = index; _save_preferences())
	box.add_child(choice)
	_label("NOMBRE DE MANCHES", 13, GOLD, box)
	var rounds := OptionButton.new()
	for count in [1,3,5]: rounds.add_item(str(count) + " manche(s)",count)
	rounds.selected = [1,3,5].find(match_length)
	rounds.custom_minimum_size.y = 52
	rounds.item_selected.connect(func(index: int): match_length = [1,3,5][index]; _save_preferences())
	box.add_child(rounds)
	var stats: Dictionary = SoloStore.statistics()
	_label("VOS STATISTIQUES SOLO",13,GOLD,box)
	_long_text("%d manches terminées · %d victoires\n%d points de pénalité cumulés" % [stats.rounds,stats.wins,stats.points],box)
	_long_text("À la fin de chaque manche, les cartes restantes comptent : nombres à leur valeur, figures 10, as 11, joker 20. Le total le plus faible gagne le match ; les égalités restent ex æquo.",box)
	_button("Terminé",_close_overlay,box,true)

func _next_round() -> void:
	if game_mode != "solo": return
	var result: Dictionary = engine.next_round()
	if not result.ok:
		_toast(result.error)
		return
	turn_token += 1
	busy = false
	_winner_key = ""
	_sound_revision = ""
	hand_order.clear()
	_close_overlay()
	_show_game()
	_refresh_snapshot()

func _play_snapshot_sound(initial: bool) -> void:
	if effects == null: return
	var key := "%s:%s:%s" % [snapshot.get("session_id",""),snapshot.get("match",{}).get("round",1),snapshot.get("revision",0)]
	if key == _sound_revision: return
	_sound_revision = key
	if int(snapshot.get("winner",-1)) >= 0:
		effects.play("win")
	elif initial:
		effects.play("deal")
	else:
		effects.play(str(snapshot.get("last_action",{}).get("type","")))

func _opponent_position(player: int) -> Vector3:
	var own := int(snapshot.get("your_index",0))
	var opponents: Array = []
	for i in range(snapshot.get("players",[]).size()):
		if i != own: opponents.append(i)
	var index := opponents.find(player)
	return Vector3((index - (opponents.size()-1)/2.0) * 5.0, 0.45, -4.5)

func _render_opponents(initial: bool) -> void:
	var players: Array = snapshot.get("players",[])
	var own := int(snapshot.get("your_index",0))
	for i in range(players.size()):
		if i == own: continue
		var count := clampi(int(players[i].get("count",13)),0,108)
		for j in range(count):
			var card := _view_card("0:S:1",false,self,"opponent:%d:%d" % [i,j],"opponent")
			card._area.input_ray_pickable = false
			card._area.collision_layer = 0
			var pos := _opponent_position(i) + Vector3((j-(count-1)/2.0)*minf(0.12,1.8/maxf(1,count-1)),j*0.003,0)
			var basis := Basis(Vector3.UP,(j-(count-1)/2.0)*minf(0.035,0.45/maxf(1,count-1))).scaled(Vector3.ONE*0.60)
			if card.get_meta("new_in_view",false):
				var last: Dictionary = snapshot.get("last_action",{})
				card.position = Vector3(0.85,0.19,-0.8) if not initial and int(last.get("player",-1)) == i and last.get("source","") == "discard" else DECK_POSITION
			card.move_to(Transform3D(basis,pos),0.35, j*0.025 if initial else 0.0,0.35)

func _copy_invitation() -> void:
	var address: String = network.local_address
	if network._hosting_locally:
		address = "ws://" + address + ":" + str(network.server_port)
	else:
		address = network._client_url
	DisplayServer.clipboard_set(Invitation.make(address,network.room_code))
	_toast("Invitation copiée. Envoyez-la à votre ami ; il la collera dans Rejoindre avec l’invitation.")

func _join_invitation() -> void:
	var invite: Dictionary = Invitation.parse(invitation_input.text)
	if invite.is_empty():
		_toast("Invitation invalide. Collez le texte complet commençant par rami3d://join?.")
		return
	network.join_room(invite.server,player_name,invite.code)

# Hand gestures are captured before 3D picking, but after GUI buttons.
# Only the originating finger can move or release a pending drag.
func _unhandled_input(event: InputEvent) -> void:
	if not game_mode in ["solo","online"] or overlay.get_child_count() > 0: return
	var position_screen := Vector2.ZERO
	var pointer := -2
	if event is InputEventScreenTouch and event.pressed:
		_last_touch_ms = Time.get_ticks_msec()
		position_screen = event.position
		pointer = event.index
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		if event.device == InputEvent.DEVICE_ID_EMULATION or Time.get_ticks_msec()-_last_touch_ms < 180:
			var paired := _pick_card(event.position)
			if paired != null and paired.get_meta("zone", "") == "hand":
				get_viewport().set_input_as_handled()
			return
		position_screen = event.position
		pointer = -1
	else: return
	if is_instance_valid(_drag_card): return
	var card := _pick_card(position_screen)
	if card == null or card.get_meta("zone","") != "hand": return
	_drag_card = card
	_drag_start = position_screen
	_drag_pointer = pointer
	_drag_active = false
	_drag_selection = selected.duplicate()
	_drag_offset = card.global_position - camera.project_position(position_screen, 8.8)
	get_viewport().set_input_as_handled()

func _input(event: InputEvent) -> void:
	if not is_instance_valid(_drag_card): return
	if (event is InputEventScreenTouch or event is InputEventScreenDrag) and event.index != _drag_pointer:
		get_viewport().set_input_as_handled()
		return
	if _drag_pointer >= 0 and (event is InputEventMouseButton or event is InputEventMouseMotion) and event.device == InputEvent.DEVICE_ID_EMULATION:
		get_viewport().set_input_as_handled()
		return
	var position_screen := Vector2.ZERO
	var release := false
	if event is InputEventScreenDrag and event.index == _drag_pointer:
		position_screen = event.position
	elif event is InputEventScreenTouch and event.index == _drag_pointer and not event.pressed:
		if event.canceled:
			_cancel_drag()
			return
		position_screen = event.position
		release = true
	elif event is InputEventMouseMotion and _drag_pointer == -1:
		position_screen = event.position
	elif event is InputEventMouseButton and _drag_pointer == -1 and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		position_screen = event.position
		release = true
	else: return
	get_viewport().set_input_as_handled()
	if overlay.get_child_count() > 0:
		_cancel_drag()
		return
	if not _drag_active and position_screen.distance_to(_drag_start) > 16:
		_drag_active = true
		_drag_card.cancel_motion()
		if not _drag_card.card_id in selected:
			selected = [_drag_card.card_id]
			suggested.clear()
		_drag_card.set_selected(true, false)
		_update_hand_status()
	if release:
		var card := _drag_card
		var dragged := _drag_active
		_drag_card = null
		_drag_pointer = -2
		_drag_active = false
		if dragged: _drop_card(card,position_screen)
		else: card.tapped.emit(card)
	elif _drag_active:
		_drag_card.global_position = camera.project_position(position_screen,8.8) + _drag_offset

func _pick_card(point: Vector2, exclude: Array[RID] = []) -> Node3D:
	var origin := camera.project_ray_origin(point)
	var query := PhysicsRayQueryParameters3D.create(origin,origin+camera.project_ray_normal(point)*100,1,exclude)
	query.collide_with_areas = true
	query.collide_with_bodies = false
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty(): return null
	return hit.collider.get_parent()

func _drop_card(card: Node3D, point: Vector2) -> void:
	var id: String = card.card_id
	if not get_viewport().get_visible_rect().has_point(point):
		selected = _drag_selection.duplicate()
		_layout_hand()
		for item in hand_cards: item.set_selected(item.card_id in selected,false)
		return
	var target := _pick_card(point,[card._area.get_rid()])
	var hand_y := get_viewport().get_visible_rect().size.y * 0.57
	if (target != null and target.get_meta("zone","") == "hand") or point.y >= hand_y:
		hand_order.erase(id)
		var index := hand_order.size()
		for i in range(hand_order.size()):
			var candidate: Node3D = _view_cards.get("card:" + str(hand_order[i]))
			if candidate == null: continue
			var center := camera.unproject_position(hand_root.to_global(candidate.motion_target.origin))
			if point.x < center.x:
				index = i
				break
		hand_order.insert(index,id)
		_render_snapshot()
		_autosave()
		return
	if not _my_turn() or snapshot.get("phase","") != "play":
		_toast("Piochez avant de poser ou de défausser.")
		_layout_hand()
		return
	var discard_center := camera.unproject_position(Vector3(0.85,0.19,-0.8))
	if (target != null and target.get_meta("zone","") == "discard") or point.distance_to(discard_center) < 48:
		selected = [id]
		_discard_selected()
	elif target != null and target.get_meta("zone","") == "meld":
		_extend_at(int(target.get_meta("meld_index",-1)))
	elif point.y > get_viewport().get_visible_rect().size.y*0.24:
		_meld_selected()
	else:
		selected = _drag_selection.duplicate()
	_layout_hand()
	for item in hand_cards: item.set_selected(item.card_id in selected,false)
	_update_hand_status()

func _cancel_drag(restore: bool = true) -> void:
	var active := is_instance_valid(_drag_card)
	_drag_card = null
	_drag_pointer = -2
	_drag_active = false
	if active and restore:
		selected = _drag_selection.duplicate()
		_layout_hand()
		for item in hand_cards: item.set_selected(item.card_id in selected,false)
