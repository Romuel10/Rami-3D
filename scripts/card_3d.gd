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
	var paper := StandardMaterial3D.new()
	paper.albedo_color = IVORY
	paper.roughness = 0.92
	body.material_override = paper
	_visual.add_child(body)
	_outline = MeshInstance3D.new()
	_outline.name = "SelectionBorder"
	_outline.mesh = _body_mesh
	_outline.scale = Vector3(1.065, 0.7, 1.045)
	_outline.position.y = -0.008
	var gold := StandardMaterial3D.new()
	gold.albedo_color = GOLD
	gold.metallic = 0.45
	gold.roughness = 0.38
	gold.emission_enabled = true
	gold.emission = Color("9b773a")
	gold.emission_energy_multiplier = 0.16
	_outline.material_override = gold
	_outline.visible = selected
	_visual.add_child(_outline)
	_face = MeshInstance3D.new()
	_face.name = "PrintedFace"
	var quad := QuadMesh.new()
	quad.size = Vector2(CARD_WIDTH, CARD_LENGTH)
	_face.mesh = quad
	_face.rotation.x = -PI / 2.0
	_face.position.y = CARD_DEPTH / 2.0 + 0.001
	_face.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_visual.add_child(_face)
	var back := MeshInstance3D.new()
	back.name = "PrintedBack"
	back.mesh = quad
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
	var shape := BoxShape3D.new()
	shape.size = Vector3(CARD_WIDTH, 0.09, CARD_LENGTH)
	collision.shape = shape
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
	material.roughness = 0.94
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
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
	var top := CARD_DEPTH / 2.0
	for i in range(points.size()):
		var a := points[i]
		var b := points[(i + 1) % points.size()]
		# Godot's front faces wind clockwise when seen from outside.
		vertices.append_array(PackedVector3Array([Vector3(0, top, 0), Vector3(a.x, top, a.y), Vector3(b.x, top, b.y)]))
		normals.append_array(PackedVector3Array([Vector3.UP, Vector3.UP, Vector3.UP]))
		vertices.append_array(PackedVector3Array([Vector3(0, -top, 0), Vector3(b.x, -top, b.y), Vector3(a.x, -top, a.y)]))
		normals.append_array(PackedVector3Array([Vector3.DOWN, Vector3.DOWN, Vector3.DOWN]))
		var side_normal := Vector3(a.x + b.x, 0, a.y + b.y).normalized()
		vertices.append_array(PackedVector3Array([Vector3(a.x, -top, a.y), Vector3(b.x, -top, b.y), Vector3(b.x, top, b.y), Vector3(a.x, -top, a.y), Vector3(b.x, top, b.y), Vector3(a.x, top, a.y)]))
		for _j in range(6):
			normals.append(side_normal)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
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
	var ink := "#ba443d" if suit in ["H", "D"] else "#193937"
	if joker:
		ink = "#9a773b"
	var label := "*" if joker else str(rank)
	match rank:
		1: label = "A"
		11: label = "V"
		12: label = "D"
		13: label = "R"
	var svg := _svg_shell()
	svg += '<rect x="0" y="0" width="210" height="304" rx="13" fill="#f9f5e9"/>'
	svg += '<rect x="7" y="7" width="196" height="290" rx="8" fill="none" stroke="#e8dfca" stroke-width="1"/>'
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
		svg += '<rect x="54" y="87" width="102" height="130" rx="5" fill="none" stroke="#d1b06e" stroke-width="1.6"/>'
		svg += '<path d="M70 134L68 111L86 123L105 101L124 123L142 111L140 134Z" fill="#c8a461"/>'
		svg += _suit_path(suit, 105, 171, 29, ink)
		svg += '<path d="M81 205H129" stroke="#c8a461" stroke-width="2"/>'
	else:
		var pips := _pip_positions(rank)
		for pip in pips:
			var size := 30.0 if rank == 1 else 18.0
			svg += _suit_path(suit, pip.x, pip.y, size, ink)
	svg += '</svg>'
	return svg

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
	svg += '<rect width="210" height="304" rx="13" fill="#f9f5e9"/>'
	svg += '<rect x="8" y="8" width="194" height="288" rx="8" fill="#174e4b"/>'
	svg += '<rect x="16" y="16" width="178" height="272" rx="5" fill="none" stroke="#c5a46b" stroke-width="1.4"/>'
	for row in range(10):
		for column in range(6):
			var x := 24 + column * 32 + (16 if row % 2 else 0)
			var y := 20 + row * 29
			if x < 190:
				svg += '<path d="M0 -11L8 0L0 11L-8 0Z" transform="translate(%s %s)" fill="none" stroke="#6b907c" stroke-width="0.8"/>' % [x, y]
	svg += '<circle cx="105" cy="152" r="34" fill="#174e4b" stroke="#c5a46b" stroke-width="1.4"/>'
	svg += _star(105, 152, 22, "#c5a46b")
	svg += '</svg>'
	return svg
