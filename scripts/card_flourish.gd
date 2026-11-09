extends Control

const CardView = preload("res://scripts/card_3d.gd")
const SUITS := ["♠", "♥", "♣", "♦"]
const FACES := ["0:C:11", "0:H:12", "0:S:13"]

var victory := false
var accent := Color("ead19b")
var progress := 0.0

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip_contents = true
	var motion := create_tween()
	motion.tween_method(_advance, 0.0, 1.0, 1.08 if victory else 0.48)
	if not victory: motion.tween_callback(queue_free)

func _advance(value: float) -> void:
	progress = value
	queue_redraw()

func _draw() -> void:
	var center := size * Vector2(0.5, 0.54)
	var travel := 1.0 - pow(1.0 - progress, 3.0)
	var strength := (1.0 - progress) * minf(progress * 10.0, 1.0)
	if victory:
		var spread := ease(minf(progress * 2.6, 1.0), 0.25)
		for i in range(FACES.size()):
			var side := float(i - 1)
			draw_set_transform(center + Vector2(side * 37.0, absf(side) * 7.0) * spread, side * 0.28 * spread)
			draw_texture_rect(CardView.texture_for(FACES[i]), Rect2(-25, -38, 50, 75), false)
		draw_set_transform(Vector2.ZERO)
	else:
		draw_arc(center, 10.0 + 35.0 * travel, 0.0, TAU, 36, Color(accent, strength * 0.66), 2.0, true)
	if strength <= 0.0: return
	var font := get_theme_default_font()
	for i in range(16 if victory else 8):
		var angle := float(i) * 2.39996
		var distance := 21.0 + float(i % 5) * 6.0
		if victory: distance *= 2.1
		var drift := Vector2.from_angle(angle) * distance * travel
		var position_2d := center + drift * Vector2(1.0, 0.69)
		if victory:
			var pigment := Color("e7a898") if i % 2 else accent
			draw_string(font, position_2d, SUITS[i % SUITS.size()], HORIZONTAL_ALIGNMENT_LEFT, -1, 17, Color(pigment, strength))
		else:
			var points := PackedVector2Array([Vector2(0,-4), Vector2(3,0), Vector2(0,4), Vector2(-3,0)])
			for j in range(points.size()): points[j] += position_2d
			draw_colored_polygon(points, Color(accent, strength))
