class_name RamiMusic
extends Node
## Original instrumental loops, played locally with a short musical crossfade.
## Settings are owned by the application; this node never writes player files.

signal settings_changed

const TRACKS := [
	{"name": "Salon acoustique", "path": "res://assets/music/salon.ogg"},
	{"name": "Piano tranquille", "path": "res://assets/music/piano.ogg"},
	{"name": "Escale chill", "path": "res://assets/music/chill.ogg"},
]
const SILENT_DB := -70.0
const FADE_SECONDS := 0.42

var enabled: bool = true
var volume: float = 0.28
var track_index: int = 0
var _players: Array[AudioStreamPlayer] = []
var _active: int = 0
var _fade: Tween
var _transition_id: int = 0
var _app_paused: bool = false
var _focus_paused: bool = false
var _loaded_track: int = -1

func _ready() -> void:
	# Music belongs to the app scene; dedicated servers do not instantiate it.
	process_mode = Node.PROCESS_MODE_ALWAYS
	for i in range(2):
		var player := AudioStreamPlayer.new()
		player.name = "MusicChannel%d" % i
		player.bus = "Master"
		player.volume_db = SILENT_DB
		add_child(player)
		_players.append(player)
	_select_track(track_index, false)

func _exit_tree() -> void:
	# Stop decoding before scene teardown, including an interrupted crossfade.
	_cancel_fade()
	for player in _players:
		if is_instance_valid(player):
			player.stop()
			player.stream = null
	_players.clear()
	_loaded_track = -1

func track_names() -> Array:
	var names: Array = []
	for track in TRACKS:
		names.append(track.name)
	return names

func get_settings() -> Dictionary:
	return {"enabled": enabled, "volume": volume, "track_index": track_index}

func apply_settings(settings: Dictionary) -> void:
	var new_enabled: bool = settings.get("enabled", enabled) if settings.get("enabled", enabled) is bool else enabled
	var new_volume: float = volume
	var raw_volume: Variant = settings.get("volume", volume)
	if (raw_volume is int or raw_volume is float) and is_finite(float(raw_volume)):
		new_volume = clampf(float(raw_volume), 0.0, 1.0)
	var new_track: int = track_index
	var raw_track: Variant = settings.get("track_index", track_index)
	if raw_track is int or raw_track is float:
		if is_finite(float(raw_track)):
			new_track = clampi(int(raw_track), 0, TRACKS.size() - 1)
	var changed := enabled != new_enabled or not is_equal_approx(volume, new_volume) or track_index != new_track
	enabled = new_enabled
	volume = new_volume
	track_index = new_track
	if is_node_ready():
		if _loaded_track != track_index:
			_select_track(track_index, false)
		else:
			_sync_playback(false)
	if changed:
		settings_changed.emit()

func set_enabled(value: bool) -> void:
	if enabled == value:
		return
	enabled = value
	_sync_playback(true)
	settings_changed.emit()

func set_volume(value: float) -> void:
	if not is_finite(value):
		return
	value = clampf(value, 0.0, 1.0)
	if is_equal_approx(volume, value):
		return
	volume = value
	_sync_playback(true)
	settings_changed.emit()

func set_track(index: int) -> void:
	index = clampi(index, 0, TRACKS.size() - 1)
	if track_index == index and _loaded_track == index:
		return
	track_index = index
	if is_node_ready():
		_select_track(index, true)
	settings_changed.emit()

func set_app_paused(value: bool) -> void:
	_app_paused = value
	_sync_playback(false)

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED:
		_app_paused = true
		_sync_playback(false)
	elif what == NOTIFICATION_APPLICATION_RESUMED:
		_app_paused = false
		_sync_playback(false)
	elif what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_focus_paused = true
		_sync_playback(false)
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN:
		_focus_paused = false
		_sync_playback(false)

func _select_track(index: int, crossfade: bool) -> void:
	if _players.is_empty():
		return
	var stream := load(str(TRACKS[index].path)) as AudioStreamOggVorbis
	if stream == null:
		push_warning("Piste musicale indisponible : %s" % TRACKS[index].path)
		return
	stream = stream.duplicate() as AudioStreamOggVorbis
	stream.loop = true
	stream.loop_offset = 0.0
	_cancel_fade()
	var previous: AudioStreamPlayer = _players[_active]
	var incoming: AudioStreamPlayer = _players[1 - _active]
	incoming.stop()
	incoming.stream = stream
	incoming.volume_db = SILENT_DB
	incoming.stream_paused = false
	_active = 1 - _active
	_loaded_track = index
	if not _can_play():
		previous.stop()
		incoming.volume_db = _target_db()
		return
	incoming.play()
	if crossfade and previous.playing and not previous.stream_paused:
		var token := _transition_id
		_fade = create_tween().set_parallel(true)
		_fade.tween_property(previous, "volume_db", SILENT_DB, FADE_SECONDS)
		_fade.tween_property(incoming, "volume_db", _target_db(), FADE_SECONDS)
		_fade.chain().tween_callback(func():
			if token == _transition_id:
				previous.stop()
		)
	else:
		previous.stop()
		incoming.volume_db = _target_db()

func _can_play() -> bool:
	return enabled and volume > 0.0 and not _app_paused and not _focus_paused

func _target_db() -> float:
	return linear_to_db(volume) if volume > 0.0 else SILENT_DB

func _sync_playback(fade_change: bool) -> void:
	if _players.is_empty():
		return
	_cancel_fade()
	var player: AudioStreamPlayer = _players[_active]
	# Any outgoing crossfade channel stops when the user changes settings.
	_players[1 - _active].stop()
	if not _can_play():
		if fade_change and player.playing and not _app_paused and not _focus_paused:
			var token := _transition_id
			_fade = create_tween()
			_fade.tween_property(player, "volume_db", SILENT_DB, 0.18)
			_fade.tween_callback(func():
				if token == _transition_id and not _can_play():
					player.stream_paused = true
			)
		else:
			player.stream_paused = true
		return
	if player.stream == null:
		_select_track(track_index, false)
		return
	if not player.playing:
		player.play()
	player.stream_paused = false
	if fade_change:
		_fade = create_tween()
		_fade.tween_property(player, "volume_db", _target_db(), 0.18)
	else:
		player.volume_db = _target_db()

func _cancel_fade() -> void:
	_transition_id += 1
	if _fade != null and _fade.is_valid():
		_fade.kill()
	_fade = null
