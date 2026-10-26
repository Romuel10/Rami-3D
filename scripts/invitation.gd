extends RefCounted
## Copy/paste invitation carries the endpoint and code, never a session token.
static func make(address: String, code: String) -> String:
	return "rami3d://join?server=" + address.uri_encode() + "&code=" + code.uri_encode()

static func parse(text: String) -> Dictionary:
	text = text.strip_edges()
	if text.length() > 2048 or not text.begins_with("rami3d://join?"): return {}
	var result := {}
	for part in text.trim_prefix("rami3d://join?").split("&"):
		var pair := part.split("=",true,1)
		if pair.size() != 2 or result.has(pair[0]) or not pair[0] in ["server","code"]: return {}
		result[pair[0]] = pair[1].uri_decode()
	var server := str(result.get("server",""))
	var code := str(result.get("code",""))
	if code.length() != 6 or not code.is_valid_int() or code.contains("+") or code.contains("-"): return {}
	if not (server.begins_with("ws://") or server.begins_with("wss://")): return {}
	var authority := server.split("://",true,1)[1].split("/")[0]
	if authority.is_empty() or "@" in server or "#" in server or " " in server or "\n" in server or "\r" in server: return {}
	return result
