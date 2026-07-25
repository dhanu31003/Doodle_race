class_name MainMenuScreen
extends Control

signal navigate_requested(route: String, payload: Dictionary)

func _ready() -> void:
	_build()

func _build() -> void:
	var safe := DesignSystem.make_margin(64, 24, 64, 24)
	safe.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(safe)

	var layout := HBoxContainer.new()
	layout.add_theme_constant_override("separation", 44)
	safe.add_child(layout)

	var hero := VBoxContainer.new()
	hero.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hero.size_flags_stretch_ratio = 1.28
	hero.alignment = BoxContainer.ALIGNMENT_CENTER
	hero.add_theme_constant_override("separation", 10)
	layout.add_child(hero)

	var eyebrow := DesignSystem.label("DRAW  •  GENERATE  •  RACE", 17, DesignSystem.MINT)
	eyebrow.add_theme_constant_override("outline_size", 6)
	eyebrow.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.28))
	hero.add_child(eyebrow)

	var title := DesignSystem.title("RACE\nGLYPH", 72)
	title.autowrap_mode = TextServer.AUTOWRAP_OFF
	title.add_theme_constant_override("line_spacing", -12)
	hero.add_child(title)

	var rule := ColorRect.new()
	rule.color = DesignSystem.MINT
	rule.custom_minimum_size = Vector2(132.0, 5.0)
	rule.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	hero.add_child(rule)

	var tagline := DesignSystem.label("Your line becomes the circuit.\nYour nerve decides the finish.", 22, DesignSystem.MUTED)
	tagline.add_theme_constant_override("line_spacing", 5)
	hero.add_child(tagline)

	var version_name := str(ProjectSettings.get_setting("application/config/version", "0.2.0"))
	var version := DesignSystem.label("VERSION %s" % version_name, 13, Color(0.6, 0.68, 0.76, 0.72))
	version.add_theme_constant_override("outline_size", 4)
	version.add_theme_color_override("font_outline_color", DesignSystem.INK)
	hero.add_child(version)

	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(390.0, 0.0)
	card.add_theme_stylebox_override("panel", DesignSystem.panel_style(Color(0.047, 0.095, 0.17, 0.94), 28, Color(0.37, 1.0, 0.82, 0.18), 1))
	layout.add_child(card)

	var menu := VBoxContainer.new()
	menu.add_theme_constant_override("separation", 12)
	card.add_child(menu)
	var menu_title := DesignSystem.label("START YOUR RUN", 15, DesignSystem.MUTED)
	menu.add_child(menu_title)
	_add_route_button(menu, "TRACK STUDIO", "studio", true)
	_add_route_button(menu, "OFFLINE RACE", "tracks")
	_add_route_button(menu, "PRIVATE ROOM", "multiplayer")
	var split := HSeparator.new()
	split.add_theme_constant_override("separation", 6)
	menu.add_child(split)
	_add_route_button(menu, "SAVED TRACKS", "saved")
	_add_route_button(menu, "GARAGE", "garage")
	_add_route_button(menu, "SETTINGS", "settings")
	_add_route_button(menu, "CREDITS & LICENSES", "credits")

func _add_route_button(container: VBoxContainer, text: String, route: String, primary: bool = false) -> void:
	var item := DesignSystem.button(text, primary)
	# Seven complete routes remain visible at maximum text scale on the 720p
	# landscape baseline while retaining a generous mobile touch target.
	item.custom_minimum_size.y = 54.0
	item.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	item.pressed.connect(func() -> void: navigate_requested.emit(route, {}))
	container.add_child(item)
