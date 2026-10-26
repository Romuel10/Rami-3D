extends SceneTree

const Music = preload("res://scripts/music_manager.gd")
var checks := 0

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, message: String) -> void:
	if not condition:
		push_error("FAIL: " + message)
		quit(1)
		assert(condition, message)
	checks += 1

func _run() -> void:
	var music = Music.new()
	# A persisted mute must prevent even the first frame of playback.
	music.apply_settings({"enabled":false,"volume":0.33,"track_index":1})
	root.add_child(music)
	await process_frame
	_check(music.track_names().size() == 3, "three music choices")
	_check(music.get_settings() == {"enabled":false,"volume":0.33,"track_index":1}, "preferences applied before ready")
	_check(not music._players[music._active].playing, "saved mute does not autoplay")
	for track in music.TRACKS:
		var stream = load(track.path) as AudioStreamOggVorbis
		_check(stream != null and stream.get_length() >= 40.0, "long musical loop: " + track.name)
	music.set_enabled(true)
	await process_frame
	_check(music._players[music._active].playing, "enable starts audio")
	_check(not music._players[music._active].stream_paused, "enable resumes audio")
	_check(music._players[music._active].stream.loop, "runtime stream loops")
	var previous: int = music._active
	music.set_track(2)
	await process_frame
	_check(music._active != previous, "track change uses second channel")
	_check(music._players[music._active].playing, "incoming track plays")
	await create_timer(0.55).timeout
	_check(not music._players[previous].playing, "crossfade stops outgoing track")
	music.set_app_paused(true)
	_check(music._players[music._active].stream_paused, "background silences music immediately")
	music.set_app_paused(false)
	_check(not music._players[music._active].stream_paused, "foreground resumes music")
	music.set_enabled(false)
	await create_timer(0.3).timeout
	_check(music._players[music._active].stream_paused, "disable fades into pause")
	music.set_app_paused(true)
	music.set_app_paused(false)
	_check(music._players[music._active].stream_paused, "foreground preserves user mute")
	music.apply_settings({"enabled":true,"volume":-10.0,"track_index":100})
	_check(music.volume == 0.0 and music.track_index == 2, "settings clamp volume and track")
	_check(music._players[music._active].stream_paused, "zero volume pauses playback")
	music.set_volume(1.8)
	_check(music.volume == 1.0, "slider maximum clamps")
	music.apply_settings({"volume":NAN,"track_index":NAN,"enabled":"false"})
	_check(music.volume == 1.0 and music.track_index == 2 and music.enabled, "invalid settings retain valid values")
	music.set_enabled(false)
	music.set_track(0)
	await create_timer(0.25).timeout
	_check(not music._players[music._active].playing, "changing track while muted never starts audio")
	music.set_enabled(true)
	await process_frame
	_check(music._players[music._active].playing, "unmute starts selected track")
	music.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	_check(music._players[music._active].stream_paused, "focus loss pauses")
	music.notification(Node.NOTIFICATION_APPLICATION_FOCUS_IN)
	_check(not music._players[music._active].stream_paused, "focus restore resumes")
	music.queue_free()
	await process_frame
	var closing = Music.new()
	root.add_child(closing)
	await process_frame
	closing.set_track(1)
	_check(closing._fade != null and closing._fade.is_valid(), "cleanup scenario starts during crossfade")
	var channels: Array = closing._players.duplicate()
	root.remove_child(closing)
	_check(closing._fade == null and closing._players.is_empty(), "scene exit releases tween and channel references")
	for channel in channels:
		_check(not channel.playing and channel.stream == null, "scene exit stops and releases each stream")
	closing.queue_free()
	await process_frame
	for channel in channels:
		_check(not is_instance_valid(channel), "music channels freed with their manager")
	# Godot releases stopped Vorbis playback references on its next audio mix.
	await create_timer(0.2).timeout
	print("PASS: %d music checks" % checks)
	quit(0)
