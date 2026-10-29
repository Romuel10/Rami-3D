extends RefCounted
## Public connection settings only. Database credentials never reach the APK.
static func normalise(value: String) -> String:
	var text := value.strip_edges()
	var expression := RegEx.new()
	expression.compile("^(https?|wss?)://([^/\\s?#]+)(/[^\\s?#]*)?$")
	var found := expression.search(text)
	if found==null: return ""
	var scheme := found.get_string(1)
	var authority := found.get_string(2)
	var path := found.get_string(3)
	if authority.contains("@") or authority.begins_with(":") or authority.ends_with(":"): return ""
	if authority.contains(":") and not authority.begins_with("["):
		var port := authority.get_slice(":",1)
		if not port.is_valid_int() or int(port)<1 or int(port)>65535: return ""
	var host := authority.to_lower().get_slice(":",0)
	if not host.contains(".") and host!="localhost": return ""
	if scheme=="https": scheme="wss"
	elif scheme=="http": scheme="ws"
	if path in ["","/"] and (host.ends_with(".vercel.app") or text.begins_with("https://")):
		path="/api/ws"
	return scheme+"://"+authority+path

static func configured_url() -> String:
	return normalise(str(ProjectSettings.get_setting("network/default_server_url","")))
