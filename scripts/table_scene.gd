extends Node3D
## Static, shared materials and light meshes keep the salon inexpensive on mobile.
static var _materials: Dictionary = {}
var _seats: Dictionary = {}
var _seat_layout := ""
var seating: Node3D

func _ready() -> void:
	name = "TableScene"
	_build_table()
	seating = Node3D.new()
	seating.name = "Seating"
	add_child(seating)

func _surface(kind: String) -> StandardMaterial3D:
	if _materials.has(kind): return _materials[kind]
	var mat := StandardMaterial3D.new()
	mat.roughness = 0.88
	var image := Image.create(256,256,false,Image.FORMAT_RGB8)
	var noise := FastNoiseLite.new()
	noise.seed = 173
	noise.frequency = 0.065
	for y in range(256):
		for x in range(256):
			var grain := noise.get_noise_2d(x,y)
			var value := 0.0
			var color: Color
			if kind == "felt":
				value = grain*0.023 + (0.008 if (x+y)%2==0 else -0.008)
				color = Color(0.075+value*0.32,0.32+value,0.225+value*0.65)
			elif kind == "wood":
				var line := sin(float(x)*0.23 + noise.get_noise_2d(x*0.45,y*0.10)*5.0)
				value = line*0.035 + grain*0.026
				color = Color(0.19+value,0.093+value*0.57,0.043+value*0.30)
			elif kind == "leather":
				value = grain*0.022 + (0.005 if x%3==0 else 0.0)
				color = Color(0.065+value,0.086+value,0.071+value)
			else:
				value = grain*0.013
				color = Color(0.062+value,0.068+value,0.058+value)
			image.set_pixel(x,y,color)
	image.generate_mipmaps()
	mat.albedo_texture = ImageTexture.create_from_image(image)
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	mat.uv1_triplanar = true
	mat.uv1_triplanar_sharpness = 2.0
	mat.uv1_scale = Vector3.ONE * (5.0 if kind=="felt" else 0.6)
	if kind=="wood": mat.roughness = 0.42
	if kind=="leather": mat.roughness = 0.65
	_materials[kind] = mat
	return mat

func _plain(color: Color, roughness: float = 0.8, metal: float = 0.0) -> StandardMaterial3D:
	var key := str(color) + str(roughness) + str(metal)
	if _materials.has(key): return _materials[key]
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = roughness
	mat.metallic = metal
	_materials[key] = mat
	return mat

func _mesh(parent: Node3D, mesh: Mesh, material: Material, label: String, position_value: Vector3, scale_value: Vector3 = Vector3.ONE) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.name = label
	node.mesh = mesh
	node.material_override = material
	node.position = position_value
	node.scale = scale_value
	parent.add_child(node)
	return node

func _oval(label: String, radius: float, height: float, y: float, material: Material) -> void:
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = height
	mesh.radial_segments = 96
	_mesh(self,mesh,material,label,Vector3(0,y,0),Vector3(1,1,.68))

func _ring(label: String, radius: float, width: float, y: float, material: Material) -> void:
	var mesh := TorusMesh.new()
	mesh.inner_radius = radius-width
	mesh.outer_radius = radius+width
	mesh.rings = 96
	mesh.ring_segments = 8
	_mesh(self,mesh,material,label,Vector3(0,y,0),Vector3(1,.45,.68))

func _build_table() -> void:
	_oval("WoodBase",9.50,.65,-.55,_surface("wood"))
	_ring("RoundedWoodEdge",9.28,.22,-.27,_surface("wood"))
	_oval("BrassInlay",9.24,.035,-.16,_plain(Color("b08a4c"),.32,.72))
	_oval("LeatherRail",9.18,.21,-.08,_surface("leather"))
	_ring("PaddedRail",8.98,.22,.002,_surface("leather"))
	_oval("FeltSurface",8.74,.055,-.015,_surface("felt"))
	_ring("InnerSeam",8.61,.015,.024,_plain(Color("8a8965")))
	# Short stitches are one mesh, rather than hundreds of scene nodes.
	var stitch_mesh := ImmediateMesh.new()
	stitch_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for i in range(220):
		var angle := TAU*float(i)/220.0
		for offset in [-.004,.004]:
			stitch_mesh.surface_add_vertex(Vector3(cos(angle+offset)*9.035,.103,sin(angle+offset)*9.035*.68))
	stitch_mesh.surface_end()
	var stitch := _mesh(self,stitch_mesh,_plain(Color("776b4c")),"RailStitching",Vector3.ZERO)
	stitch.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var floor_mesh := PlaneMesh.new()
	floor_mesh.size = Vector2(120,120)
	_mesh(self,floor_mesh,_surface("carpet"),"SalonFloor",Vector3(0,-1.8,0))
	for side in [-1,1]:
		var leg := CylinderMesh.new()
		leg.top_radius = .25
		leg.bottom_radius = .36
		leg.height = 1.05
		_mesh(self,leg,_surface("wood"),"TableLeg",Vector3(side*5.7,-1.16,0))
	# Small embossed mark sits on the felt and follows its lighting.
	var brand := Label3D.new()
	brand.name = "FeltEmbossing"
	brand.text = "R A M I   S A L O N"
	brand.font = load("res://assets/serif.ttf")
	brand.font_size = 72
	brand.pixel_size = .007
	brand.modulate = Color(.42,.56,.44,.30)
	brand.outline_size = 0
	brand.rotation_degrees.x = -90
	brand.position = Vector3(0,.024,.65)
	add_child(brand)

static func seat_position(index: int, count: int) -> Vector3:
	if count <= 1: return Vector3(0,.72,-3.25)
	if count == 2: return Vector3(-4.5 if index==0 else 4.5,.72,-3.05)
	if index==1: return Vector3(0,.72,-3.55)
	return Vector3(-5.3 if index==0 else 5.3,.72,-2.55)

static func seat_yaw(index: int, count: int) -> float:
	if count<=1: return 0.0
	if count==3 and index==1: return 0.0
	return .58 if index==0 else -.58

func clear_seats() -> void:
	for seat in _seats.values(): seat.queue_free()
	_seats.clear()
	_seat_layout = ""

func set_players(players: Array, own: int, active: int) -> void:
	var opponents: Array = []
	for i in range(players.size()):
		if i!=own: opponents.append(i)
	var layout := str(opponents)
	if layout != _seat_layout:
		clear_seats()
		_seat_layout = layout
		for relative in range(opponents.size()):
			var index: int = opponents[relative]
			var seat := Node3D.new()
			seat.name = "PlayerSeat%d"%index
			seat.set_meta("seat_index",index)
			seat.position = seat_position(relative,opponents.size())
			seat.rotation.y = seat_yaw(relative,opponents.size())
			seating.add_child(seat)
			_build_player(seat,relative)
			_seats[index] = seat
	for index in _seats:
		var seat: Node3D = _seats[index]
		var tag: Label3D = seat.get_node("Nameplate")
		var player: Dictionary = players[index]
		tag.text = str(player.get("name","Joueur")) + "   ·   " + ("abandon" if player.get("forfeited",false) else str(int(player.get("count",13))) + " cartes")
		tag.modulate = Color("edce8f") if index==active else Color("bdc9bb")
		seat.get_node("Sleeves").visible = not player.get("forfeited",false)

func _ellipsoid(parent: Node3D, label: String, position_value: Vector3, scale_value: Vector3, material: Material) -> MeshInstance3D:
	var mesh := SphereMesh.new()
	mesh.radius = 1.0
	mesh.height = 2.0
	mesh.radial_segments = 16
	mesh.rings = 8
	return _mesh(parent,mesh,material,label,position_value,scale_value)

func _limb(parent: Node3D, label: String, start: Vector3, end: Vector3, width: float, material: Material) -> void:
	var mesh := CapsuleMesh.new()
	mesh.radius = width
	mesh.height = start.distance_to(end)+width*2.0
	mesh.radial_segments = 12
	mesh.rings = 4
	var node := _mesh(parent,mesh,material,label,(start+end)*.5)
	node.quaternion = Quaternion(Vector3.UP,(end-start).normalized())

func _build_player(seat: Node3D, style: int) -> void:
	var clothing: Array = [Color("344651"),Color("775445"),Color("424b38")]
	var skins: Array = [Color("b17e5d"),Color("d5a780"),Color("82543e")]
	var cloth := _plain(clothing[style%3],.94)
	var skin := _plain(skins[style%3],.8)
	var chair := _ellipsoid(seat,"ChairBack",Vector3(0,-.15,-4.1),Vector3(1.25,.58,.30),_surface("leather"))
	chair.rotation_degrees.x = -12
	var sleeves := Node3D.new()
	sleeves.name = "Sleeves"
	seat.add_child(sleeves)
	_ellipsoid(sleeves,"Torso",Vector3(0,-.30,-3.6),Vector3(1.05,.55,.52),cloth)
	for side in [-1,1]:
		var elbow := Vector3(side*1.12,-.18,-1.25)
		var wrist := Vector3(side*1.28,-.24,-.02)
		_limb(sleeves,"UpperSleeve",Vector3(side*.82,-.19,-3.4),elbow,.27,cloth)
		_limb(sleeves,"Forearm",elbow,wrist,.20,cloth)
		_limb(sleeves,"Cuff",wrist-Vector3(0,0,.11),wrist+Vector3(0,0,.06),.205,_plain(clothing[style%3].lightened(.10)))
		_ellipsoid(sleeves,"Palm",wrist+Vector3(0,-.02,.21),Vector3(.22,.105,.32),skin)
		_limb(sleeves,"Thumb",wrist+Vector3(side*.17,.06,.15),wrist+Vector3(side*.23,.10,.34),.066,skin)
	var label := Label3D.new()
	label.name = "Nameplate"
	label.font = load("res://assets/sans.ttf")
	label.font_size = 26
	label.pixel_size = .008
	label.outline_size = 3
	label.outline_modulate = Color("122821")
	label.position = Vector3(0,-.43,1.05)
	label.rotation_degrees.x = -70
	seat.add_child(label)
