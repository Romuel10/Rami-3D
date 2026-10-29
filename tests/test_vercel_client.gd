extends SceneTree
## Real Android network code against the Node/Vercel protocol, isolated data only.
const Network = preload("res://scripts/network_manager.gd")
var host: Node
var guest: Node
var host_view: Dictionary = {}
var guest_view: Dictionary = {}
var checks := 0
var failures := 0

func _init() -> void: call_deferred("_run")
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(message)
func until(predicate: Callable) -> void:
	var deadline := Time.get_ticks_msec()+5000
	while not predicate.call() and Time.get_ticks_msec()<deadline: await create_timer(.01).timeout
	check(predicate.call(),"bounded protocol response")
func _run() -> void:
	var url := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--url="): url = arg.trim_prefix("--url=")
	if url.is_empty():
		push_error("Use -- --url=ws://127.0.0.1:PORT/api/ws")
		quit(1)
		return
	for size in [0,6,12]:
		host_view = {}; guest_view = {}
		host = Network.new(); guest = Network.new()
		host.session_path = "user://vercel-host-session"; guest.session_path = "user://vercel-guest-session"
		root.add_child(host); root.add_child(guest)
		host.game_updated.connect(func(data): host_view=data)
		guest.game_updated.connect(func(data): guest_view=data)
		check(host.create_remote_room(url,"Alice",size),"create remote Vercel room")
		await until(func(): return host.connected)
		check(host.is_host and not host._hosting_locally,"Vercel creator is remote owner")
		check(guest.join_room(url,"Bob",host.room_code),"join with room code")
		await until(func(): return guest.connected)
		check(host.start_match(),"start remote game")
		await until(func(): return not host_view.is_empty() and not guest_view.is_empty())
		var count: int = 13 if size==0 else size
		check(host_view.get("hand",[]).size()==count and guest_view.get("hand",[]).size()==count,"deal exact hand size")
		check(host_view.get("hand",[])!=guest_view.get("hand",[]),"own hands differ")
		for player in host_view.get("players",[]): check(not player.has("hand"),"no other hand in public summary")
		check(host_view.get("variant")==("rami" if size==0 else "tri"),"authoritative variant")
		host.send_action({"type":"draw","source":"deck"})
		await until(func(): return host_view.get("hand",[]).size()==count+1)
		check(host_view.get("phase")=="play","draw then play")
		await create_timer(.07).timeout
		host.send_action({"type":"discard","card":host_view.hand.back()})
		await until(func(): return guest_view.get("turn")==1)
		var before: Array = guest_view.get("hand",[]).duplicate()
		var token: String = guest._session_token
		guest._client.close(1001,"Reconnexion testée")
		await until(func(): return host_view.get("paused",false))
		check(guest.reconnect(),"manual reconnect uses same token")
		await until(func(): return guest.connected and not host_view.get("paused",true))
		check(guest._session_token==token and guest_view.hand==before,"reconnect preserves seat and private cards")
		guest.leave_room()
		await until(func(): return int(host_view.get("winner",-1))==0)
		check(host_view.get("win_by_forfeit",false),"explicit abandon gives opponent victory")
		host.leave_room()
		host.queue_free(); guest.queue_free()
		await process_frame
	print("VERCEL GODOT CLIENT: %d checks; %d failures"%[checks,failures])
	quit(0 if failures==0 else 1)
