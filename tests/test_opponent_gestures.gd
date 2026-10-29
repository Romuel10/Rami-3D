extends SceneTree
## Public-action gestures are bounded, retain meshes, and respect reduced motion.
const Table = preload("res://scripts/table_scene.gd")
var checks := 0
var failures: Array[String] = []
var table
func _init() -> void: call_deferred("_run")
func _preview_scene() -> void:
	if DisplayServer.get_name()=="headless": return
	root.size = Vector2i(1440,900)
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 11.8
	camera.keep_aspect = Camera3D.KEEP_HEIGHT
	camera.position = Vector3(0,14,10.5)
	root.add_child(camera)
	camera.look_at(Vector3(0,0,.35))
	camera.current = true
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color("151b18")
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color("cbd2ce")
	environment.ambient_light_energy = .4
	var world := WorldEnvironment.new()
	world.environment = environment
	root.add_child(world)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-62,-22,0)
	light.light_color = Color("fff1d4")
	light.light_energy = .53
	light.shadow_enabled = true
	root.add_child(light)
func _capture(label: String) -> void:
	if DisplayServer.get_name()=="headless": return
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://builds/opponent-gesture-"+label+".png")
func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures.append(message)
		push_error("FAIL: "+message)
func arms_rest(player: int) -> bool:
	var seat: Node3D = table._seats[player]
	for name_value in ["LeftArm","RightArm"]:
		var arm: Node3D = seat.get_node("Sleeves/"+name_value)
		if not arm.transform.is_equal_approx(arm.get_meta("rest_transform")): return false
	return true
func all_rest() -> bool:
	for player in table._seats:
		if not arms_rest(player): return false
	return true
func _run() -> void:
	_preview_scene()
	table = Table.new()
	root.add_child(table)
	var players: Array = [{"name":"Vous","count":13},{"name":"Camille","count":13},{"name":"Alex","count":13},{"name":"Charlie","count":13}]
	table.set_players(players,0,0)
	var ids: Array = []
	for mesh in table.find_children("*","MeshInstance3D",true,false): ids.append(mesh.get_instance_id())
	check(table._seats.size()==3 and all_rest(),"initial seated opponents rest naturally")
	check(table._gestures.is_empty(),"own turn does not start opponent gestures")
	table.animate_action(-1,"draw")
	table.animate_action(0,"draw")
	table.animate_action(1,"invented")
	check(table._gestures.is_empty(),"invalid player, own seat and unknown action are ignored")
	table.set_players(players,0,1)
	check(table.is_gesturing(1),"opponent turn starts one small thinking gesture")
	var thinking: Tween = table._gestures[1]
	var sequence: int = table._gesture_serials[1]
	await create_timer(.14).timeout
	check(not arms_rest(1),"thinking passes through a visible intermediate pose")
	check(arms_rest(2) and arms_rest(3),"unrelated opponents remain still")
	await _capture("think")
	table.set_players(players,0,1)
	check(table._gestures[1]==thinking and table._gesture_serials[1]==sequence,"repeated snapshots do not restart the thinking gesture")
	await create_timer(.7).timeout
	check(not table.is_gesturing(1) and arms_rest(1),"thinking ends and returns exactly to rest")
	await create_timer(.2).timeout
	check(table._gestures.is_empty(),"no perpetual idle animation remains")
	for kind in ["draw","discard","meld","extend"]:
		table.animate_action(1,kind)
		check(table.is_gesturing(1),kind+" starts a public-action gesture")
		await create_timer(.16).timeout
		check(not arms_rest(1),kind+" moves forearm and hand through an intermediate pose")
		if kind in ["draw","discard"]: await _capture(kind)
		for arm_name in ["LeftArm","RightArm"]:
			var arm: Node3D = table._seats[1].get_node("Sleeves/"+arm_name)
			check(arm.rotation.length()<.6,kind+" stays within a natural elbow reach")
		var ongoing: Tween = table._gestures[1]
		table.animate_action(1,kind)
		check(table._gestures[1]==ongoing,kind+" duplicate cannot restart an in-progress motion")
		await create_timer(.65).timeout
		check(arms_rest(1) and not table.is_gesturing(1),kind+" returns to its original transform")
	# A draw from each public pile reaches with the nearer hand.
	for source in ["deck","discard"]:
		table.animate_action(2,"draw",source)
		await create_timer(.22).timeout
		check(not arms_rest(2),"drawing from "+source+" animates a reach")
		table.set_motion_enabled(false)
		check(arms_rest(2) and table._gestures.is_empty(),"reduced motion cancels and restores "+source+" reach immediately")
		table.animate_action(2,"discard")
		check(arms_rest(2) and table._gestures.is_empty(),"motion-disabled actions do not create tweens")
		table.set_motion_enabled(true)
	# Fast actions keep the current reach rather than teleporting both hands.
	table.animate_action(1,"draw")
	await create_timer(.15).timeout
	var before_interrupt: Dictionary = {}
	for arm_name in ["LeftArm","RightArm"]:
		before_interrupt[arm_name] = table._seats[1].get_node("Sleeves/"+arm_name).transform
	table.animate_action(1,"discard")
	for arm_name in before_interrupt:
		check(table._seats[1].get_node("Sleeves/"+arm_name).transform.is_equal_approx(before_interrupt[arm_name]),"new action starts from the visible hand pose")
	await create_timer(.8).timeout
	check(arms_rest(1) and not table.is_gesturing(1),"interrupted reach still finishes at the exact resting pose")
	table.animate_action(3,"discard")
	await create_timer(.10).timeout
	players[3]["forfeited"] = true
	table.set_players(players,0,3)
	check(not table.is_gesturing(3) and arms_rest(3),"forfeit stops and restores an active gesture")
	check(not table._seats[3].get_node("Sleeves").visible,"forfeited opponent has no floating hand")
	table.animate_action(3,"draw")
	check(not table.is_gesturing(3),"absent opponent cannot animate")
	table.set_motion_enabled(false)
	var current_ids: Array = []
	for mesh in table.find_children("*","MeshInstance3D",true,false): current_ids.append(mesh.get_instance_id())
	check(current_ids==ids,"all gestures reuse the same table, hands and meshes")
	check(table.find_children("*","CollisionObject3D",true,false).is_empty(),"gestures add no collisions or private card data")
	table.set_motion_enabled(true)
	table.animate_action(1,"draw")
	table.set_players(players.slice(0,2),0,0)
	check(table._gestures.is_empty() and table._seats.size()==1 and all_rest(),"new seating layout cancels old gestures and starts at rest")
	table.animate_action(1,"discard")
	table.clear_seats()
	check(table._seats.is_empty() and table._gestures.is_empty() and table.seating.get_child_count()==0,"leaving removes rigs and cancels every gesture")
	table.queue_free()
	await process_frame
	print("RESULT: %d opponent gesture checks; %d failures"%[checks,failures.size()])
	quit(0 if failures.is_empty() else 1)
