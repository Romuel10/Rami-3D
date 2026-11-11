extends RefCounted
## One palette for the controls and the physical salon. Faces stay paper-white.
const DEFAULT := "lagon"
const IDS := ["lagon", "terre", "indigo"]
const NAMES := ["Lagon et sable", "Terre rouge", "Indigo et cuivre"]
const PALETTES := {
	"lagon": {"background":"10272e", "panel":"193943", "ink":"eaf7f4", "muted":"b4d0d2", "line":"385b62", "accent":"f3b96b", "primary_ink":"252d33", "field":"f7fcfb", "field_ink":"17383d", "felt":"156477", "wood":"776957", "leather":"344e55", "metal":"ba905d", "seam":"91bac0"},
	"terre": {"background":"30221f", "panel":"44302b", "ink":"ffeddc", "muted":"d4b8ab", "line":"6c4c42", "accent":"93d6cb", "primary_ink":"193c38", "field":"fff9ef", "field_ink":"492d29", "felt":"9b4235", "wood":"745044", "leather":"573c34", "metal":"c99c69", "seam":"e0b79d"},
	"indigo": {"background":"171c31", "panel":"242b48", "ink":"f4effb", "muted":"c2c0da", "line":"42496c", "accent":"e9ad6f", "primary_ink":"2f2333", "field":"f7f6fd", "field_ink":"2b2d52", "felt":"3a447f", "wood":"797283", "leather":"393b59", "metal":"c68e66", "seam":"aaa8cc"}
}

static func checked_id(value: Variant) -> String:
	return str(value) if value is String and value in IDS else DEFAULT

static func colors(id: String) -> Dictionary:
	var result: Dictionary = {}
	var values: Dictionary = PALETTES[checked_id(id)]
	for role in values: result[role] = Color(values[role])
	result["hover"] = (result.panel as Color).lightened(0.11)
	result["pressed"] = (result.panel as Color).lightened(0.18)
	result["disabled"] = (result.background as Color).lightened(0.025)
	result["disabled_ink"] = (result.muted as Color).darkened(0.30)
	result["primary_hover"] = (result.accent as Color).lightened(0.13)
	result["primary_pressed"] = (result.accent as Color).darkened(0.12)
	result["field_hint"] = (result.field_ink as Color).lightened(0.22)
	result["field_selection"] = (result.felt as Color).darkened(0.16)
	result["floor"] = (result.background as Color).darkened(0.18)
	return result

static func _remap(value: Color, previous: Dictionary, next: Dictionary) -> Color:
	for role in previous:
		var old: Color = previous[role]
		if is_equal_approx(value.r, old.r) and is_equal_approx(value.g, old.g) and is_equal_approx(value.b, old.b):
			var replacement: Color = next[role]
			replacement.a = value.a
			return replacement
	return value

static func _recolor_style(style: StyleBox, previous: Dictionary, next: Dictionary, seen: Dictionary) -> void:
	if not style is StyleBoxFlat or seen.has(style.get_instance_id()): return
	seen[style.get_instance_id()] = true
	style.bg_color = _remap(style.bg_color, previous, next)
	style.border_color = _remap(style.border_color, previous, next)

static func recolor_controls(node: Node, previous: Dictionary, next: Dictionary, seen: Dictionary = {}) -> void:
	# Update existing resources in place: no snapshots, hands or dialogs are rebuilt.
	if node is Control:
		var theme: Theme = node.theme
		if theme != null and not seen.has(theme.get_instance_id()):
			seen[theme.get_instance_id()] = true
			for type_name in theme.get_type_list():
				for key in theme.get_color_list(type_name): theme.set_color(key, type_name, _remap(theme.get_color(key, type_name), previous, next))
				for key in theme.get_stylebox_list(type_name): _recolor_style(theme.get_stylebox(key, type_name), previous, next, seen)
		for property in node.get_property_list():
			var key := str(property.name)
			if key.begins_with("theme_override_colors/") and node.has_theme_color_override(key.get_slice("/", 1)):
				node.set(key, _remap(node.get(key), previous, next))
			elif key.begins_with("theme_override_styles/") and node.has_theme_stylebox_override(key.get_slice("/", 1)):
				_recolor_style(node.get(key), previous, next, seen)
		if node is ColorRect: node.color = _remap(node.color, previous, next)
		if node is TextureRect and node.texture is GradientTexture2D:
			var gradient: Gradient = node.texture.gradient
			for index in range(gradient.get_point_count()): gradient.set_color(index, _remap(gradient.get_color(index), previous, next))
	for child in node.get_children(): recolor_controls(child, previous, next, seen)
