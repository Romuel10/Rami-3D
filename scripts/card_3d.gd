class_name RamiCard3D
extends Node3D
## A physical, touchable card lying face-up in the local XZ plane.
## SVG artwork uses paths only, so Android's SVG renderer needs no system fonts.

signal tapped(card: RamiCard3D)

const CARD_WIDTH := 1.05
const CARD_LENGTH := 1.52
const CARD_DEPTH := 0.026
const REST_HEIGHT := 0.15
const SELECTED_LIFT := 0.28
const IVORY := Color("f6f0df")
const GOLD := Color("d3ae65")

static var _textures: Dictionary = {}
static var _materials: Dictionary = {}
static var _body_mesh: ArrayMesh
static var _print_mesh: QuadMesh
static var _touch_shape: BoxShape3D
static var _paper_grain: ImageTexture
var card_id: String = "0:S:1"
var face_up: bool = true
var selected: bool = false
var _visual: Node3D
var _face: MeshInstance3D
var _outline: MeshInstance3D
var _area: Area3D
var _lift_tween: Tween
var _motion_tween: Tween
var _motion_from := Transform3D.IDENTITY
var motion_target := Transform3D.IDENTITY
var _motion_arc := 0.0
# Godot may deliver both touch and its synthetic mouse press to picking.
var _last_touch_press_msec: int = -1000
var _last_emulated_press_msec: int = -1000
const TOUCH_MOUSE_PAIR_WINDOW_MSEC := 150

func _ready() -> void:
	_build_if_needed()
	_update_art()

func setup(new_card_id: String, new_face_up: bool = true) -> void:
	card_id = new_card_id
	face_up = new_face_up
	set_meta("card_id", card_id)
	_build_if_needed()
	_update_art()

func set_selected(value: bool, lift_paper: bool = true) -> void:
	selected = value
	_build_if_needed()
	_outline.visible = value
	if _lift_tween and _lift_tween.is_valid():
		_lift_tween.kill()
	var target := REST_HEIGHT + (SELECTED_LIFT if value and lift_paper else 0.0)
	if get_meta("reduced_motion",false):
		_set_paper_height(target)
	elif is_equal_approx(_visual.position.y, target):
		_set_paper_height(target)
	elif is_inside_tree():
		_lift_tween = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		_lift_tween.tween_method(_set_paper_height, _visual.position.y, target, 0.18)
	else:
		_set_paper_height(target)

func _set_paper_height(height: float) -> void:
	# The hitbox follows the printed card throughout selection, including on touch.
	_visual.position.y = height
	_area.position.y = height

func move_to(target: Transform3D, seconds: float = 0.32, delay: float = 0.0, arc: float = 0.0) -> void:
	if get_meta("reduced_motion",false):
		seconds = 0.0
		delay = 0.0
		arc = 0.0
	# A repeated network snapshot must not restart a flight already in progress.
	if seconds > 0.0 and is_moving() and motion_target.is_equal_approx(target):
		return
	cancel_motion()
	motion_target = target
	if not is_inside_tree() or seconds <= 0.0 or transform.is_equal_approx(target):
		transform = target
		return
	_motion_from = transform
	_motion_arc = arc
	_motion_tween = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_motion_tween.tween_method(_sample_motion, 0.0, 1.0, seconds).set_delay(delay)

func _sample_motion(progress: float) -> void:
	var pose := _motion_from.interpolate_with(motion_target, progress)
	pose.origin.y += sin(progress * PI) * _motion_arc
	transform = pose

func is_moving() -> bool:
	return _motion_tween != null and _motion_tween.is_valid()

func cancel_motion() -> void:
	if is_moving():
		_motion_tween.kill()
	_motion_tween = null

func _build_if_needed() -> void:
	if _visual != null:
		return
	_visual = Node3D.new()
	_visual.name = "Paper"
	_visual.position.y = REST_HEIGHT
	add_child(_visual)
	if _body_mesh == null:
		_body_mesh = _rounded_prism()
	var body := MeshInstance3D.new()
	body.mesh = _body_mesh
	body.name = "Cardstock"
	body.material_override = _paper_material()
	_visual.add_child(body)
	_outline = MeshInstance3D.new()
	_outline.name = "SelectionBorder"
	_outline.mesh = _body_mesh
	_outline.scale = Vector3(1.065, 0.7, 1.045)
	_outline.position.y = -0.008
	_outline.material_override = _selection_material()
	_outline.visible = selected
	_visual.add_child(_outline)
	_face = MeshInstance3D.new()
	_face.name = "PrintedFace"
	if _print_mesh == null:
		_print_mesh = QuadMesh.new()
		_print_mesh.size = Vector2(CARD_WIDTH, CARD_LENGTH)
	_face.mesh = _print_mesh
	_face.rotation.x = -PI / 2.0
	_face.position.y = CARD_DEPTH / 2.0 + 0.001
	_face.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_visual.add_child(_face)
	var back := MeshInstance3D.new()
	back.name = "PrintedBack"
	back.mesh = _print_mesh
	back.rotation.x = PI / 2.0
	back.position.y = -CARD_DEPTH / 2.0 - 0.001
	back.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	back.material_override = _art_material("__back__", _back_svg())
	_visual.add_child(back)
	_area = Area3D.new()
	_area.name = "TouchTarget"
	_area.position.y = REST_HEIGHT
	_area.input_ray_pickable = true
	_area.collision_layer = 1
	_area.collision_mask = 0
	var collision := CollisionShape3D.new()
	if _touch_shape == null:
		_touch_shape = BoxShape3D.new()
		_touch_shape.size = Vector3(CARD_WIDTH, 0.09, CARD_LENGTH)
	collision.shape = _touch_shape
	_area.add_child(collision)
	_area.input_event.connect(_on_input_event)
	add_child(_area)

func _update_art() -> void:
	var key := "__back__"
	if face_up:
		var parts := card_id.split(":")
		key = "__joker__" if parts[0] == "J" else ":".join(parts.slice(1))
	_face.material_override = _art_material(key, _front_svg(card_id) if face_up else _back_svg())

func _art_material(key: String, svg: String) -> StandardMaterial3D:
	if _materials.has(key):
		return _materials[key]
	if not _textures.has(key):
		var img := Image.new()
		var error := img.load_svg_from_string(svg, 1.4)
		if error != OK:
			push_warning("Unable to render card artwork: %s" % key)
			return StandardMaterial3D.new()
		img.generate_mipmaps()
		_textures[key] = ImageTexture.create_from_image(img)
	var material := StandardMaterial3D.new()
	material.albedo_texture = _textures[key]
	material.albedo_color = Color("e4e1d8")
	# Matte ink follows the room lighting. A small texture-matched fill keeps
	# rank corners readable in the held fan without flattening cast shadows.
	material.roughness = 0.86
	material.metallic_specular = 0.12
	material.roughness_texture = _grain_texture()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	material.emission_enabled = true
	material.emission = Color.WHITE
	material.emission_texture = _textures[key]
	material.emission_energy_multiplier = 0.025
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	material.alpha_scissor_threshold = 0.25
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_materials[key] = material
	return material

func _on_input_event(_camera: Node, event: InputEvent, _point: Vector3, _normal: Vector3, _shape: int) -> void:
	var touch_press: bool = event is InputEventScreenTouch and event.pressed
	var mouse_press: bool = event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed
	if not touch_press and not mouse_press:
		return
	var now := Time.get_ticks_msec()
	if touch_press:
		if now - _last_emulated_press_msec <= TOUCH_MOUSE_PAIR_WINDOW_MSEC:
			return
		_last_touch_press_msec = now
	elif event.device == InputEvent.DEVICE_ID_EMULATION:
		if now - _last_touch_press_msec <= TOUCH_MOUSE_PAIR_WINDOW_MSEC:
			return
		_last_emulated_press_msec = now
	# Record only accepted presses. Successive real touches remain responsive,
	# and synthetic-mouse-only picking still works when no touch was delivered.
	tapped.emit(self)

static func _paper_material() -> StandardMaterial3D:
	if _materials.has("__stock__"): return _materials["__stock__"]
	var material := StandardMaterial3D.new()
	material.albedo_color = IVORY
	material.vertex_color_use_as_albedo = true
	material.roughness = 0.79
	material.metallic_specular = 0.22
	_materials["__stock__"] = material
	return material

static func _selection_material() -> StandardMaterial3D:
	if _materials.has("__selection__"): return _materials["__selection__"]
	var material := StandardMaterial3D.new()
	material.albedo_color = GOLD
	material.metallic = 0.35
	material.roughness = 0.40
	material.emission_enabled = true
	material.emission = Color("9b773a")
	material.emission_energy_multiplier = 0.14
	_materials["__selection__"] = material
	return material

static func _grain_texture() -> ImageTexture:
	if _paper_grain != null: return _paper_grain
	# One small, deterministic roughness map is shared by every printed side.
	# Grain affects the broad highlight; it never reduces the ink contrast.
	var image := Image.create(64,64,false,Image.FORMAT_RGB8)
	for y in range(64):
		for x in range(64):
			var value := 0.82 + float((x*37+y*71+x*y*13) % 19)/100.0
			image.set_pixel(x,y,Color(value,value,value))
	image.generate_mipmaps()
	_paper_grain = ImageTexture.create_from_image(image)
	return _paper_grain

static func _rounded_prism() -> ArrayMesh:
	var points: Array[Vector2] = []
	var radius := 0.065
	var half_width := CARD_WIDTH / 2.0
	var half_length := CARD_LENGTH / 2.0
	var corners := [Vector2(half_width - radius, half_length - radius), Vector2(-half_width + radius, half_length - radius), Vector2(-half_width + radius, -half_length + radius), Vector2(half_width - radius, -half_length + radius)]
	for corner in range(4):
		for step in range(7):
			var angle := float(corner) * PI / 2.0 + float(step) * PI / 12.0
			points.append(corners[corner] + Vector2(cos(angle), sin(angle)) * radius)
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var top := CARD_DEPTH / 2.0
	var bevel := 0.005
	var heights := [-top,-top+bevel,top-bevel,top]
	var insets := [0.004,0.0,0.0,0.004]
	for i in range(points.size()):
		var a := points[i]
		var b := points[(i + 1) % points.size()]
		var inner_a := a * Vector2((half_width-0.004)/half_width,(half_length-0.004)/half_length)
		var inner_b := b * Vector2((half_width-0.004)/half_width,(half_length-0.004)/half_length)
		# Godot's front faces wind clockwise when seen from outside.
		vertices.append_array(PackedVector3Array([Vector3(0,top,0),Vector3(inner_a.x,top,inner_a.y),Vector3(inner_b.x,top,inner_b.y)]))
		normals.append_array(PackedVector3Array([Vector3.UP,Vector3.UP,Vector3.UP]))
		vertices.append_array(PackedVector3Array([Vector3(0,-top,0),Vector3(inner_b.x,-top,inner_b.y),Vector3(inner_a.x,-top,inner_a.y)]))
		normals.append_array(PackedVector3Array([Vector3.DOWN,Vector3.DOWN,Vector3.DOWN]))
		for _face_vertex in range(6): colors.append(Color.WHITE)
		var side := Vector3(b.y-a.y,0,a.x-b.x).normalized()
		for layer in range(3):
			var low_scale := Vector2((half_width-insets[layer])/half_width,(half_length-insets[layer])/half_length)
			var high_scale := Vector2((half_width-insets[layer+1])/half_width,(half_length-insets[layer+1])/half_length)
			var low_a := a*low_scale
			var low_b := b*low_scale
			var high_a := a*high_scale
			var high_b := b*high_scale
			var normal := (side + Vector3.UP * (-0.65 if layer==0 else (0.65 if layer==2 else 0.0))).normalized()
			vertices.append_array(PackedVector3Array([Vector3(low_a.x,heights[layer],low_a.y),Vector3(low_b.x,heights[layer],low_b.y),Vector3(high_b.x,heights[layer+1],high_b.y),Vector3(low_a.x,heights[layer],low_a.y),Vector3(high_b.x,heights[layer+1],high_b.y),Vector3(high_a.x,heights[layer+1],high_a.y)]))
			for _vertex in range(6):
				normals.append(normal)
				colors.append(Color("d5cebb") if layer==1 else Color("f7f2e6"))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

static func _svg_shell() -> String:
	return '<svg xmlns="http://www.w3.org/2000/svg" width="210" height="304" viewBox="0 0 210 304">'

static func _front_svg(id: String) -> String:
	var parts := id.split(":")
	var joker := parts.size() < 3 or parts[0] == "J"
	var suit := "S" if joker else parts[1]
	var rank := 0 if joker else int(parts[2])
	var ink := "#aa352f" if suit in ["H", "D"] else "#182e2c"
	if joker:
		ink = "#9a773b"
	var label := "*" if joker else str(rank)
	match rank:
		1: label = "A"
		11: label = "V"
		12: label = "D"
		13: label = "R"
	var svg := _svg_shell()
	svg += '<defs><linearGradient id="paper" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#fffdf5"/><stop offset="0.7" stop-color="#f6f2e7"/><stop offset="1" stop-color="#e9e1ce"/></linearGradient></defs>'
	svg += '<rect x="0" y="0" width="210" height="304" rx="13" fill="url(#paper)"/>'
	svg += '<rect x="2" y="2" width="206" height="300" rx="11" fill="none" stroke="#ffffff" stroke-opacity="0.75" stroke-width="1"/>'
	svg += '<rect x="7" y="7" width="196" height="290" rx="8" fill="none" stroke="#dcd3bf" stroke-width="0.8"/>'
	for rotation in [0, 180]:
		svg += '<g transform="rotate(%s 105 152)">' % rotation
		svg += '<g transform="translate(13 12) scale(1.15)">%s</g>' % _rank_paths(label, ink)
		svg += _suit_path(suit, 30, 75, 13, ink) if not joker else _star(30, 75, 12, ink)
		svg += '</g>'
	if joker:
		svg += '<circle cx="105" cy="152" r="45" fill="none" stroke="#c6a45c" stroke-width="1.7"/>'
		svg += _star(105, 152, 37, ink)
		svg += '<circle cx="105" cy="152" r="12" fill="#f9f5e9"/>'
		svg += _suit_path("D", 105, 152, 9, ink)
	elif rank > 10:
		svg += _court_art(rank,suit,ink)
	else:
		var pips := _pip_positions(rank)
		for pip in pips:
			var size := 30.0 if rank == 1 else 18.0
			svg += _suit_path(suit, pip.x, pip.y, size, ink)
	svg += '</svg>'
	return svg

static func _court_art(rank: int, suit: String, ink: String) -> String:
	var svg := '<g transform="translate(105 152) scale(1.1 1.18) translate(-105 -152)"><rect x="53" y="85" width="104" height="134" rx="3" fill="#f0e5ca" stroke="#b49354" stroke-width="1.2"/>'
	svg += '<rect x="57" y="89" width="96" height="126" fill="none" stroke="%s" stroke-width="0.7"/>' % ink
	for rotation in [0,180]:
		svg += '<g transform="rotate(%d 105 152)">' % rotation
		# A mirrored court portrait, with the classic two-ended card composition.
		svg += '<path d="M63 152L72 134L91 127H118L138 139L148 152Z" fill="%s"/>' % ink
		svg += '<path d="M74 152L85 131L94 136L87 152ZM113 132L126 136L139 152H122Z" fill="#c3a35f"/>'
		svg += '<path d="M95 127L102 140L112 128L120 152H88Z" fill="#f4ead0" stroke="#927b50" stroke-width="0.7"/>'
		svg += '<path d="M90 110C87 119 91 128 101 131L111 125L116 114L111 105L96 104Z" fill="#dfc491" stroke="#5f5141" stroke-width="0.9"/>'
		svg += '<path d="M106 112L112 114L109 119L113 120L109 123M99 112L103 111M97 110L100 116" fill="none" stroke="#55483b" stroke-width="1"/>'
		if rank==13:
			svg += '<path d="M88 108L84 95L95 99L103 91L111 99L121 94L118 108Z" fill="#c8a254" stroke="#6d593a" stroke-width="0.8"/>'
			svg += '<path d="M95 122L102 127L111 123L108 133L98 131Z" fill="#5d4939"/>'
			svg += '<path d="M131 148L131 109M126 115H136" stroke="#cba75d" stroke-width="2.2"/>'
		elif rank==12:
			svg += '<path d="M89 126C78 118 81 100 94 98L110 99L119 108L114 115L108 106L94 108Z" fill="#6d4b39"/>'
			svg += '<path d="M87 103L91 96L99 100L106 94L114 101" fill="none" stroke="#cba75d" stroke-width="2.4"/>'
			svg += '<path d="M132 148L131 127M131 133L125 128M131 137L137 131" stroke="#6c7c50" stroke-width="1.3"/>'
			svg += _suit_path("D",131,122,5,ink)
		else:
			svg += '<path d="M86 109L85 102L95 95L113 100L121 110Z" fill="%s" stroke="#6d593a" stroke-width="0.8"/>' % ink
			svg += '<path d="M93 101C82 94 84 90 90 91L99 102" fill="#cba75d"/>'
			svg += '<path d="M131 149L132 109L136 116L132 123" fill="none" stroke="#ad915c" stroke-width="1.8"/>'
		svg += _suit_path(suit,70,115,6,ink)
		svg += '<path d="M61 151H149" stroke="#b49354" stroke-width="0.8"/></g>'
	return svg + '</g>'

static func _pip_positions(rank: int) -> Array[Vector2]:
	var pips: Array[Vector2] = []
	if rank == 1:
		return [Vector2(105, 152)]
	if rank <= 3:
		pips = [Vector2(105, 92), Vector2(105, 212)]
		if rank == 3: pips.append(Vector2(105, 152))
		return pips
	var top_y := 90.0
	var bottom_y := 214.0
	pips = [Vector2(69, top_y), Vector2(141, top_y), Vector2(69, bottom_y), Vector2(141, bottom_y)]
	if rank in [5, 7, 9]:
		pips.append(Vector2(105, 152))
	if rank >= 6:
		pips.append(Vector2(69, 152))
		pips.append(Vector2(141, 152))
	if rank == 8:
		pips.append(Vector2(105, 121))
		pips.append(Vector2(105, 183))
	if rank >= 9:
		# Four rows for nine and ten cards.
		pips = [Vector2(69, 87), Vector2(141, 87), Vector2(69, 130), Vector2(141, 130), Vector2(69, 174), Vector2(141, 174), Vector2(69, 217), Vector2(141, 217)]
		if rank == 9:
			pips.append(Vector2(105, 152))
		else:
			pips.append(Vector2(105, 108))
			pips.append(Vector2(105, 195))
	return pips

static func _suit_path(suit: String, x: float, y: float, size: float, ink: String) -> String:
	var path := ""
	match suit:
		"H": path = "M0 0.88C-0.28 0.55 -1 -0.02 -1 -0.53C-1 -1.2 -0.26 -1.3 0 -0.76C0.26 -1.3 1 -1.2 1 -0.53C1 -0.02 0.28 0.55 0 0.88Z"
		"D": path = "M0 -1.15L0.86 0L0 1.15L-0.86 0Z"
		"C": path = "M-0.16 0.3C-0.62 0.9 -1.24 0.46 -1 0C-0.85 -0.33 -0.44 -0.34 -0.3 -0.21C-0.97 -1.28 0.97 -1.28 0.3 -0.21C0.44 -0.34 0.85 -0.33 1 0C1.24 0.46 0.62 0.9 0.16 0.3L0.15 0.58L0.48 1H-0.48L-0.15 0.58Z"
		_: path = "M0 -1.08C-0.29 -0.68 -1.1 -0.07 -1 0.35C-0.83 0.95 -0.27 0.79 -0.12 0.38L-0.14 0.69L-0.48 1H0.48L0.14 0.69L0.12 0.38C0.27 0.79 0.83 0.95 1 0.35C1.1 -0.07 0.29 -0.68 0 -1.08Z"
	return '<path d="%s" transform="translate(%s %s) scale(%s)" fill="%s"/>' % [path, x, y, size, ink]

static func _star(x: float, y: float, size: float, ink: String) -> String:
	return '<path d="M0 -1L0.25 -0.25L1 0L0.25 0.25L0 1L-0.25 0.25L-1 0L-0.25 -0.25Z" transform="translate(%s %s) scale(%s)" fill="%s"/>' % [x, y, size, ink]

static func _rank_paths(label: String, ink: String) -> String:
	var glyphs := {
		"0": "M9 0C-3 0 -3 34 9 34C21 34 21 0 9 0Z",
		"1": "M3 6L10 0V34M2 34H18",
		"2": "M1 7C2 -3 19 -3 19 7C19 15 1 20 1 34H20",
		"3": "M1 2C11 -3 20 0 20 8C20 13 16 17 8 17C17 17 21 20 21 27C21 35 8 38 0 32",
		"4": "M16 34V0L0 24H23",
		"5": "M21 0H2L1 17C12 12 22 16 22 25C22 35 8 38 0 31",
		"6": "M19 1C6 -4 0 9 0 22C0 39 23 39 23 24C23 12 7 10 1 22",
		"7": "M0 0H23L7 34",
		"8": "M11 17C-3 16 -3 0 11 0C25 0 25 16 11 17C-5 18 -4 35 11 35C26 35 27 18 11 17Z",
		"9": "M2 33C16 40 23 24 23 12C23 -4 0 -4 0 11C0 24 17 25 23 12",
		"A": "M0 34L12 0L25 34M5 23H20",
		"V": "M0 0L12 34L25 0",
		"D": "M0 0V34H8C29 34 29 0 8 0Z",
		"R": "M0 34V0H10C28 0 28 17 10 17H0M10 17L26 34",
		"*": "M12 0V34M0 8L25 26M0 26L25 8"
	}
	var result := '<g fill="none" stroke="%s" stroke-width="3.2" stroke-linecap="round" stroke-linejoin="round">' % ink
	var offset := 0
	for letter in label:
		result += '<path d="%s" transform="translate(%s 0)"/>' % [glyphs.get(letter, glyphs["*"]), offset]
		offset += 28
	result += '</g>'
	return result

static func _back_svg() -> String:
	var svg := _svg_shell()
	svg += '<defs><linearGradient id="back" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#194948"/><stop offset="0.55" stop-color="#103536"/><stop offset="1" stop-color="#082b2e"/></linearGradient></defs>'
	svg += '<rect width="210" height="304" rx="13" fill="#f7f1e1"/>'
	svg += '<rect x="3" y="3" width="204" height="298" rx="11" fill="none" stroke="#d7cdb6" stroke-width="1"/>'
	svg += '<rect x="9" y="9" width="192" height="286" rx="7" fill="url(#back)"/>'
	svg += '<rect x="16" y="16" width="178" height="272" rx="4" fill="none" stroke="#bda775" stroke-width="1.2"/>'
	svg += '<rect x="20" y="20" width="170" height="264" rx="3" fill="none" stroke="#6e8c7f" stroke-width="0.6"/>'
	# Fine diagonal engraving is symmetric under a half-turn, as on a real deck.
	for row in range(12):
		for column in range(7):
			var x := 30 + column*25
			var y := 31 + row*22
			if x <=181 and y <=275:
				svg += '<path d="M0 -9L9 0L0 9L-9 0ZM0 -5L5 0L0 5L-5 0Z" transform="translate(%d %d)" fill="none" stroke="#729181" stroke-opacity="0.57" stroke-width="0.65"/>' % [x,y]
	for rotation in [0,180]:
		svg += '<g transform="rotate(%d 105 152)"><path d="M29 48C29 28 49 27 52 36C54 45 41 47 40 40M29 58V28H60" fill="none" stroke="#c0a875" stroke-width="1.1"/>' % rotation
		svg += '<path d="M181 48C181 28 161 27 158 36C156 45 169 47 170 40M181 58V28H150" fill="none" stroke="#c0a875" stroke-width="1.1"/></g>'
	svg += '<path d="M105 110L140 132V172L105 194L70 172V132Z" fill="#103536" stroke="#bda775" stroke-width="1.2"/>'
	svg += '<path d="M105 117L134 135V169L105 187L76 169V135Z" fill="none" stroke="#6e8c7f" stroke-width="0.7"/>'
	svg += _star(105,152,24,"#c1aa76")
	svg += '<circle cx="105" cy="152" r="8" fill="#163c3d" stroke="#c1aa76" stroke-width="0.8"/>'
	svg += '</svg>'
	return svg
