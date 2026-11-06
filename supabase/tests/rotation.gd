extends SceneTree
## Explicit hosted integration: real client automatically survives Edge rotation.
const Network = preload("res://scripts/network_manager.gd")
var host: Node
var guest: Node
var host_view: Dictionary = {}
var guest_view: Dictionary = {}
var failures := 0
var checks := 0

func _init() -> void: call_deferred("_run")
func check(value: bool, label_text: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error(label_text)
func until(predicate: Callable, seconds: float = 15.0) -> void:
	var deadline := Time.get_ticks_msec()+int(seconds*1000)
	while not predicate.call() and Time.get_ticks_msec()<deadline: await create_timer(.02).timeout
	check(predicate.call(), "bounded hosted response")
func _run() -> void:
	var url := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--url="): url = arg.trim_prefix("--url=")
	if url.is_empty():
		push_error("Supply -- --url=ws[s]://host/path")
		quit(1)
		return
	host = Network.new(); guest = Network.new()
	host.session_path = "user://supabase-rotation-host"
	guest.session_path = "user://supabase-rotation-guest"
	root.add_child(host); root.add_child(guest)
	host.game_updated.connect(func(value): host_view=value)
	guest.game_updated.connect(func(value): guest_view=value)
	host.connection_changed.connect(func(active):
		if not active: host_view={}
	)
	guest.connection_changed.connect(func(active):
		if not active: guest_view={}
	)
	check(host.create_remote_room(url,"QA Rotation Alice",6), "create hosted Tri")
	await until(func(): return host.connected)
	check(guest.join_room(url,"QA Rotation Bob",host.room_code), "join hosted Tri")
	await until(func(): return guest.connected)
	host.start_match()
	await until(func(): return not host_view.is_empty() and not guest_view.is_empty())
	if host_view.is_empty() or guest_view.is_empty():
		host.leave_room(); guest.leave_room(); quit(1); return
	host.send_action({"type":"draw","source":"deck"})
	await until(func(): return host_view.get("phase")=="play")
	var before: Array = host_view.hand.duplicate()
	var other_before: Array = guest_view.hand.duplicate()
	var token: String = host._session_token
	var code: String = host.room_code
	var old_host: WebSocketPeer = host._client
	var old_guest: WebSocketPeer = guest._client
	print("Waiting for hosted socket rotation with a private seven-card hand…")
	await until(func(): return host._client!=old_host and guest._client!=old_guest, 120.0)
	await until(func(): return host.connected and guest.connected and not guest_view.is_empty() and not host_view.get("paused",true))
	check(host.room_code==code and host._session_token==token, "automatic resume retains room and private token")
	check(host.local_player==0 and guest.local_player==1, "automatic resume retains seats")
	check(host_view.hand==before and guest_view.hand==other_before, "automatic resume preserves both private hands")
	check(host_view.phase=="play" and host_view.turn==0, "automatic resume preserves pending turn")
	host.send_action({"type":"discard","card":before.back()})
	await until(func(): return guest_view.get("turn")==1)
	guest.leave_room()
	await until(func(): return host_view.get("winner",-1)==0)
	check(host_view.get("win_by_forfeit",false), "match continues after rotation")
	host.leave_room()
	host.queue_free(); guest.queue_free()
	await process_frame
	print("SUPABASE ROTATION: %d checks; %d failures"%[checks,failures])
	quit(0 if failures==0 else 1)
