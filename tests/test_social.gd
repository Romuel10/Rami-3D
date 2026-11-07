extends SceneTree
const Main = preload("res://main.tscn")
const Codec = preload("res://scripts/voice_codec.gd")
const Network = preload("res://scripts/network_manager.gd")
var checks := 0
var failures := 0
func _init() -> void: call_deferred("_run")
func check(value: bool, message: String) -> void:
	checks += 1
	if not value: failures += 1; push_error(message)
func button(node: Node, text: String) -> Button:
	if node is Button and node.text==text: return node
	for child in node.get_children():
		var result := button(child,text)
		if result != null: return result
	return null
func fields(node: Node) -> int:
	var count := 1 if node is LineEdit else 0
	for child in node.get_children(): count += fields(child)
	return count
func capture(app: Node, label: String) -> void:
	if DisplayServer.get_name()=="headless": return
	for size in [Vector2i(1440,900),Vector2i(2400,1080)]:
		root.size=size
		app._screen_changed()
		await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("res://builds/social-%s-%dx%d.png" % [label,size.x,size.y])
		if app.voice_panel.visible:
			check(app.ui.get_global_rect().encloses(app.voice_panel.get_global_rect()),"voice controls stay within the screen")
func _run() -> void:
	var samples := PackedFloat32Array()
	samples.resize(Codec.SAMPLES)
	for i in range(samples.size()): samples[i] = 0.35*sin(TAU*440.0*i/Codec.RATE)
	var encoded := Codec.encode(samples)
	var decoded := Codec.decode(encoded)
	check(encoded.size()==645 and Marshalls.raw_to_base64(encoded).length()==860,"audio frames have bounded wire size")
	check(decoded.size()==1280,"codec returns exact 80 ms stereo playback frame")
	var error := 0.0
	for i in range(50,decoded.size()): error += pow(decoded[i].x-samples[i],2)
	check(sqrt(error/(decoded.size()-50)) < 0.025,"speech codec preserves a reference tone")
	check(Codec.decode(encoded.slice(0,644)).is_empty(),"truncated audio rejected")
	var invalid := encoded.duplicate(); invalid[2]=255
	check(Codec.decode(invalid).is_empty(),"invalid step index rejected")
	invalid=encoded.duplicate(); invalid.encode_u16(3,65535)
	check(Codec.decode(invalid).is_empty(),"invalid frame length rejected")
	check(Codec.encode(PackedFloat32Array([0.0])).is_empty(),"short capture is not transmitted")

	var app = Main.instantiate()
	root.add_child(app)
	await process_frame
	app.animations_enabled=false
	app.saved_address="ws://192.168.1.2:7357"
	app._open_friends()
	check(fields(app.overlay)==1 and app.address_input==null and app.invitation_input==null,"friends screen only requests six-digit code")
	check(button(app.overlay,"Même Wi-Fi")==null and button(app.overlay,"Changer de serveur")==null,"technical address tabs removed")
	check(app.code_input.max_length==6 and app.code_input.virtual_keyboard_type==LineEdit.KEYBOARD_TYPE_NUMBER,"numeric six-digit keyboard")
	check(app.room_count_select.item_count==3,"creator has 2/3/4 player choices")
	await capture(app,"join")
	app.room_count_select.item_selected.emit(2)
	check(app.friends_player_count==4,"creator selection is retained")
	app.code_input.text="12+456"; app._join_room()
	check(app.network.room_code.is_empty() and "6 chiffres" in app.toast_label.text,"non-digit code rejected without connecting")
	app._close_overlay()
	app.network.room_code="001234"; app.network.is_host=true; app.network.local_player=0; app.network.connected=true
	var players := [{"name":"Alice","connected":true},{"name":"Bob","connected":true}]
	var lobby := {"code":"001234","players":players,"started":false,"player_count":3,"tri_cards":0,"host":true,"your_index":0}
	app._lobby_updated(lobby)
	check(app.game_mode=="lobby" and app.lobby_start.disabled,"selected count must be present before start")
	check(button(app.content,"Copier le code")!=null,"lobby shares just the six-digit code")
	lobby.player_count=2; app._lobby_updated(lobby)
	check(not app.lobby_start.disabled,"exact connected roster can start")
	var picker: OptionButton = app.room_count_select
	app._lobby_updated(lobby.duplicate(true))
	check(app.room_count_select==picker,"unchanged presence update preserves open room controls")
	await capture(app,"lobby")
	players[1].connected=false; app._lobby_updated(lobby)
	check(app.lobby_start.disabled,"disconnected player prevents start")
	players[1].connected=true
	app._start_solo(12)
	app.engine.state.winner=0; app._refresh_snapshot()
	check(button(app.overlay,"Rejouer")!=null,"solo result asks to play again")
	button(app.overlay,"Rejouer").pressed.emit()
	check(app.game_mode=="solo" and app.snapshot.winner<0 and app.snapshot.tri_hand_size==12,"solo replay keeps twelve-card Tri format")
	await capture(app,"game")

	app.network.connected=true; app.network.supports_rematch=true; app.network.room_code="001234"; app.network.local_player=0
	app.game_mode="online"
	app.snapshot={"session_id":"completed","winner":0,"players":[{"name":"Alice"},{"name":"Bob"}],"your_index":0,"match_result":{"finished":true,"winners":[0]}}
	app.current_lobby={"started":true,"players":players}
	app._winner_key=""; app._show_winner()
	check(button(app.overlay,"Oui, rejouer")!=null and app.game_mode=="online","online result stays in room and offers a rematch")
	players[0].rematch_ready=true; app._update_rematch_controls()
	check(app.rematch_button.disabled and "1 / 2" in app.rematch_status.text,"own vote waits for the other player")
	app._update_voice_controls()
	await capture(app,"rematch")
	app._connection_changed(false)
	check(app.overlay_kind=="winner","postgame reconnect never sends player to home")
	check(not app.voice.transmitting and app.voice._microphone==null,"microphone is off and unopened by default")
	app.voice._status(true)
	app.voice._receive(1,"test-stream",1,Marshalls.raw_to_base64(encoded))
	check(app.voice.speakers.has(1),"received audio is decoded for a room member")
	app.voice.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	app.voice._receive(1,"test-stream",2,Marshalls.raw_to_base64(encoded))
	check(app.voice._receivers.is_empty() and not app.voice.transmitting,"background app cannot resume capture or received speech")
	app.voice.notification(Node.NOTIFICATION_APPLICATION_RESUMED)
	app.voice.toggle_listening()
	check(app.voice._receivers.is_empty() and not app.voice.listening,"mute clears pending received audio")
	app.voice._status(false)
	check(not app.voice.transmitting and not app.voice.available,"disconnect stops all voice capture")
	app._leave_to_menu()
	check(not app.voice_panel.visible and app.game_mode=="menu","leaving hides voice controls")
	app.queue_free()
	await create_timer(0.25).timeout

	var net := Network.new()
	net.session_path="user://social-session-test.save"
	root.add_child(net)
	net._client_url="ws://127.0.0.1:7357"; net._client_name="Alice"
	net._client_message({"type":"welcome","player":0,"token":"a".repeat(48),"code":"001234","features":{"rematch":true}})
	net._client_message({"type":"state","data":{"session_id":"completed","winner":0,"players":[{}]}})
	check(net.has_saved_session(),"new server retains seat token after a completed match")
	net._client_message({"type":"welcome","player":0,"token":"a".repeat(48),"code":"001234","features":{"rematch":true}})
	check(net._match_finished and net._session_id=="completed","postgame welcome cannot discard completed result before replay click")
	net.leave_room()
	check(not net.has_saved_session(),"intentional leave removes recovery token")
	net.queue_free()
	await create_timer(0.3).timeout
	print("SOCIAL: %d checks; %d failures" % [checks,failures])
	quit(0 if failures==0 else 1)
