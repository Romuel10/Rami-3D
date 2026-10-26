extends SceneTree
var scene
func _initialize() -> void:
	call_deferred("_capture")
func _frames(count: int = 12) -> void:
	for _i in range(count):
		await process_frame
	await RenderingServer.frame_post_draw
func _save(name: String) -> void:
	root.get_texture().get_image().save_png("res://builds/" + name + ".png")
	print("Captured ", name)
func _capture() -> void:
	scene = load("res://main.tscn").instantiate()
	root.add_child(scene)
	scene.saved_name = "Vous"
	scene.name_input.text = "Vous"
	await _frames()
	_save("menu")
	scene._start_solo()
	await _frames()
	_save("game")
	scene._show_rules()
	await _frames()
	_save("rules")
	scene._close_overlay()
	scene._show_friends(false)
	await _frames()
	_save("friends-wifi")
	scene._close_overlay()
	scene._show_friends(true)
	await _frames()
	_save("friends-internet")
	scene._close_overlay()
	scene._show_menu()
	scene._show_friends(false)
	scene._create_room()
	await _frames()
	_save("lobby")
	scene._leave_to_menu()
	quit(0)
