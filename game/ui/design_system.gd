class_name DesignSystem
extends RefCounted

const SafeMarginType := preload("res://game/ui/components/safe_margin_container.gd")

const INK := Color("07101f")
const INK_SOFT := Color("0c1830")
const PANEL := Color("101f3a")
const PANEL_LIGHT := Color("172b4c")
const MINT := Color("5fffd0")
const CYAN := Color("51c8ff")
const CORAL := Color("ff6b72")
const GOLD := Color("ffc857")
const WHITE := Color("f5f8ff")
const MUTED := Color("9aacbf")
const ROAD := Color("202b3a")
const GRASS := Color("102f2b")

const MIN_UI_SCALE := 0.85
const MAX_UI_SCALE := 1.30
const FONT_BASE_META: StringName = &"raceglyph_font_base_size"

static var _ui_scale := 1.0


static func configure_ui_scale(value: float) -> void:
	_ui_scale = clampf(value, MIN_UI_SCALE, MAX_UI_SCALE)


static func current_ui_scale() -> float:
	return _ui_scale


static func scaled_font_size(base_size: int, scale: float = _ui_scale) -> int:
	return maxi(1, roundi(float(base_size) * clampf(scale, MIN_UI_SCALE, MAX_UI_SCALE)))


static func apply_font_size(control: Control, base_size: int) -> void:
	if control == null:
		return
	control.set_meta(FONT_BASE_META, maxi(1, base_size))
	control.add_theme_font_size_override("font_size", scaled_font_size(base_size))


static func apply_ui_scale(root: Node, value: float = _ui_scale) -> void:
	if root == null:
		return
	configure_ui_scale(value)
	_apply_ui_scale_recursive(root)


static func _apply_ui_scale_recursive(node: Node) -> void:
	if node is Control:
		var control := node as Control
		if control.has_meta(FONT_BASE_META):
			control.add_theme_font_size_override(
				"font_size", scaled_font_size(int(control.get_meta(FONT_BASE_META)))
			)
		elif control.has_theme_font_size_override("font_size"):
			var baseline := control.get_theme_font_size("font_size")
			control.set_meta(FONT_BASE_META, baseline)
			control.add_theme_font_size_override("font_size", scaled_font_size(baseline))
	for child in node.get_children():
		_apply_ui_scale_recursive(child)

static func panel_style(color: Color = PANEL, radius: int = 22, border_color: Color = Color.TRANSPARENT, border_width: int = 0) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.corner_radius_top_left = radius
	style.corner_radius_top_right = radius
	style.corner_radius_bottom_left = radius
	style.corner_radius_bottom_right = radius
	style.border_width_left = border_width
	style.border_width_top = border_width
	style.border_width_right = border_width
	style.border_width_bottom = border_width
	style.border_color = border_color
	style.content_margin_left = 24.0
	style.content_margin_top = 18.0
	style.content_margin_right = 24.0
	style.content_margin_bottom = 18.0
	style.shadow_color = Color(0.0, 0.0, 0.0, 0.24)
	style.shadow_size = 10
	style.shadow_offset = Vector2(0.0, 6.0)
	return style

static func button(text: String, primary: bool = false, compact: bool = false) -> Button:
	var result := Button.new()
	result.text = text
	result.focus_mode = Control.FOCUS_ALL
	result.custom_minimum_size = Vector2(190.0 if compact else 260.0, 52.0 if compact else 64.0)
	apply_font_size(result, 17 if compact else 20)
	result.add_theme_color_override("font_color", INK if primary else WHITE)
	result.add_theme_color_override("font_hover_color", INK if primary else WHITE)
	result.add_theme_color_override("font_pressed_color", INK if primary else WHITE)
	var normal := panel_style(MINT if primary else PANEL_LIGHT, 16, Color(1.0, 1.0, 1.0, 0.08), 1)
	var hover := panel_style(CYAN if primary else Color("203b65"), 16, Color(1.0, 1.0, 1.0, 0.22), 1)
	var pressed := panel_style(Color("42d7ad") if primary else Color("0c172b"), 16, MINT, 2)
	result.add_theme_stylebox_override("normal", normal)
	result.add_theme_stylebox_override("hover", hover)
	result.add_theme_stylebox_override("pressed", pressed)
	result.add_theme_stylebox_override("focus", panel_style(Color.TRANSPARENT, 16, GOLD, 3))
	result.pressed.connect(func() -> void:
		var audio := result.get_node_or_null("/root/Audio")
		if audio != null:
			audio.call("play_sfx", &"click")
	)
	return result

static func label(text: String, size: int = 18, color: Color = WHITE) -> Label:
	var result := Label.new()
	result.text = text
	apply_font_size(result, size)
	result.add_theme_color_override("font_color", color)
	return result

static func title(text: String, size: int = 56) -> Label:
	var result := label(text, size, WHITE)
	result.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.45))
	result.add_theme_constant_override("shadow_offset_x", 0)
	result.add_theme_constant_override("shadow_offset_y", 5)
	return result

static func make_margin(left: int, top: int, right: int, bottom: int) -> MarginContainer:
	var margin := SafeMarginType.new()
	margin.configure(left, top, right, bottom)
	return margin

static func screen_button(text: String) -> Button:
	var result := button(text, false, true)
	result.custom_minimum_size = Vector2(148.0, 50.0)
	return result
