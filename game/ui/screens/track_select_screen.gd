extends Control

signal navigate_requested(route: String, payload: Dictionary)

const CatalogType := preload("res://game/content/predefined_track_catalog.gd")
const CompilerType := preload("res://game/track/generation/track_compiler.gd")
const TrackRendererType := preload("res://game/track/rendering/track_renderer.gd")

var _items: Array[Dictionary] = []
var _selected: Dictionary
var _renderer: TrackRenderer
var _name_label: Label
var _location_label: Label
var _description_label: Label
var _spec_label: Label
var _status_label: Label
var _track_buttons: Dictionary = {}


func _ready() -> void:
	_items = CatalogType.all()
	_selected = _items[0]
	_build()
	_refresh_selected()


func _build() -> void:
	var safe := DesignSystem.make_margin(42, 28, 42, 30)
	safe.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(safe)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 14)
	safe.add_child(root)

	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 14)
	root.add_child(top)
	var back := DesignSystem.screen_button("‹ PADDOCK")
	back.pressed.connect(func() -> void: navigate_requested.emit("home", {}))
	top.add_child(back)
	var title := DesignSystem.title("OFFLINE CIRCUITS", 38)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(title)
	_status_label = DesignSystem.label("%d release circuits • fully offline" % _items.size(), 14, DesignSystem.MINT)
	_status_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	top.add_child(_status_label)

	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 18)
	root.add_child(body)
	body.add_child(_build_preview())
	body.add_child(_build_configuration())


func _build_preview() -> PanelContainer:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_stretch_ratio = 1.55
	panel.add_theme_stylebox_override("panel", DesignSystem.panel_style(Color(0.035, 0.075, 0.135, 0.97), 28, Color(0.37, 1.0, 0.82, 0.16), 1))
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 7)
	panel.add_child(content)
	var heading := HBoxContainer.new()
	content.add_child(heading)
	var labels := VBoxContainer.new()
	labels.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	heading.add_child(labels)
	_name_label = DesignSystem.title("", 33)
	labels.add_child(_name_label)
	_location_label = DesignSystem.label("", 14, DesignSystem.MUTED)
	labels.add_child(_location_label)
	_spec_label = DesignSystem.label("", 14, DesignSystem.GOLD)
	_spec_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	heading.add_child(_spec_label)
	var frame := PanelContainer.new()
	frame.size_flags_vertical = Control.SIZE_EXPAND_FILL
	frame.add_theme_stylebox_override("panel", DesignSystem.panel_style(DesignSystem.GRASS, 20, Color(1.0, 1.0, 1.0, 0.08), 1))
	content.add_child(frame)
	_renderer = TrackRendererType.new()
	# The preview remains expand-fill at ordinary UI scale. A smaller vertical
	# floor gives enlarged text enough room at 1280x720 / 1.30x without pushing
	# the root safe-area container below the viewport.
	_renderer.custom_minimum_size = Vector2(640.0, 320.0)
	_renderer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_renderer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_renderer.clip_contents = true
	frame.add_child(_renderer)
	_description_label = DesignSystem.label("", 15, DesignSystem.WHITE)
	_description_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_description_label.custom_minimum_size.y = 38.0
	content.add_child(_description_label)
	return panel


func _build_configuration() -> PanelContainer:
	var panel := PanelContainer.new()
	panel.custom_minimum_size.x = 405.0
	panel.add_theme_stylebox_override("panel", DesignSystem.panel_style(Color(0.047, 0.095, 0.17, 0.97), 28, Color(1.0, 1.0, 1.0, 0.08), 1))
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 7)
	panel.add_child(content)
	content.add_child(DesignSystem.label("SELECT CIRCUIT", 15, DesignSystem.MINT))
	var track_scroll := ScrollContainer.new()
	track_scroll.custom_minimum_size.y = 188.0
	track_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	track_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	track_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	content.add_child(track_scroll)
	var track_list := VBoxContainer.new()
	track_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	track_list.add_theme_constant_override("separation", 5)
	track_scroll.add_child(track_list)
	for item in _items:
		var button := Button.new()
		button.text = "%s  •  %s" % [item["name"], _difficulty_marks(int(item["difficulty"]))]
		button.custom_minimum_size.y = 39.0
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.add_theme_font_size_override("font_size", 14)
		button.add_theme_color_override("font_color", DesignSystem.WHITE)
		button.add_theme_color_override("font_hover_color", DesignSystem.WHITE)
		var track_id := str(item["track_id"])
		button.pressed.connect(func() -> void: _select_track(track_id))
		track_list.add_child(button)
		_track_buttons[track_id] = button

	var divider := HSeparator.new()
	content.add_child(divider)
	var next_step := DesignSystem.label(
		"Tour the generated circuit, or continue to race setup for laps, AI, grid size and collisions.",
		14,
		DesignSystem.MUTED
	)
	next_step.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	next_step.custom_minimum_size.y = 54.0
	content.add_child(next_step)
	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 10)
	content.add_child(buttons)
	var tour := DesignSystem.button("TOUR", false, true)
	tour.custom_minimum_size.y = 48.0
	tour.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tour.pressed.connect(func() -> void: navigate_requested.emit("tour", _configured_payload()))
	buttons.add_child(tour)
	var race := DesignSystem.button("RACE SETUP  ›", true, true)
	race.custom_minimum_size.y = 48.0
	race.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	race.pressed.connect(func() -> void:
		var setup_payload := _configured_payload()
		setup_payload["_config_return_route"] = "tracks"
		navigate_requested.emit("race_config", setup_payload)
	)
	buttons.add_child(race)
	return panel


func _select_track(track_id: String) -> void:
	_selected = CatalogType.by_id(track_id)
	_refresh_selected()
	var audio := get_node_or_null("/root/Audio")
	if audio != null:
		audio.call("play_sfx", &"click")


func _refresh_selected() -> void:
	var definition: TrackDefinition = _selected["definition"]
	var compiled: TrackCompileResult = CompilerType.compile(definition)
	if not compiled.succeeded():
		_status_label.text = "Circuit verification failed"
		_status_label.add_theme_color_override("font_color", DesignSystem.CORAL)
		return
	if not _renderer.set_track_world(definition, compiled.track):
		_status_label.text = "Circuit world generation failed"
		_status_label.add_theme_color_override("font_color", DesignSystem.CORAL)
		return
	_name_label.text = str(_selected["name"])
	_name_label.add_theme_color_override("font_color", _selected["accent"])
	_location_label.text = str(_selected["location"])
	_description_label.text = str(_selected["description"])
	_spec_label.text = "%d m  •  %s  •  %s" % [
		roundi(compiled.track.total_length),
		"PIT %s" % str(definition.pit_side).to_upper() if str(definition.pit_side) != "none" else "NO PIT",
		_difficulty_marks(int(_selected["difficulty"])),
	]
	for id_variant in _track_buttons:
		var track_id := str(id_variant)
		var button: Button = _track_buttons[track_id]
		var item := CatalogType.by_id(track_id)
		var active := track_id == str(_selected["track_id"])
		button.add_theme_stylebox_override("normal", DesignSystem.panel_style(
			Color(0.07, 0.135, 0.235, 0.98), 13,
			item["accent"] if active else Color(1.0, 1.0, 1.0, 0.07),
			3 if active else 1
		))
		button.add_theme_stylebox_override("hover", DesignSystem.panel_style(Color(0.1, 0.19, 0.32, 1.0), 13, item["accent"], 2))
		button.add_theme_stylebox_override("pressed", DesignSystem.panel_style(Color(0.035, 0.075, 0.135, 1.0), 13, item["accent"], 3))
		button.add_theme_stylebox_override("focus", DesignSystem.panel_style(Color.TRANSPARENT, 13, DesignSystem.GOLD, 3))


func _configured_payload() -> Dictionary:
	var payload := CatalogType.race_payload(str(_selected["track_id"]), 3, "standard")
	payload["collisions"] = true
	payload["grid_size"] = 12
	payload["display_name"] = str(_selected["name"])
	payload["location"] = str(_selected["location"])
	payload["accent"] = (_selected["accent"] as Color).to_html()
	return payload


func _difficulty_marks(value: int) -> String:
	return "◆".repeat(clampi(value, 1, 4)) + "◇".repeat(4 - clampi(value, 1, 4))
