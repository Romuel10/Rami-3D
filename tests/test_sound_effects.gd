extends SceneTree
const Foley = preload("res://scripts/sound_effects.gd")
var checks := 0
var failures: Array[String] = []
func _init() -> void: call_deferred("_run")
func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)
		push_error(label)
func _run() -> void:
	var foley = Foley.new()
	root.add_child(foley)
	await process_frame
	check(foley._voices.size()==4,"bounded four-voice pool")
	check(foley._clips.size()==8,"eight distinct card and victory cues")
	var fingerprints: Dictionary = {}
	for kind in Foley.DURATIONS:
		var clip: AudioStreamWAV = foley._clips[kind]
		check(clip.format==AudioStreamWAV.FORMAT_16_BITS and clip.mix_rate==22050 and not clip.stereo,"standard small mono PCM clip: "+kind)
		var samples: PackedByteArray = clip.data
		check(samples.size()>2000 and clip.get_length()<0.8,"short fully generated cue: "+kind)
		var peak := 0
		var energy := 0.0
		for offset in range(0,samples.size(),2):
			var sample := samples.decode_s16(offset)
			peak = maxi(peak,absi(sample))
			energy += float(sample)*sample
		check(peak>700 and peak<13000,"audible waveform with headroom: "+kind)
		check(sqrt(energy/(samples.size()/2.0))>100.0,"cue has nontrivial signal energy: "+kind)
		check(absi(samples.decode_s16(0))<2 and absi(samples.decode_s16(samples.size()-2))<2,"waveform starts and ends without discontinuity: "+kind)
		var fingerprint := hash(samples)
		check(not fingerprints.has(fingerprint),"different physical actions have different waveforms: "+kind)
		fingerprints[fingerprint] = true
		check(foley._make_clip(kind)==clip,"clips are cached resources: "+kind)
	var other = Foley.new()
	root.add_child(other)
	await process_frame
	check(other._clips.draw==foley._clips.draw,"app instances share the generated audio data")
	foley.play("draw")
	check(foley._cursor==1 and foley._voices[0].playing,"normal draw starts a voice")
	check(foley._voices[0].pitch_scale>=0.97 and foley._voices[0].pitch_scale<=1.03,"paper pitch variation stays subtle")
	foley.enabled = false
	check(not foley._voices.any(func(voice): return voice.playing),"mute stops current foley immediately")
	foley.play("discard")
	check(foley._cursor==1,"muted actions never start a voice")
	foley.enabled = true
	foley.volume = 0.0
	foley.play("draw")
	check(foley._cursor==1,"zero volume starts no voice")
	foley.volume = 0.7
	foley.play("unknown")
	check(foley._cursor==1,"unknown gameplay actions remain silent")
	foley.play_slide()
	var after_slide: int = foley._cursor
	for _movement in range(30): foley.play_slide()
	check(foley._cursor==after_slide,"pointer movement cannot spam friction sounds")
	var slide_deadline := Time.get_ticks_msec()+Foley.SLIDE_INTERVAL_MS+30
	while Time.get_ticks_msec()<slide_deadline:
		await create_timer(0.01).timeout
	foley.play_slide()
	check(foley._cursor==after_slide+1,"a later intentional slide can be heard")
	foley.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	check(not foley._voices.any(func(voice): return voice.playing),"app pause stops all effects")
	foley.play("draw")
	check(foley._cursor==after_slide+1,"actions received in background do not play")
	foley.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	foley.notification(Node.NOTIFICATION_APPLICATION_RESUMED)
	foley.play("draw")
	check(foley._cursor==after_slide+1,"app resume cannot override lost focus")
	foley.notification(Node.NOTIFICATION_APPLICATION_FOCUS_IN)
	foley.play("draw")
	check(foley._cursor==after_slide+2,"foreground allows new effects without replaying old ones")
	foley.volume = 0.0
	check(not foley._voices.any(func(voice): return voice.playing),"changing volume to zero stops existing effects")
	foley.volume = 10.0
	check(foley.volume==1.0,"volume clamps to a valid range")
	foley.volume = NAN
	check(foley.volume==1.0,"invalid volume preserves valid setting")
	var voices: Array = foley._voices.duplicate()
	root.remove_child(foley)
	check(foley._voices.is_empty() and foley._clips.is_empty(),"scene cleanup releases manager playback references")
	for voice in voices: check(not voice.playing and voice.stream==null,"scene cleanup releases a stopped voice")
	foley.queue_free()
	other.queue_free()
	await process_frame
	await create_timer(0.4).timeout
	print("RESULT: %d card foley checks; %d failures" % [checks,failures.size()])
	quit(0 if failures.is_empty() else 1)
