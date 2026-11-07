extends RefCounted
## Independent 80 ms IMA ADPCM frames, mono 16 kHz. No recording on disk.
const RATE := 16000
const SAMPLES := 1280
const BYTES := 645
const INDEX := [-1,-1,-1,-1,2,4,6,8]
const STEPS := [7,8,9,10,11,12,13,14,16,17,19,21,23,25,28,31,34,37,41,45,50,55,60,66,73,80,88,97,107,118,130,143,157,173,190,209,230,253,279,307,337,371,408,449,494,544,598,658,724,796,876,963,1060,1166,1282,1411,1552,1707,1878,2066,2272,2499,2749,3024,3327,3660,4026,4428,4871,5358,5894,6484,7132,7845,8630,9493,10442,11487,12635,13899,15289,16818,18500,20350,22385,24623,27086,29794,32767]

static func encode(samples: PackedFloat32Array) -> PackedByteArray:
	if samples.size() != SAMPLES: return PackedByteArray()
	var data := PackedByteArray()
	data.resize(BYTES)
	var predictor := clampi(roundi(samples[0] * 32767.0),-32768,32767)
	var index := 32
	data.encode_s16(0,predictor)
	data[2] = index
	data.encode_u16(3,SAMPLES)
	for i in range(1,SAMPLES):
		var delta := clampi(roundi(samples[i]*32767.0),-32768,32767)-predictor
		var code := 8 if delta < 0 else 0
		delta = absi(delta)
		var step: int = STEPS[index]
		var change := step >> 3
		if delta >= step: code |= 4; delta -= step; change += step
		if delta >= (step >> 1): code |= 2; delta -= step >> 1; change += step >> 1
		if delta >= (step >> 2): code |= 1; change += step >> 2
		predictor = clampi(predictor + (-change if code & 8 else change),-32768,32767)
		index = clampi(index+INDEX[code & 7],0,88)
		var offset := 5 + ((i-1) >> 1)
		data[offset] |= code << (4 if (i-1) & 1 else 0)
	return data

static func decode(data: PackedByteArray) -> PackedVector2Array:
	if data.size() != BYTES or data[2] > 88 or data.decode_u16(3) != SAMPLES: return PackedVector2Array()
	var predictor := data.decode_s16(0)
	var index := int(data[2])
	var samples := PackedVector2Array()
	samples.resize(SAMPLES)
	samples[0] = Vector2.ONE * (predictor / 32768.0)
	for i in range(1,SAMPLES):
		var code: int = (data[5+((i-1) >> 1)] >> (4 if (i-1) & 1 else 0)) & 15
		var step: int = STEPS[index]
		var change := step >> 3
		if code & 4: change += step
		if code & 2: change += step >> 1
		if code & 1: change += step >> 2
		predictor = clampi(predictor + (-change if code & 8 else change),-32768,32767)
		index = clampi(index+INDEX[code & 7],0,88)
		samples[i] = Vector2.ONE * (predictor / 32768.0)
	return samples
