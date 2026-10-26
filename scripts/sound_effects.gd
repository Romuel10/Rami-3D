extends Node
## Original short synthesized sounds; independent of music, no external media.
var volume := 0.55
var enabled := true
var _voices: Array[AudioStreamPlayer] = []
var _clips: Dictionary = {}
var _cursor := 0

func _ready() -> void:
	for i in range(4):
		var voice := AudioStreamPlayer.new()
		add_child(voice)
		_voices.append(voice)
	for kind in ["draw","discard","meld","extend","select","deal","win"]:
		_clips[kind] = _make_clip(kind)

func play(kind: String) -> void:
	if not enabled or volume <= 0 or not _clips.has(kind) or _voices.is_empty(): return
	var voice := _voices[_cursor % _voices.size()]
	_cursor += 1
	voice.stream = _clips[kind]
	voice.volume_db = linear_to_db(clampf(volume, 0.001, 1.0))
	voice.play()

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED or what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		for voice in _voices: voice.stop()

func _make_clip(kind: String) -> AudioStreamWAV:
	var duration := 0.65 if kind == "win" else (0.28 if kind == "deal" else 0.10)
	var rate := 22050
	var data := PackedByteArray()
	data.resize(int(duration * rate) * 2)
	var rng := RandomNumberGenerator.new()
	rng.seed = 42
	for i in range(data.size() / 2):
		var t := float(i) / rate
		var envelope := minf(t * 250.0, 1.0) * pow(1.0 - t / duration, 2)
		var sample := 0.0
		if kind in ["win", "meld", "extend"]:
			var notes := [523.25, 659.25, 783.99]
			var hz: float = notes[mini(2, int(t / (duration / 3.0)))]
			sample = sin(TAU * hz * t) * 0.22
		else:
			sample = rng.randf_range(-0.22,0.22) + sin(TAU * (320.0 if kind == "select" else 180.0) * t) * 0.08
		data.encode_s16(i * 2, int(sample * envelope * 32767.0))
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = rate
	stream.data = data
	return stream
