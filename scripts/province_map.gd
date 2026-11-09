extends Control

signal province_chosen(province: String)

const Profile = preload("res://scripts/player_profile.gd")
const DATA := "res://assets/maps/madagascar-provinces.json"
const COLORS := [Color("548c86"), Color("78925b"), Color("a16b52"), Color("a38856"), Color("587e98"), Color("a2646b")]
const SEA := Color("162d2e")
const COAST := Color("203638")
const LIGHT := Color("f5e5be")

var selected := ""
var animate := true
var _atlas: Dictionary = {}
var _rings: Dictionary = {}
var _markers: Dictionary = {}
var _hovered := ""
var _pulse := 1.0
var _highlight: Tween

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(DATA))
	if parsed is Dictionary:
		_atlas = parsed
	resized.connect(_fit_map)
	mouse_exited.connect(_set_hover.bind(""))
	_fit_map()

func choose(province: String, pulse: bool = true) -> void:
	if not province in Profile.PROVINCES or province == selected: return
	selected = province
	if _highlight != null: _highlight.kill()
	_set_pulse(1.0)
	if animate and pulse:
		_set_pulse(0.0)
		_highlight = create_tween().set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		_highlight.tween_method(_set_pulse, 0.0, 1.0, 0.45)
	province_chosen.emit(province)

func marker_position(province: String) -> Vector2:
	return _markers.get(province, Vector2.ZERO)

func province_at(point: Vector2) -> String:
	for province in _rings:
		for ring: PackedVector2Array in _rings[province]:
			if Geometry2D.is_point_in_polygon(point, ring): return province
	return ""

func _fit_map() -> void:
	_rings.clear()
	_markers.clear()
	if _atlas.is_empty(): return
	var aspect := float(_atlas.aspect)
	var height := maxf(1.0, minf(size.y - 80.0, (size.x - 56.0) / aspect))
	var origin := Vector2((size.x - height * aspect) * 0.5, (size.y - height) * 0.5 + 11.0)
	for province in Profile.PROVINCES:
		var shape: Dictionary = _atlas.provinces[province]
		var rings: Array[PackedVector2Array] = []
		for coords: Array in shape.rings:
			var ring := PackedVector2Array()
			for point: Array in coords:
				ring.append(origin + Vector2(point[0], point[1]) * height)
			rings.append(ring)
		_rings[province] = rings
		_markers[province] = origin + Vector2(shape.marker[0], shape.marker[1]) * height
	queue_redraw()

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_set_hover(province_at(event.position))
	elif (event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed) or (event is InputEventScreenTouch and event.pressed):
		var province := province_at(event.position)
		if not province.is_empty():
			choose(province)
			accept_event()

func _set_hover(province: String) -> void:
	if province == _hovered: return
	_hovered = province
	mouse_default_cursor_shape = CURSOR_POINTING_HAND if not province.is_empty() else CURSOR_ARROW
	queue_redraw()

func _set_pulse(value: float) -> void:
	_pulse = value
	queue_redraw()

func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), SEA)
	var grid := Color(0.57, 0.72, 0.65, 0.12)
	for i in range(1, 8):
		var x := size.x * i / 8.0
		draw_line(Vector2(x, 0), Vector2(x, size.y), grid)
	for i in range(1, 7):
		var y := size.y * i / 7.0
		draw_line(Vector2(0, y), Vector2(size.x, y), grid)
	var font := get_theme_default_font()
	draw_string(font, Vector2(18, 31), "MADAGASCAR", HORIZONTAL_ALIGNMENT_LEFT, -1, 18, LIGHT)
	draw_string(font, Vector2(18, 51), "Les six provinces", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color("adbbb2"))
	draw_string(font, Vector2(size.x - 37, 31), "N", HORIZONTAL_ALIGNMENT_LEFT, -1, 15, LIGHT)
	draw_colored_polygon(PackedVector2Array([Vector2(size.x-32, 37), Vector2(size.x-39, 56), Vector2(size.x-25, 56)]), LIGHT)
	for index in range(Profile.PROVINCES.size()):
		var province: String = Profile.PROVINCES[index]
		var fill: Color = COLORS[index]
		if province == selected: fill = fill.lerp(LIGHT, 0.34)
		elif province == _hovered: fill = fill.lightened(0.15)
		for ring: PackedVector2Array in _rings.get(province, []):
			draw_colored_polygon(ring, fill)
			if province != selected: _draw_outline(ring, COAST, 1.4)
	for ring: PackedVector2Array in _rings.get(selected, []):
		_draw_outline(ring, LIGHT, 2.8)
	for index in range(Profile.PROVINCES.size()):
		var province: String = Profile.PROVINCES[index]
		if not _markers.has(province): continue
		var center := marker_position(province)
		var chosen := province == selected
		if chosen and _pulse < 1.0:
			draw_arc(center, 16.0 + _pulse * 20.0, 0, TAU, 36, Color(LIGHT, 1.0 - _pulse), 2.0, true)
		draw_circle(center, 13.0, LIGHT if chosen else SEA, true, -1.0, true)
		draw_circle(center, 13.0, LIGHT, false, 1.2, true)
		draw_string(font, center + Vector2(-11, 5), str(index + 1), HORIZONTAL_ALIGNMENT_CENTER, 22, 15, SEA if chosen else LIGHT)
	draw_string(font, Vector2(18, size.y - 16), "Contours simplifiés · Natural Earth", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("b1bdb0"))

func _draw_outline(ring: PackedVector2Array, color: Color, width: float) -> void:
	var closed := ring.duplicate()
	closed.append(ring[0])
	draw_polyline(closed, color, width, true)
