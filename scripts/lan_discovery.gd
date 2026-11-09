extends RefCounted
## The invitation code is checked by the host. The socket uses the reply's IP.

const PORT := 7358
const TAG := "rami-lan-1"
const TIMEOUT_MS := 5500
var _socket: PacketPeerUDP
var _code := ""
var _game_port := 0
var _nonce := ""
var _next_packet := 0
var _deadline := 0

func listen(code: String, port: int) -> bool:
	_socket = PacketPeerUDP.new()
	_code = code
	_game_port = port
	return _socket.bind(PORT, "0.0.0.0") == OK

func search(code: String) -> bool:
	_socket = PacketPeerUDP.new()
	if _socket.bind(0, "0.0.0.0") != OK: return false
	_socket.set_broadcast_enabled(true)
	if _socket.set_dest_address("255.255.255.255", PORT) != OK: return false
	_code = code
	_nonce = Crypto.new().generate_random_bytes(8).hex_encode()
	_deadline = Time.get_ticks_msec() + TIMEOUT_MS
	return true

func poll(waiting: bool) -> Dictionary:
	var now := Time.get_ticks_msec()
	if _game_port == 0:
		if now >= _deadline: return {"address": ""}
		if now >= _next_packet:
			_socket.put_packet(("%s|find|%s|%s" % [TAG, _code, _nonce]).to_utf8_buffer())
			_next_packet = now + 550
	for _packet in range(mini(16, _socket.get_available_packet_count())):
		var packet := _socket.get_packet()
		if packet.size() > 96: continue
		var fields := packet.get_string_from_utf8().split("|")
		if fields.size() < 4 or fields[0] != TAG or fields[2] != _code: continue
		var ip := _socket.get_packet_ip()
		if _game_port > 0 and waiting and fields.size() == 4 and fields[1] == "find" and fields[3].length() == 16:
			if _socket.set_dest_address(ip, _socket.get_packet_port()) == OK:
				_socket.put_packet(("%s|room|%s|%s|%d" % [TAG, _code, fields[3], _game_port]).to_utf8_buffer())
		elif _game_port == 0 and fields.size() == 5 and fields[1] == "room" and fields[3] == _nonce and fields[4].is_valid_int():
			var port := int(fields[4])
			if port >= 1024 and port <= 65535 and ip.is_valid_ip_address() and not ip.contains(":"):
				return {"address": "ws://%s:%d" % [ip, port]}
	return {}

func close() -> void:
	if _socket != null: _socket.close()
