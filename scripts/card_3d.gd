class_name RamiCard3D
extends Node3D
## A physical, touchable card lying face-up in the local XZ plane.
## Classic licensed illustrations share one texture; no runtime fonts or downloads.

signal tapped(card: RamiCard3D)

const CARD_WIDTH := 1.05
const CARD_LENGTH := 1.52
const CARD_DEPTH := 0.026
const REST_HEIGHT := 0.15
const SELECTED_LIFT := 0.28
const IVORY := Color("fffdf2")
const GOLD := Color("d3ae65")

static var _textures: Dictionary = {}
static var _materials: Dictionary = {}
static var _body_mesh: ArrayMesh
static var _print_mesh: QuadMesh
static var _touch_shape: BoxShape3D
static var _paper_grain: ImageTexture
static var _atlas: Texture2D
const ATLAS_CELL := Vector2i(272,400)
const FACE_PIXELS := Vector2i(256,384)
const ATLAS_PADDING := 8
const SUIT_ROWS := {"S":0,"H":1,"D":2,"C":3}
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
	back.material_override = _art_material(54)
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
	_face.material_override = _art_material(artwork_index(card_id,face_up))

func _art_material(index: int) -> StandardMaterial3D:
	var key := "art:%d" % index
	if _materials.has(key): return _materials[key]
	var atlas := atlas_texture()
	var region := artwork_region(index)
	var dimensions := Vector2(atlas.get_size())
	var material := StandardMaterial3D.new()
	material.albedo_texture = atlas
	material.albedo_color = Color.WHITE
	material.uv1_scale = Vector3(region.size.x/dimensions.x,region.size.y/dimensions.y,1)
	material.uv1_offset = Vector3(region.position.x/dimensions.x,region.position.y/dimensions.y,0)
	material.roughness = 0.62
	material.metallic_specular = 0.24
	material.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	# A subtle fill preserves the small corner indices in the held fan.
	material.emission_enabled = true
	material.emission = Color.WHITE
	material.emission_texture = atlas
	material.emission_energy_multiplier = 0.025
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	material.alpha_scissor_threshold = 0.25
	material.texture_repeat = false
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
	material.roughness_texture = _grain_texture()
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

static func atlas_texture() -> Texture2D:
	if _atlas == null: _atlas = load("res://assets/cards/classic-atlas.png")
	return _atlas

static func artwork_index(id: String, shown: bool = true) -> int:
	if not shown: return 54
	var parts := id.split(":")
	if parts.size()==2 and parts[0]=="J" and parts[1] in ["0","1","2","3"]:
		return 52+int(parts[1])%2
	if parts.size()!=3 or not parts[0] in ["0","1"] or not SUIT_ROWS.has(parts[1]): return 54
	var rank := int(parts[2])
	if rank<1 or rank>13 or str(rank)!=parts[2]: return 54
	return int(SUIT_ROWS[parts[1]])*13+rank-1

static func artwork_region(index: int) -> Rect2:
	var safe_index := clampi(index,0,54)
	return Rect2(Vector2((safe_index%13)*ATLAS_CELL.x+ATLAS_PADDING,floori(float(safe_index)/13.0)*ATLAS_CELL.y+ATLAS_PADDING),Vector2(FACE_PIXELS))

static func texture_for(id: String, shown: bool = true) -> Texture2D:
	var index := artwork_index(id,shown)
	if not _textures.has(index):
		var texture := AtlasTexture.new()
		texture.atlas = atlas_texture()
		texture.region = artwork_region(index)
		texture.filter_clip = true
		_textures[index] = texture
	return _textures[index]
