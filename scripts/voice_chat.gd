extends Node
## Hold-to-talk. Capture exists only while held, never starts after a permission
## dialog or reconnect. Incoming audio is silenced while speaking to avoid echo.
signal changed
signal notice(message: String)
const Codec = preload("res://scripts/voice_codec.gd")
const MICROPHONE_PERMISSION := "android.permission.RECORD_AUDIO"
var network: Node
var transmitting := false
var listening := true
var available := false
var _foreground := true
var speakers: Dictionary = {}
var _capture: AudioEffectCapture
var _microphone: AudioStreamPlayer
var _bus_name := ""
var _pcm := PackedFloat32Array()
var _phase := 0.0
var _low_pass := 0.0
var _dc := 0.0
var _sequence := 0
var _next_send := 0
var _receivers: Dictionary = {}
var _speaker_ids: Array[String] = []
var _muted: Dictionary = {}

func setup(room: Node) -> void:
	network = room
	network.voice_received.connect(_receive)
	network.voice_status.connect(_status)
	network.connection_changed.connect(func(connected: bool):
		if not connected: _status(false))
	get_tree().on_request_permissions_result.connect(_permission_result)

func begin_talk() -> void:
	if transmitting or not _foreground or not available or network == null or not network.connected: return
	if OS.has_feature("android") and not OS.request_permission(MICROPHONE_PERMISSION):
		notice.emit("Autorisez le micro, puis maintenez Parler pour discuter.")
		return
	if DisplayServer.get_name() == "headless": return
	_make_capture()
	_capture.clear_buffer()
	_pcm.clear()
	_phase = 0.0; _low_pass = 0.0; _dc = 0.0
	_next_send = Time.get_ticks_msec()
	_clear_receivers()
	transmitting = true
	_microphone.play()
	changed.emit()

func stop_talk() -> void:
	if _microphone != null: _microphone.stop()
	if _capture != null: _capture.clear_buffer()
	_pcm.clear()
	if transmitting:
		transmitting = false
		changed.emit()

func toggle_listening() -> void:
	listening = not listening
	_clear_receivers()
	changed.emit()

func speaker_muted(index: int) -> bool:
	return index >= 0 and index < _speaker_ids.size() and _muted.has(_speaker_ids[index])

func set_speaker_muted(index: int, value: bool) -> void:
	if index < 0 or index >= _speaker_ids.size(): return
	var id := _speaker_ids[index]
	if value:
		_muted[id] = true
		_drop_receiver(index)
	else: _muted.erase(id)
	changed.emit()

func _permission_result(permission: String, granted: bool) -> void:
	if permission != MICROPHONE_PERMISSION: return
	stop_talk()
	notice.emit("Micro autorisé. Maintenez Parler pour discuter." if granted else "Micro refusé. Vous pouvez toujours écouter vos amis.")

func _status(value: bool) -> void:
	available = value
	if not value:
		stop_talk()
		_clear_receivers()
	changed.emit()

func _make_capture() -> void:
	if _microphone != null: return
	_bus_name = "RamiMicrophone_%d" % get_instance_id()
	AudioServer.add_bus()
	var bus := AudioServer.bus_count-1
	AudioServer.set_bus_name(bus,_bus_name)
	_capture = AudioEffectCapture.new()
	_capture.buffer_length = 0.3
	AudioServer.add_bus_effect(bus,_capture)
	# Muting the bus output leaves its capture effect active (no local feedback).
	AudioServer.set_bus_mute(bus,true)
	_microphone = AudioStreamPlayer.new()
	_microphone.stream = AudioStreamMicrophone.new()
	_microphone.bus = _bus_name
	add_child(_microphone)

func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	for index in speakers.keys():
		if now-int(speakers[index]) > 450:
			speakers.erase(index)
			changed.emit()
	if not transmitting or _capture == null: return
	var count := _capture.get_frames_available()
	var mix_rate := AudioServer.get_mix_rate()
	if count > int(mix_rate*0.24):
		_capture.clear_buffer(); _pcm.clear(); _phase = 0.0
		return
	if count > 0:
		for sample in _capture.get_buffer(count):
			_low_pass = lerpf(_low_pass,(sample.x+sample.y)*0.5,0.65)
			_dc = lerpf(_dc,_low_pass,0.001)
			_phase += Codec.RATE
			if _phase >= mix_rate:
				_phase -= mix_rate
				_pcm.append(clampf((_low_pass-_dc)*1.2,-1.0,1.0))
	if _pcm.size() > Codec.SAMPLES*3:
		_pcm = _pcm.slice(_pcm.size()-Codec.SAMPLES)
	if _pcm.size() < Codec.SAMPLES or now < _next_send: return
	_next_send = maxi(_next_send+80,now+45)
	var frame := _pcm.slice(0,Codec.SAMPLES)
	_pcm = _pcm.slice(Codec.SAMPLES)
	var energy := 0.0
	for sample in frame: energy += sample*sample
	if energy/Codec.SAMPLES < 0.000006: return
	_sequence += 1
	network.send_voice(_sequence,Marshalls.raw_to_base64(Codec.encode(frame)))

func _receive(index: int, stream: String, sequence: int, encoded: String) -> void:
	if not _foreground or not available or not listening or transmitting or sequence < 0 or stream.is_empty() or speaker_muted(index): return
	if encoded.length() != 860: return
	var samples := Codec.decode(Marshalls.base64_to_raw(encoded))
	if samples.is_empty(): return
	var receiver: Dictionary = _receivers.get(index,{})
	if receiver.is_empty() or receiver.stream != stream:
		if not receiver.is_empty(): receiver.player.queue_free()
		var player := AudioStreamPlayer.new()
		var generator := AudioStreamGenerator.new()
		generator.mix_rate = Codec.RATE
		generator.buffer_length = 0.32
		player.stream = generator
		add_child(player)
		player.play()
		receiver = {"player":player,"playback":player.get_stream_playback(),"stream":stream,"sequence":-1,"last":0}
		_receivers[index] = receiver
	if sequence <= int(receiver.sequence): return
	var now := Time.get_ticks_msec()
	var playback: AudioStreamGeneratorPlayback = receiver.playback
	# Discard a delayed backlog after packet loss or a slow rendering frame.
	if int(receiver.last) > 0 and (now-int(receiver.last) > 300 or playback.get_frames_available() < Codec.SAMPLES*2):
		receiver.player.stop()
		receiver.player.play()
		playback = receiver.player.get_stream_playback()
		receiver.playback = playback
		receiver.last = 0
	if int(receiver.last) == 0:
		var lead_in := PackedVector2Array()
		lead_in.resize(640) # 40 ms of jitter allowance, never a growing speech queue.
		playback.push_buffer(lead_in)
	if playback.can_push_buffer(samples.size()): playback.push_buffer(samples)
	receiver.sequence = sequence
	receiver.last = now
	speakers[index] = now
	changed.emit()

func sync_players(players: Array) -> void:
	var ids: Array[String] = []
	for i in range(players.size()):
		var id := str(players[i].get("seat_id", ""))
		ids.append(id if not id.is_empty() else "%d:%s" % [i, players[i].get("name", "")])
	for index in _receivers.keys():
		if index >= ids.size() or index >= _speaker_ids.size() or ids[index] != _speaker_ids[index] or not players[index].get("connected",false) or players[index].get("departed",false):
			_drop_receiver(index)
	_speaker_ids = ids
	for id in _muted.keys():
		if not id in ids: _muted.erase(id)

func _drop_receiver(index: int) -> void:
	if _receivers.has(index):
		_receivers[index].player.stop()
		_receivers[index].player.queue_free()
		_receivers.erase(index)
	speakers.erase(index)

func _clear_receivers() -> void:
	for index in _receivers.keys(): _drop_receiver(index)
	speakers.clear()

func _notification(what: int) -> void:
	if what in [NOTIFICATION_APPLICATION_PAUSED,NOTIFICATION_APPLICATION_FOCUS_OUT]:
		_foreground = false
		stop_talk()
		_clear_receivers()
	elif what in [NOTIFICATION_APPLICATION_RESUMED,NOTIFICATION_APPLICATION_FOCUS_IN]:
		_foreground = true

func _exit_tree() -> void:
	stop_talk()
	_clear_receivers()
	if not _bus_name.is_empty():
		var bus := AudioServer.get_bus_index(_bus_name)
		if bus > 0: AudioServer.remove_bus(bus)
