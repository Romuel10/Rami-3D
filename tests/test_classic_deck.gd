extends SceneTree
## Imported illustrations, shared 2D/3D identity, privacy and physical layering.
const Card = preload("res://scripts/card_3d.gd")
const Main = preload("res://main.tscn")
var checks := 0
var failures := 0

func _init() -> void: call_deferred("_run")
func check(value: bool, message: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error(message)

func _run() -> void:
	var atlas := Card.atlas_texture()
	check(atlas.get_width()<=4096 and atlas.get_height()<=4096,"atlas fits the supported mobile texture bound")
	var regions: Array[Rect2] = []
	for suit in ["S","H","D","C"]:
		for rank in range(1,14):
			var id := "0:%s:%d"%[suit,rank]
			var face = Card.texture_for(id)
			check(face is AtlasTexture and face.atlas==atlas,"every physical rank uses a retrieved illustration")
			check(not face.region in regions,"each of the 52 suit/rank illustrations is distinct")
			regions.append(face.region)
			check(Card.texture_for("1:%s:%d"%[suit,rank])==face,"the second deck reuses the same illustration")
			check(face.region.size==Vector2(256,384) and Rect2(Vector2.ZERO,Vector2(atlas.get_size())).encloses(face.region),"indices stay inside their own padded texture region")
	check(Card.texture_for("J:0")!=Card.texture_for("J:1"),"both illustrated joker colours are present")
	check(Card.texture_for("J:0")==Card.texture_for("J:2") and Card.texture_for("J:1")==Card.texture_for("J:3"),"four physical jokers retain the two original illustrations")
	check(Card.texture_for("0:S:13",false)==Card.texture_for("0:H:12",false),"hidden opponents always receive the same back")
	check(FileAccess.file_exists("res://assets/cards/LICENSE.txt"),"source and adaptation credits are included")
	var app = Main.instantiate()
	root.add_child(app)
	await process_frame
	app._set_fullscreen(false,false)
	app.animations_enabled = false
	app._apply_comfort()
	app.network.local_player = 0
	var hand := ["0:S:13","0:S:12","0:S:11","0:H:1","0:D:10","0:C:8","0:H:13","0:H:12","0:H:11","0:C:11","0:C:12","0:C:13","0:D:11"]
	app._network_game_updated({"your_index":0,"turn":0,"phase":"draw","winner":-1,"players":[{"name":"Vous","count":13},{"name":"Camille","count":13},{"name":"Alex","count":13},{"name":"Charlie","count":13}],"hand":hand,"deck_count":55,"discard_top":"J:0","melds":[],"turn_count":1,"session_id":"classic-preview","revision":0})
	app.header_status.text = "Rami · 4 joueurs"
	var table: Node3D = app.table_scene
	var felt: MeshInstance3D = table.get_node("FeltSurface")
	var leather: MeshInstance3D = table.get_node("LeatherRail")
	check(felt.position.y+felt.mesh.height*.5>leather.position.y+leather.mesh.height*.5,"felt is above the solid leather support and actually visible")
	var stock: Node3D = app.hand_cards[0]
	var print_material: StandardMaterial3D = stock.get_node("Paper/PrintedFace").material_override
	var crop := Card.artwork_region(Card.artwork_index(stock.card_id))
	check(print_material.albedo_texture==atlas,"3D cards share the same licensed deck as tutorials")
	check(print_material.uv1_offset.is_equal_approx(Vector3(crop.position.x/atlas.get_width(),crop.position.y/atlas.get_height(),0)),"3D UVs display the matching 2D face")
	for card in app.card_nodes:
		if card.get_meta("zone","")=="opponent":
			check(not card.face_up and card.get_node("Paper/PrintedFace").material_override==card.get_node("Paper/PrintedBack").material_override,"new artwork cannot expose a hidden opponent hand")
	if DisplayServer.get_name()!="headless":
		for size in [Vector2i(1440,900),Vector2i(2400,1080)]:
			root.size = size
			app._screen_changed()
			await create_timer(.25).timeout
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png("res://builds/classic-cards-%dx%d.png"%[size.x,size.y])
	app._leave_to_menu()
	app._show_credits()
	check(app.overlay.get_child_count()>0,"card source credits open from the actual game")
	app._close_overlay()
	app.queue_free()
	await process_frame
	print_material = null
	atlas = null
	await create_timer(.2).timeout
	print("CLASSIC DECK: %d checks; %d failures"%[checks,failures])
	quit(0 if failures==0 else 1)
