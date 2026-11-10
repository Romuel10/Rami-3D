extends SubViewportContainer

signal finished

const SCENE := "res://assets/animations/salon-intro.glb"

var animator: AnimationPlayer
var _render: SubViewport
var _clip: StringName

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	stretch = true
	stretch_shrink = 2
	_render = SubViewport.new()
	_render.own_world_3d = true
	_render.msaa_3d = Viewport.MSAA_2X
	_render.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_render)
	var stage := (load(SCENE) as PackedScene).instantiate()
	_render.add_child(stage)
	var camera := stage.find_child("CAM_Salon", true, false) as Camera3D
	camera.make_current()
	# Match the Blender exposure in the compatibility renderer.
	var key := stage.find_child("LGT_Cle_Chaud", true, false) as OmniLight3D
	key.light_energy *= 0.18
	var fill := stage.find_child("LGT_Remplissage", true, false) as OmniLight3D
	fill.light_energy *= 0.18
	var world := WorldEnvironment.new()
	world.environment = Environment.new()
	world.environment.background_mode = Environment.BG_COLOR
	world.environment.background_color = Color("17211d")
	world.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	world.environment.ambient_light_color = Color("e1dbc2")
	world.environment.ambient_light_energy = 0.16
	_render.add_child(world)
	animator = stage.find_child("AnimationPlayer", true, false) as AnimationPlayer
	for clip in animator.get_animation_list():
		if clip != "RESET":
			_clip = StringName(clip)
			break
	animator.animation_finished.connect(_hold_final_frame)
	replay()

func replay() -> void:
	_render.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	animator.stop()
	animator.play(_clip)
	animator.advance(0.0)

func _hold_final_frame(_name: StringName) -> void:
	_render.render_target_update_mode = SubViewport.UPDATE_ONCE
	finished.emit()
