extends Node3D

const CardText = preload("res://scripts/card_labels.gd")
const EngineRules = preload("res://scripts/rami_engine.gd")
const TableSalon = preload("res://scripts/table_scene.gd")
const CardView = preload("res://scripts/card_3d.gd")
const NetworkRoom = preload("res://scripts/network_manager.gd")
const VoiceChat = preload("res://scripts/voice_chat.gd")
const MusicPlayer = preload("res://scripts/music_manager.gd")
const Coach = preload("res://scripts/beginner_coach.gd")
const SortingChallenge = preload("res://scripts/sorting_challenge.gd")
const TriPractice = preload("res://scripts/tri_tutorial.gd")
const HandGroups = preload("res://scripts/hand_groups.gd")
const ServerProfile = preload("res://scripts/server_profile.gd")
const Practice = preload("res://scripts/tutorial_practice.gd")
const SoloStore = preload("res://scripts/solo_store.gd")
const SoundEffects = preload("res://scripts/sound_effects.gd")
const Invitation = preload("res://scripts/invitation.gd")
const Profile = preload("res://scripts/player_profile.gd")
const HAND_SCALE := 2.15
const DECK_POSITION := Vector3(-0.8, 0.28, -0.8)
const INK = Color("f2eee4")
const MUTED = Color("b2bbb1")
const GOLD = Color("d1b581")
const TEAL = Color("303b33")
const DEEP = Color("1d2520")

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
var player_province := ""
var tri_grouping_enabled := false
var economy_mode := false
var _tri_boundaries: Array = []
var _group_button: Button
var _key_light: DirectionalLight3D
var _heading_font: FontVariation
var tri_choice := 6
var friends_tri_cards := 0
var friends_player_count := 2
var friends_rounds := 1
var friends_local := false
var tournament_name_input: LineEdit
var province_input: OptionButton
var room_count_select: OptionButton
var voice: Node
var voice_panel: PanelContainer
var mic_button: Button
var listen_button: Button
var speakers_button: Button
var voice_label: Label
var rematch_button: Button
var rematch_status: Label
var bot_count := 1
var table_scene: Node3D
var camera: Camera3D
var ui: Control
var content: Control
var overlay: Control
var toast_label: Label
var toast_time := 0.0
var header_status: Label
var _header: PanelContainer
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
var animations_enabled := true
var hand_scale_factor := 1.0
var left_handed := false
var play_buttons: Array = []
var action_buttons_base: Array = []

func _ready() -> void:
	get_viewport().physics_object_picking = true
	Input.emulate_touch_from_mouse = false
	var restored := Profile.finish_restore()
	_load_preferences()
	_make_world()
	_make_interface()
	_apply_performance()
	effects = SoundEffects.new()
	effects.volume = effects_volume
	effects.enabled = effects_enabled
	add_child(effects)
	music = MusicPlayer.new()
	music.apply_settings(music_settings)
	add_child(music)
	music.settings_changed.connect(_music_settings_changed)
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
	network.room_closed.connect(_room_closed)
	voice = VoiceChat.new()
	add_child(voice)
	voice.setup(network)
	voice.changed.connect(_update_voice_controls)
	voice.notice.connect(_toast)
	_make_voice_controls()
	_show_menu()
	# Reproducible visual checks can start an offline table without network access.
	if "--demo" in OS.get_cmdline_user_args():
		_start_solo()
	elif player_province.is_empty():
		_show_profile(true)
	if not restored: _toast("Restauration en attente. Libérez de l’espace puis relancez le jeu.")

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
		if voice != null: voice.stop_talk()
	if what == NOTIFICATION_APPLICATION_PAUSED: Engine.max_fps = 5
	if what == NOTIFICATION_APPLICATION_RESUMED: _apply_performance()
	if what == NOTIFICATION_APPLICATION_RESUMED and OS.has_feature("android") and fullscreen_enabled:
		_set_fullscreen(true, false)
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		if overlay_kind == "profile_setup": return
		if overlay_kind == "room_setup":
			_cancel_room_setup()
			return
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
	env.background_color = Color("1c201b")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("c8cfdb")
	env.ambient_light_energy = 0.30
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
	_key_light = key
	key.rotation_degrees = Vector3(-62, -22, 0)
	key.light_color = Color("fff1d8")
	key.light_energy = 0.68
	key.shadow_enabled = true
	key.shadow_bias = .10
	key.shadow_normal_bias = 1.5
	key.directional_shadow_max_distance = 32
	key.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	add_child(key)
	var light := OmniLight3D.new()
	light.position = Vector3(0, 7, -3)
	light.light_color = Color("b8c9dd")
	light.light_energy = 0.16
	light.omni_range = 18
	add_child(light)
	table_scene = TableSalon.new()
	add_child(table_scene)

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
	theme.default_font_size = 18
	_heading_font = FontVariation.new()
	_heading_font.base_font = text_font
	_heading_font.variation_embolden = 0.5
	theme.set_color("font_color", "Label", INK)
	theme.set_color("font_color", "Button", INK)
	theme.set_color("font_hover_color", "Button", GOLD)
	theme.set_color("font_disabled_color", "Button", Color("627c78"))
	theme.set_stylebox("normal", "Button", _style(Color("29372f"), Color("526052"), 12, 18))
	theme.set_stylebox("hover", "Button", _style(Color("3c4e40"), GOLD, 12, 18))
	theme.set_stylebox("pressed", "Button", _style(Color("4e6050"), GOLD, 12, 18))
	theme.set_stylebox("disabled", "Button", _style(Color("232c25"), Color("3c483f"), 12, 18))
	theme.set_stylebox("normal", "LineEdit", _style(Color("18231d"), Color("526253"), 10, 16))
	theme.set_stylebox("focus", "LineEdit", _style(Color("283b2e"), GOLD, 10, 16))
	theme.set_color("font_color", "LineEdit", INK)
	theme.set_color("font_placeholder_color", "LineEdit", MUTED)
	theme.set_stylebox("panel", "PopupMenu", _style(DEEP, Color("526253"), 8, 10))
	ui.theme = theme
	_header = PanelContainer.new()
	var header_style := _style(Color(0.07,0.10,0.08,0.94), Color("3d473d"), 0, 0)
	header_style.content_margin_left = 30
	header_style.content_margin_right = 30
	header_style.content_margin_top = 10
	header_style.content_margin_bottom = 10
	_header.add_theme_stylebox_override("panel", header_style)
	_place(_header, ui, Vector2.ZERO, Vector2(0,72), Vector2.ZERO, Vector2(1,0))
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 10)
	_header.add_child(header)
	var logo := TextureRect.new()
	logo.texture = load("res://assets/icon.svg")
	logo.custom_minimum_size = Vector2(40, 40)
	logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	header.add_child(logo)
	var wordmark := _label("Rami", 27, INK, header)
	wordmark.add_theme_font_override("font", load("res://assets/serif.ttf"))
	wordmark.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)
	header_status = _label("", 14, MUTED, header)
	header_status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_command_button("Règles", _show_rules, header).custom_minimum_size.y = 44
	_command_button("Options", _show_options, header).custom_minimum_size.y = 44
	_command_button("Accueil", _confirm_leave, header).custom_minimum_size.y = 44
	content = Control.new()
	_place(content, ui, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ONE)
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay = Control.new()
	_place(overlay, ui, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ONE)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	toast_label = _label("", 16, INK, ui)
	_place(toast_label, ui, Vector2(-550,-36), Vector2(550,-6), Vector2(0.5,1), Vector2(0.5,1))
	toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	toast_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	toast_label.add_theme_stylebox_override("normal", _style(Color("202a23"), Color("766646"), 5, 5))
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
	label.add_theme_constant_override("line_spacing", 3)
	if size >= 24 and _heading_font != null: label.add_theme_font_override("font", _heading_font)
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

func _command_button(text: String, callback: Callable, parent: Node, primary: bool = false) -> Button:
	var button := _button(text, callback, parent, primary)
	button.add_theme_font_size_override("font_size", 17)
	var colors := {
		"normal": [Color("d2b980"), Color("edd6a3")] if primary else [Color("24312a"), Color("626a53")],
		"hover": [Color("ecd099"), Color("ffe5b2")] if primary else [Color("374638"), GOLD],
		"pressed": [Color("b89a5d"), Color("9b804c")] if primary else [Color("18251e"), GOLD],
		"disabled": [Color("1b241f"), Color("343e34")],
	}
	for state in colors:
		var style := _style(colors[state][0], colors[state][1], 6, 15)
		style.content_margin_top = 6
		style.content_margin_bottom = 6
		if state in ["normal", "hover"]:
			style.shadow_color = Color(0,0,0,0.34)
			style.shadow_size = 3
			style.shadow_offset = Vector2(0,3)
		button.add_theme_stylebox_override(state, style)
	button.add_theme_stylebox_override("focus", _style(Color.TRANSPARENT, GOLD, 6, 0))
	button.add_theme_color_override("font_disabled_color", Color("829084"))
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
	_header.visible = game_mode != "menu"
	camera.h_offset = -2.0 if game_mode == "menu" else 0.0
	for node in content.get_children():
		node.get_parent().remove_child(node)
		node.queue_free()
	selected.clear()
	suggested.clear()
	_clear_cards()

func _clear_cards() -> void:
	if is_instance_valid(table_scene): table_scene.clear_seats()
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
	header_status.text = "%s · %s" % [saved_name, player_province] if not player_province.is_empty() else ""
	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array([0.0, 0.30, 0.53, 0.79, 1.0])
	gradient.colors = PackedColorArray([Color("101813"), Color(0.06,0.095,0.075,0.98), Color(0.06,0.095,0.075,0.65), Color(0.05,0.07,0.05,0.08), Color(0.05,0.07,0.05,0.13)])
	var wash := GradientTexture2D.new()
	wash.gradient = gradient
	wash.width = 512
	wash.height = 2
	var backdrop := TextureRect.new()
	backdrop.texture = wash
	backdrop.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_place(backdrop, content, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ONE)
	if not player_province.is_empty():
		var profile_button := _command_button("%s · %s" % [saved_name, player_province], _show_profile, content)
		_place(profile_button, content, Vector2(-400,70), Vector2(-68,120), Vector2(1,0), Vector2(1,0))

	var brand := VBoxContainer.new()
	brand.add_theme_constant_override("separation", -8)
	_place(brand, content, Vector2(70,74), Vector2(500,254))
	var title := _label("Rami", 110, Color("f1e5c6"), brand)
	title.add_theme_font_override("font", load("res://assets/serif.ttf"))
	_label("Salon 3D", 24, GOLD, brand)
	var rule := ColorRect.new()
	rule.color = Color("967a48")
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_place(rule, content, Vector2(72,268), Vector2(156,270))

	var choices := VBoxContainer.new()
	choices.add_theme_constant_override("separation", 11)
	_place(choices, content, Vector2(72,304), Vector2(442,680))
	var solo := _command_button("Jouer au rami", _start_solo, choices, true)
	solo.alignment = HORIZONTAL_ALIGNMENT_LEFT
	solo.custom_minimum_size.y = 64
	solo.add_theme_font_size_override("font_size", 22)
	var friends := _command_button("Jouer avec des amis", _open_friends, choices)
	friends.alignment = HORIZONTAL_ALIGNMENT_LEFT
	friends.custom_minimum_size.y = 60
	friends.add_theme_font_size_override("font_size", 20)
	var tri := _command_button("Jouer au Tri", _show_tri_setup, choices)
	tri.alignment = HORIZONTAL_ALIGNMENT_LEFT
	tri.custom_minimum_size.y = 60
	tri.add_theme_font_size_override("font_size", 20)
	_command_button("Tournois", _show_tournaments, choices).alignment = HORIZONTAL_ALIGNMENT_LEFT
	if not SoloStore.load_game().is_empty():
		_command_button("Reprendre ma partie solo", _resume_solo, choices).alignment = HORIZONTAL_ALIGNMENT_LEFT
	if network.has_saved_session():
		_command_button("Retrouver mon salon", _resume_network, choices).alignment = HORIZONTAL_ALIGNMENT_LEFT

	var practice := HBoxContainer.new()
	practice.add_theme_constant_override("separation", 10)
	_place(practice, content, Vector2(72,-158), Vector2(442,-106), Vector2(0,1), Vector2(0,1))
	_command_button("Apprendre à jouer", _start_tutorial, practice).size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_command_button("Rangement", _start_sorting, practice).size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var footer := HBoxContainer.new()
	footer.add_theme_constant_override("separation", 8)
	_place(footer, content, Vector2(72,-89), Vector2(442,-41), Vector2(0,1), Vector2(0,1))
	_command_button("Options", _show_options, footer).custom_minimum_size.y = 46
	_command_button("Règles du jeu", _show_rules, footer).custom_minimum_size.y = 46
	_command_button("Crédits", _show_credits, footer).custom_minimum_size.y = 46

	for i in range(4):
		var back = _card("0:S:1", false, Vector3(3.8+i*0.024,0.16+i*0.035,-1.65))
		back.rotation_degrees.y = -14.0
		back.scale = Vector3.ONE * 1.72
		back.move_to(back.transform, 0.0)
	var menu_ids := ["0:C:11", "0:D:12", "0:S:13", "0:H:1", "0:S:1"]
	for i in range(menu_ids.size()):
		var card = _card(menu_ids[i], true, Vector3(1.25+i*0.79,0.26+i*0.048,1.3+absf(i-2)*0.15))
		card.rotation_degrees.y = (2-i)*10.0
		card.scale = Vector3.ONE * 2.50
		var target: Transform3D = card.transform
		if animations_enabled:
			card.position += Vector3(0.2,0.4,-0.6)
		card.move_to(target, 0.42 if animations_enabled else 0.0, i*0.045, 0.12)

func _show_options() -> void:
	var box := _modal("Options", "")
	if game_mode == "menu":
		_button("Profil du joueur", _show_profile, box)
		_button("Sauvegarder ou restaurer", _show_backup, box)
	if game_mode in ["menu", "solo"]:
		_button("Options du solo", _show_solo_settings, box)
	if game_mode == "online" and current_lobby.get("tournament") is Dictionary:
		_button("Tableau du tournoi", _show_bracket, box)
	_button("Affichage et confort", _show_comfort_settings, box)
	music_button = _button("Musique" if music.enabled else "Musique coupée", _show_music_settings, box)
	fullscreen_button = _button("Fenêtre" if fullscreen_enabled else "Plein écran", _toggle_fullscreen, box)
	_button("Fermer", _close_overlay, box, true)

func _show_profile(first_launch: bool = false) -> void:
	var box := _modal("Votre profil", "Choisissez un pseudo et votre province.")
	if first_launch: overlay_kind = "profile_setup"
	_label("Pseudo", 16, MUTED, box)
	name_input = _field("Votre pseudo", saved_name if saved_name != "Vous" or not first_launch else "", box)
	name_input.max_length = 20
	_label("Province", 16, MUTED, box)
	province_input = OptionButton.new()
	province_input.custom_minimum_size.y = 54
	province_input.add_item("Choisir une province")
	province_input.set_item_disabled(0, true)
	for province in Profile.PROVINCES: province_input.add_item(province)
	province_input.select(Profile.PROVINCES.find(player_province) + 1)
	box.add_child(province_input)
	_button("Enregistrer le profil", _save_profile, box, true)
	if first_launch: _button("Restaurer ma sauvegarde", _show_backup.bind(true), box)
	else: _button("Retour", _show_options, box)

func _save_profile() -> void:
	var name_text := Profile.clean_name(name_input.text)
	if name_text.is_empty() or province_input.selected < 1:
		_toast("Indiquez un pseudo et choisissez une province.")
		return
	var previous := [saved_name, player_province]
	saved_name = name_text
	player_province = Profile.PROVINCES[province_input.selected - 1]
	if not _save_preferences():
		saved_name = previous[0]
		player_province = previous[1]
		_toast("Le profil n’a pas pu être enregistré.")
		return
	player_name = saved_name
	_close_overlay()
	_show_menu()

func _show_backup(first_launch: bool = false) -> void:
	var box := _modal("Sauvegarde", "Votre profil, votre partie solo et vos statistiques.")
	if first_launch: overlay_kind = "profile_setup"
	if not player_province.is_empty():
		_button("Copier ma sauvegarde", func():
			var text := Profile.backup_text(saved_name, player_province)
			if text.length() <= Profile.BACKUP_LIMIT:
				DisplayServer.clipboard_set(text)
				_toast("Sauvegarde copiée. Collez-la dans un fichier que vous garderez.")
			else: _toast("La sauvegarde est trop volumineuse pour être copiée."), box)
	_long_text("La restauration remplace les données de jeu de cet appareil.", box)
	var backup := TextEdit.new()
	backup.custom_minimum_size.y = 120
	backup.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	backup.placeholder_text = "Collez ici le texte de votre sauvegarde"
	box.add_child(backup)
	_button("Coller", func(): backup.text = DisplayServer.clipboard_get().left(Profile.BACKUP_LIMIT + 1), box)
	_button("Restaurer cette sauvegarde", func(): _restore_backup(backup.text), box, true)
	_button("Retour", _show_profile.bind(true) if first_launch else _show_options, box)

func _restore_backup(text: String) -> void:
	var data := Profile.parse_backup(text)
	if data.is_empty():
		_toast("Sauvegarde invalide. Collez le texte complet exporté par Rami.")
		return
	if not SoloStore.write_data(Profile.RESTORE, data) or not Profile.finish_restore():
		_toast("Restauration en attente. Libérez de l’espace puis relancez le jeu.")
		return
	_load_preferences()
	_close_overlay()
	_show_menu()
	_toast("Votre sauvegarde a été restaurée.")

func _start_solo(tri_size: int = 0) -> void:
	turn_token += 1
	busy = false
	player_name = saved_name
	network.leave_room()
	_close_overlay()
	engine = EngineRules.new()
	hand_order.clear()
	_winner_key = ""
	_sound_revision = ""
	if tri_size in [6,12]:
		engine.start_tri_game([player_name, "Camille"], tri_size)
	else:
		var names := [player_name] + ["Camille", "Alex", "Charlie"].slice(0, bot_count)
		engine.start_game(names, 0, match_length)
	game_mode = "solo"
	_show_game()
	_refresh_snapshot()

func _show_game() -> void:
	_clear_content()
	header_status.text = "Solo · " + ["facile","normal","difficile"][difficulty] if game_mode == "solo" else "Salon · " + network.room_code
	players_row = HBoxContainer.new()
	players_row.alignment = BoxContainer.ALIGNMENT_CENTER
	players_row.add_theme_constant_override("separation", 10)
	_place(players_row, content, Vector2(0,87), Vector2(0,138), Vector2(0,0), Vector2(1,0))

	var table_status := PanelContainer.new()
	table_status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	table_status.add_theme_stylebox_override("panel", _style(Color(0.08,0.13,0.10,0.92), Color("5b644d"), 6, 10))
	_place(table_status, content, Vector2(30,365), Vector2(380,461))
	var status_box := VBoxContainer.new()
	status_box.add_theme_constant_override("separation", 4)
	table_status.add_child(status_box)
	game_status = _label("", 18, INK, status_box)
	game_status.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	hand_status = _label("", 13, GOLD, status_box)
	hand_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

	var draw_row := HBoxContainer.new()
	draw_row.alignment = BoxContainer.ALIGNMENT_CENTER
	draw_row.add_theme_constant_override("separation", 8)
	_place(draw_row, content, Vector2(-215,410), Vector2(215,460), Vector2(0.5,0), Vector2(0.5,0))
	draw_buttons = []
	draw_buttons.append(_command_button("Piocher", func(): _act({"type":"draw", "source":"deck"}), draw_row, true))
	draw_buttons.append(_command_button("Prendre la défausse", func(): _act({"type":"draw", "source":"discard"}), draw_row))
	for button in draw_buttons:
		button.custom_minimum_size = Vector2(172,50)
	coach_button = _command_button("Conseils", _show_coach, content)
	coach_button.custom_minimum_size.y = 50
	_place(coach_button, content, Vector2(-160,410), Vector2(-30,460), Vector2(1,0), Vector2(1,0))

	var tray := PanelContainer.new()
	tray.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var tray_style := _style(Color(0.07,0.105,0.08,0.97), Color("635740"), 9, 8)
	tray_style.shadow_color = Color(0,0,0,0.42)
	tray_style.shadow_size = 6
	tray_style.shadow_offset = Vector2(0,4)
	tray.add_theme_stylebox_override("panel", tray_style)
	var tray_half_width := 375 if _is_tri() else 430
	_place(tray, content, Vector2(-tray_half_width,-106), Vector2(tray_half_width,-37), Vector2(0.5,1), Vector2(0.5,1))
	action_row = HBoxContainer.new()
	action_row.add_theme_constant_override("separation", 8)
	tray.add_child(action_row)
	_command_button("Trier", _sort_hand, action_row)
	play_buttons = []
	_group_button = null
	if _is_tri():
		_command_button("Mes tris", _suggest, action_row)
		_group_button = _command_button("Regrouper mes tris", _toggle_tri_groups, action_row)
		_group_button.toggle_mode = true
	else:
		play_buttons.append(_command_button("Suggestion", _suggest, action_row))
		play_buttons.append(_command_button("Compléter", _extend_selected, action_row))
		play_buttons.append(_command_button("Poser", _meld_selected, action_row))
	play_buttons.append(_command_button("Défausser", _discard_selected, action_row, true))
	action_buttons_base = action_row.get_children()
	for button in action_buttons_base:
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_apply_comfort()

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
		header_status.text = "Solo · %s · manche %d/%d" % [["facile","normal","difficile"][difficulty],int(snapshot.get("match",{}).get("round",1)),int(snapshot.get("match",{}).get("length",1))]
	for i in range(players.size()):
		var panel := PanelContainer.new()
		panel.custom_minimum_size = Vector2(184, 50)
		panel.add_theme_stylebox_override("panel", _style(Color("26382d") if i == turn else Color("1b261f"), GOLD if i == turn else Color("465346"), 6, 5))
		players_row.add_child(panel)
		var column := VBoxContainer.new()
		column.add_theme_constant_override("separation", 0)
		panel.add_child(column)
		var p: Dictionary = players[i]
		var name_text := "Vous" if i == own else str(p.get("name", "Joueur"))
		panel.tooltip_text = _profile_label(p)
		var name_label := _label(name_text, 15, GOLD if i == turn else INK, column)
		name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		var count := int(p.get("count", p.get("hand_count", 13)))
		var detail := "Forfait" if p.get("forfeited", false) else "%d cartes" % count
		if p.get("opened", false) and not p.get("forfeited", false): detail += " · ouvert"
		if not str(p.get("province", "")).is_empty(): detail += " · " + str(p.province)
		var detail_label := _label(detail, 12, MUTED, column)
		detail_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		detail_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	if _is_tri(): header_status.text = "Tri · %d cartes · %d tris à former" % [int(snapshot.tri_hand_size),int(snapshot.tri_goal)]
	if game_mode == "online":
		var scores: Dictionary = snapshot.get("match", {})
		var tournament: Variant = current_lobby.get("tournament")
		if tournament is Dictionary and int(tournament.stage) in [0,1,2]:
			header_status.text = ["Demi-finale 1", "Demi-finale 2", "Finale"][int(tournament.stage)]
		elif not _is_tri(): header_status.text = "Salon · " + network.room_code
		if int(scores.get("length", 1)) > 1: header_status.text += " · Manche %d/%d" % [int(scores.round),int(scores.length)]
	_update_turn_controls()
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
	_tri_boundaries.clear()
	if _is_tri() and tri_grouping_enabled:
		var grouped: Dictionary = HandGroups.arrange(hand,true)
		hand = grouped.cards
		_tri_boundaries = grouped.boundaries
	if is_instance_valid(_group_button):
		_group_button.set_pressed_no_signal(tri_grouping_enabled)
		_group_button.text = "Tris regroupés" if tri_grouping_enabled else "Regrouper mes tris"
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
			var position_card := Vector3(-5.3 + col * 3.5 + (j - (cards.size()-1)/2.0) * gap, 0.12 + j * 0.005, -1.9)
			var card = _view_card(str(cards[j]), true, self, "card:" + str(cards[j]), "meld")
			card.set_meta("meld_index", i)
			_place_table_card(card, Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * 0.70), position_card), initial_deal, j * 0.035)
	_render_opponents(initial_deal)
	_play_snapshot_sound(initial_deal)
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

func _update_turn_controls() -> void:
	if not is_instance_valid(game_status) or snapshot.is_empty(): return
	var own := int(snapshot.get("your_index", 0))
	var turn := int(snapshot.get("turn", 0))
	var players: Array = snapshot.get("players", [])
	var phase := str(snapshot.get("phase", "draw"))
	var paused: bool = bool(snapshot.get("paused", false)) or (game_mode == "online" and network.quick_reconnect)
	var won := int(snapshot.get("winner", -1)) >= 0
	var abandoned := own >= 0 and own < players.size() and bool(players[own].get("forfeited", false))
	var can_act := own >= 0 and own < players.size() and turn == own and not paused and not won and not abandoned
	for button in draw_buttons:
		button.disabled = not can_act or phase != "draw"
	if not draw_buttons.is_empty():
		draw_buttons[0].text = "Piocher · " + str(snapshot.get("deck_count", 0))
		var discard: Variant = snapshot.get("discard_top", "")
		draw_buttons[1].disabled = draw_buttons[1].disabled or discard == null or discard == ""
	for button in play_buttons:
		if is_instance_valid(button): button.disabled = not can_act or phase != "play"
	if won: game_status.text = str(_winner_result().title)
	elif abandoned: game_status.text = "Vous avez abandonné cette partie."
	elif paused: game_status.text = "Reconnexion au salon…"
	elif turn == own:
		game_status.text = "À vous de piocher" if phase == "draw" else ("À vous de défausser" if _is_tri() else "À vous de jouer")
		if beginner_enabled and not _is_tri():
			game_status.text = "1. Piochez une carte" if phase == "draw" else "2. Posez ou défaussez"
	else: game_status.text = str(players[turn].get("name", "L’adversaire")) + " joue…" if turn >= 0 and turn < players.size() else "En attente…"

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
	card.set_meta("reduced_motion", not animations_enabled)
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
	card.set_meta("reduced_motion", not animations_enabled)
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
		if not _is_tri() and own < players.size() and not players[own].get("opened", false):
			var preview: Dictionary = EngineRules.new().selection_preview(snapshot, selected, suggested)
			opening = "\nOuverture : %d/30 points" % int(preview.points)
		if _is_tri(): opening = "\nVos tris : %d / %d" % [EngineRules.new().tri_groups(snapshot.get("hand",[])).size(),int(snapshot.get("tri_goal",0))]
		hand_status.text = "Votre main · " + str(snapshot.get("hand", []).size()) + " cartes"
		if not selected.is_empty():
			hand_status.text += " · %d sélectionnée%s" % [selected.size(), "s" if selected.size()>1 else ""]
		hand_status.text += opening

	var preview: Dictionary = EngineRules.new().selection_preview(snapshot, selected, suggested)
	for card in card_nodes:
		if card.get_meta("zone","") == "meld":
			card.set_selected(int(card.get_meta("meld_index",-1)) in preview.targets, false)

func _my_turn(show_error: bool = true) -> bool:
	if snapshot.is_empty() or int(snapshot.get("winner", -1)) >= 0:
		return false
	var own := int(snapshot.get("your_index",0))
	var players: Array = snapshot.get("players",[])
	if own < players.size() and players[own].get("forfeited",false):
		if show_error: _toast("Vous avez abandonné et ne pouvez plus jouer dans ce match.")
		return false
	if snapshot.get("paused", false) or (game_mode == "online" and network.quick_reconnect):
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
	tri_grouping_enabled = false
	if effects != null: effects.play_slide()
	sort_suit = not sort_suit
	hand_order.clear()
	_render_snapshot()
	_autosave()
	_save_preferences()
	_toast("Cartes triées par " + ("couleur." if sort_suit else "valeur."))

func _suggest() -> void:
	if _is_tri():
		selected.clear()
		for group in EngineRules.new().tri_groups(snapshot.get("hand",[])):
			selected.append_array(group)
		for card in hand_cards: _set_hand_selection(card,selected.has(card.card_id))
		_update_hand_status()
		_toast("Vos tris restent privés. Choisissez ensuite une seule carte à défausser.")
		return
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
			names.append(CardText.short_label(str(id)))
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

func _winner_result() -> Dictionary:
	var players: Array = snapshot.get("players",[])
	var own := int(snapshot.get("your_index",0))
	var round_winner := int(snapshot.get("winner",-1))
	var scores: Dictionary = snapshot.get("match",{})
	var forfeit: bool = bool(snapshot.get("win_by_forfeit",false))
	var finished: bool = forfeit or (round_winner >= 0 and int(scores.get("round",1)) >= int(scores.get("length",1)))
	var winners: Array = []
	var authoritative: Dictionary = snapshot.get("match_result",{})
	if not authoritative.is_empty():
		finished = bool(authoritative.get("finished",finished))
		forfeit = bool(authoritative.get("forfeit",forfeit))
		if authoritative.get("winners") is Array:
			for index in authoritative.winners:
				if index is int or index is float: winners.append(int(index))
	if finished and winners.is_empty():
		if forfeit:
			for index in snapshot.get("forfeit_winners",[round_winner]):
				if index is int or index is float: winners.append(int(index))
		else:
			var best := 2147483647
			var totals: Array = scores.get("totals",[])
			for i in range(players.size()):
				if players[i].get("forfeited",false): continue
				var total: int = int(totals[i]) if i < totals.size() else (0 if i == round_winner else 1)
				if total < best:
					best = total
					winners = [i]
				elif total == best: winners.append(i)
	var names: Array[String] = []
	for index in winners:
		if int(index) >= 0 and int(index) < players.size(): names.append(str(players[int(index)].get("name","Joueur")))
	var title := "Manche remportée" if round_winner == own else "Manche terminée"
	var body := "Vous remportez cette manche. Le classement du match dépend du total de toutes les manches." if round_winner == own else (str(players[round_winner].get("name","L’adversaire")) + " remporte cette manche." if round_winner >= 0 and round_winner < players.size() else "La manche est terminée.")
	if finished:
		if forfeit:
			title = "Victoire par forfait" if own in winners else "Défaite par abandon"
			if own in winners:
				body = "Vous gagnez : votre adversaire a abandonné." if winners.size()==1 else "Victoire par abandon pour " + ", ".join(names) + "."
			else:
				body = "Vous avez abandonné. " + ", ".join(names) + (" remporte le match." if names.size()==1 else " remportent le match.")
		elif winners.size() > 1:
			title = "Match terminé · ex æquo"
			body = ", ".join(names) + " partagent la victoire avec le même total de points."
		else:
			title = "Match remporté !" if own in winners else "Match terminé"
			body = "Vous gagnez le match au total des points." if own in winners else ", ".join(names) + " gagne le match au total des points."
	if authoritative.get("tie_break",false):
		body = "Vous gagnez le duel au nombre de manches remportées." if own in winners else ", ".join(names) + " gagne le duel au nombre de manches remportées."
	if _is_tri() and finished and not forfeit and int(scores.get("length",1)) == 1:
		title = "Tri : victoire !" if own in winners else "Tri : partie terminée"
		body = ("Vous remportez la partie" if own in winners else ", ".join(names) + " remporte la partie") + " avec %d tris, après la défausse." % int(snapshot.get("tri_goal",2))
	return {"title":title,"body":body,"winners":winners,"finished":finished,"forfeit":forfeit,"round_winner":round_winner}

func _show_winner() -> void:
	var winner := int(snapshot.get("winner",-1))
	var players: Array = snapshot.get("players",[])
	if winner < 0 or winner >= players.size(): return
	var key := str(snapshot.get("session_id","")) + ":" + str(snapshot.get("match",{}).get("round",1)) + ":" + str(snapshot.get("win_by_forfeit",false))
	if _winner_key == key and overlay_kind == "winner": return
	_winner_key = key
	var result := _winner_result()
	var box := _modal(result.title,result.body)
	overlay_kind = "winner"
	if int(snapshot.get("your_index",0)) in (result.winners if result.finished else [winner]):
		var celebration := _label("✦  ✦  ✦",40,GOLD,box)
		celebration.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		if animations_enabled:
			var sparkle := celebration.create_tween().set_loops(3)
			_UI_sparkles.append(sparkle)
			sparkle.tween_property(celebration,"modulate:a",0.35,0.32)
			sparkle.tween_property(celebration,"modulate:a",1.0,0.32)
	var scores: Dictionary = snapshot.get("match",{})
	if _is_tri() and not result.forfeit:
		for group in snapshot.get("winning_tris",[]):
			var labels: Array[String] = []
			for id in group:
				labels.append(CardText.short_label(str(id)))
			_long_text("  ·  ".join(labels),box)
	if not scores.is_empty() and (not _is_tri() or int(scores.get("length",1)) > 1):
		_label("Manche %d / %d · le plus petit total gagne" % [int(scores.get("round",1)),int(scores.get("length",1))],17,INK,box)
		var ranking: Array = []
		for index in range(players.size()):
			if not players[index].get("forfeited",false): ranking.append(index)
		ranking.sort_custom(func(a,b): return int(scores.totals[a]) < int(scores.totals[b]))
		var rank := 1
		for place in range(ranking.size()):
			var index: int = ranking[place]
			if place > 0 and int(scores.totals[index]) != int(scores.totals[ranking[place-1]]): rank = place+1
			_label("%d. %s · %d points" % [rank,players[index].name,int(scores.totals[index])],19,GOLD if index in result.winners else INK,box)
		for player in players:
			if player.get("forfeited",false):
				_label(str(player.name) + " · éliminé par abandon",18,MUTED,box)
	if game_mode == "solo":
		SoloStore.record_round(engine.state)
		if not result.finished: _button("Manche suivante",_next_round,box,true)
		if result.finished:
			_label("Une autre partie ?",22,INK,box)
			_button("Rejouer",func(): _start_solo(int(snapshot.get("tri_hand_size",0))),box,true)
	elif game_mode == "online":
		if not result.finished:
			if network.is_host: _button("Manche suivante", network.next_match_round, box, true)
			else: _label("L’hôte lancera la manche suivante.", 17, MUTED, box)
		elif current_lobby.get("tournament") is Dictionary: _add_bracket(box)
		elif network.supports_rematch:
			_label("On rejoue ?",22,INK,box)
			rematch_status = _label("",17,MUTED,box)
			rematch_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			rematch_button = _button("Oui, rejouer",_request_rematch,box,true)
			_update_rematch_controls()
	var leave := _confirm_leave if game_mode == "online" and (not result.finished or current_lobby.get("tournament") is Dictionary) else _leave_to_menu
	_button("Quitter le salon" if game_mode == "online" else "Retour à l’accueil",leave,box)

func _open_friends() -> void:
	friends_tri_cards = 0
	friends_local = false
	_show_friends()

func _show_friends(internet: bool = true) -> void:
	friends_local = not internet
	online_tab = internet
	address_input = null
	invitation_input = null
	var description := "Connectez les appareils au même Wi-Fi. Ce salon fonctionne sans Internet." if friends_local else "Retrouvez vos amis à distance avec un code à 6 chiffres."
	var box := _modal("Tri entre amis" if friends_tri_cards > 0 else "Rami entre amis", description)
	overlay_kind = "room_setup"
	var modes := HBoxContainer.new()
	modes.add_theme_constant_override("separation", 10)
	box.add_child(modes)
	_command_button("En ligne", _show_friends.bind(true), modes, not friends_local).size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_command_button("Même Wi-Fi", _show_friends.bind(false), modes, friends_local).size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var columns := HBoxContainer.new()
	columns.add_theme_constant_override("separation", 20)
	box.add_child(columns)
	var create := VBoxContainer.new()
	create.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	create.add_theme_constant_override("separation", 8)
	columns.add_child(create)
	_label("Créer un salon",22,INK,create)
	if friends_tri_cards > 0:
		_label("%d cartes par joueur" % friends_tri_cards,17,MUTED,create)
	room_count_select = _player_count_picker(create,friends_player_count)
	room_count_select.item_selected.connect(func(index: int): friends_player_count = index+2)
	_round_picker(create)
	_button("Créer un salon", _create_room, create, true)
	var join := VBoxContainer.new()
	join.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	join.add_theme_constant_override("separation", 8)
	columns.add_child(join)
	_label("Rejoindre un salon",22,INK,join)
	_room_code_field(join)
	_button("Rejoindre le salon", _join_room, join)
	_button("Retour", _cancel_room_setup, box)

func _cancel_room_setup() -> void:
	network.cancel_pending_join()
	_close_overlay()

func _room_code_field(parent: Node) -> void:
	code_input = _field("Code à 6 chiffres", "", parent)
	code_input.max_length = 6
	code_input.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_NUMBER
	code_input.text_submitted.connect(func(_value: String): _join_room())

func _round_picker(parent: Node) -> void:
	var picker := OptionButton.new()
	picker.custom_minimum_size.y = 54
	for count in [1,3,5]: picker.add_item("1 manche" if count == 1 else "%d manches" % count, count)
	picker.select(picker.get_item_index(friends_rounds))
	picker.item_selected.connect(func(index: int): friends_rounds = picker.get_item_id(index))
	parent.add_child(picker)

func _player_count_picker(parent: Node, count: int) -> OptionButton:
	var picker := OptionButton.new()
	picker.custom_minimum_size.y = 56
	for number in [2,3,4]: picker.add_item("%d joueurs" % number)
	picker.select(clampi(count-2,0,2))
	parent.add_child(picker)
	return picker

func _create_room() -> void:
	if friends_local:
		network.host_room(saved_name, NetworkRoom.PORT, friends_tri_cards, {"count":friends_player_count, "rounds":friends_rounds, "province":player_province, "discover":true})
		return
	_create_online(friends_tri_cards, friends_player_count)

func _create_online(tri_size: int, count: int, tournament: String = "") -> void:
	var address := ServerProfile.configured_url()
	if address.is_empty():
		_toast("Le service en ligne est indisponible dans cette version.")
		return
	if network.create_remote_room(address, saved_name, tri_size, count, {"rounds":friends_rounds, "province":player_province, "tournament":tournament}):
		_toast("Création du salon…")

func _join_room() -> void:
	var code := code_input.text.strip_edges()
	var digits_only := code.length() == 6
	for digit in code:
		if digit not in "0123456789": digits_only = false
	if not digits_only:
		_toast("Entrez le code à 6 chiffres de votre ami.")
		return
	if friends_local:
		if network.join_lan_room(saved_name, code, player_province): _toast("Recherche du salon sur le Wi-Fi…")
		return
	var address := ServerProfile.configured_url()
	if address.is_empty():
		_toast("Le service en ligne est indisponible dans cette version.")
		return
	if network.join_room(address, saved_name, code, player_province): _toast("Connexion au salon…")

func _show_tournaments() -> void:
	friends_local = false
	var box := _modal("Tournois", "Quatre joueurs, deux demi-finales et une finale.")
	overlay_kind = "room_setup"
	_label("Organiser un tournoi", 22, INK, box)
	tournament_name_input = _field("Nom du tournoi", "Tournoi entre amis", box)
	tournament_name_input.max_length = 36
	var choices := HBoxContainer.new()
	choices.add_theme_constant_override("separation", 10)
	box.add_child(choices)
	var format := OptionButton.new()
	format.custom_minimum_size.y = 54
	format.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	format.add_item("Rami", 0)
	format.add_item("Tri · 6 cartes", 6)
	format.add_item("Tri · 12 cartes", 12)
	choices.add_child(format)
	_round_picker(choices)
	_button("Créer le tournoi", func():
		var title := tournament_name_input.text.strip_edges()
		_create_online(format.get_selected_id(), 4, title if not title.is_empty() else "Tournoi entre amis"), box, true)
	box.add_child(HSeparator.new())
	_label("Rejoindre un tournoi", 22, INK, box)
	_room_code_field(box)
	_button("Rejoindre avec un code", _join_room, box)
	_button("Retour", _cancel_room_setup, box)

func _lobby_updated(data: Dictionary) -> void:
	var unchanged: bool = current_lobby == data
	var host_changed := bool(current_lobby.get("host",false)) != bool(data.get("host",false))
	current_lobby = data.duplicate(true)
	friends_tri_cards = int(data.get("tri_cards",0))
	if voice != null: voice.sync_players(data.get("players",[]))
	_update_voice_controls()
	if game_mode == "online" and not snapshot.is_empty() and data.get("started",false) and data.get("playing",true):
		if host_changed and overlay_kind == "winner":
			_winner_key = ""
			_show_winner()
		_update_rematch_controls()
		return
	# Presence heartbeats must not recreate an open player-count picker.
	if unchanged and game_mode == "lobby" and overlay_kind != "connection": return
	if game_mode != "lobby":
		toast_label.hide()
		toast_time = 0.0
	snapshot = {}
	game_mode = "lobby"
	_close_overlay()
	_clear_content()
	header_status.text = ("Salon Wi-Fi" if data.get("local",false) else "Salon") + " · " + str(data.get("code", network.room_code))
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _style(Color("222e26"), Color("657461"), 16, 26))
	_place(panel, content, Vector2(-330,125), Vector2(330,-35), Vector2(0.5,0), Vector2(0.5,1))
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)
	lobby_box = VBoxContainer.new()
	lobby_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lobby_box.add_theme_constant_override("separation", 12)
	scroll.add_child(lobby_box)
	var players: Array = data.get("players", [])
	var tournament: Variant = data.get("tournament")
	var started := bool(data.get("started", false))
	var title := _label(str(tournament.name) if tournament is Dictionary else ("Salon Wi-Fi" if data.get("local",false) else "Votre salon"), 30, INK, lobby_box)
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	if not started:
		var invitation := HBoxContainer.new()
		invitation.add_theme_constant_override("separation", 14)
		lobby_box.add_child(invitation)
		_label(str(data.get("code", network.room_code)), 40, GOLD, invitation).size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_command_button("Copier le code", _copy_invitation, invitation)
	var variant := "Tri · %d cartes" % friends_tri_cards if friends_tri_cards > 0 else "Rami"
	var count := int(data.get("rounds",1))
	_label("%s · %d manche%s" % [variant, count, "s" if count > 1 else ""], 16, MUTED, lobby_box)
	if started and tournament is Dictionary:
		_add_bracket(lobby_box)
		_button("Quitter le tournoi", _confirm_leave, lobby_box)
		_update_voice_controls()
		return
	var target := int(data.get("player_count",0))
	if target == 0: target = maxi(2, players.size())
	_label("%d / %d joueurs" % [players.size(),target],20,GOLD,lobby_box)
	for i in range(players.size()):
		var p: Dictionary = players[i]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		lobby_box.add_child(row)
		var name_label := _label(("●  " if p.get("connected",true) else "○  ") + _profile_label(p) + (" · vous" if i == network.local_player else ""), 18, INK, row)
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		if network.is_host and network.supports_kick and i != network.local_player and not str(p.get("seat_id","")).is_empty():
			_command_button("Retirer", network.remove_guest.bind(str(p.seat_id)), row)
	if network.is_host and not tournament is Dictionary:
		room_count_select = _player_count_picker(lobby_box,maxi(2,target))
		for i in range(3): room_count_select.set_item_disabled(i,i+2 < players.size())
		room_count_select.item_selected.connect(func(index: int): network.configure_players(index+2))
	var all_connected := true
	for player in players:
		if not player.get("connected",false): all_connected = false
	if players.size() < target: _label("En attente de %d joueur(s)…" % (target-players.size()),17,MUTED,lobby_box)
	if network.is_host:
		lobby_start = _button("Lancer le tournoi" if tournament is Dictionary else "Commencer la partie", func(): network.start_match(), lobby_box, true)
		lobby_start.disabled = players.size() < 2 or players.size() != target or not all_connected
	else:
		_label("L’hôte lancera la partie.", 18, GOLD, lobby_box)
	_button("Quitter le salon", _leave_to_menu, lobby_box)
	_update_voice_controls()

func _profile_label(player: Dictionary) -> String:
	var province := str(player.get("province", ""))
	return str(player.get("name", "Joueur")) + (" · " + province if not province.is_empty() else "")

func _entrant_label(index: Variant) -> String:
	var players: Array = current_lobby.get("players", [])
	if index == null or int(index) < 0 or int(index) >= players.size(): return "À déterminer"
	return _profile_label(players[int(index)])

func _show_bracket() -> void:
	var box := _modal("Tableau du tournoi", str(current_lobby.tournament.name))
	_add_bracket(box)
	_button("Revenir à la table", func():
		_close_overlay()
		if int(snapshot.get("winner",-1)) >= 0: _show_winner(), box)

func _add_bracket(box: VBoxContainer) -> void:
	var tournament: Dictionary = current_lobby.tournament
	var stage := int(tournament.stage)
	var labels := ["Demi-finale 1", "Demi-finale 2", "Finale"]
	for i in range(tournament.duels.size()):
		var duel: Dictionary = tournament.duels[i]
		var active_duel := i == stage and duel.winner == null
		var panel := PanelContainer.new()
		panel.add_theme_stylebox_override("panel", _style(DEEP, GOLD if active_duel else Color("465346"), 8, 10))
		box.add_child(panel)
		var card := VBoxContainer.new()
		card.add_theme_constant_override("separation", 4)
		panel.add_child(card)
		var title: String = labels[i]
		if active_duel: title += " · en cours"
		_label(title, 16, GOLD, card)
		var seats: Array = duel.seats
		if i == 2 and seats.size() < 2: seats = [tournament.duels[0].winner, tournament.duels[1].winner]
		if seats.size() == 2:
			_long_text(_entrant_label(seats[0]) + "   —   " + _entrant_label(seats[1]), card)
		if duel.winner != null:
			_long_text("Vainqueur · " + _entrant_label(duel.winner) if int(duel.winner) >= 0 else "Duel clos par abandon.", card)
	if tournament.champion != null:
		var champion := _label("Champion · " + _entrant_label(tournament.champion) if int(tournament.champion) >= 0 else "Tournoi clos", 21, GOLD, box)
		champion.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	elif stage >= 0 and tournament.duels[stage].winner != null:
		if network.is_host:
			_button("Lancer la finale" if stage == 1 else "Lancer la deuxième demi-finale", network.advance_tournament.bind(stage), box, true)
		else: _label("Le prochain duel sera lancé par l’hôte.", 17, MUTED, box)
	elif not current_lobby.get("playing",false):
		var progress: Variant = current_lobby.get("progress")
		if progress is Dictionary and progress.round_finished and not progress.finished and network.is_host:
			_button("Manche suivante", network.next_match_round.bind(progress), box, true)

func _request_rematch() -> void:
	network.request_rematch()

func _update_rematch_controls() -> void:
	if not is_instance_valid(rematch_button) or not is_instance_valid(rematch_status) or overlay_kind != "winner": return
	var ready := 0
	var count := 0
	var own_ready := false
	for i in range(current_lobby.get("players",[]).size()):
		var player: Dictionary = current_lobby.players[i]
		if player.get("departed",false) or player.get("forfeited",false): continue
		count += 1
		if player.get("rematch_ready",false):
			ready += 1
			if i == network.local_player: own_ready = true
	rematch_button.disabled = own_ready or not network.connected
	rematch_button.text = "Vous êtes prêt" if own_ready else "Oui, rejouer"
	rematch_status.text = "%d / %d prêts · même salon, même code." % [ready,count]
	if not network.connected: rematch_status.text = "Reconnexion au salon… Vous pourrez ensuite rejouer."
	elif own_ready: rematch_status.text += " En attente de vos amis…"

func _network_game_updated(data: Dictionary) -> void:
	if network.local_player < 0: return
	if overlay_kind == "connection" or game_mode != "online":
		_close_overlay()
	var entering: bool = game_mode != "online" or snapshot.get("session_id","") != data.get("session_id","") or snapshot.get("match",{}).get("round",1) != data.get("match",{}).get("round",1)
	var updated := data.duplicate(true)
	updated["your_index"] = int(updated.get("your_index", network.local_player))
	if not entering:
		var old_table := snapshot.duplicate()
		var new_table := updated.duplicate()
		for key in ["paused", "reconnect_remaining_ms"]:
			old_table.erase(key)
			new_table.erase(key)
		if old_table == new_table:
			snapshot = updated
			_update_turn_controls()
			return
	if entering:
		_close_overlay()
		_winner_key = ""
		_sound_revision = ""
		selected.clear()
		hand_order.clear()
		busy = false
	snapshot = updated
	if entering:
		game_mode = "online"
		_show_game()
	_render_snapshot()

func _connection_changed(connected: bool) -> void:
	_update_voice_controls()
	_update_rematch_controls()
	if network.quick_reconnect:
		if not connected and not snapshot.is_empty(): snapshot["paused"] = true
		_update_turn_controls()
		return
	if not connected and game_mode == "online" and int(snapshot.get("winner",-1)) >= 0:
		return
	if not connected and (game_mode == "lobby" or game_mode == "online"):
		if not snapshot.is_empty():
			snapshot["paused"] = true
			_update_turn_controls()
		var box := _modal("Connexion interrompue", "La partie vous laisse 60 secondes pour vous reconnecter. Passé ce délai, votre absence vaut abandon. Revenir à l’accueil maintenant compte aussi comme un abandon.")
		overlay_kind = "connection"
		_button("Se reconnecter", func(): _close_overlay(); network.reconnect(), box, true)
		_button("Abandonner la partie", _abandon_to_menu, box)

func _room_closed(message: String) -> void:
	_update_voice_controls()
	_update_rematch_controls()
	if game_mode == "online" and int(snapshot.get("winner", -1)) >= 0:
		if is_instance_valid(rematch_status): rematch_status.text = "Le salon est fermé."
		return
	if game_mode in ["lobby", "online"]:
		var box := _modal("Salon fermé", message)
		_button("Retour à l’accueil", _leave_to_menu, box, true)

func _modal(title: String, subtitle: String) -> VBoxContainer:
	_cancel_drag()
	_close_overlay()
	toast_label.hide()
	toast_time = 0.0
	overlay_kind = "general"
	var dim := ColorRect.new()
	dim.color = Color(0.015, 0.02, 0.015, 0.84)
	_place(dim, overlay, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ONE)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _style(Color("222e26"), Color("657461"), 10, 28))
	_place(panel, overlay, Vector2(-340,105), Vector2(340,-38), Vector2(0.5,0), Vector2(0.5,1))
	if animations_enabled:
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
	if not subtitle.is_empty():
		var sub := _label(subtitle, 17, MUTED, box)
		sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return box

func _close_overlay() -> void:
	overlay_kind = ""
	if not is_instance_valid(overlay): return
	for node in overlay.get_children():
		node.get_parent().remove_child(node)
		node.queue_free()

func _show_credits() -> void:
	var box := _modal("Crédits", "Les illustrations et polices du jeu.")
	_long_text("Cartes : SVGCards, Saul Spatz. Illustrations du domaine public, avec les figures classiques de Byron Knoll.",box)
	_button("Voir les cartes d’origine",func(): OS.shell_open("https://github.com/saulspatz/SVGCards"),box)
	_long_text("Polices : Open Sans, Noto Sans Symbols et DejaVu Serif. Leurs licences sont incluses dans l’application.",box)
	_button("Fermer",_close_overlay,box,true)

func _show_rules() -> void:
	if _is_tri():
		_show_tri_rules()
		return
	_show_lessons(-1)

func _show_lessons(chapter: int = -1) -> void:
	lesson_index = chapter
	var lessons: Array = coach.lessons()
	var box := _modal("Apprendre le rami", "Les règles, avec quelques exemples.")
	overlay_kind = "lessons"
	var setting := CheckButton.new()
	setting.text = "Afficher les conseils pendant la partie"
	setting.button_pressed = beginner_enabled
	setting.custom_minimum_size.y = 48
	setting.toggled.connect(func(value: bool): beginner_enabled = value; _save_preferences())
	box.add_child(setting)
	if chapter < 0:
		var intro := _label("Pour gagner, videz votre main en posant des combinaisons. Choisissez une règle ou essayez un tour d’entraînement.", 18, INK, box)
		intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		for i in range(lessons.size()):
			var idx := i
			var title := str(lessons[i].get("title", "")).trim_prefix(str(i+1)+" · ")
			var button := _button(str(i+1) + ". " + title, func(): _show_lessons(idx), box)
			button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		_button("Faire un tour d’essai", _start_tutorial, box, true)
		if game_mode in ["solo", "online"]:
			_button("Expliquer mon tour actuel", _show_coach, box)
	else:
		var lesson: Dictionary = lessons[clampi(chapter, 0, lessons.size()-1)]
		var title := str(lesson.get("title", "")).trim_prefix(str(chapter+1)+" · ")
		_label(str(chapter+1) + " / " + str(lessons.size()) + " · " + title, 23, GOLD, box).autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_long_text(str(lesson.get("body", "")), box)
		_label("Exemple", 13, GOLD, box)
		_long_text(str(lesson.get("example", "")), box)
		for tip in lesson.get("tips", []):
			_long_text("• " + str(tip), box)
		if chapter < lessons.size()-1:
			_button("Étape suivante", func(): _show_lessons(chapter+1), box, true)
		_button("Toutes les étapes", func(): _show_lessons(-1), box)
	_button("C’est compris", _close_overlay, box)

func _long_text(text: String, parent: Node) -> Label:
	var label := _label(text, 19, INK, parent)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_constant_override("line_spacing", 5)
	return label

func _show_coach() -> void:
	if _is_tri():
		_show_tri_rules()
		return
	var advice: Dictionary = coach.advice(snapshot, selected)
	var box := _modal(str(advice.get("title", "Votre prochain tour")), str(advice.get("body", "")))
	overlay_kind = "coach"
	_label("Les étapes", 13, GOLD, box)
	var steps: Array = advice.get("steps", [])
	for i in range(steps.size()):
		_long_text(str(i+1) + ". " + str(steps[i]), box)
	_label("Avec votre main", 13, GOLD, box)
	_long_text(str(advice.get("example", "")), box)
	_label("À faire maintenant", 13, GOLD, box)
	_long_text(str(advice.get("action", "")), box)
	_button("Revenir à ma main", _close_overlay, box, true)
	_button("Lire les règles", _show_rules, box)

func _start_sorting() -> void:
	player_name = saved_name
	turn_token += 1
	busy = false
	game_mode = "sorting"
	network.leave_room()
	_close_overlay()
	snapshot = {}
	_clear_content()
	header_status.text = "Rangement · 3 manches"
	var challenge := SortingChallenge.new()
	_place(challenge, content, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ONE)
	challenge.exit_requested.connect(_leave_to_menu)
	challenge.start_challenge()

func _show_music_settings() -> void:
	var box := _modal("Musique et sons", "Réglez la musique et le volume des cartes.")
	overlay_kind = "music"
	var toggle := CheckButton.new()
	toggle.text = "Écouter la musique"
	toggle.custom_minimum_size.y = 54
	toggle.button_pressed = music.enabled
	toggle.toggled.connect(func(value: bool): music.set_enabled(value))
	box.add_child(toggle)
	_label("Morceau", 13, GOLD, box)
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
	_label("Sons des cartes", 13, GOLD, box)
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
	if is_instance_valid(music_button):
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
	var scale_value := HAND_SCALE * hand_scale_factor
	var available := camera.size * ratio * 0.90
	var separation := 0.32 * scale_value if _is_tri() and tri_grouping_enabled else 0.0
	var extras: float = separation * _tri_boundaries.size()
	var gap := minf(1.60, (available - 1.05*scale_value - extras) / maxf(1, hand_cards.size()-1))
	var span: float = (hand_cards.size()-1)*gap + extras
	var center_y := -camera.size/2.0 + 1.95 + 1.52*scale_value/2.0
	for i in range(hand_cards.size()):
		var card = hand_cards[i]
		var offset := 0.0
		for boundary in _tri_boundaries:
			if i >= int(boundary): offset += separation
		var x: float = i*gap+offset-span*.5
		var norm: float = x/maxf(1,span*.5)
		var y: float = center_y + 0.28*(1.0-norm*norm)
		card.set_meta("rest_y", y)
		var pos := Vector3(x, y + (0.32 if selected.has(card.card_id) else 0.0), -10.0+i*0.018)
		var basis := (Basis(Vector3.BACK, -norm*0.25) * Basis(Vector3.RIGHT, PI/2.0)).scaled(Vector3.ONE*scale_value)
		var arriving: bool = card.get_meta("arriving", false)
		card.move_to(Transform3D(basis, pos), (0.42 if arriving else 0.28) if animate and animations_enabled else 0.0, i * 0.045 if deal else 0.0, 0.35 if arriving else 0.08)
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
	if game_mode in ["sorting","tutorial"]:
		var exercise := _modal("Quitter cet exercice ?", "Vous pourrez recommencer depuis l’accueil.")
		_button("Continuer",_close_overlay,exercise,true)
		_button("Retour à l’accueil",_leave_to_menu,exercise)
		return
	if game_mode == "lobby" or current_lobby.get("tournament") is Dictionary and game_mode == "online":
		var tournament := current_lobby.get("tournament") is Dictionary
		var subtitle := "Votre place sera libérée."
		if tournament and current_lobby.get("started",false) and not current_lobby.get("finished",false): subtitle = "Quitter retire votre place dans les duels à venir."
		var box := _modal("Quitter le tournoi ?" if tournament else "Quitter le salon ?", subtitle)
		_button("Rester", _close_overlay, box, true)
		_button("Quitter", _leave_to_menu, box)
		return
	if int(snapshot.get("winner",-1)) >= 0 and _winner_result().finished:
		_leave_to_menu()
		return
	var message := "Abandonner termine le match : vous perdez et votre adversaire gagne."
	if game_mode == "online" and network._hosting_locally:
		message += " Comme vous hébergez le salon Wi-Fi, celui-ci sera fermé et les joueurs restants seront déclarés gagnants."
	elif game_mode == "online" and snapshot.get("players",[]).size() > 2:
		message = "Vous serez éliminé du match. Les joueurs restants continueront ; le dernier encore en jeu gagnera."
	var box := _modal("Abandonner la partie ?",message)
	_button("Rester à la table",_close_overlay,box,true)
	if game_mode == "solo":
		_button("Sauvegarder et revenir à l’accueil",_leave_to_menu,box)
	_button("Abandonner la partie",_abandon_to_menu,box)

func _abandon_to_menu() -> void:
	turn_token += 1
	busy = false
	if game_mode == "solo" and engine != null and int(engine.state.get("winner",-1)) < 0:
		engine.forfeit_player(0,"abandon",true)
		snapshot = engine.view_for(0)
		snapshot["your_index"] = 0
		SoloStore.record_round(engine.state)
		_autosave()
	_leave_to_menu()

func _leave_to_menu() -> void:
	_autosave()
	game_mode = "menu"
	current_lobby = {}
	voice.sync_players([])
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
	if cfg.load(Profile.PREFERENCES) == OK:
		saved_name = str(cfg.get_value("player", "name", "Vous"))
		var province := str(cfg.get_value("player", "province", ""))
		player_province = province if province in Profile.PROVINCES else ""
		saved_address = str(cfg.get_value("network", "server", ""))
		difficulty = clampi(int(cfg.get_value("solo","difficulty",1)),0,2)
		bot_count = clampi(int(cfg.get_value("solo","opponents",1)),1,3)
		match_length = int(cfg.get_value("solo","rounds",1))
		if not match_length in [1,3,5]: match_length = 1
		effects_volume = clampf(float(cfg.get_value("effects","volume",0.55)),0,1)
		effects_enabled = bool(cfg.get_value("effects","enabled",true))
		beginner_enabled = bool(cfg.get_value("help", "beginner", true))
		animations_enabled = bool(cfg.get_value("comfort","animations",true))
		hand_scale_factor = clampf(float(cfg.get_value("comfort","hand_scale",1.0)),0.85,1.05)
		left_handed = bool(cfg.get_value("comfort","left_handed",false))
		economy_mode = bool(cfg.get_value("comfort","economy",false))
		tri_grouping_enabled = bool(cfg.get_value("comfort","tri_groups",false))
		var saved_music: Variant = cfg.get_value("music", "settings", music_settings)
		if saved_music is Dictionary:
			music_settings = saved_music
	player_name = saved_name

func _save_preferences() -> bool:
	var cfg := ConfigFile.new()
	cfg.set_value("player", "name", saved_name)
	cfg.set_value("player", "province", player_province)
	cfg.set_value("network", "server", saved_address)
	cfg.set_value("help", "beginner", beginner_enabled)
	cfg.set_value("music", "settings", music_settings)
	cfg.set_value("solo","difficulty",difficulty)
	cfg.set_value("solo","rounds",match_length)
	cfg.set_value("solo","opponents",bot_count)
	cfg.set_value("effects","volume",effects_volume)
	cfg.set_value("effects","enabled",effects_enabled)
	cfg.set_value("comfort","animations",animations_enabled)
	cfg.set_value("comfort","hand_scale",hand_scale_factor)
	cfg.set_value("comfort","left_handed",left_handed)
	cfg.set_value("comfort","economy",economy_mode)
	cfg.set_value("comfort","tri_groups",tri_grouping_enabled)
	return Profile.save_preferences(cfg)

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
	if engine.state.get("variant", "rami") == "rami":
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
	_label("Adversaires au rami", 15, MUTED, box)
	var opponents := OptionButton.new()
	for count in [1,2,3]: opponents.add_item("%d adversaire%s" % [count, "s" if count > 1 else ""])
	opponents.selected = bot_count-1
	opponents.custom_minimum_size.y = 52
	opponents.item_selected.connect(func(index: int):
		bot_count = index+1
		_save_preferences()
	)
	box.add_child(opponents)
	_label("Difficulté", 15, MUTED, box)
	var choice := OptionButton.new()
	for title in ["Facile · pour apprendre", "Normal · équilibré", "Difficile · anticipe les combinaisons"]:
		choice.add_item(title)
	choice.selected = difficulty
	choice.custom_minimum_size.y = 52
	choice.item_selected.connect(func(index: int): difficulty = index; _save_preferences())
	box.add_child(choice)
	_label("Manches", 13, GOLD, box)
	var rounds := OptionButton.new()
	for count in [1,3,5]: rounds.add_item(str(count) + " manche(s)",count)
	rounds.selected = [1,3,5].find(match_length)
	rounds.custom_minimum_size.y = 52
	rounds.item_selected.connect(func(index: int): match_length = [1,3,5][index]; _save_preferences())
	box.add_child(rounds)
	var stats: Dictionary = SoloStore.statistics()
	_label("Vos statistiques",13,GOLD,box)
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
	var key := "%s:%s:%s" % [snapshot.get("session_id",""),snapshot.get("match",{}).get("round",1),snapshot.get("revision",0)]
	if key == _sound_revision: return
	_sound_revision = key
	var action: Dictionary = snapshot.get("last_action",{})
	var actor := int(action.get("player",-1))
	if not initial and actor != int(snapshot.get("your_index",0)):
		table_scene.animate_action(actor,str(action.get("type","")),str(action.get("source","deck")))
	if effects == null: return
	if int(snapshot.get("winner",-1)) >= 0:
		effects.play("win")
	elif initial:
		effects.play("deal")
	else:
		effects.play(str(snapshot.get("last_action",{}).get("type","")))

func _opponent_indices() -> Array:
	var result: Array = []
	var own := int(snapshot.get("your_index",0))
	for index in range(snapshot.get("players",[]).size()):
		if index != own: result.append(index)
	return result

func _opponent_position(player: int) -> Vector3:
	var opponents := _opponent_indices()
	return TableSalon.seat_position(maxi(0,opponents.find(player)),opponents.size())

func _render_opponents(initial: bool) -> void:
	var players: Array = snapshot.get("players",[])
	var own := int(snapshot.get("your_index",0))
	table_scene.set_motion_enabled(animations_enabled)
	table_scene.set_players(players,own,int(snapshot.get("turn",-1)))
	var opponents := _opponent_indices()
	for i in opponents:
		var count := 0 if players[i].get("forfeited",false) else clampi(int(players[i].get("count",13)),0,108)
		var yaw := TableSalon.seat_yaw(opponents.find(i),opponents.size())
		for j in range(count):
			var card := _view_card("0:S:1",false,self,"opponent:%d:%d" % [i,j],"opponent")
			card.set_meta("seat_index",i)
			card._area.input_ray_pickable = false
			card._area.collision_layer = 0
			var norm: float = (j-(count-1)/2.0)/maxf(1,(count-1)/2.0)
			var spread := minf(.19,2.15/maxf(1,count-1))
			var local := Vector3((j-(count-1)/2.0)*spread,.11*(1.0-norm*norm),.12*norm*norm+j*.004)
			var pos := _opponent_position(i) + Basis(Vector3.UP,yaw)*local
			var basis := (Basis(Vector3.UP,yaw)*Basis(Vector3.RIGHT,1.05)*Basis(Vector3.UP,-norm*.22)).scaled(Vector3.ONE*.94)
			if card.get_meta("new_in_view",false):
				var last: Dictionary = snapshot.get("last_action",{})
				card.position = Vector3(.85,.19,-.8) if not initial and int(last.get("player",-1)) == i and last.get("source","") == "discard" else DECK_POSITION
			card.move_to(Transform3D(basis,pos),.35 if animations_enabled else 0.0,j*.025 if initial else 0.0,.35)

func _copy_invitation() -> void:
	DisplayServer.clipboard_set(network.room_code)
	_toast("Code copié. Envoyez ces 6 chiffres à vos amis.")

func _join_invitation() -> void:
	var invite: Dictionary = Invitation.parse(invitation_input.text)
	if invite.is_empty():
		_toast("Invitation invalide. Collez le texte complet commençant par rami3d://join?.")
		return
	if invite.server.begins_with("wss://"):
		saved_address = invite.server
		_save_preferences()
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
		if effects != null: effects.play_slide()
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
		tri_grouping_enabled = false
		_save_preferences()
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

var _UI_sparkles: Array = []

func _show_comfort_settings() -> void:
	var box := _modal("Affichage et confort","Ces réglages sont mémorisés sur ce téléphone.")
	var motion := CheckButton.new()
	motion.text = "Animations des cartes et transitions"
	motion.custom_minimum_size.y = 52
	motion.button_pressed = animations_enabled
	motion.toggled.connect(func(value: bool): animations_enabled = value; _apply_comfort(); _save_preferences())
	box.add_child(motion)
	var handed := CheckButton.new()
	handed.text = "Mode gaucher · actions principales à gauche"
	handed.custom_minimum_size.y = 52
	handed.button_pressed = left_handed
	handed.toggled.connect(func(value: bool): left_handed = value; _apply_comfort(); _save_preferences())
	box.add_child(handed)
	var size_label := _label("Taille de votre main · " + str(roundi(hand_scale_factor*100)) + " %",20,INK,box)
	var slider := HSlider.new()
	slider.min_value = 85
	slider.max_value = 105
	slider.step = 1
	slider.value = hand_scale_factor*100
	slider.custom_minimum_size.y = 54
	slider.value_changed.connect(func(value: float): hand_scale_factor = value/100.0; size_label.text = "Taille de votre main · " + str(roundi(value)) + " %"; _apply_comfort(); _save_preferences())
	box.add_child(slider)
	_long_text("Le mode gaucher inverse l’ordre des boutons sous la main. Désactivez les animations pour des déplacements instantanés et moins de mouvement.",box)
	var economy := CheckButton.new()
	economy.text = "Économie de batterie · 30 images/s, sans ombres"
	economy.custom_minimum_size.y = 52
	economy.button_pressed = economy_mode
	economy.toggled.connect(func(value: bool): economy_mode = value; _apply_performance(); _save_preferences())
	box.add_child(economy)
	_button("Terminé",_close_overlay,box,true)

func _apply_comfort() -> void:
	if is_instance_valid(table_scene): table_scene.set_motion_enabled(animations_enabled)
	hand_scale_factor = clampf(hand_scale_factor,0.85,1.05)
	for card in card_nodes:
		if not is_instance_valid(card): continue
		card.set_meta("reduced_motion",not animations_enabled)
		if not animations_enabled:
			var target: Transform3D = card.motion_target
			card.move_to(target,0)
	if not animations_enabled:
		for sparkle in _UI_sparkles:
			if sparkle != null and sparkle.is_valid(): sparkle.kill()
		_UI_sparkles.clear()
	if is_instance_valid(action_row) and not action_buttons_base.is_empty():
		var order := action_buttons_base.duplicate()
		if left_handed: order.reverse()
		for i in range(order.size()):
			if is_instance_valid(order[i]) and order[i].get_parent() == action_row: action_row.move_child(order[i],i)
	_layout_hand(false)

func _start_tutorial() -> void:
	if game_mode == "online" and int(snapshot.get("winner",-1)) < 0:
		_toast("Terminez votre partie ou abandonnez-la avant de lancer l’entraînement.")
		return
	_autosave()
	turn_token += 1
	busy = false
	game_mode = "tutorial"
	network.leave_room()
	_close_overlay()
	_clear_content()
	header_status.text = "Apprendre le rami"
	var practice := Practice.new()
	_place(practice,content,Vector2.ZERO,Vector2.ZERO,Vector2.ZERO,Vector2.ONE)
	practice.exit_requested.connect(_leave_to_menu)
	practice.completed.connect(func(): _toast("Premier tour réussi ! Vous pouvez maintenant essayer une partie solo."))
	practice.start_lesson()

func _resume_network() -> void:
	if network.resume_session():
		_toast("Reconnexion à votre salon…")
	else:
		_toast("Aucun salon ne peut être repris. Rejoignez un nouveau salon.")

func _is_tri() -> bool:
	if game_mode == "solo" and engine != null: return engine.state.get("variant","rami") == "tri"
	return game_mode == "online" and snapshot.get("variant","rami") == "tri"

func _show_tri_setup() -> void:
	friends_local = false
	var box := _modal("Tri", "Choisissez le nombre de cartes et votre mode de jeu.")
	var choice := OptionButton.new()
	choice.add_item("6 cartes · objectif 2 tris",6)
	choice.add_item("12 cartes · objectif 3 tris",12)
	choice.selected = 0 if tri_choice == 6 else 1
	choice.custom_minimum_size.y = 52
	choice.item_selected.connect(func(index: int): tri_choice = [6,12][index])
	box.add_child(choice)
	_button("Tri contre l’ordinateur",func(): _start_solo(tri_choice),box,true)
	_button("Tri avec des amis",func(): friends_tri_cards = tri_choice; _show_friends(),box)
	_button("Apprendre le Tri",_start_tri_tutorial,box)
	_button("Retour",_close_overlay,box)

func _show_tri_rules() -> void:
	var box := _modal("Les règles du Tri","Vos combinaisons restent cachées jusqu’à votre victoire.")
	overlay_kind = "tri_rules"
	_long_text("Objectif : 2 tris avec 6 cartes, ou 3 tris avec 12 cartes. Un tri réunit exactement trois cartes de même valeur : 7♥ + 7♥ + 7♣ est valable. Les suites ne comptent pas. Au maximum deux cartes de la même couleur (♣ ♦ ♥ ♠) dans un tri.",box)
	_long_text("1. Piochez une carte dans la pioche ou sur la défausse.\n2. Gardez vos tris dans votre main.\n3. Touchez une seule carte puis Défausser. Le jeu vérifie alors si vous avez assez de tris distincts. Chaque carte ne compte que dans un tri. Avec 12 cartes, les trois cartes hors des tris restent libres.",box)
	_long_text("Trier alterne le rangement par couleur et par valeur, même pendant le tour adverse. Mes tris met vos groupes en évidence uniquement sur votre téléphone ; ce bouton ne pose aucune carte. Cette version utilise deux jeux sans jokers.",box)
	_button("Revenir à ma main",_close_overlay,box,true)

func _toggle_tri_groups() -> void:
	if not _is_tri(): return
	tri_grouping_enabled = not tri_grouping_enabled
	if effects != null: effects.play_slide()
	_render_snapshot()
	_autosave()
	_save_preferences()
	_toast("Tris séparés dans votre main privée." if tri_grouping_enabled else "Rangement libre de votre main.")

func _apply_performance() -> void:
	Engine.max_fps = 30 if economy_mode else 60
	get_viewport().msaa_3d = Viewport.MSAA_DISABLED if economy_mode else Viewport.MSAA_2X
	if is_instance_valid(_key_light): _key_light.shadow_enabled = not economy_mode

func _start_tri_tutorial() -> void:
	if game_mode == "online" and int(snapshot.get("winner",-1)) < 0:
		_toast("Terminez votre partie ou abandonnez-la avant de lancer l’entraînement.")
		return
	_autosave()
	turn_token += 1
	busy = false
	game_mode = "tutorial"
	network.leave_room()
	_close_overlay()
	_clear_content()
	header_status.text = "Apprendre le Tri · %d cartes" % tri_choice
	var practice := TriPractice.new()
	_place(practice,content,Vector2.ZERO,Vector2.ZERO,Vector2.ZERO,Vector2.ONE)
	practice.exit_requested.connect(_leave_to_menu)
	practice.completed.connect(func(): _toast("Premier Tri réussi ! Vous pouvez lancer une partie."))
	practice.start_lesson(tri_choice)

func _make_voice_controls() -> void:
	voice_panel = PanelContainer.new()
	voice_panel.add_theme_stylebox_override("panel",_style(Color("1b281f"),Color("5b644d"),6,12))
	_place(voice_panel,ui,Vector2(24,105),Vector2(262,265))
	var box := VBoxContainer.new()
	voice_panel.add_child(box)
	voice_label = _label("Micro coupé",15,MUTED,box)
	voice_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	mic_button = _command_button("Maintenir pour parler",func(): pass,box)
	mic_button.icon = load("res://assets/microphone.svg")
	mic_button.expand_icon = true
	mic_button.add_theme_constant_override("icon_max_width",18)
	mic_button.add_theme_font_size_override("font_size",14)
	mic_button.button_down.connect(func(): voice.begin_talk())
	mic_button.button_up.connect(func(): voice.stop_talk())
	mic_button.mouse_exited.connect(func(): voice.stop_talk())
	listen_button = _command_button("Son des amis : activé",func(): voice.toggle_listening(),box)
	listen_button.add_theme_font_size_override("font_size",14)
	speakers_button = _command_button("Voix par joueur", _show_voice_settings, box)
	speakers_button.add_theme_font_size_override("font_size",14)
	_update_voice_controls()

func _show_voice_settings() -> void:
	var box := _modal("Voix des joueurs", "Choisissez qui vous voulez entendre.")
	var players: Array = current_lobby.get("players", [])
	for i in range(players.size()):
		if i == network.local_player or players[i].get("departed",false): continue
		var toggle := CheckButton.new()
		toggle.text = _profile_label(players[i])
		toggle.custom_minimum_size.y = 48
		toggle.button_pressed = not voice.speaker_muted(i)
		toggle.toggled.connect(func(value: bool): voice.set_speaker_muted(i, not value))
		box.add_child(toggle)
	_button("Revenir au salon" if game_mode == "lobby" else "Revenir à la table", func():
		_close_overlay()
		if int(snapshot.get("winner",-1)) >= 0: _show_winner(), box, true)

func _update_voice_controls() -> void:
	if not is_instance_valid(voice_panel) or network == null or voice == null: return
	voice_panel.visible = not network.room_code.is_empty() and game_mode in ["lobby","online"] and not current_lobby.get("local",false)
	mic_button.disabled = not voice.available or not network.connected
	speakers_button.disabled = current_lobby.get("players",[]).size() < 2
	listen_button.text = "Son des amis : activé" if voice.listening else "Son des amis : coupé"
	mic_button.text = "Vous parlez…" if voice.transmitting else "Maintenir pour parler"
	if not voice.available: voice_label.text = "Vocal indisponible" if network.connected else "Vocal déconnecté"
	elif voice.transmitting: voice_label.text = "Micro ouvert · relâchez pour couper"
	elif not voice.listening: voice_label.text = "Micro coupé · écoute désactivée"
	elif not voice.speakers.is_empty():
		var names: Array[String] = []
		for index in voice.speakers:
			var players: Array = current_lobby.get("players",[])
			if index < players.size(): names.append(str(players[index].name))
		voice_label.text = ", ".join(names) + " parle…"
	else: voice_label.text = "Micro coupé · écoute activée"
