extends SceneTree

const Card = preload("res://scripts/card_3d.gd")
var taps := 0

func _initialize() -> void:
	call_deferred("_run")

func _touch() -> InputEventScreenTouch:
	var event := InputEventScreenTouch.new()
	event.pressed = true
	return event

func _mouse(emulated: bool) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	event.device = InputEvent.DEVICE_ID_EMULATION if emulated else 0
	return event

func _dispatch(card: Node3D, event: InputEvent) -> void:
	card._on_input_event(null, event, Vector3.ZERO, Vector3.UP, 0)

func _run() -> void:
	var card = Card.new()
	root.add_child(card)
	card.tapped.connect(func(_card): taps += 1)
	_dispatch(card, _touch())
	_dispatch(card, _mouse(true))
	assert(taps == 1, "Touch plus emulated mouse must emit once")
	_dispatch(card, _mouse(false))
	assert(taps == 2, "Physical mouse must remain responsive after touch")
	_dispatch(card, _touch())
	_dispatch(card, _mouse(true))
	assert(taps == 3, "A successive direct touch must remain responsive")
	await create_timer(0.18).timeout
	_dispatch(card, _touch())
	_dispatch(card, _mouse(true))
	assert(taps == 4, "The next later physical touch must emit once")
	var mouse_first = Card.new()
	root.add_child(mouse_first)
	mouse_first.tapped.connect(func(_card): taps += 1)
	_dispatch(mouse_first, _mouse(true))
	_dispatch(mouse_first, _touch())
	assert(taps == 5, "Mouse-first emulation must also emit once")
	_dispatch(mouse_first, _mouse(true))
	assert(taps == 6, "Synthetic-mouse-only picking must remain responsive")
	_dispatch(mouse_first, _touch())
	assert(taps == 6, "Its corresponding direct touch must be suppressed")
	var release := _touch()
	release.pressed = false
	_dispatch(card, release)
	var right_click := _mouse(false)
	right_click.button_index = MOUSE_BUTTON_RIGHT
	_dispatch(card, right_click)
	assert(taps == 6, "Releases and right clicks must not emit taps")
	print("PASS: card touch/mouse emulation deduplication (both event orders, rapid presses, later tap, physical mouse, fallback, releases)")
	quit(0)
