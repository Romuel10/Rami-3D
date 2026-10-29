extends Node
## Original card foley: filtered paper friction, felt-muted taps and soft stacking.
## All samples are generated once and shared; no external recordings or licences.
const RATE := 22050
const SLIDE_INTERVAL_MS := 140
const DURATIONS := {"draw":0.22,"discard":0.24,"meld":0.30,"extend":0.22,"select":0.075,"deal":0.44,"slide":0.20,"win":0.72}
const SEEDS := {"draw":117,"discard":231,"meld":349,"extend":433,"select":521,"deal":619,"slide":727,"win":829}
static var _shared_clips: Dictionary = {}

var _voices: Array[AudioStreamPlayer] = []
var _clips: Dictionary = {}
var _cursor := 0
var _last_slide_ms := -1000000
var _app_paused := false
var _focus_paused := false
var _variation := RandomNumberGenerator.new()
var volume := 0.55:
	set(value):
		volume = clampf(value,0.0,1.0) if is_finite(value) else volume
		for voice in _voices:
			if volume <= 0.0: voice.stop()
			else: voice.volume_db = linear_to_db(volume)
var enabled := true:
	set(value):
		enabled = value
		if not value: _stop_all()

func _ready() -> void:
	_variation.randomize()
	for i in range(4):
		var voice := AudioStreamPlayer.new()
		voice.name = "CardFoley%d" % i
		add_child(voice)
		_voices.append(voice)
	for kind in DURATIONS:
		_clips[kind] = _make_clip(kind)

func play(kind: String) -> void:
	if not enabled or volume <= 0.0 or _app_paused or _focus_paused or not _clips.has(kind) or _voices.is_empty(): return
	if kind == "slide":
		var now := Time.get_ticks_msec()
		if now - _last_slide_ms < SLIDE_INTERVAL_MS: return
		_last_slide_ms = now
	var voice := _voices[_cursor % _voices.size()]
	_cursor += 1
	voice.stream = _clips[kind]
	# Very small variations avoid a repeated stamped sound without changing a cue.
	voice.pitch_scale = 1.0 if kind == "win" else _variation.randf_range(0.97,1.03)
	voice.volume_db = linear_to_db(clampf(volume*_variation.randf_range(0.94,1.0),0.001,1.0))
	voice.play()

func play_slide() -> void:
	play("slide")

func _stop_all() -> void:
	for voice in _voices:
		if is_instance_valid(voice): voice.stop()

func _notification(what: int) -> void:
	match what:
		NOTIFICATION_APPLICATION_PAUSED:
			_app_paused = true
			_stop_all()
		NOTIFICATION_APPLICATION_RESUMED:
			_app_paused = false
		NOTIFICATION_APPLICATION_FOCUS_OUT:
			_focus_paused = true
			_stop_all()
		NOTIFICATION_APPLICATION_FOCUS_IN:
			_focus_paused = false

func _exit_tree() -> void:
	_stop_all()
	for voice in _voices: voice.stream = null
	_voices.clear()
	_clips.clear()

func _pulse(time: float, start: float, duration: float, attack: float = 0.009) -> float:
	var age := time-start
	if age < 0.0 or age >= duration: return 0.0
	return minf(age/attack,1.0)*pow(1.0-age/duration,2.0)

func _make_clip(kind: String) -> AudioStreamWAV:
	if _shared_clips.has(kind): return _shared_clips[kind]
	if not DURATIONS.has(kind): return null
	var duration: float = DURATIONS[kind]
	var frames := int(duration*RATE)
	var data := PackedByteArray()
	data.resize(frames*2)
	var rng := RandomNumberGenerator.new()
	rng.seed = SEEDS[kind]
	var low := 0.0
	var medium := 0.0
	for i in range(frames):
		var time := float(i)/RATE
		var white := rng.randf_range(-1.0,1.0)
		low += 0.075*(white-low)
		medium += 0.40*(white-medium)
		# Band-limited noise makes the paper whisper soft rather than metallic.
		var paper := medium-low
		var sample := 0.0
		match kind:
			"draw":
				sample = paper*_pulse(time,0.0,0.19,0.023)*0.30
				sample += (low*0.16+sin(TAU*165.0*time)*0.050)*_pulse(time,0.155,0.055,0.003)
			"discard":
				# A small initial card flex, a felt landing, then a short settling slide.
				sample = paper*_pulse(time,0.0,0.08,0.008)*0.20
				sample += (low*0.30+sin(TAU*118.0*(time-0.045))*0.10)*_pulse(time,0.045,0.085,0.002)
				sample += paper*_pulse(time,0.070,0.16,0.020)*0.18
			"meld", "extend":
				var offsets: Array = [0.0,0.055,0.12] if kind=="meld" else [0.0,0.065]
				for start: float in offsets:
					var age := time-start
					sample += (paper*0.22+low*0.18+sin(TAU*145.0*age)*0.045)*_pulse(time,start,0.125,0.004)
			"select":
				sample = (paper*0.15+sin(TAU*270.0*time)*0.025)*_pulse(time,0.0,duration,0.003)
			"deal":
				for start: float in [0.0,0.09,0.18,0.27]:
					var age := time-start
					sample += paper*_pulse(time,start,0.13,0.012)*0.22
					sample += (low*0.15+sin(TAU*150.0*age)*0.04)*_pulse(time,start+0.068,0.06,0.003)
			"slide":
				sample = (paper*0.22+low*0.07)*_pulse(time,0.0,duration,0.035)
			"win":
				# A quiet three-note resolution, softer than the old electronic beep.
				for note in range(3):
					var start: float = float(note)*0.105
					var hz: float = [523.25,659.25,783.99][note]
					var age := time-start
					sample += (sin(TAU*hz*age)*0.08+sin(TAU*hz*2.0*age)*0.015)*_pulse(time,start,duration-start,0.012)
		# Fade the boundary to zero to avoid clicks even when pitch is varied.
		sample *= minf(float(frames-1-i)/float(RATE)*400.0,1.0)
		data.encode_s16(i*2,int(clampf(sample,-0.38,0.38)*32767.0))
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = RATE
	stream.stereo = false
	stream.data = data
	_shared_clips[kind] = stream
	return stream
