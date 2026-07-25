extends Control

signal navigate_requested(route: String, payload: Dictionary)

const VehicleCatalogType := preload("res://game/content/vehicle_catalog.gd")

var _selected: Dictionary
var _preview: TextureRect
var _car_name: Label
var _team_name: Label
var _number: Label
var _status: Label
var _buttons: Dictionary = {}


func _ready() -> void:
	var services := _services()
	var saved: Dictionary = services.call("selected_cosmetics") if services != null else {
		"car_id": VehicleCatalogType.DEFAULT_CAR_ID,
		"team_id": VehicleCatalogType.DEFAULT_TEAM_ID,
	}
	_selected = VehicleCatalogType.by_car_id(str(saved.get("car_id", VehicleCatalogType.DEFAULT_CAR_ID)))
	if not VehicleCatalogType.is_valid_pair(str(_selected["car_id"]), str(saved.get("team_id", _selected["team_id"]))):
		_selected = VehicleCatalogType.by_car_id(str(_selected["car_id"]))
	_build()
	_refresh_selection()


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
	var title := DesignSystem.title("GARAGE", 38)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(title)
	_status = DesignSystem.label("All cars share identical performance", 14, DesignSystem.MINT)
	_status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	top.add_child(_status)

	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 18)
	root.add_child(body)
	body.add_child(_build_preview_panel())
	body.add_child(_build_catalog_panel())


func _build_preview_panel() -> PanelContainer:
	var panel := PanelContainer.new()
	panel.custom_minimum_size.x = 390.0
	panel.add_theme_stylebox_override("panel", DesignSystem.panel_style(Color(0.035, 0.075, 0.135, 0.97), 28, Color(0.37, 1.0, 0.82, 0.16), 1))
	var content := VBoxContainer.new()
	content.alignment = BoxContainer.ALIGNMENT_CENTER
	content.add_theme_constant_override("separation", 5)
	panel.add_child(content)
	var eyebrow := DesignSystem.label("CURRENT DRIVE", 14, DesignSystem.MUTED)
	eyebrow.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(eyebrow)
	_preview = TextureRect.new()
	_preview.custom_minimum_size = Vector2(250.0, 310.0)
	_preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_preview.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	content.add_child(_preview)
	_car_name = DesignSystem.title("", 36)
	_car_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(_car_name)
	_team_name = DesignSystem.label("", 15, DesignSystem.MUTED)
	_team_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(_team_name)
	_number = DesignSystem.label("", 13, DesignSystem.GOLD)
	_number.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(_number)
	return panel


func _build_catalog_panel() -> PanelContainer:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", DesignSystem.panel_style(Color(0.047, 0.095, 0.17, 0.96), 28, Color(1.0, 1.0, 1.0, 0.08), 1))
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 12)
	panel.add_child(content)
	content.add_child(DesignSystem.label("CHOOSE YOUR FICTIONAL TEAM", 15, DesignSystem.MINT))
	var note := DesignSystem.label("Identity only — every car has identical speed, grip, braking, and steering.", 14, DesignSystem.MUTED)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(note)
	var grid := GridContainer.new()
	grid.columns = 4
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 10)
	content.add_child(grid)
	for vehicle in VehicleCatalogType.all():
		var button := Button.new()
		button.text = "%s\n%s" % [vehicle["number"], vehicle["name"]]
		button.custom_minimum_size = Vector2(142.0, 112.0)
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.size_flags_vertical = Control.SIZE_EXPAND_FILL
		button.add_theme_font_size_override("font_size", 16)
		button.add_theme_color_override("font_color", DesignSystem.WHITE)
		button.add_theme_color_override("font_hover_color", DesignSystem.WHITE)
		button.icon = load(str(vehicle["asset"])) as Texture2D
		button.add_theme_constant_override("icon_max_width", 42)
		button.expand_icon = true
		button.alignment = HORIZONTAL_ALIGNMENT_CENTER
		button.focus_mode = Control.FOCUS_ALL
		var car_id := str(vehicle["car_id"])
		button.pressed.connect(func() -> void: _select_car(car_id))
		grid.add_child(button)
		_buttons[car_id] = button
	return panel


func _select_car(car_id: String) -> void:
	var candidate := VehicleCatalogType.by_car_id(car_id)
	var services := _services()
	var result: Dictionary = services.call("set_selected_cosmetics", str(candidate["car_id"]), str(candidate["team_id"])) if services != null else {"ok": false, "message": "Local profile is unavailable."}
	if result.get("ok", false):
		_selected = candidate
		_status.text = "%s selected • saved locally" % candidate["name"]
		_status.add_theme_color_override("font_color", DesignSystem.MINT)
		_play_sfx(&"confirm")
		_refresh_selection()
	else:
		_status.text = str(result.get("message", "Selection could not be saved"))
		_status.add_theme_color_override("font_color", DesignSystem.CORAL)
		_play_sfx(&"error")


func _refresh_selection() -> void:
	_preview.texture = load(str(_selected["asset"])) as Texture2D
	_car_name.text = str(_selected["name"])
	_car_name.add_theme_color_override("font_color", _selected["accent"])
	_team_name.text = str(_selected["team"])
	_number.text = "CAR %s  •  FACTORY UNLOCKED" % _selected["number"]
	for car_id_variant in _buttons:
		var car_id := str(car_id_variant)
		var button: Button = _buttons[car_id]
		var vehicle := VehicleCatalogType.by_car_id(car_id)
		var active := car_id == str(_selected["car_id"])
		var border: Color = vehicle["accent"] if active else Color(1.0, 1.0, 1.0, 0.08)
		var border_width := 3 if active else 1
		button.add_theme_stylebox_override("normal", DesignSystem.panel_style(Color(0.07, 0.135, 0.235, 0.98), 16, border, border_width))
		button.add_theme_stylebox_override("hover", DesignSystem.panel_style(Color(0.1, 0.19, 0.32, 1.0), 16, vehicle["accent"], 2))
		button.add_theme_stylebox_override("pressed", DesignSystem.panel_style(Color(0.035, 0.075, 0.135, 1.0), 16, vehicle["accent"], 3))
		button.add_theme_stylebox_override("focus", DesignSystem.panel_style(Color.TRANSPARENT, 16, DesignSystem.GOLD, 3))
		button.tooltip_text = "%s — %s" % [vehicle["name"], vehicle["team"]]


func _services() -> Node:
	return get_node_or_null("/root/GameServices")


func _play_sfx(cue_id: StringName) -> void:
	var audio := get_node_or_null("/root/Audio")
	if audio != null and audio.has_method("play_sfx"):
		audio.call("play_sfx", cue_id)
